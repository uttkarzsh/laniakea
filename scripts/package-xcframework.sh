#!/usr/bin/env bash
# Package the staged iOS static libraries into a HEADERLESS laniakeaFFI.xcframework and
# prepare the root Swift package (Package.swift) around it. Needs full Xcode (xcodebuild).
#
# The XCFramework carries no C header and no module map on purpose: Xcode copies every
# XCFramework's headers into one shared include/ directory, so two such packages collide
# ("Multiple commands produce include/module.modulemap"). The header belongs to the
# package's C target (swift/LaniakeaKit/Sources/laniakeaFFI/include) instead.
#
# Usage:
#   scripts/package-xcframework.sh
#   INCLUDE_X86_64_SIM=1 scripts/package-xcframework.sh   # Intel simulator too
#
# Exit codes: 0 = XCFramework and package created; 1 = error;
#             3 = BLOCKED: everything up to packaging succeeded, but xcodebuild is
#                 unavailable. No XCFramework is created in that case.
#
# Everything is assembled and validated in a temporary directory first (inside Binaries/,
# so the final moves are same-filesystem renames). The existing package output is replaced
# only after every check has passed; if anything fails, including the final
# scripts/check-bindings.sh run, the previous output is restored and the temporary
# directory is removed.
#
# Outputs:
#   Binaries/laniakeaFFI.xcframework                    (what the root Package.swift uses; git-ignored)
#   swift/LaniakeaKit/Sources/_LaniakeaBindings/laniakea.swift   (generated; committed)
#   swift/LaniakeaKit/Sources/laniakeaFFI/include/laniakeaFFI.h  (generated; committed)
# <min> is IPHONEOS_DEPLOYMENT_TARGET (default 15.0) and must equal the iOS version in the
# root Package.swift; the script refuses to continue otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

"$ROOT/scripts/build-ios.sh"

ios_layout
BIND="$TARGET/uniffi/swift"
XCF="$STAGE/laniakeaFFI.xcframework"
LIBNAME=liblaniakea_uniffi.a

if ! xcodebuild -version >/dev/null 2>&1; then
  {
    echo
    echo "BLOCKED: xcodebuild is not usable (full Xcode is not installed or not selected)."
    echo "The static libraries and headers are built and verified in:"
    echo "  $STAGE"
    echo "No XCFramework was created. On a machine with Xcode, run this script again, or run:"
    echo "  xcodebuild -create-xcframework \\"
    echo "    -library \"$STAGE/device/$LIBNAME\" \\"
    echo "    -library \"$STAGE/simulator/$LIBNAME\" \\"
    echo "    -output \"$XCF\""
  } >&2
  exit 3
fi

# --- assemble and validate in a temporary directory; nothing existing is touched yet
mkdir -p "$ROOT/Binaries"
TMP="$(mktemp -d "$ROOT/Binaries/.package.XXXXXX")"
INSTALLING=0
SRC_SWIFT="$ROOT/swift/LaniakeaKit/Sources/_LaniakeaBindings/laniakea.swift"
SRC_HEADER="$ROOT/swift/LaniakeaKit/Sources/laniakeaFFI/include/laniakeaFFI.h"
DEST_XCF="$ROOT/Binaries/laniakeaFFI.xcframework"

# Runs on every exit. If we fail after the first existing file was replaced, put the
# previous output back; always remove the temporary directory.
restore_previous() {
  echo "==> restoring the previous package output" >&2
  rm -rf "$DEST_XCF"
  if [ -d "$TMP/prev.xcframework" ]; then mv "$TMP/prev.xcframework" "$DEST_XCF" || echo "WARNING: could not restore $DEST_XCF; the previous copy is in $TMP" >&2; fi
  for pair in "laniakea.swift:$SRC_SWIFT" "laniakeaFFI.h:$SRC_HEADER"; do
    if [ -f "$TMP/prev/${pair%%:*}" ]; then cp -p "$TMP/prev/${pair%%:*}" "${pair#*:}" || echo "WARNING: could not restore ${pair#*:}; the previous copy is in $TMP/prev" >&2; fi
  done
}
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$INSTALLING" = 1 ]; then restore_previous; fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

NEW_XCF="$TMP/laniakeaFFI.xcframework"
echo "==> xcodebuild -create-xcframework (headerless)"
xcodebuild -create-xcframework \
  -library "$STAGE/device/$LIBNAME" \
  -library "$STAGE/simulator/$LIBNAME" \
  -output "$NEW_XCF"
[ -f "$NEW_XCF/Info.plist" ] || die "xcodebuild did not produce $NEW_XCF/Info.plist"
if find "$NEW_XCF" \( -name '*.h' -o -name '*.modulemap' -o -name 'module.map' \) | grep -q .; then
  die "$NEW_XCF contains C headers or module maps; it must be headerless"
fi

echo "==> checking that Package.swift declares iOS $MIN"
grep -Eq "\.iOS\(\"$MIN\"\)" "$ROOT/Package.swift" \
  || die "Package.swift does not declare .iOS(\"$MIN\"); the libraries were built for $MIN. Update the manifest or IPHONEOS_DEPLOYMENT_TARGET."

