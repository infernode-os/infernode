#!/bin/sh
# Loads and channels that cannot be made with the Dis heap full, in an
# emulator of its own with a small heap (tests/load_heapfull.b fills
# it), and what the kernel's pool holds afterwards.
#
# A module is built in the kernel's pool; its data, and the Modlink a
# program holds it by, are in the Dis heap, and making those raises when
# the heap is full. Raised from the middle of the loader, the module
# built so far, its instructions, its types and the copy of its file
# stayed in the kernel's pool for good (megabytes for each load of an
# ordinary module, from any program that filled the heap first), and a
# module whose Modlink could not be made stayed loaded with nothing to
# unload it. A buffered channel of a tuple left its type behind whenever
# its buffer could not be made.
#
# 150 loads of a module with no data (parsed, then no Modlink), 30 of
# /dis/limbo.dis (no room for its data) and 100000 channels with a
# buffer larger than the heap: each raises, the main pool is where it
# was, and all three work once there is room.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "load_heapfull_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/load_heapfull.dis ] || { echo "load_heapfull_test: SKIP (dis/tests/load_heapfull.dis not built)"; exit 77; }
[ -f dis/tests/load_heapfull_mod.dis ] || { echo "load_heapfull_test: SKIP (dis/tests/load_heapfull_mod.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

# growth of the main pool a stage may leave: its 150, 30 or 100000
# failures each kept kilobytes to megabytes
LIMIT=262144

for mode in -c1 -c0; do
	out=$(with_timeout 300 "$EMU" $mode -pheap=48m -pmain=512m -r"$ROOT" /dis/tests/load_heapfull.dis 2>&1 < /dev/null)
	if echo "$out" | grep -q '^SKIP'; then
		echo "load_heapfull_test: SKIP ($(echo "$out" | grep '^SKIP' | head -1))"
		exit 77
	fi
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode: the program did not finish: $(echo "$out" | grep -v '^pool \|^fs:\|^  ' | tail -3 | tr '\n' ' ' | cut -c1-300)"; ok=0; }
	for stage in CHANS LINK PARSE; do
		line=$(echo "$out" | grep "^$stage ")
		grew=$(echo "$line" | sed -n 's/.* grew \(-\{0,1\}[0-9]*\)$/\1/p')
		if [ -z "$grew" ] || [ "$grew" -gt $LIMIT ]; then
			fail "$mode: $stage: the main pool grew by ${grew:-?} bytes: $line"
			ok=0
		fi
	done
	echo "$out" | grep -q '^CHANS raised 100000 ' || { fail "$mode: not every channel with a buffer beyond the heap was refused: $(echo "$out" | grep '^CHANS')"; ok=0; }
	echo "$out" | grep -q '^LINK raised 150 nil 0 loaded 0 ' || { fail "$mode: not every load with no room for a Modlink raised: $(echo "$out" | grep '^LINK')"; ok=0; }
	echo "$out" | grep -q '^PARSE raised 30 nil 0 loaded 0 ' || { fail "$mode: not every load with no room for the module's data raised: $(echo "$out" | grep '^PARSE')"; ok=0; }
	echo "$out" | grep -q '^ROOM f(1) 1$' || { fail "$mode: the module does not load once there is room: $(echo "$out" | grep '^ROOM')"; ok=0; }
	echo "$out" | grep -q '^CHAN 3 4 5 6$' || { fail "$mode: a buffered channel of a tuple: $(echo "$out" | grep '^CHAN ')"; ok=0; }
	echo "$out" | grep -q '^UNBUFFERED empty$' || { fail "$mode: an unbuffered one: $(echo "$out" | grep '^UNBUFFERED')"; ok=0; }
	[ $ok = 1 ] && pass "$mode: $(echo "$out" | grep '^CHANS \|^LINK \|^PARSE ' | tr '\n' ';' | cut -c1-220)"
done
exit $rc
