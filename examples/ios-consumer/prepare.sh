#!/usr/bin/env bash
# Copies a compatible circuit (a proving .artifact and its circuit .wasm) into the app's
# Resources as age_check.artifact / age_check.wasm, which is where ProofModel looks.
# Nothing is committed: LaniakeaConsumer/Resources/ is git-ignored.
#
# Usage:
#   examples/ios-consumer/prepare.sh [<circuit.artifact> <circuit.wasm>]
# With no arguments it uses the repository's development age_check files
# (examples/ios-age-app/AgeCheckApp/Resources), for local testing only. Their licensing
# has not been cleared for redistribution, so this app does not ship them: supply your
# own compatible files for anything beyond local testing. The app expects the age_check
# input signals (age, threshold) and two public signals.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
if [ "$#" -eq 2 ]; then ART="$1"; WASM="$2"
elif [ "$#" -eq 0 ]; then
  ART="$ROOT/examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact"
  WASM="$ROOT/examples/ios-age-app/AgeCheckApp/Resources/age_check.wasm"
else echo "usage: $0 [<circuit.artifact> <circuit.wasm>]" >&2; exit 64; fi
[ -s "$ART" ] || { echo "error: not a file: $ART" >&2; exit 1; }
[ -s "$WASM" ] || { echo "error: not a file: $WASM" >&2; exit 1; }
mkdir -p "$HERE/LaniakeaConsumer/Resources"
cp "$ART" "$HERE/LaniakeaConsumer/Resources/age_check.artifact"
cp "$WASM" "$HERE/LaniakeaConsumer/Resources/age_check.wasm"
echo "OK: circuit files copied to LaniakeaConsumer/Resources/"
