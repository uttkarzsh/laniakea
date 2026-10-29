#!/usr/bin/env bash
# Host tests for the LaniakeaKit Swift layer (swift/LaniakeaKit/Sources/LaniakeaKit:
# Circuit, Prover, Proof, Input, LaniakeaError).
#
# Usage:
#   scripts/swift-sdk-test.sh                    # snarkjs missing -> verification SKIPPED, exit 0
#   REQUIRE_SNARKJS=1 scripts/swift-sdk-test.sh  # strict (CI): a missing snarkjs is an error
#
# Steps:
#   1. builds the generated bindings as module `_LaniakeaBindings` and the Swift layer as module
#      `LaniakeaKit` (Swift 5 mode, as the package's manifest says; the layer with
#      testing enabled so the tests can reach its internal mapping code);
#   2. type-checks the layer, warnings as errors, in the language modes an app may use:
#      Swift 5 with complete concurrency checking, and Swift 6;
#   3. builds and runs swift/LaniakeaKit/Tests-macOS/SDKTests.swift against the host
#      library, with the demo's age_check artifact and WASM (and an unrelated circuit's
#      WASM, to test an artifact paired with the wrong circuit);
#   4. verifies the proofs exported by Proof.write with snarkjs.
#
# Host execution only: the iOS slices are exercised by scripts/run-ios-sim-app.sh.
# Output goes under Cargo's target directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

command -v swiftc >/dev/null || die "swiftc not found (install Xcode or the Command Line Tools)"

TARGET="$(target_dir)"
BIND="$TARGET/uniffi/swift"
LIBDIR="$TARGET/debug"
WORK="$TARGET/uniffi/sdk-test"
KIT="$ROOT/swift/LaniakeaKit"
RESOURCES="$ROOT/examples/ios-age-app/AgeCheckApp/Resources"
CIRCUIT="$ROOT/circuits/age_check"

echo "==> checking the bundled resources"
"$ROOT/scripts/prepare-ios-app-resources.sh" --check

"$ROOT/scripts/gen-swift-bindings.sh"
[ -f "$LIBDIR/liblaniakea_uniffi.dylib" ] || die "host library missing in $LIBDIR"

rm -rf "$WORK"
mkdir -p "$WORK/mod" "$WORK/out"

SOURCES=("$KIT"/Sources/LaniakeaKit/*.swift)
[ -f "${SOURCES[0]}" ] || die "no Swift sources in $KIT/Sources/LaniakeaKit"
IMPORTS=(-I "$WORK/mod" -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND")

echo "==> building the bindings as module _LaniakeaBindings (Swift 5 mode)"
# Generated code: its warnings are UniFFI's, not ours.
swiftc -swift-version 5 -parse-as-library -suppress-warnings -module-name _LaniakeaBindings \
  -emit-library -static -emit-module -emit-module-path "$WORK/mod/_LaniakeaBindings.swiftmodule" \
  -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND" \
  "$BIND/laniakea.swift" -o "$WORK/lib_LaniakeaBindings.a"

echo "==> type-checking LaniakeaKit (warnings are errors)"
for config in "5 complete" "6 -"; do
  set -- $config
  flags=(-swift-version "$1")
  [ "$2" = complete ] && flags+=(-strict-concurrency=complete)
  swiftc -typecheck -warnings-as-errors -parse-as-library -module-name LaniakeaKit "${flags[@]}" "${IMPORTS[@]}" "${SOURCES[@]}" \
    || die "type-check failed: ${flags[*]}"
  echo "    ok  ${flags[*]}"
done

echo "==> building LaniakeaKit as a module (Swift 5 mode, testing enabled)"
swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -parse-as-library -enable-testing -D LANIAKEA_TESTING \
  -module-name LaniakeaKit -emit-library -static -emit-module -emit-module-path "$WORK/mod/LaniakeaKit.swiftmodule" \
  "${IMPORTS[@]}" "${SOURCES[@]}" -o "$WORK/libLaniakeaKit.a"

echo "==> building the tests (Swift 5, complete concurrency checking)"
swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "${IMPORTS[@]}" "$KIT/Tests-macOS/SDKTests.swift" \
  -L "$WORK" -lLaniakeaKit -l_LaniakeaBindings -L "$LIBDIR" -llaniakea_uniffi -Xlinker -rpath -Xlinker "$LIBDIR" \
  -o "$WORK/SDKTests"

echo "==> running"
"$WORK/SDKTests" "$RESOURCES" "$WORK/out" "$ROOT/circuits/witness_probe/witness_probe_js/witness_probe.wasm"

echo "==> independent verification of the files written by Proof.write"
if command -v snarkjs >/dev/null; then
  for name in eligible ineligible; do
    # With set -e, a rejected proof aborts here, before any success message.
    snarkjs groth16 verify "$CIRCUIT/verification_key.json" "$WORK/out/$name.public.json" "$WORK/out/$name.proof.json"
    echo "    snarkjs accepted the $name proof (public signals $(tr -d ' \n' < "$WORK/out/$name.public.json"))"
  done
  echo "INDEPENDENT VERIFICATION: snarkjs accepted both exported proofs"
elif [ "${REQUIRE_SNARKJS:-0}" = "1" ]; then
  die "REQUIRE_SNARKJS=1 but snarkjs is not installed; independent verification was NOT performed"
else
  echo "INDEPENDENT VERIFICATION: SKIPPED (snarkjs not installed); only proof generation and export were checked" >&2
fi
