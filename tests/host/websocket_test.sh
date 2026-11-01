#!/bin/bash
#
# tests/host/websocket_test.sh
#
# websocket(2) over the network, against a server written apart from it
# (tests/host/websocket/fake_ws.py, from RFC 6455, standard library only):
#
#   - ws://: the upgrade with the caller's Authorization sent; a greeting
#     in two fragments with a ping between them, joined, the ping answered
#     with a masked pong; text (UTF-8) and 100000 bytes of binary echoed;
#     a close answered with the same code
#   - wss://: the same through TLS whose certificate the client verifies
#     (the test's own CA bound over /lib/certs, as mail9p_imap_test does)
#   - wss:// to a server whose certificate comes from a CA not trusted:
#     refused before any upgrade
#   - the server's log: no frame from the client unmasked
#
# The pipe-driven cases (framing, every protocol error) are the same
# Limbo file's, run by the test runner with no network.
#
# Run from project root: ./tests/host/websocket_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=0
[[ "${1:-}" = -v ]] && VERBOSE=1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/lib/websocket.dis dis/tests/websocket_test.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

ca() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.pem" -days 2 -subj "/CN=$1" 2>/dev/null
}
cert() {	# name CA
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$D/$1.key" -out "$D/$1.csr" -subj "/CN=$1" 2>/dev/null
    printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > "$D/$1.ext"
    openssl x509 -req -in "$D/$1.csr" -CA "$D/$2.pem" -CAkey "$D/$2.key" \
        -CAcreateserial -days 2 -extfile "$D/$1.ext" -out "$D/$1.pem" 2>/dev/null
}
ca testca; ca otherca
cert good testca
cert stranger otherca
mkdir -p "$D/certs"
openssl x509 -in "$D/testca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/good.pem" && -s "$D/stranger.pem" ]] ||
    { echo "FAIL: openssl made no certificates"; exit 1; }

# serve name [cert] -> its port
serve() {
    local pf="$D/$1.port" tls=()
    [[ -n "${2:-}" ]] && tls=(--cert "$D/$2.pem" --key "$D/$2.key")
    python3 -I "$ROOT/tests/host/websocket/fake_ws.py" "${tls[@]}" \
        --log "$D/$1.log" > "$pf" 2>"$D/$1.err" &
    PIDS="$PIDS $!"
    for i in $(seq 50); do [[ -s "$pf" ]] && break; sleep 0.1; done
    head -1 "$pf"
}
P_WS=$(serve plain)
P_WSS=$(serve tls good)
P_BAD=$(serve stranger stranger)
for p in "$P_WS" "$P_WSS" "$P_BAD"; do
    [[ -n "$p" ]] || { echo "FAIL: a fake server did not start"; cat "$D"/*.err; exit 1; }
done

# live url [refused-url] -> the Limbo test's output in $D/out.<n>
n=0
live() {
    n=$((n+1))
    with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "bind '#U*'$D/certs /lib/certs
wsurl='$1'
wsrefused='${2:-}'
/tests/websocket_test.dis -v" > "$D/out.$n" 2>&1
    [[ "$VERBOSE" -eq 1 ]] && sed 's/^/  | /' "$D/out.$n"
    grep -q -- '--- PASS: Live' "$D/out.$n"
}

if live "ws://127.0.0.1:$P_WS/socket?ticket=1"; then
    pass "ws://: upgrade, fragments round a ping, echoes, close"
else
    fail "ws://"; sed 's/^/  | /' "$D/out.$n"
fi

if live "wss://127.0.0.1:$P_WSS/socket" "wss://127.0.0.1:$P_BAD/socket"; then
    pass "wss://: the same through verified TLS; an untrusted CA refused"
else
    fail "wss://"; sed 's/^/  | /' "$D/out.$n"
fi

grep -q -- '--- FAIL' "$D"/out.* && fail "the pipe-driven cases failed beside the live ones"

check() {	# log pattern description
    if grep -q -- "$2" "$D/$1.log" 2>/dev/null; then pass "$3"; else fail "$3"; cat "$D/$1.log" 2>/dev/null | sed 's/^/  | /'; fi
}
check plain '^upgrade /socket?ticket=1$' "the request target sent as given"
check plain '^authorization Bearer xapp-live$' "the caller's header sent"
check plain '^pong are-you-there$' "the server's ping answered"
check plain '^text echo κόσμε$' "UTF-8 text arrives as sent"
check plain '^binary 100000 ' "100000 bytes of binary arrive whole"
check plain '^close 1000 done$' "close code and reason arrive"
check tls '^close 1000 done$' "wss://: the whole exchange"
if grep -q unmasked "$D"/*.log; then fail "a client frame arrived unmasked"; else pass "every client frame masked"; fi
if grep -q '^upgrade' "$D/stranger.log" 2>/dev/null; then
    fail "an upgrade was sent to the untrusted server"
else
    pass "nothing sent past TLS to the untrusted server"
fi

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
