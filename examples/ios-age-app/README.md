# Age-check iOS demo

A minimal SwiftUI app that generates a Groth16 (BN254) proof on the device for the
`circuits/age_check` Circom circuit, through the Rust prover:

```
SwiftUI (ContentView) → AgeProofViewModel → AgeProofService (actor)
  → import Laniakea (UniFFI bindings, LaniakeaKit package) → Rust LaniakeaProver
  → Wasmi witness generation → Groth16 proof → proof.json + public signals
```

The user enters an age; the threshold is fixed at 18. The age is a private input and
stays on the device. The app makes no network requests.

## What the demo shows, and what it does not

- **Proof generation, not verification.** The FFI exposes no verifier, so the app never
  verifies a proof and never claims to. Results read "Proof generated — eligible.",
  "Proof generated — not eligible." or "Proof generation failed." Verify proofs elsewhere,
  for example with snarkjs and `circuits/age_check/verification_key.json` (the logic
  test does this).
- **Eligibility comes from the public signals.** age_check's public signals are
  `[out, threshold]`, with `out = 1` when `age >= threshold` and `out = 0` otherwise. The
  circuit does **not** constrain `out == 1`, so a valid proof exists for an ineligible
  age too. `AgeProofService.classify` accepts exactly `["1", "18"]` (eligible) and
  `["0", "18"]` (not eligible), and rejects any other count, threshold or `out`.
- **The 0–255 range is enforced by the app, not by the circuit.** circomlib's
  `GreaterEqThan(8)` is only meaningful for inputs below 2^8 and does not check that.
  With threshold 18 the circuit proves every age from 0 to 273 (256–273 with `out = 1`),
  fails an assertion from 274 on, and proves a field element near the modulus (a
  "negative" age) with `out = 0`. The logic test records this behaviour. The app rejects
  empty, non-numeric, negative and out-of-range input before calling Rust.
- The age is self-asserted and proofs are replayable; see the root README's *Security
  Model* section for what a proof does and does not establish.
- Nothing here is audited, and simulator results say nothing about device performance.

## Layout

```
AgeCheckApp/
  AgeCheckApp.swift           @main; LaunchOptions (debug-only automation hook)
  ContentView.swift           the screen
  AgeProofViewModel.swift     ObservableObject state; loading and proving off the main actor
  AgeProofService.swift       actor owning the prover; input parsing; signal classification
  ProverError+Message.swift   user-facing text for every ProverError case
  Resources/
    age_check.wasm            copy of circuits/age_check/age_check_js/age_check.wasm
    age_check.artifact        ProvingArtifact exported from age_check_final.zkey
Tests-macOS/
  ServiceTests.swift          logic tests, run on the Mac host
```

### Concurrency

`LaniakeaProver` (generated) is a non-`Sendable` class. `AgeProofService` is an
**actor** that creates the prover inside itself and never hands it out, so no
`@unchecked Sendable` is needed. Every call into Rust happens on the actor's executor,
one at a time. A `dispatchPrecondition` asserts it is not the main queue.

- **Loading.** Reading the resources, validating the artifact and compiling the WASM all
  run in a detached task.
- **Proving.** The view model awaits the actor, so the main actor stays free. The Rust
  call itself cannot yield, so it occupies one cooperative-pool thread for the proof's
  duration. Pinning it to a dedicated thread would need a custom actor executor (iOS 17+).
- **Duplicate submissions.** These are ignored while loading or proving. A failed attempt
  leaves the prover usable.

**Verified configurations:**

- **The Xcode project** (section 5) uses these settings:
  - **Settings:** Swift 5 language mode (`SWIFT_VERSION = 5.0`), MainActor default
    isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), and Approachable Concurrency
    (`SWIFT_APPROACHABLE_CONCURRENCY = YES`).
  - **Upcoming features** Xcode passes with these settings:
    - `NonisolatedNonsendingByDefault`
    - `InferIsolatedConformances`
    - `InferSendableFromCaptures`
    - `DisableOutwardActorInference`
    - `GlobalActorIsolatedTypesUsability`
    - `MemberImportVisibility`
  - **Evidence:**
    - The app builds with these settings (section 5).
    - A small standalone program, compiled with the same flags and using the same pattern
      (a detached loading task that constructs an actor, then an actor method call), ran
      the detached task, the actor initializer and the actor method off the main thread.
      That program is a reduced reproduction, not the app itself.
