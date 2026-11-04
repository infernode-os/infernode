#!/bin/sh
#
# wm/osk in Lucifer's phone layout (tests/osk/mobile.sh): the chat's
# field tapped shows the keyboard and its strip's icon hides it, twice.
# Each time the zones are laid out again the accordion keeps its Chat
# title and the chat what it showed, by pixel: the zones were laid out
# on a fresh screen, and the old ones, freed after the new were drawn,
# painted the old screen's fill over them (the Chat title and the chat
# blank on iOS and Android after the keyboard hid).  Needs the SDL
# emulator (SDL_VIDEODRIVER=dummy).
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

W=720 H=1280
T=tmp/osk_mobile_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 200 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g${W}x$H -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; infmobile=1; run /lib/lucifer/boot.sh & sleep 45; bind -c /$T /tmp; w=$W; h=$H; run /tests/osk/mobile.sh" \
	</dev/null >"$LOG" 2>&1 || true

grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; grep -v '^fs:' "$LOG" | tail -20; exit 1; }

PYTHONPATH="$ROOT/tools" python3 - "$ROOT/$T" <<'PY'
import sys, re
import p9img2png as P
d = sys.argv[1]
log = open(d + '/log', errors='replace').read()
failed = 0
def check(ok, what):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        failed = 1
def status(step):
    s = {}
    for l in open('%s/status.%s' % (d, step)):
        k, _, v = l.strip().partition(' ')
        s[k] = v
    return s
m = re.findall(r'zonerects expanded=0 bodytop=(\d+) bodybot=\d+ titleh=(\d+) ctx_y=(\d+) pres_y=\d+ conv_y=(\d+)', log)
if not m:
    print('FAIL: no accordion layout in the log'); sys.exit(1)
bodytop, titleh, ctxy, convy = map(int, m[-1])
for step, want in (('shown1', 'shown'), ('hidden1', 'handle'), ('shown2', 'shown'), ('hidden2', 'handle')):
    st = status(step).get('state')
    check(st == want, '%s: the keyboard %s (%s)' % (step, want, st))
    im = P.load('%s/%s.img' % (d, step))
    w, h = im.w, im.h
    at = lambda x, y: tuple(im.rgb[(y * w + x) * 3:(y * w + x) * 3 + 3])
    x = w // 2
    title = at(x, ctxy + titleh // 2)
    chat = at(x, convy + titleh // 2)
    check(chat == title, '%s: the Chat title drawn (%s, as Context\'s %s)' % (step, chat, title))
    # the chat's body, from below its title to a little above the input:
    # "No messages yet" or the messages, not only the fill
    top = convy + titleh + 4
    ys = [int(l.split()[2]) for l in open('%s/keys.%s' % (d, step)) if len(l.split()) == 5]
    bot = (min(ys) if ys else h) - 150
    bg = at(4, top + 4)
    lit = sum(1 for y in range(top, bot, 2) for xx in range(0, w, 2) if at(xx, y) != bg)
    check(lit > 1000, '%s: the chat drawn (%d pixels not its fill)' % (step, lit))
sys.exit(failed)
PY
rc=$?
[ $rc -eq 0 ] && echo "ALL PASS" || { grep -v '^fs:' "$LOG" | grep -vE 'accordion' | tail -15; }
exit $rc
