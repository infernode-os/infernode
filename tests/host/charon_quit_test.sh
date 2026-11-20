#!/bin/sh
#
# charon_quit_test.sh — Charon left, by wm's Delete (an exit) or by
# Ctrl-Q, leaves nothing running: not its own processes, and not its
# page's realm, which is a process group of its own (browser.b,
# startrealm), so the exit's killgrp missed it.  A page's scripts and
# timers ran on after the browser was closed, holding the page's heap
# and waking for as long as emu ran: on a desktop, days later, the idle
# collector was going round that heap a core's worth.  Ctrl-Q and Quit
# were a bare exit, which left Charon's own processes too.
# (tests/charon/quit/drive.sh drives it.)
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/charon.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/charon_quit_test.$$
W="$ROOT/$T"
mkdir -p "$W"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/charon/quit/drive.sh" > "$W/log" 2>&1 < /dev/null
grep -q '^R done' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -10; exit 1; }

fail=0
# a step's line: R step, then the ps lines of what is left
left() { grep "^R $1" "$W/log" | sed "s/^R $1//"; }
running() {	# step, what it is: something must be running (the test's premise)
	if left "$1" | grep -q 'Js'; then echo "PASS: $2"; else echo "FAIL: $2: no realm: '$(left "$1")'"; fail=1; fi
}
gone() {	# step, what it is: nothing of the browser's or the realm's left
	l=$(left "$1" | tr -s ' ')
	if [ -z "$(printf '%s' "$l" | tr -d ' ')" ]; then echo "PASS: $2"; else echo "FAIL: $2: left '$l'"; fail=1; fi
}
running delete-before "a page's realm runs, its timer going"
gone delete-after "Delete from wm's menu leaves nothing running"
running ctrlq-before "again, for Ctrl-Q"
gone ctrlq-after "Ctrl-Q leaves nothing running"
[ $fail = 0 ] && echo "ALL PASS"
exit $fail
