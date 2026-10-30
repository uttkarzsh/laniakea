# Using Laniakea in your app

Laniakea generates Groth16 (BN254) proofs for Circom circuits on the device. You add one Swift
package, bundle two files for your circuit, and call `Prover`. Your app never builds or touches
Rust.

Versions are published as [GitHub releases](https://github.com/uttkarzsh/laniakea/releases); the first is
the pre-release `0.1.0-rc.1`. See *Tested and not tested* for what has been run where.

## 1. Add the package

Xcode: *File ▸ Add Package Dependencies…*, enter `https://github.com/uttkarzsh/laniakea.git`, choose a
version (for a pre-release such as `0.1.0-rc.1`, the rule *Exact Version*; for stable releases, *Up to Next
Major Version*), and add the **LaniakeaKit** product to your app target.

If your app keeps its code in a local Swift package (a common layout for SwiftUI apps), declare the
dependency there. A feature module that proves with its own circuit files:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgeProof",
    platforms: [.iOS(.v16)],                       // LaniakeaKit needs iOS 15.0 or later
    products: [.library(name: "AgeProof", targets: ["AgeProof"])],
    dependencies: [
        .package(url: "https://github.com/uttkarzsh/laniakea.git", exact: "0.1.0-rc.1"),
        // stable releases: from: "0.1.0"
    ],
    targets: [
        .target(
            name: "AgeProof",
            dependencies: [.product(name: "LaniakeaKit", package: "laniakea")],
            resources: [.copy("Resources/my_circuit.artifact"), .copy("Resources/my_circuit.wasm")]
        ),
    ]
)
```

SwiftPM clones the repository at the version tag and downloads the compiled Rust libraries as a
release asset (a `.binaryTarget` with a URL and checksum). You do not run Cargo, copy an
XCFramework or generate bindings. The clone is the whole repository (about 12 MB of git objects),
but only the library code is built.

Depend on a **version** (`from:`, `exact:`), not on a branch or commit: only the commit a release tag
points at names the downloadable libraries. On branches the manifest points at a local, git-ignored
`Binaries/` directory, so a `branch:` or `revision:` dependency fails to resolve the `LaniakeaRustLib`
binary target. Pre-release versions such as `0.1.0-rc.1` are only picked with `exact:`.

Requirements: Xcode 16.0 or later (the manifest uses `swift-tools-version: 6.0`) and a deployment
target of iOS 15.0 or later, as declared. Device and simulator slices are `arm64` only (no Intel
simulator). The app's Swift language mode can be 5 or 6.

LaniakeaKit includes an Apple privacy manifest (`PrivacyInfo.xcprivacy`, in the `Laniakea_LaniakeaKit.bundle`
it adds to your app): no tracking, no data collected, and one required-reason API, `fstat` (file timestamp
category, reason `C617.1`), which the linked Rust standard library references. Xcode includes it in your app's
privacy report; you do not need to declare it yourself.

## 2. Add your circuit's two files

For each circuit you need `<name>.artifact` and `<name>.wasm`, built together:

- `<name>.wasm` is the witness generator Circom produces (`circom --wasm`).
- `<name>.artifact` is the proving key and constraint matrices in Laniakea's versioned format. Make
  it once, on a development machine, from the circuit's final `.zkey` with the repository's tool
  (this is the only step that needs Rust, and your app does not):

  ```sh
  git clone https://github.com/uttkarzsh/laniakea.git && cd laniakea
  cargo run -p laniakea-cli --bin export_artifact -- my_circuit_final.zkey my_circuit.artifact
  ```

  The format is described in `docs/ARTIFACT_FORMAT.md`. A file made before the format was versioned
  must be exported again.

Where the files go decides which bundle you load them from:

- **In the app target** (dragged into Xcode, listed in *Copy Bundle Resources*): they are in the app
  bundle, and `Circuit(name: "my_circuit")` finds them (it defaults to `Bundle.main`).
- **In a Swift package target** (declared with `resources: [.copy(...)]`, as above): SwiftPM puts them
  in that target's own resource bundle, so load them with `Circuit(name: "my_circuit", bundle: .module)`
  from code in that target. `Bundle.main` will not find them. Use `.copy` so the files are bundled
  unchanged. Keep the pair from
one build: the SDK checks the artifact's structure and its wire count against the WASM, but cannot
tell that a WASM belongs to a different circuit of the same size.

## 3. Prove

```swift
import LaniakeaKit

// Once, off the main thread: reads both files, validates the artifact, compiles the WASM.
let circuit = try Circuit(name: "my_circuit")          // Bundle.main; in a package target add `bundle: .module`
let prover = try await Prover(circuit: circuit)        // keep it; reuse it for every proof

// Per proof. Inputs are named as in the Circom file; values are non-negative decimals below the BN254 modulus.
let proof = try await prover.prove(["age": .integer(25), "threshold": .integer(18)])

