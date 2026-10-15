#!/bin/sh
#
# book2tex_test.sh — book2tex(1), a book written with -mbook as LaTeX:
#
#	tests/book/book.ms: the title page, front, main and back matter,
#	chapters (numbered, and not), sections and their labels, an
#	epigraph and its source, quotations, footnotes (their marks after
#	the text a \c ends), endnotes by chapter (each chapter's heading
#	before its first), references, citations as biblatex-chicago's
#	(\autocite, \autocites, page ranges with en dashes), the notes and
#	the bibliography; every brace and environment closed;
#	tests/book/latex.ms: equations (eqn's sub, sup, over, sqrt,
#	from and to, matrix, pile, left and right, accents, fonts, a
#	numbered display; inline between delim's), tables (spans, boxes,
#	a text block), a picture drawn as a PDF of its own, the size of
#	the picture, .nf and .ce, strings, the index (makeindex's entries,
#	sort keys and formats), LaTeX's special characters escaped, troff's
#	characters by name;
#	where LuaLaTeX is installed (with biblatex-chicago, epigraph,
#	endnotes and imakeidx), both are set without an error: the book
#	with biber, its citations found, its text where it should be.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "book2tex_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/book2tex.dis" ] || { echo "book2tex_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/book2tex.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS: $1"; }
failed() { echo "FAIL: $1"; fail=1; }

cp tests/book/book.ms tests/book/works.bib tests/book/latex.ms "$tmp/"
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; book2tex -p works.bib -o book.tex book.ms >[2]book.err; book2tex -o latex.tex latex.ms >[2]latex.err" </dev/null >/dev/null 2>&1
if [ ! -s "$tmp/book.tex" ] || [ ! -s "$tmp/latex.tex" ]; then
    failed "no LaTeX: $(cat "$tmp"/*.err)"
    exit 1
fi
[ -s "$tmp/book.err" ] && failed "book.ms said: $(cat "$tmp/book.err")"

# each line wanted is in the LaTeX
want() {
    f=$1; shift
    miss=""
    for w in "$@"; do
        grep -qF -- "$w" "$tmp/$f" || miss="$miss
    $w"
    done
    [ -z "$miss" ] && return 0
    echo "missing from $f:$miss"
    return 1
}

want book.tex '\title{A Study of Virtue\\[1ex]\large Justice and the Soul in Plato and Aristotle}' \
    '\maketitle' '\frontmatter' '\tableofcontents' '\chapter*{Preface}' \
    '\addcontentsline{toc}{chapter}{Preface}' '\mainmatter' '\chapter{On Virtue}' '\label{ch1}' \
    '\section{The Argument of the Good}' '\label{sec1-1}' \
    '\epigraph{Πάντες ἄνθρωποι τοῦ εἰδέναι ὀρέγονται φύσει.}{---~Aristotle, \emph{Metaphysics} 980a21}' \
    'The word \emph{ἀρετή} matters here.\footnote{A note of my own, about ἀρετή and its translation as ``virtue'"''"'; see chapter \ref{ch2} on page \pageref{ch2}.}' \
    'next time with.\autocite[315--16]{smith-swing}' '\autocites[12]{grazer}[177--178]{thoreau}' \
    'Another claim\endnotemark{}\addtoendnotes{' '\textit{Chapter 1: On Virtue}' \
    '\endnotetext{An endnote on the claim, with Greek: μῆνιν ἄειδε θεά.}' \
    '\begin{quotation}' '\backmatter' '\theendnotes' '\printbibliography[heading=bibintoc]' \
    '\usepackage[notes,backend=biber]{biblatex-chicago}' '\addbibresource{works.bib}' \
    '\usepackage{endnotes}' '\usepackage{epigraph}' '\setmathfont{Libertinus Math}' \
    '\usepackage[paperwidth=6in,paperheight=9in,' &&
    pass "the book's macros as LaTeX's" || failed "the book's macros"
[ "$(grep -c 'addtoendnotes' "$tmp/book.tex")" = 3 ] &&
    pass "endnotes' headings, one a chapter" || failed "endnotes' headings: $(grep -c addtoendnotes "$tmp/book.tex")"

