# LaniakeaKit

The Swift API over the Rust prover: `Circuit`, `Prover`, `Proof`, `Input`,
`LaniakeaError` (`Sources/LaniakeaKit`, handwritten, checked in), on top of the
UniFFI-generated binding and the Rust static library. Not published: for now the package
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
- **A `Circuit` is only two blobs.** The artifact carries no circuit identity, so a WASM
  from another circuit is not always detected. Keep the pair from one build.
- **Tests:** `scripts/swift-sdk-test.sh` (macOS host; `REQUIRE_SNARKJS=1` to require the
  independent snarkjs check of the exported files).

## Package assembly

`Package.swift.template` is the manifest for the package that wraps the Rust prover.
The package itself is **assembled**, not checked in, because it contains generated
files:

```
scripts/package-xcframework.sh      # needs full Xcode
# -> <cargo target dir>/uniffi/ios-<min>/LaniakeaKit/   (<min> = IPHONEOS_DEPLOYMENT_TARGET)
```

Requirements and caveats

- **Swift 5 language mode** (`swiftLanguageVersions: [.v5]`): the code UniFFI 0.28.3
  generates does not type-check in Swift 6 mode. Do not upgrade the mode without
  upgrading UniFFI and re-verifying.
- Minimum iOS: `IPHONEOS_DEPLOYMENT_TARGET` (default 14.0), substituted for the
  `@IOS_MIN@` placeholder when the package is assembled. Libraries for each
  deployment target are built in their own Cargo target directory (`<target>/ios-<min>`).
- The binary target and the XCFramework are both named `laniakeaFFI`; the module the
  generated Swift imports (`import laniakeaFFI`) is defined by the `module.modulemap`
  inside the XCFramework.
- Never edit the generated `laniakea.swift`; regenerate it.
- Built and consumed by Xcode: `examples/ios-age-app` links the generated package as a
  local dependency (`target/uniffi/ios-14.0/LaniakeaKit`), and the Debug simulator,
  Release simulator and unsigned Release device builds of the demo succeed with it.
  Not exercised: a standalone `swift build` of the package, and any run on a physical
  device.

What is checked in and what is generated

- Checked in: this directory's `Package.swift.template`, `Sources/LaniakeaKit` (the Swift
  API), `Tests-macOS` and this README.
- Generated by `scripts/package-xcframework.sh` under `<cargo target dir>/uniffi/ios-<min>/`
  (git-ignored, because `target/` is): `laniakeaFFI.xcframework` (slices `ios-arm64` and
  `ios-arm64-simulator`), and `LaniakeaKit/` containing `Package.swift` (from the
  template), `Sources/Laniakea/laniakea.swift` (generated), `Sources/LaniakeaKit` (copied
  from this directory) and a copy of the XCFramework. The product `LaniakeaKit` is the
  `LaniakeaKit` target, which depends on the generated `Laniakea` target.
- The script first runs `scripts/build-ios.sh`, which builds the Rust static libraries,
  runs its checks (dependency guard, archive inspection, binding consistency) and stages
  them, then `xcodebuild -create-xcframework` and the package assembly.
- The Xcode project references the package by the relative path
  `../../../target/uniffi/ios-14.0/LaniakeaKit`, so it exists only after the script has
  run. See `examples/ios-age-app/README.md` for prerequisites and the full procedure.
