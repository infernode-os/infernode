#!/bin/sh
#
# tbl_test.sh — tbl(1), the table preprocessor:
#
#	its output is Plan 9 tbl's: tests/tbl/tbl.out was made by Plan 9's
#	tbl (as Neatroff uses it) from tests/tbl/tbl.ms (boxed, all-boxed,
#	double-boxed and expanded tables, spans across and down, fonts,
#	sizes and widths, text blocks, numbers aligned, alphabetic
#	columns, \R, .T&, rules, eqn's delimiters);
#	a table whose one line spans down (\^), on which Plan 9's tbl
#	loops for ever, is set;
#	under -mbook, a table's rules are drawn as lines (.rules), not as
#	glyphs set side by side;
#	a line outside a table, and one in a text block, longer than C's
#	buffers (5120 and 4096 bytes) is passed on whole, not cut in two
#	with a word.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "tbl_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/tbl.dis" ] && [ -f "$ROOT/dis/troff.dis" ] ||
    { echo "tbl_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tbl.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '.TS\nl.\n\\^\n.TE\n' >"$tmp/span.ms"
printf '.TS\nbox;\nl | l.\na\tb\n.TE\n' >"$tmp/box.ms"
long=$(awk 'BEGIN { for (i = 0; i < 1500; i++) printf "w%04d ", i }')
printf '%s\n.TS\nl.\nT{\n%s\nT}\n.TE\n' "$long" "$long" >"$tmp/long.ms"

with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "tbl < /tests/tbl/tbl.ms > '#U*$tmp/tbl.out'; tbl < '#U*$tmp/span.ms' > '#U*$tmp/span.out'; tbl < '#U*$tmp/box.ms' | troff -mbook > '#U*$tmp/box.tr'; tbl < '#U*$tmp/long.ms' > '#U*$tmp/long.out'" \
    </dev/null >"$tmp/emu.log" 2>&1

if cmp -s "$tmp/tbl.out" tests/tbl/tbl.out; then
    echo "PASS: Plan 9 tbl's output"
else
    echo "FAIL: Plan 9 tbl's output:"
    diff tests/tbl/tbl.out "$tmp/tbl.out" | head -20 | sed 's/^/    /'
    fail=1
fi

if grep -q '^\.TE' "$tmp/span.out" 2>/dev/null; then
    echo "PASS: a table of one line spanning down is set"
else
    echo "FAIL: a table of one line spanning down: $(head -c 200 "$tmp/span.out" 2>/dev/null)"
    fail=1
fi

# rules as lines: troff's output draws (D) and sets no underscore or bar
if grep -q '^D' "$tmp/box.tr" 2>/dev/null && ! grep -q '^c_' "$tmp/box.tr"; then
    echo "PASS: rules drawn as lines under -mbook"
else
    echo "FAIL: rules drawn as lines: $(grep -c '^D' "$tmp/box.tr" 2>/dev/null) lines drawn"
    fail=1
fi
if [ "$(grep -c "^$long\$" "$tmp/long.out" 2>/dev/null)" = 2 ]; then
    echo "PASS: long lines passed on whole"
else
    echo "FAIL: long lines: $(awk '{ print length($0) }' "$tmp/long.out" 2>/dev/null | sort -rn | head -3 | tr '\n' ' ')"
    fail=1
fi
exit $fail
