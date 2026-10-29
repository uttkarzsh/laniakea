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
| iOS static libraries + XCFramework + Swift package | ✅ Built with Xcode 27.1 (device + arm64 simulator slices). Consuming the package needs Swift tools 6.0, i.e. Xcode 16.0 or later (not tested below 27.1) |
| SwiftUI age-check demo | ✅ Xcode project builds; runs on the iPhone Duo simulator |

**Not yet complete:**

- Physical-device testing and measurements (proving time, memory, binary size, battery/thermal)
- Signed device builds, Release archive and App Store validation
- On-device proof verification (the FFI exposes no verifier; the demo generates proofs but does not verify them)
- Intel (x86_64) simulator support (deferred)
- Production hardening and security review

## Architecture

```
SwiftUI app (examples/ios-age-app)
        ↓
 Swift package LaniakeaKit (`import LaniakeaKit`: Circuit, Prover, Proof, LaniakeaError)
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

## Security Model: Proving, Verifying, and Deciding

The age-check app is a **demonstration of on-device proof generation**. It is not a
production identity or age-verification system, and nothing here has been audited. Three
separate things must not be confused:

1. **Proof generation** (this repository, on the device). `LaniakeaProver.prove` runs the
   committed circuit on the inputs and returns a Groth16 proof plus the public signals.
   Producing a proof is not verifying it: the FFI exposes no verifier, so the demo app
   never verifies its own proof and says so on screen.
2. **Proof verification** (a verifier, elsewhere). Checks that a proof is valid for a
   given verification key and given public signals, for example `snarkjs groth16 verify
   circuits/age_check/verification_key.json public.json proof.json`, which the logic
   tests do. The verifier must choose and pin the verification key itself; a key supplied
   by the party being verified proves nothing.
3. **Application policy** (the verifier's decision). A valid proof only says that the
   committed circuit's constraints are satisfied for those public signals. What that
   means is up to whoever reads the signals.

**What a valid age_check proof establishes.** The public signals are `[out, threshold]`.
`age` is a private input and does not appear in the proof or the signals. The circuit
constrains `out` to be the result of `GreaterEqThan(8)(age, threshold)`, and nothing more:
- It does **not** require `out == 1`. A valid proof with `out = 0` is a proof that the
  condition is false, not of eligibility. A verifier must require `out == 1` and the
  threshold it expects (the demo's check is `["1", "18"]`).
- It does **not** range-check `age` or `threshold` to 8 bits. With threshold 18 it also
  accepts ages 256–273 (with `out = 1`) and field elements just below the modulus (with
  `out = 0`). See `crates/laniakea-core/tests/age_check_behavior.rs`.

**Where inputs are restricted, and where they are not.** The layers differ:
- The circuit: the rule above, and nothing about 8 bits.
- `laniakea-core`: reduces input values modulo the field (negatives wrap).
- The UniFFI boundary: accepts only canonical non-negative decimal strings below the
  field modulus. It does not limit age to 255.
- The demo app: accepts only ASCII digits in 0–255 (`AgeProofService.parseAge`).

App-level validation only constrains the honest app. Anyone who generates proofs
with their own tooling is bound only by the circuit, so a verifier must not assume that
the app's range check was applied.

**The age is self-asserted.** The user types it. Nothing ties it to an identity document
or to any authority, so a proof only says "the prover knows an `age` input that satisfies
the comparison", not that the age is true.

**Privacy.** Under the implementation, the proof and signals contain `out` and the
threshold, not the age; the demo makes no network requests and keeps the age on the
device. The proof does reveal the comparison result, and a surrounding application can
still leak the age or link users through other data (timing, identifiers, repeated
proofs). No anonymity beyond this is claimed.

**No replay or recipient protection.** The circuit has no nonce, session, verifier or
timestamp input, and the signals contain none. A proof for `["1","18"]` is valid
whenever and wherever it is presented, and can be copied and replayed by anyone who
holds it. An integration that needs freshness or recipient binding must add public inputs
and circuit and application logic for them; this repository does not implement that.

**Trusted setup.** Verifying a proof, or the key consistency checks, does not show that
the setup was sound. See *Trusted Setup Provenance* below: the current key is a
development key and must not back decisions that rely on proof soundness.

**Current behavior versus a production design.** Everything above is current behavior. A
production design would at least need: a verifier that pins the verification key and
checks `out == 1` and the expected threshold; range constraints in the circuit; a
nonce or session binding; a trusted source for the age (for example a signed credential
verified in-circuit) instead of self-assertion; a documented setup ceremony; and an
independent security review. None of these exist yet.

## Trusted Setup Provenance (age_check)

**Treat `circuits/age_check/age_check_final.zkey` as a development key.** Its setup
cannot be verified from this repository, and nothing here establishes that it is sound.

**What the repository records**
- The `.zkey`, `age_check.r1cs`, the WASM, `verification_key.json` and the circuit source
  were added together in one commit (`829842d`, "feat: add age check circuit artifacts",
  author date 2026-10-04) with no earlier history. No script, log, `.ptau` file,
  checksum list or README note says how they were produced. Git history cannot say more
  than that.
- The `.zkey` describes itself (read by hand from its sections, not by `snarkjs`):
  Groth16 on BN254, 15 variables, 2 public signals, domain size 16, and **one**
  recorded contribution, of the ordinary (non-beacon) kind, named `laniakea dev`. That
  name is free text; the file cannot prove who contributed, when, or with what
  randomness.

**What is missing**
- The Powers of Tau (phase 1) file that was used, or even its name, source or hash.
- The commands and `snarkjs` version used for `zkey new` / `zkey contribute`.
- Any evidence that the contribution's secret was destroyed, any beacon, any second
  contributor, and any contribution transcript.

**What can be checked today** (all read-only)
- `REQUIRE_SNARKJS=1 scripts/check-vk-consistency.sh`: the key inside the `.zkey`, the
  bundled `age_check.artifact`, `verification_key.json` and the key `snarkjs` derives
  from the `.zkey` are the same key.
- `REQUIRE_SNARKJS=1 scripts/check-circuit-behavior.sh`: proofs verify under `verification_key.json`
  (Rust and `snarkjs`), and what the circuit accepts and rejects (see above).
- `snarkjs zkey verify age_check.r1cs <ptau> age_check_final.zkey`, the check that ties
  the `.zkey` to the R1CS and to a Powers of Tau file, **cannot be run**: the original
  `.ptau` is not in the repository, and its identity is unknown. It was not run, and no
  claim is made that it would succeed. No candidate Powers of Tau file has been tested
  against this key. If the original file is found, this is the check to run. (That the
  original file is unavailable here does not mean that no public file exists.)

**What this does and does not show.** Consistency among the `.zkey`, the verification
key and the bundled artifact shows that they belong together. It says nothing about
whether the setup was honest: with a single contribution, anyone who kept that
contribution's secret (or the phase 1 secrets) could forge proofs that verify under this
key. Proofs that verify are therefore not evidence of a sound setup.

**To strengthen the evidence.** There are two kinds of work.

*Evidence work* does not replace any cryptographic artifact: finding and identifying
the original Powers of Tau file; recording its source and SHA-256; recording the setup
commands and `snarkjs` version where evidence for them exists; and running
`snarkjs zkey verify` once the R1CS and the original `.ptau` are both available. If the
original inputs or records cannot be found, this work cannot reconstruct the original
setup, and the gaps above remain.

*A new setup* (a fresh `.zkey` from the committed R1CS, using a named public Powers of
Tau file and scripted commands) would replace the `.zkey`, the verification key, the
bundled artifact and every resource derived from them. It needs its own approved task
and must be followed by the consistency checks and regression tests above. More
contributions help only if, in each phase, at least one contributor was honest, kept
their secret private and then destroyed it; the number of contributions guarantees
nothing by itself. A final public beacon adds unpredictability that nobody can choose,
but it is not a substitute for an honest contribution. For anything beyond a demo, use a
real multi-party ceremony.

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
├── package-xcframework.sh        # Headerless XCFramework + refresh of the Swift package inputs
├── check-bindings.sh             # Committed generated sources == fresh generation
├── prepare-ios-app-resources.sh  # Copy/verify the demo app's resources
├── swift-sdk-test.sh             # macOS tests for the LaniakeaKit Swift API
├── swift-app-logic-test.sh       # macOS logic tests for the demo app
└── run-ios-sim-app.sh            # Scripted simulator build/run harness

Package.swift                     # Swift package (local): LaniakeaKit over generated _LaniakeaBindings
swift/LaniakeaKit/                # the handwritten Swift API (Sources/LaniakeaKit), the committed
│                                 # generated sources (_LaniakeaBindings, laniakeaFFI) and tests

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
**Status: IN PROGRESS** — host-side hardening done; all device work is **blocked**
(no physical iPhone is paired and no code-signing identity is configured). Nothing has
run on a physical device, and nothing has been measured on one.

Completed and committed:
- [x] Remove the unused `ethers-core` dependency from the iOS dependency graph (T5.1, `5a026b7`)
- [x] Guard `scripts/build-ios.sh` against forbidden and incomplete iOS dependency graphs (T5.2, `c390da1`)
- [x] Simulator architecture policy: arm64 only, Intel (x86_64) simulators deferred (T5.4, `218e4d9`)
- [x] Packaging and signing documentation; generic demo bundle identifier, no team ID (T5.5, `06bc1ba`)
- [x] Verifying-key consistency test: zkey, bundled artifact, `verification_key.json`, snarkjs export (T4.1, `9e1c92f`)
- [x] Tests pinning the age_check circuit's actual behavior (T4.2, `276e610`)

Done, without a commit:
- [x] Clean-checkout reproducibility (T5.3): a fresh clone of `c390da1` passed the
  documented Rust, Swift-logic, packaging and Xcode build steps (simulator and unsigned
  device builds) on 2026-10-27. No repository change was needed; the run's logs are not
  committed.

Written, not yet committed (in the working tree when this list was updated):
- [ ] Trusted-setup provenance documentation (T4.4; see *Trusted Setup Provenance*)
- [ ] Security model: proving, verifying and deciding (T3.1; see *Security Model*)

Pending (host-side, not started):
- [ ] Thread-stack headroom and a guard against `panic = "abort"` (T6.1, T6.2)
- [ ] Pin `uniffi` exactly and consider an FFI snapshot (T6.5)
- [ ] Review the proof RNG (T3.3) and decide whether to expose on-device verification (T3.4)
- [ ] Proving-time breakdown, host benchmark and benchmark circuit (T2.1–T2.3)
- [ ] Binary-size measurement (T2.5)

Blocked on a paired device and a signing identity:
- [ ] Signed device build and device correctness runs (T1.1–T1.3)
- [ ] Malformed inputs, lifecycle, leaks and memory footprint on device (T4.3, T6.3, T6.4)
- [ ] Export proofs generated on device and verify them independently (T3.2)
- [ ] Device benchmarks: proving time, memory, battery/thermal (T2.4)
- [ ] Release archive and App Store validation (T5.6)

Closing documentation for the phase (T7.1) is pending.

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
scripts/swift-sdk-test.sh
scripts/swift-app-logic-test.sh
scripts/package-xcframework.sh

# Verifying-key consistency (zkey = bundled artifact = verification_key.json = snarkjs export)
REQUIRE_SNARKJS=1 scripts/check-vk-consistency.sh

# Pins the age_check circuit's actual behavior (no `out == 1` constraint, no 8-bit range check)
REQUIRE_SNARKJS=1 scripts/check-circuit-behavior.sh

# Format
cargo fmt --all
```

## License

MIT OR Apache-2.0
