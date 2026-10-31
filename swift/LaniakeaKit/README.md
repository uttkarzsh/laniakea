# LaniakeaKit

The Swift API over the Rust prover and verifier: `Circuit`, `Prover`, `Proof`, `Input`,
`LaniakeaError`, `Verifier`, `VerificationError` (`Sources/LaniakeaKit`, handwritten, checked in), on top of the
UniFFI-generated binding and the Rust static library. How to add it to an app: `docs/INTEGRATION.md`. Not published yet: for now the package
is assembled locally (below). Circuit files stay outside the SDK binary.

```swift
import LaniakeaKit

let circuit = try Circuit(name: "age_check")                  // age_check.artifact + .wasm in the bundle
// or: try Circuit(artifactURL: artifactURL, wasmURL: wasmURL)
let prover = try await Prover(circuit: circuit)               // validates the artifact, compiles the WASM
let proof = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])

proof.publicSignals            // ["1", "18"]: read these; a valid proof can have out = 0
proof.proofJSON                // snarkjs proof.json
try proof.write(to: directory) // proof.json + public.json, for an independent verifier
```

- **Verification is not done here.** `prove` generates; check with
  `snarkjs groth16 verify verification_key.json public.json proof.json` (or any Groth16
  verifier). A valid proof is not the application's answer: read the public signals.
- **Threading.** `Prover` is an actor, but actor isolation alone does not give a dedicated
  thread: building it and proving are synchronous Rust calls that run on a thread of
  Swift's cooperative pool, never on the main thread, and hold that thread until they
  finish.
  - Calls on one `Prover` are serialized; queued calls hold no thread.
  - Several active `Prover`s add CPU, memory and scheduling pressure, and each running
    proof takes a cooperative-pool thread from other Swift-concurrency work. Do not launch
    large numbers of concurrent proofs.
  - Cancellation is checked when the actor starts handling a `prove` call (including one
    that was queued): a cancelled task gets `CancellationError`. A proof already executing
    cannot be interrupted and returns its result.
  - No `@unchecked Sendable` and no custom executor is used.
- **Network and privacy.** The SDK itself makes no network calls. What happens to a proof
  or to anything derived from the inputs, including exporting or sending it, is up to the
  integrating app.
- **Export.** `Proof.write(to:)` replaces existing `proof.json`/`public.json`, stages both
  files first and moves them into place, and restores the first one if the second move
  fails. The two-file export is **not atomic** and nothing is explicitly flushed to disk:
  a crash between the two moves can leave a new file beside an old one. If restoring the
  first file also fails, `exportFailed` says so in its reason, and the previous
  `proof.json` is kept as a hidden `.proof.json.<id>.bak` file whose path the reason
  gives; recover it from there. A mismatched pair can fail verification, but if both
  proofs have identical public signals it still verifies, as a valid proof of that
  statement. Do not export concurrently into the same directory.
- **Inputs.** `[String: Input]`: `.integer(Int)`, `.decimal(String)` for values above
  `Int.max`, `.integers`/`.decimals` for array signals. Values are checked once, by the
  prover: a non-canonical decimal, a negative number or a value at or above the BN254
  scalar modulus is `LaniakeaError.invalidInputValue(signal:index:value:)`.
- **Errors.** Everything thrown is a `LaniakeaError` (a `LocalizedError`; `debugDescription`
  has the details), mapped case by case from the Rust `ProverError`. `.outOfMemory` is the
  circuit's WASM failing to get memory while computing the witness; if the whole process
  runs out of memory, the system terminates the app and no error can be thrown, so the
  case cannot promise to catch every out-of-memory situation.
- **`age_check` is a development example, not production material.** The bundled artifact
  comes from a development trusted setup (one contribution, no ceremony records), and the
  circuit has known limitations (it does not constrain `out == 1` and does not range-check
  its inputs). Do not ship it for real use. See *Security Model: Proving, Verifying, and
  Deciding* and *Trusted Setup Provenance (age_check)* in the repository README.
- **Artifact files are versioned.** An `.artifact` starts with a header (magic and format
  version, `docs/ARTIFACT_FORMAT.md`). A file from a newer format is
  `.unsupportedArtifactVersion(found:supported:)`; a missing header (an artifact from before
  format 1: re-export it with `export_artifact`), truncation, trailing bytes or a malformed
  payload are `.invalidArtifact`. This is not an integrity check.
