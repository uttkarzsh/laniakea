# Shared helpers for the build scripts. Source this file; do not execute it.
# Expects ROOT (repository root) to be set by the caller.

die() { echo "error: $*" >&2; exit 1; }

# Cargo's real target directory (honours CARGO_TARGET_DIR and build.target-dir).
target_dir() {
  command -v python3 >/dev/null || die "python3 not found (needed to read cargo metadata)"
  local dir
  dir="$(cargo metadata --format-version 1 --no-deps --manifest-path "$ROOT/Cargo.toml" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')" \
    || die "cargo metadata failed"
  [ -n "$dir" ] || die "cargo metadata returned an empty target directory"
  printf '%s\n' "$dir"
}

# Succeeds if the Rust standard library for $1 is installed.
rust_target_installed() {
  [ -d "$(rustc --print sysroot)/lib/rustlib/$1/lib" ]
}

# Canonical form of an iOS version: "14" -> "14.0", "14.0.0" -> "14.0",
# "14.2.0" -> "14.2", "14.2.1" -> "14.2.1".
norm_ver() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || die "invalid version '$1'"
  printf '%s\n' "$1" | awk -F. '{ m=$1+0; n=$2+0; p=$3+0;
    if (p) printf "%d.%d.%d\n", m, n, p; else printf "%d.%d\n", m, n }'
}

# Paths for the iOS build with deployment target $IPHONEOS_DEPLOYMENT_TARGET
# (default 14.0). Sets MIN, TARGET, IOS_TARGET_DIR, STAGE.
#
# Cargo does not rebuild when IPHONEOS_DEPLOYMENT_TARGET changes, so every
# deployment target gets its own Cargo target directory: objects built for
# different minimum versions can never end up in one archive, and an ordinary
# build in the default target directory cannot contaminate a packaging build.
ios_layout() {
  MIN="$(norm_ver "${IPHONEOS_DEPLOYMENT_TARGET:-14.0}")"
  TARGET="$(target_dir)"
  IOS_TARGET_DIR="$TARGET/ios-$MIN"
  STAGE="$TARGET/uniffi/ios-$MIN"
}

# Remove the staging directory, after checking it is exactly what we generate:
# <target>/uniffi/ios-<version>, a real directory (not a symlink).
clean_stage() {
  [ -n "${TARGET:-}" ] && [ -n "${STAGE:-}" ] || die "internal: staging paths are not set"
  case "$STAGE" in
    "$TARGET"/uniffi/ios-[0-9]*) ;;
    *) die "refusing to delete unexpected staging path: $STAGE" ;;
  esac
  [ "$(dirname "$STAGE")" = "$TARGET/uniffi" ] || die "refusing to delete unexpected staging path: $STAGE"
  [ ! -L "$STAGE" ] || die "refusing to delete a symlink: $STAGE"
  rm -rf -- "$STAGE"
}
