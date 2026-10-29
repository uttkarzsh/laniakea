#!/usr/bin/env bash
# Builds the release asset for a version: LaniakeaRustLib-<version>.xcframework.zip, its
# SwiftPM checksum and a RELEASE-INFO.txt, under dist/<version>/ (git-ignored).
#
# Usage:  scripts/release/build-asset.sh <version>        e.g. 0.1.0 or 0.1.0-rc.1
#
# What it does:
#   1. checks the version (SemVer) and that the working tree is clean (no modified,
#      deleted or untracked-but-not-ignored files), that dist/<version> does not exist
#      (a released version is never rebuilt over), and that Package.swift is in its
#      development (local binary target) form;
#   2. scripts/package-xcframework.sh: builds the iOS libraries from the current source,
#      validates and installs Binaries/LaniakeaRustLib.xcframework, and runs
#      scripts/check-bindings.sh. (This replaces your local Binaries/ copy.) The tree must
#      still be clean afterwards, i.e. the committed bindings were already current;
#   3. zips the XCFramework with the .xcframework directory at the archive root;
#   4. computes the checksum with `swift package compute-checksum` on that exact file;
#   5. extracts that exact ZIP into a fresh directory and validates the extracted copy:
#      only the expected files, slices, platform variants, architectures, the minimum
#      deployment target of this project's objects, identity with the freshly staged
#      libraries, no builder paths, and that the committed binding and header are exactly
#      what bindgen generates from each extracted library;
#   6. writes RELEASE-INFO.txt.
#
# Everything is assembled in a hidden temporary directory inside dist/ and renamed to
# dist/<version>/ only at the end; on failure it is removed and nothing else is touched
# (no existing dist/<version>, no tag, no commit, no GitHub release, no upload).
# Intel simulator slices are not part of the first distribution: INCLUDE_X86_64_SIM must
# not be set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=../lib/xcframework.sh
. "$ROOT/scripts/lib/xcframework.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 64; }
VERSION="$1"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$' <<<"$VERSION" \
  || die "version '$VERSION' is not SemVer (e.g. 0.1.0 or 0.1.0-rc.1)"
[ "${INCLUDE_X86_64_SIM:-0}" != "1" ] || die "the first distribution is arm64 only; unset INCLUDE_X86_64_SIM"
for tool in git ditto swift xcodebuild shasum python3 cargo rustc; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

dirty="$(git status --porcelain)"
[ -z "$dirty" ] || die "the working tree is not clean; commit or stash first (a release asset must come from a recorded commit):
$dirty"
COMMIT="$(git rev-parse HEAD)"
BRANCH="$(git branch --show-current || true)"
grep -Eq '^ *\.binaryTarget\(name: "LaniakeaRustLib", path: "Binaries/LaniakeaRustLib\.xcframework"\),$' Package.swift \
  || die "Package.swift is not in its development form; run scripts/release/set-binary-target.sh --local first"

DIST="$ROOT/dist"
OUT="$DIST/$VERSION"
[ ! -e "$OUT" ] || die "$OUT already exists; a version's assets are never rebuilt over. Remove it yourself if it was never published."
mkdir -p "$DIST"
WORK="$(mktemp -d "$DIST/.build-$VERSION.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> building and validating the XCFramework (scripts/package-xcframework.sh)"
"$ROOT/scripts/package-xcframework.sh"
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || die "packaging changed tracked or unignored files (the committed bindings were out of date?):
$dirty"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "HEAD moved during the build"

ios_layout   # MIN, TARGET, STAGE
BIND="$TARGET/uniffi/swift"
LIBNAME=liblaniakea_uniffi.a
XCFNAME=LaniakeaRustLib.xcframework
ASSET="LaniakeaRustLib-$VERSION.xcframework.zip"

echo "==> creating $ASSET"
# The archive holds only the .xcframework directory (--keepParent), without resource
# forks, extended attributes, quarantine flags or ACLs.
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$ROOT/Binaries/$XCFNAME" "$WORK/$ASSET"

echo "==> swift package compute-checksum"
CHECKSUM="$(cd "$WORK" && swift package compute-checksum "$ASSET")"
grep -Eq '^[0-9a-f]{64}$' <<<"$CHECKSUM" || die "unexpected checksum output: $CHECKSUM"
ZIP_SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
[ "$CHECKSUM" = "$ZIP_SHA" ] || echo "note: SwiftPM checksum and shasum differ ($CHECKSUM vs $ZIP_SHA); the SwiftPM value is the one to use"

