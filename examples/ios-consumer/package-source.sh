#!/usr/bin/env bash
# Chooses where the consumer app gets the Laniakea package from, by editing its Xcode project.
#
#   package-source.sh remote [--from <version> | --exact <version>] [--url <repository URL>] [--project <path>]
#       A remote package: repository URL plus a version rule. This is how an app developer
#       adds Laniakea, and it is the committed form. Default: --from 0.1.0 and the project's
#       GitHub URL. Needs a published version tag to resolve.
#   package-source.sh local [--project <path>]
#       The checkout this example lives in (../..), for working on the SDK and the example
#       together. Do not commit this form.
#
# Only the package reference changes. Run it on the committed project or on a copy.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"; shift || true
PROJECT="$HERE/LaniakeaConsumer.xcodeproj/project.pbxproj"
URL="https://github.com/uttkarzsh/laniakea.git"; RULE=from; VERSION=0.1.0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) RULE=from; VERSION="$2"; shift ;;
    --exact) RULE=exact; VERSION="$2"; shift ;;
    --url) URL="$2"; shift ;;
    --project) PROJECT="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
case "$MODE" in local|remote) ;; *) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64 ;; esac
[ -f "$PROJECT" ] || { echo "error: no project at $PROJECT (pass the .pbxproj path with --project)" >&2; exit 1; }

python3 - "$PROJECT" "$MODE" "$URL" "$RULE" "$VERSION" <<'PY'
import re, sys
path, mode, url, rule, version = sys.argv[1:6]
t = open(path).read()
REF = "A116A76F308F54F6006A1B03"
if mode == "local":
    comment = '/* XCLocalSwiftPackageReference "../.." */'
    section = "XCLocalSwiftPackageReference"
    body = 'isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = "../..";'
else:
    comment = '/* XCRemoteSwiftPackageReference "laniakea" */'
    section = "XCRemoteSwiftPackageReference"
    req = ('kind = exactVersion;\n\t\t\t\tversion = "%s";' % version) if rule == "exact" else \
          ('kind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = "%s";' % version)
    body = 'isa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = "%s";\n\t\t\trequirement = {\n\t\t\t\t%s\n\t\t\t};' % (url, req)
new_section = "/* Begin %s section */\n\t\t%s %s = {\n\t\t\t%s\n\t\t};\n/* End %s section */" % (section, REF, comment, body, section)
t, n = re.subn(r"/\* Begin XC(?:Local|Remote)SwiftPackageReference section \*/.*?/\* End XC(?:Local|Remote)SwiftPackageReference section \*/", lambda m: new_section, t, flags=re.S)
assert n == 1, "package reference section not found"
t, n = re.subn(r"%s /\* XC(?:Local|Remote)SwiftPackageReference \"[^\"]*\" \*/," % REF, "%s %s," % (REF, comment), t)
assert n == 1, "package reference list entry not found"
t = re.sub(r"\n\t\t\tpackage = %s [^\n]*;" % REF, "", t)
if mode == "remote":
    t, n = re.subn(r"(isa = XCSwiftPackageProductDependency;)(\n\t\t\tproductName = LaniakeaKit;)", lambda m: "%s\n\t\t\tpackage = %s %s;%s" % (m.group(1), REF, comment, m.group(2)), t)
    assert n == 1, "product dependency not found"
open(path, "w").write(t)
PY
echo "package source: $MODE${URL:+}$([ "$MODE" = remote ] && echo " ($URL, $RULE $VERSION)")"
