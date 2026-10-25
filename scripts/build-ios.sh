#!/usr/bin/env bash
# Build and verify the iOS static libraries for laniakea-uniffi, and stage them
# with the Swift bindings' headers for XCFramework packaging.
#
# Usage:
#   scripts/build-ios.sh                       # device (arm64) + simulator (arm64)
#   INCLUDE_X86_64_SIM=1 scripts/build-ios.sh  # also the Intel simulator (x86_64)
#   IPHONEOS_DEPLOYMENT_TARGET=15.0 scripts/build-ios.sh   # default 14.0
#
# Build artifacts for deployment target X live in their own Cargo target directory,
# <cargo target dir>/ios-X, because cargo does not rebuild when the variable changes.
# Staged output: <cargo target dir>/uniffi/ios-X/.
#
# What it does, in order:
#   1. checks prerequisites and that each Rust target is installed;
#   2. checks, per target, that laniakea-uniffi's iOS dependency graph contains no
#      host-only bindgen/CLI crates and no JIT/Wasmer crates;
#   3. `cargo build -p laniakea-uniffi --target <t> --release` (never --workspace:
#      that would unify uniffi's host-only `cli`/`bindgen` features into the iOS build);
#   4. inspects each library (architecture, exported UniFFI symbols, and the
#      platform and minimum OS of EVERY archive member, classified by content as
#      precompiled sysroot or source-built; see check_members);
#   5. generates the Swift bindings from the host library and checks that bindings
#      generated from the iOS library itself are byte-identical (ABI consistency);
#   6. stages everything under <target>/uniffi/ios-<min>/.
#
# This compiles Rust only. Linking into an app, the simulator and devices need
# Xcode and are NOT exercised here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"

[ "$(uname -s)" = "Darwin" ] || die "iOS packaging needs a macOS host"
# The compiler Cargo will use: $RUSTC when set and non-empty, else rustc.
RUSTC_BIN="${RUSTC:-rustc}"
for tool in cargo nm ar otool lipo "$RUSTC_BIN"; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

DEVICE=aarch64-apple-ios
SIM=aarch64-apple-ios-sim
X86=x86_64-apple-ios
TARGETS="$DEVICE $SIM"
[ "${INCLUDE_X86_64_SIM:-0}" = "1" ] && TARGETS="$TARGETS $X86"

for t in $TARGETS; do
  [ -d "$("$RUSTC_BIN" --print sysroot)/lib/rustlib/$t/lib" ] \
    || die "Rust target $t is not installed for $RUSTC_BIN (rustup target add $t)"
done

ios_layout
export IPHONEOS_DEPLOYMENT_TARGET="$MIN"
LIBNAME=liblaniakea_uniffi.a

# A failed run must not leave output that looks like the result of this run.
clean_stage

# --- 2. dependency isolation (package-specific; never a workspace-wide tree)
FORBIDDEN='^(uniffi_bindgen|uniffi-bindgen|clap|clap_[a-z]+|askama[a-z_]*|goblin|wasmer[a-z_-]*|cranelift[a-z_-]*|wasmtime[a-z_-]*|ark-circom|dynasm[a-z_]*|regalloc[a-z0-9_]*)$'
for t in $TARGETS; do
  echo "==> dependency check ($t)"
  crates="$(cargo tree -p laniakea-uniffi --target "$t" -e normal,build --prefix none --format '{p}' | awk '{print $1}' | sort -u)"
  bad="$(printf '%s\n' "$crates" | grep -E "$FORBIDDEN" || true)"
  [ -z "$bad" ] || die "forbidden crates in the $t graph:
$bad"
  feats="$(cargo tree -p laniakea-uniffi --target "$t" -e features -i uniffi --prefix none 2>/dev/null | grep -E '^uniffi feature' | sort -u || true)"
  if printf '%s\n' "$feats" | grep -Eq 'feature "(cli|bindgen)"'; then
    die "uniffi host-only features (cli/bindgen) are enabled for $t:
$feats"
  fi
done

