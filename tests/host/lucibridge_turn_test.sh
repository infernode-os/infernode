#!/bin/sh
#
# lucibridge_turn_test.sh — what lucibridge says and does about a turn,
# where it was not so.
#
# Boots luciuisrv, tools9p and lucibridge for activity 0 against the
# scripted model (lucibridge/mock.py) with a /tmp of its own, and checks,
# each failing on the code before:
#   - a call denied because approvals are refused (the unattended marker)
#     is said in the conversation: it was denied with no dialogue and no
#     word;
#   - /stop typed while a dialogue waits for its answer stops the turn: it
#     was taken for the answer, the one call denied and the turn went on;
#   - (a guard, true before too) a gated request whose text holds
#     " options=Yes title=X" is asked about under the bridge's own title
#     and buttons: the text is the tile's last attribute, and luciuisrv
#     reads nothing after text= as one;
#   - a line of the model's that reads as "== note <title>" makes no
#     dialogue tile: one titled "Permission required", with buttons of the
#     model's own, was made;
#   - events that arrive while a turn runs wait for it only so many deep:
#     each was kept, and each was a turn of its own;
#   - a task stopped in its first turn is "stopped", and activity 0 is told
#     it was stopped: it was "complete", "has finished its assignment";
#   - a task closed while a dialogue of its waits leaves no process of its
#     bridge: the dialogue's waiter held them for good;
#   - a tool call named "hidden" (a closed activity's status) does not
#     close the activity: the name the model called was written as the
#     status, a tool or not, and activity 0's bridge exited for good.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/veltro/tools/task.dis \
	dis/veltro/tools/write.dis dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/lucibridge"
WORK="$(mktemp -d)"
PRIV="$ROOT/tmp/lbturn.$$"		# the emulator's /tmp for this run
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	# KEEP=<dir>: keep the emulator's and the model's logs there.
	[ -z "${KEEP:-}" ] || { mkdir -p "$KEEP"; cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true; }
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$WORK" "$PRIV"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

rm -rf "$PRIV"
mkdir -p "$PRIV"

