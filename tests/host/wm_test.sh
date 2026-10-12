#!/bin/sh
#
# wm_test.sh — wm/wm (appl/wm/wm.b) under the SDL dummy driver, driven
# by the pointer (tests/wm/drive.sh): rio's button-3 menu, New by a
# click or a hold, the sweep cancelled or too small, the frame's move
# and reshape, click to focus, Move, Resize, Hide and back, Delete, and
# the background, and a theme switched (frames, fractals' among them,
# and the menu, by pixel).
# Checks where each step leaves the windows, as wm/wm lists them
# (/chan/uitest).
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
# the themes, a copy the test may switch: the tree's current is left alone
T=tmp/wm_test.$$
mkdir -p "$ROOT/$T/theme"
cp "$ROOT"/lib/lucifer/theme/* "$ROOT/$T/theme/"
printf brimstone > "$ROOT/$T/theme/current"
trap 'rm -f "$LOG"; rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T/theme /lib/lucifer/theme; mkdir -p /$T/shots; bind -c /$T/shots /tmp; wm/wm sh /tests/wm/drive.sh" \
	</dev/null >"$LOG" 2>&1 || true

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

expect fractals		0 0 0 368 278  1 500 300 850 600
expect theme		0 0 0 368 278  1 500 300 850 600

# the colour at x y of a screenshot, as RRGGBB
pixel() {
	python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys, zlib
data = open(sys.argv[1], 'rb').read(); off = 0
if data[:11] == b'compressed\n':
    off = 11
hdr = data[off:off+60]; off += 60
chan = hdr[0:11].strip().decode()
minx, miny, maxx, maxy = (int(hdr[i:i+12]) for i in (12, 24, 36, 48))
w = maxx - minx
bpp = {'x8r8g8b8': 4, 'a8r8g8b8': 4, 'r8g8b8': 3}[chan]
x, y = int(sys.argv[2]), int(sys.argv[3])
if data[:11] != b'compressed\n':
    rows = data[off:]
else:
    # Inferno's compressed image: blocks of rows, each a run of
    # literals (code >= 128) or a copy back (2 bytes: length, offset)
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
# the commonest colour within dx of x (and 2 of y, if dx): a menu's
# colour, not its letters
dx = int(sys.argv[4]); dy = 2 if dx else 0
seen = {}
for yy in range(y - dy, y + dy + 1):
    for xx in range(x - dx, x + dx + 1):
        p = ((yy - miny) * w + (xx - minx)) * bpp
        c = '%02X%02X%02X' % (rows[p+2], rows[p+1], rows[p])
        seen[c] = seen.get(c, 0) + 1
print(max(seen, key=seen.get))
PY
}
key() { sed -n "s/^$2[ 	]*\([0-9A-Fa-f]\{6\}\).*/\1/p" "$ROOT/lib/lucifer/theme/$1" | head -1 | tr a-f A-F; }

shots="$ROOT/$T/shots"
check() {	# what, shot, x, y, spread, theme, key
	got=$(pixel "$shots/$2" "$3" "$4" "$5" 2>/dev/null || echo none)
	want=$(key "$6" "$7")
	if [ "$got" = "$want" ]; then
		echo "PASS: $1 ($7 $want)"
	else
		echo "FAIL: $1: $got, want $6's $7 $want"; failed=1
	fi
}
# window 1's left frame (4 wide at 500), and the menu opened at 900 100
# (New under the pointer, Move 36 below)
check "frame in the first theme" wm-theme-0.img 501 450 0 brimstone windowborder
check "frame follows the theme switch" wm-theme-1.img 501 450 0 halo windowborder
# fractals' left frame: it sets the background of ".", which gives that
# widget its own copy of the colours
check "fractals' frame in the first theme" wm-theme-0.img 1 150 0 brimstone windowborder
check "fractals' frame follows the theme switch" wm-theme-1.img 1 150 0 halo windowborder
check "menu in the theme switched to" wm-theme-menu.img 900 136 10 halo menubg
check "menu's chosen item in it too" wm-theme-menu.img 900 100 10 halo menuhilit

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^R /!p' "$LOG" | head -20
exit 1
