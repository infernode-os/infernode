#!/bin/sh
#
# page_test.sh — wm/page (appl/wm/page.b) on a PDF of three pages, under
# wm/wm with the SDL dummy driver, driven by keys
# (tests/inferno/page_test.sh): the page shown written as an image on
# page 1, on page 2, and turned right.  The images are the pages as
# drawn: page 2 is not page 1, and turned it is as wide as it was tall.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/page.dis dis/wm/wm.dis dis/lib/sheetview.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

mkdir -p "$ROOT/tmp"
rm -f "$ROOT"/tmp/page-1.bit "$ROOT"/tmp/page-2.bit "$ROOT"/tmp/page-r.bit
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/inferno/page_test.sh" </dev/null >/dev/null 2>&1 || true

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }

# an Inferno image's size, from its header (after "compressed" if it
# is): chan x0 y0 x1 y1
size() {
	head -c 71 "$1" | sed '1{/^compressed$/d;}' | tr '\n' ' ' | awk '{ print $4 - $2 "x" $5 - $3 }'
}

for n in 1 2 r; do
	f="$ROOT/tmp/page-$n.bit"
	if [ -s "$f" ]; then ok "page written ($n): $(size "$f")"; else bad "no image written ($n)"; fi
done
p1="$ROOT/tmp/page-1.bit"
p2="$ROOT/tmp/page-2.bit"
pr="$ROOT/tmp/page-r.bit"
if [ -s "$p1" ] && [ -s "$p2" ]; then
	if cmp -s "$p1" "$p2"; then bad "page 2 is page 1 (n did not page on)"; else ok "n pages on: page 2 is not page 1"; fi
fi
if [ -s "$p2" ] && [ -s "$pr" ]; then
	w2=$(size "$p2" | cut -dx -f1); h2=$(size "$p2" | cut -dx -f2)
	wr=$(size "$pr" | cut -dx -f1); hr=$(size "$pr" | cut -dx -f2)
	if [ "$wr" -gt "$hr" ] && [ "$w2" -lt "$h2" ]; then
		ok "turned right, the page is wider than tall (${w2}x${h2} -> ${wr}x${hr})"
	else
		bad "turned: ${w2}x${h2} -> ${wr}x${hr}"
	fi
fi
rm -f "$p1" "$p2" "$pr"
if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
exit 1
