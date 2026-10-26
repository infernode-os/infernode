#!/bin/sh
#
# wm_theme_test.sh — every wm application under wm/wm through a live
# theme switch (brimstone to halo, as Xenith's Theme makes it), by
# pixel: the window's frame must take halo's windowborder, and the
# inside of the window must hold almost none of the colours only
# brimstone has.  An application that gives "." an explicit colour, or
# reads the theme once at start, fails here.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

# the applications, with what each needs to open a window
APPS='wm/about
wm/bounce
wm/charon
wm/clock
wm/coffee
wm/colors
wm/date
wm/deb
wm/editor
wm/fractals
wm/ftree
wm/keyring
wm/lens
wm/man
wm/matrix
wm/memory
wm/page /README.md
wm/rt
wm/sam /README.md
wm/scene
wm/settings
wm/sh
wm/shell
wm/task
wm/tetris
wm/view /MacOSX/Xenith.png
wm/wallet'

W="$ROOT/tmp/wm_theme_test.$$"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
cd "$ROOT"

# one application: its own copy of the themes and its own shots
run1() {
	name=$(echo "$1" | sed 's/ .*//; s|/|_|g')
	d="$W/$name"; t="tmp/wm_theme_test.$$/$name"
	mkdir -p "$d/theme" "$d/shots"
	cp lib/lucifer/theme/* "$d/theme/"
	printf brimstone > "$d/theme/current"
	SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
		/dis/sh.dis -c "bind -c /$t/theme /lib/lucifer/theme; bind -c /$t/shots /tmp; app=($1); wm/wm sh /tests/wm/theme.sh" \
		</dev/null >"$d/log" 2>&1 || true
}
pids=
n=0
printf '%s\n' "$APPS" > "$W/apps"
while read -r a; do
	run1 "$a" &
	pids="$pids $!"
	n=$((n + 1))
	if [ $((n % 4)) = 0 ]; then wait $pids; pids=; fi
done < "$W/apps"
wait $pids

python3 -I - "$W" "$ROOT/lib/lucifer/theme" <<'PY'
import os, re, sys
W, T = sys.argv[1], sys.argv[2]

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
bonly = set(B.values()) - set(H.values())
names = {v: k for k, v in B.items()}
failed = 0
for name in sorted(os.listdir(W)):
    d = os.path.join(W, name)
    if not os.path.isdir(d):
        continue
    win = [l.split()[2:] for l in open(os.path.join(d, 'log'), errors='replace') if l.startswith('R win')]
    shot = os.path.join(d, 'shots', 'b.img')
    if not win or len(win[0]) < 5 or not os.path.exists(shot):
        print('FAIL: %s: no window' % name); failed = 1; continue
    # the topmost window is the application's
    x0, y0, x1, y1 = map(int, win[0][1:5])
    # it opens at a size that shows something: wm/tetris opened as its
    # 4px frame alone, 8x8, and the check below saw no pixels to fail
    # (wm/date, a line of text, is the smallest at 162x24)
    if x1 - x0 < 24 or y1 - y0 < 24:
        print('FAIL: %s: opened %dx%d, its frame and almost nothing in it' % (name, x1 - x0, y1 - y0)); failed = 1; continue
    b = load(shot)
    frame = b(x0 + 1, (y0 + y1) // 2)
    if frame != H['windowborder']:
        print('FAIL: %s: frame %s, want halo windowborder %s' % (name, frame, H['windowborder'])); failed = 1; continue
    tot = stale = 0; seen = {}
    for y in range(y0 + 5, y1 - 5, 3):
        for x in range(x0 + 5, x1 - 5, 3):
            c = b(x, y); tot += 1
            if c in bonly:
                stale += 1; seen[c] = seen.get(c, 0) + 1
    pct = 100 * stale // max(tot, 1)
    # a picture of its own (coffee's cup, colors' swatches) has a few
    if pct > 2:
        top = sorted(seen.items(), key=lambda kv: -kv[1])[:3]
        print('FAIL: %s: %d%% of the window in brimstone colours (%s)' % (name, pct,
            ' '.join('%s %s' % (names.get(c, '?'), c) for c, _ in top))); failed = 1
    else:
        print('PASS: %s' % name)
if failed == 0:
    print('ALL PASS')
sys.exit(failed)
PY
