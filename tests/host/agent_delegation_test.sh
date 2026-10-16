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
#   - a long message arrives whole, as one message;
#   - a tool turned on after the agent started can be called (the agent's
#     restricted /tool was a snapshot of the tools active at its start).
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
	# KEEP=<dir>: keep the emulator's and the model's logs there.
	[ -z "${KEEP:-}" ] || { mkdir -p "$KEEP"; cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true; }
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$WORK" "$ROOT/tmp/deltest" "$ROOT/usr/deltest"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/tmp/deltest" "$ROOT/usr/deltest"
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
/dis/veltro/tools9p -v -m /tool -b read,list,edit read list task
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
echo add find > /mnt/toolctl/ctl
echo 'SCENARIO:late_tool go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Found with a late tool'

echo add limbo > /mnt/toolctl/ctl
echo 'SCENARIO:gate go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Gate checked'

echo '/help' > /mnt/ui/activity/0/conversation/input
sleep 2
mkdir -p /usr/deltest/notes
{echo Shopping; echo '- eggs'; echo '- milk'} > /usr/deltest/notes/todo.txt
echo '/bind /usr/deltest/notes rw' > /mnt/ui/activity/0/conversation/input
sleep 2
echo 'SCENARIO:delegate_edit go' > /mnt/ui/activity/0/conversation/input
n=''
while {! ~ \`{cat /mnt/ui/activity/0/status} blocked} {
	n=\`{echo \$n | sed 's/.*/&x/'}
	if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
		echo 'timed out waiting for the approval'
		echo blocked > /mnt/ui/activity/0/status
	}
	sleep 1
}
echo '@@ before promote'
cat /usr/deltest/notes/todo.txt
echo Allow > /mnt/ui/activity/0/conversation/input
waitfor 0 'Promoted the edit'
echo '@@ after promote'
cat /usr/deltest/notes/todo.txt


for a in 0 1 2 {
	echo '@@ conversation' \$a
	for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 {
		if {ftest -e /mnt/ui/activity/\$a/conversation/\$i} {
			echo msg \$i
			cat /mnt/ui/activity/\$a/conversation/\$i | sed 's/w[0-9]* //g'
			echo
		}
	}
}
echo '@@ luci0'
cat /tmp/deltest/luci0.log
echo '@@ agents before close'
ps | grep LuciBridge | wc -l
echo 'activity delete 1' > /mnt/ui/ctl
sleep 5
echo '@@ agents after close'
ps | grep LuciBridge | wc -l
echo '@@ tool mount after close'
ls -d /tool.1 /tool.1/tools >[2=1]
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
reqcheck "a tool turned on later is offered" \
	'"find" in [t["function"]["name"] for t in r["body"].get("tools", [])]' late_tool 0
reqcheck "a tool turned on later can be called" \
	'tools and "tool not found" not in tools[-1]["content"]' late_tool 1
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

reqcheck "the compile gate passes code that compiles" \
	'any("status: compiled" in t["content"] for t in tools)' gate 1
reqcheck "the compile gate fails code that does not, with the compiler's error" \
	'any("status: failed" in t["content"] and "undeclared" in t["content"] for t in tools)' gate 1
reqcheck "a task's edit with a space in it is made" \
	'tools and "replaced 1" in tools[-1]["content"]' child_edit 1
reqcheck "activity 0 is told the task's change is staged" \
	'"STAGED" in users[-1] and "todo.txt" in users[-1]' parent_promote 0
reqcheck "promote applies the staged change" \
	'tools and "promoted" in tools[-1]["content"]' parent_promote 1
section "before promote" | grep -q bread && bad "a staged change is not in the file before promote" || ok "a staged change is not in the file before promote"
section "after promote" | grep -q -- '- bread' && ok "the promoted change is in the file" || bad "the promoted change is in the file"

before=$(section "agents before close" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9)
after=$(section "agents after close" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9)
if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
	ok "a closed task's agent stops ($before -> $after lucibridge processes)"
else
	bad "a closed task's agent stops ($before -> $after lucibridge processes)"
fi
section "tool mount after close" | grep -q '/tool.1/tools *$' && bad "a closed task's tool server is unmounted" || ok "a closed task's tool server is unmounted"

C0=$(section "conversation 0")
[ "$(printf '%s\n' "$C0" | grep -c 'text=Started Child.')" -eq 1 ] && ok "a reply is shown once" || bad "a reply is shown once"
[ "$(printf '%s\n' "$C0" | grep -c 'text=Hello from the mock.')" -eq 2 ] && ok "each turn shows only its own reply" || bad "each turn shows only its own reply"
printf '%s\n' "$C0" | grep -q 'role=human text=\[task-event\]' && bad "the completion is not shown as the human's" || ok "the completion is not shown as the human's"
printf '%s\n' "$C0" | grep -q 'text=Reported the child.' && ok "activity 0 reports the completion" || bad "activity 0 reports the completion"
[ "$(printf '%s\n' "$C0" | grep -c 'role=human text=SCENARIO:text_only')" -eq 2 ] && ok "the long message is one message" || bad "the long message is one message"
section "conversation 1" | grep -q 'text=Child is done.' && ok "the task agent reports" || bad "the task agent reports"
printf '%s\n' "$C0" | grep -q 'role=veltro text=/bind <path>' && ok "a slash command is answered where the user sees it" || bad "a slash command is answered where the user sees it"

[ "$FAILED" -eq 0 ] || { tail -60 "$LOG"; echo "agent_delegation_test: $FAILED failed"; exit 1; }
echo "agent_delegation_test: PASS"
