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
#   3. zips the XCFramework with the .xcframework directory at the archive root, plus any
#      licence and notice files found at the repository root (LICENSE*, NOTICE*,
#      THIRD_PARTY_NOTICES*; tracked files only). The archive is deterministic: the files
#      are copied to a staging directory with normalized modes and a fixed modification time,
#      listed in sorted order and stored by `zip -X` with TZ=UTC, and the script builds it
#      twice and requires identical bytes;
#   4. computes the checksum with `swift package compute-checksum` on that exact file;
#   5. validates that exact ZIP: its entry list is exactly the expected files (no directory
#      entries, resource forks, absolute or `..` paths), `unzip -t` passes, and the extracted
#      copy has the expected files, slices, platform variants, architectures, the minimum
#      deployment target of this project's objects, identity with the freshly staged
#      libraries, no builder paths (the home directory, the repository root, any /Users/ path),
#      and the committed binding and header are exactly what bindgen generates from each
#      extracted library;
#   6. writes RELEASE-INFO.txt.
#
# REQUIRE_NOTICES=1 makes the build fail unless a LICENSE* file and a THIRD_PARTY_NOTICES*
# file are present (the pre-release script sets it). Without it, a missing set is a loud
# warning and RELEASE-INFO.txt says the asset ships without notices.
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

# Licence and notice files at the repository root go into the archive root, next to the
# XCFramework. Only tracked files count.
NOTICES=()
while IFS= read -r f; do NOTICES+=("$f"); done < <(git ls-files -- ':(top)LICENSE*' ':(top)NOTICE*' ':(top)THIRD_PARTY_NOTICES*' | grep -v / | LC_ALL=C sort)
has_license=0; has_third=0
for f in ${NOTICES[@]+"${NOTICES[@]}"}; do
  case "$f" in LICENSE*) has_license=1 ;; THIRD_PARTY_NOTICES*) has_third=1 ;; esac
done
if [ "$has_license" = 0 ] || [ "$has_third" = 0 ]; then
  echo "WARNING: no LICENSE* file and/or no THIRD_PARTY_NOTICES* file at the repository root: this asset would ship without them (see README.md, "License")" >&2
  [ "${REQUIRE_NOTICES:-0}" != 1 ] || die "REQUIRE_NOTICES=1 but the licence and third-party notice files are missing"
fi

echo "==> creating $ASSET (deterministic)"
SCRATCH="$WORK/scratch"   # validation work files; never part of the output
STAGEZ="$SCRATCH/zipstage"
mkdir -p "$STAGEZ"
cp -R "$ROOT/Binaries/$XCFNAME" "$STAGEZ/$XCFNAME"
for f in ${NOTICES[@]+"${NOTICES[@]}"}; do cp "$ROOT/$f" "$STAGEZ/$f"; done
# Normalized: no extended attributes, modes 755/644, one fixed modification time.
xattr -cr "$STAGEZ" 2>/dev/null || true
find "$STAGEZ" -type d -exec chmod 755 {} +
find "$STAGEZ" -type f -exec chmod 644 {} +
find "$STAGEZ" -exec touch -h -t 198001010000 {} +
make_zip() { # <output>
  rm -f "$1"
  ( cd "$STAGEZ" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | TZ=UTC zip -X -q -9 -D "$1" -@ )
}
make_zip "$WORK/$ASSET"
make_zip "$SCRATCH/second.zip"
cmp -s "$WORK/$ASSET" "$SCRATCH/second.zip" || die "two archives built from identical inputs differ; the archive is not deterministic"

echo "==> swift package compute-checksum"
CHECKSUM="$(cd "$WORK" && swift package compute-checksum "$ASSET")"
grep -Eq '^[0-9a-f]{64}$' <<<"$CHECKSUM" || die "unexpected checksum output: $CHECKSUM"
ZIP_SHA="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
[ "$CHECKSUM" = "$ZIP_SHA" ] || echo "note: SwiftPM checksum and shasum differ ($CHECKSUM vs $ZIP_SHA); the SwiftPM value is the one to use"

echo "==> validating the ZIP"
unzip -tq "$WORK/$ASSET" >/dev/null || die "unzip -t failed for $ASSET"
EXPECTED_LIST="$( { (cd "$STAGEZ" && find . -type f | sed 's|^\./||'); } | LC_ALL=C sort)"
ACTUAL_LIST="$(unzip -Z1 "$WORK/$ASSET" | LC_ALL=C sort)"
[ "$EXPECTED_LIST" = "$ACTUAL_LIST" ] || die "the ZIP's entries differ from the staged files:
expected:
$EXPECTED_LIST
actual:
$ACTUAL_LIST"
if grep -Eq '(^/|(^|/)\.\.(/|$)|__MACOSX|\.DS_Store|/$)' <<<"$ACTUAL_LIST"; then die "the ZIP contains an absolute or parent path, a resource fork, a .DS_Store or a directory entry"; fi
echo "  ok  $(wc -l <<<"$ACTUAL_LIST" | tr -d ' ') entries: $(tr '\n' ' ' <<<"$ACTUAL_LIST" | cut -c1-300)"
echo "==> re-extracting the ZIP and validating the extracted copy"
EXT="$SCRATCH/extracted"
mkdir -p "$EXT"
ditto -x -k "$WORK/$ASSET" "$EXT"
EXPECTED_ROOT="$( { echo "$XCFNAME"; for f in ${NOTICES[@]+"${NOTICES[@]}"}; do echo "$f"; done; } | LC_ALL=C sort)"
[ "$(ls -A "$EXT" | LC_ALL=C sort)" = "$EXPECTED_ROOT" ] || die "the ZIP root must contain exactly: $(tr '\n' ' ' <<<"$EXPECTED_ROOT"); found: $(ls -A "$EXT" | tr '\n' ' ')"
diff -r "$EXT/$XCFNAME" "$ROOT/Binaries/$XCFNAME" >/dev/null || die "the extracted XCFramework differs from the packaged one"
for f in ${NOTICES[@]+"${NOTICES[@]}"}; do cmp -s "$EXT/$f" "$ROOT/$f" || die "the archived $f differs from the repository's"; done
validate_xcframework "$EXT/$XCFNAME" "$STAGE" "$LIBNAME" "$MIN" "ios-arm64-simulator" "arm64" "$SCRATCH"
check_no_builder_paths "$EXT/$XCFNAME" "$HOME" "$ROOT" "/Users/"
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
  echo "licence and notice files in the archive:"
  if [ "${#NOTICES[@]}" -eq 0 ]; then echo "  NONE (this asset ships without licence or notice files)"; fi
  for f in ${NOTICES[@]+"${NOTICES[@]}"}; do echo "  $f  $(shasum -a 256 "$EXT/$f" | awk '{print $1}')"; done
  echo "archive entries: $(wc -l <<<"$ACTUAL_LIST" | tr -d ' ') (stored deterministically; two builds from the same inputs on this machine were byte-identical)"
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
  echo "Reproducibility: the archive format is deterministic for identical inputs (checked"
  echo "twice within this build). Whether the libraries inside are reproducible across"
  echo "machines or toolchains has not been tested and is not claimed."
  echo "Tested: see docs/INTEGRATION.md (declared minimums versus tested versions)."
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
echo "Nothing was tagged, committed, pushed or uploaded. Next (manual, see the Releasing section of README.md):"
echo "  upload the ZIP as a release asset, then in the release commit run"
echo "  scripts/release/set-binary-target.sh --remote --version $VERSION --url <asset URL> --checksum $CHECKSUM"
