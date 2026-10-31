#!/bin/sh
#
# wm_edit_test.sh — wm/edit (appl/wm/edit.b), Inferno's own editor,
# under wm/wm, driven by the pointer and keys (tests/edit/drive.sh): it
# opens at a size that shows it on the theme's background (upstream's
# was white, under the theme's light text), reading a file with the
# arrow and page keys leaves it unchanged (Exit does not ask), text typed
# and saved is the file with it added and nothing more, a name that does
# not exist is a new file written by Save, and text not saved makes Exit
# ask.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/edit.dis dis/wm/wm.dis dis/lib/dialog.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/wm_edit_test.$$
D="$ROOT/$T"
mkdir -p "$D"
LOG=$(mktemp)
trap 'rm -f "$LOG"; rm -rf "$D"' EXIT
printf 'line one\nline two\n' > "$D/read.txt"
printf 'line one\nline two\n' > "$D/save.txt"
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/edit/drive.sh /$T" </dev/null >"$LOG" 2>&1 || true

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }
windows() { sed -n "s/^R $1 *//p" "$LOG" | head -1; }
reached() { grep -q "^R $1\( \|\$\)" "$LOG"; }

if ! reached done; then
	bad "the drive did not finish"
	cat "$LOG"
	exit 1
fi

# id minx miny maxx maxy: wider and taller than its frame, as
# wm_size_test asks of every program
set -- $(windows open) 0 0 0 0 0
dx=$(($4 - $2)) dy=$(($5 - $3))
if [ "$dx" -ge 300 ] && [ "$dy" -ge 200 ]; then
	ok "opens at ${dx}x${dy}"
else
	bad "opens at ${dx}x${dy}, too small to edit in"
fi

# the text's background, two thirds of the way into the window (below
# the text and the menu): the theme's, not white
px=$(python3 -I - "$D/open.img" $(($2 + dx * 2 / 3)) $(($3 + dy * 2 / 3)) <<'PY'
import sys
sys.path.insert(0, 'tools')
import p9img2png
im = p9img2png.load(sys.argv[1])
print(im.px(int(sys.argv[2]), int(sys.argv[3])))
PY
)
if [ "$px" = FFFFFF ]; then
	bad "the text's background is white, not the theme's"
else
	ok "the text's background is the theme's ($px)"
fi

[ -z "$(windows read-exit)" ] \
	&& ok "read with the arrow and page keys, Exit leaves without asking" \
	|| bad "Exit after only moving asked (windows: $(windows read-exit)): the keys marked it changed"

if [ "$(cat "$D/save.txt")" = "$(printf 'line one\nline two\nadded')" ]; then
	ok "saved: the file with the typed text added and nothing more"
else
	bad "saved file is '$(od -c "$D/save.txt" | head -3)'"
fi
[ -z "$(windows saved-exit)" ] \
	&& ok "Exit after Save leaves without asking" \
	|| bad "Exit after Save asked (windows: $(windows saved-exit))"

if [ -f "$D/new.txt" ] && [ "$(cat "$D/new.txt")" = "brand new" ]; then
	ok "a name that did not exist: a new file, written by Save"
else
	bad "new.txt not written as typed"
fi

# the dialog asking, over the editor: two windows
set -- $(windows dirty-exit)
if [ $# -ge 10 ]; then
	ok "Exit with text not saved asks"
else
	bad "Exit with text not saved did not ask (windows: $*)"
fi
[ "$(cat "$D/read.txt")" = "$(printf 'line one\nline two')" ] \
	&& ok "the file not saved is unchanged" \
	|| bad "read.txt changed: '$(cat "$D/read.txt")'"

exit $failed