# --- 3. build
# Both Cargo directories are isolated per deployment target: the final target
# directory (CARGO_TARGET_DIR) and the intermediate build directory
# (CARGO_BUILD_BUILD_DIR / build.build-dir, Cargo >= 1.91). Without the second, a
# user- or CI-configured shared build-dir would let a build for a new deployment
# target reuse objects compiled for the previous one. Inline environment
# variables take precedence over config files.
#
# Every artifact path Cargo reports is then checked to live under IOS_TARGET_DIR;
# if the override did not take effect we stop rather than weaken the isolation.
verify_artifact_paths() { # $1 = JSON message file
  python3 - "$1" "$IOS_TARGET_DIR" <<'PY'
import json, os, sys
msgs, root = sys.argv[1], os.path.realpath(sys.argv[2]) + os.sep
bad, n = [], 0
for line in open(msgs):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") != "compiler-artifact":
        continue
    for f in m.get("filenames", []):
        n += 1
        if not (os.path.realpath(f) + os.sep).startswith(root):
            bad.append(f)
if n == 0:
    sys.exit("no compiler-artifact messages from cargo; cannot verify build isolation")
if bad:
    sys.exit("cargo placed %d artifact(s) outside %s (is a shared build.build-dir overriding "
             "CARGO_BUILD_BUILD_DIR?), e.g.:\n  %s" % (len(bad), root, "\n  ".join(bad[:3])))
print("    %d artifact paths, all under the isolated directory" % n)
PY
}
for t in $TARGETS; do
  echo "==> cargo build -p laniakea-uniffi --target $t --release (iOS min $MIN, target+build dir $IOS_TARGET_DIR)"
  msgs="$(mktemp)"
  CARGO_TARGET_DIR="$IOS_TARGET_DIR" CARGO_BUILD_BUILD_DIR="$IOS_TARGET_DIR" \
    cargo build -p laniakea-uniffi --target "$t" --release --message-format=json-render-diagnostics >"$msgs" \
    || { rm -f "$msgs"; die "cargo build failed for $t"; }
  verify_artifact_paths "$msgs" || { rm -f "$msgs"; die "build isolation check failed for $t"; }
  rm -f "$msgs"
done

# --- 4. inspect
lib_of() { echo "$IOS_TARGET_DIR/$1/release/$LIBNAME"; }
EXPECT_SYMS="_ffi_laniakea_uniffi_uniffi_contract_version _uniffi_laniakea_uniffi_fn_constructor_laniakeaprover_new _uniffi_laniakea_uniffi_fn_method_laniakeaprover_prove _uniffi_laniakea_uniffi_checksum_method_laniakeaprover_prove"

expected_arch() { case "$1" in x86_64-*) echo x86_64 ;; *) echo arm64 ;; esac; }
expected_platform() { case "$1" in aarch64-apple-ios) echo 2 ;; *) echo 7 ;; esac; } # 2=iOS, 7=iOS Simulator
# Legacy LC_VERSION_MIN_IPHONEOS (no platform field) is what precompiled Rust
# std objects use for these targets; it is meaningless for arm64 simulator code.
legacy_min_ok() { case "$1" in aarch64-apple-ios-sim) echo 0 ;; *) echo 1 ;; esac; }