proof.publicSignals        // ["1", "18"]: canonical decimal strings, outputs first
proof.proofJSON            // snarkjs-format proof.json
proof.publicSignalsJSON    // snarkjs-format public.json
try proof.write(to: directory)   // proof.json + public.json
```

- **Load once, reuse.** Building a `Prover` is the expensive step; `prove` can then be called
  repeatedly. `Prover` is an `actor`: calls on one prover run one at a time, off the main thread, and
  hold a cooperative-pool thread while they run. Do not start many provers or proofs at once.
- **Inputs.** `.integer(Int)`, `.decimal(String)` for larger values, `.integers([...])` and
  `.decimals([...])` for array signals.
- **Cancellation.** A cancelled task gets `CancellationError` if it has not started proving; a proof
  already running cannot be interrupted.
- **Memory.** Everything is released when the `Prover` is. There is nothing to close.

`examples/ios-consumer` is a complete SwiftUI app doing exactly this, including a progress state, an
error message, and proving time and memory readout (`LaniakeaConsumer/ProofModel.swift`).

## 4. Errors

Everything thrown is a `LaniakeaError` (a `LocalizedError`; `debugDescription` has details):

| Case | Meaning |
|---|---|
| `.fileUnreadable` | a circuit file is missing from the bundle or unreadable |
| `.invalidArtifact`, `.unsupportedArtifactVersion` | damaged artifact, or one in a newer format than this SDK reads: update the SDK or export again |
| `.invalidCircuit` | the WASM is not a usable BN254 Circom circuit |
| `.invalidInputValue`, `.unknownInput`, `.duplicateInput`, `.wrongInputCount`, `.missingInputs` | the inputs do not match the circuit |
| `.circuitRejectedInputs` | the circuit's own `assert` failed: these inputs are outside what it accepts |
| `.outOfMemory` | the circuit's WASM could not get memory (if the whole app runs out of memory, iOS ends it and nothing can be thrown) |
| `.provingFailed`, `.internalFailure` | any other failure |

## 5. Verifying

The SDK generates proofs; it does not verify them. Verify with any Groth16 verifier and your
circuit's `verification_key.json`, for example
`snarkjs groth16 verify verification_key.json public.json proof.json`. A valid proof says the circuit
accepted some private inputs; it does not say your application's condition holds. **Read the public
signals**: for the `age_check` example, a valid proof exists when `out` is `0`, too.

## 6. Your circuit, and what a proof means

You own the circuit: its source, compilation, trusted setup, verification key, licence, and what its
public signals mean. The SDK contains no circuit and checks structure only. A valid proof says the
circuit's constraints held for those public signals; it does not say your application's condition is
true, and nothing here has been audited. A verifier must pin the verification key itself (a key supplied
by the prover proves nothing) and must read the public signals.

### The `age_check` example is a development example

It lives in `circuits/age_check` and is used by the demo apps and tests. The public signals are
`[out, threshold]`; `age` stays private.

- It does **not** require `out == 1`: a valid proof with `out = 0` proves the condition is false, so a
  verifier must require `out == 1` and its expected threshold.
- It does **not** range-check its inputs to 8 bits: with threshold 18 it also accepts ages 256–273
  (pinned by `crates/laniakea-core/tests/age_check_behavior.rs`). The SDK accepts any canonical decimal
  below the field modulus; the demo apps restrict to 0–255, which only constrains the honest app.
- The age is self-asserted, and a proof can be replayed by anyone holding it (no nonce, session or
  verifier input). The proof reveals the comparison result, though not the age.
- Its trusted setup is a **development key**: one contribution named `laniakea dev`, added together with
  the circuit in commit `829842d` with no record of the Powers of Tau file or the commands used.
  `scripts/check-vk-consistency.sh` shows that the `.zkey`, the bundled artifact and
  `verification_key.json` are the same key; it cannot show the setup was honest, and
  `snarkjs zkey verify` cannot be run because the original `.ptau` is unavailable. Anyone who kept that
  contribution's secret could forge proofs that verify. Do not use it for real decisions; use a real
  multi-party ceremony.
- It includes circomlib templates (GPL-3.0). Its licensing is not established; see
  `THIRD_PARTY_NOTICES.md`.

## 7. Tested and not tested

Tested (simulator, Xcode 27.1, iOS 27.x, Apple silicon Mac): proof generation from a separate consumer
app that depends on the package by URL and exact version with no access to the Rust workspace, including
a rehearsal where SwiftPM downloaded the XCFramework from a local HTTPS server and verified its checksum
(and rejected a wrong one); verification of the exported proofs with snarkjs; rejection of tampered
public signals; generic device and simulator builds. Simulator measurement: loading about 0.12 s, one
proof about 0.02 s, about 20 MB memory footprint (not representative of an iPhone).

Not tested: a physical iPhone (`examples/ios-consumer/run-on-device.sh` is written but has never run); a
real HTTPS release (nothing is published); Xcode 16.x; iOS below 27.

Known limits: the libraries are about 27 MB per architecture slice before the linker strips them
(app-size impact unmeasured); the library exports many Rust symbols, so linking it next to another Rust
static library in the same app may collide; making the `.artifact` needs the Rust tool; there is no
on-device verifier; the Intel simulator is not supported; the package is unaudited.
