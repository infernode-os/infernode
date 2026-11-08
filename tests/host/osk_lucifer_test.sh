#!/bin/sh
#
# wm/osk as Lucifer's keyboard (tests/osk/lucifer.sh): started with
# Lucifer and hidden, shown in a strip along the bottom once the screen
# is touched with no keyboard attached, the zones laid out above it;
# what is typed on it reaches the zone with the keyboard (the chat) and
# is sent; with the mouse, the keys go where the last click was, not
# where the mouse crossed into the strip (the chat, a shell in the
# presentation zone, wm/wm's shell there); a keyboard attached hides it and gives the zones the screen
# back, detached shows it again; the machine's keyboard typed on hides
# it to its handle.  Needs the SDL emulator (SDL_VIDEODRIVER=dummy).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/osk.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/osk_lucifer_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; bind -c /$T /tmp; run /tests/osk/lucifer.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
st() { sed -n "s/^$2 //p" "$ROOT/$T/status.$1" 2>/dev/null; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; grep -v '^fs:' "$LOG" | tail -20; exit 1; }

[ "$(st before state)" = hidden ] && pass "started with Lucifer, hidden until wanted" ||
	fail "before: state '$(st before state)'"
[ "$(st touched state)" = shown ] && pass "a touch with no keyboard attached shows it" ||
	fail "touched: state '$(st touched state)'"
h=$(st touched height)
if [ -n "$h" ] && [ "$h" -gt 150 ] && [ "$h" -lt 461 ]; then
	pass "a strip of $h pixels"
else
	fail "touched: height '$h'"
fi
# its keys are in the strip along the bottom of the screen
top=$((768 - ${h:-0}))
bad=$(awk -v top="$top" 'NF == 5 && ($3 < top || $5 > 768 || $2 < 0 || $4 > 1024) {print}' "$ROOT/$T/keys.touched" | head -3)
[ -s "$ROOT/$T/keys.touched" ] && [ -z "$bad" ] && pass "its keys in the strip" ||
	fail "keys outside the strip: $bad"
nb=$(tr -dc 0-9 < "$ROOT/$T/nconv.before" 2>/dev/null)
na=$(tr -dc 0-9 < "$ROOT/$T/nconv.after" 2>/dev/null)
[ -n "$nb" ] && [ -n "$na" ] && [ "$na" -gt "$nb" ] && pass "typed into the chat and sent" ||
	fail "the conversation did not grow: $nb then $na"
# with the mouse, typed where the last click was (not where the mouse
# crossed into the strip): the chat, a shell in the zone, wm/wm's shell
# in the zone
out() { grep -v '^;' "$ROOT/$T/body.$1" 2>/dev/null | tail -1; }
nc=$(tr -dc 0-9 < "$ROOT/$T/nconv.tochat" 2>/dev/null)
[ -n "$na" ] && [ -n "$nc" ] && [ "$nc" -gt "$na" ] && ! grep -q hi "$ROOT/$T/body.tochat" &&
	pass "with the mouse: to the chat clicked in, not the shell crossed" ||
	fail "with the mouse to the chat: the conversation $na then $nc, the shell '$(out tochat)'"
ns=$(tr -dc 0-9 < "$ROOT/$T/nconv.toshell" 2>/dev/null)
[ "$(out toshell)" = ok ] && [ "$ns" = "$nc" ] &&
	pass "with the mouse: to the shell clicked in, not the chat crossed" ||
	fail "with the mouse to the shell: '$(out toshell)', the conversation $nc then $ns"
[ "$(out towm)" = wm ] &&
	pass "with the mouse: to wm/wm's shell clicked in, in the zone" ||
	fail "with the mouse to wm/wm's shell: '$(out towm)'"
[ "$(st attached state)" = hidden ] && pass "a keyboard attached hides it" ||
	fail "attached: state '$(st attached state)'"
[ ! -s "$ROOT/$T/keys.attached" ] && pass "and its strip is gone" || fail "attached: keys still shown"
[ "$(st attached keyboards)" = 1 ] && pass "status says a keyboard is attached" ||
	fail "attached: keyboards '$(st attached keyboards)'"
[ "$(st detached state)" = shown ] && pass "detached: shown again" ||
	fail "detached: state '$(st detached state)'"
[ "$(st typedhard state)" = handle ] && pass "the machine's keyboard typed on: to its handle" ||
	fail "typed on: state '$(st typedhard state)'"

if [ $failed -ne 0 ]; then
	echo "--- log"
	grep -v '^fs:' "$LOG" | tail -30
	exit 1
fi
echo "ALL PASS"