- **The scripts** `scripts/swift-app-logic-test.sh` and `scripts/run-ios-sim-app.sh`
  type-check the app sources with warnings as errors in three other configurations:
  - Swift 5 with complete concurrency checking
  - Swift 6
  - Swift 6 with MainActor default isolation

Other combinations of language mode and concurrency settings have not been tested.

## Prerequisites

Required:
- macOS on Apple silicon, Xcode 27.1 (iOS 27.1 simulator runtime), Swift 6.4 toolchain.
  Full Xcode is needed for `xcodebuild` (the XCFramework and the app builds). The
  scripts also call `nm`, `ar`, `otool`, `lipo`, `cmp`, `shasum` and `swiftc`, which
  Xcode and its command-line tools provide.
- Rust with `cargo` and the targets `aarch64-apple-ios` and `aarch64-apple-ios-sim`
  (`rustup target add ...`).
- `python3`. It is used to read Cargo's target directory (`cargo metadata`, in
  `scripts/lib/common.sh` and `scripts/gen-swift-bindings.sh`, so every script needs it)
  and, in `scripts/build-ios.sh`, to check where Cargo wrote its build artifacts. No
  Python packages are needed.

Optional:
- `snarkjs` (needs Node.js) for independent proof verification in the logic test and the
  smoke test. Without it the verification step is skipped; `REQUIRE_SNARKJS=1` makes a
  missing `snarkjs` an error.

Not needed:
- `circom`: the compiled circuit artifacts are checked in.
- A physical iPhone or an Apple Developer account for the simulator builds and the
  unsigned generic-device build. Installing on a physical device needs a valid signing
  identity, which this repository does not provide (see section 5).

## 1. Resources

```sh
scripts/prepare-ios-app-resources.sh           # write if missing/different, then verify
scripts/prepare-ios-app-resources.sh --check   # verify only, writes nothing
```

The script checks two things:

- the WASM equals the circuit's generated WASM;
- the artifact equals a fresh export from `age_check_final.zkey`, and two fresh exports
  are byte-identical (the export is deterministic, so committing the 7.8 kB artifact is
  safe).

Unexpected files in `Resources/` are reported, never deleted. The `.zkey` is never
bundled. If the circuit or zkey changes, rerun the script without `--check` and commit
both files.

## 2. Logic tests on the Mac

```sh
scripts/swift-app-logic-test.sh                    # snarkjs missing -> verification SKIPPED
REQUIRE_SNARKJS=1 scripts/swift-app-logic-test.sh  # strict
```

The script compiles the generated bindings as module `Laniakea` and builds the app's
service, message and view-model files plus `Tests-macOS/ServiceTests.swift` against the
host library. It covers:

- proofs for ages 25, 10, 18, 17, 0 and 255;
- rejection of malformed signals;
- input validation;
- what the circuit does with out-of-range ages (raw path);
- recovery after errors;
- bad resources;
- messages for all 17 `ProverError` cases;
- view-model behaviour (no duplicate submissions, main actor free while proving).

Finally snarkjs verifies the eligible proof and the (valid) ineligible proof.

## 3. iOS package

```sh
scripts/package-xcframework.sh
# -> target/uniffi/ios-14.0/LaniakeaKit/  (Package.swift, Sources/Laniakea, laniakeaFFI.xcframework)
```

The package's minimum is iOS 14 (`IPHONEOS_DEPLOYMENT_TARGET`). The app needs iOS 16+
for its SwiftUI APIs. Rebuild the package after any Rust or UniFFI change.

## 4. Simulator, scripted

