#!/bin/sh
#
# wm/osk through a live switch to every theme in lib/lucifer/theme
# (tests/osk/themes.sh), by pixel: the board the theme's header, a
# letter's key its input colour with its label in its text colour, the
# keyboard's own keys (shift, delete) its border colour, a key held down
# its accent; and every label, the words shown and a held key legible
# against what is behind them (WCAG's 4.5:1).  The theme left as it was
# found.  Needs the SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/osk.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

cd "$ROOT"
CUR=lib/lucifer/theme/current
first=$(cat "$CUR")
themes=$(for f in lib/lucifer/theme/*; do b=$(basename "$f"); [ "$b" = current ] || echo "$b"; done | tr '\n' ' ')
T=tmp/osk_theme_test.$$
mkdir -p "$ROOT/$T"
trap 'printf %s "$first" > "$ROOT/$CUR"; [ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
SDL_VIDEODRIVER=dummy with_timeout 180 "$EMU" -c1 -pheap=512m -pimage=512m -g800x480 -r"$ROOT" \
	/dis/sh.dis -c "themes=($themes); first=$first; bind -c /$T /tmp; wm/wm sh /tests/osk/themes.sh" \
	</dev/null >"$ROOT/$T/log" 2>&1 || true
grep -q '^R done' "$ROOT/$T/log" || { echo "FAIL: the driver did not finish"; grep -v '^fs:' "$ROOT/$T/log" | tail; exit 1; }

PYTHONPATH="$ROOT/tools" python3 - "$ROOT" "$T" $themes <<'PY'
import sys, re, os
sys.path.insert(0, os.path.join(sys.argv[1], 'tools'))
import p9img2png as P
root, T, themes = sys.argv[1], sys.argv[2], sys.argv[3:]
def load(n):
    d = {}
    for l in open(os.path.join(root, 'lib/lucifer/theme', n)):
        m = re.match(r'(\w+)\s+([0-9A-Fa-f]{6})', l)
        if m: d[m.group(1)] = m.group(2).upper()
    return d
base = load('brimstone')
def lum(h):
    c = [int(h[i:i+2], 16)/255 for i in (0, 2, 4)]
    c = [x/12.92 if x <= 0.03928 else ((x+0.055)/1.055)**2.4 for x in c]
    return 0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2]
def cr(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True)
    return (la+0.05)/(lb+0.05)
failed = 0
def check(ok, msg):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + msg)
    if not ok: failed = 1
for th in themes:
    t = dict(base); t.update(load(th))
    im = P.load(os.path.join(root, T, th + '.img'))
    keys = {}
    for l in open(os.path.join(root, T, th + '.keys')):
        f = l.split()
        if len(f) == 5: keys[f[0]] = tuple(int(x) for x in f[1:])
    def inside(k, corner='top'):	# a point inside the key, clear of its label and the gap round it
        x0, y0, x1, y1 = keys[k]
        g = max(2, (y1-y0)*2//43) + 3
        return (x0 + g, (y0 + g) if corner == 'top' else (y1 - g))
    def label(k):	# the colours in the middle of the key, where its label is
        x0, y0, x1, y1 = keys[k]
        cx, cy = (x0+x1)//2, (y0+y1)//2
        return {im.px(x, y) for x in range(cx-8, cx+9) for y in range(cy-10, cy+11)}
    a = keys['a']
    check(im.px(a[0]+1, a[1]+1) == t['header'], f"{th}: the board is its header colour ({t['header']}, not {im.px(a[0]+1, a[1]+1)})")
    for k in ('a', 'e', 'z'):
        got = im.px(*inside(k))
        check(got == t['input'], f"{th}: {k}'s key is its input colour ({t['input']}, not {got})")
    check(t['text'] in label('a'), f"{th}: a's label in its text colour ({t['text']})")
    for k in ('shift', 'del'):
        got = im.px(*inside(k))
        check(got == t['border'], f"{th}: {k}'s key is its border colour ({t['border']}, not {got})")
    got = im.px(*inside('t', 'bottom'))
    check(got == t['accent'], f"{th}: a key held down is its accent ({t['accent']}, not {got})")
    for what, fg, bg in (('a letter', 'text', 'input'), ('a key of its own', 'text', 'border'),
                         ('a held key', 'bg', 'accent'), ('the words shown', 'text2', 'header'),
                         ('the word a space puts in', 'accent', 'header')):
        c = cr(t[fg], t[bg])
        check(c >= 4.5, f"{th}: {what}'s label legible, {c:.1f}:1")
sys.exit(failed)
PY
r=$?
[ $r -eq 0 ] && echo "ALL PASS"
exit $r
