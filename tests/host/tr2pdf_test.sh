#!/bin/sh
#
# tr2pdf_test.sh — tr2pdf(1), troff's output as PDF.
#
#	a document is a PDF whose cross-reference table finds each of its
#	objects; its OpenType (CFF) fonts are embedded as OpenType
#	(FontFile3), compressed, each with a ToUnicode map;
#	poppler, where there is one, reads it without complaint and finds
#	its text, Greek and ligatures (fi) included;
#	x X papersize gives the page its size;
#	a PDF included (x X pdf) is an XObject; Neatpost loops for ever on
#	one whose page list has two pages ([3 0 R 4 0 R]: it read the
#	revision as 4) and on a keyword (true) in a dictionary;
#	-c writes as Neatpost does (no compression, the font in hex);
#	its OpenType (CFF) fonts subset to the glyphs used (tagged ABCDEF+,
#	glyphs not used and the subroutines only they call emptied, the
#	layout tables left out): every page drawn as with the fonts whole
#	(-W), pixel for pixel, its text the same, the file a third the size
#	or less (the fallback's TrueType too, DejaVu Sans, by glyf and loca);
#	where fontTools is installed, each subset font read, every glyph
#	kept its own charstring and every glyph drawn;
#	output with no device (x T, x res) before its first page is refused
#	with a reason, where it divided by zero.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "tr2pdf_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/tr2pdf.dis" ] || { echo "tr2pdf_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tr2pdf.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

inferno() {
    with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "$1" </dev/null 2>"$tmp/err"
}

pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

printf '\\X'"'"'papersize 595x842'"'"'\n.ps 14\nThe first office: \\fIμῆνιν ἄειδε θεά\\fP, ἀρετή.\n' >"$tmp/doc.tr"
inferno "cd '#U*$tmp'; troff doc.tr | tr2pdf >doc.pdf"
pdf=$tmp/doc.pdf
if [ ! -s "$pdf" ]; then
    failed "no PDF: $(cat "$tmp/err")"
    exit 1
fi

# the cross-reference table finds every object
if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$pdf" <<'PY' && pass "the xref table finds every object" || failed "xref: see above"
import re, sys
d = open(sys.argv[1], 'rb').read()
x = int(d[d.rindex(b'startxref') + 9:].split()[0])
assert d[x:x+4] == b'xref', 'startxref does not point at xref'
lines = d[x:].split(b'\n')
n = int(lines[1].split()[1])
for i in range(1, n):
    off = int(lines[2 + i][:10])
    assert d[off:].startswith(b'%d 0 obj' % i), 'object %d not at %d' % (i, off)
PY
fi

LC_ALL=C grep -aq '/FontFile3' "$pdf" && LC_ALL=C grep -aq '/Subtype /OpenType' "$pdf" &&
    LC_ALL=C grep -aq '/Subtype /CIDFontType0' "$pdf" &&
    pass "the CFF font is embedded as OpenType" || failed "font embedding"
LC_ALL=C grep -aq '/ToUnicode' "$pdf" && LC_ALL=C grep -aq '/FlateDecode' "$pdf" &&
    pass "compressed, with a ToUnicode map" || failed "no ToUnicode or compression"
LC_ALL=C grep -aq 'MediaBox \[ 0 0 595 842 \]' "$pdf" &&
    pass "x X papersize sets the page" || failed "papersize: $(LC_ALL=C grep -a MediaBox "$pdf")"

if command -v pdftotext >/dev/null 2>&1; then
    txt=$(pdftotext "$pdf" - 2>"$tmp/poppler")
    case "$txt" in
    *"The first office: μῆνιν ἄειδε θεά, ἀρετή."*)
        [ -s "$tmp/poppler" ] && failed "poppler complains: $(head -3 "$tmp/poppler")" ||
            pass "poppler finds the text, Greek and ligatures" ;;
    *)
        failed "poppler's text: $txt" ;;
    esac
else
    echo "SKIP: no pdftotext"
fi

