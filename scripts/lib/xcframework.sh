# Validation of a packaged XCFramework, shared by scripts/package-xcframework.sh and
# scripts/release/build-asset.sh. Source this file; do not execute it. Expects die()
# (scripts/lib/common.sh).

# validate_xcframework <xcf> <stage> <libname> <min> <sim_id> <sim_archs> <tmp>
# Exactly the expected files and slices (platform, variant, architectures), each library
# byte-identical to its counterpart in <stage> (<stage>/device, <stage>/simulator), and
# the platform and minimum OS of this project's own objects. <sim_id> is the simulator
# slice's LibraryIdentifier, <sim_archs> its space-separated architectures; <tmp> is a
# scratch directory.
validate_xcframework() {
  local xcf="$1" stage="$2" lib="$3" min="$4" sim_id="$5" sim_archs="$6" tmp="$7"
  python3 - "$xcf" "$stage" "$lib" "$min" "$sim_id" "$sim_archs" "$tmp" <<'PY' || die "the XCFramework failed validation"
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
}

# verify_binding_matches_xcframework <xcf> <bind_dir> <libname> <tmp>
# The generated Swift binding and C header in <bind_dir> (one generation) must describe
# every library inside the XCFramework: bindings generated from each library must equal
# them byte for byte.
verify_binding_matches_xcframework() {
  local xcf="$1" bind="$2" lib="$3" tmp="$4" f slice chk
  for f in laniakea.swift laniakeaFFI.h; do
    [ -s "$bind/$f" ] || die "missing generated $bind/$f"
  done
  for slice in "$xcf"/*/"$lib"; do
    chk="$tmp/bindgen-$(basename "$(dirname "$slice")")"
    mkdir -p "$chk"
    cargo run -q -p uniffi-bindgen -- generate --library "$slice" --language swift --out-dir "$chk" --no-format >"$chk/bindgen.log" 2>&1 \
      || { cat "$chk/bindgen.log" >&2; die "bindgen could not read the interface from $slice"; }
    for f in laniakea.swift laniakeaFFI.h; do
      cmp -s "$chk/$f" "$bind/$f" || die "$f generated from $slice differs from the one to be installed; the binding and the library do not match"
    done
    echo "    ok  $(basename "$(dirname "$slice")")"
  done
}

# check_no_builder_paths <xcf> <dir>...
# Fails if a library contains one of the given directory names (the builder's home
# directory and repository root): build-ios.sh remaps them with --remap-path-prefix.
check_no_builder_paths() {
  local xcf="$1" lib dir n; shift
  for lib in "$xcf"/*/*.a; do
    for dir in "$@"; do
      n="$(LC_ALL=C grep -a -c -F -- "$dir" "$lib" || true)"
      [ "${n:-0}" = 0 ] || die "$lib still contains $n line(s) with the builder path $dir (check the --remap-path-prefix flags in scripts/build-ios.sh)"
    done
  done
  echo "    ok  no occurrence of: $*"
}