want latex.tex 'Inline $x^{2} + y_{i}^{2}$ and $\frac{\alpha}{\beta}$ and $\sqrt{{a+b}}$.\index{mathematics!inline}Here.\index{aretē@\emph{ἀρετή}|textbf}' \
    '\sum_{i=1}^{n} x_{i} = \int\limits_{0}^{\infty} e^{{{-x}^{2}}} dx \tag{1.1}' \
    '\left( \begin{array}{cr}a & c \\ b & d\end{array} \right) \ \ \lim_{{x \to 0}} \frac{{\sin x}}{x} = 1' \
    '\overline{x} + \vec{y} + {\textrm{max}} - \symbf{X} + \left[ \begin{array}{c}1 \\ 2\end{array} \right] + a \le b \ne c' \
    '\begin{tabular}{|lr|}' '\multicolumn{2}{|c|}{Heading} \\' 'Plato & 347 \\' \
    '\begin{tabular}{|l|p{0.40\linewidth}|}' '\textbf{One} & A text block of some length that should wrap inside its cell. \\ \hline' \
    '\includegraphics{latex-pic1}' 'A poem'"'"'s line\newline' '\begin{center}' 'Centred' \
    'Done: 50\% \& \$5 \#1 \textasciitilde{} \textasciicircum{} a\_b \{c\} \textbackslash{} -{}- --- ``quoted'"''"'.' \
    'Hello Plato.' '\printindex' '\usepackage{imakeidx}' '\usepackage{graphicx}' &&
    pass "equations, tables, a picture, the index, characters" || failed "latex.ms"

# the picture: a PDF its size
if command -v pdfinfo >/dev/null 2>&1; then
    sz=$(pdfinfo "$tmp/latex-pic1.pdf" 2>/dev/null | sed -n 's/^Page size: *\([0-9.]*\) x \([0-9.]*\) pts.*/\1 \2/p')
    [ "$sz" = "129 39" ] && pass "the picture a PDF its size" || failed "the picture: $sz"
fi

# braces and environments closed
if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$tmp/book.tex" "$tmp/latex.tex" <<'PY' && pass "every brace and environment closed" || failed "unbalanced: see above"
import re, sys
for f in sys.argv[1:]:
    t = re.sub(r'\\[{}%]', '', open(f).read())
    t = '\n'.join(l for l in t.split('\n') if not l.startswith('%'))
    d = 0
    for c in t:
        d += {'{': 1, '}': -1}.get(c, 0)
        assert d >= 0, f + ': } before its {'
    assert d == 0, '%s: %d { open' % (f, d)
    st = []
    for m in re.finditer(r'\\(begin|end)\{([^}]*)\}', t):
        if m.group(1) == 'begin':
            st.append(m.group(2))
        else:
            assert st and st.pop() == m.group(2), f + ': \\end{%s}' % m.group(2)
    assert not st, f + ': ' + ' '.join(st) + ' open'
PY
fi

# set by LuaLaTeX, where there is one with what the book uses
if command -v lualatex >/dev/null 2>&1 && command -v biber >/dev/null 2>&1 &&
        kpsewhich biblatex-chicago.sty epigraph.sty endnotes.sty imakeidx.sty >/dev/null 2>&1 &&
        [ "$(kpsewhich biblatex-chicago.sty epigraph.sty endnotes.sty imakeidx.sty | wc -l)" = 4 ]; then
    export OSFONTDIR="$ROOT/fonts/libertinus"
    (
        cd "$tmp" || exit 1
        lualatex -interaction=nonstopmode -halt-on-error book.tex >/dev/null 2>&1 &&
            biber book >/dev/null 2>&1 &&
            lualatex -interaction=nonstopmode -halt-on-error book.tex >/dev/null 2>&1 &&
            lualatex -interaction=nonstopmode -halt-on-error book.tex >/dev/null 2>&1 &&
            lualatex -interaction=nonstopmode -halt-on-error latex.tex >/dev/null 2>&1 &&
            makeindex latex >/dev/null 2>&1 &&
            lualatex -interaction=nonstopmode -halt-on-error latex.tex >/dev/null 2>&1
    )
    if [ -s "$tmp/book.pdf" ] && [ -s "$tmp/latex.pdf" ] && ! grep -q '^!' "$tmp/book.log" "$tmp/latex.log"; then
        txt=$(pdftotext "$tmp/book.pdf" - 2>/dev/null)
        case "$txt" in
        *"Swing Time"*"Notes"*"An endnote on the claim"*"Bibliography"*"Grazer, Brian"*)
            pass "LuaLaTeX sets both, the citations found" ;;
        *)
            failed "LuaLaTeX's book lacks its citations or notes" ;;
        esac
        grep -q 'undefined' "$tmp/book.log" && failed "undefined: $(grep -m3 undefined "$tmp/book.log")"
    else
        failed "LuaLaTeX: $(grep -h -m1 -A2 '^!' "$tmp/book.log" "$tmp/latex.log" 2>/dev/null)"
    fi
else
    echo "SKIP: no LuaLaTeX with biblatex-chicago, epigraph, endnotes and imakeidx"
fi

exit $fail
