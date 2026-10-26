#!/bin/sh
#
# wm_size_test.sh — every program in dis/wm opens under wm/wm at a size
# that shows it.  Not its frame alone: wm/tetris was an 8x8 square in
# the corner, and a wm/wm run as a client, a desktop in a window, a
# 108x108 one with no room for a window.  Not the whole screen: wm/coffee
# and wm/memory asked for the display, for Lucifer's presentation zone,
# and wm/wm gave them that.  Run on a 2560x1600 screen, so a window sized
# by the display shows as one.
#
# The programs are what is in dis/wm, not a list kept here: a new one is
# run with no arguments, and one that needs some, or is not a program to
# open under wm/wm, is named in how() below.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/wm/wm.dis" ] || { echo "SKIP: dis/wm/wm.dis not built"; exit 77; }
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

# How each is run: a program and its arguments, or "-" and why it is
# not opened under wm/wm.
how() {
	case $1 in
	samengine|samrx|samstub|samtk)
		echo "- a module of wm/sam's, not a program" ;;
	logon)	echo "- the boot screen: it draws on the display itself, before any window manager" ;;
	presrender)
		echo "- Lucifer's presentation renderer: it follows /mnt/ui" ;;
	page)	echo "wm/page /README.md" ;;		# with nothing named it reads standard input
	sam)	echo "wm/sam /README.md" ;;
	view)	echo "wm/view /MacOSX/Xenith.png" ;;	# with nothing named it opens nothing
	*)	echo "wm/$1" ;;
	esac
}

W="$ROOT/tmp/wm_size_test.$$"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
cd "$ROOT"

run1() {
	SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -pheap=512m -pimage=512m -g2560x1600 -r"$ROOT" \
		/dis/sh.dis -c "app=($2); wm/wm sh /tests/wm/size.sh" </dev/null >"$W/$1" 2>&1 || true
}
pids= n=0
for f in dis/wm/*.dis; do
	p=$(basename "$f" .dis)
	h=$(how "$p")
	case $h in
	-*)	echo "SKIP: wm/$p:${h#-}"; continue ;;
	esac
	run1 "$p" "$h" &
	pids="$pids $!"
	n=$((n + 1))
	if [ $((n % 4)) = 0 ]; then wait $pids; pids=; fi
done
wait $pids

failed=0
for f in "$W"/*; do
	p=$(basename "$f")
	set -- $(sed -n 's/^R win //p' "$f" | head -1) ""
	if [ $# -lt 6 ]; then
		echo "FAIL: wm/$p: no window"; failed=1; continue
	fi
	# the topmost window is the program's
	dx=$(($4 - $2)) dy=$(($5 - $3))
	if [ $dx -lt 24 ] || [ $dy -lt 24 ]; then
		echo "FAIL: wm/$p: opened ${dx}x$dy, its frame and almost nothing in it"; failed=1
	elif [ "$p" = wm ] && { [ $dx -lt 320 ] || [ $dy -lt 240 ]; }; then
		# a clock may be 108x108; a desktop needs room for a window
		echo "FAIL: wm/wm: opened ${dx}x$dy, no room for a window in it"; failed=1
	elif [ $dx -gt 2304 ] && [ $dy -gt 1440 ]; then
		echo "FAIL: wm/$p: opened ${dx}x$dy, the whole screen"; failed=1
	else
		echo "PASS: wm/$p (${dx}x$dy)"
	fi
done

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
