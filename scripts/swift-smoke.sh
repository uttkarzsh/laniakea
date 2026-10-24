#!/usr/bin/env bash
# Phase 6b smoke test: Swift (macOS host) -> generated UniFFI bindings -> Rust
# prover. Proves age_check, exercises typed errors, then verifies the proof with
# snarkjs if it is installed. Host execution only: no Xcode, no iOS SDK.
#
# Usage:
#   scripts/swift-smoke.sh                   # local use: if snarkjs is missing,
#                                            # independent verification is reported
#                                            # as SKIPPED and the script exits 0
#   REQUIRE_SNARKJS=1 scripts/swift-smoke.sh # strict (CI): a missing snarkjs is an error
#
# If snarkjs is installed and rejects the proof, the script fails in both modes.
# Everything is written under Cargo's target directory (CARGO_TARGET_DIR and
# build.target-dir are honoured).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }
command -v swiftc >/dev/null || die "swiftc not found (install Xcode Command Line Tools)"

# Cargo's real target directory (honours CARGO_TARGET_DIR and build.target-dir).
target_dir() {
  command -v python3 >/dev/null || die "python3 not found (needed to read cargo metadata)"
  cargo metadata --format-version 1 --no-deps --manifest-path "$ROOT/Cargo.toml" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])'
}

TARGET="$(target_dir)"
[ -n "$TARGET" ] || die "could not determine Cargo's target directory"
BIND="$TARGET/uniffi/swift"
WORK="$TARGET/uniffi/smoke"
LIBDIR="$TARGET/debug"
CIRCUIT="$ROOT/circuits/age_check"

"$ROOT/scripts/gen-swift-bindings.sh"
[ -f "$LIBDIR/liblaniakea_uniffi.dylib" ] || die "host library missing in $LIBDIR"
for f in laniakea.swift laniakeaFFI.modulemap; do
  [ -s "$BIND/$f" ] || die "generated binding $BIND/$f is missing"
done

rm -rf "$WORK"; mkdir -p "$WORK"

echo "==> exporting proving artifact from the zkey"
cargo run -q -p laniakea-cli --bin export_artifact -- \
  "$CIRCUIT/age_check_final.zkey" "$WORK/age_check.artifact"

echo "==> compiling Swift (language mode 5)"
# The UniFFI 0.28.3 output does not type-check in Swift 6 mode, so the bindings
# are compiled in Swift 5 mode. -fmodule-map-file points at the generated
# module map without renaming it.
swiftc -swift-version 5 \
  -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND" \
  -L "$LIBDIR" -llaniakea_uniffi -Xlinker -rpath -Xlinker "$LIBDIR" \
  "$BIND/laniakea.swift" "$ROOT/scripts/swift-smoke/main.swift" \
  -o "$WORK/smoke"

echo "==> running"
"$WORK/smoke" "$WORK/age_check.artifact" "$CIRCUIT/age_check_js/age_check.wasm" "$WORK"

echo "==> independent verification"
if command -v snarkjs >/dev/null; then
  # With set -e, a rejected proof aborts here, before any success message.
  snarkjs groth16 verify "$CIRCUIT/verification_key.json" "$WORK/public.json" "$WORK/proof.json"
  echo "INDEPENDENT VERIFICATION: snarkjs accepted the proof produced through Swift"
elif [ "${REQUIRE_SNARKJS:-0}" = "1" ]; then
  die "REQUIRE_SNARKJS=1 but snarkjs is not installed; independent verification was NOT performed"
else
  echo "INDEPENDENT VERIFICATION: SKIPPED (snarkjs not installed); only Swift-side proof generation was checked" >&2
fi