echo "==> re-extracting the ZIP and validating the extracted copy"
SCRATCH="$WORK/scratch"   # validation work files; never part of the output
EXT="$SCRATCH/extracted"
mkdir -p "$EXT"
ditto -x -k "$WORK/$ASSET" "$EXT"
[ "$(ls -A "$EXT")" = "$XCFNAME" ] || die "the ZIP root must contain exactly $XCFNAME, found: $(ls -A "$EXT" | tr '\n' ' ')"
diff -r "$EXT/$XCFNAME" "$ROOT/Binaries/$XCFNAME" >/dev/null || die "the extracted XCFramework differs from the packaged one"
validate_xcframework "$EXT/$XCFNAME" "$STAGE" "$LIBNAME" "$MIN" "ios-arm64-simulator" "arm64" "$SCRATCH"
check_no_builder_paths "$EXT/$XCFNAME" "$HOME" "$ROOT"
echo "==> binding and header against the extracted libraries"
mkdir "$SCRATCH/committed"
cp "$ROOT/swift/LaniakeaKit/Sources/_LaniakeaBindings/laniakea.swift" "$ROOT/swift/LaniakeaKit/Sources/laniakeaFFI/include/laniakeaFFI.h" "$SCRATCH/committed/"
verify_binding_matches_xcframework "$EXT/$XCFNAME" "$SCRATCH/committed" "$LIBNAME" "$SCRATCH"
grep -Fq ".iOS(\"$MIN\")" Package.swift || die "Package.swift does not declare iOS $MIN"

echo "==> writing RELEASE-INFO.txt"
uniffi_ver="$(awk '/^name = "uniffi"$/{getline; print $3; exit}' Cargo.lock | tr -d '"')"
{
  echo "Laniakea release asset"
  echo "version:            $VERSION"
  echo "source commit:      $COMMIT"
  echo "source branch:      ${BRANCH:-(detached)}"
  echo "working tree:       clean at build time"
  echo "built (UTC):        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "asset:              $ASSET"
  echo "asset size (bytes): $(stat -f %z "$WORK/$ASSET")"
  echo "swiftpm checksum:   $CHECKSUM   (swift package compute-checksum)"
  echo "asset sha256:       $ZIP_SHA"
  echo "declared min iOS:   $MIN (Package.swift)"
  echo "slices:             ios-arm64 (device), ios-arm64-simulator (Apple Silicon simulator)"
  echo "no Intel simulator slice"
  echo
  echo "libraries (sha256):"
  for s in ios-arm64 ios-arm64-simulator; do
    echo "  $s/$LIBNAME  $(shasum -a 256 "$EXT/$XCFNAME/$s/$LIBNAME" | awk '{print $1}')"
  done
  echo "  Info.plist  $(shasum -a 256 "$EXT/$XCFNAME/Info.plist" | awk '{print $1}')"
  echo
  echo "committed generated files (sha256), validated against the libraries above:"
  echo "  laniakea.swift    $(shasum -a 256 "$SCRATCH/committed/laniakea.swift" | awk '{print $1}')"
  echo "  laniakeaFFI.h     $(shasum -a 256 "$SCRATCH/committed/laniakeaFFI.h" | awk '{print $1}')"
  echo
  echo "toolchain:"
  echo "  $(rustc -vV | sed -n 1p) / $(rustc -vV | sed -n 2,3p | tr '\n' ' ')"
  echo "  $(cargo -V)"
  echo "  uniffi (Cargo.lock): ${uniffi_ver:-unknown}"
  echo "  $(xcodebuild -version | tr '\n' ' ')"
  echo "  $(swift --version 2>&1 | head -1)"
  echo "  $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
  echo
  echo "Reproducibility: this file does not claim the asset is reproducible on another"
  echo "machine or toolchain; that has not been tested."
  echo "Tested: see docs/RELEASING.md (declared minimums versus tested versions)."
} > "$WORK/RELEASE-INFO.txt"
rm -rf "$SCRATCH"

# Output: exactly the ZIP and RELEASE-INFO.txt.
chmod 755 "$WORK"
mv "$WORK" "$OUT"

trap - EXIT
echo
echo "OK: $OUT"
echo "    $ASSET"
echo "    swiftpm checksum: $CHECKSUM"
echo "Nothing was tagged, committed, pushed or uploaded. Next (manual, see docs/RELEASING.md):"
echo "  upload the ZIP as a release asset, then in the release commit run"
echo "  scripts/release/set-binary-target.sh --remote --version $VERSION --url <asset URL> --checksum $CHECKSUM"
