# Laniakea

A Rust-based zero-knowledge proving SDK targeting iOS devices.

## Project Goal

Laniakea enables Circom circuits with Groth16 proofs to run fully on iOS devices:

- Witness generation and proving happen on-device
- No private inputs leave the device
- No server required for proof generation
- Pure Rust proving pipeline (no JIT, no Wasmer on iOS)

Long-term: support for Noir + Barretenberg and other proving ecosystems.

## Current Status

The core Rust proving pipeline is implemented and tested. The iOS-compatible proving code compiles for `aarch64-apple-ios`. Swift/UniFFI application integration is the next major phase.

**What works today:**

| Component | Status |
|-----------|--------|
| Circom age-check example circuit | ✅ Compiled artifacts (R1CS, WASM, zkey) |
| Wasmi witness generation | ✅ Tested against reference implementation |
| ProvingArtifact (portable zkey representation) | ✅ Serialization + roundtrip tested |
| Portable CircomReduction | ✅ Matches ark-circom output element-for-element |
| Portable Groth16 proving | ✅ End-to-end test passes; proof verifies with snarkjs |
| iOS compilation + dependency isolation | ✅ No ark-circom / Wasmer / Cranelift on iOS target |

**Not yet complete:**

- High-level Rust API (Phase 5)
- UniFFI / Swift bindings (Phase 6)
- Packaged iOS app with real SwiftUI flow (Phase 7)

## Architecture

```
Swift / iOS (future)
        ↓
     UniFFI
        ↓
  laniakea-core
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
artifact.bin  ──► bundled with iOS app
```

### Runtime (iOS)

```
User input (age=25, threshold=18)
        ↓
age_check.wasm  ──► Wasmi interpreter
        ↓
Vec<Fr> witness  [1, 1, 18, 25, ...]
        ↓
ProvingArtifact (deserialized from artifact.bin)
        ↓
prove_with_artifact(artifact, witness)
        ├─► CircomReduction::witness_map_from_matrices()
        ├─► Groth16::create_proof_with_reduction_and_matrices()
        ▼
Groth16 Proof (a, b, c in G1/G2)
        ↓
proof_to_json()  → snarkjs-compatible JSON
```

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
│   │   │   ├── prover.rs             # Portable prove_with_artifact()
│   │   │   └── mod.rs
│   │   ├── witness.rs            # WitnessCalculator trait
│   │   ├── witness_wasmi.rs      # Wasmi adapter
│   │   └── witness_ark.rs        # ark-circom adapter (desktop)
│   └── tests/
│       ├── witness_equivalence.rs
│       └── circom_reduction_compare.rs
├── wasmi-witness/
│   └── src/lib.rs                # Standalone Wasmi witness execution
├── laniakea-uniffi/
│   └── ...                       # FFI layer (future Swift integration)
└── laniakea-cli/
    └── ...                       # CLI tooling

circuits/
└── age_check/
    ├── age_check.circom
    ├── age_check.r1cs
    ├── age_check_js/age_check.wasm
    ├── age_check_final.zkey
    └── verification_key.json

examples/
└── ios-age-app/
    └── ...                       # iOS example / integration area
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
**Status: NEXT / NOT STARTED**

Goal: Clean API hiding Arkworks internals

```rust
// Conceptual - not yet implemented
let prover = Prover::from_artifact(artifact_bytes, wasm_bytes)?;
let result = prover.prove(inputs)?;
```

### Phase 6 — UniFFI / Swift integration
**Status: NOT STARTED / PARTIAL INFRASTRUCTURE ONLY**

- Expose high-level Rust API via UniFFI
- Generate Swift bindings
- Ergonomic SwiftUI API
- Keep Arkworks/internal types off FFI boundary

### Phase 7 — Real iOS packaging and on-device proving
**Status: NOT STARTED**

- Package Rust library for iOS
- Bundle WASM + proving artifact with app
- SwiftUI flow: user input → witness → proof
- Test on simulator + device
- Measure proving time, memory, binary size, battery/thermal

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

# Core tests (witness, artifacts, reduction, proving)
cargo test -p wasmi-witness -p laniakea-core

# Format
cargo fmt --all
```

## License

MIT OR Apache-2.0