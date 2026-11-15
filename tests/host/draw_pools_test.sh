#!/bin/sh
# $Draw with the Dis heap or the image pool full, each case in an
# emulator of its own with a small pool (tests/draw_pools.b fills it).
#
# lock: a builtin that makes a Draw->Image made the display's image
# first and the Limbo cell for it second, holding the display's lock.
# The cell is refused by an exception when the heap is full, which left
# the lock held: on a mounted display, every other Prog using it waited
# for ever.  Here newimage, color, rgb and colormix are each refused with the heap
# full, and another Prog then draws on the display.
#
# alloc: Display.allocate made the Display's cell and its five images'
# cells after the display, which it is handed locked.  With room for
# the first and not for the others the caller was left half a Display,
# its lock held for good, and freeing it waited for that lock.  Here the
# heap is given back a little at a time until a Display fits: each
# attempt is refused whole or gives a Display that draws, and the
# collector then frees it.
#
# nofont: a display made when the image pool has no room for the default
# font has none.  Font.build of "*default*" read through the nil, and
# closing the nil font when the display was freed faulted in the
# collector's sweep: the emulator exited.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "draw_pools_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/draw_pools.dis ] || { echo "draw_pools_test: SKIP (dis/tests/draw_pools.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

# run MODE POOLFLAG WHAT: the helper's lines, less the kernel's own about the full pool
run() {
	with_timeout 120 "$EMU" "$1" "$2" -r"$ROOT" /dis/tests/draw_pools.dis "$3" 2>&1 < /dev/null |
		grep -v '^pool \|^  \|^fs:\|^Display_newimage FAIL'
}
last() { echo "$1" | tail -3 | tr '\n' ' ' | cut -c1-300; }

for mode in -c1 -c0; do
	out=$(run $mode -pheap=8m lock)
	if echo "$out" | grep -q '^SKIP'; then
		echo "draw_pools_test: SKIP ($mode lock: $(echo "$out" | grep '^SKIP'))"
	else
		ok=1
		echo "$out" | grep -q '^DONE$' || { fail "$mode lock: the program did not finish: $(last "$out")"; ok=0; }
		echo "$out" | grep -q '^BEFORE ok$' || { fail "$mode lock: the mounted display did not draw to begin with: $(last "$out")"; ok=0; }
		echo "$out" | grep -q '^RAISED 4$' || { fail "$mode lock: not every builtin was refused with the heap full: $(echo "$out" | grep '^RAISED')"; ok=0; }
		echo "$out" | grep -q '^AFTER ok$' || { fail "$mode lock: the display was left locked: $(echo "$out" | grep '^AFTER')"; ok=0; }
		[ $ok = 1 ] && pass "$mode lock: four builtins refused with the heap full, and another Prog still draws on the display"
	fi

	out=$(run $mode -pheap=8m alloc)
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode alloc: the program did not finish: $(last "$out")"; ok=0; }
	echo "$out" | grep -q '^RAISED [1-9]' || { fail "$mode alloc: Display.allocate was never refused: $(echo "$out" | grep '^RAISED')"; ok=0; }
	echo "$out" | grep -q '^MADE ok$' || { fail "$mode alloc: $(echo "$out" | grep '^MADE\|^HUNG\|^FAIL' | tr '\n' ' ')"; ok=0; }
	echo "$out" | grep -q '^SWEPT$' || { fail "$mode alloc: the collector did not free the display"; ok=0; }
	[ $ok = 1 ] && pass "$mode alloc: Display.allocate refused whole $(echo "$out" | sed -n 's/^RAISED //p') times, then a display that draws, freed by the collector"

	out=$(run $mode -pimage=8m nofont)
	if echo "$out" | grep -q '^SKIP\|^NODISPLAY'; then
		echo "draw_pools_test: SKIP ($mode nofont: no second display with the image pool full)"
		continue
	fi
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode nofont: the program did not finish: $(last "$out")"; ok=0; }
	echo "$out" | grep -q '^FONT none$' || { fail "$mode nofont: $(echo "$out" | grep '^FONT\|^FAIL' | tr '\n' ' ')"; ok=0; }
	echo "$out" | grep -q '^SWEPT$' || { fail "$mode nofont: the collector did not free the display"; ok=0; }
	echo "$out" | grep -q '^DRAWS$' || { fail "$mode nofont: the first display no longer draws"; ok=0; }
	[ $ok = 1 ] && pass "$mode nofont: a display with no default font is made, gives no font, and is freed by the collector"
done
exit $rc
