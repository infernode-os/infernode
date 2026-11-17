#!/bin/sh
#
# lucibridge_promote_test.sh — where a task's staged changes are applied.
#
# A task writes to a folder it was given through a cowfs overlay; the user
# applies the changes (promote).  The overlay kept the name of its folder in
# a file of its own directory (.cowmeta), which cowfs served to the task
# like any file, and lucibridge took the folder to write in from that file.
# So a task with `write` changed the file, and on the user's ordinary
# "Allow" its files were written wherever it had named: outside the granted
# folder, in any directory the user can write.  The same for the record of
# what each file's base was (.cowbase: the conflict check) and the list of
# deletions (.whiteout).
#
# Boots luciuisrv, tools9p and lucibridge for activity 0 against the
# scripted model (lucibridge/mock.py) with a /tmp of its own, and checks,
# each failing on the code before:
#   - a task's writes to .cowmeta, .cowbase and .whiteout through its
#     tools are refused (cowfs), and it cannot read .cowmeta;
#   - the dialogue that asks the user to allow "task promote" names the
#     files that would change;
#   - on Allow the task's file is in the granted folder and nowhere else;
#   - an overlay whose .cowmeta names another folder than the one the
#     harness noted as granted (changed here behind cowfs's back, as a
#     fault in it would allow) is not applied, by /promote in the task's
#     tab or by "task promote" with the user's Allow, and says why;
#   - an overlay of the activity's own for a folder it was never granted
#     for writing (exec's staging of /lib/veltro is one) is not applied by
#     /promote: every overlay named for the activity was;
#   - changes kept from an earlier session are applied only to the folder
#     noted for them: one whose .cowmeta names another, and one with no
#     note, are offered for discarding only, and "Apply" is refused.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 77; }
for f in dis/veltro/veltrosrv.dis dis/veltro/tools9p.dis dis/veltro/tools/task.dis \
	dis/veltro/tools/write.dis dis/veltro/cowfs.dis dis/lucibridge.dis dis/luciuisrv.dis dis/llmsrv.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

HERE="$ROOT/tests/host/lucibridge"
WORK="$(mktemp -d)"
PRIV="$ROOT/tmp/lbpromote.$$"		# the emulator's /tmp for this run
SERVER_PID=
EMU_PID=
SCRIPT=
cleanup() {
	# KEEP=<dir>: keep the emulator's and the model's logs there.
	[ -z "${KEEP:-}" ] || { mkdir -p "$KEEP"; cp "$WORK"/*.log "$KEEP"/ 2>/dev/null || true; }
	[ -z "$EMU_PID" ] || kill -9 "$EMU_PID" 2>/dev/null || true
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	[ -z "$SCRIPT" ] || rm -f "$SCRIPT"
	rm -rf "$WORK" "$PRIV" "$ROOT/usr/lbtest"
}
trap cleanup EXIT HUP INT TERM

python3 -I "$HERE/mock.py" "$WORK/req.log" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
i=0
while [ ! -s "$WORK/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$WORK/port" ] || { echo "FAIL: mock backend did not start"; exit 1; }
PORT=$(cat "$WORK/port")

key() {	# nsconstruct's name for a folder's overlay: FNV-1a of the path
	python3 -I -c '
import sys
h = 0x811c9dc5
for b in sys.argv[1].encode():
    h = ((h ^ b) * 0x01000193) & 0xffffffff
print("%08x" % h)' "$1"
}
MOREKEY=$(key /usr/lbtest/more)
LIBKEY=$(key /lib/veltro)
KEPTKEY=$(key /usr/lbtest/kept)
KEPT2KEY=$(key /usr/lbtest/kept2)

rm -rf "$PRIV" "$ROOT/usr/lbtest"
mkdir -p "$PRIV/veltro/cow/.grants" "$ROOT/usr/lbtest/notes" "$ROOT/usr/lbtest/more" \
	"$ROOT/usr/lbtest/home/.ssh" "$ROOT/usr/lbtest/kept" "$ROOT/usr/lbtest/kept2"
echo 'the user own key' > "$ROOT/usr/lbtest/home/.ssh/id_note"
printf 'Shopping\n- eggs\n' > "$ROOT/usr/lbtest/notes/todo.txt"
echo one > "$ROOT/usr/lbtest/more/m.txt"
# What an earlier session left (activity ids start again at 1, and this
# run's tasks are 1 and 2): task 5's overlay of the folder kept, noted as
# granted, whose .cowmeta names another folder; and task 6's of kept2, with
# no note of any grant.
K1="$PRIV/veltro/cow/5-$KEPTKEY"
K2="$PRIV/veltro/cow/6-$KEPT2KEY"
mkdir -p "$K1" "$K2"
printf 'basepath=/usr/lbtest/home/.ssh\nboot=999\n' > "$K1/.cowmeta"
echo 'planted from an earlier session' > "$K1/planted.txt"
echo /usr/lbtest/kept > "$PRIV/veltro/cow/.grants/5-$KEPTKEY"
printf 'basepath=/usr/lbtest/kept2\nboot=999\n' > "$K2/.cowmeta"
echo 'no grant was noted for this' > "$K2/unnoted.txt"

SCRIPT="$ROOT/tests/inferno/.lucibridge-promote-test.$$.sh"
cat > "$SCRIPT" <<EOF
#!/dis/sh.dis
load std
bind -c /tmp/lbpromote.$$ /tmp
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
/dis/veltro/tools9p -v -m /tool -b read,list,write read list task
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
			if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
				echo 'timed out waiting for' \$t
				found=1
			}
			sleep 1
		}
	}
}
fn waitblocked {
	n=''
	while {! ~ \`{cat /mnt/ui/activity/0/status} blocked} {
		n=\`{echo \$n | sed 's/.*/&x/'}
		if {~ \$n xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx} {
			echo 'timed out waiting for the approval'
			echo blocked > /mnt/ui/activity/0/status
		}
		sleep 1
	}
}
fn conv {
	for f in /mnt/ui/activity/\$1/conversation/[0-9]* { cat \$f; echo }
}

