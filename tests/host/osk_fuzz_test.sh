#!/bin/sh
#
# wm/osk ground with random use (tests/osk_fuzz.b, through
# tests/osk/fuzz.sh) as it types into a wm/editor under wm/wm: taps,
# strokes, two fingers at once, long presses, the suggestions, delete
# and its stroke, hiding and showing, layers and layouts, at random
# speeds.  Afterwards it still answers, the editor holds exactly what
# osk says it typed (its trace, every correction and delete applied),
# and shift is not left on.  OSK_FUZZ_SEED and OSK_FUZZ_ACTIONS choose
# the run (a failing seed is printed).  Needs the SDL emulator
# (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/editor.dis dis/wm/osk.dis dis/tests/osk_fuzz.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi
command -v python3 >/dev/null || { echo "SKIP: no python3 to read the trace"; exit 77; }

# a seed of its own each run, but 1 in CI (CI is set), so a failure there reruns
SEED=${OSK_FUZZ_SEED:-${CI:+1}}
SEED=${SEED:-$(date +%s)}
ACTIONS=${OSK_FUZZ_ACTIONS:-400}
T=tmp/osk_fuzz_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
echo "seed $SEED, $ACTIONS actions"
SDL_VIDEODRIVER=dummy with_timeout 600 "$EMU" -c1 -pheap=512m -pimage=512m -g800x480 -r"$ROOT" \
	/dis/sh.dis -c "seed=$SEED; actions=$ACTIONS; bind -c /$T /tmp; wm/wm sh /tests/osk/fuzz.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }

grep -q '^R done' "$LOG" || { fail "the run did not finish (seed $SEED)"; grep -v '^fs:' "$LOG" | tail -20; exit 1; }
grep -q '^oskfuzz: ' "$LOG" && pass "$ACTIONS random actions" || fail "the fuzzer did not finish"
grep -q '^state ' "$ROOT/$T/status" && pass "it still answers" || fail "no status after the fuzzing"
grep -q '^state shown' "$ROOT/$T/status.end" && pass "shown at the end" || fail "end: $(head -1 "$ROOT/$T/status.end")"

# the editor's text against osk's trace: every "t" line typed, \b deleting
python3 -I - "$ROOT/$T/trace" "$ROOT/$T/body" <<'PY' || failed=1
import sys
def unq(s):
    out=[]; i=0
    while i < len(s):
        c=s[i]
        if c=='\\' and i+1 < len(s):
            n=s[i+1]; out.append({'n':'\n','b':'\b','t':'\t','\\':'\\'}.get(n,n)); i+=2
        else:
            out.append(c); i+=1
    return ''.join(out)
text=[]
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    line=line.rstrip('\n')
    if not line.startswith('t '):
        continue
    for c in unq(line[2:]):
        if c=='\b':
            if text: text.pop()
        else:
            text.append(c)
want=''.join(text)
got=open(sys.argv[2], encoding='utf-8', errors='replace').read()
if got == want:
    print("PASS: the editor holds what osk typed (%d characters)" % len(got))
    if got.endswith('qq') or got.endswith('Qq'):
        print("PASS: shift is not left on")
    else:
        print("FAIL: the last two letters typed are %r, not 'qq'" % got[-2:]); sys.exit(1)
else:
    n=next((i for i in range(min(len(got),len(want))) if got[i]!=want[i]), min(len(got),len(want)))
    print("FAIL: the editor differs from what osk typed at %d: %r vs %r" % (n, got[max(0,n-20):n+20], want[max(0,n-20):n+20]))
    sys.exit(1)
PY

if [ $failed -ne 0 ]; then
	echo "(seed $SEED: OSK_FUZZ_SEED=$SEED reruns it)"
	grep -v '^fs:' "$LOG" | tail -20
	exit 1
fi
echo "ALL PASS"
