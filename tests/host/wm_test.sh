#!/bin/sh
#
# wm_test.sh — wm/wm (appl/wm/wm.b) under the SDL dummy driver, driven
# by the pointer (tests/wm/drive.sh): rio's button-3 menu, New by a
# click or a hold, the sweep cancelled or too small, the frame's move
# and reshape, click to focus, Move, Resize, Hide and back, Delete, and
# the background.  Checks where each step leaves the windows, as wm/wm
# lists them (/chan/uitest), not pixels.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/sh.dis dis/lib/menuhit.dis; do
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
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/wm/drive.sh" </dev/null >"$LOG" 2>&1 || true

failed=0
# step, then the windows it must leave: id minx miny maxx maxy, topmost first
expect() {
	step=$1; shift
	got=$(sed -n "s/^R $step *//p" "$LOG" | head -1)
	if ! grep -q "^R $step\( \|\$\)" "$LOG"; then
		echo "FAIL: $step: never reached"; failed=1
	elif [ "$got" = "$*" ]; then
		echo "PASS: $step"
	else
		echo "FAIL: $step: windows '$got', want '$*'"; failed=1
	fi
}

expect start
expect new-click	0 100 100 400 300
expect new-held		1 450 350 800 650  0 100 100 400 300
expect new-cancel	1 450 350 800 650  0 100 100 400 300
expect new-small	1 450 350 800 650  0 100 100 400 300
expect background	1 450 350 800 650  0 100 100 400 300
expect focus		0 100 100 400 300  1 450 350 800 650
expect frame-move	0 150 150 450 350  1 450 350 800 650
expect frame-reshape	0 150 150 500 350  1 450 350 800 650
expect menu-move	1 500 300 850 600  0 150 150 500 350
expect menu-resize	0 100 450 400 700  1 500 300 850 600
expect menu-hide	0 100 450 400 700
expect menu-unhide	1 500 300 850 600  0 100 450 400 700
expect menu-delete	1 500 300 850 600
expect delete-cancel	1 500 300 850 600

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^R /!p' "$LOG" | head -20
exit 1
