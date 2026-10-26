#!/usr/bin/env bash
# Build the age-check app for the iOS Simulator, install it on a booted simulator
# and drive it through four scenarios, checking what the app reports.
#
# Usage:
#   scripts/package-xcframework.sh        # first: builds laniakeaFFI.xcframework + LaniakeaKit
#   scripts/run-ios-sim-app.sh            # uses the one booted simulator
#   SIM_DEVICE=<udid> scripts/run-ios-sim-app.sh
#
# This is a scripted development harness, NOT the Xcode project workflow (see
# examples/ios-age-app/README.md). It exists because there is no supported way to
# create an .xcodeproj from the command line and `simctl` cannot tap or type. It:
#   * compiles LaniakeaKit's Swift sources (Sources/Laniakea/laniakea.swift) as
#     module `Laniakea`, and the app's sources against it, with swiftc for the
#     simulator SDK (Debug: -Onone, DEBUG defined);
#   * links the Rust static library from the XCFramework's simulator slice (the
#     real one; never a host library);
#   * writes Info.plist, copies the two resources, ad-hoc signs the bundle;
#   * installs it and launches it once per scenario with -AgeCheckAutoProveAge
#     (a DEBUG-only launch option, see AgeCheckApp.swift), reading the app's
#     "AGECHECK ..." trace lines from stderr and taking a screenshot.
#
# Scenarios: 25 -> eligible ["1","18"]; 10 -> not eligible ["0","18"];
# 256 and abc -> rejected by the app before reaching the prover.
#
# Output: <cargo target dir>/uniffi/ios-app-sim/ (app bundle, logs, screenshots).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

[ "$(uname -s)" = "Darwin" ] || die "needs a macOS host"
[ "$(uname -m)" = "arm64" ] || die "this harness builds for arm64 simulators (Apple silicon host)"
for tool in xcrun xcodebuild swiftc plutil codesign python3 nm; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild is not usable (full Xcode is required)"

ios_layout   # MIN, TARGET, STAGE: the package built by package-xcframework.sh
PKG="$STAGE/LaniakeaKit"
XCF="$PKG/laniakeaFFI.xcframework"
BINDING="$PKG/Sources/Laniakea/laniakea.swift"
[ -f "$PKG/Package.swift" ] && [ -f "$XCF/Info.plist" ] && [ -f "$BINDING" ] \
  || die "LaniakeaKit not found in $PKG; run scripts/package-xcframework.sh first"

APP_SRC_DIR="$ROOT/examples/ios-age-app/AgeCheckApp"
APP_MIN="${APP_DEPLOYMENT_TARGET:-16.0}"   # SwiftUI APIs used need iOS 16
BUNDLE_ID="${BUNDLE_ID:-dev.laniakea.AgeCheckApp}"
WORK="$TARGET/uniffi/ios-app-sim"
APP="$WORK/AgeCheckApp.app"
TRIPLE="arm64-apple-ios$APP_MIN-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
# As Xcode does. Without it the clang link driver falls back to the macOS SDK for
# the SDK version recorded in LC_BUILD_VERSION (and warns -Wincompatible-sysroot).
export SDKROOT="$SDK"

"$ROOT/scripts/prepare-ios-app-resources.sh" --check

# --- the simulator slice of the XCFramework, from its Info.plist
SLICE="$(python3 - "$XCF/Info.plist" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
for lib in info["AvailableLibraries"]:
    if (lib.get("SupportedPlatform") == "ios" and lib.get("SupportedPlatformVariant") == "simulator"
            and "arm64" in lib.get("SupportedArchitectures", [])):
        base = os.path.join(os.path.dirname(path), lib["LibraryIdentifier"])
        print(os.path.join(base, lib["LibraryPath"]))
        print(os.path.join(base, lib["HeadersPath"]))
        break
else:
    sys.exit("no arm64 iOS simulator slice in " + path)
PY
)" || die "could not read the XCFramework's Info.plist"
RUST_LIB="$(sed -n 1p <<<"$SLICE")"
HEADERS="$(sed -n 2p <<<"$SLICE")"
[ -f "$RUST_LIB" ] && [ -f "$HEADERS/module.modulemap" ] || die "simulator slice is incomplete: $RUST_LIB"
echo "==> simulator slice: $RUST_LIB ($(lipo -archs "$RUST_LIB"))"

# --- device
DEVICE_INFO="$(xcrun simctl list devices -j | python3 -c '
import json, os, sys
want = os.environ.get("SIM_DEVICE", "")
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if (want and d["udid"] == want) or (not want and d["state"] == "Booted"):
            found.append((d["udid"], d["name"], runtime.rsplit(".", 1)[-1], d["state"]))
if len(found) != 1:
    sys.exit("expected exactly one %s simulator, found %d; set SIM_DEVICE=<udid>"
             % ("matching" if want else "booted", len(found)))
print("\t".join(found[0]))
')" || die "no usable simulator"
IFS=$'\t' read -r UDID DEV_NAME DEV_RUNTIME DEV_STATE <<<"$DEVICE_INFO"
[ "$DEV_STATE" = Booted ] || die "simulator $DEV_NAME ($UDID) is $DEV_STATE; boot it first"
echo "==> simulator: $DEV_NAME ($DEV_RUNTIME, $UDID)"

rm -rf "$WORK"
mkdir -p "$WORK/mod" "$APP"

