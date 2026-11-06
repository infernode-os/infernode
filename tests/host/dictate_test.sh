#!/bin/sh
#
# dictate_test.sh — dictate(1) and Lucifer's microphone, on speech(4)
# with the fake audio hardware ($INFERNODE_AUDIO_FAKE) and the fake
# engine (tests/speechfake.b).  Alone (tests/dictate/alone.sh): dictate
# turns talk on, and once the user turns it off types the utterance's
# words; with -w it waits for talk to be turned on; with talk on already
# it refuses, and leaves nothing running.  In Lucifer
# (tests/dictate/lucifer.sh, booted headless): the microphone at the
# right of the header, dim, then red while on, by pixel; Ctrl+Space and
# a tap on it each turn it on and off, and the words are typed into the
# chat; while an agent asks (speech's ask) it is lit in the accent, and
# a tap answers the agent: the words go to the ask and are not typed.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/dictate.dis dis/veltro/speech9p.dis dis/tests/speechfake.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

T=tmp/dictate_test.$$
mkdir -p "$ROOT/$T"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
python3 -I - "$T/tone.raw" <<'PY'
import sys, struct, math
with open(sys.argv[1], 'wb') as f:
    for i in range(int(48000 * 0.6)):
        v = int(7000 * math.sin(2 * math.pi * 700 * i / 48000))
        f.write(struct.pack('<hh', v, v))
PY

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$T/$1" 2>/dev/null || true; }
has() { grep -q -- "$2" "$T/$1" 2>/dev/null; }

printf 'call sarah at work\nmeet at noon\nnot mine\n' > "$T/script"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; run /tests/dictate/alone.sh" \
	</dev/null >"$T/log.alone" 2>&1 || true
grep -q '^R done' "$T/log.alone" || { fail "the driver did not finish"; tail -20 "$T/log.alone"; }

has ctl.1 '^talk on' && pass "dictate turns talk on" || fail "ctl while dictating: $(f ctl.1 | tr '\n' '|')"
[ "$(f typed.1)" = "call sarah at work " ] && pass "and types the words once talk is off" || fail "typed '$(f typed.1)' ($(f err.1))"
has ctl.2 '^talk off' && [ "$(f typed.2)" = "meet at noon " ] &&
	pass "-w: waits for talk, then types its words" || fail "-w: talk $(f ctl.2 | grep talk), typed '$(f typed.2)' ($(f err.2))"
[ ! -s "$T/typed.3" ] && has err.3 'talk is on already' &&
	pass "with talk on already it refuses and types nothing" || fail "talk on: typed '$(f typed.3)', said '$(f err.3)'"
a=$(tr -dc 0-9 < "$T/nprog.a" 2>/dev/null); b=$(tr -dc 0-9 < "$T/nprog.b" 2>/dev/null)
[ -n "$a" ] && [ "$a" = "$b" ] && pass "nothing of it left running ($a Progs)" || fail "Progs $a then $b"

# Lucifer: needs the SDL emulator
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: Lucifer's microphone ($EMU is a headless build)"
	exit $failed
fi
[ -f "$ROOT/dis/lucifer.dis" ] || { fail "lucifer.dis not built"; exit 1; }
printf 'call sarah at work\ncall bob\nthe answer is yes\n' > "$T/script"
printf '\0' > "$T/nul"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 200 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; bind -c /$T /tmp; run /tests/dictate/lucifer.sh" \
	</dev/null >"$T/log.lucifer" 2>&1 || true
grep -q '^R done' "$T/log.lucifer" || { fail "the Lucifer driver did not finish"; grep -v '^fs:' "$T/log.lucifer" | tail -20; exit 1; }

# the microphone's square, the header's last 40 pixels: how many pixels
# of the theme's dim, red and accent colours
for s in off on asked after; do
	python3 -I tools/p9img2png.py "$T/$s.img" "$T/$s.png" >/dev/null 2>&1 || true
done
count() {
	python3 -I - "$T/$1.png" "$ROOT/lib/lucifer/theme/$(cat "$ROOT/lib/lucifer/theme/current" 2>/dev/null || echo brimstone)" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
th = {}
for l in open(sys.argv[2]):
    w = l.split()
    if len(w) == 2 and len(w[1]) == 6 and all(c in '0123456789abcdefABCDEF' for c in w[1]):
        th[w[0]] = tuple(int(w[1][i:i+2], 16) for i in (0, 2, 4))
W = im.size[0]
n = {'dim': 0, 'red': 0, 'accent': 0}
for y in range(0, 40):
    for x in range(W - 40, W):
        p = im.getpixel((x, y))
        for k in n:
            if all(abs(p[i] - th[k][i]) <= 12 for i in range(3)):
                n[k] += 1
print(n['dim'], n['red'], n['accent'])
PY
}
set -- $(count off 2>/dev/null || echo 0 0 0); d=$1; r=$2; a=$3
[ "$d" -ge 20 ] && [ "$r" -lt 5 ] && [ "$a" -lt 20 ] && pass "the microphone at the header's right, dim while off ($d pixels)" ||
	fail "off: dim $d red $r accent $a"
set -- $(count on 2>/dev/null || echo 0 0 0); d=$1; r=$2; a=$3
[ "$r" -ge 20 ] && pass "red while on ($r pixels)" || fail "on: dim $d red $r accent $a"
set -- $(count asked 2>/dev/null || echo 0 0 0); d=$1; r=$2; a=$3
[ "$a" -ge 400 ] && pass "lit in the accent while an agent asks ($a pixels)" || fail "asked: dim $d red $r accent $a"
set -- $(count after 2>/dev/null || echo 0 0 0); d=$1; r=$2; a=$3
[ "$d" -ge 20 ] && [ "$a" -lt 20 ] && pass "dim again once answered" || fail "after: dim $d red $r accent $a"

has ctl.start '^engine /mnt/fakeengine' && has ctl.start '^engine ok' && pass "the fake engine is speech's" || fail "ctl: $(f ctl.start | tr '\n' '|')"
has ctl.key '^talk on' && pass "Ctrl+Space turns talk on" || fail "after Ctrl+Space: $(f ctl.key | grep talk)"
grep -q 'call sarah at work' "$T/sent.key" 2>/dev/null && pass "and again off: the words typed into the chat" || fail "the chat sent '$(f sent.key)'"
has ctl.tap '^talk on' && grep -q 'call bob' "$T/sent.tap" 2>/dev/null &&
	pass "a tap on the microphone does the same" || fail "tap: $(f ctl.tap | grep talk), sent '$(f sent.tap)'"
has ctl.answer '^talk on' && [ "$(f ask.words)" = "the answer is yes" ] &&
	pass "while an agent asks, a tap answers it" || fail "answer: $(f ctl.answer | grep talk), ask got '$(f ask.words)'"
grep -q 'answer is yes' "$T/sent.ask" 2>/dev/null && fail "the answer was typed into the chat too" || pass "and the answer is not typed"

exit $failed