```sh
scripts/run-ios-sim-app.sh                 # the one booted simulator
SIM_DEVICE=<udid> scripts/run-ios-sim-app.sh
```

This is a development harness, separate from the Xcode project in section 5. It builds
the app without `xcodebuild`, and drives it through a launch argument because `simctl`
cannot tap or type. It installs a separate app (`dev.laniakea.AgeCheckApp`). The
harness:

- compiles LaniakeaKit's Swift and the app's sources with `swiftc` for
  `arm64-apple-ios16.0-simulator` (Debug, `SDKROOT` set);
- links the Rust library from the XCFramework's simulator slice;
- bundles the two resources and ad-hoc signs the app;
- installs it and launches it four times with `-AgeCheckAutoProveAge <age>`.

That launch argument is a debug-only hook (see `LaunchOptions`): it enters the age and
presses the button through the normal code path.

It checks the app's `AGECHECK` trace lines on stderr:

- **25** → `eligible ["1", "18"]`
- **10** → `notEligible ["0", "18"]`
- **256** and **abc** → rejected before the prover is called
- the prover runs off the main thread
- proving releases the main actor

Screenshots and logs go to `target/uniffi/ios-app-sim/`.

## 5. Xcode project

The project is `examples/ios-age-app/AgeCheckDemo/AgeCheckDemo.xcodeproj`. It was
created with Xcode's iOS App template, not hand-written.

| Part | Details |
|---|---|
| Scheme | `AgeCheckDemo`, shared (`AgeCheckDemo.xcodeproj/xcshareddata/xcschemes/AgeCheckDemo.xcscheme`). |
| Target sources | The five files in `examples/ios-age-app/AgeCheckApp/`, referenced in place (not copied). The template's own Swift files were removed; only `AgeCheckDemo/Assets.xcassets` remains from the template. |
| Bundle resources | `age_check.wasm` and `age_check.artifact` (Copy Bundle Resources). |
| Package dependency | The local package `../../../target/uniffi/ios-14.0/LaniakeaKit` (relative to the project directory). The app links its product `LaniakeaKit` and uses `import Laniakea`. |
| Settings | Deployment target iOS 16.0; the Swift and concurrency settings in Concurrency above; bundle identifier `dev.laniakea.AgeCheckDemo`; automatic signing with no development team (see Signing below). |
| Debug vs Release | Debug defines `DEBUG`. Release does not, so `LaunchOptions` and the `AGECHECK` trace are compiled out. |

The package lives in the generated, git-ignored `target/` directory, so after a fresh
checkout **run steps 1 and 3 before opening the project**. The path assumes Cargo's
default target directory and `IPHONEOS_DEPLOYMENT_TARGET=14.0`. With a different
`CARGO_TARGET_DIR` or deployment target, re-add the package from its actual location.

**Signing:** the project contains no development team ID and no signing identity
(`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM` unset), so the simulator builds and the
unsigned device build (`CODE_SIGNING_ALLOWED=NO`) need nothing personal. To install on a
physical device, select your own team under Signing & Capabilities and, if
`dev.laniakea.AgeCheckDemo` is unavailable to your team, change the bundle identifier
locally. That path has not been exercised: no device is paired and no signing identity
was available here.

**Opening and running:** open the project in Xcode, choose the **iPhone Duo** (iOS 27.1)
simulator and Product → Run. For scripted input, add `-AgeCheckAutoProveAge 25` under
Edit Scheme → Run → Arguments (Debug only).

**Building from the command line:**