COMMON=(-target "$TRIPLE" -sdk "$SDK" -parse-as-library -Xcc -fmodule-map-file="$HEADERS/module.modulemap" -I "$HEADERS")
APP_SRC=(
  "$APP_SRC_DIR/AgeCheckApp.swift"
  "$APP_SRC_DIR/ContentView.swift"
  "$APP_SRC_DIR/AgeProofViewModel.swift"
  "$APP_SRC_DIR/AgeProofService.swift"
  "$APP_SRC_DIR/ProverError+Message.swift"
)

echo "==> compiling module Laniakea from LaniakeaKit (Swift 5 mode, as its manifest says)"
swiftc "${COMMON[@]}" -swift-version 5 -suppress-warnings -Onone -g -module-name Laniakea \
  -emit-library -static -emit-module -emit-module-path "$WORK/mod/Laniakea.swiftmodule" \
  "$BINDING" -o "$WORK/libLaniakea.a"

echo "==> type-checking the app for iOS (warnings are errors)"
for config in "5 complete" "6 -" "6 MainActor"; do
  set -- $config
  flags=(-swift-version "$1")
  [ "$2" = complete ] && flags+=(-strict-concurrency=complete)
  [ "$2" = MainActor ] && flags+=(-default-isolation MainActor)
  for debug in "" "-DDEBUG"; do
    swiftc -typecheck -warnings-as-errors "${COMMON[@]}" "${flags[@]}" ${debug:+"$debug"} -I "$WORK/mod" "${APP_SRC[@]}" \
      || die "type-check failed: ${flags[*]} ${debug:-(release conditions)}"
  done
  echo "    ok  ${flags[*]}  (with and without DEBUG)"
done

echo "==> compiling and linking the app ($TRIPLE, Debug)"
swiftc "${COMMON[@]}" -swift-version 5 -strict-concurrency=complete -warnings-as-errors -DDEBUG -Onone -g \
  -module-name AgeCheckApp -I "$WORK/mod" "${APP_SRC[@]}" \
  -L "$WORK" -lLaniakea "$RUST_LIB" -Xlinker -dead_strip \
  -o "$APP/AgeCheckApp"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Age Check</string>
  <key>CFBundleExecutable</key><string>AgeCheckApp</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>AgeCheckApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>$APP_MIN</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key>
  <dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Info.plist" >/dev/null || die "generated Info.plist is invalid"
cp "$APP_SRC_DIR/Resources/age_check.wasm" "$APP_SRC_DIR/Resources/age_check.artifact" "$APP/"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || die "ad-hoc signing failed"

echo "==> app binary"
printf '    %s bytes  %s (%s, Debug, unstripped)\n' "$(stat -f %z "$APP/AgeCheckApp")" "$APP/AgeCheckApp" "$(lipo -archs "$APP/AgeCheckApp")"
procs="$(nm -u "$APP/AgeCheckApp" | grep -E '^_(fork|execvp?|posix_spawnp?|system)$' | tr '\n' ' ' || true)"
echo "    process-spawning imports left after -dead_strip: ${procs:-none}"
otool -l "$APP/AgeCheckApp" | awk '/LC_BUILD_VERSION/{b=1} b&&/platform|minos|sdk/{printf "    %s %s", $1, $2} b&&/sdk/{print ""; b=0}'

echo "==> installing on $DEV_NAME"
xcrun simctl install "$UDID" "$APP"

# scenario: launch argument, then the trace line that must appear
run_scenario() { # $1 = age text, $2 = name, $3 = required final line (regex)
  local age=$1 name=$2 want=$3 err="$WORK/$2.stderr" out="$WORK/$2.stdout" line i
  xcrun simctl launch --terminate-running-process --stdout="$out" --stderr="$err" \
    "$UDID" "$BUNDLE_ID" -AgeCheckAutoProveAge "$age" >/dev/null
  line=""
  for i in $(seq 1 120); do   # up to 60 s
    line="$(grep -E '^AGECHECK (result|failed|unavailable|input-rejected)' "$err" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] && break
    sleep 0.5
  done
  sleep 1   # let SwiftUI render the final state before the screenshot
  xcrun simctl io "$UDID" screenshot "$WORK/$name.png" >/dev/null 2>&1 || echo "    (screenshot failed)"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "    trace: $(tr '\n' '|' < "$err")"
  [ -n "$line" ] || { echo "  FAIL $name: no result within 60 s"; return 1; }
  if grep -Eq "$want" <<<"$line"; then
    echo "  ok   $name: $line"
  else
    echo "  FAIL $name: expected /$want/, got: $line"; return 1
  fi
}

echo "==> scenarios"
fail=0
run_scenario 25 eligible '^AGECHECK result eligible signals=\["1", "18"\] .* mainActorReleased=true ' || fail=1
run_scenario 10 ineligible '^AGECHECK result notEligible signals=\["0", "18"\] .* mainActorReleased=true ' || fail=1
for name in eligible ineligible; do
  if ! grep -qx 'AGECHECK prover-call mainThread=false' "$WORK/$name.stderr"; then
    echo "  FAIL $name: no evidence that the prover was called off the main thread"; fail=1
  fi
done
run_scenario 256 out-of-range '^AGECHECK input-rejected outOfRange$' || fail=1
run_scenario abc not-a-number '^AGECHECK input-rejected notANumber$' || fail=1
for name in out-of-range not-a-number; do
  if grep -q '^AGECHECK proving' "$WORK/$name.stderr"; then
    echo "  FAIL $name: the prover was invoked"; fail=1
  fi
done

echo "==> screenshots and logs in $WORK"
[ "$fail" -eq 0 ] || die "simulator scenarios failed"
echo "==> OK: built, installed and ran on $DEV_NAME ($DEV_RUNTIME); results as expected"
