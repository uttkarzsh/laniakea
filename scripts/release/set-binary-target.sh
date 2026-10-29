#!/usr/bin/env bash
# Switches the LaniakeaRustLib binary target in Package.swift between its two forms.
# Nothing is guessed and nothing is chosen automatically: you name the mode.
#
#   scripts/release/set-binary-target.sh --local
#       .binaryTarget(name: "LaniakeaRustLib", path: "Binaries/LaniakeaRustLib.xcframework")
#       The DEVELOPMENT form. Every commit on a development branch has this form.
#
#   scripts/release/set-binary-target.sh --remote --version <V> --url <URL> --checksum <SHA256>
#       .binaryTarget(name: "LaniakeaRustLib", url: "<URL>", checksum: "<SHA256>")
#       The RELEASE form. It belongs only in a release commit, the one a version tag
#       points at, and only after the asset at <URL> exists and <SHA256> is the
#       `swift package compute-checksum` of exactly that file (see docs/RELEASING.md).
#       <URL> must be https and end in /<V>/LaniakeaRustLib-<V>.xcframework.zip.
#
#   --manifest <path>   edit another Package.swift (default: the repository's root one)
#
# Only the one binaryTarget line changes. The result is written to a temporary directory
# first and checked with `swift package dump-package` (target name and type, URL and
# checksum or path, platforms, products, and that exactly that one line differs); only
# then does it replace the manifest, by renaming a file in the same directory. On any
# failure the manifest is untouched. This script creates no tag, commit or release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/scripts/lib/common.sh"

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

MODE="" VERSION="" URL="" CHECKSUM="" MANIFEST="$ROOT/Package.swift"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) MODE=local ;;
    --remote) MODE=remote ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION="$2"; shift ;;
    --url) [ "$#" -ge 2 ] || usage; URL="$2"; shift ;;
    --checksum) [ "$#" -ge 2 ] || usage; CHECKSUM="$2"; shift ;;
    --manifest) [ "$#" -ge 2 ] || usage; MANIFEST="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "error: choose --local or --remote" >&2; usage; }
[ -f "$MANIFEST" ] || die "no such manifest: $MANIFEST"
command -v swift >/dev/null || die "swift not found"

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
LOCAL_PATH="Binaries/LaniakeaRustLib.xcframework"
if [ "$MODE" = local ]; then
  [ -z "$VERSION$URL$CHECKSUM" ] || die "--local takes no --version, --url or --checksum"
else
  [ -n "$VERSION" ] && [ -n "$URL" ] && [ -n "$CHECKSUM" ] || die "--remote needs --version, --url and --checksum"
  grep -Eq "$SEMVER" <<<"$VERSION" || die "version '$VERSION' is not SemVer (e.g. 0.1.0 or 0.1.0-rc.1)"
  grep -Eq '^[0-9a-f]{64}$' <<<"$CHECKSUM" || die "checksum must be 64 lowercase hex digits (swift package compute-checksum)"
  grep -Eq '^https://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+$' <<<"$URL" || die "url must be an https URL without quotes or spaces"
  case "$URL" in
    */"$VERSION"/LaniakeaRustLib-"$VERSION".xcframework.zip) ;;
    *) die "url must end in /$VERSION/LaniakeaRustLib-$VERSION.xcframework.zip (immutable, versioned asset name)" ;;
  esac
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/laniakea-manifest.XXXXXX")"
NEW=""
trap 'rm -rf "$WORK"; [ -z "$NEW" ] || rm -f "$NEW"' EXIT

python3 - "$MANIFEST" "$WORK/Package.swift" "$MODE" "$LOCAL_PATH" "$URL" "$CHECKSUM" <<'PY' || die "could not edit the manifest"
import re, sys
src, dst, mode, local_path, url, checksum = sys.argv[1:7]
text = open(src).read()
pat = re.compile(r'^( *)\.binaryTarget\(name: "LaniakeaRustLib",[^\n]*\),\n', re.M)
found = pat.findall(text)
if len(found) != 1:
    sys.exit('expected exactly one single-line .binaryTarget(name: "LaniakeaRustLib", ...) in the manifest, found %d' % len(found))
indent = found[0]
if mode == "local":
    line = '%s.binaryTarget(name: "LaniakeaRustLib", path: "%s"),\n' % (indent, local_path)
else:
    line = '%s.binaryTarget(name: "LaniakeaRustLib", url: "%s", checksum: "%s"),\n' % (indent, url, checksum)
open(dst, "w").write(pat.sub(lambda m: line, text, count=1))
PY

echo "==> validating the edited manifest with swift package dump-package"
swift package dump-package --package-path "$WORK" > "$WORK/dump.json" 2> "$WORK/dump.err" \
  || { cat "$WORK/dump.err" >&2; die "swift package dump-package rejected the edited manifest"; }
python3 - "$WORK/dump.json" "$MANIFEST" "$WORK/Package.swift" "$MODE" "$LOCAL_PATH" "$URL" "$CHECKSUM" <<'PY' || die "the edited manifest failed validation"
import json, sys
dump, old, new, mode, local_path, url, checksum = sys.argv[1:8]
d = json.load(open(dump))
def fail(m): sys.exit("  FAIL: " + m)
t = {x["name"]: x for x in d["targets"]}
if sorted(t) != ["LaniakeaKit", "LaniakeaRustLib", "_LaniakeaBindings", "laniakeaFFI"]: fail("targets are %s" % sorted(t))
b = t["LaniakeaRustLib"]
if b["type"] != "binary": fail("LaniakeaRustLib is not a binary target")
if mode == "local":
    if b.get("path") != local_path or b.get("url") is not None or b.get("checksum") is not None: fail("not the local form: %s" % b)
else:
    if b.get("url") != url or b.get("checksum") != checksum or b.get("path") is not None: fail("not the remote form: %s" % b)
if [p["name"] for p in d["products"]] != ["LaniakeaKit"]: fail("products changed")
if [(p["platformName"], p["version"]) for p in d["platforms"]] != [("ios", "15.0")]: fail("platforms changed: %s" % d["platforms"])
a, c = open(old).read().splitlines(), open(new).read().splitlines()
if len(a) != len(c): fail("line count changed")
diff = [i for i, (x, y) in enumerate(zip(a, c)) if x != y]
if len(diff) > 1: fail("more than the binaryTarget line differs: lines %s" % [i + 1 for i in diff])
print("  ok  %s form; %s" % (mode, "only line %d changed" % (diff[0] + 1) if diff else "manifest already in this form (no change)"))
PY

if cmp -s "$WORK/Package.swift" "$MANIFEST"; then
  echo "==> unchanged: $MANIFEST was already in the $MODE form"
else
  NEW="$(mktemp "$(dirname "$MANIFEST")/.Package.swift.XXXXXX")"
  cp "$WORK/Package.swift" "$NEW"
  # keep the mode of the original
  chmod "$(stat -f %Lp "$MANIFEST")" "$NEW"
  mv "$NEW" "$MANIFEST"; NEW=""
  echo "==> $MANIFEST now has the $MODE binary target"
fi
if [ "$MODE" = remote ]; then
  echo "NOTE: the remote form belongs only in a release commit. Do not commit it to a development branch." >&2
fi
