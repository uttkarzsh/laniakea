#!/usr/bin/env bash
# Validates the package as an EXTERNAL consumer would use it: a throwaway copy of
# examples/ios-consumer, outside the repository, that depends on the package by
# repository URL and exact version, with fresh package and derived-data caches and a
# PATH without cargo/rustup. Builds for the generic iOS Simulator and generic iOS
# (signing disabled), runs the app on a simulator for an eligible and an ineligible
# age, exports proof.json/public.json, verifies both with snarkjs, and checks that a
# tampered public signal is rejected.
#
# Two modes. The report states which one ran, and they prove different things.
#
#   scripts/release/validate-consumer.sh --rehearse <version>
#       OFFLINE REHEARSAL. Uses dist/<version>/LaniakeaRustLib-<version>.xcframework.zip
#       from scripts/release/build-asset.sh. Builds a throwaway local git repository
#       from the current working tree (tracked and unignored files), in which the binary
#       target points at that ZIP by path, commits it and tags <version>; the fixture
#       resolves it by file:// URL and exact version. It exercises the ZIP layout, SwiftPM's
#       handling of an XCFramework from an archive, tag resolution and a consumer with no
#       Rust. It does NOT exercise an HTTPS download or the binary-target checksum:
#       SwiftPM verifies a checksum only for a remote url: target.
#
#       With ASSET_URL_BASE=https://host:port/path set (the ZIP served at
#       $ASSET_URL_BASE/<version>/LaniakeaRustLib-<version>.xcframework.zip), the binary target
#       is a url: target instead, so SwiftPM downloads the ZIP and verifies its checksum; see
#       scripts/release/serve-asset-https.sh for a local server. Still a local git repository.
#       ASSET_CHECKSUM=<64 hex digits> replaces the computed checksum, to check that SwiftPM
#       rejects a mismatch (the run must then fail at package resolution).
#
#   scripts/release/validate-consumer.sh --remote <https-repository-URL> <version>
#       REAL REMOTE. The same fixture resolves the published repository by https URL and
#       exact version; SwiftPM downloads the release asset over HTTPS and checks its
#       checksum. Needs a published tag whose manifest has the remote binary target; this
#       has not been run, because nothing is published.
#
# Environment: SIM_DEVICE=<udid> (default: the single booted simulator),
#   CIRCUIT_ARTIFACT / CIRCUIT_WASM (default: the repository's development age_check
#   pair; test input standing in for the consumer's own circuit), VKEY (default:
#   circuits/age_check/verification_key.json), KEEP_WORK=1 (keep the temporary directory).
# Needs full Xcode, git, python3 and snarkjs (on PATH or via npx). Writes only under a
# temporary directory (TMPDIR). Creates no tag, commit or release in this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/scripts/lib/common.sh"

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
MODE="${1:-}"
case "$MODE" in
  --rehearse) [ "$#" -eq 2 ] || usage; VERSION="$2"; REPO_URL="" ;;
  --remote) [ "$#" -eq 3 ] || usage; REPO_URL="$2"; VERSION="$3"
            case "$REPO_URL" in https://*) ;; *) die "--remote needs an https:// repository URL" ;; esac ;;
  *) usage ;;
esac
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$' <<<"$VERSION" || die "version '$VERSION' is not SemVer"
for tool in git xcodebuild xcrun python3 ditto; do command -v "$tool" >/dev/null || die "$tool not found"; done
SNARKJS=(snarkjs); command -v snarkjs >/dev/null || SNARKJS=(npx --no-install snarkjs)
VKEY="${VKEY:-$ROOT/circuits/age_check/verification_key.json}"
ART="${CIRCUIT_ARTIFACT:-$ROOT/examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact}"
WASM="${CIRCUIT_WASM:-$ROOT/examples/ios-age-app/AgeCheckApp/Resources/age_check.wasm}"
for f in "$VKEY" "$ART" "$WASM"; do [ -s "$f" ] || die "missing input file: $f"; done

UDID="${SIM_DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
[ -n "$UDID" ] || die "no booted simulator; boot one or set SIM_DEVICE=<udid>"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

WORK="$(mktemp -d "${TMPDIR:-/tmp}/laniakea-consumer.XXXXXX")"
OK=0
cleanup() {
  if [ "$OK" = 1 ] && [ "${KEEP_WORK:-0}" != 1 ]; then rm -rf "$WORK"; else echo "work directory kept: $WORK" >&2; fi
}
trap cleanup EXIT
echo "work directory: $WORK"

