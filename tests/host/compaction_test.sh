#!/bin/sh
#
# compaction_test.sh — a long session is compacted without breaking a turn.
#
# llmsrv compacts a session's history when it grows past a mark: the
# history becomes a summary.  It ran at the end of every generation, one
# that ended in tool calls too, in the middle of the agent's turn: the
# tool calls went into the summary, and the results sent next answered
# calls the model's history no longer had, which a real API refuses.  Here
# llmsrv compacts at a mark so low that it does it after every
# generation, the scripted model refuses a result that answers no call,
# and an agent runs turns of several tool steps.  Each must finish.
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
	[ -z "${KEEP:-}" ] || { mkdir -p "$KEEP"; cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true; }
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

rm -rf "$ROOT/usr/agentloop"
SCRIPT="$ROOT/tests/inferno/.compaction-test.$$.sh"
cat > "$SCRIPT" <<EOS
#!/dis/sh.dis
load std
mkdir -p /usr/agentloop
echo alpha > /usr/agentloop/a.txt
echo beta > /usr/agentloop/b.txt
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock -c 5 &
sleep 1
/dis/veltro/tools9p.dis read list &
sleep 1
/dis/veltro/veltrosrv.dis -p /usr/agentloop
id=\`{cat /mnt/veltro/new}
for sc in two_reads dup_read text_and_tool error_streak {
	echo SCENARIO:\$sc go > /mnt/veltro/\$id/input
	cat /mnt/veltro/\$id/text > /dev/null
}
echo '@@ text'
cat /mnt/veltro/\$id/text
echo '@@ log'
cat /mnt/veltro/\$id/log
echo '@@ end'
echo DRIVER_DONE
EOS
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" </dev/null > "$WORK/emu.log" 2>&1 &
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
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

n=$(python3 -I -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if str(json.loads(l)["body"]["messages"][-1].get("content","")).startswith("Summarize this conversation")))' "$WORK/req.log")
[ "$n" -gt 2 ] && ok "the session was compacted ($n times)" || bad "the session was compacted ($n times)"
grep -q 'Model unavailable' "$LOG" && bad "no tool result outlives its call (the model service refused a turn)" || ok "no tool result outlives its call"
for want in "Read both." "Read twice." "Done looking." "Giving up."; do
	section text | grep -q -- "$want" && ok "a turn finishes across compaction: $want" || bad "a turn finishes across compaction: $want"
done

[ "$FAILED" -eq 0 ] || { tail -40 "$LOG"; echo "compaction_test: $FAILED failed"; exit 1; }
echo "compaction_test: PASS"
