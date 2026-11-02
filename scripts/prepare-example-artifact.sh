#!/usr/bin/env bash
# Prepare (or check) the committed proving artifact of the development example circuit:
#
#   circuits/age_check/age_check.artifact
#       the serialized ProvingArtifact exported from circuits/age_check/age_check_final.zkey
#
# It is what the tests, the release check (scripts/release/validate-consumer.sh) and
# examples/ios-consumer/prepare.sh bundle next to circuits/age_check/age_check_js/age_check.wasm.
# Apps never read the .zkey; the artifact is what the portable prover loads.
#
# Usage:
#   scripts/prepare-example-artifact.sh           # write the file if missing or different, then verify
#   scripts/prepare-example-artifact.sh --check   # verify only; never writes into the source tree
#
# Verification, in both modes: the artifact equals a fresh export from the zkey, and two
# fresh exports are identical (the export is deterministic, which is what makes committing
# the artifact safe). Scratch exports go under Cargo's target directory.
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
SRC_ZKEY="$CIRCUIT/age_check_final.zkey"
ARTIFACT="$CIRCUIT/age_check.artifact"
[ -s "$SRC_ZKEY" ] || die "zkey not found or empty: $SRC_ZKEY"

TARGET="$(target_dir)"
mkdir -p "$TARGET/uniffi"
WORK="$(mktemp -d "$TARGET/uniffi/example-artifact.XXXXXX")"
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

if [ "$MODE" = write ]; then
  if [ -L "$ARTIFACT" ]; then die "refusing to overwrite a symlink: $ARTIFACT"; fi
  if [ -f "$ARTIFACT" ] && cmp -s "$FRESH" "$ARTIFACT"; then
    echo "    unchanged  $(basename "$ARTIFACT")"
  else
    # write next to the destination, then rename: no half-written file on failure
    cp "$FRESH" "$CIRCUIT/.age_check.artifact.tmp"
    mv -f "$CIRCUIT/.age_check.artifact.tmp" "$ARTIFACT"
    echo "    wrote      $(basename "$ARTIFACT")"
  fi
fi

echo "==> verifying $ARTIFACT"
if [ ! -f "$ARTIFACT" ] || [ -L "$ARTIFACT" ]; then
  die "$ARTIFACT is missing or not a regular file (run without --check to create it)"
fi
cmp -s "$FRESH" "$ARTIFACT" || die "$ARTIFACT does not match a fresh export of $SRC_ZKEY (run without --check to refresh it)"
printf '    ok         %s  %s bytes  sha256 %s\n' "$(basename "$ARTIFACT")" "$(stat -f %z "$ARTIFACT")" "$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "==> OK: the artifact matches a fresh deterministic export"
