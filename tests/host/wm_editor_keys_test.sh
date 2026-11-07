#!/bin/sh
#
# wm_editor_keys_test.sh — wm/editor (appl/wm/editor.b) under wm/wm
# with the SDL dummy driver, typed at through /dev/keyboard
# (tests/editor/keys.sh): the arrow keys and End move the caret, and
# keys that are not characters (F1, Insert, Page Up and Down) type
# nothing.  They were X11 keysyms in the editor, which keyboard.h's
# keys never matched, so each was typed as a private-use glyph.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/editor.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/wm_editor_keys_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/editor/keys.sh" \
	</dev/null >"$LOG" 2>&1 || true

grep -q '^R done' "$LOG" || { echo "FAIL: the driver did not finish"; tail -20 "$LOG"; exit 1; }
body=$(cat "$ROOT/$T/body" 2>/dev/null || true)
if [ "$body" = abcde ]; then
	echo "PASS: the arrow keys and End move the caret, F1, Insert and the page keys type nothing"
	echo "wm_editor_keys_test: PASS"
else
	echo "FAIL: the document is not abcde: $(printf '%s' "$body" | od -c | head -3)"
	exit 1
fi
