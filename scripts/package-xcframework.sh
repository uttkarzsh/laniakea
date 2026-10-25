#!/usr/bin/env bash
# Package the staged iOS static libraries into laniakeaFFI.xcframework and assemble
# a Swift package around it. Needs full Xcode (xcodebuild).
#
# Usage:
#   scripts/package-xcframework.sh
#   INCLUDE_X86_64_SIM=1 scripts/package-xcframework.sh   # Intel simulator too
#
# Exit codes: 0 = XCFramework and package created; 1 = error;
#             3 = BLOCKED: everything up to packaging succeeded, but xcodebuild is
#                 unavailable. No XCFramework is created in that case.
#
# Outputs, under Cargo's target directory:
#   <target>/uniffi/ios-<min>/laniakeaFFI.xcframework
#   <target>/uniffi/ios-<min>/LaniakeaKit/  (Package.swift, Sources/Laniakea/laniakea.swift,
#                                            laniakeaFFI.xcframework)
# <min> is IPHONEOS_DEPLOYMENT_TARGET (default 14.0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

"$ROOT/scripts/build-ios.sh"

ios_layout
BIND="$TARGET/uniffi/swift"
XCF="$STAGE/laniakeaFFI.xcframework"
PKG="$STAGE/LaniakeaKit"
LIBNAME=liblaniakea_uniffi.a

if ! xcodebuild -version >/dev/null 2>&1; then
  {
    echo
    echo "BLOCKED: xcodebuild is not usable (full Xcode is not installed or not selected)."
    echo "The static libraries and headers are built and verified in:"
    echo "  $STAGE"
    echo "No XCFramework was created. On a machine with Xcode, run this script again, or run:"
    echo "  xcodebuild -create-xcframework \\"
    echo "    -library \"$STAGE/device/$LIBNAME\" -headers \"$STAGE/headers\" \\"
    echo "    -library \"$STAGE/simulator/$LIBNAME\" -headers \"$STAGE/headers\" \\"
    echo "    -output \"$XCF\""
  } >&2
  exit 3
fi

echo "==> xcodebuild -create-xcframework"
rm -rf "$XCF"   # only the output path this script owns
xcodebuild -create-xcframework \
  -library "$STAGE/device/$LIBNAME" -headers "$STAGE/headers" \
  -library "$STAGE/simulator/$LIBNAME" -headers "$STAGE/headers" \
  -output "$XCF"
[ -f "$XCF/Info.plist" ] || die "xcodebuild did not produce $XCF/Info.plist"

echo "==> assembling Swift package in $PKG"
rm -rf "$PKG"
mkdir -p "$PKG/Sources/Laniakea"
# The template carries a placeholder so the manifest's platform matches the
# deployment target the libraries were actually built for.
sed "s/@IOS_MIN@/$MIN/g" "$ROOT/swift/LaniakeaKit/Package.swift.template" > "$PKG/Package.swift"
grep -q '@IOS_MIN@' "$PKG/Package.swift" && die "unsubstituted placeholder in Package.swift"
cp "$BIND/laniakea.swift" "$PKG/Sources/Laniakea/laniakea.swift"
cp -R "$XCF" "$PKG/laniakeaFFI.xcframework"
echo "==> OK: add $PKG as a local Swift package dependency in Xcode"
