# LaniakeaKit consumer example

A small SwiftUI app that uses LaniakeaKit the way another developer would. It contains only
`import LaniakeaKit` (no generated bindings, no Rust), and its Xcode project depends on Laniakea
**as a remote Swift package**: repository URL plus a version rule (`from 0.1.0`), exactly what
*Add Package Dependencies…* writes. It is a reference integration, not a production app
(`docs/INTEGRATION.md` is the guide).

The app loads `age_check.artifact` and `age_check.wasm` from its bundle (`Circuit(name:)`), builds a
`Prover` once, proves `age >= 18` for the age you type, and shows the public signals, the load and
proving time, process memory, and any error. Invalid input and proving errors are shown as
messages. It says that **proof validity** (not checked here) and **eligibility** (the public signal
`out`) are separate questions.

## Circuit files

The SDK ships no circuit; an app brings its own (`docs/INTEGRATION.md`). `LaniakeaConsumer/Resources/`
is git-ignored. Supply your own compatible pair (the app expects the `age`/`threshold` inputs and two
public signals), or copy the repository's development example for local testing only:

```sh
examples/ios-consumer/prepare.sh <circuit.artifact> <circuit.wasm>
examples/ios-consumer/prepare.sh        # local testing only: the repository's age_check development files
```

## Build and run

**Once a version is published**, open `LaniakeaConsumer.xcodeproj` in Xcode, add the circuit files
(above), choose a simulator or your device (set your own signing team; none is committed) and run.
Xcode downloads the package and the prebuilt libraries; nothing else is needed.

**Before that**, no version exists to resolve, so point the project at this checkout. That needs a
Rust toolchain and builds the libraries yourself:

```sh
scripts/package-xcframework.sh                     # builds Binaries/LaniakeaRustLib.xcframework
examples/ios-consumer/package-source.sh local      # the package comes from ../.. (do not commit this)
examples/ios-consumer/prepare.sh
open examples/ios-consumer/LaniakeaConsumer.xcodeproj
examples/ios-consumer/package-source.sh remote     # restore the committed form
```

The app targets iOS 16 (SwiftUI); the package declares iOS 15.0 and needs Xcode 16.0 or later (only
Xcode 27.1 has been tested).

## Validating as a remote consumer (no Rust, no repository checkout)

`scripts/release/validate-consumer.sh` copies this project to a temporary directory outside the
repository, points it at a package URL and exact version, and builds with fresh caches and no Rust on
`PATH`, runs the proofs on a simulator, verifies them with snarkjs and checks that tampered public
signals are rejected. `--rehearse <version>` uses a local git repository and a local ZIP; with
`ASSET_URL_BASE=https://localhost:8443` (and `scripts/release/serve-asset-https.sh`) SwiftPM also
downloads the ZIP over HTTPS and checks its checksum; `--remote <https URL> <version>` is the real
thing. See the "Releasing" section of the root `README.md`.

## On a physical iPhone

`run-on-device.sh <device> ` builds, installs, runs the app for ages 25 and 10, copies back the
proofs and the log (proving time, memory) and verifies them with snarkjs. It needs your
`DEVELOPMENT_TEAM`, an unlocked connected device in Developer Mode, and has **not been run yet**.

## Export and verify

"Export proof.json and public.json" writes to the app's Documents directory. Verify independently:

```sh
snarkjs groth16 verify circuits/age_check/verification_key.json public.json proof.json
```

Debug builds also accept `-ConsumerAutoAge 25 -ConsumerAutoExport 1` (launch arguments); the
outcome, with timings and memory, is written to `Documents/consumer.log`.
