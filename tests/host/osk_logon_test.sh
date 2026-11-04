#!/bin/sh
#
# wm/osk as the boot starts it for the login screen (lib/lucifer/boot.sh,
# boot-baremetal.sh; tests/osk/logon.sh): with no window manager, in
# secret mode: hidden until the screen is touched, then along the
# bottom of the screen; what it types reaches the keyboard's reader
# (wm/logon) as typed -- nothing put right -- and nothing of it is
# recorded (its trace says only that a key was typed) or learned; no
# word list read (a slow board's seconds, as the password is typed)
# until a mode wants it; a touch above its keys types nothing; kill -g
# ends all of it.  Needs
# the SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/osk.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/osk_logon_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g800x480 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; run /tests/osk/logon.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
st() { sed -n "s/^$2 //p" "$ROOT/$T/status.$1" 2>/dev/null; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; grep -v '^fs:' "$LOG" | tail -20; exit 1; }
[ "$(st before state)" = hidden ] && pass "hidden until the screen is touched" || fail "before: '$(st before state)'"
[ "$(st shown state)" = shown ] && pass "shown once it is" || fail "touched: '$(st shown state)'"
[ "$(st shown mode)" = secret ] && pass "secret mode" || fail "mode '$(st shown mode)'"
bad=$(awk 'NF == 5 && ($3 < 240 || $5 > 480) {print}' "$ROOT/$T/keys" | head -2)
[ -s "$ROOT/$T/keys" ] && [ -z "$bad" ] && pass "its keys along the bottom of the screen" || fail "keys: $bad"
typed=$(cat "$ROOT/$T/typed" 2>/dev/null)
[ "$typed" = "hunter " ] && pass "typed as tapped, nothing put right, nothing more" || fail "typed '$typed'"
if grep -q 'hunter\|^t [^*]' "$ROOT/$T/trace.copy"; then
	fail "the trace has what was typed: $(grep '^t ' "$ROOT/$T/trace.copy" | head -3)"
else
	n=$(grep -c '^t \*$' "$ROOT/$T/trace.copy" || true)
	[ "$n" -ge 6 ] && pass "its trace says only that keys were typed ($n)" || fail "trace: $n keys"
fi
[ ! -s "$ROOT/$T/home/lib/osk/words" ] && pass "nothing learned" || fail "learned: $(cat "$ROOT/$T/home/lib/osk/words")"
[ "$(st secret words)" = 0 ] && pass "no words read for a password (it puts nothing right)" ||
	fail "secret mode read $(st secret words) words"
w=$(st text words)
[ -n "$w" ] && [ "$w" -gt 0 ] && pass "read once a mode wants them ($w)" || fail "text mode: words '$w'"
grep -q '^R gone' "$LOG" && pass "kill -g ends it" || fail "still serving after kill -g"

[ $failed -eq 0 ] && echo "ALL PASS"
exit $failed
