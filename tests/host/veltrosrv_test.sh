#!/bin/sh
#
# veltrosrv_test.sh — the contract of /mnt/veltro.
#
# Boots the agent stack against the scripted model (agentloop/mock_openai.py)
# and checks what veltrosrv(4) promises: the files a session has; that text
# and log end when the session is idle and follow a turn while it runs;
# that input is refused while a turn runs; that cancel stops a turn; that
# ctl validates; and that the agent's tools cannot see /mnt/veltro at all,
# which is what makes approve and ctl safe.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$ROOT/usr/agentloop" "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch"
SCRIPT="$ROOT/tests/inferno/.veltrosrv-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mkdir -p /usr/agentloop
echo alpha > /usr/agentloop/a.txt
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
/dis/veltro/tools9p.dis read list write &
sleep 1
/dis/veltro/veltrosrv.dis -p /usr/agentloop

echo '@@ root'
ls /mnt/veltro
id=\`{cat /mnt/veltro/new}
echo '@@ session'
echo \$id
ls /mnt/veltro/\$id
echo '@@ ctl'
cat /mnt/veltro/\$id/ctl
echo '@@ idle text'
cat /mnt/veltro/\$id/text
echo '@@ idle approve'
cat /mnt/veltro/\$id/approve
echo '@@ status'
cat /mnt/veltro/\$id/status
echo '@@ bad ctl'
echo nonsense > /mnt/veltro/\$id/ctl
echo gate sideways > /mnt/veltro/\$id/ctl
echo persona ../../etc > /mnt/veltro/\$id/ctl
echo maxsteps 3 > /mnt/veltro/\$id/ctl
echo '@@ ctl after'
cat /mnt/veltro/\$id/ctl

echo '@@ turn'
echo 'SCENARIO:single_read go' > /mnt/veltro/\$id/input
echo '@@ busy'
echo 'another' > /mnt/veltro/\$id/input
cat /mnt/veltro/\$id/text > /dev/null
echo '@@ text'
cat /mnt/veltro/\$id/text
echo '@@ status after'
cat /mnt/veltro/\$id/status

echo '@@ cancel'
echo maxsteps 100 > /mnt/veltro/\$id/ctl
echo 'SCENARIO:step_cap go' > /mnt/veltro/\$id/input
sleep 1
echo cancel > /mnt/veltro/\$id/ctl
cat /mnt/veltro/\$id/text > /dev/null
echo '@@ cancelled'
grep 'turn done' /mnt/veltro/\$id/log

echo '@@ probe'
echo 'SCENARIO:probe_mount go' > /mnt/veltro/\$id/input
cat /mnt/veltro/\$id/text > /dev/null
grep 'tool list: done' /mnt/veltro/\$id/log

echo '@@ close'
echo close > /mnt/veltro/\$id/ctl
ls /mnt/veltro
echo DRIVER_DONE
EOF
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 120 ]; do
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

LOG="$WORK/emu.log"
FAILED=0
check() {	# description, grep pattern (in the whole log)
	if grep -q -- "$2" "$LOG"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (no /$2/)"
		FAILED=$((FAILED + 1))
	fi
}
section() {	# name: the lines between @@ name and the next @@
	awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"
}
expect() {	# description, section, pattern
	if section "$2" | grep -q -- "$3"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (section $2 lacks /$3/)"
		FAILED=$((FAILED + 1))
	fi
}
expectnot() {
	if section "$2" | grep -q -- "$3"; then
		echo "FAIL: $1 (section $2 has /$3/)"
		FAILED=$((FAILED + 1))
	else
		echo "PASS: $1"
	fi
}

grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -30 "$LOG"; exit 1; }

expect "root lists new" root '/new$'
for f in ctl input text log status approve; do
	expect "session has $f" session "/$f\$"
done
expect "ctl reads settings" ctl 'persona= role= model= think=0 maxsteps=100 gate=on llm= busy=0'
expectnot "idle text is empty" "idle text" '.'
expectnot "idle approve is empty" "idle approve" '.'
expect "status idle" status '^idle$'
expect "unknown ctl refused" "bad ctl" 'unknown control request'
expect "bad gate refused" "bad ctl" 'gate on|off'
expect "persona name validated" "bad ctl" 'bad persona name'
expect "maxsteps applied" "ctl after" 'maxsteps=3'
expect "input refused while busy" busy 'busy'
expect "text has the user message" text '^== user$'
expect "text has the reply" text '^Read it.$'
expect "status idle after turn" "status after" '^idle$'
expect "cancel stops the turn" cancelled 'stop=cancelled'
expect "the tool cannot see /mnt/veltro" probe "does not exist"
expectnot "close removes the session" close "^0\$"

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "veltrosrv_test: $FAILED failed"; exit 1; }
echo "veltrosrv_test: PASS"