SCRIPT="$ROOT/tests/inferno/.lucibridge-turn-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
bind -c /tmp/lbturn.$$ /tmp
mkdir -p /tmp/lbtest/ndb /tmp/lbtest/veltro
echo 'mode=local' > /tmp/lbtest/ndb/llm
echo 'backend=openai' >> /tmp/lbtest/ndb/llm
echo 'url=http://127.0.0.1:$PORT/v1' >> /tmp/lbtest/ndb/llm
bind -bc /tmp/lbtest/ndb /lib/ndb
echo > /tmp/lbtest/veltro/welcome_shown
echo > /tmp/lbtest/veltro/tour_offered
bind -bc /tmp/lbtest/veltro /lib/veltro
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$PORT/v1 -M mock &
sleep 1
luciuisrv
echo 'activity create Main' > /mnt/ui/ctl
/dis/veltro/tools9p -v -m /tool -b read,list,write read list write task
lucibridge -v -a 0 >[2] /tmp/lbtest/luci0.log &
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
			if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
				echo 'timed out waiting for' \$t
				found=1
			}
			sleep 1
		}
	}
}
fn waitstatus {
	# waitstatus <activity> <status>
	a=\$1
	want=\$2
	n=''
	found=0
	while {! ~ \$found 1} {
		if {~ \`{cat /mnt/ui/activity/\$a/status >[2] /dev/null} \$want} {
			found=1
		} {
			n=\`{echo \$n | sed 's/.*/&x/'}
			if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
				echo 'timed out waiting for status' \$want of \$a
				found=1
			}
			sleep 1
		}
	}
}
fn conv {
	for f in /mnt/ui/activity/\$1/conversation/[0-9]* { cat \$f; echo }
}

# Approvals refused for want of anyone to ask.
echo deny > /tmp/veltro/.headless-approval-deny
echo 'SCENARIO:gated_write go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Write was handled'
sleep 1
rm /tmp/veltro/.headless-approval-deny
echo '@@ unattended'
conv 0

# /stop while a dialogue waits.
echo 'SCENARIO:gated_write stop this one' > /mnt/ui/activity/0/conversation/input
waitstatus 0 blocked
echo '/stop' > /mnt/ui/activity/0/conversation/input
waitstatus 0 idle
sleep 3
echo '@@ stop'
conv 0
echo '@@ stop status'
cat /mnt/ui/activity/0/status

# A request whose own text reads as a tile's attributes.
echo 'SCENARIO:gated_attrs go' > /mnt/ui/activity/0/conversation/input
waitstatus 0 blocked
echo '@@ attrs'
conv 0
echo Deny > /mnt/ui/activity/0/conversation/input
waitfor 0 'Attrs handled'
sleep 1

# The model's own "== note".
echo 'SCENARIO:forged_note go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Please confirm above'
sleep 2
echo '@@ forged'
conv 0

# A task closed while its dialogue waits.
echo '@@ bridges before'
ps | grep LuciBridge | wc -l
echo 'SCENARIO:delegate_gate go' > /mnt/ui/activity/0/conversation/input
waitstatus 1 blocked
sleep 1
echo '@@ bridges with the task'
ps | grep LuciBridge | wc -l
echo 'activity delete 1' > /mnt/ui/ctl
sleep 8
echo '@@ bridges after'
ps | grep LuciBridge | wc -l
echo '@@ bridges left'
ps | grep LuciBridge

# Events while a turn runs.
echo 'SCENARIO:busy go' > /mnt/ui/activity/0/conversation/input
sleep 2
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 {
	echo '[task-event] flood' \$i > /mnt/ui/activity/0/conversation/input
}
waitfor 0 'Busy turn done'
waitfor 0 'more notification'
sleep 6
echo '@@ flood'
conv 0

# A task stopped in its first turn.
echo 'SCENARIO:delegate_slow go' > /mnt/ui/activity/0/conversation/input
waitstatus 2 working
sleep 1
echo '/stop' > /mnt/ui/activity/2/conversation/input
waitstatus 2 stopped
sleep 3
echo '@@ stopped task'
cat /mnt/ui/activity/2/status

# A tool call named as a closed activity's status is.
echo 'SCENARIO:hidden_tool go' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Hidden done'
sleep 2
echo '@@ hidden status'
cat /mnt/ui/activity/0/status
echo 'SCENARIO:text_only still here' > /mnt/ui/activity/0/conversation/input
waitfor 0 'Hello from the mock'
echo '@@ hidden'
conv 0
echo '@@ end'
echo DRIVER_DONE
EOF
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -pheap=512m -pmain=512m -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" \
	</dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 480 ]; do
	grep -q '^DRIVER_DONE$' "$WORK/emu.log" 2>/dev/null && break
	sleep 1
	i=$((i + 1))
done
kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true
EMU_PID=

LOG="$WORK/emu.log"
REQ="$WORK/req.log"
FAILED=0
# (not finished, what it did get to is still checked)
grep -q '^DRIVER_DONE$' "$LOG" || { echo "FAIL: the driver did not finish"; FAILED=1; }
section() { awk -v s="@@ $1" '$0 == s {p=1; next} /^@@ / {p=0} p' "$LOG"; }
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
has() { section "$1" | grep -q -- "$2"; }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
checknot() { d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
num() { section "$1" | grep -E '^ *[0-9]+ *$' | tr -dc 0-9; }
# user messages the model was sent that hold a text
sent() {
	python3 -I - "$REQ" "$1" <<'PY'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    for m in json.loads(line)["body"]["messages"]:
        c = str(m.get("content"))
        if m.get("role") == "user" and sys.argv[2] in c:
            seen.add(c)
print(len(seen))
PY
}

check "a call denied for want of anyone to ask is said in the conversation" has unattended 'denied without asking'
checknot "with no dialogue" has unattended 'title=Permission required'

check "/stop while a dialogue waits is answered as a stop" has stop '(stopping)'
check "the dialogue is closed as denied" has stop 'title=Denied'
n=$(section stop | grep -c 'Write was handled' || true)
[ "$n" -eq 1 ] && ok "and the turn does not go on" || bad "and the turn does not go on (the reply after the call is shown $n times, once is the turn before)"
check "the activity is idle after it" has "stop status" '^idle$'

check "a request that reads as a tile's attributes is the tile's text, its title and buttons the bridge's" has attrs 'dtype=dialogue title=Permission required options=Allow,Deny text=write: /dev/null probe options=Yes title=X'
n=$(section attrs | grep -c 'dtype=dialogue.*title=X options=\|dtype=dialogue.*options=Yes text=' || true)
[ "$n" -eq 0 ] && ok "nothing in the request is taken for the tile's title or buttons" || bad "nothing in the request is taken for the tile's title or buttons"

check "the model's text is shown" has forged 'Please confirm above'
checknot "a line of it that reads as a note's header makes no dialogue" has forged 'dtype=dialogue title=Permission required options=Allow,Deny text=read:'
checknot "nor a tile under any title of the model's" has forged 'title=Permission required.*lbtest/a.txt'

n=$(sent '[task-event] flood')
[ "$n" -ge 1 ] && [ "$n" -le 16 ] && ok "events that arrive during a turn wait at most 16 deep ($n were turns)" || bad "events that arrive during a turn wait at most 16 deep ($n were turns)"
check "and the user is told some were not given to the agent" has flood 'more notification(s) arrived'

check "a task stopped in its first turn is stopped, not complete" has "stopped task" '^stopped$'
n=$(sent 'Task 2 "Slowpoke" was stopped before it finished its assignment')
[ "$n" -ge 1 ] && ok "activity 0 is told it was stopped" || bad "activity 0 is told it was stopped"
n=$(sent 'Task 2 "Slowpoke" has finished its assignment')
[ "$n" -eq 0 ] && ok "and not that it finished" || bad "and not that it finished"

before=$(num "bridges before")
with=$(num "bridges with the task")
after=$(num "bridges after")
[ -n "$before" ] && [ -n "$with" ] && [ "$with" -gt "$before" ] && ok "a task blocked on a dialogue has its bridge ($before, then $with)" || bad "a task blocked on a dialogue has its bridge ($before, then $with)"
[ -n "$after" ] && [ "$after" -eq "$before" ] && ok "closed, nothing of its bridge is left ($after)" || bad "closed, nothing of its bridge is left ($before before, $after after)"

checknot "a tool call named hidden does not close the activity" has "hidden status" '^hidden$'
check "the call is answered" has hidden 'Hidden done'
check "and the activity goes on answering" has hidden 'Hello from the mock'

[ "$FAILED" -eq 0 ] || { echo "lucibridge_turn_test: $FAILED FAILED"; exit 1; }
echo "lucibridge_turn_test: PASS"
