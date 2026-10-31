#!/bin/sh
#
# editor_headless_test.sh — a Tk application run with no window manager
# waits for events; it does not spin (INFR-365).
#
# wm/editor serves its documents at /edit from the same alt as its Tk
# control channel. With no window manager, wmlib->connect gives the
# window channels nothing writes to, so the alt must block until a 9P
# request comes. If the control channel were always ready the loop
# would spin, a core would be busy, and the 9P requests would starve:
# a write to /edit/1/body would never return.
#
# Starts wm/editor in a headless emu, writes a document body through
# /edit and reads it back, then measures the emu's CPU time while the
# editor sits idle.
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/wm/editor.dis" ] || { echo "SKIP: dis tree not built"; exit 77; }
[ -r /proc/self/stat ] || { echo "SKIP: no /proc to measure CPU time"; exit 77; }

OUT=$(mktemp)
TMPD=$(mktemp -d)
EMUPID=
trap 'rm -rf "$OUT" "$TMPD"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM

# A /tmp of its own, so nothing the editor or the test makes stays in the
# tree's.
# emu does not exit while the editor runs: wait for the marker, then stop it.
"$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
	"bind -c '#U*$TMPD' /tmp; wm/editor & sleep 2; echo 'body 365' > /edit/1/body; echo '=== WROTE'; cat /edit/1/body; echo '=== READ'; sleep 3600" \
	</dev/null >"$OUT" 2>&1 &
EMUPID=$!
i=0
while [ $i -lt 30 ] && ! grep -q '=== READ' "$OUT"; do
	sleep 1
	i=$((i + 1))
done

status=0
if grep -q '=== WROTE' "$OUT"; then
	echo "PASS: a write to /edit/1/body returns with no window manager"
else
	tail -20 "$OUT"
	echo "FAIL: the write to /edit/1/body did not return"
	exit 1
fi
if sed -n '/=== WROTE/,/=== READ/p' "$OUT" | grep -q '^body 365$'; then
	echo "PASS: the body reads back"
else
	tail -20 "$OUT"
	echo "FAIL: /edit/1/body did not read back what was written"
	status=1
fi

# CPU time (user + system, in clock ticks) used by emu over 3 seconds
# of idling: a spinning loop uses all of them, a waiting one almost none.
ticks() {
	awk '{ print $14 + $15 }' "/proc/$EMUPID/stat"
}
hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
t0=$(ticks)
sleep 3
t1=$(ticks)
used=$((t1 - t0))
limit=$((hz * 3 / 4))
if [ "$used" -le "$limit" ]; then
	echo "PASS: the idle editor used $used of $((hz * 3)) ticks in 3 s"
else
	echo "FAIL: the idle editor used $used of $((hz * 3)) ticks in 3 s: its event loop spins"
	status=1
fi
[ $status -eq 0 ] && echo "editor_headless_test: PASS"
exit $status
