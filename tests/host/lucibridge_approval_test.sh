#
# lucibridge_approval_test.sh — the "Permission required" tile is answered by
# the user, and only the user's explicit yes allows the call.
#
# Boots activity 0 as Lucifer does (luciuisrv, tools9p, lucibridge, llmsrv
# against the scripted model) and runs the gated write of approval_deny once
# per arm, each in its own emulator. While the tile waits, the arm writes to
# the activity's conversation/input:
#
#   allow  "Allow"                        the user's button: allowed
#   deny   "Deny"                         the user's button: denied
#   task   "[task-event] ...", then Deny  what a finishing task posts is a turn
#                                         for the agent, not the answer: the
#                                         user's Deny that follows decides
#                                         (it was taken as the answer, and
#                                         anything but Deny allowed the call)
#   typed  "what will that do?"           the user typing instead: not consent
#
# The verdict is the tile's own (title Allowed or Denied) and what the model
# was told the call returned.
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

PASSED=0; FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

WORK="$(mktemp -d)"
SERVER_PID=
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	rm -rf "$WORK" "$ROOT/tmp/apvtest" "$ROOT"/tmp/.lucibridge-approval-test.*.sh
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$ROOT/tool" "$ROOT/tmp"

# run_arm <arm> <answer> <then>: prints the tile's title and the call's result
run_arm() {
	python3 -I "$ROOT/tests/host/agentloop/mock_openai.py" "$WORK/$1-req.log" > "$WORK/$1-port" 2> "$WORK/$1-server.log" &
	SERVER_PID=$!
	i=0
	while [ ! -s "$WORK/$1-port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	port=$(cat "$WORK/$1-port")
	script="$ROOT/tmp/.lucibridge-approval-test.$1.sh"
	cat > "$script" <<EOF
load std
mkdir -p /tmp/apvtest/ndb /tmp/apvtest/veltro
echo 'mode=local' > /tmp/apvtest/ndb/llm
echo 'backend=openai' >> /tmp/apvtest/ndb/llm
echo 'url=http://127.0.0.1:$port/v1' >> /tmp/apvtest/ndb/llm
bind -bc /tmp/apvtest/ndb /lib/ndb
echo > /tmp/apvtest/veltro/welcome_shown
echo > /tmp/apvtest/veltro/tour_offered
bind -bc /tmp/apvtest/veltro /lib/veltro
bind -a '#I' /net
ndb/cs
llmsrv -b openai -u http://127.0.0.1:$port/v1 -M mock &
sleep 1
luciuisrv
echo 'activity create Main' > /mnt/ui/ctl
/dis/veltro/tools9p -m /tool -b read,list,write read list write
lucibridge -a 0 >[2] /dev/null &
sleep 3
fn waitfor {
	n=''
	found=0
	while {! ~ \$found 1} {
		if {grep -s \$1 /mnt/ui/activity/0/conversation/[0-9]* >[2] /dev/null} { found=1 } {
			n=\`{echo \$n | sed 's/.*/&x/'}
			if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} { found=1 }
			sleep 1
		}
	}
}
echo 'SCENARIO:approval_deny go' > /mnt/ui/activity/0/conversation/input
waitfor 'Permission required'
echo -n '$2' > /mnt/ui/activity/0/conversation/input
if {! ~ '$3' ''} {
	sleep 2
	echo -n '$3' > /mnt/ui/activity/0/conversation/input
}
waitfor 'Write was handled'
sleep 1
if {grep -s 'title=Allowed' /mnt/ui/activity/0/conversation/[0-9]*} { echo TILE Allowed }
if {grep -s 'title=Denied' /mnt/ui/activity/0/conversation/[0-9]*} { echo TILE Denied }
echo halt > /dev/sysctl
EOF
	out=$(with_timeout 90 "$EMU" -c1 -pheap=512m -pmain=512m -r"$ROOT" /dis/sh.dis "/tmp/.lucibridge-approval-test.$1.sh" </dev/null 2>&1) || true
	printf '%s\n' "$out" > "$WORK/$1-emu.log"
	kill "$SERVER_PID" 2>/dev/null || true
	SERVER_PID=
	rm -rf "$ROOT/tmp/apvtest"
	tile=$(echo "$out" | sed -n 's/^TILE //p' | tr '\n' ' ' | sed 's/ $//')
	if grep -q 'operation denied by operator' "$WORK/$1-req.log" 2>/dev/null; then
		result=denied
	elif grep -q '"call_approval_deny_0_0"' "$WORK/$1-req.log" 2>/dev/null; then
		result=ran
	else
		result=none
	fi
	echo "$tile $result"
}

for spec in "allow|Allow||Allowed ran" "deny|Deny||Denied denied" \
	"task|[task-event] Task 7 (Probe) has finished.|Deny|Denied denied" \
	"typed|what will that do?||Denied denied"; do
	arm=${spec%%|*}; rest=${spec#*|}
	answer=${rest%%|*}; rest=${rest#*|}
	then=${rest%%|*}; want=${rest#*|}
	got=$(run_arm "$arm" "$answer" "$then")
	if [ "$got" = "$want" ]; then
		pass "$arm: tile and call $want"
	else
		fail "$arm: want '$want', got '$got'"
		sed -n '1,120p' "$WORK/$arm-emu.log"
		sed -n '1,80p' "$WORK/$arm-server.log"
	fi
done

echo "Total: $PASSED passed, $FAILED failed, 0 skipped"
[ "$FAILED" -eq 0 ]
