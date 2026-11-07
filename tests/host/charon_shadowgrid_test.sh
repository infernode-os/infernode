#!/bin/sh
#
# charon_shadowgrid_test.sh — a web component laid out as a grid, as
# JSTOR's home page is (Pharos's layout: <slot name="top"> at the top of
# its shadow tree, the page's style sheet naming the grid's areas).  An
# element at the top of a shadow tree is not the root: the slot is
# display: contents, so what is slotted in it takes the areas the page
# names, and :root in the shadow tree's sheet matches nothing.  A grid
# item that scrolls (the hero slider, overflow: hidden, its slides
# 35000px wide) has no automatic minimum, though it spans tracks with
# fixed minimums: the grid is laid out the window's width.  JSTOR's
# heading, search box and hero were in one cell 144px wide, then the page
# 35000px wide.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "charon_shadowgrid_test: SKIP (no emu)"; exit 77; }

mkdir -p "$ROOT/tmp"
trap 'rm -f "$ROOT/tmp/charon_shadowgrid.sh" "$ROOT/tmp/charon_shadowgrid.html"' EXIT
cat >"$ROOT/tmp/charon_shadowgrid.html" <<'HTML'
<!doctype html>
<html><head><title>start</title>
<style>
body { margin: 0 }
x-layout.home { grid-template-areas: ". heading ." "hero hero hero" ". content ."; }
.h { grid-area: heading; width: 300px; margin: auto; height: 20px }
.hero { grid-area: hero; width: 100%; height: 20px; overflow: hidden }
.c { height: 20px }
</style></head><body>
<x-layout class="home"><div class="h" slot="top">H</div><section class="hero" slot="top"><ul style="display: flex; width: 35000px; margin: 0; padding: 0"><li style="width: 1000px">HERO</li></ul></section><div class="c">C</div></x-layout>
<script>
customElements.define('x-layout', class extends HTMLElement {
	constructor() {
		super();
		this.attachShadow({mode: 'open'}).innerHTML =
			'<style>:host { display: grid; grid-template-areas: ". content ."; grid-template-columns: minmax(50px, 100px) auto minmax(50px, 100px) }' +
			' .layout { grid-area: content; display: grid; width: 500px } :root { display: block; width: 7px }</style>' +
			'<slot name="top"></slot><div class="layout"><slot></slot></div>';
	}
});
document.title = 'ready';
</script>
</body></html>
HTML
cat >"$ROOT/tmp/charon_shadowgrid.sh" <<'SH'
load std
wm/charon -h about:blank &
for i in 1 2 3 4 5 6 7 8 9 10 { if {! ftest -e '#scharon/fs'} { sleep 1 } }
mkdir -p /n/charonsg
mount -A '#scharon/fs' /n/charonsg
echo scripts on > /n/charonsg/ctl
echo size 1000x600 > /n/charonsg/ctl
echo open file:///tmp/charon_shadowgrid.html > /n/charonsg/ctl
for i in 1 2 3 4 5 6 7 8 9 10 { if {! grep -s ready /n/charonsg/title} { sleep 1 } }
sleep 1
for d in /n/charonsg/dom/* {
	t=`{cat $d/tag}
	if {~ $t x-layout div section slot} { echo R_BOX $t `{grep '^class ' $d/attrs} '=>' `{cat $d/box} }
	if {~ $t slot} { echo R_SLOT `{grep '^display ' $d/style} }
}
SH
out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -g1000x600 -r"$ROOT" /dis/sh.dis -c \
	"sh /tmp/charon_shadowgrid.sh; echo halt > '#c/sysctl'" 2>&1)

failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
box() { echo "$out" | sed -n "s/^R_BOX $1 => //p" | head -1; }
slots=$(echo "$out" | sed -n 's/^R_SLOT //p' | sort -u)
if [ "$slots" = "display contents" ]; then
	pass "a slot at the top of a shadow tree is display: contents"
else
	fail "the slots: '$slots'"
fi
got=$(box 'div class h')
if [ "$got" = "block 350 0 300 20" ]; then
	pass "what is slotted takes the grid area the page names (the heading centred)"
else
	fail "the heading: '$got'"
fi
got=$(box 'section class hero')
if [ "$got" = "block 0 20 1000 20" ]; then
	pass "a grid item that scrolls spans the window, not its 35000px content"
else
	fail "the hero: '$got'"
fi
got=$(box 'div class c')
if [ "$got" = "block 100 40 500 20" ]; then
	pass "the content area is between the margins"
else
	fail "the content: '$got'"
fi
[ $failed = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$out" | grep '^R_' >&2
exit 1