```sh
P=examples/ios-age-app/AgeCheckDemo/AgeCheckDemo.xcodeproj
UDID=<simulator udid>   # from: xcrun simctl list devices

# Debug, Apple-silicon simulator
xcodebuild -project "$P" -scheme AgeCheckDemo -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" build

# Release, the same simulator
xcodebuild -project "$P" -scheme AgeCheckDemo -configuration Release \
  -destination "platform=iOS Simulator,id=$UDID" build

# Release, any Apple-silicon simulator
xcodebuild -project "$P" -scheme AgeCheckDemo -configuration Release \
  -destination 'generic/platform=iOS Simulator' build

# Release, device: compile and link only, no code signing
xcodebuild -project "$P" -scheme AgeCheckDemo -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

**Supported architectures:** arm64 devices and arm64 (Apple-silicon) simulators only.
The XCFramework has exactly two slices, `ios-arm64` and `ios-arm64-simulator`. The
app target sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`, so the **app
executable** is arm64-only in simulator builds, including the generic one. The setting
is conditional on the simulator SDK; device builds are unaffected (`ARCHS = arm64`).

The exclusion applies to the app target only. Package targets do not inherit it: in the
generic simulator build, LaniakeaKit's Swift wrapper (`laniakea.swift`) was still
compiled for both arm64 and x86_64 (a universal object), and only the arm64 code ended up
in the app. That is harmless for the build, but **any other app that consumes
LaniakeaKit needs the same simulator exclusion** (`EXCLUDED_ARCHS[sdk=iphonesimulator*] =
x86_64`), because the package does not impose it.

**Intel (x86_64) simulator support is deferred**: it needs an x86_64 simulator slice
(`INCLUDE_X86_64_SIM=1 scripts/package-xcframework.sh`, not tested with the app) and
removing the exclusion.

**Build results** with Xcode 27.1:

| Configuration | Destination | Result |
|---|---|---|
| Debug | iPhone Duo simulator (iOS 27.1, arm64) | succeeds |
| Release | iPhone Duo simulator (iOS 27.1, arm64) | succeeds |
| Release | `generic/platform=iOS`, unsigned | succeeds |
| Release | `generic/platform=iOS Simulator` (arm64 only) | succeeds |

**Why the generic simulator build needed the exclusion:** a generic simulator build
uses `ARCHS_STANDARD`, which for the simulator SDK is `arm64 x86_64`, while the
XCFramework has only an arm64 simulator slice. Before the exclusion it failed at link
time with `Undefined symbols for architecture x86_64` (exit 65). With the exclusion the
app executable is arm64 only (checked with `lipo -archs` on the Debug simulator,
Release simulator and Release device products; the package's own wrapper object is the
exception described above).

**What the builds contained:**
- **Resources.** In the Debug simulator, Release simulator and Release device products,
  the bundled `age_check.wasm` and `age_check.artifact` were byte-identical to
  `AgeCheckApp/Resources/`, and no `.zkey` was bundled. The Release builds for a specific
  simulator and for the generic simulator write to the same product directory, so the
  check covered whichever of the two ran last (the generic one).
- **Release binaries.** The Release simulator and Release device executables inspected
  in an earlier check, before the x86_64 exclusion was added, had no
  `fork`/`exec`/`posix_spawn` or socket imports, and no debug-hook strings. That
  inspection was not repeated for the builds made with the exclusion, including the
  generic simulator build.
- **The Debug simulator build** still contains unreachable Rust `std` process and
  networking imports, because Xcode's debug dylib is not dead-stripped.

**Verified on the simulator** (Xcode Debug build on the iPhone Duo, iOS 27.1, driven with
`-AgeCheckAutoProveAge` and checked by screenshot):

| Age | Result |
|---|---|
| 0, 17 | "Proof generated — not eligible." |
| 18, 255 | "Proof generated — eligible." |
| 256 | inline 0–255 range message; button disabled; no proof |
| `abc` | inline digits-only message; button disabled; no proof |
| empty | button disabled |

The exact public signals for these ages are asserted by the logic test (section 2), not
read from the screenshots.

**How the project was created** (to recreate it, for example under another name):

1. Run steps 1 and 3 above.
2. Xcode → File → New → Project… → iOS → **App** → Next.
   - **Product Name:** `AgeCheckDemo`. Don't use `AgeCheckApp`: Xcode would create an
     `AgeCheckApp/` folder that collides with the existing sources.
   - **Interface:** SwiftUI. **Language:** Swift. **Testing System:** None. **Storage:**
     None.
   - Save in `examples/ios-age-app/`, with **Create Git repository** unchecked.
