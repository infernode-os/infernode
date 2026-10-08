#!/bin/sh
#
# xenith_agent_test.sh — the Agent window in a headless Xenith.
#
# Boots Xenith with no display (SDL dummy driver) against the scripted
# model.  Xenith forks its namespace at start, so its window files are
# reachable only from commands it runs itself: the test gives it a dump
# file whose one window is a shell script (Xenith re-runs a window's
# command on load, as acme does), and that script runs Agent with a
# first message, finds its window, and reads the body back through
# /chan into a file the host can see.  The message must have been sent,
# the tool call made, and the reply shown in the window.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis dis/xenith.dis xenith/dis/Agent.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display to run Xenith on"
	exit 77
fi

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
SCRIPT=
DRIVER=
OUT="$ROOT/tmp/xenith-agent-test.out"
DUMP="$ROOT/tmp/xenith-agent-test.dump"
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ "${KEEP:-0}" = 1 ] && return 0
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	[ -z "$DRIVER" ] || rm -f "$DRIVER"
	rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch" "$OUT" "$DUMP" \
		"$ROOT/tmp/xenith-agent-test.err" "$ROOT/tmp/xenith-agent-test.trace" "$ROOT/tmp/xenith-agent-test.agent" \
		"$ROOT/tmp/xenith-agent-test.tools9p" "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch" "$OUT"
mkdir -p "$ROOT/tmp"

# What runs inside Xenith: Agent, then the window's body, read back.
DRIVER="$ROOT/tests/inferno/.xenith-agent-driver.$$.sh"
cat > "$DRIVER" <<'EOF'
#!/dis/sh.dis
load std
echo start > /tmp/xenith-agent-test.trace
/xenith/dis/Agent.dis -p /usr/agentloop -t read,list -x SCENARIO:single_read >[2] /tmp/xenith-agent-test.agent &
id=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 {
	if {~ $#id 0} {
		for w in `{ls /chan} {
			if {ftest -f $w/tag} {
				if {grep -s '^/[+]Agent' $w/tag} {
					id=$w
				}
			}
		}
		sleep 1
	}
}
echo window $id >> /tmp/xenith-agent-test.trace
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 {
	if {! grep -s 'Read it.' $id/body} {
		sleep 1
	}
}
echo reply >> /tmp/xenith-agent-test.trace
{
	echo '@@ window' $id
	echo '@@ tag'
	cat $id/tag
	echo
	echo '@@ body'
	cat $id/body
	echo '@@ tools'
	cat /tool/tools
	echo '@@ log'
	cat /mnt/veltro/0/log
	echo '@@ end'
	echo DRIVER_DONE
} > /tmp/xenith-agent-test.out
EOF

# The dump: a working directory, no fonts, one column, one window
# running the driver (an 'e' line is an external command's window).
{
	printf '/usr/agentloop\n\n\n'
	printf '%11d \n' 0
	printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0
	printf 'ctl\n'
	printf '/usr/agentloop\n'
	printf 'sh /tests/inferno/%s\n' "$(basename "$DRIVER")"
} > "$DUMP"

SCRIPT="$ROOT/tests/inferno/.xenith-agent-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mkdir -p /usr/agentloop
echo alpha > /usr/agentloop/a.txt
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
bind -bc '#splumber' /chan
xenith -l /tmp/$(basename "$DUMP") >[2] /tmp/xenith-agent-test.err
EOF
chmod +x "$SCRIPT" "$DRIVER"

SDL_VIDEODRIVER=dummy OPENAI_API_KEY=test "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g1024x768 \
	-r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 180 ]; do
	grep -q '^DRIVER_DONE$' "$OUT" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

if ! { [ -f "$OUT" ] && grep -q '^DRIVER_DONE$' "$OUT"; }; then
	echo "FAIL: driver did not finish"
	[ -f "$OUT" ] && cat "$OUT"
	echo "--- trace:"
	[ -f "$ROOT/tmp/xenith-agent-test.trace" ] && cat "$ROOT/tmp/xenith-agent-test.trace"
	echo "--- agent:"
	[ -f "$ROOT/tmp/xenith-agent-test.agent" ] && cat "$ROOT/tmp/xenith-agent-test.agent"
	echo "--- xenith:"
	[ -f "$ROOT/tmp/xenith-agent-test.err" ] && cat "$ROOT/tmp/xenith-agent-test.err"
	echo "--- emu:"
	tail -20 "$WORK/emu.log"
	exit 1
fi
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$OUT"; }
FAILED=0
expect() {
	if section "$2" | grep -q -- "$3"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (section $2 lacks /$3/)"
		FAILED=$((FAILED + 1))
	fi
}
grep -q '^@@ window /chan/[0-9]' "$OUT" && echo "PASS: Agent window opened" || { echo "FAIL: no Agent window"; FAILED=$((FAILED + 1)); }
expect "tag has Send" tag 'Send'
expect "tag has Stop" tag 'Stop'
expect "body shows the user message" body 'SCENARIO:single_read'
expect "body shows the reply" body 'Read it.'
grep -q 'call_single_read_0_0' "$WORK/req.log" && echo "PASS: the model saw the tool result" || { echo "FAIL: no tool round trip in the model's requests"; FAILED=$((FAILED + 1)); }

[ "$FAILED" -eq 0 ] || { cat "$OUT"; echo "xenith_agent_test: $FAILED failed"; exit 1; }
echo "xenith_agent_test: PASS"