# fonts subset to the glyphs used: a page of text, italic, bold, Greek
# and mathematics (Libertinus Math), set as with the fonts whole
{ cat lib/troff/eqnrc; printf '.EQ\ndelim $$\n.EN\n.ps 12\nRoman \\fIitalic\\fP \\fBbold\\fP: ἀρετή, λόγος, φιλοσοφία; fi ffl.\n.br\nIts sum $sum from {i=1} to n x sub i sup 2$ and root $sqrt {a + b}$; done ✓.\n'; } >"$tmp/sub.tr"
inferno "cd '#U*$tmp'; eqn < sub.tr | troff -mbook | tr2pdf > sub.pdf; eqn < sub.tr | troff -mbook | tr2pdf -W > whole.pdf"
if [ -s "$tmp/sub.pdf" ] && [ -s "$tmp/whole.pdf" ]; then
    ns=$(LC_ALL=C grep -aoc '/FontName /[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z]+' "$tmp/sub.pdf")
    ss=$(wc -c <"$tmp/sub.pdf"); sw=$(wc -c <"$tmp/whole.pdf")
    LC_ALL=C grep -aq '/FontName /[A-Z]\{6\}+DejaVuSans' "$tmp/sub.pdf" || ns=0
    [ "$ns" -ge 4 ] && [ $((ss * 3)) -lt "$sw" ] &&
        pass "fonts subset ($ns fonts tagged; $ss bytes, $sw whole)" || failed "subset: $ns tagged, $ss bytes, $sw whole"
    if command -v pdftoppm >/dev/null 2>&1; then
        pdftoppm -r 150 "$tmp/sub.pdf" "$tmp/ps" 2>/dev/null
        pdftoppm -r 150 "$tmp/whole.pdf" "$tmp/pw" 2>/dev/null
        same=1
        for f in "$tmp"/ps*.ppm; do cmp -s "$f" "$tmp/pw${f#$tmp/ps}" || same=0; done
        [ -n "$(ls "$tmp"/ps*.ppm 2>/dev/null)" ] && [ $same = 1 ] &&
            [ "$(pdftotext "$tmp/sub.pdf" - 2>&1)" = "$(pdftotext "$tmp/whole.pdf" - 2>&1)" ] &&
            pass "a subset font draws the page as the whole one, and its text is the same" ||
            failed "subset fonts draw or read otherwise"
    fi
    if python3 -c 'import fontTools' 2>/dev/null; then
        python3 -I - "$tmp/sub.pdf" "$ROOT/fonts/libertinus" <<'PY' && pass "each subset font read, its glyphs the original's, every one drawn" || failed "a subset font: see above"
import io, re, sys, zlib
from fontTools.ttLib import TTFont
from fontTools.pens.boundsPen import BoundsPen
d = open(sys.argv[1], 'rb').read()
n = 0
for m in re.finditer(rb'<<([^>]*?/Subtype /OpenType[^>]*?)>>\s*stream\n', d):
    ln = int(re.search(rb'/Length (\d+)', m.group(1)).group(1))
    f = TTFont(io.BytesIO(zlib.decompress(d[m.end():m.end() + ln])))
    cff = f['CFF '].cff
    name = cff.fontNames[0]
    orig = TTFont(sys.argv[2] + '/' + name + '.otf')['CFF '].cff[name].CharStrings
    cs = cff[name].CharStrings
    kept = 0
    for g in cs.keys():
        c = cs[g]
        c.compile()
        if c.bytecode != b'\x0e':
            kept += 1
            o = orig[g]
            o.compile()
            assert c.bytecode == o.bytecode, '%s: %s differs' % (name, g)
        c.draw(BoundsPen(cs))
    assert 0 < kept < len(cs) / 2, '%s: %d of %d glyphs kept' % (name, kept, len(cs))
    n += 1
assert n >= 3, '%d fonts' % n
PY
    fi
else
    failed "subset: no PDFs: $(cat "$tmp/err")"
fi

# an included PDF; these two looped Neatpost for ever
printf '%%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R /Resources << /ProcSet [/PDF] /Properties << /P0 << /Hidden true >> >> >> >>\nendobj\n4 0 obj\n<< /Length 18 >>\nstream\n0 0 1 rg 0 0 50 50 re f\nendstream\nendobj\n5 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>\nendobj\n' >"$tmp/fig.pdf"
off() { LC_ALL=C grep -abo "^$1 0 obj" "$tmp/fig.pdf" | cut -d: -f1; }
x=$(wc -c <"$tmp/fig.pdf")
{ printf 'xref\n0 6\n0000000000 65535 f \n'; for i in 1 2 3 4 5; do printf '%010d 00000 n \n' "$(off $i)"; done
  printf 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$x"; } >>"$tmp/fig.pdf"
printf 'Before.\n.sp 1i\n\\X'"'"'pdf fig.pdf 7200'"'"'\n.br\nAfter.\n' >"$tmp/fig.tr"
inferno "cd '#U*$tmp'; troff fig.tr | tr2pdf >figdoc.pdf"
if [ -s "$tmp/figdoc.pdf" ] && LC_ALL=C grep -aq '/Subtype /Form' "$tmp/figdoc.pdf" &&
        LC_ALL=C grep -aq '/XObject << /FO0' "$tmp/figdoc.pdf"; then
    pass "an included PDF is an XObject (two pages, a keyword)"
else
    failed "inclusion: $(cat "$tmp/err")"
fi

# -c: as Neatpost
inferno "cd '#U*$tmp'; troff doc.tr | tr2pdf -c >compat.pdf"
LC_ALL=C grep -aq '/FontFile2' "$tmp/compat.pdf" && LC_ALL=C grep -aq '/ASCIIHexDecode' "$tmp/compat.pdf" &&
    ! LC_ALL=C grep -aq '/FlateDecode' "$tmp/compat.pdf" &&
    pass "-c writes as Neatpost" || failed "-c"

# no device: said, and failed
printf 'p1\nDl 100 100\n' >"$tmp/nodev.tr"
inferno "cd '#U*$tmp'; tr2pdf <nodev.tr >nodev.pdf >[2]nodev.err" >/dev/null
if grep -q 'no device' "$tmp/nodev.err" 2>/dev/null; then
    pass "output with no device is refused"
else
    failed "no device: $(cat "$tmp/nodev.err" "$tmp/err")"
fi

exit $fail