# The final XCFramework, not the staged libraries it was made from: exactly the expected
# files and slices (platform, variant, architectures), each library byte-identical to its
# staged counterpart, and the deployment target of this project's own objects.
echo "==> validating the final XCFramework"
if [ "${INCLUDE_X86_64_SIM:-0}" = "1" ]; then SIM_ARCHS="arm64 x86_64"; SIM_ID="ios-arm64_x86_64-simulator"; else SIM_ARCHS="arm64"; SIM_ID="ios-arm64-simulator"; fi
python3 - "$NEW_XCF" "$STAGE" "$LIBNAME" "$MIN" "$SIM_ID" "$SIM_ARCHS" "$TMP" <<'PY' || die "the final XCFramework failed validation"
import filecmp, os, plistlib, re, subprocess, sys
xcf, stage, lib, minos, sim_id, sim_archs, tmp = sys.argv[1:8]
want = {  # LibraryIdentifier -> (variant, architectures, staged library)
    "ios-arm64": (None, ["arm64"], os.path.join(stage, "device", lib)),
    sim_id: ("simulator", sorted(sim_archs.split()), os.path.join(stage, "simulator", lib)),
}
def fail(msg): sys.exit("  FAIL: " + msg)
files = sorted(os.path.relpath(os.path.join(d, f), xcf) for d, _, fs in os.walk(xcf) for f in fs)
expected = sorted(["Info.plist"] + [os.path.join(i, lib) for i in want])
if files != expected: fail("XCFramework files are %s, expected %s" % (files, expected))
info = plistlib.load(open(os.path.join(xcf, "Info.plist"), "rb"))
libs = info["AvailableLibraries"]
if sorted(l["LibraryIdentifier"] for l in libs) != sorted(want): fail("slices are %s" % [l["LibraryIdentifier"] for l in libs])
for l in libs:
    ident = l["LibraryIdentifier"]
    variant, archs, staged = want[ident]
    if l.get("SupportedPlatform") != "ios": fail("%s: platform %r" % (ident, l.get("SupportedPlatform")))
    if l.get("SupportedPlatformVariant") != variant: fail("%s: variant %r" % (ident, l.get("SupportedPlatformVariant")))
    if sorted(l["SupportedArchitectures"]) != archs: fail("%s: architectures %r" % (ident, l["SupportedArchitectures"]))
    if l["LibraryPath"] != lib or l.get("BinaryPath", lib) != lib: fail("%s: library path %r" % (ident, l["LibraryPath"]))
    path = os.path.join(xcf, ident, lib)
    if not filecmp.cmp(path, staged, shallow=False): fail("%s differs from the staged library %s" % (ident, staged))
    got = sorted(subprocess.check_output(["lipo", "-archs", path], text=True).split())
    if got != archs: fail("%s: lipo reports %s" % (ident, got))
    # This project's own objects must have been built for exactly this platform and minos.
    platform = {"ios-arm64": "2"}.get(ident, "7")
    work = os.path.join(tmp, "members-" + ident); os.makedirs(work)
    subprocess.check_call(["ar", "-x", os.path.abspath(path)], cwd=work)
    own = [f for f in os.listdir(work) if re.match(r"(laniakea_uniffi|laniakea_core|wasmi_witness)-.*\.o$", f)]
    if not own: fail("%s: no objects of this project's crates found" % ident)
    for f in own:
        out = subprocess.check_output(["otool", "-l", os.path.join(work, f)], text=True)
        m = re.search(r"LC_BUILD_VERSION.*?platform (\S+).*?minos (\S+)", out, re.S)
        if not m or m.group(1) != platform or m.group(2) != minos:
            fail("%s: %s has platform/minos %s, expected %s/%s" % (ident, f, m.groups() if m else None, platform, minos))
    print("  ok  %s: %s, %s, %d own objects at platform %s minos %s, identical to the staged library" % (ident, "ios" + ("-" + variant if variant else ""), "+".join(archs), len(own), platform, minos))
PY

# The generated Swift binding and C header (one generation) must describe the libraries
# inside the final XCFramework: bindings generated from each of its libraries must equal
# them byte for byte.
echo "==> validating that the binding and header belong to the XCFramework's libraries"
for f in laniakea.swift laniakeaFFI.h; do
  [ -s "$BIND/$f" ] || die "missing generated $BIND/$f"
done
for slice in "$NEW_XCF"/*/"$LIBNAME"; do
  chk="$TMP/bindgen-$(basename "$(dirname "$slice")")"
  mkdir -p "$chk"
  cargo run -q -p uniffi-bindgen -- generate --library "$slice" --language swift --out-dir "$chk" --no-format >"$chk/bindgen.log" 2>&1 \
    || { cat "$chk/bindgen.log" >&2; die "bindgen could not read the interface from $slice"; }
  for f in laniakea.swift laniakeaFFI.h; do
    cmp -s "$chk/$f" "$BIND/$f" || die "$f generated from $slice differs from the one to be installed; the binding and the library do not match"
  done
  echo "    ok  $(basename "$(dirname "$slice")")"
done
mkdir -p "$TMP/new" "$TMP/prev"
cp "$BIND/laniakea.swift" "$BIND/laniakeaFFI.h" "$TMP/new/"

# --- install: every check has passed. Previous output is kept in $TMP until the end.
echo "==> installing (previous output is restored if anything below fails)"
INSTALLING=1
mkdir -p "$(dirname "$SRC_SWIFT")" "$(dirname "$SRC_HEADER")"
[ -f "$SRC_SWIFT" ] && cp -p "$SRC_SWIFT" "$TMP/prev/laniakea.swift"
[ -f "$SRC_HEADER" ] && cp -p "$SRC_HEADER" "$TMP/prev/laniakeaFFI.h"
[ -d "$DEST_XCF" ] && mv "$DEST_XCF" "$TMP/prev.xcframework"
mv "$NEW_XCF" "$DEST_XCF"
cp "$TMP/new/laniakea.swift" "$SRC_SWIFT"
cp "$TMP/new/laniakeaFFI.h" "$SRC_HEADER"

# The committed sources must now equal a fresh generation (the check regenerates them).
echo "==> scripts/check-bindings.sh"
"$ROOT/scripts/check-bindings.sh"
INSTALLING=0
echo "==> OK: the root Package.swift ($ROOT) is ready; add it as a local Swift package in Xcode"
