#!/bin/sh
#
# charon_headless_test.sh — wm/charon -h, Charon with no window: a page
# read and a form submitted through its files.  Runs
# tests/inferno/charon_headless_test.sh in an emu, with a draw device
# (SDL's dummy driver) so the rendering is checked too.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_headless_test: SKIP (no emu)"; exit 77; }
mkdir -p "$ROOT/tmp"
# a headless emu has no draw device, so no rendering to check
nodraw=0
if command -v nm >/dev/null 2>&1 && ! nm "$EMU" 2>/dev/null | grep -q sdl3_mainloop; then
    nodraw=1
fi
out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "load std; nodraw=$nodraw; sh /tests/inferno/charon_headless_test.sh; echo halt > '#c/sysctl'" 2>&1)
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP|ALL PASS)'
printf '%s\n' "$out" | grep -q '^ALL PASS' && exit 0
echo "FAIL: charon_headless_test"
printf '%s\n' "$out" | grep -vE '^(PASS|FAIL|SKIP)' | sed 's/^/    /'
exit 1
