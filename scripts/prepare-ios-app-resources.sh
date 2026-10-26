#!/usr/bin/env bash
# Prepare (or check) the two resources the iOS age-check app bundles:
#
#   examples/ios-age-app/AgeCheckApp/Resources/age_check.wasm
#       a byte-for-byte copy of circuits/age_check/age_check_js/age_check.wasm
#   examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact
#       the serialized ProvingArtifact exported from circuits/age_check/age_check_final.zkey
#
# The app never bundles or reads the .zkey; the artifact is what the portable
# prover loads.
#
# Usage:
#   scripts/prepare-ios-app-resources.sh           # write the files if missing or different, then verify
#   scripts/prepare-ios-app-resources.sh --check   # verify only; never writes into the source tree
#
# Verification, in both modes:
#   * the WASM equals the circuit's generated WASM;
#   * the artifact equals a fresh export from the zkey, and two fresh exports are
#     identical (the export is deterministic, which is what makes committing the
#     artifact safe);
#   * Resources/ holds nothing but the two files (a stray .DS_Store is ignored).
#     Unexpected files are reported, never deleted.
#
# Scratch exports go under Cargo's target directory. Nothing else is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

MODE=write
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  *) die "usage: $0 [--check]" ;;
esac
[ $# -le 1 ] || die "usage: $0 [--check]"

for tool in cargo cmp shasum; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

CIRCUIT="$ROOT/circuits/age_check"
SRC_WASM="$CIRCUIT/age_check_js/age_check.wasm"
SRC_ZKEY="$CIRCUIT/age_check_final.zkey"
RES="$ROOT/examples/ios-age-app/AgeCheckApp/Resources"
EXPECTED="age_check.artifact age_check.wasm"

[ -s "$SRC_WASM" ] || die "circuit WASM not found or empty: $SRC_WASM (compile the circuit with circom first)"
[ -s "$SRC_ZKEY" ] || die "zkey not found or empty: $SRC_ZKEY"

TARGET="$(target_dir)"
mkdir -p "$TARGET/uniffi"
WORK="$(mktemp -d "$TARGET/uniffi/app-resources.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

echo "==> building export_artifact"
# Build output (including known upstream warnings) goes to a log, shown on failure.
EXPORTER="$TARGET/debug/export_artifact"
cargo build -q -p laniakea-cli --bin export_artifact >"$WORK/build.log" 2>&1 \
  || { cat "$WORK/build.log" >&2; die "building export_artifact failed"; }
[ -x "$EXPORTER" ] || die "expected $EXPORTER after the build"

echo "==> exporting the proving artifact twice from $(basename "$SRC_ZKEY")"
for n in 1 2; do
  "$EXPORTER" "$SRC_ZKEY" "$WORK/export$n.artifact" >/dev/null || die "export_artifact failed"
  [ -s "$WORK/export$n.artifact" ] || die "export_artifact produced no output"
done
cmp -s "$WORK/export1.artifact" "$WORK/export2.artifact" \
  || die "two exports of the same zkey differ: the export is not deterministic, so a committed artifact cannot be checked"
FRESH="$WORK/export1.artifact"

# canonical source for each resource
source_of() {
  case "$1" in
    age_check.wasm) echo "$SRC_WASM" ;;
    age_check.artifact) echo "$FRESH" ;;
    *) die "internal: no source for $1" ;;
  esac
}

if [ "$MODE" = write ]; then
  if [ -L "$RES" ]; then die "refusing to write through a symlink: $RES"; fi
  mkdir -p "$RES"
  for f in $EXPECTED; do
    src="$(source_of "$f")"
    if [ -L "$RES/$f" ]; then die "refusing to overwrite a symlink: $RES/$f"; fi
    if [ -f "$RES/$f" ] && cmp -s "$src" "$RES/$f"; then
      echo "    unchanged  $f"
    else
      # write next to the destination, then rename: no half-written file on failure
      cp "$src" "$RES/.$f.tmp"
      mv -f "$RES/.$f.tmp" "$RES/$f"
      echo "    wrote      $f"
    fi
  done
fi

echo "==> verifying $RES"
[ -d "$RES" ] || die "$RES does not exist (run without --check to create it)"
fail=0
for f in $EXPECTED; do
  src="$(source_of "$f")"
  if [ ! -f "$RES/$f" ] || [ -L "$RES/$f" ]; then
    echo "    MISSING    $f (or not a regular file)" >&2; fail=1
  elif ! cmp -s "$src" "$RES/$f"; then
    echo "    DIFFERS    $f does not match $( [ "$f" = age_check.wasm ] && echo "$SRC_WASM" || echo "a fresh export of $SRC_ZKEY" )" >&2; fail=1
  else
    printf '    ok         %-20s %7s bytes  sha256 %s\n' "$f" "$(stat -f %z "$RES/$f")" "$(shasum -a 256 "$RES/$f" | awk '{print $1}')"
  fi
done
# Anything else in Resources/ would be bundled too. Report it; never delete it.
extra="$(cd "$RES" && find . -mindepth 1 -maxdepth 1 ! -name .DS_Store ! -name age_check.wasm ! -name age_check.artifact | sed 's|^\./||' || true)"
if [ -n "$extra" ]; then
  echo "    UNEXPECTED entries in Resources/ (not removed):" >&2
  printf '%s\n' "$extra" | sed 's/^/      /' >&2
  fail=1
fi
[ "$fail" -eq 0 ] || die "resource verification failed ($MODE mode)"
echo "==> OK: resources match the circuit WASM and a fresh deterministic export"
