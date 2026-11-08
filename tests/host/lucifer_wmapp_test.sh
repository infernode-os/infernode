#!/bin/sh
#
# lucifer_wmapp_test.sh — wm/wm run as an app in Lucifer (from the
# context browser's /dis/wm) does not take the apps started after it.
# wmsrv puts a window server of its own over /chan/wmctl; Lucifer ran
# Activity 0's apps in its own namespace, so osk, a shell, Charon,
# About, started after it, were wm/wm's clients: black tabs, no
# typing, and wm/wm broken ("dereference of nil") when one went
# without joining.  Each app has a namespace of its own now.
#
# Lucifer boots under the SDL dummy driver; tests/wm/luciferwmapp.sh
# opens wm, osk and About as apps and counts broken processes.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/wm.dis dis/wm/osk.dis dis/wm/about.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOG=$TMP/log
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 \
	-pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 40; run /tests/wm/luciferwmapp.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
broken() { sed -n "s/^R $1 //p" "$LOG"; }

for s in wm osk about; do
	n=$(broken $s)
	if [ -z "$n" ]; then
		fail "$s: never reached"
	elif [ "$n" = 0 ]; then
		echo "PASS: $s opened, nothing broken"
	else
		fail "$s: $n processes broken"
	fi
done
if grep -q 'Broken' "$LOG"; then
	fail "$(grep -m1 Broken "$LOG")"
fi
st=$(sed -n 's/^R status //p' "$LOG")
[ "$st" = running ] && echo "PASS: About, opened after wm/wm, is running" ||
	fail "About's status '$st'"

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
grep -v '^tools9p' "$LOG" | tail -20
exit 1