3. In the project navigator, delete the template's `AgeCheckDemoApp.swift` and
   `ContentView.swift` (Move to Trash). They would duplicate `@main` and `ContentView`.
   Keep `Assets.xcassets`.
4. File → Add Files to "AgeCheckDemo"… → select `examples/ios-age-app/AgeCheckApp`.
   - **Action:** Reference files in place.
   - **Groups:** Create groups.
   - **Target:** AgeCheckDemo checked.

   Don't add `Tests-macOS/`.
5. Target → Build Phases. Check that:
   - **Compile Sources** lists the five `.swift` files;
   - **Copy Bundle Resources** lists `age_check.wasm` and `age_check.artifact`. Add them
     if they're missing. Without them the app shows "Prover unavailable" and names the
     missing file.
6. File → Add Package Dependencies… → **Add Local…** → select
   `target/uniffi/ios-14.0/LaniakeaKit` → add the product **LaniakeaKit** to the
   AgeCheckDemo target. The project stores a relative path into `target/`, so keep that
   layout or re-add the package after moving it.
7. Target → General → Minimum Deployments: **iOS 16.0** or later. Use Swift 5 language
   mode, MainActor default isolation and Approachable Concurrency, the configuration
   verified above.
8. Choose the **iPhone Duo** (iOS 27.1) destination and Product → Run.

Per-user Xcode state (`xcuserdata/`) is not part of the project; don't commit it.

## Troubleshooting

- **"Prover unavailable … age_check.wasm is missing"**: the resources are not in Copy
  Bundle Resources (step 5).
- **`No such module 'Laniakea'`**: the LaniakeaKit product is not linked to the target,
  or the package was not built (`scripts/package-xcframework.sh`).
- **"UniFFI API checksum mismatch" at launch**: the package is stale relative to the
  Rust code. Rerun `scripts/package-xcframework.sh`, then File → Packages → Reset Package
  Caches.
- **`clang: warning: using sysroot for 'macOS …'`** when building by hand: set
  `SDKROOT` to the simulator SDK. Without it the SDK version recorded in the binary is
  the macOS one.
- **Swift 6 errors inside `laniakea.swift`**: the generated bindings must be compiled in
  Swift 5 mode, which the package manifest already does. Do not copy `laniakea.swift`
  into the app target.
- **Building for an Intel (x86_64) simulator:** not supported (section 5). The exact
  failure has not been tested, so no specific error message is documented. If the
  project's `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64` setting is removed, a
  generic simulator build is expected to fail with `Undefined symbols for architecture
  x86_64` again, as it did before the setting was added.
- **Missing package after a fresh checkout**: `target/` is generated. Run
  `scripts/package-xcframework.sh`, then reopen the project.

## Known limitations

**Verified:**
- The Xcode project builds as listed in section 5.
- The app launched on the iPhone Duo simulator (iOS 27.1) and gave the results tabulated
  there.

**Outstanding:**
- **Physical device.** Nothing has run on one, so device proving time, memory and binary
  size are unmeasured. Simulator times (a few milliseconds per proof) are measured on a
  Mac and are not device benchmarks.
- **Signed device builds.** The device build has only been compiled and linked with
  signing disabled; no development team is configured.
- **Release archive and App Store validation.** Neither has been done.
- **Accessibility.** No testing has been done.

**Unsupported or by design:**
- **Intel simulators.** Deferred: the XCFramework has no x86_64 simulator slice and the
  project excludes x86_64 for simulator builds.
- **Proof verification.** The app generates proofs but does not verify them, by design of
  the current FFI.
- **Eligibility.** Read from the public signals `[out, threshold]`, not from the fact that
  a proof exists. A valid proof is generated for eligible and ineligible ages alike.
- **The 0–255 range.** Enforced by the app's input validation. The circuit's
  `GreaterEqThan(8)` comparator does not enforce it.