# Kept from the earlier session: offered at start; neither can be applied.
echo 'Apply 1' > /mnt/ui/activity/0/conversation/input
sleep 2
echo 'Apply 2' > /mnt/ui/activity/0/conversation/input
sleep 2
echo '@@ kept'
conv 0
echo '@@ kept files'
ls /usr/lbtest/home/.ssh /usr/lbtest/kept /usr/lbtest/kept2
echo '@@ kept end'

echo '/bind /usr/lbtest/notes rw' > /mnt/ui/activity/0/conversation/input
sleep 2
echo '/bind /usr/lbtest/more rw' > /mnt/ui/activity/0/conversation/input
sleep 2

# 1. The task goes for its overlay's records with its own tools.
echo 'SCENARIO:forge_delegate go' > /mnt/ui/activity/0/conversation/input
waitblocked
echo '@@ overlay records'
for d in /tmp/veltro/cow/1-* { cat \$d/.cowmeta; echo '--'; cat \$d/.cowbase; echo '--'; cat \$d/.whiteout >[2] /dev/null; echo '--'; ls \$d }
echo '@@ asked'
conv 0
echo '@@ before allow'
ls /usr/lbtest/notes
echo '@@ before allow end'
echo Allow > /mnt/ui/activity/0/conversation/input
waitfor 0 'Promoted the edit'
sleep 1
echo '@@ after allow'
echo outside:
ls /usr/lbtest/home/.ssh
echo granted:
ls /usr/lbtest/notes
cat /usr/lbtest/notes/authorized_keys
cat /usr/lbtest/notes/todo.txt

