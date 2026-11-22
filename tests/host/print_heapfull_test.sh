#!/bin/sh
# sys->aprint and sys->sprint with the Dis heap full, in an emulator of
# its own with a small heap (tests/print_heapfull.b fills it).
#
# aprint destroyed the array its result replaces before making the new
# one, which raises when the heap is full: the caller's variable was
# left naming a freed block, which the program then read, wrote and
# freed again (the emulator's allocator caught the second free and
# panicked; before that, a write through it reached whatever had been
# allocated there since). And the buffer both format long text into was
# malloc'd from the kernel's main pool and lost at every such raise:
# twenty megabytes a call.
#
# Twelve aprints and twelve sprints of 20MB each with the heap full: all
# raise; the array is still the one it was, another allocation is not
# written through it, the string is unchanged, the main pool has not
# grown, the emulator goes on and both work once there is room.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "print_heapfull_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/print_heapfull.dis ] || { echo "print_heapfull_test: SKIP (dis/tests/print_heapfull.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

for mode in -c1 -c0; do
	out=$(with_timeout 120 "$EMU" $mode -pheap=48m -pmain=512m -r"$ROOT" /dis/tests/print_heapfull.dis 2>&1 < /dev/null)
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode: the program did not finish: $(echo "$out" | grep -v '^pool \|^fs:' | tail -3 | tr '\n' ' ' | cut -c1-300)"; ok=0; }
	echo "$out" | grep -q '^RAISED 24$' || { fail "$mode: not every print with the heap full raised: $(echo "$out" | grep '^RAISED')"; ok=0; }
	echo "$out" | grep -q '^A 1 11 X 77 S kept$' || { fail "$mode: after aprint raised, its old array or the string is not what it was: $(echo "$out" | grep '^A ')"; ok=0; }
	echo "$out" | grep -q '^AFTERWRITE X 77$' || { fail "$mode: a write through the old array reached another allocation: $(echo "$out" | grep '^AFTERWRITE')"; ok=0; }
	grown=$(echo "$out" | sed -n 's/^MAIN \(-\{0,1\}[0-9]*\)$/\1/p')
	if [ -z "$grown" ] || [ "$grown" -gt 1048576 ]; then
		fail "$mode: the main pool grew by ${grown:-?} bytes over 24 prints that raised"
		ok=0
	fi
	echo "$out" | grep -q '^ROOM 300 300 55$' || { fail "$mode: aprint and sprint with room again: $(echo "$out" | grep '^ROOM')"; ok=0; }
	[ $ok = 1 ] && pass "$mode: 24 prints raised with the heap full; the old array and string are kept, the main pool grew by $grown bytes, both print once there is room"
done
exit $rc
