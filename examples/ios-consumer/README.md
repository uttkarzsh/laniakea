# LaniakeaKit consumer example

A minimal SwiftUI app that uses LaniakeaKit the way another developer would: it contains
`import LaniakeaKit` only (no generated bindings, no Rust) and its Xcode project depends on
one local Swift package, the repository root (`Package.swift`). It is a boundary test, not a
second demo (see `../ios-age-app`), and not production material.

The app loads `age_check.artifact` and `age_check.wasm` from its bundle (`Circuit(name:)`),
builds a `Prover`, proves `age >= 18` for the age you type, and shows the public signals and
errors. It states that **proof validity** (not checked here; a verifier must do it) and
**eligibility** (the public signal `out`; a valid proof also exists when `out = 0`) are
separate questions. File reads happen in a detached task and `Prover` runs its synchronous
Rust work on the cooperative pool, not on the main thread (see the `Prover` documentation).

## Circuit files

Nothing is committed here: `LaniakeaConsumer/Resources/` is git-ignored and the licensing of
the repository's development `age_check` files has not been cleared for redistribution. Supply
your own compatible pair (the app expects the `age`/`threshold` inputs and two public signals):

```sh
examples/ios-consumer/prepare.sh <circuit.artifact> <circuit.wasm>
examples/ios-consumer/prepare.sh        # local testing only: copies the repository's development files
```

## Build and run

Needs full Xcode, a Rust toolchain with the iOS targets (`aarch64-apple-ios`,
`aarch64-apple-ios-sim`), and `snarkjs` for the check below.

```sh
scripts/package-xcframework.sh          # builds Binaries/LaniakeaRustLib.xcframework
examples/ios-consumer/prepare.sh        # circuit files, see above
open examples/ios-consumer/LaniakeaConsumer.xcodeproj
```

Choose an iOS Simulator and run. For a device set your own signing team in Xcode (none is
committed). The app targets iOS 16 (SwiftUI); the package declares iOS 15.0 and needs Swift tools 6.0
(Xcode 16.0 or later; only Xcode 27.1 has been tested).

## Validating as a remote consumer

`scripts/release/validate-consumer.sh` copies this project to a temporary directory outside
the repository, makes it depend on the package by repository URL and exact version, and
repeats the builds, the simulator proofs, the snarkjs checks and the tamper check with fresh
caches and no Rust on `PATH`. `--rehearse <version>` is an offline rehearsal with a local
ZIP; `--remote <https URL> <version>` is the real HTTPS test, which has not been run because
nothing is published. See `docs/RELEASING.md`.

## Export and verify

"Export proof.json and public.json" writes to the app's Documents directory. On the
simulator: `xcrun simctl get_app_container <udid> dev.laniakea.LaniakeaConsumer data`, then
`Documents/`. Verify independently:

```sh
snarkjs groth16 verify circuits/age_check/verification_key.json public.json proof.json
```

Debug builds also accept `-ConsumerAutoAge 25 -ConsumerAutoExport 1` (launch arguments); the
outcome is written to `Documents/consumer.log`.
