#!/usr/bin/env bash
# Copies a compatible circuit (a proving .artifact, its circuit .wasm and, optionally, its snarkjs
# verification_key.json) into the app's Resources as age_check.artifact / age_check.wasm /
# verification_key.json, which is where ProofModel looks. Without a verification key the app
# still proves; "Verify on this device" is then off.
# Nothing is committed: LaniakeaConsumer/Resources/ is git-ignored.
#
# Usage:
#   examples/ios-consumer/prepare.sh [<circuit.artifact> <circuit.wasm> [<verification_key.json>]]
# With no arguments it uses the repository's development age_check files
# (circuits/age_check/age_check.artifact, age_check_js/age_check.wasm and verification_key.json),
# for local testing only. Their licensing has not been cleared for redistribution, so this app
# does not ship them: supply your own compatible files for anything beyond local testing. The
# app expects the age_check input signals (age, threshold) and two public signals.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VKEY=""
if [ "$#" -eq 2 ] || [ "$#" -eq 3 ]; then ART="$1"; WASM="$2"; VKEY="${3:-}"
elif [ "$#" -eq 0 ]; then
  ART="$ROOT/circuits/age_check/age_check.artifact"
  WASM="$ROOT/circuits/age_check/age_check_js/age_check.wasm"
  VKEY="$ROOT/circuits/age_check/verification_key.json"
else echo "usage: $0 [<circuit.artifact> <circuit.wasm> [<verification_key.json>]]" >&2; exit 64; fi
for f in "$ART" "$WASM" ${VKEY:+"$VKEY"}; do
  [ -s "$f" ] || { echo "error: not a file: $f" >&2; exit 1; }
done
RES="$HERE/LaniakeaConsumer/Resources"
mkdir -p "$RES"
cp "$ART" "$RES/age_check.artifact"
cp "$WASM" "$RES/age_check.wasm"
if [ -n "$VKEY" ]; then
  cp "$VKEY" "$RES/verification_key.json"
  echo "OK: circuit files and verification key copied to LaniakeaConsumer/Resources/"
else
  # never leave a key from another circuit next to these files
  rm -f "$RES/verification_key.json"
  echo "OK: circuit files copied to LaniakeaConsumer/Resources/ (no verification key: on-device verification off)"
fi
