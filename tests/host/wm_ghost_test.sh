#!/bin/sh
#
# wm_ghost_test.sh — a wm/wm client that leaves (INFR-433), under the
# SDL dummy driver, driven by tests/wm/ghost.sh: wm/colors deleted from
# rio's menu, then killed.  Each time wm/wm must still be running (an
# exit is a killgrp: a client that shares wm's process group takes wm
# with it), and where its window was must be wm's background again,
# not the client's own screen fill.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/colors.dis dis/scap.dis dis/tests/wm_frozen.dis dis/wm/dir.dis dis/wm/task.dis dis/wm/matrix.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

LOG=$(mktemp)
T=tmp/wm_ghost_test.$$
mkdir -p "$ROOT/$T"
# chmod: Matrix's services leave directories of no permission in /tmp
trap 'rm -f "$LOG"; chmod -R u+rwx "$ROOT/$T" 2>/dev/null; rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/wm/ghost.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
for step in colors deleted colors2 killed frozen frozen-deleted after-frozen after-frozen-deleted dir dir-deleted task task-deleted matrix matrix-deleted keeps done; do
	if grep -q "^R $step\( \|\$\)" "$LOG"; then
		echo "PASS: $step"
	else
		echo "FAIL: $step: never reached (wm/wm gone?)"; failed=1
	fi
done

# the colour at x y of a screenshot, as RRGGBB
pixel() {
	python3 -I - "$1" "$2" "$3" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read(); off = 0
if data[:11] == b'compressed\n':
    off = 11
hdr = data[off:off+60]; off += 60
chan = hdr[0:11].strip().decode()
minx, miny, maxx, maxy = (int(hdr[i:i+12]) for i in (12, 24, 36, 48))
w = maxx - minx
bpp = {'x8r8g8b8': 4, 'a8r8g8b8': 4, 'r8g8b8': 3}[chan]
if data[:11] != b'compressed\n':
    rows = data[off:]
else:
    rows = bytearray(); yy = miny
    while yy < maxy:
        bmaxy = int(data[off:off+12]); nb = int(data[off+12:off+24]); off += 24
        blk = data[off:off+nb]; off += nb; i = 0
        while i < len(blk):
            c = blk[i]; i += 1
            if c >= 128:
                n = c - 128 + 1; rows += blk[i:i+n]; i += n
            else:
                n = (c >> 2) + 3; o = ((c & 3) << 8 | blk[i]) + 1; i += 1
                for _ in range(n):
                    rows.append(rows[-o])
        yy = bmaxy
x, y = int(sys.argv[2]), int(sys.argv[3])
p = ((y - miny) * w + (x - minx)) * bpp
print('%02X%02X%02X' % (rows[p+2], rows[p+1], rows[p]))
PY
}

# wm/wm's background (Background in appl/wm/wm.b)
BG=777777
shots="$ROOT/$T"
check() {	# what, shot, x, y, want (or !colour: anything but)
	got=$(pixel "$shots/$2" "$3" "$4" 2>/dev/null || echo none)
	case $5 in
	!*)	ok=0; [ "$got" != none ] && [ "$got" != "${5#!}" ] && ok=1 ;;
	*)	ok=0; [ "$got" = "$5" ] && ok=1 ;;
	esac
	if [ $ok = 1 ]; then
		echo "PASS: $1 ($got)"
	else
		echo "FAIL: $1: $got, want $5"; failed=1
	fi
}
# wm/colors' window is at 0 0 264 264: its frame, and inside it
check "window shown: its corner" ghost-0.img 5 5 "!$BG"
check "window shown: its frame" ghost-0.img 260 260 "!$BG"
for s in "1 deleted" "2 killed"; do
	n=${s% *}; what=${s#* }
	for xy in "5 5" "130 130" "260 260" "40 200"; do
		check "$what: background at $xy" ghost-$n.img $xy $BG
	done
done

# a client that has stopped: Delete still takes its window, wm goes on;
# one that took the exit and stays is left alone
step() { grep "^R $1\( \|\$\)" "$LOG" | head -1 | cut -d' ' -f3-; }
[ -n "$(step frozen)" ] && echo "PASS: frozen window shown" || { echo "FAIL: frozen window not shown"; failed=1; }
check "frozen: its window shown" ghost-3.img 150 100 "!$BG"
[ -z "$(step frozen-deleted)" ] && echo "PASS: frozen client deleted" || { echo "FAIL: frozen client left: $(step frozen-deleted)"; failed=1; }
check "frozen: background where it was" ghost-4.img 150 100 $BG
[ -n "$(step after-frozen)" ] && [ -z "$(step after-frozen-deleted)" ] && echo "PASS: wm works after a frozen client" || { echo "FAIL: wm after frozen: $(step after-frozen) / $(step after-frozen-deleted)"; failed=1; }
for w in dir task matrix; do
	[ -n "$(step $w)" ] && [ -z "$(step $w-deleted)" ] && echo "PASS: $w deleted, wm still up" ||
		{ echo "FAIL: $w: $(step $w) / $(step $w-deleted)"; failed=1; }
done
[ -z "$(step matrix-left)" ] && echo "PASS: nothing of Matrix or what it hosts left" || { echo "FAIL: left: $(step matrix-left)"; failed=1; }
[ -n "$(step keeps)" ] && echo "PASS: a client that took the exit stays" || { echo "FAIL: a client that took the exit was dropped"; failed=1; }

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^R /!p' "$LOG" | head -20
exit 1
