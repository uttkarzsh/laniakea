#!/usr/bin/env bash
# Checks that the committed generated sources equal a fresh generation from the current
# Rust code: the Swift binding (swift/LaniakeaKit/Sources/_LaniakeaBindings/laniakea.swift)
# and the C header (swift/LaniakeaKit/Sources/laniakeaFFI/include/laniakeaFFI.h).
# A remote SwiftPM consumer cannot run UniFFI, so these files must always match the
# library. Writes nothing in the source tree; exits 1 on a difference.
#
# To update them, run scripts/package-xcframework.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

"$ROOT/scripts/gen-swift-bindings.sh" >/dev/null
BIND="$(target_dir)/uniffi/swift"
status=0
check() {
  if cmp -s "$1" "$2"; then echo "    ok  $2 matches a fresh generation"
  else echo "    DIFFERS  $2 (regenerate with scripts/package-xcframework.sh)" >&2; status=1; fi
}
check "$BIND/laniakea.swift" "swift/LaniakeaKit/Sources/_LaniakeaBindings/laniakea.swift"
check "$BIND/laniakeaFFI.h" "swift/LaniakeaKit/Sources/laniakeaFFI/include/laniakeaFFI.h"
[ "$status" = 0 ] && echo "BINDINGS CHECK: PASSED" || die "committed bindings are out of date"
