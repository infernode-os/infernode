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
	rm -rf "$WORK" "$ROOT/tmp/deltest" "$ROOT/usr/deltest" "$ROOT/tmp/veltro/cow/kept-1000-2-${STALEKEY:-none}" "$ROOT/tmp/veltro/cow/kept-999-1-${KEPTKEY:-none}"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock_openai.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$ROOT/tmp/deltest" "$ROOT/usr/deltest"
# What an earlier session left: task 2's overlay of the same folder, with a
# change staged in it and never approved.  Activity ids start again at 1,
# so this session's task 2 is given the same overlay name; it must not
# take over that change, and the change must not be lost.
STALEKEY=$(python3 -I -c '
h = 0x811c9dc5
for b in b"/usr/deltest/notes":
    h = ((h ^ b) * 0x01000193) & 0xffffffff
print("%08x" % h)')
rm -rf "$ROOT/tmp/veltro/cow/2-$STALEKEY" "$ROOT/tmp/veltro/cow/kept-1000-2-$STALEKEY"
# And one an earlier session left under its own name (task 1, a folder no
# task here is given): set aside and offered back at start, then applied.
KEPTKEY=$(python3 -I -c '
h = 0x811c9dc5
for b in b"/usr/deltest/kept":
    h = ((h ^ b) * 0x01000193) & 0xffffffff
print("%08x" % h)')
KEPT="$ROOT/tmp/veltro/cow/1-$KEPTKEY"
rm -rf "$KEPT" "$ROOT/tmp/veltro/cow/kept-999-1-$KEPTKEY"; mkdir -p "$KEPT" "$ROOT/usr/deltest/kept"
printf 'basepath=/usr/deltest/kept\nboot=999\n' > "$KEPT/.cowmeta"
echo old > "$ROOT/usr/deltest/kept/k.txt"
echo new > "$KEPT/k.txt"
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
echo 'create id=notes type=markdown label=Notes' > /mnt/ui/activity/1/presentation/ctl
echo '@@ task status'
echo 'status 1' > /tool/task/run
cat /tool/task/run
echo
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

echo add write > /mnt/toolctl/ctl
echo add edit > /mnt/toolctl/ctl
echo 'SCENARIO:raw_write go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Wrote it raw'
echo '@@ raw file'
cat /tmp/veltro/scratch/0/raw.b
echo '@@ raw file end'

mkdir -p /tmp/veltro/scratch/0
{echo 'implement Good;'; echo 'include "sys.m";'; echo 'include "draw.m";'; echo 'Good: module { init: fn(nil: ref Draw->Context, nil: list of string); };'; echo 'init(nil: ref Draw->Context, nil: list of string) { }'} > /tmp/veltro/scratch/0/good.b
{echo 'implement Bad;'; echo 'include "sys.m";'; echo 'include "draw.m";'; echo 'Bad: module { init: fn(nil: ref Draw->Context, nil: list of string); };'; echo 'init(nil: ref Draw->Context, nil: list of string) { undeclared = 1; }'} > /tmp/veltro/scratch/0/bad.b
{echo 'implement C;'; echo 'include "sys.m";'; echo 'include "draw.m";'; echo 'C: module { init: fn(nil: ref Draw->Context, nil: list of string); };'; echo '// a comment as C writes one'; echo 'init(nil: ref Draw->Context, nil: list of string) { }'} > /tmp/veltro/scratch/0/ccomment.b
echo 'SCENARIO:compile_check go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Compiled the files'
echo 'SCENARIO:compile_loop go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'It still fails'

echo '/help' > /mnt/ui/activity/0/conversation/input
sleep 2
mkdir -p /usr/deltest/notes
{echo Shopping; echo '- eggs'; echo '- milk'} > /usr/deltest/notes/todo.txt
echo '/bind /usr/deltest/notes rw' > /mnt/ui/activity/0/conversation/input
sleep 2
mkdir -p /usr/deltest/more
echo one > /usr/deltest/more/m.txt
echo '/bind /usr/deltest/more rw' > /mnt/ui/activity/0/conversation/input
sleep 2
# (made after activity 0 started, which sets aside what it finds then)
mkdir -p /tmp/veltro/cow/2-$STALEKEY
{echo 'basepath=/usr/deltest/notes'; echo 'boot=1000'} > /tmp/veltro/cow/2-$STALEKEY/.cowmeta
{echo Shopping; echo '- eggs'; echo '- milk'; echo '- STALE'} > /tmp/veltro/cow/2-$STALEKEY/todo.txt
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
cat /usr/deltest/more/m.txt
echo '@@ kept overlay'
cat /tmp/veltro/cow/kept-1000-2-$STALEKEY/todo.txt


echo 'SCENARIO:spill_readback go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Spill read'
echo 'SCENARIO:grant_baseline go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Granted the baseline'

echo 'SCENARIO:backend_down go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Model unavailable'

echo 'SCENARIO:step_cap go' > /mnt/ui/activity/0/conversation/input
sleep 4
echo 'SCENARIO:text_only typed during the turn' > /mnt/ui/activity/0/conversation/input
sleep 2
echo '@@ typed shown'
grep -l 'typed during the turn' /mnt/ui/activity/0/conversation/[0-9]* | wc -l
echo '@@ stopping'
echo '/stop' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Hello from the mock' 
sleep 3

echo 'SCENARIO:delegate_loop go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Started the looper'
sleep 4
echo '@@ looper closing'
echo 'activity delete 4' > /mnt/ui/ctl
sleep 6
echo '@@ looper closed'
sleep 6
echo '@@ looper later'

echo 'Apply 1' > /mnt/ui/activity/0/conversation/input
sleep 3
echo '@@ kept applied'
cat /usr/deltest/kept/k.txt
ls /tmp/veltro/cow
echo '@@ kept end'

for a in 0 1 2 {
	echo '@@ conversation' \$a
	for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 {
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
want=$(printf '\n"quoted" first line\n\tsys->print("%%d\\t%%d\\n", i, j);')
got=$(section "raw file")
[ "$got" = "$want" ] && ok "a native write and edit keep the text as given" || bad "a native write and edit keep the text as given (got: $(printf '%s' "$got" | od -c | head -3))"
reqcheck "a task granted what every agent reads is created" \
	'tools and tools[-1]["content"].startswith("created activity")' grant_baseline 1
reqcheck "limbo compile passes a file that compiles" \
	'any("good.b compiles." in t["content"] for t in tools)' compile_check 1
reqcheck "limbo compile fails a file that does not, with the compiler's error" \
	'any("bad.b does not compile" in t["content"] and "undeclared" in t["content"] for t in tools)' compile_check 1
reqcheck "the same failure a third time says the changes are not fixing it" \
	'tools and "failed 3 times this turn" in tools[-1]["content"]' compile_loop 5
reqcheck "not before" \
	'tools and "failed 3 times" not in tools[-1]["content"] and "harness:" not in tools[-1]["content"]' compile_loop 3
reqcheck "a C comment's failure says how Limbo writes one" \
	'any("ccomment.b" in t["content"] and "comments begin with #" in t["content"] for t in tools)' compile_check 1
reqcheck "a task's edit with a space in it is made" \
	'tools and "replaced 1" in tools[-1]["content"]' child_edit 1
reqcheck "activity 0 is told the task's change is staged" \
	'"STAGED" in users[-1] and "todo.txt" in users[-1]' parent_promote 0
reqcheck "promote applies the staged change" \
	'tools and "promoted" in tools[-1]["content"]' parent_promote 1
section "before promote" | grep -q bread && bad "a staged change is not in the file before promote" || ok "a staged change is not in the file before promote"
section "after promote" | grep -q -- '- bread' && ok "the promoted change is in the file" || bad "the promoted change is in the file"
python3 -I -c 'import json,sys
first = back = None
for l in open(sys.argv[1]):
    for m in json.loads(l)["body"]["messages"]:
        if m.get("role") == "tool" and m.get("tool_call_id") == "call_spill_readback_0_0": first = str(m.get("content"))
        if m.get("role") == "tool" and m.get("tool_call_id") == "call_spill_readback_1_0": back = str(m.get("content"))
ok = first is not None and "full output at" in first and back is not None and not back.startswith("error") and "1\t" in back
sys.exit(0 if ok else 1)' "$WORK/req.log" && ok "a long result is read back where the agent is told it is" || bad "a long result is read back where the agent is told it is"
section "task status" | grep -q '^recently used (latest first): /lib/veltro/system.txt (via read)' && ok "task status says what the task has used" || bad "task status says what the task has used"
section "task status" | grep -q '^documents, in its own tab (task 1), not yours: notes "Notes"' && ok "task status says where the task's documents are" || bad "task status says where the task's documents are"
section "task status" | grep -q '^last said: Child is done' && ok "task status says what the task last said" || bad "task status says what the task last said"
section "after promote" | grep -q '^two$' && ok "a task's changes to a second folder are promoted too" || bad "a task's changes to a second folder are promoted too"
section "after promote" | grep -q STALE && bad "an earlier session's staged change was promoted with this task's" || ok "an earlier session's staged change was not taken over"
grep -q 'offered 1 kept change set' "$LOG" && section "conversation 0" | grep -q 'options=Apply 1,Discard 1 text=M /usr/deltest/kept/k.txt' && ok "changes kept from an earlier session are offered at start" || bad "changes kept from an earlier session are offered at start"
python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    m = json.loads(l)["body"]["messages"]
    if any("were never applied" in str(x.get("content", "")) for x in m): sys.exit(0)
sys.exit(1)' "$WORK/req.log" && ok "the agent is told of them" || bad "the agent is told of them"
section "kept applied" | grep -q '^new$' && ok "Apply puts them in the folder" || bad "Apply puts them in the folder"
section "kept applied" | grep -q 'kept-999' && bad "an applied set is still kept" || ok "an applied set is no longer kept"
section "kept overlay" | grep -q STALE && ok "an earlier session's staged change is kept aside" || bad "an earlier session's staged change is kept aside"

before=$(section "agents before close" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9)
after=$(section "agents after close" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9)
if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -lt "$before" ]; then
	ok "a closed task's agent stops ($before -> $after lucibridge processes)"
else
	bad "a closed task's agent stops ($before -> $after lucibridge processes)"
fi
section "tool mount after close" | grep -q '/tool.1/tools *$' && bad "a closed task's tool server is unmounted" || ok "a closed task's tool server is unmounted"

# The looper's model calls after it is closed (and a moment for the call
# in flight): none.
steps_after=$(awk '/^@@ looper closed$/ {p=1; next} /^@@ looper later$/ {p=0} p && /^veltrosrv: step [0-9]+: writing/' "$LOG" | wc -l)
steps_before=$(awk '/^@@ looper closing$/ {p=0} /Started the looper/ {p=1} p && /^veltrosrv: step [0-9]+: writing/' "$LOG" | wc -l)
if [ "$steps_before" -gt 2 ] && [ "$steps_after" -eq 0 ]; then
	ok "a task closed while it works stops ($steps_before steps, then $steps_after)"
else
	bad "a task closed while it works stops ($steps_before steps, then $steps_after)"
fi
grep -q 'turn done stop=cancelled' "$LOG" && ok "its turn ends cancelled" || bad "its turn ends cancelled"

C0=$(section "conversation 0")
printf '%s\n' "$C0" | grep -q 'dtype=dialogue title=Model unavailable' && ok "the model service failing is said so, plainly" || bad "the model service failing is said so, plainly"
printf '%s\n' "$C0" | grep -q 'role=veltro text=Error:' && bad "no raw error is shown as the agent's reply" || ok "no raw error is shown as the agent's reply"
[ "$(section "typed shown" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9)" = 1 ] && ok "what the user types during a turn is shown at once" || bad "what the user types during a turn is shown at once"
awk '/^@@ stopping$/{p=1} p' "$LOG" | grep -q 'veltrosrv: turn done stop=cancelled' && ok "/stop stops the turn" || bad "/stop stops the turn"
[ "$(printf '%s\n' "$C0" | grep -c 'role=human text=SCENARIO:text_only typed during the turn')" -eq 1 ] && ok "what was typed is shown once, and answered after" || bad "what was typed is shown once, and answered after"
[ "$(printf '%s\n' "$C0" | grep -c 'text=Started Child.')" -eq 1 ] && ok "a reply is shown once" || bad "a reply is shown once"
[ "$(printf '%s\n' "$C0" | grep -c 'text=Hello from the mock.')" -eq 3 ] && ok "each turn shows only its own reply" || bad "each turn shows only its own reply"
printf '%s\n' "$C0" | grep -q 'role=human text=\[task-event\]' && bad "the completion is not shown as the human's" || ok "the completion is not shown as the human's"
printf '%s\n' "$C0" | grep -q 'text=Reported the child.' && ok "activity 0 reports the completion" || bad "activity 0 reports the completion"
[ "$(printf '%s\n' "$C0" | grep -c 'role=human text=SCENARIO:text_only go')" -eq 2 ] && ok "the long message is one message" || bad "the long message is one message"
section "conversation 1" | grep -q 'text=Child is done.' && ok "the task agent reports" || bad "the task agent reports"
printf '%s\n' "$C0" | grep -q 'role=veltro text=/stop' && ok "a slash command is answered where the user sees it" || bad "a slash command is answered where the user sees it"

[ "$FAILED" -eq 0 ] || { tail -60 "$LOG"; echo "agent_delegation_test: $FAILED failed"; exit 1; }
echo "agent_delegation_test: PASS"
