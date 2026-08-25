#!/bin/sh
# INFR-362: concurrent task creates are one serialized allocation/provision
# transaction, and trusted tools9p owns namespace-setup completion.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
if [ -n "${INFERNODE_TEST_EMU:-}" ]; then
	EMU=$INFERNODE_TEST_EMU
fi

if [ ! -x "$EMU" ] || [ ! -f "$ROOT/dis/veltro/tools9p.dis" ] ||
   [ ! -f "$ROOT/dis/tests/task_concurrent_probe.dis" ]; then
	echo "SKIP: emulator or provisioning probe bytecode unavailable"
	exit 77
fi

name="task-provisioning-$$"
script="$ROOT/tmp/$name.sh"
log="$ROOT/tmp/$name.log"
mkdir -p "$ROOT/tmp"
trap 'rm -f "$script" "$log"' EXIT HUP INT TERM

cat >"$script" <<'EOF'
#!/dis/sh.dis
load std
path=(/dis/veltro /dis/cmd /dis .)

mkdir -p /tmp/veltro/.ns
luciuisrv &
sleep 3
echo 'activity create Main' > /mnt/ui/ctl
tools9p -v -z 750 -b read,list,find,search,grep task read list find search grep &
sleep 5
rm -f /tmp/task-a /tmp/task-b /tmp/task-c /tmp/task-a.done /tmp/task-b.done /tmp/task-c.done

{ /tests/task_concurrent_probe.dis ConcurrentA > /tmp/task-a; echo done > /tmp/task-a.done } &
{ /tests/task_concurrent_probe.dis ConcurrentB > /tmp/task-b; echo done > /tmp/task-b.done } &
{ /tests/task_concurrent_probe.dis ConcurrentC > /tmp/task-c; echo done > /tmp/task-c.done } &
createsdone=no
for (i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40) {
	if {~ $createsdone no} {
		donefiles=()
		if {ftest -f /tmp/task-a.done} { donefiles=($donefiles x) }
		if {ftest -f /tmp/task-b.done} { donefiles=($donefiles x) }
		if {ftest -f /tmp/task-c.done} { donefiles=($donefiles x) }
		if {~ $#donefiles 3} {
			createsdone=yes
		}{
			sleep 1
		}
	}
}
cat /tmp/task-a
cat /tmp/task-b
cat /tmp/task-c
echo TASKLIST
cat /tool/task/run
echo list > /tool/task/run
cat /tool/task/run
for (a in 1 2 3) {
	echo LABEL-$a
	cat /mnt/ui/activity/$a/label
	echo STATUS-$a
	cat /mnt/ui/activity/$a/status
	echo MANIFEST-$a
	cat /tmp/veltro/.ns/manifest.$a
	echo result $a > /tool/task/run
	echo TASKRESULT-$a
	cat /tool/task/run
}

echo /tmp/veltro/.ns/manifest.1 > /tool/read/run
echo AUTHORITY
cat /tool/read/run

echo 'create label=Rejected paths=/not-granted' > /tool/task/run
echo REJECTED-RESULT
cat /tool/task/run
echo LIST-AFTER-REJECT

echo list > /tool/task/run
cat /tool/task/run
if {ftest -d /tool.4} {
	echo FAILED-MOUNT-PRESENT
}{
	echo FAILED-MOUNT-ABSENT
}
echo '=== SCRIPT DONE ==='
EOF
chmod 755 "$script"

"$EMU" -r"$ROOT" "/tmp/$name.sh" </dev/null >"$log" 2>&1 &
pid=$!

doneflag=0
i=0
while [ "$i" -lt 100 ]; do
	if grep -q '^=== SCRIPT DONE ===$' "$log" 2>/dev/null; then
		doneflag=1
		break
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		break
	fi
	sleep 1
	i=$((i + 1))
done

kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

if [ "$doneflag" -ne 1 ]; then
	echo "FAIL: concurrent task provisioning probe timed out"
	cat "$log"
	exit 1
fi
if grep -q 'namespace setup pending\|task not created.*Concurrent' "$log"; then
	echo "FAIL: a concurrent successful create returned before provisioning completed"
	cat "$log"
	exit 1
fi

ids=$(sed -n 's/^RESULT Concurrent[A-C] created activity \([0-9][0-9]*\): Concurrent[A-C]$/\1/p' "$log" | sort -n)
if [ "$(printf '%s\n' "$ids" | grep -c '[0-9]')" -ne 3 ] ||
   [ "$(printf '%s\n' "$ids" | uniq | grep -c '[0-9]')" -ne 3 ]; then
	echo "FAIL: concurrent creates did not return three unique activity IDs"
	cat "$log"
	exit 1
fi
for label in ConcurrentA ConcurrentB ConcurrentC; do
	if ! grep -q "^RESULT $label created activity [0-9][0-9]*: $label$" "$log"; then
		echo "FAIL: per-fid create result was overwritten for $label"
		cat "$log"
		exit 1
	fi
done
for id in 1 2 3; do
	if ! grep -A10 "^MANIFEST-$id$" "$log" |
	   grep -q "^path=/tmp/veltro label=Veltro Workspace perm=rw$"; then
		echo "FAIL: activity $id returned without trusted namespace completion"
		cat "$log"
		exit 1
	fi
	if ! grep -A2 "^TASKRESULT-$id$" "$log" | grep -q "^task $id .* result:"; then
		echo "FAIL: activity $id has no retrievable result or explicit failure"
		cat "$log"
		exit 1
	fi
done
if ! grep -q '^error: cannot open /tmp/veltro/.ns/manifest.1' "$log"; then
	echo "FAIL: model-run read reached trusted namespace metadata"
	cat "$log"
	exit 1
fi
if ! grep -q '^REJECTED-RESULT$' "$log" ||
   ! grep -A1 '^REJECTED-RESULT$' "$log" | grep -q '^error:'; then
	echo "FAIL: refused provisioning did not return an explicit error"
	cat "$log"
	exit 1
fi
if ! grep -q 'FAILED-MOUNT-ABSENT' "$log"; then
	echo "FAIL: refused provisioning left a live child tool mount"
	cat "$log"
	exit 1
fi
if grep -A6 '^LIST-AFTER-REJECT$' "$log" | grep -q 'Rejected'; then
	echo "FAIL: refused provisioning remained task-list discoverable"
	cat "$log"
	exit 1
fi

echo "PASS: concurrent task provisioning is atomic and authority-safe"
