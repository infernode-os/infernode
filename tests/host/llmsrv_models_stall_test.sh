#!/bin/sh
#
# llmsrv_models_stall_test.sh — a read of /mnt/llm/models asks the
# backend, and one that does not answer must not stop llmsrv: other
# reads go on being answered while it waits.  It was made in the serve
# loop, so a stalled backend stopped every session.
#
set -e

. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }

WORK="$(mktemp -d)"
SERVER_PID=
SCRIPT=
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

# accepts, never answers
cat > "$WORK/server.py" <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
print(s.getsockname()[1], flush=True)
held = []
while True:
    held.append(s.accept()[0])
PY

python3 -I "$WORK/server.py" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

SCRIPT="$ROOT/tests/inferno/.llmsrv-models-stall.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mkdir -p /tmp
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 2
cat /mnt/llm/models > /dev/null &
sleep 1
# llmsrv answers while that read waits
{ cat /mnt/llm/new > /dev/null; echo R answered } &
sleep 3
echo R done
echo halt > '#c/sysctl'
EOF

LOG="$WORK/log"
cd "$ROOT"
OPENAI_API_KEY=test with_timeout 30 "$EMU" -c1 -r"$ROOT" /dis/sh.dis \
	"/tests/inferno/$(basename "$SCRIPT")" </dev/null > "$LOG" 2>&1 || true

failed=0
if grep -q '^R done' "$LOG"; then echo "PASS: the driver finished"; else echo "FAIL: the driver did not finish"; failed=1; fi
if grep -q '^R answered' "$LOG"; then echo "PASS: llmsrv answered while models waited"; else echo "FAIL: llmsrv stopped behind models"; failed=1; fi
if [ "$failed" = 0 ]; then echo "ALL PASS"; exit 0; fi
tail -20 "$LOG"
exit 1
