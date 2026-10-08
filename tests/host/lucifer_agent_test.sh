#!/bin/sh
#
# lucifer_agent_test.sh — the agent through Lucia's full boot.
#
# Boots the whole Lucifer desktop headless (SDL dummy driver, logon
# skipped) with /lib/ndb/llm pointing at the scripted model, so boot.sh
# starts llmsrv, tools9p and lucibridge as it would for a user; then
# sends a message through /mnt/ui and reads the conversation back.  The
# message must be answered with a tool call made and the reply shown,
# through the same files Lucia itself reads.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and cannot boot the desktop"
	exit 77
fi

HERE="$ROOT/tests/host/agentloop"
WORK="$(mktemp -d)"
SERVER_PID=
EMU_PID=
cleanup() {
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch" "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch"
mkdir -p "$ROOT/usr/agentloop"
echo alpha > "$ROOT/usr/agentloop/a.txt"

# boot.sh reads /lib/ndb/llm; stage one naming the scripted backend and
# bind it over before the boot (the driver runs in the boot's shell).
DRIVER="mkdir -p /tmp/lucindb; echo 'mode=local' > /tmp/lucindb/llm; echo 'backend=openai' >> /tmp/lucindb/llm; echo 'url=http://127.0.0.1:$PORT/v1' >> /tmp/lucindb/llm; echo 'model=mock' >> /tmp/lucindb/llm; bind -bc /tmp/lucindb /lib/ndb; skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; echo '@@ status'; cat /mnt/ui/activity/0/status; echo; echo 'SCENARIO:read_system go' > /mnt/ui/activity/0/conversation/input; sleep 15; echo '@@ conversation'; for i in 0 1 2 3 4 5 6 7 8 9 { if {ftest -e /mnt/ui/activity/0/conversation/\$i} { echo msg \$i; cat /mnt/ui/activity/0/conversation/\$i; echo } }; echo '@@ end'; echo DRIVER_DONE"

SDL_VIDEODRIVER=dummy OPENAI_API_KEY=test "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 \
	-r"$ROOT" /dis/sh.dis -l -c "$DRIVER" </dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 150 ]; do
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

LOG="$WORK/emu.log"
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -40 "$LOG"; exit 1; }
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"; }
FAILED=0
expect() {
	if section "$2" | grep -q -- "$3"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (section $2 lacks /$3/)"
		FAILED=$((FAILED + 1))
	fi
}
expect "activity 0 came up" status '^\(idle\|active\)$'
expect "the human message is recorded" conversation 'role=human text=SCENARIO:read_system go'
expect "the reply is shown" conversation 'role=veltro text=Read the system prompt.'
grep -q 'call_read_system_0_0' "$WORK/req.log" && echo "PASS: the model saw the tool result" || { echo "FAIL: no tool round trip in the model's requests"; FAILED=$((FAILED + 1)); }
grep -q '"role": "tool", "content": "error' "$WORK/req.log" && { echo "FAIL: the read failed in the agent's namespace"; FAILED=$((FAILED + 1)); } || echo "PASS: the read succeeded in the agent's namespace"

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "lucifer_agent_test: $FAILED failed"; exit 1; }
echo "lucifer_agent_test: PASS"
