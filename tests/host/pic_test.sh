#!/bin/sh
#
# pic_test.sh — pic(1), the picture preprocessor:
#
#	its output is Plan 9 pic's: tests/pic/pic.out was made by Plan 9's
#	pic (as Neatroff uses it) from tests/pic/pic.ms (boxes, circles,
#	ellipses, arcs, lines, arrows, splines; dashes, dots, fills,
#	chop, invis; corners, between, positions; blocks and their places;
#	variables, scale, for, if, define with arguments, sprintf; a .PS
#	line's size) — C's floats kept, its %g;
#	an error is reported as pic reports it, and the picture left out
#	(pic stops there, as Plan 9's does).

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "pic_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/pic.dis" ] || { echo "pic_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '.PS\nbox\nline from Nowhere\n.PE\nafter\n' >"$tmp/err.ms"

with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "pic < /tests/pic/pic.ms > '#U*$tmp/pic.out'; pic < '#U*$tmp/err.ms' > '#U*$tmp/err.out' >[2] '#U*$tmp/err.err'" \
    </dev/null >"$tmp/emu.log" 2>&1

if cmp -s "$tmp/pic.out" tests/pic/pic.out; then
    echo "PASS: Plan 9 pic's output"
else
    echo "FAIL: Plan 9 pic's output:"
    diff tests/pic/pic.out "$tmp/pic.out" | head -20 | sed 's/^/    /'
    fail=1
fi

if grep -q "no such place as Nowhere" "$tmp/err.err" 2>/dev/null &&
    ! grep -q '^\.PS' "$tmp/err.out"; then
    echo "PASS: an error reported, the picture left out"
else
    echo "FAIL: an error: $(cat "$tmp/err.err" 2>/dev/null | head -3)"
    fail=1
fi
exit $fail
