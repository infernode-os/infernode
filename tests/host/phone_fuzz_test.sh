#!/bin/sh
#
# Lucifer's phone layout, booted as iOS and Android boot it
# (boot-mobile.sh), ground with random use (tests/phone_fuzz.b, through
# tests/osk/phonefuzz.sh): taps on the accordion's titles and anywhere,
# the chat's field, wm/osk's keys, strokes, delete, two fingers at once,
# its hide icon and handle, drags, a keyboard attached and detached,
# every touch a finger and the pointer's press made from it.  At each
# checkpoint, by pixel: the three title bars drawn alike, the open zone
# not blank, osk's letters drawn on their keys while it shows, the zones
# not under the keys; at the end osk and Lucifer's UI server still
# answer and nothing panicked.  PHONE_FUZZ_SEED and PHONE_FUZZ_ACTIONS
# choose the run (a failing seed is printed), PHONE_FUZZ_SIZE the screen
# (an iPhone's 1179x2556; 1080x2400 is a common Android's).  Needs the
# SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/osk.dis dis/scap.dis dis/tests/phone_fuzz.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }

# a seed of its own each run, but 1 in CI (CI is set), so a failure there reruns
SEED=${PHONE_FUZZ_SEED:-${CI:+1}}
SEED=${SEED:-$(date +%s)}
ACTIONS=${PHONE_FUZZ_ACTIONS:-240}
EVERY=${PHONE_FUZZ_EVERY:-30}
SIZE=${PHONE_FUZZ_SIZE:-1179x2556}
# -c0 to rerun a failure interpreted, whose stacks name their lines
JIT=${PHONE_FUZZ_JIT:--c1}
W=${SIZE%x*} H=${SIZE#*x}
T=tmp/phone_fuzz_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
echo "seed $SEED, $ACTIONS actions, ${W}x$H"
SDL_VIDEODRIVER=dummy with_timeout 1200 "$EMU" $JIT -pheap=1024m -pmain=1024m -pimage=1024m -g${W}x$H -r"$ROOT" \
	/dis/sh.dis -l -c "run /lib/lucifer/boot-mobile.sh --no-logon & sleep 45; bind -c /$T /tmp; seed=$SEED; actions=$ACTIONS; every=$EVERY; w=$W; h=$H; run /tests/osk/phonefuzz.sh" \
	</dev/null >"$LOG" 2>&1 || true

PYTHONPATH="$ROOT/tools" python3 - "$ROOT/$T" "$ACTIONS" "$EVERY" <<'PY'
import sys, re, os
import p9img2png as P
d, actions, every = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
log = open(d + '/log', errors='replace').read()
failed = 0
def check(ok, what):
    global failed
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        failed = 1
    return ok

check('R done' in log.splitlines(), 'the run finished')
check(re.search(r'^phonefuzz: %d actions' % actions, log, re.M) is not None, '%d random actions' % actions)
bad = [l for l in log.splitlines() if re.search(r'panic|Broken:|exception|nil dereference|array bounds|out of memory|link typecheck|^tk: ', l)]
check(not bad, 'nothing panicked or died' + ('' if not bad else ': ' + bad[0]))
stall = re.search(r'^S stalled at action (\d+)', log, re.M)
check(stall is None, 'it went on to the end' + ('' if stall is None else ' (stalled at action %s)' % stall.group(1)))
for b in re.findall(r'^B (.*)$', log, re.M):
    print('broken: ' + b)
st = open(d + '/status.end').read() if os.path.exists(d + '/status.end') else ''
check(st.startswith('state ') or '\nstate ' in st, 'osk still answers')
check(os.path.exists(d + '/ui.end') and os.path.getsize(d + '/ui.end') > 0, "Lucifer's UI server still answers")

# each checkpoint against the accordion's layout logged before it
lay = None
cps = []
for l in log.splitlines():
    m = re.search(r'zonerects expanded=(\d) bodytop=(\d+) bodybot=(\d+) titleh=(\d+) ctx_y=(\d+) pres_y=(\d+) conv_y=(\d+)', l)
    if m:
        lay = tuple(map(int, m.groups()))
    m = re.match(r'^C (\d+)$', l)
    if m:
        cps.append((int(m.group(1)), lay))
want = (actions + every - 1) // every
check(len(cps) == want, '%d checkpoints (%d)' % (want, len(cps)))
for n, lay in cps:
    if lay is None:
        check(False, 'checkpoint %d: no accordion layout logged' % n); continue
    exp, bodytop, bodybot, titleh, ctxy, presy, convy = lay
    try:
        im = P.load('%s/cp.%d.img' % (d, n))
    except Exception as e:
        check(False, 'checkpoint %d: no screen (%s)' % (n, e)); continue
    w, h = im.w, im.h
    at = lambda x, y: tuple(im.rgb[(y * w + x) * 3:(y * w + x) * 3 + 3])
    status = {}
    for l in open('%s/cp.%d.status' % (d, n)):
        k, _, v = l.strip().partition(' ')
        status[k] = v
    keys = {}
    for l in open('%s/cp.%d.keys' % (d, n)):
        f = l.split()
        if len(f) == 5:
            keys[f[0]] = tuple(int(v) for v in f[1:])
    shown = status.get('state') == 'shown'
    where = 'checkpoint %d (zone %d open, keyboard %s)' % (n, exp, status.get('state'))
    # the title bars drawn alike, between their labels and chevrons
    xs = (w // 2, w * 3 // 4)
    tc = [[at(x, y + titleh // 2) for x in xs] for y in (ctxy, presy, convy)]
    check(tc[0] == tc[1] == tc[2], '%s: the three title bars drawn alike (%s)' % (where, [t[0] for t in tc]))
    # the zones above the keys
    if shown:
        ky = min(k[1] for k in keys.values()) if keys else h
        check(bodybot <= ky, '%s: the zones end above the keys (%d, keys at %d)' % (where, bodybot, ky))
    # the open zone's body not only its fill
    top = {0: convy, 1: presy, 2: ctxy}[exp] + titleh + 4
    bot = {0: bodybot, 1: convy, 2: presy}[exp] - 4
    bg = at(4, top + 2)
    lit = sum(1 for y in range(top, bot, 3) for x in range(0, w, 3) if at(x, y) != bg)
    check(lit > 300, '%s: the open zone drawn (%d points not its fill)' % (where, lit))
    if shown:
        # every letter's label drawn on its key
        blank = []
        for c, (x0, y0, x1, y1) in keys.items():
            if len(c) != 1 or not c.isalpha():
                continue
            fill = at((x0 + x1) // 2, y0 + 6)
            ink = sum(1 for y in range(y0 + 2, y1 - 2, 2) for x in range(x0 + 4, x1 - 4, 2)
                      if sum(abs(a - b) for a, b in zip(at(x, y), fill)) > 120)
            if ink < 10:
                blank.append(c)
        check(len(keys) > 20 and not blank, '%s: the letters drawn on their keys%s' % (where, '' if not blank else ' (not %s)' % ''.join(blank)))
sys.exit(failed)
PY
rc=$?
if [ $rc -ne 0 ]; then
	echo "(seed $SEED: PHONE_FUZZ_SEED=$SEED reruns it)"
	grep -v '^fs:' "$LOG" | grep -v accordion | tail -20
	exit 1
fi
echo "ALL PASS"
