#!/bin/sh
#
# Connections rejected by listen(1)'s global or per-source concurrency caps
# must not consume the shared pre-auth rate bucket.  Otherwise rejected work
# can starve an eligible peer without ever entering authentication.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }

PORT=${PORT:-17173}
PORT2=${PORT2:-$((PORT + 1))}
TIMEOUT=${TIMEOUT:-45}
mkdir -p "$ROOT/tmp"
SCRIPT="$ROOT/tmp/listen_rate_fairness_test.sh"
LOG="$ROOT/tmp/listen_rate_fairness_test.log"

cat > "$SCRIPT" <<EOF
load std
user=\`{cat /dev/user}
mkdir -p /tmp/listenrate/usr/\$user/keyring
bind -b /tmp/listenrate/usr /usr
auth/createsignerkey -f /usr/\$user/keyring/signer \$user-signer
auth/mkauthinfo -k 'key=signer' \$user /usr/\$user/keyring/default
listen -v -L 8 -P 1 -R 8 -T 5000 'tcp!*!$PORT' auxi/rstyxd &
listen -v -L 1 -P 0 -R 8 -T 5000 'tcp!*!$PORT2' auxi/rstyxd &
sleep 2
echo READY
sleep 20
echo halt > /dev/sysctl
EOF

: > "$LOG"
timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/listen_rate_fairness_test.sh >"$LOG" 2>&1 < /dev/null &
epid=$!
trap 'kill "$epid" 2>/dev/null; wait "$epid" 2>/dev/null' EXIT HUP INT TERM

i=0
while ! grep -q '^READY$' "$LOG" && [ $i -lt 100 ]; do
	sleep 0.1
	i=$((i + 1))
done
if ! grep -q '^READY$' "$LOG"; then
	echo "FAIL: listener did not become ready"
	tail -20 "$LOG"
	exit 1
fi

if python3 - "$PORT" "$PORT2" <<'PYEOF'
import socket, sys, time

port = int(sys.argv[1])
port2 = int(sys.argv[2])

def connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=2)
    s.settimeout(1)
    return s

held = connect(port)
if not held.recv(32).startswith(b"0001\n2"):
    raise SystemExit("first handshake got no auth greeting")

# With -P 1 these are all rejected by the source cap.  With the old order,
# seven of them nevertheless used the remaining seven -R tokens.
for _ in range(7):
    s = connect(port)
    try:
        s.recv(32)
    except (ConnectionResetError, OSError):
        pass
    s.close()

held.close()
time.sleep(0.15)
s = connect(port)
try:
    got = s.recv(32)
finally:
    s.close()
if not got.startswith(b"0001\n2"):
    raise SystemExit("eligible handshake was starved by source-cap rejects")

held = connect(port2)
if not held.recv(32).startswith(b"0001\n2"):
    raise SystemExit("global-cap handshake got no auth greeting")

# These find the one global slot occupied.  They must not consume the seven
# remaining rate tokens merely because -P 0 disables the source cap.
for _ in range(7):
    s = connect(port2)
    try:
        s.recv(32)
    except (ConnectionResetError, OSError):
        pass
    s.close()

held.close()
time.sleep(0.15)
s = connect(port2)
try:
    got = s.recv(32)
finally:
    s.close()
if not got.startswith(b"0001\n2"):
    raise SystemExit("eligible handshake was starved by global-cap rejects")
PYEOF
then
	echo "PASS: source-cap rejects do not consume the shared auth-rate bucket"
	echo "PASS: global-cap rejects do not consume the shared auth-rate bucket"
	exit 0
fi

echo "FAIL: source-cap rejects starved an eligible handshake"
tail -30 "$LOG"
exit 1
