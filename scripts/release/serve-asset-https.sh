#!/usr/bin/env bash
# Serves dist/<version>/LaniakeaRustLib-<version>.xcframework.zip over HTTPS on localhost so
# the real SwiftPM binary-target download and checksum check can be tested without publishing
# anything. SwiftPM accepts only https:// URLs for a binary target and trusts the system
# store, so a throwaway CA has to be trusted for the duration of the test.
#
#   scripts/release/serve-asset-https.sh <version> [port]       (default port 8443)
#
# It creates a temporary CA and a certificate for localhost, prints the two commands that
# trust and untrust the CA (it never changes your trust settings itself), copies the ZIP
# into <tmp>/www/<version>/ and serves <tmp>/www until you press Ctrl-C. Then, in another
# terminal:
#
#   ASSET_URL_BASE=https://localhost:8443 scripts/release/validate-consumer.sh --rehearse <version>
#
# The asset URL is https://localhost:<port>/<version>/LaniakeaRustLib-<version>.xcframework.zip.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-}"; PORT="${2:-8443}"
[ -n "$VERSION" ] || { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
ZIP="$ROOT/dist/$VERSION/LaniakeaRustLib-$VERSION.xcframework.zip"
[ -s "$ZIP" ] || { echo "error: $ZIP not found; run scripts/release/build-asset.sh $VERSION first" >&2; exit 1; }

KEEP="$HOME/.laniakea-test-ca.pem"
# Checked before anything is created: a running server or a CA left from an earlier run (possibly
# still trusted) must not be replaced, or the printed untrust command would name the wrong CA.
if python3 -I -c 'import socket, sys; s = socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$PORT"; then
  echo "error: something is already listening on port $PORT" >&2; exit 1
fi
[ ! -e "$KEEP" ] || { echo "error: $KEEP exists from an earlier run; untrust and remove it first (security remove-trusted-cert $KEEP; rm $KEEP)" >&2; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/laniakea-https.XXXXXX")"
PY_PID=""
# One cleanup for every way out: stops only the server this script started (by PID), removes the
# temporary directory with the server's private key, and says what is left to do by hand.
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$PY_PID" ] && kill -0 "$PY_PID" 2>/dev/null; then
    kill "$PY_PID" 2>/dev/null || true
    wait "$PY_PID" 2>/dev/null || true
  fi
  rm -rf "$T"
  echo "server stopped; removed $T" >&2
  if [ -e "$KEEP" ]; then
    cat >&2 <<MSG
Left for you, if you trusted the CA (each may ask for your password):
  security remove-trusted-cert $KEEP; rm $KEEP
  then delete "Laniakea test CA (temporary)" from the login keychain in Keychain Access
  (adding the trust also imports the certificate, and security delete-certificate does not reliably remove it).
MSG
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
cat > "$T/san.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[v3]
subjectAltName = DNS:localhost, IP:127.0.0.1
basicConstraints = critical, CA:FALSE
extendedKeyUsage = serverAuth
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$T/ca.pem" -days 2 -subj "/CN=Laniakea test CA (temporary)" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$T/server.key" -out "$T/server.csr" -config "$T/san.cnf" 2>/dev/null
openssl x509 -req -in "$T/server.csr" -CA "$T/ca.pem" -CAkey "$T/ca.key" -CAcreateserial -out "$T/server.pem" -days 2 \
  -extfile "$T/san.cnf" -extensions v3 2>/dev/null
rm -f "$T/ca.key"   # only needed for signing; the trusted CA can no longer sign anything
mkdir -p "$T/www/$VERSION"; cp "$ZIP" "$T/www/$VERSION/"
cp "$T/ca.pem" "$KEEP"

cat <<MSG
Serving https://localhost:$PORT/$VERSION/$(basename "$ZIP")
SwiftPM checksum: $(swift package compute-checksum "$ZIP")

Before the test, trust the temporary CA (asks for your password; user trust settings only):
  security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db $KEEP
After the test, remove it (printed again when the server stops):
  security remove-trusted-cert $KEEP; rm $KEEP
  and delete "Laniakea test CA (temporary)" from the login keychain in Keychain Access.

Ctrl-C (or kill <pid of this script>) stops the server.
MSG
cd "$T/www"
python3 -I - "$T/server.pem" "$T/server.key" "$PORT" <<'PY' &
import http.server, ssl, sys
cert, key, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
PY_PID=$!
wait "$PY_PID"
