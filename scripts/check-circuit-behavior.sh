#!/usr/bin/env bash
# Pin and independently cross-check what the committed age_check circuit actually does
# (it does NOT require out == 1 and does NOT range-check age to 8 bits; see the header
# of crates/laniakea-core/tests/age_check_behavior.rs).
#
# Usage:
#   scripts/check-circuit-behavior.sh                    # snarkjs missing -> that part SKIPPED, exit 0
#   REQUIRE_SNARKJS=1 scripts/check-circuit-behavior.sh  # strict (CI): a missing snarkjs is an error
#
# Steps:
#   1. cargo test -p laniakea-core --test age_check_behavior, which also writes the
#      proofs it marks to a temporary directory (LANIAKEA_PROOF_DIR);
#   2. snarkjs verifies each of those proofs with circuits/age_check/verification_key.json;
#   3. snarkjs's own JavaScript witness calculator, run on the same age_check.wasm,
#      must agree about the range boundary: 273 and p-238 are accepted (with
#      out = 1 and 0), 274 and p-239 are rejected with an assertion failure.
#
# Nothing under circuits/ is modified; everything is written to a temporary directory.
# This documents current behavior. It does not make the circuit secure or correct.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

command -v cargo >/dev/null || die "cargo not found"
command -v python3 >/dev/null || die "python3 not found"

CIRCUIT="$ROOT/circuits/age_check"
VK="$CIRCUIT/verification_key.json"
WASM="$CIRCUIT/age_check_js/age_check.wasm"
for f in "$VK" "$WASM" "$CIRCUIT/age_check_final.zkey"; do
  [ -s "$f" ] || die "missing or empty input: $f"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rust: pinned behavior of the circuit"
LANIAKEA_PROOF_DIR="$WORK/proofs" cargo test -q -p laniakea-core --test age_check_behavior \
  || die "age_check behavior tests failed (the circuit's observable behavior changed, or an input is missing)"

echo "==> snarkjs"
if ! command -v snarkjs >/dev/null; then
  if [ "${REQUIRE_SNARKJS:-0}" = "1" ]; then
    die "REQUIRE_SNARKJS=1 but snarkjs is not installed; independent verification was NOT performed"
  fi
  echo "INDEPENDENT VERIFICATION: SKIPPED (snarkjs not installed); only the Rust checks ran" >&2
  exit 0
fi

n=0
for proof in "$WORK"/proofs/*.proof.json; do
  [ -e "$proof" ] || die "the Rust test wrote no proofs to verify"
  name="$(basename "$proof" .proof.json)"
  snarkjs groth16 verify "$VK" "$WORK/proofs/$name.public.json" "$proof" >"$WORK/verify.log" 2>&1 \
    || { cat "$WORK/verify.log" >&2; die "snarkjs rejected the proof '$name' (public signals $(tr -d ' \n' < "$WORK/proofs/$name.public.json"))"; }
  echo "    snarkjs accepted '$name' (public signals $(tr -d ' \n' < "$WORK/proofs/$name.public.json"))"
  n=$((n + 1))
done
[ "$n" -eq 7 ] || die "expected 7 recorded proofs, found $n"

# snarkjs's JS witness calculator on the same WASM: accepted or rejected, and out.
P=21888242871839275222246405745257275088548364400416034343698204186575808495617
minus() { python3 -I -c 'import sys; print(int(sys.argv[1]) - int(sys.argv[2]))' "$P" "$1"; }
witness_out() { # <age> -> prints out, or REJECTED
  python3 -I -c 'import json,sys; json.dump({"age": sys.argv[1], "threshold": "18"}, open(sys.argv[2], "w"))' "$1" "$WORK/in.json"
  rm -f "$WORK/w.wtns" "$WORK/w.json"
  if ! snarkjs wtns calculate "$WASM" "$WORK/in.json" "$WORK/w.wtns" >"$WORK/wtns.log" 2>&1; then
    grep -qi "assert" "$WORK/wtns.log" || { cat "$WORK/wtns.log" >&2; die "snarkjs failed for age $1, but not with an assertion"; }
    echo REJECTED
    return 0
  fi
  snarkjs wtns export json "$WORK/w.wtns" "$WORK/w.json" >/dev/null 2>&1 || die "could not export the witness"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[1])' "$WORK/w.json"
}
expect() { # <label> <age> <expected>
  local got
  got="$(witness_out "$2")"
  [ "$got" = "$3" ] || die "snarkjs witness calculator: $1 gave '$got', expected '$3' (circuit behavior changed?)"
  echo "    snarkjs witness calculator (threshold 18): $1 -> $got"
}
expect "age 25"      25 1
expect "age 10"      10 0
expect "age 273"     273 1
expect "age 274"     274 REJECTED
expect "age p-238"   "$(minus 238)" 0
expect "age p-239"   "$(minus 239)" REJECTED
echo "==> OK: the pinned circuit behavior holds and snarkjs agrees"
