# 🌌💫 Laniakea

On-device zero-knowledge proving for iOS. Laniakea generates **Groth16 proofs (BN254) for Circom circuits
entirely on the iPhone**: witness generation and proving run locally, no server is needed, and private inputs
never leave the device. The Rust prover uses the Wasmi interpreter (no JIT, no Wasmer on iOS) and is exposed to
Swift as the package `LaniakeaKit`.

> **Status: early and unaudited.** Releases are published on the
> [GitHub releases page](https://github.com/uttkarzsh/laniakea/releases), starting with the pre-release
> `0.1.0-rc.1`. Testing so far is on the iOS Simulator; physical-device results are tracked in
> `docs/INTEGRATION.md`. The only circuit here, `age_check`, is a development example, not production material.

## Features

- Circom circuits, Groth16 over BN254; proofs verify with snarkjs.
- Small Swift API: `Circuit`, `Prover` (an actor), `Proof`, `Input`, `LaniakeaError`, and `Verifier` (an actor) for
  on-device verification against a snarkjs `verification_key.json`.
- Distributed as a Swift package with a prebuilt XCFramework: no Rust, Cargo or UniFFI on the app side.
- Versioned `.artifact` proving-key format (`docs/ARTIFACT_FORMAT.md`).
- Circuit-independent: your app bundles its own `<name>.artifact` and `<name>.wasm`.

**Platforms:** iOS 15.0 or later (declared; tested only on iOS 27.x simulators), `arm64` device and `arm64`
simulator. Needs Xcode 16.0 or later (Swift tools 6.0; tested only with Xcode 27.1). No Intel simulator.

## Install

Xcode: *File ▸ Add Package Dependencies…* with `https://github.com/uttkarzsh/laniakea.git`, then add the
**LaniakeaKit** product. Pick a version from the releases page: pre-releases (such as `0.1.0-rc.1`) need an
exact version; stable releases can use *Up to Next Major*. In `Package.swift`:

```swift
.package(url: "https://github.com/uttkarzsh/laniakea.git", exact: "0.1.0-rc.1")   // or from: "0.1.0"
```

## Use

Add your circuit's `my_circuit.artifact` and `my_circuit.wasm` to the app target, then:

```swift
import LaniakeaKit

let circuit = try Circuit(name: "my_circuit")            // reads both files from the app bundle
let prover = try await Prover(circuit: circuit)          // once; reuse it
let proof = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])

proof.publicSignals     // ["1", "18"]: read these; a valid proof can still say "false"
proof.proofJSON         // snarkjs proof.json
try proof.write(to: directory)   // proof.json + public.json, for an independent verifier
```

Verify on the device with the circuit's snarkjs verification key, or with any Groth16 verifier
(`snarkjs groth16 verify verification_key.json public.json proof.json`):

```swift
let verifier = try Verifier(verificationKeyAt: keyURL)   // a key you chose, not one sent with the proof
let valid = try await verifier.verify(proof)              // true, false, or throws VerificationError
```

**Full guide** (installation details, circuit files, errors, verification, limitations, the example circuit's
caveats): [`docs/INTEGRATION.md`](docs/INTEGRATION.md). A complete SwiftUI app doing this:
[`examples/ios-consumer`](examples/ios-consumer) (and a larger demo in `examples/ios-age-app`).

## How it works

```
SwiftUI app → LaniakeaKit (Swift) → UniFFI bindings → laniakea-core (Rust)
                                         Circom WASM + inputs ─▶ Wasmi witness ─┐
                          .artifact (proving key + matrices) ─▶ CircomReduction ─┴▶ Groth16 prover ▶ proof
```

The `.artifact` is made once from the circuit's `.zkey` on a desktop with the Rust tool
(`cargo run -p laniakea-cli --bin export_artifact -- circuit_final.zkey circuit.artifact`); the iOS code only
reads artifacts. `ark-circom` and Wasmer are used on desktop for that export and as test references, never in
the iOS build.

## Repository layout

```
crates/            laniakea-core (prover), laniakea-uniffi (FFI), wasmi-witness, laniakea-cli, uniffi-bindgen
vendor/ark-circom  modified copy of ark-circom (desktop only)
swift/LaniakeaKit  Swift API (Sources/LaniakeaKit), committed generated bindings, tests
Package.swift      the Swift package (LaniakeaKit over a binary XCFramework of the Rust libraries)
circuits/          age_check development example; witness_probe and reference data for tests
examples/          ios-consumer (remote-package reference app), ios-age-app (demo)
scripts/           build, test and release scripts
docs/              INTEGRATION.md, ARTIFACT_FORMAT.md, third-party-upstream/ (licence texts)
```

## Develop

Needs Rust (with `aarch64-apple-ios` and `aarch64-apple-ios-sim`), full Xcode, and `snarkjs` for the independent checks.

```sh
cargo fmt --all --check
cargo test --locked --offline --workspace --exclude ark-circom
scripts/package-xcframework.sh          # builds Binaries/LaniakeaRustLib.xcframework (git-ignored) and checks the bindings
scripts/check-bindings.sh               # committed generated Swift/C == a fresh generation
scripts/prepare-ios-app-resources.sh --check
REQUIRE_SNARKJS=1 scripts/check-vk-consistency.sh
REQUIRE_SNARKJS=1 scripts/check-circuit-behavior.sh
REQUIRE_SNARKJS=1 scripts/swift-sdk-test.sh
REQUIRE_SNARKJS=1 scripts/swift-app-logic-test.sh
scripts/run-ios-sim-app.sh              # demo app on a booted simulator
```

On development branches the package's binary target is the local `Binaries/` directory, so work on the SDK and
the example against a checkout with `examples/ios-consumer/package-source.sh local` (and `remote` to restore).
Re-run `package-xcframework.sh` after changing Rust code. After editing `Cargo.lock`, regenerate the notices with
`scripts/release/third-party-notices.py --write`.

## Releasing (manual; nothing has been published)

`Package.swift` has two forms that differ in one line, the `LaniakeaRustLib` binary target: a local path on
every development commit, and a `url:` plus `checksum:` only in the release commit a version tag points at
(`scripts/release/set-binary-target.sh --local | --remote --version V --url URL --checksum SHA`). Only tagged
versions are consumable; a `branch:` dependency gets the local form and cannot resolve.

1. On a clean commit: `scripts/release/prerelease-check.sh <V>` runs the tests above, builds the asset
   (`scripts/release/build-asset.sh <V>`: deterministic ZIP, checksum, validation of the archive and of the
   bindings against it, `LICENSE*` and `THIRD_PARTY_NOTICES*` files from the repository root included) and runs an
   offline consumer rehearsal (`scripts/release/validate-consumer.sh --rehearse <V>`).
2. HTTPS check (SwiftPM requires HTTPS for binary targets): `scripts/release/serve-asset-https.sh <V>` serves the
   ZIP with a throwaway CA that you trust yourself for the test (it prints the commands); then
   `ASSET_URL_BASE=https://localhost:8443 scripts/release/validate-consumer.sh --rehearse <V>`. Setting
   `ASSET_CHECKSUM` to a wrong value must fail at package resolution. Remove the CA afterwards.
3. Create the GitHub release for tag `<V>` and upload `dist/<V>/LaniakeaRustLib-<V>.xcframework.zip`.
4. Make the release commit with `set-binary-target.sh --remote …` using the checksum in `RELEASE-INFO.txt`, tag it
   (`<V>`, annotated), push, and run `validate-consumer.sh --remote <repo URL> <V>`.
5. Switch the development branch back with `set-binary-target.sh --local`. Never replace an uploaded asset;
   publish a new version instead.

Physical device: `DEVELOPMENT_TEAM=<id> examples/ios-consumer/run-on-device.sh "<device>"` (never run yet).

## License

Laniakea's original code is licensed under the **MIT License** ([`LICENSE`](LICENSE), copyright (c) 2026 Uttkarsh).
MIT applies only to that original code. Third-party code keeps its own licences, including the portable
`CircomReduction` (`crates/laniakea-core/src/backend/circom_reduction.rs`), which is adapted from `ark-circom` and
retains its upstream MIT notice (Laniakea does not claim authorship of it). See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), which also records the vendored `ark-circom`, UniFFI (MPL-2.0), the
example circuit's GPL-3.0 circomlib dependency, and the open question about the licence of UniFFI-generated code.
