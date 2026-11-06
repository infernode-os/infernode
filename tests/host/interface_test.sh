#!/bin/sh
#
# The login screen's choice of interface, Lucia or Desktop, and what
# lib/lucifer/boot.sh starts from it (tests/logon/interface.sh drives
# each boot), by pixel and by what each interface serves:
#
#   - the screen shows both under the field, Lucia chosen at first
#   - a click on Desktop chooses it, and keys typed after the click
#     still go to the password field; up and down choose round
#   - skipped there (Escape twice), the boot starts the Desktop: wm/wm
#     with a shell window, the choice kept in the user's
#     /usr/inferno/lib/interface, a file plumbed opening in a window of
#     its own (Xenith under wm/wm, not over it)
#   - the next login screen has Desktop chosen
#   - at the Raspberry Pi panel's 800x480, the keyboard on the screen
#     shown by a touch (wm/osk, as the boot starts it): the picker above
#     its strip, a touch on Desktop choosing it, a word tapped on the
#     keys going to the field, the keyboard still shown
#   - with $skiplogon the boot starts Lucia whatever was chosen;
#     $interface starts that one; a phone ($infmobile) has Lucia alone
#
# The boots with the login screen have the keyboard on the screen
# running, as every boot has: it read /dev/pointer, which has one
# reader, and the login screen, opening it second, had no clicks or
# taps at all.  Each boot has a HOME of its own (~/.infernode with
# it), so the developer's own choice is neither read nor changed.
# Needs the SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/logon.dis dis/wm/osk.dis dis/wm/wm.dis dis/xenith.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

W=1024
H=768
T=tmp/interface_test.$$
mkdir -p "$ROOT/$T/home"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"

# boot NAME VARS [WxH]: a boot with the shell variables VARS set
# before boot.sh runs and the driver beside it; its output to
# $T/NAME.log
boot() {
	name=$1
	vars=$2
	geom=${3:-${W}x$H}
	SDL_VIDEODRIVER=dummy HOME="$ROOT/$T/${home:-home}" with_timeout 150 "$EMU" -c1 \
		-pheap=512m -pmain=512m -pimage=512m -g$geom -r"$ROOT" \
		/dis/sh.dis -l -c "$vars run /lib/lucifer/boot.sh & bind -c /$T /tmp; run /tests/logon/interface.sh" \
		</dev/null >"$ROOT/$T/$name.log" 2>&1 || true
	grep -q '^R done' "$ROOT/$T/$name.log" || {
		echo "FAIL: the $name boot's driver did not finish"
		grep -v '^fs:' "$ROOT/$T/$name.log" | tail -20
		exit 1
	}
}

failed=0
check() {
	if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; failed=1; fi
}
has() { grep -q "$2" "$ROOT/$T/$1.log"; }

