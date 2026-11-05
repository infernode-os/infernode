#!/bin/bash
#
# tests/host/llmclient_pool_test.sh
#
# llmclient's connection pool against a fake LLM API
# (tests/host/llmclient/fake_llm.py) over TLS the client verifies: the
# test's own CA is the only root, a directory holding it bound over
# /lib/certs in emu's name space, the server's certificate made here for
# 127.0.0.1.  The checks are tests/llmclient_pool_test.b's (its header
# lists them): sequential requests on one connection, a server-closed
# idle connection replaced, a stream read to its terminating chunk
# before its connection is used again, a cancelled stream's connection
# dropped, concurrent requests on connections of their own, a request
# sent again at most once and never after a byte of its reply, and a
# proxy's tunnel kept.
#
# With --bench [MS], it times 20 sequential requests (buffered, then
# streamed) through the fake API's relay with MS (default 50) of
# round-trip time, instead of the checks.  LLMCLIENT_DIS=<file> binds
# another llmclient.dis over /dis/lib/llmclient.dis first (to time the
# one before the pool).
#
# Run from project root: ./tests/host/llmclient_pool_test.sh [-v] [--bench [MS]]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
VERBOSE=
BENCH=
while [[ $# -gt 0 ]]; do
    case "$1" in
    -v) VERBOSE=-v ;;
    --bench) BENCH=50; [[ "${2:-}" =~ ^[0-9]+$ ]] && { BENCH=$2; shift; } ;;
    esac
    shift
done

[[ -x "$EMU" ]] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/lib/llmclient.dis dis/tests/llmclient_pool_test.dis; do
    [[ -f "$ROOT/$f" ]] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }
command -v openssl >/dev/null || { echo "SKIP: openssl not found"; exit 77; }

D=$(mktemp -d)
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$D"' EXIT
cd "$ROOT"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/ca.key" -out "$D/ca.pem" -days 2 -subj "/CN=testca" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$D/srv.key" -out "$D/srv.csr" -subj "/CN=127.0.0.1" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' > "$D/srv.ext"
openssl x509 -req -in "$D/srv.csr" -CA "$D/ca.pem" -CAkey "$D/ca.key" \
    -CAcreateserial -days 2 -extfile "$D/srv.ext" -out "$D/srv.pem" 2>/dev/null
mkdir -p "$D/certs"
openssl x509 -in "$D/ca.pem" -outform der -out "$D/certs/testca.der"
[[ -s "$D/certs/testca.der" && -s "$D/srv.pem" ]] ||
    { echo "FAIL: openssl made no certificates"; exit 1; }

python3 -I "$ROOT/tests/host/llmclient/fake_llm.py" --cert "$D/srv.pem" --key "$D/srv.key" \
    ${BENCH:+--delay "$BENCH"} > "$D/ports" 2>"$D/server.err" &
PIDS="$PIDS $!"
for i in $(seq 50); do
    [[ $(wc -l < "$D/ports") -ge $([[ -n "$BENCH" ]] && echo 2 || echo 1) ]] && break
    sleep 0.1
done
PORT=$(sed -n 1p "$D/ports")
RELAY=$(sed -n 2p "$D/ports")
[[ -n "$PORT" ]] || { echo "FAIL: the fake API did not start"; cat "$D/server.err"; exit 1; }

BIND=
if [[ -n "${LLMCLIENT_DIS:-}" ]]; then
    mkdir -p "$D/lib"
    cp "$LLMCLIENT_DIS" "$D/lib/llmclient.dis"
    BIND="bind '#U*'$D/lib/llmclient.dis /dis/lib/llmclient.dis"
fi
ARGS="-p $PORT $VERBOSE"
[[ -n "$BENCH" ]] && ARGS="-b $RELAY 20"

T=$D/transcript
with_timeout 180 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "
bind '#U*'$D/certs /lib/certs
$BIND
{/dis/tests/llmclient_pool_test.dis $ARGS} >[2=1]
echo '<<<' end status '''$status''' '>>>'
echo halt > /dev/sysctl
" </dev/null >"$T" 2>&1
st=$?

if [[ -n "$BENCH" ]]; then
    grep '^bench' "$T" || { cat "$T"; exit 1; }
    exit 0
fi
[[ -n "$VERBOSE" ]] && cat "$T" || grep -E '^(--- |FAIL|PASS|ok|    )' "$T"
grep -q "^<<< end status '' >>>" "$T" && grep -qE '^PASS$' "$T" && exit 0
emu_timeout_ok "$st" || echo "emu exited $st"
echo "FAIL: llmclient_pool_test"
[[ -n "$VERBOSE" ]] || cat "$T"
cat "$D/server.err"
exit 1
