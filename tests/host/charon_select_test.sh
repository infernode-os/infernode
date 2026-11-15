#!/bin/sh
#
# charon_select_test.sh — selecting, copying and pasting in Charon's
# window (wm/charon under wm/wm), by the pointer and keys
# (tests/charon/select/drive.sh on tests/charon/select/page.html): a
# click on text copies nothing, a drag along a line and a double-click
# on a word copy them with Ctrl-C, Ctrl-A selects the page, Ctrl-V in a
# text field types the snarf buffer, and the drag's selection is drawn
# (light blue over the text, by pixel); Tab from the page goes to the
# field, and + zooms the page (by pixel) and 0 puts it back.  Charon had no selection: a
# drag did nothing and Ctrl-C copied nothing.  Tk sends button 1's press
# again with each motion while it is held, which restarted the drag.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/charon.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/charon_select_test.$$
W="$ROOT/$T"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/charon/select/drive.sh /$T" > "$W/log" 2>&1 < /dev/null
grep -q '^R done' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -10; exit 1; }

fail=0
check() {	# step, what is wanted, what it is
	got=$(sed -n "s/^R $1 \[\(.*\)\]\$/\1/p" "$W/log")
	if [ "$got" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3: got '$got', want '$2'"; fail=1; fi
}
check click "start" "a click on text copies nothing"
check drag "Supercalifragilistic bravo charlie" "a drag along a line copies it"
check word "Supercalifragilistic" "a double-click copies the word"
check all "Supercalifragilistic bravo charlie" "Ctrl-A selects the page"
if grep -q '^0 16 text q pasted words$' "$W/log"; then
	echo "PASS: Ctrl-V pastes into a text field"
else
	echo "FAIL: Ctrl-V in a text field:"; sed -n '/^R field/,/^R done/p' "$W/log"; fail=1
fi

if grep -q '^0 16 text q pasted words tabbed$' "$W/log"; then
	echo "PASS: Tab goes from the page to the text field"
else
	echo "FAIL: Tab to the text field:"; sed -n '/^R tab/,/^R done/p' "$W/log"; fail=1
fi

# at 200% the line's text reaches past x 420 (at 100% it ends near 264):
# dark pixels there zoomed, none once back at 0
dark() {
	python3 - "$ROOT/tools" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
im = load(sys.argv[2])
m = 0
for y in range(300, 372):
	for x in range(430, 520):
		p = ((y - im.r[1]) * im.w + x - im.r[0]) * 3
		if im.rgb[p] < 100 and im.rgb[p+1] < 100 and im.rgb[p+2] < 100:
			m += 1
print(m)
PY
}
if [ -f "$W/zoom.img" ] && [ -f "$W/unzoom.img" ]; then
	z=$(dark "$W/zoom.img"); u=$(dark "$W/unzoom.img")
	if [ "${z:-0}" -gt 200 ] && [ "${u:-1}" -eq 0 ]; then
		echo "PASS: + zooms the page and 0 puts it back ($z dark pixels zoomed, $u after)"
	else
		echo "FAIL: zoom: $z dark pixels zoomed, $u after"; fail=1
	fi
else
	echo "FAIL: zoom: no screens captured"; fail=1
fi

if [ -f "$W/drag.img" ]; then
	n=$(python3 - "$ROOT/tools" "$W/drag.img" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
im = load(sys.argv[2])
# the line's text, about (4, 172) to (264, 192) on the screen
m = 0
for y in range(172, 193):
	for x in range(4, 260):
		p = ((y - im.r[1]) * im.w + x - im.r[0]) * 3
		r, b = im.rgb[p], im.rgb[p+2]
		if 150 < r < 210 and b > r + 20:
			m += 1
print(m)
PY
)
	if [ "${n:-0}" -gt 2000 ]; then echo "PASS: the selection is drawn ($n light blue pixels)"; else echo "FAIL: the selection is not drawn ($n light blue pixels)"; fail=1; fi
else
	echo "FAIL: no screen captured"; fail=1
fi
[ $fail = 0 ] && echo "ALL PASS"
exit $fail
