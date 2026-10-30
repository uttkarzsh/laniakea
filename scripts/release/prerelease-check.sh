#!/usr/bin/env bash
# One command for the checks to run before a release is published.
#
#   scripts/release/prerelease-check.sh <version>        e.g. 0.1.0-rc.1
#   SIM_DEVICE=<udid> scripts/release/prerelease-check.sh <version>   (default: the one booted simulator)
#
# Requires a clean working tree on the commit to be released, Package.swift in its development
# (local) form, full Xcode with an iOS simulator runtime, snarkjs and a booted simulator. Runs, in
# order, logging each step to a temporary directory and continuing after a failure: formatting,
# Rust tests, binding consistency, THIRD_PARTY_NOTICES.md freshness, artifact resource consistency,
# verifying-key and circuit-behavior checks, Swift SDK and app-logic tests, build-asset.sh (which
# also validates the ZIP), the offline consumer rehearsal, generic iOS Simulator and generic iOS
# (signing off) builds, and the demo simulator run. Takes several minutes.
#
# It does not test the HTTPS download of the release asset (scripts/release/validate-consumer.sh
# --remote, or --rehearse with ASSET_URL_BASE, README.md "Releasing"), other Xcode or iOS versions, or
# physical devices. It also reports, without failing, whether LICENSE and THIRD_PARTY_NOTICES.md exist.
#
# Exit status: 0 = every step passed; 1 = a step failed. It never tags, commits, pushes, uploads or
# publishes. dist/<version>/ is left in place when build-asset.sh succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../lib/common.sh
. "$ROOT/scripts/lib/common.sh"

[ "$#" -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 64; }
VERSION="$1"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$' <<<"$VERSION" || die "version '$VERSION' is not SemVer"
for tool in git cargo swift xcodebuild xcrun python3 snarkjs; do command -v "$tool" >/dev/null || die "$tool not found"; done
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean; the checks must run on the commit to be released"
grep -Eq '^ *\.binaryTarget\(name: "LaniakeaRustLib", path: "Binaries/LaniakeaRustLib\.xcframework"\),$' Package.swift \
  || die "Package.swift is not in its development form (scripts/release/set-binary-target.sh --local)"
[ ! -e "dist/$VERSION" ] || die "dist/$VERSION already exists"
UDID="${SIM_DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
[ -n "$UDID" ] || die "no booted simulator; boot one or set SIM_DEVICE=<udid>"
export SIM_DEVICE="$UDID"

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/laniakea-prerelease.XXXXXX")"
COMMIT="$(git rev-parse HEAD)"
echo "release candidate: $VERSION  commit: $COMMIT  simulator: $UDID"
echo "logs: $LOGS"
echo

RESULTS=(); FAILED=0; N=0
step() { # <label> <command...>
  local label="$1"; shift
  N=$((N + 1))
  local log="$LOGS/$(printf '%02d' "$N")-$(tr -c 'A-Za-z0-9' '-' <<<"$label").log" t0=$SECONDS
  printf '%-58s ' "$label"
  if "$@" >"$log" 2>&1; then
    printf 'PASS  (%ss)\n' "$((SECONDS - t0))"; RESULTS+=("PASS  $label")
  else
    printf 'FAIL  (%ss)  log: %s\n' "$((SECONDS - t0))" "$log"; RESULTS+=("FAIL  $label"); FAILED=$((FAILED + 1))
    tail -5 "$log" | sed 's/^/        /'
  fi
}

step "cargo fmt --check" cargo fmt --all --check
step "cargo test (workspace, without ark-circom)" cargo test --locked --offline --workspace --exclude ark-circom
step "scripts/check-bindings.sh" scripts/check-bindings.sh
step "THIRD_PARTY_NOTICES.md is current" scripts/release/third-party-notices.py --check
step "scripts/prepare-ios-app-resources.sh --check" scripts/prepare-ios-app-resources.sh --check
step "scripts/check-vk-consistency.sh" env REQUIRE_SNARKJS=1 scripts/check-vk-consistency.sh
step "scripts/check-circuit-behavior.sh" env REQUIRE_SNARKJS=1 scripts/check-circuit-behavior.sh
step "scripts/swift-sdk-test.sh" env REQUIRE_SNARKJS=1 scripts/swift-sdk-test.sh
step "scripts/swift-app-logic-test.sh" env REQUIRE_SNARKJS=1 scripts/swift-app-logic-test.sh

# A LICENSE file is wanted in the asset but is the maintainer's to add (README.md "License"); the
# asset is still built without one, with a warning from build-asset.sh.
NOTICE_ENV=0
[ -n "$(git ls-files -- 'LICENSE*')" ] && [ -n "$(git ls-files -- 'THIRD_PARTY_NOTICES*')" ] && NOTICE_ENV=1
step "build-asset.sh $VERSION (+ ZIP validation)" env REQUIRE_NOTICES="$NOTICE_ENV" scripts/release/build-asset.sh "$VERSION"
if [ -d "dist/$VERSION" ]; then
  step "validate-consumer.sh --rehearse $VERSION" scripts/release/validate-consumer.sh --rehearse "$VERSION"
else
  RESULTS+=("SKIP  validate-consumer.sh --rehearse (no asset was built)"); FAILED=$((FAILED + 1))
fi
DD="$LOGS/derived-data"
step "xcodebuild Laniakea, generic iOS Simulator" xcodebuild -scheme Laniakea -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD/sim" build
step "xcodebuild Laniakea, generic iOS, signing off" xcodebuild -scheme Laniakea -destination 'generic/platform=iOS' -derivedDataPath "$DD/dev" CODE_SIGNING_ALLOWED=NO build
step "scripts/run-ios-sim-app.sh (demo on the simulator)" scripts/run-ios-sim-app.sh
rm -rf .build .swiftpm
[ -z "$(git status --porcelain)" ] || { RESULTS+=("FAIL  the working tree is clean after the run"); FAILED=$((FAILED + 1)); }

echo
echo "== steps"; printf '%s\n' "${RESULTS[@]}"
echo
[ -n "$(git ls-files -- 'LICENSE*')" ] && echo "LICENSE: present" || echo "LICENSE: not present yet (README.md "License")"
[ -n "$(git ls-files -- 'THIRD_PARTY_NOTICES*')" ] && echo "THIRD_PARTY_NOTICES.md: present" || echo "THIRD_PARTY_NOTICES.md: not present"
echo "not covered: HTTPS download of the asset, Xcode 16.x, iOS below 27, physical devices"
echo "candidate asset: dist/$VERSION (if built).  Logs: $LOGS"
if [ "$FAILED" -gt 0 ]; then echo "RESULT: $FAILED step(s) failed"; exit 1; fi
echo "RESULT: all steps passed"
