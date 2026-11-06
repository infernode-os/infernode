#!/bin/sh
#
# wm/logon with the keyboard on the screen at the Raspberry Pi's 7"
# panel's 800x480, booted as lib/lucifer/boot.sh boots it (wm/osk -s
# -M secret, then wm/logon, no window manager; tests/logon/osk.sh), by
# pixel: the login screen with its logo; the screen touched shows the
# keyboard and the form moves above its strip (its logo gone for
# room), the keys whole; a password tapped shows in the field above
# the strip and draws nothing over the keys; the keyboard hidden to its
# handle gives the form the screen back, the logo with it.  The two had
# each a whole-screen window: the keyboard's hid the form, and the
# form's field, under the strip, was drawn over the keys.  Needs the
# SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/logon.dis dis/wm/osk.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

W=800
H=480
T=tmp/logon_osk_test.$$
mkdir -p "$ROOT/$T"
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g${W}x$H -r"$ROOT" \
	/dis/sh.dis -l -c "run /lib/lucifer/boot.sh & bind -c /$T /tmp; run /tests/logon/osk.sh" \
	</dev/null >"$ROOT/$T/log" 2>&1 || true
grep -q '^R done' "$ROOT/$T/log" || { echo "FAIL: the driver did not finish"; grep -v '^fs:' "$ROOT/$T/log" | tail -20; exit 1; }

python3 - "$ROOT" "$T" "$W" "$H" <<'PY'
import sys, os
root, T, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P
d = os.path.join(root, T)
failed = 0
def check(ok, msg):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + msg)
    if not ok: failed = 1
def status(s):
    st = {}
    for l in open(os.path.join(d, 'status.' + s)):
        f = l.split(None, 1)
        if len(f) == 2: st[f[0]] = f[1].strip()
    return st
im = {s: P.load(os.path.join(d, s + '.img')) for s in ('boot', 'shown', 'typed', 'handle')}
bg = im['boot'].px(4, 4)
def ink(i, y0, y1):	# points not the background in rows y0..y1
    return sum(1 for y in range(y0, y1, 2) for x in range(0, W, 2) if i.px(x, y) != bg)
def diff(a, b, y0, y1):
    return sum(1 for y in range(y0, y1, 2) for x in range(0, W, 2) if a.px(x, y) != b.px(x, y))
# the logo: the commonest colour drawn in the top third of the boot screen
from collections import Counter
cols = Counter(im['boot'].px(x, y) for y in range(0, H // 3, 2) for x in range(0, W, 2))
del cols[bg]
lc = cols.most_common(1)[0][0] if cols else None
def logoink(i):
    return sum(1 for y in range(0, H, 2) for x in range(0, W, 2) if i.px(x, y) == lc)
logo = logoink(im['boot'])
check(logo > 500, 'the login screen shows its logo (%d points)' % logo)
st = status('shown')
h = int(st.get('height', '0') or 0)
check(st.get('state') == 'shown' and 0 < h <= H // 2,
      'the screen touched shows the keyboard, a strip of %d of %d' % (h, H))
top = H - h
if h > 0:
    above = ink(im['shown'], 0, top)
    check(above > 200, 'the form drawn above the strip (%d points)' % above)
    over = logoink(im['shown'])
    check(over < logo // 4, "its logo gone for room (%d points of the logo's colour, %d before)" % (over, logo))
    keys = diff(im['shown'], im['typed'], top, H)
    check(keys == 0, 'a password tapped draws nothing over the keys (%d points changed)' % keys)
    field = diff(im['shown'], im['typed'], 0, top)
    check(field > 0, 'and shows in the field above the strip (%d points changed)' % field)
st = status('handle')
hh = int(st.get('height', '0') or 0)
check(st.get('state') == 'handle', 'hidden to its handle (a strip of %d)' % hh)
back = logoink(im['handle'])
check(back > logo * 3 // 4, 'the form has the screen back, its logo with it (%d points)' % back)
sys.exit(failed)
PY
echo ALL PASS