# --- the package source the fixture depends on
if [ "$MODE" = "--rehearse" ]; then
  BANNER="OFFLINE REHEARSAL (local git repository + local ZIP; NOT an HTTPS download, checksum NOT exercised)"
  ASSET="LaniakeaRustLib-$VERSION.xcframework.zip"
  ZIP="$ROOT/dist/$VERSION/$ASSET"
  [ -s "$ZIP" ] || die "$ZIP not found; run scripts/release/build-asset.sh $VERSION first"
  RE="$WORK/rehearsal-repo"
  mkdir -p "$RE"
  echo "==> building the rehearsal repository from the working tree"
  # Tracked and unignored files that exist now (a deleted tracked file is skipped).
  ( cd "$ROOT" && git ls-files -co --exclude-standard -z ) | while IFS= read -r -d '' f; do
    [ -f "$ROOT/$f" ] || continue
    mkdir -p "$RE/$(dirname "$f")"; cp -p "$ROOT/$f" "$RE/$f"
  done
  if [ -z "${ASSET_URL_BASE:-}" ]; then cp "$ZIP" "$RE/$ASSET"; fi
  if [ -n "${ASSET_URL_BASE:-}" ]; then
    # The binary target downloads the asset over HTTPS and SwiftPM checks its checksum.
    case "$ASSET_URL_BASE" in https://*) ;; *) die "ASSET_URL_BASE must be an https:// URL" ;; esac
    TARGET_LINE="url: \"${ASSET_URL_BASE%/}/$VERSION/$ASSET\", checksum: \"${ASSET_CHECKSUM:-$(swift package compute-checksum "$ZIP")}\""
    BANNER="HTTPS ASSET REHEARSAL (local git repository; asset downloaded from $ASSET_URL_BASE, checksum verified by SwiftPM)"
  else
    TARGET_LINE="path: \"$ASSET\""
  fi
  python3 - "$RE/Package.swift" "$TARGET_LINE" <<'PY'
import re, sys
p, target = sys.argv[1:3]
t = open(p).read()
pat = re.compile(r'^( *)\.binaryTarget\(name: "LaniakeaRustLib",[^\n]*\),\n', re.M)
assert len(pat.findall(t)) == 1
open(p, "w").write(pat.sub(lambda m: '%s.binaryTarget(name: "LaniakeaRustLib", %s),\n' % (m.group(1), target), t, count=1))
PY
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  git -C "$RE" init -q -b main
  git -C "$RE" add -A
  git -C "$RE" -c user.name=rehearsal -c user.email=rehearsal@invalid -c commit.gpgsign=false commit -q -m "rehearsal $VERSION"
  git -C "$RE" -c user.name=rehearsal -c user.email=rehearsal@invalid -c tag.gpgsign=false tag -a "$VERSION" -m "rehearsal $VERSION"
  EXPECT_REV="$(git -C "$RE" rev-parse "$VERSION^{commit}")"
  REPO_URL="file://$RE"
else
  BANNER="REAL REMOTE (repository and release asset fetched over HTTPS; checksum verified by SwiftPM)"
  EXPECT_REV=""
fi
echo "mode: $BANNER"

# --- the consumer fixture: a copy outside the repository, depending on the package by URL + exact version
FIX="$WORK/consumer"
mkdir -p "$FIX"
cp -R "$ROOT/examples/ios-consumer/LaniakeaConsumer.xcodeproj" "$ROOT/examples/ios-consumer/LaniakeaConsumer" "$FIX/"
rm -rf "$FIX/LaniakeaConsumer/Resources"; mkdir -p "$FIX/LaniakeaConsumer/Resources"
cp "$ART" "$FIX/LaniakeaConsumer/Resources/age_check.artifact"
cp "$WASM" "$FIX/LaniakeaConsumer/Resources/age_check.wasm"
"$ROOT/examples/ios-consumer/package-source.sh" remote --exact "$VERSION" --url "$REPO_URL" --project "$FIX/LaniakeaConsumer.xcodeproj/project.pbxproj" >/dev/null