# SHA-256 of every object in the active toolchain's precompiled std/compiler
# builtins for target $1 (the .rlib archives in the sysroot), one per line.
# Classification is by content, never by file name.
sysroot_hashes() {
  local t=$1 dir r d n=0 rc=0
  dir="$("$RUSTC_BIN" --print sysroot)/lib/rustlib/$t/lib" \
    || die "$RUSTC_BIN --print sysroot failed"
  d="$(mktemp -d)"
  for r in "$dir"/*.rlib; do
    [ -e "$r" ] || continue
    mkdir "$d/$n"
    ( cd "$d/$n" && ar -x "$r" ) || { rm -rf "$d"; die "$t: could not unpack sysroot archive $r"; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { rm -rf "$d"; die "$t: no precompiled sysroot archives in $dir; cannot classify archive members"; }
  # Capture the pipeline's status (pipefail is on) BEFORE cleaning up, so the
  # cleanup cannot mask a failure; the temp dir is removed either way.
  find "$d" -name '*.o' -type f -exec shasum -a 256 {} + | awk '{print $1}' | sort -u || rc=$?
  rm -rf "$d"
  if [ "$rc" -ne 0 ]; then
    echo "error: $t: hashing the sysroot objects failed (status $rc)" >&2
  fi
  return "$rc"
}

# Check every member of the archive $2 (built for target $1).
#
# Each member is classified by the SHA-256 of its contents:
#  * precompiled: identical to an object in the active toolchain's sysroot rlibs
#    for this target (Rust std, compiler-builtins, ...);
#  * source-built: everything else (our crates and all dependencies).
#
# Policy, from the member's Mach-O load commands:
#  precompiled
#    - LC_BUILD_VERSION: platform must be the target's; minos <= deployment target.
#    - LC_VERSION_MIN_IPHONEOS (legacy, no platform field): accepted only for the
#      targets whose precompiled objects use it; version <= deployment target.
#    - no version command: allowed and counted (it makes no deployment claim).
#    - any other version command (macOS, tvOS, ...): rejected.
#  source-built (including all dependencies)
#    - LC_BUILD_VERSION with the target's platform and minos EXACTLY equal to the
#      deployment target. Anything else is rejected: an earlier minimum means the
#      object was built for another deployment target, a later one is incompatible.
#    - legacy version-min, any other version command, or no version command:
#      rejected (cannot be verified).
#  A member named like one of our crates (laniakea_uniffi, laniakea_core,
#  wasmi_witness) that matches a sysroot object is rejected as suspicious.
# Rejections list the member, its platform and version.
check_members() {
  local t=$1 lib=$2 work recs hashes
  work="$(mktemp -d)"
  # Inspect the member listing first. `ar -x` extracts each name once, so a later
  # member with a repeated name would silently overwrite an earlier one and the
  # earlier object would never be validated.
  local listing objs badnames dups other n_objs n_extracted
  listing="$(ar -t "$lib")" || { rm -rf "$work"; die "$t: could not list $lib"; }
  objs="$(grep '\.o$' <<<"$listing" || true)"
  # Validation records are space-separated and read by field position, so a member
  # name containing spaces (or other odd characters) could forge its own record.
  # Accept only plain object names, checked on each listed name individually.
  badnames="$(grep -Ev '^[A-Za-z0-9._-]+\.o$' <<<"$objs" || true)"
  if [ -n "$badnames" ]; then
    rm -rf "$work"
    die "$t: $lib has object member name(s) outside [A-Za-z0-9._-] (refusing to validate them):
$(printf '%s\n' "$badnames" | head -10)"
  fi
  dups="$(sort <<<"$objs" | uniq -d)"
  if [ -n "$dups" ]; then
    rm -rf "$work"
    die "$t: $lib has duplicate object member names (the earlier ones would not be validated):
$(printf '%s\n' "$dups" | head -10)"
  fi
  # Only objects and the archive symbol table (__.SYMDEF, __.SYMDEF SORTED and
  # their _64 variants) are expected; anything else would go unvalidated.
  other="$(grep -v '\.o$' <<<"$listing" | grep -Ev '^__\.SYMDEF(_64)?( SORTED)?$' || true)"
  if [ -n "$other" ]; then
    rm -rf "$work"
    die "$t: $lib contains unexpected non-object member(s):
$(printf '%s\n' "$other" | head -10)"
  fi
  n_objs="$(printf '%s' "$objs" | grep -c . || true)"
  ( cd "$work" && ar -x "$lib" ) || { rm -rf "$work"; die "$t: could not unpack $lib"; }
  n_extracted="$(find "$work" -maxdepth 1 -type f -name '*.o' | wc -l | tr -d ' ')"
  if [ "$n_objs" != "$n_extracted" ]; then
    rm -rf "$work"
    die "$t: $lib lists $n_objs object member(s) but $n_extracted were extracted; refusing to validate a partial set"
  fi
  hashes="$work/.sysroot.sha256"
  sysroot_hashes "$t" > "$hashes" || { rm -rf "$work"; exit 1; }
  [ -s "$hashes" ] || { rm -rf "$work"; die "$t: empty sysroot object index"; }
  recs="$work/.records"
  : > "$recs"
  local f h
  for f in "$work"/*.o; do
    [ -e "$f" ] || { rm -rf "$work"; die "$t: $lib contains no object files"; }
    h="$(shasum -a 256 "$f" | awk '{print $1}')"
    [ -n "$h" ] || { rm -rf "$work"; die "$t: could not hash $f"; }
    otool -l "$f" | awk -v m="$(basename "$f")" -v h="$h" '
      /cmd LC_BUILD_VERSION/      { k="B"; next }
      /cmd LC_VERSION_MIN_IPHONEOS/ { k="M"; next }
      /cmd LC_VERSION_MIN_/       { print m, "X", $2, "-", h; k=""; seen=1; next }
      k=="B" && $1=="platform"    { p=$2 }
      k=="B" && $1=="minos"       { print m, "B", p, $2, h; k=""; seen=1 }
      k=="M" && $1=="version"     { print m, "M", 0, $2, h; k=""; seen=1 }
      END { if (!seen) print m, "N", 0, "-", h }' >> "$recs"
  done
  # Every listed object must have been examined. The loop above and the count
  # check enumerate files differently (a glob skips dot-prefixed names, find does
  # not), so count the distinct members that actually produced a record.
  local n_validated
  n_validated="$(awk '{print $1}' "$recs" | sort -u | grep -c . || true)"
  if [ "$n_validated" != "$n_objs" ]; then
    rm -rf "$work"
    die "$t: $lib lists $n_objs object member(s) but only $n_validated were validated; refusing to accept an archive with uninspected objects"
  fi
  local bad
  bad="$(awk -v want_platform="$(expected_platform "$t")" -v target="$MIN" -v legacy_ok="$(legacy_min_ok "$t")" '
    function vnum(v,   a, n) { n = split(v, a, "."); return a[1]*1000000 + a[2]*1000 + a[3] }
    function norm(v,   a, n) { n = split(v, a, "."); return (a[3]+0) ? (a[1]+0)"."(a[2]+0)"."(a[3]+0) : (a[1]+0)"."(a[2]+0) }
    NR == FNR { sys[$1] = 1; next }
    { member=$1; kind=$2; plat=$3; ver=$4; pre = ($5 in sys)
      own = (member ~ /^(laniakea_uniffi|laniakea_core|wasmi_witness)-/)
      if (own && pre) { print member ": named like our crate but identical to a sysroot object"; next }
      if (pre) {
        if (kind == "B") {
          if (plat != want_platform) print member ": precompiled, platform " plat " (expected " want_platform "), minos " ver
          else if (vnum(ver) > vnum(target)) print member ": precompiled, minos " norm(ver) " is newer than the deployment target " target
        } else if (kind == "M") {
          if (!legacy_ok) print member ": precompiled, legacy iphoneos version-min " ver " is not valid for this target"
          else if (vnum(ver) > vnum(target)) print member ": precompiled, legacy version-min " norm(ver) " is newer than the deployment target " target
        } else if (kind == "X") {
          print member ": precompiled, unexpected load command " plat
        }
      } else {
        if (kind == "B") {
          if (plat != want_platform) print member ": source-built, platform " plat " (expected " want_platform "), minos " ver
          else if (vnum(ver) != vnum(target)) print member ": source-built, minos " norm(ver) " (expected exactly " target "; built for a different deployment target?)"
        } else if (kind == "M") {
          print member ": source-built with a legacy version-min command (" ver "); cannot verify its deployment target"
        } else if (kind == "X") {
          print member ": source-built, unexpected load command " plat
        } else {
          print member ": source-built with no platform/version metadata"
        }
      }
    }' "$hashes" "$recs")"
  local n_total n_pre n_src n_pre_none
  n_total="$(wc -l < "$recs" | tr -d ' ')"
  n_pre="$(awk 'NR==FNR{s[$1]=1;next} ($5 in s)' "$hashes" "$recs" | wc -l | tr -d ' ')"
  n_src=$((n_total - n_pre))
  n_pre_none="$(awk 'NR==FNR{s[$1]=1;next} ($5 in s) && $2=="N"' "$hashes" "$recs" | wc -l | tr -d ' ')"
  rm -rf "$work"
  if [ -n "$bad" ]; then
    die "$t: incompatible archive members in $lib (deployment target $MIN):
$(printf '%s\n' "$bad" | head -20)
$(printf '%s\n' "$bad" | wc -l | tr -d ' ') offending member(s) in total."
  fi
  echo "    members=$n_total  precompiled(sysroot)=$n_pre  source-built=$n_src (all exactly $MIN)  precompiled-without-metadata=$n_pre_none"
}

for t in $TARGETS; do
  lib="$(lib_of "$t")"
  [ -f "$lib" ] || die "expected $lib after the build"
  echo "==> inspecting $t"
  arch="$(lipo -archs "$lib")"
  [ "$arch" = "$(expected_arch "$t")" ] || die "$t: library architecture is '$arch', expected '$(expected_arch "$t")'"

  syms="$(nm -g "$lib" 2>/dev/null | awk '$2=="T"{print $3}')"
  for s in $EXPECT_SYMS; do
    # here-string, not a pipe: grep -q exits early and would SIGPIPE printf under pipefail
    grep -qx "$s" <<<"$syms" || die "$t: exported symbol $s is missing"
  done
  check_members "$t" "$lib"
  echo "    arch=$arch min=$MIN symbols ok"
done

# --- 5. bindings and ABI consistency
echo "==> generating Swift bindings from the host library"
"$ROOT/scripts/gen-swift-bindings.sh" >/dev/null
BIND="$TARGET/uniffi/swift"
for f in laniakea.swift laniakeaFFI.h laniakeaFFI.modulemap; do
  [ -s "$BIND/$f" ] || die "missing generated binding $BIND/$f"
done
grep -q '^module laniakeaFFI' "$BIND/laniakeaFFI.modulemap" \
  || die "module map does not define module laniakeaFFI"

# UniFFI reads its interface metadata from the library file itself, so bindings
# generated from each iOS library must equal the host-generated ones. A stale or
# differently-configured library would differ (checksums, API, contract version).
for t in $TARGETS; do
  echo "==> ABI consistency ($t): bindings from the iOS library vs. host bindings"
  chk="$(mktemp -d)"
  if ! cargo run -q -p uniffi-bindgen -- generate --library "$(lib_of "$t")" \
    --language swift --out-dir "$chk" --no-format >"$chk/bindgen.log" 2>&1; then
    cat "$chk/bindgen.log" >&2
    rm -rf "$chk"
    die "bindgen could not read the interface from $(lib_of "$t")"
  fi
  for f in laniakea.swift laniakeaFFI.h laniakeaFFI.modulemap; do
    cmp -s "$chk/$f" "$BIND/$f" || { rm -rf "$chk"; die "$t: $f differs from the host-generated one; the library and bindings do not match"; }
  done
  rm -rf "$chk"
done

# --- 6. stage
echo "==> staging in $STAGE"
mkdir -p "$STAGE/device" "$STAGE/simulator" "$STAGE/headers"
cp "$(lib_of "$DEVICE")" "$STAGE/device/$LIBNAME"
if [ "${INCLUDE_X86_64_SIM:-0}" = "1" ]; then
  lipo -create "$(lib_of "$SIM")" "$(lib_of "$X86")" -output "$STAGE/simulator/$LIBNAME"
else
  cp "$(lib_of "$SIM")" "$STAGE/simulator/$LIBNAME"
fi
cp "$BIND/laniakeaFFI.h" "$STAGE/headers/laniakeaFFI.h"
# The XCFramework expects the module map to be named module.modulemap.
cp "$BIND/laniakeaFFI.modulemap" "$STAGE/headers/module.modulemap"

echo "==> sizes (unstripped release static libraries)"
for f in "$STAGE/device/$LIBNAME" "$STAGE/simulator/$LIBNAME"; do
  printf '    %10s bytes  %s  (%s)\n' "$(stat -f %z "$f")" "$f" "$(lipo -archs "$f")"
done
echo "==> OK: Rust static libraries built and verified (compile-only; not linked, not run)"
