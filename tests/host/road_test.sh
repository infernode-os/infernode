#!/bin/sh
#
# road_test.sh — wm/road, the moving map, under wm/wm, through
# tests/road/drive.sh, with #g's fake service ($INFERNODE_LOCATION_FAKE)
# read by gpsfs: it opens and draws the position (the theme's red) at
# the middle of its map while following; its files (#sroad/fs: ctl,
# view, marks, event) give the view and the marks of a map file,
# refuse bad commands with the reason, and move the view (center stops
# following, and the position is drawn where the place is), add and
# remove marks, follow again, change units, and tell event of each
# change; a ship heard by AIS is drawn where it is; after a theme switch
# the map is in the new theme's colours.  Needs the SDL
# emulator; skips on a headless build.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/road.dis dis/gpsfs.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: python3 not found"; exit 77; }

T=tmp/road_test.$$
D="$ROOT/$T"
mkdir -p "$D/theme"
trap 'rm -rf "$D"' EXIT
cp "$ROOT"/lib/lucifer/theme/* "$D/theme/"
printf brimstone > "$D/theme/current"
cat > "$D/map.txt" <<'MAP'
# a street and a place near the fake position
line George Street
-33.8600 151.2070
-33.8520 151.2080
mark -33.8568 151.2153 Opera House
MAP

cd "$ROOT"
(export INFERNODE_LOCATION_FAKE='-33.856800 151.214000 12 8'
SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T/theme /lib/lucifer/theme; wm/wm sh /tests/road/drive.sh /$T" \
	</dev/null >"$D/log" 2>&1) || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }
has() { f "$1" | grep -q -- "$2"; }

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

[ "$(f ls | tr '\n' ' ')" = "/mnt/road/ctl /mnt/road/event /mnt/road/marks /mnt/road/view " ] &&
	pass "its files" || fail "ls: $(f ls | tr '\n' ' ')"
# the fake moves north a metre a second: the centre follows it
f view.a | sed -n 1p | grep -q '^center -33\.856[0-9]* 151\.214000$' &&
	[ "$(f view.a | sed -n 2,4p | tr '\n' '|')" = "width 1500|follow on|units metric|" ] &&
	pass "view: the width given, following" || fail "view: '$(f view.a | tr '\n' '|')'"
[ "$(f marks.a)" = "-33.856800 151.215300 Opera House" ] && pass "marks: the map file's" ||
	fail "marks: '$(f marks.a)'"
has err.center "no such place" && has err.width "usage: width" && has err.bogus "unknown command bogus" &&
	has err.unmark "no mark nosuch" && has err.follow "usage: follow" && has err.units "usage: units" &&
	pass "bad commands refused, with the reason" ||
	fail "errors: '$(f err.center)' '$(f err.width)' '$(f err.bogus)' '$(f err.unmark)' '$(f err.follow)'"
[ "$(f view.b | tr '\n' '|')" = "center -33.860000 151.210000|width 1500|follow off|units metric|" ] &&
	pass "center moves the view and stops following" || fail "view: '$(f view.b | tr '\n' '|')'"
[ "$(f marks.b | tail -1)" = "-33.857000 151.215000 X" ] && [ "$(f marks.c)" = "$(f marks.a)" ] &&
	pass "mark and unmark" || fail "marks: '$(f marks.b | tr '\n' '|')' then '$(f marks.c | tr '\n' '|')'"
has view.c "follow on" && has view.c "units nautical" && pass "follow on, nautical units" ||
	fail "view: '$(f view.c | tr '\n' '|')'"
[ "$(f events | grep -c changed)" -ge 4 ] && pass "event tells of each change" ||
	fail "events: '$(f events | tr '\n' '|')'"

python3 -I - "$D" "$ROOT/lib/lucifer/theme" <<'PY' || failed=1
import os, re, sys
D, T = sys.argv[1], sys.argv[2]

def load(p):
    data = open(p, 'rb').read(); off = 0
    comp = data[:11] == b'compressed\n'
    if comp:
        off = 11
    hdr = data[off:off+60]; off += 60
    chan = hdr[0:11].strip().decode()
    minx, miny, maxx, maxy = (int(hdr[i:i+12]) for i in (12, 24, 36, 48))
    w = maxx - minx
    bpp = {'x8r8g8b8': 4, 'a8r8g8b8': 4, 'r8g8b8': 3}[chan]
    if not comp:
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
    def px(x, y):
        p = ((y - miny) * w + (x - minx)) * bpp
        return '%02X%02X%02X' % (rows[p+2], rows[p+1], rows[p])
    return px

def theme(n):
    d = {}
    for l in open(os.path.join(T, n)):
        m = re.match(r'(\w+)\s+([0-9A-Fa-f]{6})', l)
        if m:
            d[m.group(1)] = m.group(2).upper()
    return d

B, H = theme('brimstone'), theme('halo')
win = [l.split()[2:] for l in open(os.path.join(D, 'log'), errors='replace') if l.startswith('R win')]
x0, y0, x1, y1 = map(int, win[0][1:5])
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
failed = 0

def red(img, colour):
    xs = []; ys = []
    for y in range(y0 + 4, y1 - 4):
        for x in range(x0 + 4, x1 - 4):
            if img(x, y) == colour:
                xs.append(x); ys.append(y)
    if not xs:
        return None
    return sum(xs) // len(xs), sum(ys) // len(ys)

a = load(os.path.join(D, 'a.img'))
p = red(a, B['red'])
if p and abs(p[0] - cx) <= 12 and abs(p[1] - cy) <= 30:
    print('PASS: following: the position at the middle of the map, in the theme\'s red')
else:
    print('FAIL: following: the position at %s, the window\'s middle %s' % (p, (cx, cy))); failed = 1

b = load(os.path.join(D, 'b.img'))
q = red(b, B['red'])
# the position is 370 m east and 355 m north of the new centre; at
# 1500 m across 520 pixels, about 128 pixels right and 123 up
if q and q[0] - p[0] > 80 and p[1] - q[1] > 80:
    print('PASS: the view moved: the position drawn where the place is')
else:
    print('FAIL: the view moved: the position at %s, before %s' % (q, p)); failed = 1

d = load(os.path.join(D, 'd.img'))
s = red(d, B['green'])
if s and abs(s[0] - (cx + 80)) <= 25 and abs(s[1] - (cy - 108)) <= 35:
    print('PASS: a ship by AIS drawn where it is, in the theme\'s green')
else:
    print('FAIL: the ship at %s, want about %s' % (s, (cx + 80, cy - 108))); failed = 1

c = load(os.path.join(D, 'c.img'))
tot = bg = old = 0
for y in range(y0 + 30, y1 - 40, 4):
    for x in range(x0 + 10, x1 - 10, 4):
        tot += 1
        v = c(x, y)
        bg += v == H['bg']
        old += v == B['bg']
if bg * 2 > tot and old == 0:
    print('PASS: after a theme switch the map is in the new theme')
else:
    print('FAIL: theme: %d of %d points halo bg, %d brimstone bg' % (bg, tot, old)); failed = 1
sys.exit(failed)
PY

[ $failed = 0 ] && echo "road_test: PASS"
exit $failed