# --- builds with fresh caches and no Rust toolchain on PATH
PROJ="$FIX/LaniakeaConsumer.xcodeproj"
DD="$WORK/derived-data"; CLONES="$WORK/source-packages"; PKGCACHE="$WORK/package-cache"
CLEANPATH="/usr/bin:/bin:/usr/sbin:/sbin"
! PATH="$CLEANPATH" command -v cargo >/dev/null 2>&1 || die "cargo is reachable on the restricted PATH"
XB=(env "PATH=$CLEANPATH" xcodebuild -project "$PROJ" -scheme LaniakeaConsumer -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$CLONES" -packageCachePath "$PKGCACHE" -disablePackageRepositoryCache)

echo "==> resolving the package ($REPO_URL @ $VERSION)"
"${XB[@]}" -resolvePackageDependencies > "$WORK/resolve.log" 2>&1 || { tail -30 "$WORK/resolve.log" >&2; die "package resolution failed"; }
RESOLVED="$(find "$PROJ" -name Package.resolved | head -1)"
[ -n "$RESOLVED" ] || die "no Package.resolved was written"
python3 - "$RESOLVED" "$VERSION" "$EXPECT_REV" <<'PY'
import json, sys
f, version, expect = sys.argv[1:4]
pins = json.load(open(f))["pins"]
if len(pins) != 1: sys.exit("expected one resolved package, found %d" % len(pins))
st = pins[0]["state"]
if st.get("version") != version: sys.exit("resolved version %r, expected %r" % (st.get("version"), version))
if expect and st.get("revision") != expect: sys.exit("resolved revision %s, expected %s" % (st.get("revision"), expect))
print("  resolved: %s %s revision %s" % (pins[0]["location"], st["version"], st["revision"]))
PY

build() { # <label> <destination> [extra xcodebuild args...]
  local label="$1" dest="$2"; shift 2
  echo "==> build: $label"
  "${XB[@]}" -destination "$dest" "$@" build > "$WORK/build-$label.log" 2>&1 \
    || { grep -E 'error:' "$WORK/build-$label.log" | head -10 >&2; die "build failed: $label (log: $WORK/build-$label.log)"; }
  grep -q 'BUILD SUCCEEDED' "$WORK/build-$label.log" || die "no BUILD SUCCEEDED in $label"
  if grep -nE "$ROOT/(Binaries|target|crates|vendor)|/\.cargo/|/\.rustup/" "$WORK/build-$label.log" | head -3 | grep .; then
    die "the $label build touched the Rust workspace or toolchain"
  fi
  echo "  BUILD SUCCEEDED ($label); no reference to the Rust workspace, Binaries/ or the toolchain in its log"
}
build simulator "generic/platform=iOS Simulator"
build device "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO

# --- run on the simulator, export, verify
APP="$(find "$DD/Build/Products" -name LaniakeaConsumer.app -path '*iphonesimulator*' | head -1)"
[ -d "$APP" ] || die "simulator app not found"
xcrun simctl install "$UDID" "$APP"
BUNDLE=dev.laniakea.LaniakeaConsumer
run_age() { # <age> -> prints the data container's Documents path
  local age="$1" docs
  docs="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents"
  rm -f "$docs/consumer.log" "$docs/proof.json" "$docs/public.json"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" -ConsumerAutoAge "$age" -ConsumerAutoExport 1 >/dev/null
  for _ in $(seq 1 60); do grep -q '^export:' "$docs/consumer.log" 2>/dev/null && break; sleep 1; done
  grep -q '^export:' "$docs/consumer.log" 2>/dev/null || die "age $age: the app did not report an export (see $docs/consumer.log)"
  echo "$docs"
}
verify() { # <dir> -> snarkjs output; non-zero if it fails
  ( cd "$1" && "${SNARKJS[@]}" groth16 verify "$VKEY" public.json proof.json 2>&1 | sed 's/\x1b\[[0-9;]*m//g' )
}
mkdir -p "$WORK/out/25" "$WORK/out/10"
echo "==> simulator run: age 25 (eligible)"
D="$(run_age 25)"; grep -q 'signals=\["1", "18"\]' "$D/consumer.log" || { cat "$D/consumer.log"; die "age 25 did not give signals [1,18]"; }
cp "$D/proof.json" "$D/public.json" "$WORK/out/25/"
echo "==> simulator run: age 10 (ineligible)"
D="$(run_age 10)"; grep -q 'signals=\["0", "18"\]' "$D/consumer.log" || { cat "$D/consumer.log"; die "age 10 did not give signals [0,18]"; }
cp "$D/proof.json" "$D/public.json" "$WORK/out/10/"
echo "  public signals: eligible $(tr -d ' \n' < "$WORK/out/25/public.json"), ineligible $(tr -d ' \n' < "$WORK/out/10/public.json")"
[ "$(tr -d ' \n' < "$WORK/out/25/public.json")" = '["1","18"]' ] && [ "$(tr -d ' \n' < "$WORK/out/10/public.json")" = '["0","18"]' ] || die "unexpected exported public signals"
! cmp -s "$WORK/out/25/proof.json" "$WORK/out/10/proof.json" || die "the two proofs are identical"

echo "==> snarkjs groth16 verify"
for a in 25 10; do
  out="$(verify "$WORK/out/$a")" || { echo "$out" >&2; die "snarkjs rejected the age $a proof"; }
  grep -q 'OK!' <<<"$out" || { echo "$out" >&2; die "snarkjs did not report OK for the age $a proof"; }
  echo "  age $a: snarkjs OK"
done
echo "==> tamper control: the age-10 proof with the public signals of the age-25 proof"
mkdir -p "$WORK/out/tamper"; cp "$WORK/out/10/proof.json" "$WORK/out/tamper/proof.json"; cp "$WORK/out/25/public.json" "$WORK/out/tamper/public.json"
if out="$(verify "$WORK/out/tamper")"; then echo "$out" >&2; die "the tampered public signals were ACCEPTED"; fi
grep -q 'Invalid proof' <<<"$out" || { echo "$out" >&2; die "tamper check failed for an unexpected reason"; }
echo "  tampered public signals rejected (Invalid proof)"

OK=1
echo
echo "PASSED: $BANNER"
echo "  package: $REPO_URL @ $VERSION"
echo "  simulator: $UDID; Xcode: $(xcodebuild -version | head -1); not tested: Xcode 16.x, iOS below 27, a physical device"
