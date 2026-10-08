#!/bin/sh
#
# veltro_cli_test.sh — the veltro command as a client of the harness.
#
# Against the scripted model: a task runs and prints the tool call and
# the reply; its session is saved under /usr/inferno/veltro/sessions and
# -r last resumes it; -y runs without the approval gate.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltro.dis dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/llmsrv.dis; do
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
	rm -rf "$ROOT/usr/agentloop" "$ROOT/usr/inferno/veltro/sessions/scenariosingle-read-go" \
		"$ROOT/usr/inferno/veltro/sessions/scenariosingle-read-go-"* "$WORK"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/usr/agentloop" "$ROOT/tmp/veltro/cow" "$ROOT/tmp/veltro/scratch"
SCRIPT="$ROOT/tests/inferno/.veltro-cli-test.$$.sh"
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
echo '@@ run'
/dis/veltro/veltro.dis -y -p /usr/agentloop 'SCENARIO:single_read go'
echo '@@ session'
cat /usr/inferno/veltro/sessions/last
echo
ls /usr/inferno/veltro/sessions/\`{cat /usr/inferno/veltro/sessions/last}
echo '@@ log'
cat /usr/inferno/veltro/sessions/\`{cat /usr/inferno/veltro/sessions/last}^/log
echo '@@ resume'
/dis/veltro/veltro.dis -y -r last 'SCENARIO:text_only go'
echo '@@ mounts'
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
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -30 "$LOG"; exit 1; }
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
expectnot() {
	if section "$2" | grep -q -- "$3"; then
		echo "FAIL: $1 (section $2 has /$3/)"
		FAILED=$((FAILED + 1))
	else
		echo "PASS: $1"
	fi
}
expect "the tool call is shown" run '^\[read '
expect "the reply is shown" run '^Read it.$'
expect "the session was named" session '^scenariosingle-read-go'
expect "the session has its task" session '/task$'
expect "the session has its transcript" session '/transcript$'
expect "the session log records the call" log '^step 1: read .* -> .*alpha'
expect "resume says so" resume 'resuming session scenariosingle-read-go'
expect "resume runs the task again" resume '^Read it.$'
grep -q 'Resuming Task' "$WORK/req.log" && echo "PASS: the model got the resume context" || { echo "FAIL: no resume context reached the model"; FAILED=$((FAILED + 1)); }
expectnot "the server is stopped after the run" mounts 'new'

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "veltro_cli_test: $FAILED failed"; exit 1; }
echo "veltro_cli_test: PASS"
