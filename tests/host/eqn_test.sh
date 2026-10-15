#!/bin/sh
#
# eqn_test.sh — eqn(1), the equation preprocessor:
#
#	its output is Neateqn's: tests/eqn/eqn.out was made by Neateqn
#	from tests/eqn/eqn.ms (definitions, inline and displayed
#	equations, fractions, roots, limits, piles, matrices, brackets,
#	accents, fonts and sizes, mark and lineup, set, chartype,
#	breakcost, bracketsizes);
#	a token Neateqn would loop on forever ("right" out of place) is
#	reported and passed;
#	with -mbook and Libertinus Math (book(1) and /lib/troff/eqnrc),
#	tests/eqn/book.ms is set to PDF: a display's label on its
#	equation's baseline at the right; a sum in a display larger than
#	one inline, whose limits are beside it (TeX's text style), not
#	above and below; its bars (fractions, radicals, bar, under) drawn
#	as rectangles where the rule glyphs' ink would be (.rules), none
#	set as a glyph, so none copied with the text, the page drawn as
#	with the glyphs (within the ink where they overlap).

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "eqn_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/eqn.dis" ] && [ -f "$ROOT/dis/troff.dis" ] && [ -f "$ROOT/dis/tr2pdf.dis" ] ||
    { echo "eqn_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/eqn.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp tests/eqn/book.ms "$tmp/"
printf '.EQ\nx right y\n.EN\n' >"$tmp/stray.ms"

with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "eqn < /tests/eqn/eqn.ms > '#U*$tmp/eqn.out'; eqn < '#U*$tmp/stray.ms' > '#U*$tmp/stray.out' >[2] '#U*$tmp/stray.err'; cd '#U*$tmp'; book book.ms" \
    </dev/null >"$tmp/emu.log" 2>&1

if cmp -s "$tmp/eqn.out" tests/eqn/eqn.out; then
    echo "PASS: Neateqn's output"
else
    echo "FAIL: Neateqn's output:"
    diff tests/eqn/eqn.out "$tmp/eqn.out" | head -20 | sed 's/^/    /'
    fail=1
fi

if [ -s "$tmp/stray.out" ] && grep -q "out of place" "$tmp/stray.err"; then
    echo "PASS: an operator out of place is reported"
else
    echo "FAIL: an operator out of place: $(cat "$tmp/stray.err" 2>/dev/null)"
    fail=1
fi

if [ ! -s "$tmp/book.pdf" ]; then
    echo "FAIL: no PDF: $(grep -v fsqid "$tmp/emu.log" | head -5)"
    exit 1
fi
if ! command -v pdftotext >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo "eqn_test: SKIP the PDF's checks (no pdftotext or python3)"
    exit $fail
fi
pdftotext -bbox "$tmp/book.pdf" "$tmp/book.html"
python3 -I - "$tmp/book.html" <<'PY' || fail=1
import re, sys
words = [(float(a), float(b), float(c), float(d), w) for a, b, c, d, w in
         re.findall(r'<word xMin="([^"]*)" yMin="([^"]*)" xMax="([^"]*)" yMax="([^"]*)">([^<]*)</word>',
                    open(sys.argv[1], encoding='utf-8').read())]
fail = 0
def check(ok, what, why=''):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what + ('' if ok else ': ' + why))
    fail |= not ok
def find(w):
    return [x for x in words if x[4] == w]

# (1.1) is on the baseline of x = ..., at the right
lab = find('(1.1)')
eq = [x for x in find('x') if x[0] > 150]
check(lab and eq and abs(lab[0][3] - eq[0][3]) < 1.5 and lab[0][0] > eq[0][2] + 100,
      "a display's label on its baseline, at the right", '%s %s' % (lab, eq))

# the sums: displayed taller than inline; inline, its limits beside it
sums = sorted(find('∑'), key=lambda x: x[2] - x[0])
check(len(sums) == 2 and (sums[1][2] - sums[1][0]) > 1.5 * (sums[0][2] - sums[0][0]),
      'a displayed sum larger than an inline one', str(sums))
inl = sums[0] if sums else None
lim = [x for x in words if inl and x[4] in ('ni=1', 'n', 'i=1') and abs(x[1] - inl[1]) < 4]
check(inl and lim and lim[0][0] >= inl[2] - 0.5,
      "an inline sum's limits beside it", '%s %s' % (inl, lim))
sys.exit(fail)
PY

# the bars drawn, where the glyphs would be
{ cat lib/troff/eqnrc; printf '.ps 24\n.vs 40p\n.EQ\n{a + b} over {c + d} = sqrt {x sup 2 + 1} + x bar + y under + left ( {1 over 2} right )\n.EN\n'; } >"$tmp/bars.tr"
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; eqn < bars.tr | troff -mbook > bars.out; eqn < bars.tr | troff -mbook | tr2pdf > bars.pdf; { echo .rules 0; eqn < bars.tr } | troff -mbook | tr2pdf > glyphs.pdf" </dev/null >/dev/null 2>&1
if [ "$(grep -c '^DP' "$tmp/bars.out")" -ge 5 ] && ! grep -q 'uni23AF\|⎯\|^c_\|^Cul' "$tmp/bars.out"; then
    echo "PASS: eqn's bars drawn, not set as glyphs"
else
    echo "FAIL: eqn's bars: $(grep -c '^DP' "$tmp/bars.out") drawn"; fail=1
fi
if command -v pdftoppm >/dev/null 2>&1 && python3 -c 'import PIL, numpy' 2>/dev/null; then
    pdftoppm -r 300 -png -f 1 -l 1 "$tmp/bars.pdf" "$tmp/b"
    pdftoppm -r 300 -png -f 1 -l 1 "$tmp/glyphs.pdf" "$tmp/g"
    python3 -I - "$tmp"/b-1.png "$tmp"/g-1.png <<'PY' && echo "PASS: the bars where the glyphs were" || { echo "FAIL: the bars moved"; fail=1; }
import sys
import numpy as np
from PIL import Image
a = np.array(Image.open(sys.argv[1]).convert('L')) < 128
b = np.array(Image.open(sys.argv[2]).convert('L')) < 128
d = (a ^ b).sum()
print('%d of %d pixels of ink differ' % (d, b.sum()))
sys.exit(not (b.sum() > 10000 and d < 0.06 * b.sum()))
PY
fi
exit $fail
