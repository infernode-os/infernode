#!/bin/sh
#
# Lucifer on a tablet (boot-mobile.sh --tablet, which the iOS app passes
# on an iPad): held on its side, the desktop's three columns; upright,
# the phone's accordion; a phone (no --tablet) the accordion either way.
# In the columns, the keyboard on the screen (wm/osk) shown by a tap in
# the chat's field and hidden by its strip's icon leaves the Workspace
# column as it was, by pixel: the zones were laid out again on a fresh
# screen, and the old windows, freed after, painted the old screen's
# fill over them (the Workspace blank, the other columns cut short).
#
# With TOUCH_EMU set to an emulator built with -DMOBILE_TOUCH=1 (the
# iOS and Android screen code on a desktop: EMUOPTIONS=-DMOBILE_TOUCH=1
# mk in emu/Linux), and Xvfb and xdotool installed, the screen is also
# turned: an X window upright resized to on its side, as iOS resizes the
# app's window when the device turns (or an iPad's Split View does).
# The screen programs see must follow it (it kept its first size and was
# cut off), and Lucifer change layout.  Needs the SDL emulator
# (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/osk.dis dis/scap.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

T=tmp/tablet_layout_test.$$
mkdir -p "$ROOT/$T"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
POOLS="-pheap=512m -pmain=256m -pimage=256m"	# the iOS app's

# boot NAME W H ARGS: Lucifer as the iOS app boots it, its layout logged
boot() {
	SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 $POOLS -g${2}x$3 -r"$ROOT" \
		/dis/sh.dis -l -c "run /lib/lucifer/boot-mobile.sh --no-logon $4 & sleep 45; echo halt > /dev/sysctl" \
		</dev/null >"$T/$1.log" 2>&1 || true
}
# keyboard: the columns, the chat's field tapped (tests/osk/mobile.sh)
W=2752 H=1976
D="$T/kbd"
mkdir -p "$D"
SDL_VIDEODRIVER=dummy with_timeout 200 "$EMU" -c1 $POOLS -g${W}x$H -r"$ROOT" \
	/dis/sh.dis -l -c "run /lib/lucifer/boot-mobile.sh --no-logon --tablet & sleep 45; bind -c /$D /tmp; w=$W; h=$H; tapx=$((W / 10)); run /tests/osk/mobile.sh" \
	</dev/null >"$D/log" 2>&1 &
boot upright 2064 2664 --tablet &
boot phone 2752 1976 "" &
wait

fail=0
layout() {
	grep -o 'lucifer: layout [a-z]*' "$1" | tail -1 | sed 's/lucifer: layout //'
}
check() {
	if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi
}
check "a tablet on its side has the columns" "$(layout "$D/log")" columns
check "a tablet upright has the accordion" "$(layout "$T/upright.log")" accordion
check "a phone on its side keeps the accordion" "$(layout "$T/phone.log")" accordion

if ! grep -q '^R done' "$D/log"; then
	echo "FAIL: the keyboard's driver did not finish"; grep -v '^fs:' "$D/log" | tail -20; exit 1
fi
PYTHONPATH="$ROOT/tools" python3 - "$D" "$W" "$H" <<'PY' || fail=1
import sys
import p9img2png as P
d, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
failed = 0
def check(ok, what):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        failed = 1
def state(step):
    for l in open('%s/status.%s' % (d, step)):
        if l.startswith('state '):
            return l.split()[1]
def img(step):
    return P.load('%s/%s.img' % (d, step))
for step, want in (('shown1', 'shown'), ('hidden1', 'handle'), ('shown2', 'shown'), ('hidden2', 'handle')):
    check(state(step) == want, 'keyboard %s after %s' % (want, step))
# the Workspace column (Lucifer's conv_pct 30, pres_pct 45), from below
# the task bar to above where the keyboard's strip goes
x0, x1 = W * 30 // 100 + 2, W * 75 // 100 - 2
y0, y1 = 140, H // 2
def region(im):
    w = im.w
    return [bytes(im.rgb[(y * w + x) * 3:(y * w + x) * 3 + 3]) for y in range(y0, y1, 4) for x in range(x0, x1, 4)]
base = region(img('boot'))
check(len(set(base)) > 1, 'the Workspace column has something drawn at boot')
for step in ('shown1', 'hidden1', 'shown2', 'hidden2'):
    r = region(img(step))
    same = sum(1 for a, b in zip(base, r) if a == b) * 100 // len(base)
    check(same >= 99, 'the Workspace column as it was with the keyboard %s (%s): %d%% the same' % (state(step), step, same))
sys.exit(failed)
PY

# the screen turned, where it can be: Xvfb, xdotool and a touch build
TOUCH_EMU=${TOUCH_EMU:-}
if [ -z "$TOUCH_EMU" ] || [ ! -x "$TOUCH_EMU" ] || ! command -v Xvfb >/dev/null || ! command -v xdotool >/dev/null; then
	echo "(the screen turned: skipped, needs TOUCH_EMU, Xvfb and xdotool)"
	exit $fail
fi
R="$T/rot"
mkdir -p "$R"
dpy=:$(( ($$ % 50) + 40 ))
Xvfb $dpy -screen 0 3000x3000x24 >/dev/null 2>&1 &
xvfb=$!
sleep 2
DISPLAY=$dpy SDL_VIDEODRIVER=x11 with_timeout 150 "$TOUCH_EMU" -c1 $POOLS -g2064x2664 -r"$ROOT" \
	/dis/sh.dis -l -c "run /lib/lucifer/boot-mobile.sh --no-logon --tablet & sleep 45; bind -c /$R /tmp; echo R up; sleep 20; scap /tmp/after.img; echo R turned; echo halt > /dev/sysctl" \
	</dev/null >"$R/log" 2>&1 &
emu=$!
i=0
while [ $i -lt 90 ] && ! grep -q '^R up' "$R/log"; do sleep 1; i=$((i + 1)); done
wid=$(DISPLAY=$dpy xdotool search --name InferNode | head -1)
[ -n "$wid" ] && DISPLAY=$dpy xdotool windowsize "$wid" 2752 1976
wait $emu || true
kill $xvfb 2>/dev/null || true
# Lucifer reads /dev/wmsize (one reader takes each size), so its change
# of layout is how the size is seen to reach programs
check "turned: Lucifer changes to the columns" "$(layout "$R/log")" columns
PYTHONPATH="$ROOT/tools" python3 -c "
import sys, p9img2png as P
im = P.load('$R/after.img'); w, h = im.w, im.h
print(('PASS' if (w, h) == (2752, 1976) else 'FAIL') + ': turned: the screen is %dx%d' % (w, h))
sys.exit((w, h) != (2752, 1976))
" || fail=1
exit $fail
