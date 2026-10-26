# 🌌💫 Laniakea

A Rust-based zero-knowledge proving SDK targeting iOS devices.

## Project Goal

Laniakea enables Circom circuits with Groth16 proofs to run fully on iOS devices:

- Witness generation and proving happen on-device
- No private inputs leave the device
- No server required for proof generation
- Pure Rust proving pipeline (no JIT, no Wasmer on iOS)

Long-term: support for Noir + Barretenberg and other proving ecosystems.

## Current Status

The Rust proving pipeline, the UniFFI/Swift bindings, the iOS packaging scripts and a minimal SwiftUI demo app are implemented. The demo builds with Xcode and runs on an iOS Simulator (iPhone Duo, iOS 27.1), where it generates proofs on-device. It has **not** been run on a physical device, and proof timing, memory and binary size on real hardware are unmeasured. Nothing here has been audited.

**What works today:**

| Component | Status |
|-----------|--------|
| Circom age-check example circuit | ✅ Compiled artifacts (R1CS, WASM, zkey) |
| Wasmi witness generation | ✅ Tested against reference implementation |
| ProvingArtifact (portable zkey representation) | ✅ Serialization + roundtrip tested |
| Portable CircomReduction | ✅ Matches ark-circom output element-for-element |
| Portable Groth16 proving | ✅ End-to-end test passes; proof verifies with snarkjs |
| iOS compilation + dependency isolation | ✅ No ark-circom / Wasmer / Cranelift on iOS target |
| High-level `Prover` API | ✅ Inputs in, proof + public signals out; validated artifacts, point validation, structured errors |
| UniFFI bindings (`LaniakeaProver`) | ✅ Swift bindings generated; macOS Swift smoke test passes, proof verified by snarkjs |
| iOS static libraries + XCFramework + Swift package | ✅ Built with Xcode 27.1 (device + arm64 simulator slices) |
| SwiftUI age-check demo | ✅ Xcode project builds; runs on the iPhone Duo simulator |

**Not yet complete:**

- Physical-device testing and measurements (proving time, memory, binary size, battery/thermal)
- Signed device builds, Release archive and App Store validation
- On-device proof verification (the FFI exposes no verifier; the demo generates proofs but does not verify them)
- Intel (x86_64) simulator support
- Production hardening and security review

## Architecture

```
SwiftUI app (examples/ios-age-app)
        ↓
 Swift package LaniakeaKit (`import Laniakea`)
        ↓
 UniFFI  (laniakea-uniffi: LaniakeaProver)
        ↓
  laniakea-core  (Prover)
        ├──────────────────────────────────────────┐
        │                                          │
        ▼                                          ▼
   Desktop (macOS/Linux)                      iOS Target
   ─────────────────────────────────────────────────────
   ark-circom for:                            Wasmi for:
   • zkey → ProvingArtifact                   • Circom WASM witness
   • Reference witness                        • No JIT / Wasmer
   • Desktop testing                          • Pure Rust
```

### Platform Separation

| Platform | Proving | Witness | Dependencies |
|----------|---------|---------|--------------|
| Desktop (macOS/Linux) | ✅ ark-circom + Wasmer | ark-circom / Wasmi | ark-circom, Wasmer |
| iOS | ✅ portable prover | Wasmi | **No** ark-circom, Wasmer, Cranelift |

## Pipeline

### Build Time (Desktop)

```
Circom circuit (.circom)
        ↓
circom compiler
        ↓
┌──────────────────────────────────────────────┐
│ age_check.r1cs    age_check.wasm    age_check.zkey  │
└──────────────────────────────────────────────┘
        ↓
parse_zkey_to_artifact()  (uses ark-circom)
        ↓
ProvingArtifact { ProvingKey, ConstraintMatrices }
        ↓
serialize (CanonicalSerialize)
        ↓
age_check.artifact  ──► bundled with iOS app (export_artifact)
```

### Runtime (iOS)

