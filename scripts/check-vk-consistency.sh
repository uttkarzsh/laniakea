#!/usr/bin/env bash
# Check that the age_check verifying key is consistent across the repository.
#
# Usage:
#   scripts/check-vk-consistency.sh                    # snarkjs missing -> that part SKIPPED, exit 0
#   REQUIRE_SNARKJS=1 scripts/check-vk-consistency.sh  # strict (CI): a missing snarkjs is an error
#
# Steps:
#   1. cargo test -p laniakea-core --test vk_consistency: the key embedded in
#      circuits/age_check/age_check_final.zkey, the key embedded in the bundled
#      examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact, and
#      circuits/age_check/verification_key.json are the same key, and the JSON's
#      vk_alphabeta_12 is the pairing of its alpha and beta;
#   2. snarkjs derives a verification key from the same .zkey
#      (`snarkjs zkey export verificationkey`) and it must equal the committed
#      verification_key.json exactly (as JSON).
#
# Nothing is regenerated or overwritten: the export goes to a temporary directory.
# This does not check that the .zkey comes from a sound setup (that needs the original
# powers-of-tau file, which the repository does not contain), and it says nothing about
# the circuit's policy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

command -v cargo >/dev/null || die "cargo not found"
command -v python3 >/dev/null || die "python3 not found"

CIRCUIT="$ROOT/circuits/age_check"
ZKEY="$CIRCUIT/age_check_final.zkey"
VK="$CIRCUIT/verification_key.json"
for f in "$ZKEY" "$VK" "$ROOT/examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact"; do
  [ -s "$f" ] || die "missing or empty input: $f"
done

echo "==> Rust: zkey, bundled artifact and verification_key.json hold the same key"
cargo test -q -p laniakea-core --test vk_consistency || die "verifying-key consistency test failed"

echo "==> snarkjs: key derived from the zkey vs the committed verification_key.json"
if ! command -v snarkjs >/dev/null; then
  if [ "${REQUIRE_SNARKJS:-0}" = "1" ]; then
    die "REQUIRE_SNARKJS=1 but snarkjs is not installed; the independent derivation was NOT performed"
  fi
  echo "INDEPENDENT DERIVATION: SKIPPED (snarkjs not installed); only the Rust checks ran" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
snarkjs zkey export verificationkey "$ZKEY" "$WORK/derived.json" >"$WORK/snarkjs.log" 2>&1 \
  || { cat "$WORK/snarkjs.log" >&2; die "snarkjs could not export a verification key from $ZKEY"; }
[ -s "$WORK/derived.json" ] || die "snarkjs produced no verification key"

python3 -I - "$WORK/derived.json" "$VK" <<'PY' || die "verification_key.json does not match the key snarkjs derives from the zkey"
import json, sys
derived, committed = (json.load(open(p)) for p in sys.argv[1:3])
if derived == committed:
    print("    identical (%d top-level fields)" % len(derived))
    sys.exit(0)
bad = sorted(k for k in set(derived) | set(committed) if derived.get(k) != committed.get(k))
print("differing fields: " + ", ".join(bad), file=sys.stderr)
sys.exit(1)
PY
echo "==> OK: verifying key is consistent (zkey = bundled artifact = verification_key.json = snarkjs export)"
