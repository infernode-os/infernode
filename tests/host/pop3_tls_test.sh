#!/bin/bash
#
# tests/host/pop3_tls_test.sh
#
# pop3(2) over TLS (what Mailpop3 -t asks for) against a fake POP3 server
# (tests/host/pop3/fake_pop3.py), through tests/pop3cli.b.  TLS is the
# tree's client: the server's chain is verified against the system's
# roots (here the test's own CA, bound over /lib/certs) and its name
# against the certificate.  It was the SSL 3.0 client, which checked no
# name, and with which a server holding no key or certificate could
# finish a handshake (a ServerHello with an empty session id was taken
# for a resumed session under an empty master secret): USER and PASS
# were then sent to it.
#
#   - a server whose certificate the CA signed for 127.0.0.1: the
#     session works (stat, list, a message with its dots unstuffed, a
#     delete), and QUIT's answer is read
#   - a certificate naming only localhost, one from another CA, and a
#     server answering with an SSL 3.0 ServerHello of an empty session
#     id: each refused, and no USER or PASS sent to any of them
#   - a message with a line of 5000 bytes is read whole (the reader
#     broke at 1024, and every call after it waited ten seconds)
#   - fetch names its file by the server's id only when that is a name
#   - a server that never answers PASS: open fails at its deadline, and
#     the password is in nothing the caller is told
#
# Run from project root: ./tests/host/pop3_tls_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0
[[ "${1:-}" = -v ]] && VERBOSE=1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/lib/pop3.dis tests/pop3cli.dis; do
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
mkdir -p "$D/certs" "$D/fetch"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" && -s "$D/stranger.pem" ]] ||
    { echo "SKIP: openssl made no certificates"; exit 77; }

serve() {	# label cert scen -> its port
    python3 -I "$ROOT/tests/host/pop3/fake_pop3.py" --scen "$3" \
        --cert "$D/$2.pem" --key "$D/$2.key" --log "$D/$1.log" > "$D/$1.port" 2>"$D/$1.err" &
    PIDS="$PIDS $!"
    for i in $(seq 50); do [[ -s "$D/$1.port" ]] && break; sleep 0.1; done
    head -1 "$D/$1.port"
}
P_OK=$(serve ok good ok)
P_NAME=$(serve name localonly ok)
P_CA=$(serve ca stranger ok)
P_SSL3=$(serve ssl3 good ssl3)
P_LONG=$(serve long good longline)
P_UIDL=$(serve uidl good nouidl)
P_STALL=$(serve stall good stall)
for p in "$P_OK" "$P_NAME" "$P_CA" "$P_SSL3" "$P_LONG" "$P_UIDL" "$P_STALL"; do
    [[ -n "$p" ]] || { echo "FAIL: a fake server did not start"; cat "$D"/*.err; exit 1; }
done

T=$D/transcript
with_timeout 100 "$EMU" -r"$ROOT" /dis/sh.dis -c "path=(/dis /dis/cmd .)
bind '#U*'$D/certs /lib/certs
bind -c '#U*'$D/fetch /tmp
echo '<<< ok >>>'
/tests/pop3cli.dis 127.0.0.1!$P_OK /tmp
ls /tmp
echo '<<< name >>>'
/tests/pop3cli.dis 127.0.0.1!$P_NAME
echo '<<< ca >>>'
/tests/pop3cli.dis 127.0.0.1!$P_CA
echo '<<< ssl3 >>>'
/tests/pop3cli.dis 127.0.0.1!$P_SSL3
echo '<<< long >>>'
/tests/pop3cli.dis 127.0.0.1!$P_LONG
echo '<<< uidl >>>'
/tests/pop3cli.dis 127.0.0.1!$P_UIDL /tmp
ls /tmp
echo '<<< stall >>>'
/tests/pop3cli.dis 127.0.0.1!$P_STALL
echo '<<< procs >>>'
ps
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
nologin() {	# label: the server was sent no USER or PASS
    if grep -q '^USER\|^PASS\|^record 2[023]' "$D/$1.log" 2>/dev/null; then
        fail "$1: the server was sent a login: $(cat "$D/$1.log")"
    else
        pass "$1: the server was sent no USER or PASS"
    fi
}

grep -q '<<< end >>>' "$T" || fail "the script did not finish: $(tail -5 "$T")"

expect ok "a server the CA signed for 127.0.0.1 is logged in to over TLS" '^open: 1 '
expect ok "its mailbox is counted" '^stat: 1 .*messages=2'
expect ok "and listed" '^list: 1  1 2$'
expect ok "a message is read" '^First message\.$'
expect ok "a line that began with a dot has it once" '^\. a line that began with a dot$'
expect ok "the next message is the next" '^Second message\.$'
expect ok "fetch writes the message under the server's id" '/tmp/uid1$'
expect ok "a message is deleted" '^delete: 1 '
expect ok "and QUIT is answered" '^close: 1 '
if grep -q '^USER alice$' "$D/ok.log" && grep -q '^QUIT' "$D/ok.log" && ! grep -q '^PASS .' "$D/ok.log"; then
    pass "ok: the server saw USER, PASS and QUIT"
else
    fail "ok: the server saw: $(cat "$D/ok.log")"
fi
expect name "a certificate naming only localhost is refused for 127.0.0.1" '^open: -1 tlsdial: tls: hostname 127.0.0.1 does not match'
nologin name
expect ca "a certificate from a CA that is not a root is refused" '^open: -1 tlsdial: tls: certificate chain verification failed'
nologin ca
expect ssl3 "an SSL 3.0 ServerHello with an empty session id is refused" '^open: -1 tlsdial: tls: '
nologin ssl3
expect long "a message with a line of 5000 bytes is read" '^get: 1 '
expect long "to its end" '^Second message\.$'
expect uidl "an id that is a path is not the file's name" '^fetch: 1 '
expect uidl "the file is named by the message's number" '/tmp/1$'
if [[ -e "$D/x" || -e "$D/../x" ]]; then fail "uidl: a file was made outside the directory"; else pass "uidl: nothing was made outside the directory"; fi
expect stall "PASS never answered: open fails at its deadline" '^open: -1 PASS receive failed (pop3 timed out)'
refuse stall "and does not wait long past it" '([4-9][0-9][0-9][0-9][0-9] ms)'
expect procs "the processes are listed" 'Sh\|Ps'
refuse procs "none is broken or left from a connection" 'roken\|Mailconn\|Pop3\|TLS'

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