```
User input (age=25, threshold=18)
        ↓  (SwiftUI → LaniakeaProver.prove via UniFFI)
age_check.wasm  ──► Wasmi interpreter
        ↓
Vec<Fr> witness  [1, 1, 18, 25, ...]
        ↓
ProvingArtifact (deserialized from age_check.artifact)
        ↓
prove_with_artifact(artifact, witness)
        ├─► CircomReduction::witness_map_from_matrices()
        ├─► Groth16::create_proof_with_reduction_and_matrices()
        ▼
Groth16 Proof (a, b, c in G1/G2)
        ↓
proof_json + public signals  → snarkjs-compatible JSON, e.g. ["1", "18"]
```

Public signals are `[out, threshold]`. The age-check circuit does **not** constrain `out == 1`, so a valid proof exists for an ineligible age too; callers must read `out`. `GreaterEqThan(8)` also does not enforce that inputs are in 0–255; the demo app enforces that range itself.

## Implemented Pieces

### 1. Circom age-check example
- Circuit: `age >= threshold` predicate
- Compiled artifacts in `circuits/age_check/`
  - `age_check.r1cs`
  - `age_check_js/age_check.wasm`
  - `age_check_final.zkey`
- Validated against snarkjs during development

### 2. Wasmi witness generation
- Pure Rust WASM interpreter (`wasmi` crate)
- Executes Circom 2.0 generated witness calculator
- Produces BN254 `Vec<Fr>` witness
- Tested against desktop `ark-circom` witness output

### 3. iOS dependency isolation
- `cargo check -p laniakea-core --target aarch64-apple-ios` passes
- iOS dependency tree contains: `wasmi-witness`, `ark-groth16`, `ark-bn254`, `ark-snark`, `ark-relations`, `ark-ff`, `ark-poly`
- **Excludes**: `ark-circom`, `wasmer`, `cranelift`

### 4. ProvingArtifact
- Portable representation of proving data from zkey
- Fields: `ProvingKey<Bn254>`, `ConstraintMatrices<Fr>` (wrapped for serialization)
- `CanonicalSerialize` / `CanonicalDeserialize` roundtrip tested

### 5. Portable CircomReduction
- Implements `R1CSToQAP` trait
- Mirrors snarkjs/Circom QAP convention (double-sized domain, odd coefficients)
- Output matches `vendor/ark-circom/src/circom/qap.rs` element-for-element

### 6. Portable Groth16 proving
- `prove_with_artifact(ProvingArtifact, witness) → Proof<Bn254>`
- Uses `ark-groth16` + Laniakea's `CircomReduction`
- Proof serialized to snarkjs-compatible JSON (`pi_a`, `pi_b`, `pi_c`)
- Verification via parsed `verification_key.json`
- End-to-end test passes; proof verified by both ark-groth16 and snarkjs

## Repository Structure

```
crates/
├── laniakea-core/
│   ├── src/
│   │   ├── artifacts.rs          # ProvingArtifact + zkey parsing
│   │   ├── backend/
│   │   │   ├── circom_reduction.rs   # Portable CircomReduction
│   │   │   ├── groth16.rs            # Groth16 backend
│   │   │   ├── points.rs             # Curve/subgroup point validation
│   │   │   ├── prover.rs             # Portable prove_with_artifact()
│   │   │   └── mod.rs
│   │   ├── api.rs                # High-level Prover API
│   │   ├── error.rs              # Structured errors
│   │   ├── witness.rs            # WitnessCalculator trait
│   │   ├── witness_wasmi.rs      # Wasmi adapter
│   │   └── witness_ark.rs        # ark-circom adapter (desktop)
│   └── tests/                    # witness, reduction, artifact/point validation, Prover API
├── wasmi-witness/
│   └── src/lib.rs                # Standalone Wasmi witness execution
├── laniakea-uniffi/
│   └── src/                      # UniFFI layer: LaniakeaProver, ProverError
├── uniffi-bindgen/               # Host-only Swift binding generator
└── laniakea-cli/
    └── src/bin/export_artifact.rs  # .zkey → ProvingArtifact bytes

scripts/
├── gen-swift-bindings.sh         # Generate Swift bindings
├── swift-smoke.sh                # macOS Swift smoke test (+ snarkjs verification)
├── build-ios.sh                  # Build + verify iOS static libraries
├── package-xcframework.sh        # XCFramework + LaniakeaKit Swift package
├── prepare-ios-app-resources.sh  # Copy/verify the demo app's resources
├── swift-app-logic-test.sh       # macOS logic tests for the demo app
└── run-ios-sim-app.sh            # Scripted simulator build/run harness

swift/LaniakeaKit/                # Package.swift template (package is generated under target/)

circuits/
└── age_check/
    ├── age_check.circom
    ├── age_check.r1cs
    ├── age_check_js/age_check.wasm
    ├── age_check_final.zkey
    └── verification_key.json

examples/
└── ios-age-app/                  # SwiftUI age-check demo (see its README)
    ├── AgeCheckApp/              # app sources + bundled resources
    ├── AgeCheckDemo/             # Xcode project
    └── Tests-macOS/              # logic tests
```

