#!/bin/sh
#
# agent_delegation_test.sh — activity 0 delegating to a task agent.
#
# Boots luciuisrv, tools9p (with the task tool) and lucibridge for
# activity 0 against the scripted model (agentloop/mock_openai.py), and
# runs a delegation end to end:
#
#   activity 0 creates a task (scenario delegate); the task agent reads a
#   file with its own tools (child_read) and reports; activity 0 is told
#   the task is done, as a turn of its own (parent_report), and uses its
#   own tools again; then the human talks to activity 0, once briefly and
#   once at length (a message longer than one 9P message).
#
# What it pins, each a way this broke after the loop moved into veltrosrv:
#   - the task agent can use its tools (its veltrosrv restricted /tool.N
#     away and the agent was left describing calls it could not make);
#   - activity 0 keeps its tools after delegating (each new tools9p swept
#     every shadow directory, the live ones activity 0 is bound through);
#   - activity 0 keeps talking to its own agent (each lucibridge mounted
#     its veltrosrv at /mnt/veltro in one shared namespace, so after the
#     first delegation activity 0 was writing to the task's session);
#   - the completion reaches activity 0 and is not shown as the human's;
#   - a reply is shown once (text's length was 0, so every turn replayed
#     the whole conversation into the UI);
#   - a long message arrives whole, as one message.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/veltro/tools/task.dis \
	dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
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
	rm -rf "$WORK" "$ROOT/tmp/deltest"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/tmp/deltest"
# A message longer than one 9P message (msize is 8K): words, then a mark.
LONG="SCENARIO:text_only go $(python3 -c "print(' '.join('w%d' % i for i in range(3000)))") TAILMARK"

SCRIPT="$ROOT/tests/inferno/.agent-delegation-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
mkdir -p /tmp/deltest/ndb /tmp/deltest/veltro
echo 'mode=local' > /tmp/deltest/ndb/llm
echo 'backend=openai' >> /tmp/deltest/ndb/llm
echo 'url=http://127.0.0.1:$PORT/v1' >> /tmp/deltest/ndb/llm
bind -bc /tmp/deltest/ndb /lib/ndb
echo > /tmp/deltest/veltro/welcome_shown
echo > /tmp/deltest/veltro/tour_offered
bind -bc /tmp/deltest/veltro /lib/veltro
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
luciuisrv
echo 'activity create Main' > /mnt/ui/ctl
/dis/veltro/tools9p -m /tool -b read,list read list task
lucibridge -v -a 0 >[2] /tmp/deltest/luci0.log &
sleep 3

fn waitfor {
	# waitfor <activity> <text>: until a message of the activity holds it
	a=\$1
	t=\$2
	echo 'waiting for' \$t
	n=''
	found=0
	while {! ~ \$found 1} {
		if {grep -s \$t /mnt/ui/activity/\$a/conversation/[0-9]* >[2] /dev/null} {
			found=1
		} {
			n=\`{echo \$n | sed 's/.*/&x/'}
			if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
				echo 'timed out waiting for' \$t
				found=1
			}
			sleep 1
		}
	}
}

echo 'SCENARIO:delegate go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Reported the child'
sleep 2
echo 'SCENARIO:text_only go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Hello from the mock'
sleep 2
echo -n '$LONG' > /mnt/ui/activity/0/conversation/input
sleep 5

for a in 0 1 {
	echo '@@ conversation' \$a
	for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 {
		if {ftest -e /mnt/ui/activity/\$a/conversation/\$i} {
			echo msg \$i
			cat /mnt/ui/activity/\$a/conversation/\$i | sed 's/w[0-9]* //g'
			echo
		}
	}
}
echo '@@ luci0'
cat /tmp/deltest/luci0.log
echo '@@ end'
echo DRIVER_DONE
EOF
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -pheap=512m -pmain=512m -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" \
	</dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 300 ]; do
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

LOG="$WORK/emu.log"
REQ="$WORK/req.log"
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: driver did not finish"; tail -40 "$LOG"; exit 1; }
FAILED=0
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"; }
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# What the model was sent, by scenario and turn: python reads the request log.
reqcheck() {	# description, python expression over r (the request) -> bool, scenario, turn
	if python3 -I - "$REQ" "$3" "$4" "$2" <<'PY'
import json, sys
log, scen, turn, expr = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
for line in open(log):
    r = json.loads(line)
    if r["scenario"] == scen and r["turn"] == turn:
        msgs = r["body"]["messages"]
        tools = [m for m in msgs if m.get("role") == "tool"]
        system = " ".join(str(m.get("content")) for m in msgs if m.get("role") == "system")
        users = [str(m.get("content")) for m in msgs if m.get("role") == "user"]
        sys.exit(0 if eval(expr) else 1)
sys.exit(2)
PY
	then ok "$1"; else bad "$1 (scenario $3 turn $4)"; fi
}

reqcheck "the task agent's read ran with its own tools" \
	'tools and not tools[-1]["content"].startswith("error")' child_read 1
reqcheck "activity 0 heard of the completion" \
	'"[task-event]" in users[-1] and "Child is done" in users[-1]' parent_report 0
reqcheck "activity 0's tools still work after delegating" \
	'tools and "tool not found" not in tools[-1]["content"] and "activity 1" in tools[-1]["content"]' parent_report 1
reqcheck "activity 0 talks to its own agent after delegating" \
	'"Chief of Staff" in system' text_only 0
if grep -q TAILMARK "$REQ" && python3 -I - "$REQ" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    for m in r["body"]["messages"]:
        c = str(m.get("content"))
        if m.get("role") == "user" and "TAILMARK" in c:
            sys.exit(0 if "SCENARIO:text_only go w0 " in c else 1)
sys.exit(1)
PY
then ok "a long message reaches the model whole"; else bad "a long message reaches the model whole"; fi

C0=$(section "conversation 0")
[ "$(printf '%s\n' "$C0" | grep -c 'text=Started Child.')" -eq 1 ] && ok "a reply is shown once" || bad "a reply is shown once"
[ "$(printf '%s\n' "$C0" | grep -c 'text=Hello from the mock.')" -eq 2 ] && ok "each turn shows only its own reply" || bad "each turn shows only its own reply"
printf '%s\n' "$C0" | grep -q 'role=human text=\[task-event\]' && bad "the completion is not shown as the human's" || ok "the completion is not shown as the human's"
printf '%s\n' "$C0" | grep -q 'text=Reported the child.' && ok "activity 0 reports the completion" || bad "activity 0 reports the completion"
[ "$(printf '%s\n' "$C0" | grep -c 'role=human text=SCENARIO:text_only')" -eq 2 ] && ok "the long message is one message" || bad "the long message is one message"
section "conversation 1" | grep -q 'text=Child is done.' && ok "the task agent reports" || bad "the task agent reports"

[ "$FAILED" -eq 0 ] || { tail -60 "$LOG"; echo "agent_delegation_test: $FAILED failed"; exit 1; }
echo "agent_delegation_test: PASS"
