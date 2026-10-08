#!/bin/sh
#
# xenith_scroll_quit_test.sh — scrolling never quits Xenith.
#
# Xenith's quit, help and resize signals travel down the same channel
# as the pointer's events, as button bits. M_QUIT was 32, and the
# emulator sends 32 for scrolling left: a trackpad's vertical scroll
# nearly always moves a little sideways too, so scrolling quit Xenith
# (INFR-523), silently and with status 0 when every window was clean.
#
# This runs Xenith under the SDL dummy driver, sends every wheel
# direction (8 up, 16 down, 32 left, 64 right) through /dev/pointer,
# and checks Xenith is still running. Needs the SDL GUI emulator:
# SKIP (77) on a headless build.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "xenith_scroll_quit_test: SKIP (no emu)"; exit 77; }
if command -v nm >/dev/null 2>&1; then
    syms=$(nm "$EMU" 2>/dev/null)
    if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
        echo "xenith_scroll_quit_test: SKIP (headless emulator)"; exit 77
    fi
fi
[ -f "$ROOT/dis/xenith.dis" ] || { echo "xenith_scroll_quit_test: SKIP (Xenith not built)"; exit 77; }

out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c0 -g800x600 -r"$ROOT" /dis/sh.dis -c '
load std
xenith &
sleep 6
echo before `{ps | grep -i xenith | wc -l}
for b in 8 16 32 64 32 64 16 8 {
	echo m 300 300 0 > /dev/pointer
	echo m 300 300 $b > /dev/pointer
}
echo m 300 300 0 > /dev/pointer
sleep 3
echo after `{ps | grep -i xenith | wc -l}
echo halt > /dev/sysctl' 2>&1)

before=$(printf '%s\n' "$out" | sed -n 's/^before *//p' | tr -d ' ')
after=$(printf '%s\n' "$out" | sed -n 's/^after *//p' | tr -d ' ')
if [ -z "$before" ] || [ "$before" = 0 ]; then
    echo "FAIL: Xenith did not start"
    printf '%s\n' "$out" | sed 's/^/    /'
    exit 1
fi
if [ "$after" = "$before" ]; then
    echo "PASS: Xenith is still running after scrolling in every direction"
    exit 0
fi
echo "FAIL: Xenith processes $before before scrolling, '$after' after"
exit 1
