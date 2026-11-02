# LaniakeaKit consumer example

A small SwiftUI app that uses LaniakeaKit the way another developer would. It contains only
`import LaniakeaKit` (no generated bindings, no Rust), and its Xcode project depends on Laniakea
**as a remote Swift package**: repository URL plus a version rule (`from 0.1.0`), exactly what
*Add Package Dependencies…* writes. It is a reference integration, not a production app
(`docs/INTEGRATION.md` is the guide).

The app loads `age_check.artifact` and `age_check.wasm` from its bundle (`Circuit(name:)`), builds a
`Prover` once, proves `age >= 18` for the age you type, and shows the public signals, the load and
proving time, process memory, and any error. Invalid input and proving errors are shown as
messages. *Verify on this device* checks the proof with `Verifier` against the
`verification_key.json` bundled with the app (and, as a control, shows that the same proof with `out`
changed is rejected); without a bundled key the app still proves and the button is off. It says that
**proof validity** and **eligibility** (the public signal `out`) are separate questions, and that
verifying on the proving device convinces no one else.

## Circuit files

The SDK ships no circuit; an app brings its own (`docs/INTEGRATION.md`). `prepare.sh` copies the files
into `LaniakeaConsumer/Resources/`, which is git-ignored: the circuit's `.artifact` and `.wasm`, and
optionally its snarkjs `verification_key.json` (without it the app proves but does not verify; passing
only two files removes a key left from an earlier run). Supply your own compatible files (the app
expects the `age`/`threshold` inputs and two public signals), or copy the repository's development
example (all three files) for local testing only:

```sh
examples/ios-consumer/prepare.sh <circuit.artifact> <circuit.wasm> [<verification_key.json>]
examples/ios-consumer/prepare.sh        # local testing only: the repository's age_check development files
```

## Build and run

**From GitHub.** The committed rule, *Up to Next Major from 0.1.0*, is for stable releases; the only
published versions so far are pre-releases, which that rule does not select. Pin the newest,
`0.1.0-rc.2` (the app uses `Verifier`, which `0.1.0-rc.1` lacks), first (do not commit the result):

```sh
examples/ios-consumer/package-source.sh remote --exact 0.1.0-rc.2
```

Then open `LaniakeaConsumer.xcodeproj` in Xcode, add the circuit files (above), choose a simulator or
your device (set your own signing team; none is committed) and run. Xcode downloads the package and
the prebuilt libraries; nothing else is needed. Restore the committed rule with
`package-source.sh remote`.

**From this checkout** (to work on the SDK, or to use code newer than the latest release), point the
project at the repository. That needs a Rust toolchain and builds the libraries yourself:

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
`PATH`, runs the proofs on a simulator, verifies them inside the app with `Verifier` and outside with
snarkjs, and checks that tampered public signals are rejected. `--rehearse <version>` uses a local git repository and a local ZIP; with
`ASSET_URL_BASE=https://localhost:8443` (and `scripts/release/serve-asset-https.sh`) SwiftPM also
downloads the ZIP over HTTPS and checks its checksum; `--remote <https URL> <version>` is the real
thing. See the "Releasing" section of the root `README.md`.

## On a physical iPhone

`run-on-device.sh <device> ` builds, installs, runs the app for ages 25 and 10, copies back the
proofs and the log (proving time, memory, the on-device `Verifier` result) and verifies them with snarkjs. It needs your
`DEVELOPMENT_TEAM`, an unlocked connected device in Developer Mode, and the app's developer profile trusted
on the device (*Settings ▸ General ▸ VPN & Device Management*; until then iOS refuses to launch it). It has
been run on an iPhone 16 with iOS 26.6.2 (results in `docs/INTEGRATION.md`).

## Export and verify

"Export proof.json and public.json" writes to the app's Documents directory. Verify independently:

```sh
snarkjs groth16 verify circuits/age_check/verification_key.json public.json proof.json
```

Debug builds also accept `-ConsumerAutoAge 25 -ConsumerAutoExport 1` (launch arguments); the
outcome, with timings, memory and the on-device verification result, is written to
`Documents/consumer.log`.
