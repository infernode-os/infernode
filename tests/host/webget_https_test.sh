#!/bin/bash
#
# tests/host/webget_https_test.sh
#
# The webget service's https (appl/svc/webget/http.b; web(2), which
# acme's and Xenith's Jwin load, starts the service and uses its file)
# against an HTTPS server on 127.0.0.1 (tests/host/webget/fake_https.py),
# through tests/webgetcli.b, which speaks to /chan/webget.
# TLS is the tree's client: the chain is verified against the system's
# roots (here the test's CA, bound over /lib/certs) and the name against
# the certificate.  It was the SSL 3.0 client, which checked no name and
# could be answered by a server with no key; and after its handshake the
# request was written to a buffer that went nowhere, so no page came.
#
#   - a page from a server the CA signed for 127.0.0.1 is fetched
#   - a certificate naming only localhost, and one from another CA, are
#     refused, and no request is sent to either
#
# Run from project root: ./tests/host/webget_https_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0
[[ "${1:-}" = -v ]] && VERBOSE=1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/webget/webget.dis dis/svc/webget/http.dis tests/webgetcli.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

cert() {	# name CA subjectAltName
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.csr" -subj "/CN=$1" 2>/dev/null
    printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\n' "$3" > "$D/$1.ext"
    openssl x509 -req -in "$D/$1.csr" -CA "$D/$2.pem" -CAkey "$D/$2.key" \
        -CAcreateserial -days 2 -extfile "$D/$1.ext" -out "$D/$1.pem" 2>/dev/null
}
ca() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.pem" -days 2 -subj "/CN=$1" 2>/dev/null
}
ca testca; ca otherca
cert good testca IP:127.0.0.1
cert localonly testca DNS:localhost
cert stranger otherca IP:127.0.0.1
mkdir -p "$D/certs" "$D/svc"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" && -s "$D/stranger.pem" ]] ||
    { echo "SKIP: openssl made no certificates"; exit 77; }

serve() {	# label cert -> its port
    python3 -I "$ROOT/tests/host/webget/fake_https.py" \
        --cert "$D/$2.pem" --key "$D/$2.key" --log "$D/$1.log" > "$D/$1.port" 2>"$D/$1.err" &
    PIDS="$PIDS $!"
    for i in $(seq 50); do [[ -s "$D/$1.port" ]] && break; sleep 0.1; done
    head -1 "$D/$1.port"
}
P_OK=$(serve ok good)
P_NAME=$(serve name localonly)
P_CA=$(serve ca stranger)
for p in "$P_OK" "$P_NAME" "$P_CA"; do
    [[ -n "$p" ]] || { echo "FAIL: a fake server did not start"; cat "$D"/*.err; exit 1; }
done

T=$D/transcript
with_timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd .)
bind '#U*'$D/certs /lib/certs
bind -c '#U*'$D/svc /services/webget
echo '<<< ok >>>'
/tests/webgetcli.dis https://127.0.0.1:$P_OK/page
echo '<<< name >>>'
/tests/webgetcli.dis https://127.0.0.1:$P_NAME/page
echo '<<< ca >>>'
/tests/webgetcli.dis https://127.0.0.1:$P_CA/page
echo '<<< end >>>'
echo halt > /dev/sysctl
" </dev/null >"$T" 2>&1
[[ "$VERBOSE" -eq 1 ]] && sed 's/^/  /' "$T"

slice() {
    awk -v m="<<< $1 >>>" '
        $0 == m { capture = 1; next }
        capture && /^<<< / { exit }
        capture { print }
    ' "$T"
}
expect() {
    if slice "$1" | grep -q -- "$3"; then pass "$1: $2"; else fail "$1: $2: got: $(slice "$1" | head -8)"; fi
}
refuse() {
    if slice "$1" | grep -q -- "$3"; then fail "$1: $2: got: $(slice "$1" | grep -- "$3" | head -4)"; else pass "$1: $2"; fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

expect ok "a page is fetched over TLS from a server the CA signed for 127.0.0.1" 'webget fetched this over TLS'
if grep -q '^GET /page ' "$D/ok.log"; then pass "ok: the request reached the server"; else fail "ok: the server saw: $(cat "$D/ok.log")"; fi
refuse name "a certificate naming only localhost gives no page" 'webget fetched this'
expect name "and the reason" 'webgetcli: failed: .*does not match'
refuse ca "a certificate from a CA that is not a root gives no page" 'webget fetched this'
expect ca "and the reason" 'webgetcli: failed: .*certificate chain verification failed'
if grep -q '^GET' "$D/name.log" "$D/ca.log" 2>/dev/null; then
    fail "a request was sent to a server whose certificate was refused: $(cat "$D/name.log" "$D/ca.log")"
else
    pass "no request was sent to a server whose certificate was refused"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
