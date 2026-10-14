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
#	(pic stops there, as Plan 9's does);
#	a place not found, then used (B.ht, move to B), stops pic as that
#	error, where Plan 9's crashes;
#	1st circle asked for inside a [ ] still open is looked for there,
#	where Plan 9's went back to the open block for ever.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "pic_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/pic.dis" ] || { echo "pic_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pic.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '.PS\nbox\nline from Nowhere\n.PE\nafter\n' >"$tmp/err.ms"
printf '.PS\nx = B.ht\n.PE\n' >"$tmp/ht.ms"
printf '.PS\nmove to B\n.PE\n' >"$tmp/to.ms"
printf '.PS\narrow\nbox\n[\ncircle\nline from 1st circle.e right\n]\n.PE\n' >"$tmp/open.ms"

cat >"$tmp/run.sh" <<EOF
pic < /tests/pic/pic.ms > '#U*$tmp/pic.out'
pic < '#U*$tmp/err.ms' > '#U*$tmp/err.out' >[2] '#U*$tmp/err.err'
pic < '#U*$tmp/ht.ms' > '#U*$tmp/ht.out' >[2] '#U*$tmp/ht.err'
echo ht \$status >> '#U*$tmp/status'
pic < '#U*$tmp/to.ms' > '#U*$tmp/to.out' >[2] '#U*$tmp/to.err'
echo to \$status >> '#U*$tmp/status'
pic < '#U*$tmp/open.ms' > '#U*$tmp/open.out' >[2] '#U*$tmp/open.err'
echo open \$status >> '#U*$tmp/status'
EOF
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "#U*$tmp/run.sh" \
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
for f in ht to; do
    if grep -q "no such place as B" "$tmp/$f.err" 2>/dev/null && ! grep -q "nil\|Broken" "$tmp/$f.err" "$tmp/emu.log" &&
        grep -q "^$f ..*" "$tmp/status"; then
        echo "PASS: a place not found, then used ($f)"
    else
        echo "FAIL: a place not found, then used ($f): $(cat "$tmp/$f.err" 2>/dev/null | head -3)"
        fail=1
    fi
done

if grep -q '^\.PE' "$tmp/open.out" 2>/dev/null && grep -q "^open *$" "$tmp/status"; then
    echo "PASS: 1st circle inside an open block"
else
    echo "FAIL: 1st circle inside an open block: $(cat "$tmp/open.err" "$tmp/status" 2>/dev/null | head -3)"
    fail=1
fi
exit $fail
