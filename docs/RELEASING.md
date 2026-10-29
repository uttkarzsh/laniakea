# Releasing and consuming Laniakea through Swift Package Manager

Status: **engineering for remote distribution is in place; nothing is published.** There is
no tag, no GitHub release and no published asset. The real HTTPS path (SwiftPM downloading
the release asset and checking its checksum) has therefore **not been tested**. This
document describes what exists, how a release is meant to be made, and what has to be
decided before the first public version.

## Two manifests: development and release

The repository's root `Package.swift` is the only manifest. It has two forms, differing in
exactly one line, the binary target `LaniakeaRustLib`:

| Form | Line | Where it belongs |
|---|---|---|
| Development (local) | `.binaryTarget(name: "LaniakeaRustLib", path: "Binaries/LaniakeaRustLib.xcframework")` | Every commit on a development branch, including `mother` |
| Release (remote) | `.binaryTarget(name: "LaniakeaRustLib", url: "https://…/<V>/LaniakeaRustLib-<V>.xcframework.zip", checksum: "<sha256>")` | **Only** the release commit that a version tag points at |

Nothing switches automatically. `scripts/release/set-binary-target.sh --local` and
`--remote --version <V> --url <URL> --checksum <SHA256>` are the only way the line is
changed; the result is validated with `swift package dump-package` (only that line may
differ) before it replaces the file. A manifest in remote form on a development branch
would make local development depend on a published asset, so do not commit it there.
Consequence: depending on the repository by *branch* gets the local form, which cannot
resolve for a consumer (`Binaries/` is git-ignored). Only tagged versions are consumable.

## Local development workflow

Needs full Xcode and a Rust toolchain with the iOS targets. Declared minimums: see below.

```sh
scripts/package-xcframework.sh     # builds, validates and installs Binaries/LaniakeaRustLib.xcframework,
                                   # refreshes the committed generated binding and header, runs check-bindings.sh
scripts/check-bindings.sh          # committed generated sources == a fresh generation
swift package dump-package         # and add the repository root as a local package in Xcode
```

The XCFramework in `Binaries/` is a local build product: **re-run `package-xcframework.sh`
after changing Rust code.** Nothing detects a stale `Binaries/` at consumption time; an
API change is caught by UniFFI's checksum at run time (by `fatalError`), an
implementation-only change is not caught at all.

## Keeping the binary, the generated binding and the wrapper in step

Three things must always describe the same native build:

1. the Rust static libraries inside the XCFramework,
2. the UniFFI-generated binding and C header, committed under `swift/LaniakeaKit/Sources/`
   (`_LaniakeaBindings/laniakea.swift`, `laniakeaFFI/include/laniakeaFFI.h`),
3. the handwritten Swift wrapper `LaniakeaKit`, which calls the binding.

A remote consumer cannot run UniFFI, so the generated files stay committed. The release
commit's manifest pins the binary by checksum, and the tag fixes the sources, so the three
cannot drift once tagged. Before tagging they are held together by:
`package-xcframework.sh` (bindings generated from each *final* slice must equal the
installed ones; platform, variant, architecture and minimum OS are checked on the final
XCFramework), `check-bindings.sh`, and `build-asset.sh`, which repeats those checks on the
ZIP it will publish, extracted into a fresh directory.

## Building the release asset

```sh
scripts/release/build-asset.sh 0.1.0        # SemVer; pre-releases like 0.1.0-rc.1 are fine
```

Requires a clean working tree (modified or untracked-but-unignored files are refused, so the
asset comes from a recorded commit), the development form of the manifest, and a version
whose `dist/<version>/` does not exist (a version is never rebuilt over). It builds with
`package-xcframework.sh` (this replaces your local `Binaries/` copy), zips the XCFramework with
the `.xcframework` directory at the archive root, computes the checksum with
`swift package compute-checksum` on that exact file, extracts that same ZIP into a fresh
directory and validates it again, and writes, under `dist/<version>/` (git-ignored):

- `LaniakeaRustLib-<version>.xcframework.zip` – the asset to upload,
- `RELEASE-INFO.txt` – version, source commit, toolchain versions, ZIP checksum, hashes of
  each library, of the XCFramework's `Info.plist` and of the committed binding and header.

It never creates a tag, commit, release or upload. Observed so far, on one machine:
the two slices' library hashes were identical across two builds, and across builds in two
different checkout paths (path remapping is what allows the latter), but the ZIP (and so its
checksum) and the XCFramework's `Info.plist` differed between two builds of the same
libraries (file timestamps are stored in the archive). Reproducibility across machines
or toolchains is untested and is not claimed; the checksum that counts is that of the file
you upload.

## Versions, tags and immutable assets

- Versions are SemVer; tags are the bare version (`0.1.0`, `0.1.0-rc.1`), annotated, and
  never moved or re-created. SwiftPM selects a pre-release only when it is requested
  explicitly.
- The asset name embeds the version: `LaniakeaRustLib-<version>.xcframework.zip`, uploaded as
  an asset of the GitHub release for that tag. `set-binary-target.sh` refuses a URL that does
  not end in `/<version>/LaniakeaRustLib-<version>.xcframework.zip`.
- Never replace an uploaded asset: a different file has a different checksum and would make
  every pinned consumer fail to resolve, which is the correct failure. Publish a new version
  instead. Whether GitHub's "immutable releases" setting is available and enabled for the
  repository was not checked; look in the repository settings.

### Intended release procedure (manual; no automation)

