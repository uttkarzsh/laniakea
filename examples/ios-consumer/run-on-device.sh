#!/usr/bin/env bash
# Builds the consumer app for a connected iPhone, runs it for an eligible and an ineligible age,
# copies back the exported proofs and the app's log (which has the proving time and memory), and
# verifies both proofs with snarkjs. NOT YET RUN: written while no iPhone was reachable, so treat
# its first run as a test of the script as well.
#
#   DEVELOPMENT_TEAM=<your team id> examples/ios-consumer/run-on-device.sh <device name or UDID>
#
# The device must be unlocked, paired and in Developer Mode (`xcrun devicectl list devices` shows
# it as available). The team ID is yours and is never written into the project. The package must
# resolve: `package-source.sh local` while working in this checkout, or the published version.
# Circuit files: run prepare.sh first (see README.md). Needs snarkjs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEVICE="${1:-}"; [ -n "$DEVICE" ] || { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple developer team ID}"
VKEY="${VKEY:-$ROOT/circuits/age_check/verification_key.json}"
SNARKJS=(snarkjs); command -v snarkjs >/dev/null || SNARKJS=(npx --no-install snarkjs)
BUNDLE=dev.laniakea.LaniakeaConsumer
WORK="$(mktemp -d "${TMPDIR:-/tmp}/laniakea-device.XXXXXX")"; echo "work directory: $WORK"

UDID="$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEVICE" '$0 ~ d {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{20,}$/) {print $i; exit}}')"
[ -n "$UDID" ] || { echo "error: device '$DEVICE' not found (xcrun devicectl list devices)" >&2; exit 1; }
# State column: "available", "available (paired)" or "connected" (not "unavailable").
xcrun devicectl list devices 2>/dev/null | grep -Eq "$UDID.*[[:space:]](available|connected)([[:space:]]|$)" \
  || { echo "error: $UDID is not available (unlocked, connected, Developer Mode on?)" >&2; exit 1; }

echo "==> building for $UDID"
xcodebuild -project "$HERE/LaniakeaConsumer.xcodeproj" -scheme LaniakeaConsumer -destination "id=$UDID" \
  -derivedDataPath "$WORK/dd" -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build > "$WORK/build.log" 2>&1 \
  || { grep -E 'error:' "$WORK/build.log" | head >&2; echo "build failed: $WORK/build.log" >&2; exit 1; }
APP="$(find "$WORK/dd/Build/Products" -name LaniakeaConsumer.app -path '*iphoneos*' | head -1)"
xcrun devicectl device install app --device "$UDID" "$APP" > "$WORK/install.log" 2>&1 || { cat "$WORK/install.log" >&2; exit 1; }

for age in 25 10; do
  echo "==> age $age"
  xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE" -ConsumerAutoAge "$age" -ConsumerAutoExport 1 > "$WORK/launch-$age.log" 2>&1 \
    || { cat "$WORK/launch-$age.log" >&2; exit 1; }
  mkdir -p "$WORK/out/$age"
  for _ in $(seq 1 60); do   # the app writes consumer.log last
    xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source Documents/consumer.log --destination "$WORK/out/$age/consumer.log" >/dev/null 2>&1 && grep -q '^export:' "$WORK/out/$age/consumer.log" && break
    sleep 2
  done
  grep -q '^export:' "$WORK/out/$age/consumer.log" || { echo "error: no result for age $age" >&2; exit 1; }
  for f in proof.json public.json; do
    xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source "Documents/$f" --destination "$WORK/out/$age/$f" >/dev/null
  done
  head -1 "$WORK/out/$age/consumer.log"
  ( cd "$WORK/out/$age" && "${SNARKJS[@]}" groth16 verify "$VKEY" public.json proof.json 2>&1 | sed 's/\x1b\[[0-9;]*m//g' )
done

echo "==> tamper control (age-10 proof with the age-25 public signals)"
mkdir -p "$WORK/out/tamper"; cp "$WORK/out/10/proof.json" "$WORK/out/tamper/"; cp "$WORK/out/25/public.json" "$WORK/out/tamper/"
if ( cd "$WORK/out/tamper" && "${SNARKJS[@]}" groth16 verify "$VKEY" public.json proof.json ) >/dev/null 2>&1; then
  echo "error: tampered signals were accepted" >&2; exit 1
fi
echo "tampered signals rejected"
echo "device: $(xcrun devicectl device info details --device "$UDID" 2>/dev/null | grep -E 'marketingName|osVersionNumber|productType' | tr -s ' ' | tr '\n' ';')"
echo "results kept in $WORK/out"
