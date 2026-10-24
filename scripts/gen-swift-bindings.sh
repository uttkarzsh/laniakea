#!/usr/bin/env bash
# Generate the Swift bindings for laniakea-uniffi into target/uniffi/swift/.
#
# Library mode: UniFFI reads the interface (including the namespace, "laniakea")
# out of a *built host library*, so we build a host cdylib first. The cdylib is
# for bindgen only; the iOS build uses a staticlib (see Phase 6c).
#
# Output, under Cargo's target directory (target/ by default; CARGO_TARGET_DIR
# and build.target-dir are honoured), never in tracked directories:
#   <target>/uniffi/swift/laniakea.swift
#   <target>/uniffi/swift/laniakeaFFI.h
#   <target>/uniffi/swift/laniakeaFFI.modulemap
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS hosts (expects a .dylib)"
command -v cargo >/dev/null || die "cargo not found; install Rust (https://rustup.rs)"

# Cargo's real target directory (honours CARGO_TARGET_DIR and build.target-dir).
target_dir() {
  command -v python3 >/dev/null || die "python3 not found (needed to read cargo metadata)"
  cargo metadata --format-version 1 --no-deps --manifest-path "$ROOT/Cargo.toml" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])'
}

TARGET="$(target_dir)"
[ -n "$TARGET" ] || die "could not determine Cargo's target directory"
OUT="$TARGET/uniffi/swift"
LIB="$TARGET/debug/liblaniakea_uniffi.dylib"

echo "==> building host library (cdylib, debug) in $TARGET"
# Remove any previous copy first so that a missing file after the build means the
# build did not produce one, instead of an old library being picked up.
rm -f "$LIB"
cargo rustc -p laniakea-uniffi --lib --crate-type cdylib
[ -f "$LIB" ] || die "expected $LIB after the build, but it was not produced"

echo "==> generating Swift bindings -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cargo run -q -p uniffi-bindgen -- generate \
  --library "$LIB" \
  --language swift \
  --out-dir "$OUT" \
  --no-format

for f in laniakea.swift laniakeaFFI.h laniakeaFFI.modulemap; do
  [ -s "$OUT/$f" ] || die "bindgen did not produce $f"
done
echo "==> done:"
ls -1 "$OUT"