1. On a clean, reviewed commit: `scripts/release/build-asset.sh <V>`.
2. Create the GitHub release for tag `<V>` and upload the ZIP as an asset (this is publication
   and needs the maintainer's explicit go-ahead; the scripts never do it).
3. Make the **release commit**: `scripts/release/set-binary-target.sh --remote --version <V> --url <asset URL> --checksum <checksum from RELEASE-INFO.txt>`, review the one-line
   diff, commit.
4. Tag that commit `<V>` (annotated) and push it.
5. Validate as an external consumer (next section), against the real HTTPS URL.
6. Switch the development branch back with `set-binary-target.sh --local` (the release
   commit lives only on the tag).

## Validating as an external consumer

`scripts/release/validate-consumer.sh` copies `examples/ios-consumer` to a temporary
directory outside the repository, makes it depend on the package by repository URL and
**exact version**, uses fresh derived-data, source-package and package caches with
`-disablePackageRepositoryCache`, and a `PATH` without cargo. It then resolves, builds for
the generic iOS Simulator and for generic iOS (`CODE_SIGNING_ALLOWED=NO`), checks that the
build logs mention neither the Rust workspace, `Binaries/` nor the toolchain, runs the app
on a simulator for age 25 and age 10, exports `proof.json`/`public.json`, verifies both with
`snarkjs groth16 verify`, and checks that the age-10 proof with the age-25 public signals
is rejected. The circuit files it copies in are the repository's development `age_check`
pair, standing in for a consumer's own.

| Mode | What it proves | What it does not |
|---|---|---|
| `--rehearse <V>` (offline) | The ZIP layout, SwiftPM using an XCFramework from an archive, tag + exact-version resolution through a `file://` repository, a consumer with no Rust and no `Binaries/`, proof generation and snarkjs verification | HTTPS download of the asset, the binary-target checksum (SwiftPM checks it only for `url:` targets), GitHub, the release-commit manifest |
| `--remote <https URL> <V>` | The real thing: the published tag, the remote manifest, HTTPS download, checksum | **Not run: nothing is published** |

In `--rehearse` mode the binary target of a throwaway repository points at the ZIP by
path. The rehearsal result must never be reported as an HTTPS result.

## Declared versus tested

| | Declared | Actually tested |
|---|---|---|
| iOS deployment target | 15.0 (`Package.swift`; the Rust objects are verified to be built for exactly 15.0) | iOS 27.0/27.1 simulator only. One physical iPhone 16 was used by the maintainer with the *earlier, pre-package* layout (not verified by this repository's scripts). Nothing from 15 to 26 has been run |
| Xcode / Swift toolchain | Swift tools 6.0, i.e. Xcode 16.0 or later (`swift-tools-version:6.0`, and `internal import`, SE-0409) | Xcode 27.1 (Swift 6.4) only. **Xcode 16.x has not been tested** |
| Language mode | Swift 5 (the UniFFI 0.28.3 output does not compile in Swift 6 mode) | Swift 5 mode |
| Architectures | iOS device arm64, Apple Silicon simulator arm64 | same; **no Intel simulator slice** in the initial distribution (Intel-Mac simulators are unsupported) |

A simulator build is not evidence of physical-device compatibility.

## Preparing circuit files (`.artifact`) needs the Rust CLI

Consumers never need Rust to *use* the package, but the proving artifact for a circuit is
produced from its `.zkey` by the repository's Rust tool, on a development machine:

```sh
cargo run -p laniakea-cli --bin export_artifact -- <circuit>_final.zkey <circuit>.artifact
```

The app bundles `<name>.artifact` and `<name>.wasm` and loads them with `Circuit(name:)`.
There is no Rust-free authoring workflow, and none is promised. The `.artifact` format is
versioned (`docs/ARTIFACT_FORMAT.md`); artifacts made before the header existed must be
re-exported with this tool.

## Before any public release (decisions not made here)

These are open and **not** resolved by the Phase 2A engineering work:

- **Licence.** The repository has no LICENSE file; the README states "MIT OR Apache-2.0" but
  the maintainer has not added files or `license` fields. No licence has been chosen here.
- **Third-party notices.** The static library contains many dependencies (arkworks, wasmi,
  UniFFI crates under MPL-2.0, `subtle` under BSD-3-Clause, others). An inventory and a
  notices file shipped with the source and the asset are needed; whether MPL obligations
  apply to this distribution needs human legal review.
- **circomlib (GPL-3.0).** `circuits/age_check` includes circomlib circuits. Whether the
  compiled example circuit files (already public in this repository) carry obligations needs
  legal review. Keep example circuit artifacts out of the SDK asset (they are).
- **`.artifact` versioning: implemented, pending your review.** The artifact now has an
  18-byte header with a magic and a format version (`docs/ARTIFACT_FORMAT.md`); format 1 is
  the first versioned format and legacy raw files are intentionally not read. It carries no
  circuit identity and no integrity check. Anyone who made raw artifacts from earlier commits
  of `mother` must re-export them.
- **Security posture.** The only circuit is a development example with a development
  trusted setup (single contribution), it does not constrain `out == 1`, and nothing is
  audited. State this in the release notes.
- **Minimums.** Confirm the iOS and Xcode minimums, or raise them to what can be tested.

## Deferred risks

- The static library exports roughly 17,000 Rust symbols (including `_rust_eh_personality`),
  so an app linking another Rust static library may hit duplicate-symbol errors. Hiding
  symbols or a dynamic framework would address it.
- The `wasmi` default features pull in `wat`; unstripped libraries are about 27 MB per slice
  (app size after dead-stripping is unmeasured).
- `_LaniakeaBindings` can be imported by consumers (SwiftPM cannot hide it).
- UniFFI mismatch handling is `fatalError`.
- Cross-machine reproducibility of the libraries and a deterministic ZIP are untested.
- No CI and no release automation; every step above is manual.
- Remapped build paths (`/laniakea`, `/cargo`, `/rust-sysroot`) are checked for the builder's
  home directory only; other embedded strings were not audited.
