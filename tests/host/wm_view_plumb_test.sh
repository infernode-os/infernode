#!/bin/sh
#
# wm_view_plumb_test.sh — wm/view as the Desktop's image viewer, under
# the SDL dummy driver, driven by tests/wm/viewplumb.sh: an image
# plumbed through lib/wm/plumbing, its window deleted from wm/wm's
# menu, three times.  Each plumb must give a window and each Delete
# take it.  view sent the plumber "start" for its port and never
# "stop" (its Exit's shutdown was commented out; wmclient's exit is a
# killgrp), so the plumber sent every image after the first to a port
# nobody read, and nothing opened.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/view.dis dis/plumber.dis dis/plumb.dis dis/calc.dis tests/imgload/rb.jpg; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/wm/viewplumb.sh" \
	</dev/null >"$LOG" 2>&1 || true

# the windows a step listed, or "gone" if it was never reached
step() {
	l=$(grep "^R $1\( \|\$\)" "$LOG" | head -1)
	[ -n "$l" ] || { echo gone; return; }
	printf '%s\n' "$l" | cut -d' ' -f3-
}

failed=0
if [ "$(step done)" = gone ]; then
	echo "FAIL: the driver never finished (wm/wm gone?)"; failed=1
fi
for i in 1 2 3; do
	o=$(step open$i); d=$(step deleted$i)
	if [ "$o" != gone ] && [ -n "$o" ]; then
		echo "PASS: image $i plumbed: a window ($o)"
	else
		echo "FAIL: image $i plumbed: no window"; failed=1
	fi
	if [ "$d" != gone ] && [ -z "$d" ]; then
		echo "PASS: image $i deleted"
	else
		echo "FAIL: image $i deleted: windows left: $d"; failed=1
	fi
done
n=$(grep -c 'start /dis/wm/view.dis port view' "$LOG" || true)
if [ "$n" = 3 ]; then
	echo "PASS: a view started for each image"
else
	echo "FAIL: views started: $n, want 3"; failed=1
fi

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^R /!p' "$LOG" | head -20
exit 1