# 2. An overlay whose record of its folder was changed behind cowfs.
echo 'SCENARIO:plain_delegate go' > /mnt/ui/activity/0/conversation/input
waitfor 2 'Wrote the file'
sleep 2
ov=/tmp/veltro/cow/2-$MOREKEY
echo '@@ second overlay'
ls \$ov
boot=\`{grep '^boot=' \$ov/.cowmeta}
{echo 'basepath=/usr/lbtest/home/.ssh'; echo \$boot} > \$ov/.cowmeta
echo '/diff' > /mnt/ui/activity/2/conversation/input
sleep 2
echo '/promote' > /mnt/ui/activity/2/conversation/input
sleep 3
echo '@@ task tab'
conv 2
echo '@@ after tab promote'
echo outside:
ls /usr/lbtest/home/.ssh
echo granted:
ls /usr/lbtest/more
echo 'SCENARIO:second_promote go' > /mnt/ui/activity/0/conversation/input
waitblocked
echo '@@ asked second'
conv 0
echo '@@ asked second end'
echo Allow > /mnt/ui/activity/0/conversation/input
waitfor 0 'Asked for the second'
sleep 1
echo '@@ after second allow'
echo outside:
ls /usr/lbtest/home/.ssh
echo granted:
ls /usr/lbtest/more
echo staged:
ls \$ov

# 3. An overlay of activity 0's own, for a folder it has no grant to write.
mkdir -p /tmp/veltro/cow/0-$LIBKEY
{echo 'basepath=/lib/veltro'; echo \$boot} > /tmp/veltro/cow/0-$LIBKEY/.cowmeta
echo 'staged where no grant is' > /tmp/veltro/cow/0-$LIBKEY/planted.txt
echo '/promote' > /mnt/ui/activity/0/conversation/input
sleep 3
echo '@@ ungranted'
conv 0
echo '@@ ungranted files'
ls /lib/veltro/planted.txt /tmp/veltro/cow/0-$LIBKEY/planted.txt
echo '@@ end'
echo DRIVER_DONE
EOF
chmod +x "$SCRIPT"

OPENAI_API_KEY=test "$EMU" -c1 -pheap=512m -pmain=512m -r"$ROOT" /dis/sh.dis "/tests/inferno/$(basename "$SCRIPT")" \
	</dev/null > "$WORK/emu.log" 2>&1 &
EMU_PID=$!
i=0
while kill -0 "$EMU_PID" 2>/dev/null && [ "$i" -lt 240 ]; do
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
check() {	# description, command...: passes when the command does
	d=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
checknot() {
	d=$1; shift
	if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}
has() { section "$1" | grep -q -- "$2"; }

# The result the model was given for one of its tool calls.
result() {	# call id
	python3 -I - "$REQ" "$1" <<'PY'
import json, sys
out = None
for line in open(sys.argv[1]):
    for m in json.loads(line)["body"]["messages"]:
        if m.get("role") == "tool" and m.get("tool_call_id") == sys.argv[2]:
            out = str(m.get("content"))
if out is None:
    sys.exit(2)
print(out)
PY
}
refused() {	# description, call id: the call's result is an error
	r=$(result "$2") || { bad "$1 (no result for $2)"; return; }
	case "$r" in
	error*) ok "$1" ;;
	*) bad "$1 (got: $r)" ;;
	esac
}

# 1. through the task's own tools
r=$(result call_child_forge_0_0) || r=
case "$r" in wrote*) ok "the task writes a file in its folder" ;; *) bad "the task writes a file in its folder (got: $r)" ;; esac
refused "the task cannot read .cowmeta" call_child_forge_0_1
refused "the task's write of .cowbase is refused" call_child_forge_1_0
refused "the task's write of .whiteout is refused" call_child_forge_2_0
refused "the task's write of .cowmeta is refused" call_child_forge_3_0
check "the overlay still names the granted folder" has "overlay records" '^basepath=/usr/lbtest/notes$'
checknot "nothing of the task's is in the overlay's records" has "overlay records" 'home/.ssh'
checknot "no deletion was staged" has "overlay records" '^todo.txt$'
check "the user is asked with the count of what would change" has asked '1 change(s)'
check "and the file, in the granted folder" has asked 'A /usr/lbtest/notes/authorized_keys'
checknot "nothing is applied before the user allows it" has "before allow" 'authorized_keys'
check "on Allow the file is in the granted folder" has "after allow" '^ssh-ed25519 AAAA-TASK-KEY$'
check "the folder's other file is as it was" has "after allow" '^- eggs$'
n=$(section "after allow" | sed -n '/^outside:/,/^granted:/p' | grep -c -v -e '^outside:' -e '^granted:' -e 'id_note$' || true)
[ "$n" -eq 0 ] && ok "the directory the task named holds only the user's file" || bad "the directory the task named holds only the user's file ($n more)"

# 2. the overlay's record changed behind cowfs
check "the second task staged its file" has "second overlay" 'm2.txt'
check "/diff says the change cannot be applied" has "task tab" 'cannot be applied'
check "/promote in the task's tab applies nothing, and says so" has "task tab" 'NOT applied'
check "naming the folder the overlay claims and the one granted" has "task tab" 'it says it is for /usr/lbtest/home/.ssh, and the folder granted was /usr/lbtest/more'
n=$(section "after tab promote" | sed -n '/^outside:/,/^granted:/p' | grep -c -v -e '^outside:' -e '^granted:' -e 'id_note$' || true)
[ "$n" -eq 0 ] && ok "nothing is written where the overlay said" || bad "nothing is written where the overlay said ($n files)"
checknot "nor to the granted folder" has "after tab promote" 'm2.txt'
check "the user is told, when asked to allow it, that it cannot be applied" has "asked second" 'cannot be applied'
r=$(result call_second_promote_0_0) || r=
case "$r" in *"NOT applied"*) ok "allowed, the promote is refused, and the agent told" ;; *) bad "allowed, the promote is refused, and the agent told (got: $r)" ;; esac
n=$(section "after second allow" | sed -n '/^outside:/,/^granted:/p' | grep -c -v -e '^outside:' -e '^granted:' -e 'id_note$' || true)
[ "$n" -eq 0 ] && ok "nothing is written where the overlay said, allowed or not" || bad "nothing is written where the overlay said, allowed or not ($n files)"
check "the change stays staged" sh -c "awk -v s='@@ after second allow' '\$0 == s {p=1; next} /^@@ / {p=0} p' '$LOG' | sed -n '/^staged:/,\$p' | grep -q m2.txt"

# 3. no grant, no promote
check "an overlay for a folder not granted for writing is not applied" has ungranted "0-$LIBKEY: no folder granted for writing is recorded for it"
checknot "nothing is written to that folder" has "ungranted files" '^/lib/veltro/planted.txt'
check "the change stays staged, for /revert" has "ungranted files" "^/tmp/veltro/cow/0-$LIBKEY/planted.txt"

# kept from an earlier session
check "kept changes whose record names another folder are offered" has kept 'planted.txt'
check "and those with no note of a grant" has kept 'unnoted.txt'
checknot "neither with Apply" has kept 'options=Apply'
check "each for discarding" has kept 'options=Discard'
check "Apply typed all the same is refused, saying why" has kept 'not applied: it says it is for /usr/lbtest/home/.ssh, and the folder granted was /usr/lbtest/kept'
check "and for the one with no note" has kept 'not applied: no folder granted for writing is recorded for it'
checknot "nothing of them is written" has "kept files" 'planted.txt\|unnoted.txt'

[ "$FAILED" -eq 0 ] || { echo "lucibridge_promote_test: $FAILED FAILED"; exit 1; }
echo "lucibridge_promote_test: PASS"
