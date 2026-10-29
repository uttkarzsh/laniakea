#!/usr/bin/env bash
# Phase 6d: macOS host tests for the iOS age-check app's logic
# (examples/ios-age-app/AgeCheckApp/{AgeProofService,ProverError+Message,AgeProofViewModel}.swift).
#
# Usage:
#   scripts/swift-app-logic-test.sh                   # snarkjs missing -> verification SKIPPED, exit 0
#   REQUIRE_SNARKJS=1 scripts/swift-app-logic-test.sh # strict (CI): a missing snarkjs is an error
#
# Steps:
#   1. checks the bundled resources (prepare-ios-app-resources.sh --check);
#   2. builds the generated bindings as a separate `_LaniakeaBindings` module and the SDK
#      (swift/LaniakeaKit/Sources/LaniakeaKit) as module `LaniakeaKit` on top of it, in
#      Swift 5 mode, as the LaniakeaKit package does, so the app code is compiled across
#      a real module boundary with `import LaniakeaKit`;
#   3. type-checks the app logic with warnings as errors in three configurations
#      an Xcode app target may use: Swift 5 + complete concurrency checking,
#      Swift 6, and Swift 6 with MainActor default isolation;
#   4. builds and runs Tests-macOS/ServiceTests.swift against the host library;
#   5. verifies the eligible and the ineligible proof with snarkjs.
#
# Host execution only. The SwiftUI views are iOS-only and are compiled by
# scripts/run-ios-sim-app.sh, not here. Output goes under Cargo's target directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

command -v swiftc >/dev/null || die "swiftc not found (install Xcode or the Command Line Tools)"

TARGET="$(target_dir)"
BIND="$TARGET/uniffi/swift"
LIBDIR="$TARGET/debug"
WORK="$TARGET/uniffi/app-logic"
APP="$ROOT/examples/ios-age-app"
CIRCUIT="$ROOT/circuits/age_check"

echo "==> checking the bundled resources"
"$ROOT/scripts/prepare-ios-app-resources.sh" --check

"$ROOT/scripts/gen-swift-bindings.sh"
[ -f "$LIBDIR/liblaniakea_uniffi.dylib" ] || die "host library missing in $LIBDIR"

rm -rf "$WORK"
mkdir -p "$WORK/mod" "$WORK/out"

echo "==> building the bindings as module _LaniakeaBindings (Swift 5 mode)"
# Generated code: its warnings are UniFFI's, not ours.
swiftc -swift-version 5 -parse-as-library -suppress-warnings -module-name _LaniakeaBindings \
  -emit-library -static -emit-module -emit-module-path "$WORK/mod/_LaniakeaBindings.swiftmodule" \
  -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND" \
  "$BIND/laniakea.swift" -o "$WORK/lib_LaniakeaBindings.a"

SDK_SOURCES=("$ROOT"/swift/LaniakeaKit/Sources/LaniakeaKit/*.swift)
[ -f "${SDK_SOURCES[0]}" ] || die "no Swift sources in swift/LaniakeaKit/Sources/LaniakeaKit"

echo "==> building the SDK as module LaniakeaKit (Swift 5 mode)"
swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -parse-as-library -module-name LaniakeaKit \
  -emit-library -static -emit-module -emit-module-path "$WORK/mod/LaniakeaKit.swiftmodule" \
  -I "$WORK/mod" -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND" \
  "${SDK_SOURCES[@]}" -o "$WORK/libLaniakeaKit.a"

LOGIC=(
  "$APP/AgeCheckApp/AgeProofService.swift"
  "$APP/AgeCheckApp/ProverError+Message.swift"
  "$APP/AgeCheckApp/AgeProofViewModel.swift"
  "$APP/Tests-macOS/ServiceTests.swift"
)
IMPORTS=(-parse-as-library -I "$WORK/mod" -Xcc -fmodule-map-file="$BIND/laniakeaFFI.modulemap" -I "$BIND")

echo "==> type-checking the app logic (warnings are errors)"
for config in "5 complete" "6 -" "6 MainActor"; do
  set -- $config
  flags=(-swift-version "$1")
  [ "$2" = complete ] && flags+=(-strict-concurrency=complete)
  [ "$2" = MainActor ] && flags+=(-default-isolation MainActor)
  for debug in "" "-DDEBUG"; do
    swiftc -typecheck -warnings-as-errors "${flags[@]}" ${debug:+"$debug"} "${IMPORTS[@]}" "${LOGIC[@]}" \
      || die "type-check failed: ${flags[*]} ${debug:-(release conditions)}"
  done
  echo "    ok  ${flags[*]}  (with and without DEBUG)"
done

echo "==> building the tests (Swift 5, complete concurrency checking, DEBUG)"
swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -DDEBUG "${IMPORTS[@]}" \
  "${LOGIC[@]}" \
  -L "$WORK" -lLaniakeaKit -l_LaniakeaBindings -L "$LIBDIR" -llaniakea_uniffi -Xlinker -rpath -Xlinker "$LIBDIR" \
  -o "$WORK/ServiceTests"

echo "==> running"
"$WORK/ServiceTests" "$APP/AgeCheckApp/Resources" "$WORK/out"

echo "==> independent verification of proofs generated through AgeProofService"
if command -v snarkjs >/dev/null; then
  for name in eligible ineligible; do
    # With set -e, a rejected proof aborts here, before any success message.
    snarkjs groth16 verify "$CIRCUIT/verification_key.json" "$WORK/out/$name.public.json" "$WORK/out/$name.proof.json"
    echo "    snarkjs accepted the $name proof (public signals $(tr -d ' \n' < "$WORK/out/$name.public.json"))"
  done
  echo "INDEPENDENT VERIFICATION: snarkjs accepted both proofs, including the valid proof that the condition is false"
elif [ "${REQUIRE_SNARKJS:-0}" = "1" ]; then
  die "REQUIRE_SNARKJS=1 but snarkjs is not installed; independent verification was NOT performed"
else
  echo "INDEPENDENT VERIFICATION: SKIPPED (snarkjs not installed); only proof generation was checked" >&2
fi
