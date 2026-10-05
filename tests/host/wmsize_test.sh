#!/bin/sh
#
# wmsize_test.sh — the screen programs see is the window, and
# /dev/wmsize says so.
#
# On desktop the SDL emulator backs the screen with a buffer as large as
# the largest display, shows the window's part of it one to one, and
# tells programs its size through /dev/wmsize, so a resize (macOS full
# screen, say) is laid out again instead of scaled with black margins.
# This checks the half that needs no resize: under the SDL dummy driver,
# whose display is larger than the window asked for, the screen a client
# is given (#i/draw/new) is the window's size, not the display's, and
# /dev/wmsize is bound and reports that size.
#
# Resizing itself needs a real window manager; it was checked by hand on
# macOS (Xenith and Lucifer laid out again on growing, shrinking and full
# screen). Needs the SDL GUI emulator: SKIP (77) on a headless build,
# so a CI job that builds only headless does not run it.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "wmsize_test: SKIP (no emu)"; exit 77; }
if command -v nm >/dev/null 2>&1; then
    syms=$(nm "$EMU" 2>/dev/null)
    if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
        echo "wmsize_test: SKIP (headless emulator)"; exit 77
    fi
fi

W=640
H=400
out=$(SDL_VIDEODRIVER=dummy with_timeout 30 "$EMU" -c0 -g${W}x${H} -r"$ROOT" /dis/sh.dis -c \
    "dd -bs 144 -count 1 -if '#i/draw/new' >[2] /dev/null; echo; dd -bs 49 -count 1 -if /dev/wmsize >[2] /dev/null; echo; echo halt > /dev/sysctl" 2>&1)

fail=0
# draw/new: client id, image id, chan, repl, then r and clipr
set -- $(printf '%s\n' "$out" | sed -n 1p)
if [ "$5 $6 $7 $8" = "0 0 $W $H" ]; then
    echo "PASS: the screen is the window, ${W}x${H}, not the display"
else
    echo "FAIL: screen rectangle is '$5 $6 $7 $8', want '0 0 $W $H'"; fail=1
fi
set -- $(printf '%s\n' "$out" | sed -n 2p)
if [ "$1 $2 $3" = "m $W $H" ]; then
    echo "PASS: /dev/wmsize reports ${W}x${H}"
else
    echo "FAIL: /dev/wmsize gave '$*', want 'm $W $H ...'"; fail=1
fi
[ $fail = 0 ] || { printf '%s\n' "$out" | sed 's/^/    /'; exit 1; }
exit 0
