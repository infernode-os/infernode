#!/bin/sh
#
# js_dom_test.sh — tests/js/pages/dom.html, the DOM a page's scripts see
# (lib/js/dom.js), loaded in a browsing session with its scripts on.  The
# page checks itself and sets its title to "PASS n" or "FAIL k n", and
# writes each failure to its console.  Among its checks: a page asking
# whether CSS animates is told no, since nothing does; Microsoft's sign-in
# waited forever for an animationend when it was told yes.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "js_dom_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/js/jspage.dis ] || { echo "js_dom_test: SKIP (tests not built)"; exit 77; }

out=$(SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m -g800x600 -r"$ROOT" /dis/sh.dis -c \
	"/dis/tests/js/jspage.dis -w 2000 file:///tests/js/pages/dom.html; echo halt > '#c/sysctl'" 2>&1)
title=$(echo "$out" | sed -n 's/^title: //p' | tail -1)
case "$title" in
"PASS "*)
	echo "PASS: dom.html, $title"
	exit 0 ;;
esac
echo "FAIL: dom.html, title '${title:-none}'"
echo "$out" | grep 'FAIL' | sed 's/^/    /'
[ -n "$title" ] || echo "$out" | tail -20 | sed 's/^/    /'
exit 1
