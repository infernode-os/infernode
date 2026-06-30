#!/bin/bash
#
# Production-path admission and slowloris guards for authenticated listeners.
#
# Starts a real `listen -T` server, connects a client that reads the server's
# first auth frame and then stalls, and verifies the listener hangs up that
# unauthenticated connection after the configured deadline.  A normal
# `mount -k` is then run against the same listener to prove legitimate clients
# still work.
#
# Usage:  run-auth-timeout.sh [port] [concurrency|rate] [listen|styxlisten]
# Exit:   0 = pass, 1 = failure, 2 = skipped (no emu)
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${1:-19680}"
MODE="${2:-concurrency}"
KIND="${3:-listen}"
KEY="/tmp/auth-timeout-key-$PORT"
IDENTITY="/tmp/auth-timeout-identity-$PORT"
case "$MODE" in
	concurrency) LIMIT_ARGS="-L 2 -R 100"; LIMIT_LOG='pre-auth limit reached'; ADMITTED=2 ;;
	rate)        LIMIT_ARGS="-L 4 -R 1";   LIMIT_LOG='pre-auth rate limit reached'; ADMITTED=1 ;;
	*) echo "usage: run-auth-timeout.sh [port] [concurrency|rate]" >&2; exit 2 ;;
esac
case "$KIND" in
	listen)     LISTEN_CMD="listen -sv $LIMIT_ARGS -T 5000 -a aes_256_cbc -a sha256 -k $KEY tcp!*!$PORT {cat /dev/user > $IDENTITY; export /lib &}" ;;
	styxlisten) LISTEN_CMD="styxlisten -sv $LIMIT_ARGS -T 5000 -a aes_256_cbc -a sha256 -k $KEY tcp!*!$PORT export /lib" ;;
	*) echo "usage: run-auth-timeout.sh [port] [concurrency|rate] [listen|styxlisten]" >&2; exit 2 ;;
esac
KEY_HOST="$ROOT$KEY"
IDENTITY_HOST="$ROOT$IDENTITY"
MNT="/n/auth-timeout-$PORT"
OUT="$ROOT/tmp/auth-timeout-$PORT.out"
SERVER_RC="$ROOT/tmp/auth-timeout-server-$PORT.rc"
CLIENT_RC="$ROOT/tmp/auth-timeout-client-$PORT.rc"

EMU=""
for c in "$ROOT/emu/Linux/o.emu" "$ROOT/emu/MacOSX/o.emu"; do
	[ -x "$c" ] && { EMU="$c"; break; }
done
[ -n "$EMU" ] || { echo "run-auth-timeout: no emu binary under $ROOT" >&2; exit 2; }

cleanup() {
	[ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
	rm -f "$SERVER_RC" "$CLIENT_RC" "$KEY_HOST" "$IDENTITY_HOST"
	rm -rf "$ROOT$MNT"
}
trap cleanup EXIT

mkdir -p "$ROOT/tmp" "$ROOT$MNT"
rm -f "$KEY_HOST" "$IDENTITY_HOST" "$OUT"

cat >"$SERVER_RC" <<EOF
load std
if {auth/createsignerkey -a ed25519 -f $KEY timeoutowner} {echo KEY-OK} {echo KEY-FAIL; raise 'fail:key'}
$LISTEN_CMD
EOF

"$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tmp/$(basename "$SERVER_RC")" >"$OUT" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 80); do
	[ -s "$KEY_HOST" ] && break
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "FAIL: listener exited before key generation"
		sed 's/^/    /' "$OUT"
		exit 1
	fi
	sleep 0.1
done
[ -s "$KEY_HOST" ] || { echo "FAIL: keyfile was not generated"; sed 's/^/    /' "$OUT"; exit 1; }

python3 - "$PORT" "$ADMITTED" <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
admitted = int(sys.argv[2])
def connect():
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    s.settimeout(3)
    return s

held = [connect() for _ in range(admitted)]
for i, s in enumerate(held):
    frame = s.recv(6)
    if not frame.startswith(b"0001\n"):
        print(f"FAIL: held client {i} expected auth version frame, got {frame!r}")
        sys.exit(1)

rejected = connect()
try:
    data = rejected.recv(1)
except (ConnectionResetError, BrokenPipeError, TimeoutError, OSError):
    data = b""
rejected.close()
if data:
    print(f"FAIL: over-limit client received authentication data: {data!r}")
    sys.exit(1)

held[0].close()
time.sleep(1.2)
replacement = connect()
frame = replacement.recv(6)
if not frame.startswith(b"0001\n"):
    print(f"FAIL: released pre-auth slot was not reusable: {frame!r}")
    sys.exit(1)

time.sleep(6)
for i, s in enumerate(held[1:] + [replacement]):
    try:
        data = s.recv(1)
    except (ConnectionResetError, BrokenPipeError, TimeoutError, OSError):
        data = b""
    finally:
        s.close()
    if data:
        print(f"FAIL: stalled pre-auth client {i} still readable after timeout: {data!r}")
        sys.exit(1)
print("PASS: pre-auth admission rejects excess, recovers, and closes on timeout")
PY
[ $? -eq 0 ] || { sed 's/^/    /' "$OUT"; exit 1; }

grep -q "$LIMIT_LOG" "$OUT" || {
	echo "FAIL: listener did not log the over-limit rejection"
	sed 's/^/    /' "$OUT"
	exit 1
}

cat >"$CLIENT_RC" <<EOF
load std
if {mount -k $KEY -C 'aes_256_cbc sha256' tcp!127.0.0.1!$PORT $MNT} {echo MOUNT-OK} {echo MOUNT-FAIL; raise 'fail:mount'}
if {cmp $MNT/ndb/inferno /lib/ndb/inferno} {echo AUTH-TIMEOUT-PASS} {echo AUTH-TIMEOUT-DIFF}
EOF

CLIENT_OUT="$("$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tmp/$(basename "$CLIENT_RC")" 2>&1)"
if echo "$CLIENT_OUT" | grep -q AUTH-TIMEOUT-PASS; then
	if [ "$KIND" = listen ] && [ "$(cat "$IDENTITY_HOST" 2>/dev/null)" != timeoutowner ]; then
		echo "FAIL: post-auth command did not run as authenticated identity"
		echo "    expected=timeoutowner observed=$(cat "$IDENTITY_HOST" 2>/dev/null)"
		exit 1
	fi
	echo "PASS: legitimate mount -k succeeds after stalled peer timeout"
	[ "$KIND" != listen ] || echo "PASS: post-auth command runs as authenticated identity"
	echo "ALL AUTH-TIMEOUT CHECKS PASSED ($KIND $MODE)"
	exit 0
fi

echo "FAIL: legitimate mount failed after timeout check"
echo "$CLIENT_OUT" | grep -vE '^fs:|^$' | sed 's/^/    /'
echo "--- listener output ---"
sed 's/^/    /' "$OUT"
exit 1
