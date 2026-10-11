#!/bin/sh
#
# page_test.sh — wm/page (appl/wm/page.b) on a PDF of three pages, under
# wm/wm with the SDL dummy driver, driven by keys and the pointer
# (tests/page/drive.sh), which writes the page shown as an image at each
# step.  Pages are told apart by their images: page 1, 2 and 3 differ,
# and a step that should show page 2 writes page 2's image byte for byte.
# Scale and turning show in an image's size.  Covers paging (n, p, Home,
# End, go to, space), the wheel, a drag, the button-2 and button-3
# menus, fit, zoom, turning, two files read as one, standard input,
# quitting, and Markdown and HTML shown.
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
rm -f "$ROOT"/tmp/page-*.bit
LOG=$(mktemp)
trap 'rm -f "$LOG" "$ROOT"/tmp/page-*.bit' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 240 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/page/drive.sh" </dev/null >"$LOG" 2>&1 || true

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }

img() { echo "$ROOT/tmp/page-$1.bit"; }
# an Inferno image's size, from its header (after "compressed" if it
# is): chan x0 y0 x1 y1
size() {
	head -c 71 "$(img "$1")" | sed '1{/^compressed$/d;}' | tr '\n' ' ' | awk '{ print $4 - $2 " " $5 - $3 }'
}
width() { size "$1" | cut -d' ' -f1; }
height() { size "$1" | cut -d' ' -f2; }

for n in 1 n p end home g2 fw fp zin zout r rl l wheel drag space menu pages two-n3 two-p two-end stdin md html; do
	[ -s "$(img $n)" ] || bad "no image written at step $n"
done
[ $failed = 0 ] || { sed -n '/^R /!p' "$LOG" | head -20; exit 1; }
ok "an image written at every step"

# the three pages are three images
same() { cmp -s "$(img "$1")" "$(img "$2")"; }
if same 1 n || same n end || same 1 end; then
	bad "pages 1, 2 and 3 are not three images"
else
	ok "pages 1, 2 and 3 differ"
fi

# step, the step whose page it must show, what it is
shows() {
	if same "$1" "$2"; then ok "$3"; else bad "$3 (step $1 is not step $2's page)"; fi
}
shows p 1 "p: the page before"
shows home 1 "Home: the first page"
shows g2 n "go to page 2"
shows wheel n "the wheel scrolls on to page 2"
shows drag n "a drag with button 1 pans on to page 2"
shows space n "space twice: a screen on, to page 2"
shows menu n "the button-2 menu's next page"
shows pages end "the button-3 menu's page 3"
shows rl 1 "turned right and back: as it was"
shows zout fw "zoomed in and out: as it was"
shows two-n3 1 "two files: n past the first's last page is the second's first"
shows two-p end "two files: p from there is the first's last page"
shows two-end end "two files: End is the last page"
shows stdin 1 "standard input: the same page 1"

[ "$(width zin)" -gt "$(width fw)" ] && [ "$(height zin)" -gt "$(height fw)" ] &&
	ok "zoom in: larger ($(size fw) -> $(size zin))" || bad "zoom in: $(size fw) -> $(size zin)"
[ "$(height fp)" -lt "$(height fw)" ] &&
	ok "fit page is smaller than fit width ($(size fp), $(size fw))" || bad "fit page $(size fp), fit width $(size fw)"
for t in r l; do
	if [ "$(width $t)" = "$(height 1)" ] && [ "$(height $t)" = "$(width 1)" ]; then
		ok "turned ($t): $(size 1) -> $(size $t)"
	else
		bad "turned ($t): $(size 1) -> $(size $t)"
	fi
done
if same r l; then bad "turned right and turned left are the same image"; else ok "turned right and left differ"; fi

for t in md html; do
	if [ "$(width $t)" -gt 300 ] && [ "$(height $t)" -gt 20 ] && ! same $t 1; then
		ok "$t shown: $(size $t)"
	else
		bad "$t: $(size $t)"
	fi
done

if grep -q '^R quit *$' "$LOG"; then ok "q: the window is gone"; else bad "q: windows left: $(grep '^R quit' "$LOG")"; fi
grep -q '^R done' "$LOG" || bad "the driver did not finish"

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^R /!p' "$LOG" | head -20
exit 1