## Development Phases

### Phase 1 — Portable witness generation
**Status: COMPLETE**

- Witness abstraction (`WitnessCalculator` trait)
- Circom WASM witness generation via Wasmi
- Desktop/reference witness path available
- Wasmi output validated against reference

### Phase 2 — Groth16 integration / backend foundation
**Status: COMPLETE**

- Groth16 proving + verification integrated
- Circom zkey/R1CS parsing on desktop
- Platform boundary established
- Age-check circuit validated end-to-end

### Phase 3 — Platform-aware proving architecture
**Status: COMPLETE**

- iOS target excludes ark-circom/Wasmer/JIT
- Desktop artifact preparation separated from portable proving
- Groth16 backend exposes verification independently

### Phase 4 — Portable Circom Groth16 proving
**Status: COMPLETE**

- `ProvingArtifact` with serialization
- Portable `CircomReduction` implementation
- Portable `prove_with_artifact()` function
- Reduction validated against ark-circom
- End-to-end proof generation + verification (ark-groth16 + snarkjs)
- iOS compilation + dependency isolation verified

### Phase 5 — High-level Rust proving API
**Status: COMPLETE**

Goal: Clean API hiding Arkworks internals, with validated artifacts, point validation and structured errors

```rust
// From serialized artifact bytes (validated on construction):
let prover = Prover::new(&artifact_bytes, &wasm_bytes)?;
// ...or from an already-decoded ProvingArtifact:
// let prover = Prover::from_artifact(artifact, &wasm_bytes)?;

// inputs: &[(String, Vec<BigInt>)], e.g. [("age".into(), vec![25.into()]), ...]
let result = prover.prove(&inputs)?;
// result.public_signals: decimal strings, e.g. ["1", "18"]; check `out` yourself
```

### Phase 6 — UniFFI / Swift integration
**Status: COMPLETE (simulator only)**

- 6a: high-level API exposed via UniFFI (`LaniakeaProver`), no Arkworks types on the FFI boundary
- 6b: Swift bindings generation and a macOS Swift smoke test
- 6c: iOS static-library build, XCFramework and Swift package (`LaniakeaKit`)
- 6d: minimal SwiftUI age-check demo with an Xcode project, run on the iOS Simulator

UniFFI is pinned at 0.28.3; the generated bindings compile in Swift 5 language mode.

### Phase 7 — On-device proving and measurement
**Status: NOT STARTED**

- Run on a physical device (signed build)
- Measure proving time, memory, binary size, battery/thermal
- Release archive / App Store validation
- Decide whether to expose on-device verification

### Phase 8 — Production hardening
**Status: FUTURE**

- Artifact/version management
- Error handling + API stability
- Performance + memory optimization
- Security review
- More circuits + broader testing

### Future proving systems
**Status: FUTURE**

- Noir
- Barretenberg
- Other ecosystems

## Running Tests

```bash
# Full workspace check
cargo check --workspace

# iOS target check
cargo check -p laniakea-core --target aarch64-apple-ios

# Rust tests (witness, artifacts, reduction, proving, FFI layer)
cargo test -p wasmi-witness -p laniakea-core -p laniakea-uniffi

# Swift smoke test (macOS host; set REQUIRE_SNARKJS=1 to require snarkjs)
scripts/swift-smoke.sh

# Demo app: resources, logic tests (macOS), iOS package (needs Xcode)
scripts/prepare-ios-app-resources.sh --check
scripts/swift-app-logic-test.sh
scripts/package-xcframework.sh

# Format
cargo fmt --all
```

## License

MIT OR Apache-2.0
