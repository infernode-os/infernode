#!/bin/sh
#
# The system's keyboard (iOS's, Android's) is never shown: the three
# locks in emu/port/draw-sdl3.c (apply_softkbd's comment) stay in place.
# A REGRESSION PIN on the source, not a test of behaviour -- that needs
# a phone -- plus a compile of the Android path, which Linux can do:
#   - SDL_HINT_ENABLE_SCREEN_KEYBOARD "0" set, on the touch platforms,
#     before SDL_Init;
#   - SDL_StartTextInput called on them only in apply_softkbd, and only
#     while SDL_HasKeyboard(), with ios_nosystemkeyboard either side;
#     the GUI's requests (setsoftkbd, setsoftkbd_rect) doing nothing;
#   - emu/iOS/nokeyboard.m (the empty input view) in the iOS SDL build;
#   - a hardware keyboard's printable keys taken from key-down events
#     while text input is off.
# No emulator needed.
#
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F=$ROOT/emu/port/draw-sdl3.c
failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }

# the hint, before SDL_Init, under MOBILE_TOUCH
awk '/^sdl3_preinit\(void\)/,/SDL_Init\(SDL_INIT_VIDEO\)/' "$F" > /tmp/nsk.$$
if grep -q 'SDL_SetHint(SDL_HINT_ENABLE_SCREEN_KEYBOARD, "0")' /tmp/nsk.$$ && grep -q '#if MOBILE_TOUCH' /tmp/nsk.$$; then
	pass "the screen keyboard hint off before SDL_Init"
else
	fail "SDL_HINT_ENABLE_SCREEN_KEYBOARD \"0\" not set before SDL_Init on the touch platforms"
fi
rm -f /tmp/nsk.$$

# every SDL_StartTextInput: the desktop's, or apply_softkbd's under SDL_HasKeyboard
n=$(grep -c 'SDL_StartTextInput(' "$F")
inapply=$(awk '/^apply_softkbd\(void\)/,/^}/' "$F" | grep -c 'SDL_StartTextInput(')
desktop=$(awk '/#else/{e=1} /Desktop: no keyboard on the screen/{d=1} d && /SDL_StartTextInput\(/{print; d=0}' "$F" | grep -c .)
if [ "$n" = $((inapply + desktop)) ] && [ "$inapply" = 1 ]; then
	pass "text input started only by apply_softkbd (and the desktop's, always on)"
else
	fail "SDL_StartTextInput called $n times: $inapply in apply_softkbd, $desktop the desktop's"
fi
awk '/^apply_softkbd\(void\)/,/^}/' "$F" | grep -q 'want = SDL_HasKeyboard();' &&
	pass "only while a hardware keyboard is attached" || fail "apply_softkbd starts text input without SDL_HasKeyboard"
[ "$(awk '/^apply_softkbd\(void\)/,/^}/' "$F" | grep -c 'nosystemkeyboard();')" -ge 2 ] &&
	pass "iOS's text field has no keyboard of its own, before and after" || fail "ios_nosystemkeyboard not either side of SDL_StartTextInput"
for fn in setsoftkbd setsoftkbd_rect; do
	body=$(awk "/^$fn\\(/,/^}/" "$F" | grep -v "^$fn\|^{\|^}\|USED" | grep -c '[a-z]')
	[ "$body" = 0 ] && pass "$fn does nothing" || fail "$fn does something"
done
grep -q '^GUISRC=.*nokeyboard\.\$O' "$ROOT/emu/iOS/mkfile-gui-sdl3" &&
	pass "nokeyboard.m in the iOS SDL build" || fail "emu/iOS/mkfile-gui-sdl3 does not build nokeyboard.m"
grep -q 'inputView = \[\[UIView alloc\] initWithFrame:CGRectZero\]' "$ROOT/emu/iOS/nokeyboard.m" &&
	pass "its empty input view" || fail "nokeyboard.m sets no empty input view"
awk '/^handle_key_down/,/^}/' "$F" | grep -q 'SDL_TextInputActive(sdl_window)' &&
	pass "printable keys from key-down while text input is off" || fail "handle_key_down takes no printable keys"

# the Android path compiles (SDL3's headers and a C compiler, when there are some)
inc=
for d in /usr/local/include /usr/include "${SDL3_PREFIX:-/nonexistent}/include"; do
	[ -f "$d/SDL3/SDL.h" ] && inc=$d && break
done
if [ -n "$inc" ] && command -v cc >/dev/null; then
	if cc -fsyntax-only -D__ANDROID__ -DROOT='"/x"' -DEMU -I"$ROOT/emu/Linux" -I"$ROOT/emu/port" \
		-I"$ROOT/Linux/amd64/include" -I"$ROOT/include" -I"$ROOT/libinterp" -DGUI_SDL3 -I"$inc" "$F" 2>/tmp/nsk.$$; then
		pass "the Android path compiles"
	else
		fail "the Android path does not compile: $(grep error /tmp/nsk.$$ | head -3)"
	fi
	rm -f /tmp/nsk.$$
else
	echo "(no SDL3 headers: the Android path not compiled)"
fi

[ $failed -eq 0 ] && echo "ALL PASS"
exit $failed