- **You own the circuit.** The SDK is circuit-independent and ships none: the circuit's source, trusted setup, verification
  key, licensing and the meaning of its public signals are the app developer's responsibility (`docs/INTEGRATION.md`). Making the
  `.artifact` from the circuit's `.zkey` needs the repository's Rust CLI on a development machine (`docs/INTEGRATION.md`).
- **Licensing.** MIT for the original code (`LICENSE`); third-party attributions and open questions in `THIRD_PARTY_NOTICES.md`.
- **A `Circuit` is only two blobs.** The artifact carries no circuit identity, so a WASM
  from another circuit is not always detected. Keep the pair from one build.
- **Tests:** `scripts/swift-sdk-test.sh` (macOS host; `REQUIRE_SNARKJS=1` to require the
  independent snarkjs check of the exported files).

## Package layout

The Swift package is the repository's root `Package.swift`. On development branches its
binary target is local (`Binaries/LaniakeaRustLib.xcframework`, built by you); only a tagged
release commit carries a remote `url:`/`checksum:` binary target, and **nothing is published
yet** (see the "Releasing" section of the root `README.md` for the release workflow, the manifest switching and what has
and has not been tested). Product `LaniakeaKit`; targets:

```
LaniakeaKit (Swift, handwritten)  -> internal import _LaniakeaBindings
  _LaniakeaBindings (Swift, UniFFI-generated, committed)
    laniakeaFFI (C: the generated header; SwiftPM derives the module map)
    LaniakeaRustLib (binary: Binaries/LaniakeaRustLib.xcframework, built locally, git-ignored)
```

```
scripts/package-xcframework.sh      # needs full Xcode: builds the libraries and the XCFramework,
                                    # refreshes the committed generated sources, installs Binaries/
scripts/check-bindings.sh           # committed generated sources == a fresh generation
```

- **The XCFramework is headerless on purpose.** Xcode copies every XCFramework's headers
  and `module.modulemap` into one shared `include/` directory; two packages that ship them
  collide ("Multiple commands produce include/module.modulemap"; reproduced with a
  throwaway two-package test). The header lives in the C target instead. That C target
  contains an intentionally empty `laniakeaFFI.c`: without a translation unit the app link
  step fails ("Build input file cannot be found: laniakeaFFI.o").
- **`_LaniakeaBindings` is an implementation detail, not API.** It is not a product and
  `LaniakeaKit` imports it with `internal import`, so no `LaniakeaKit` declaration exposes
  a generated type. SwiftPM cannot make it unimportable: a probe app that does
  `import _LaniakeaBindings` and names `ProverError` **builds** (tested). The underscore
  marks it as private; do not depend on it.
- **Minimum toolchain: Swift 6.0, i.e. Xcode 16.0 or later.** The manifest declares
  `swift-tools-version:6.0`, which needs a Swift 6.0 toolchain (Xcode 16.0 is the first
  Xcode that ships one), and `LaniakeaKit` uses `internal import` (SE-0409, Swift 6.0). This
  comes from those toolchain requirements; only Xcode 27.1 (Swift 6.4) has been used here,
  so Xcode 16.x has not been tested.
- **Swift 5 language mode** (`swiftLanguageModes: [.v5]`): the code UniFFI 0.28.3
  generates does not type-check in Swift 6 mode. Do not upgrade the mode without
  upgrading UniFFI and re-verifying.
- **Minimum iOS: 15.0 declared** (the manifest, and `IPHONEOS_DEPLOYMENT_TARGET`, default
  15.0, which `build-ios.sh` verifies per archive member; `package-xcframework.sh` refuses
  to run if the manifest disagrees). 15.0 is the lowest the iOS 27.1 SDK accepts for the
  Swift targets. **Declared is not validated:** the oldest iOS this has been run on is the
  iOS 27.x simulator (and, per the maintainer, one physical iPhone 16 for the earlier
  package layout). Nothing from 15 to 26 has been run.
- Never edit the generated `laniakea.swift` or `laniakeaFFI.h`; regenerate them.
- Built and consumed by Xcode: `examples/ios-age-app` and `examples/ios-consumer` use the
  root package as a local dependency; `scripts/run-ios-sim-app.sh` compiles the same
  sources with swiftc. Not exercised: a standalone `swift build`, a remote resolve, and any
  run on a physical device with this layout.