# findpicker IMAGE W H: where the picker is on the login screen shown
# in $T/IMAGE.img: "x y top bottom field", x y a point in Desktop's
# word, or "none"
findpicker() {
	python3 - "$ROOT" "$T" "$1" "$2" "$3" <<'PY'
import sys, os
root, T, name, W, H = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P
im = P.load(os.path.join(root, T, name + '.img'))
bg = im.px(4, 4)
# the field: the first line wide and of few colours, not the
# background; the picker is the second line drawn below it (the
# status line the first)
def rowink(y):
    return [x for x in range(0, W) if im.px(x, y) != bg]
field = None
for y in range(0, H):
    xs = rowink(y)
    if len(xs) > 250 and len(set(im.px(x, y) for x in xs)) <= 3:
        field = y
        break
if field is None:
    print('none'); sys.exit()
y = field
while y < H and rowink(y):	# past the field
    y += 1
rows = []
while y < H and len(rows) < 2:
    while y < H and not rowink(y):
        y += 1
    y0 = y
    while y < H and rowink(y):
        y += 1
    rows.append((y0, y))
if len(rows) < 2:
    print('none'); sys.exit()
y0, y1 = rows[1]
xs = sorted(set(x for yy in range(y0, y1) for x in rowink(yy)))
# Desktop is the rightmost of the line: a point inside its word
print(xs[-1] - 15, (y0 + y1) // 2, y0, y1, field)
PY
}

# the screen as it first shows, to find the picker on it
boot look 'phase=look;'
set -- $(findpicker look $W $H)
[ "$1" != none ] && [ $# = 5 ] || { echo "FAIL: no picker found below the field"; exit 1; }
X=$1 Y=$2 PY0=$3 PY1=$4 FY=$5
echo "PASS: the picker is under the field (row $PY0-$PY1, Desktop at $X $Y)"

boot pick "phase=pick; x=$X; y=$Y;"
boot again 'phase=again;'
cp "$ROOT/$T/home/.infernode/usr/inferno/lib/interface" "$ROOT/$T/kept" 2>/dev/null || :
boot skip 'phase=which; skiplogon=1;'
boot override 'phase=which; skiplogon=1; interface=Desktop;'
boot phone 'phase=which; skiplogon=1; interface=Desktop; infmobile=1;'

# at the Pi's panel, the keyboard on the screen shown; a home where
# nothing was chosen yet
TW=800
TH=480
home=home2
mkdir -p "$ROOT/$T/$home"
boot shown 'phase=shown;' ${TW}x$TH
set -- $(findpicker shown $TW $TH)
[ "$1" != none ] && [ $# = 5 ] || { echo "FAIL: no picker found above the keyboard"; exit 1; }
TX=$1 TY=$2 TY0=$3 TY1=$4 TFY=$5
KH=$(sed -n 's/^height //p' "$ROOT/$T/status.shown")
[ "$(sed -n 's/^state //p' "$ROOT/$T/status.shown")" = shown ] && [ "$TY1" -lt $((TH - ${KH:-0})) ]
check $? "a touch shows the keyboard (a strip of ${KH:-0}) and the picker above it (row $TY0-$TY1)"
boot touch "phase=touch; x=$TX; y=$TY;" ${TW}x$TH
[ "$(sed -n 's/^state //p' "$ROOT/$T/status.keyed")" = shown ]
check $? 'the keyboard still shown after the picker and its keys are touched'

python3 - "$ROOT" "$T" "$W" "$PY0" "$PY1" "$FY" <<'PY' || failed=1
import sys, os
root, T, W, y0, y1, fy = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P
d = os.path.join(root, T)
im = {s: P.load(os.path.join(d, s + '.img')) for s in ('look', 'start', 'click', 'typed', 'up', 'down', 'again')}
failed = 0
def check(ok, msg):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + msg)
    if not ok: failed = 1
def band(i, a, b):
    return [i.px(x, y) for y in range(a, b) for x in range(0, W)]
def same(a, b, ya, yb):
    return band(im[a], ya, yb) == band(im[b], ya, yb)
pick = (y0 - 4, y1 + 4)
field = (fy - 4, fy + 24)
check(same('look', 'start', *pick), 'the picker shows the same each boot')
check(not same('start', 'click', *pick), 'a click on Desktop chooses it')
check(same('click', 'typed', *pick) and not same('click', 'typed', *field),
      'keys typed after the click go to the password field')
check(same('start', 'up', *pick), 'up chooses the interface before it (Lucia)')
check(same('click', 'down', *pick), 'down chooses the one after (Desktop)')
check(same('down', 'again', *pick), 'the next login screen has Desktop chosen')
sys.exit(failed)
PY

python3 - "$ROOT" "$T" "$TW" "$TY0" "$TY1" "$TFY" <<'PY' || failed=1
import sys, os
root, T, W, y0, y1, fy = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P
d = os.path.join(root, T)
im = {s: P.load(os.path.join(d, s + '.img')) for s in ('shown', 'tapped', 'keyed')}
failed = 0
def check(ok, msg):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + msg)
    if not ok: failed = 1
def band(i, a, b):
    return [i.px(x, y) for y in range(a, b) for x in range(0, W)]
def same(a, b, ya, yb):
    return band(im[a], ya, yb) == band(im[b], ya, yb)
pick = (y0 - 4, y1 + 4)
field = (fy - 4, fy + 24)
check(not same('shown', 'tapped', *pick), 'a touch on Desktop, the keyboard shown, chooses it')
check(same('tapped', 'keyed', *pick) and not same('tapped', 'keyed', *field),
      'a word tapped on the keyboard after it goes to the password field')
sys.exit(failed)
PY

has pick 'boot: interface Desktop'; check $? 'skipped at the screen, the boot starts the interface chosen'
has pick '^R windows 1$'; check $? 'the Desktop is wm/wm with a shell window'
has pick '^R windows 2$'; check $? 'a file plumbed on the Desktop opens in a window of its own'
[ "$(cat "$ROOT/$T/kept" 2>/dev/null)" = Desktop ]; check $? 'the choice is kept in the user'"'"'s /usr/inferno/lib/interface'
has skip '^R started Lucia$'; check $? 'with $skiplogon the boot starts Lucia, whatever was chosen'
has override '^R started Desktop$'; check $? '$interface starts the interface it names'
has phone '^R started Lucia$'; check $? 'a phone ($infmobile) has Lucia alone'
for b in pick again skip override phone shown touch; do
	if grep -q 'R timeout' "$ROOT/$T/$b.log"; then
		echo "FAIL: the $b boot timed out: $(grep 'R timeout' "$ROOT/$T/$b.log")"
		failed=1
	fi
done
exit $failed
