# Troff in InferNode

A typesetting system for books: troff, written in Limbo, with its
preprocessors and macros, writing PDF to deliver and troff's own output
to read in InferNode's document views.

    book -p works.bib book.ms        # book.pdf, and book.out to view

## The parts

| Command | What it does | From |
|---|---|---|
| `troff` | Sets troff's input: paragraph-at-once filling, OpenType kerning, ligatures and features, hyphenation (English and Ancient Greek) | Neatroff, translated (byte-identical output on ~500 documents) |
| `eqn` | Mathematics: TeX's rules for setting it, in troff; Libertinus Math's sized brackets, radicals and operators (`/lib/troff/eqnrc`) | Neateqn, translated (byte-identical output) |
| `refer` | Citations by key from BibTeX's and refer's databases; with `-S chicago`, the *Chicago Manual of Style*'s notes and bibliography (18th edition) | Neatrefer, translated, with a BibTeX reader and styles of its own |
| `tr2pdf` | Troff's output as PDF: OpenType fonts embedded, compressed, with ToUnicode maps (text can be searched and copied) | Neatpost's PDF writer, translated |
| `mkfn` | Font descriptions for troff from OpenType, TrueType and AFM fonts, with each glyph's bounding box (CFF's too) | Neatmkfn, translated |
| `book` | Runs them: refer, eqn (if there are equations), troff `-mbook` until its references settle, tr2pdf | |

`troff`, `eqn`, and `refer` without a style, write what the C programs
they came from write, byte for byte; `tr2pdf -c` and `mkfn -c` do too.
Without `-c` those two differ where troff and its readers are better
served (their commits list how).

Troff's output (`book.out`) opens in Xenith's document view, `wm/page`
and Lucifer: a page at a time, sharp at any zoom, its text searchable
and its links followed. A `.ms`, `.man`, `.me` or `.mm` file opens there
set by troff, beside its text.

## Writing a book: `-mbook`

Each macro is one of LaTeX's, so that a book is readily turned into
LaTeX without being LaTeX.

| `-mbook` | LaTeX |
|---|---|
| `.title`, `.subtitle`, `.author`, `.date`, `.maketitle` | `\title`, ..., `\maketitle` |
| `.frontmatter`, `.mainmatter`, `.backmatter` | the same |
| `.part "Title"` | `\part{Title}` |
| `.chapter "Title" [label]` | `\chapter{Title}\label{label}` |
| `.chapter* "Title"` | `\chapter*{Title}` |
| `.section "Title" [label]`, `.subsection` | `\section`, `\subsection` |
| a blank line, or `.p` | a paragraph |
| `.quote` ... `.endquote` | `quotation` |
| `.epigraph` ... `.attrib "Source"` `.endepigraph` | `\epigraph{...}{Source}` |
| `text\*[fnmark]` then `.fn` ... `.fe` | `\footnote{...}` |
| `text\*[enmark]` then `.en` ... `.ee`; `.notes` | `\endnote{...}`; `\theendnotes` |
| `.label name`; `\*[ref name]`, `\*[pageref name]` | `\label`, `\ref`, `\pageref` |
| `.contents` | `\tableofcontents` |
| `.cite key [loc][; key loc]` | `\autocite[loc]{key}` (biblatex-chicago) |
| `\*[cite key loc]` within a note of one's own | `\cite[loc]{key}` |
| `.bibliography` | `\printbibliography` |
| `$...$` (after `delim $$`) | `$...$` |
| `.EQ` ... `.EN`; `.EQ (1.1)` | `\[...\]`; `equation` with `\tag{1.1}` |
| `\fI...\fP`, `\fB...\fP` | `\emph{...}`, `\textbf{...}` |

A footnote's mark follows the text before it: end that line with `\c`
(or put `\*[fnmark]` where the mark goes) and begin the next with `.fn`.
`refer`'s citing notes do this themselves.

The page is 6 by 9 inches, set in 11-point Libertinus on 14 points;
change it before the first text:

    .papersize 8.5i 11i
    .margins 1i 1i 1.25i 1i          \" top bottom inner outer
    .nr book-ps 12                   \" point size, whole points
    .nr book-vs 15p
    .nr book-recto 0                 \" chapters need not open on the right
    .ds book-citenotes en            \" citing notes as endnotes

Chapters open on right-hand pages, with no running head and their folio
at the foot; the running heads are the book's title on the left, the
chapter's on the right. Footnotes are numbered in each chapter; a note
that does not fit on its page goes to the next. Endnotes are gathered
under their chapters' names for `.notes`.

The table of contents and the references need a second pass (the pages
are known only once the book has been set): `book` gathers what the
first pass learnt (the `aux:` lines troff writes to its standard error)
into `book.aux`, and sets the book again until it no longer changes.

## Citations: `refer -S chicago`

Works are cited by their keys, from a BibTeX database (`works.bib`) or
refer's. The first citation of a work in a chapter is its full note,
later ones the short note; up to three authors are named in a note (the
first and *et al.* past that), up to six in the bibliography (three and
*et al.* past that); page ranges are abbreviated as the Manual
abbreviates them (101–8, 321–28, 1496–1504). Kinds of work: books
(author, editor or both, translator, edition, volume, series), chapters
in edited books, articles (with DOIs), theses, other works, and
classical works cited by their parts (`entrysubtype = {classical}`:
Homer, *Iliad* 1.1–5). See `appl/cmd/refer/style/chicago.b` for its
rules and `tests/refer/` for examples.

A style is a module (`module/referstyle.m`): another is a file of its
own under `appl/cmd/refer/style`.

## Mathematics: `eqn`

Equations are written in eqn's language (Kernighan and Cherry's, with
groff's additions), and set by TeX's rules:

    .EQ
    delim $$
    .EN
    The roots of $a x sup 2 + b x + c = 0$ are
    .EQ (1.1)
    x = {- b +- sqrt {b sup 2 - 4ac}} over {2a}
    .EN

`book` runs eqn when a book has equations, after
`/lib/troff/eqnrc`: its settings for Libertinus Math. Brackets (`left (`
... `right )`) take the font's larger sizes, then are built from its
pieces; radicals likewise; a displayed sum, product or integral is the
font's display size, an inline one the text size with its limits beside
it (`ifdisplay` and `set text_limits 1`, which eqn has beyond Neateqn).
A display is centred, its label at the right on its baseline.

Glyphs' heights and depths come from the fonts' descriptions: `mkfn`
reads each glyph's bounding box from its outline, CFF's (Libertinus's)
as well as TrueType's.

## Fonts

The device `utf` (`lib/troff/devutf`) sets in Libertinus: Serif (R, I,
B, BI), Sans (HR, HI, HB), Mono (CR), Math (S), with Greek. Its
descriptions are made by `mkfn` (`lib/troff/devutf/mkdesc`). Another
font, Minion Pro for one, is described the same way:

    mkfn -b -l -o -r7200 -Slatn,grek -tMR -f/fonts/minion/MinionPro-Regular.otf /fonts/minion/MinionPro-Regular.otf >/lib/troff/devutf/MR

Glyphs beyond U+FFFF (mathematical alphanumerics, for one) are
described without names: a Limbo string's characters are 16 bits.

## Speed

On a 2.8 GHz Xeon, the 62-page benchmark book takes troff 2.9 seconds
(C Neatroff: 1.05), about 0.2 seconds to start and 45 milliseconds a
page; a page is painted in about 20 milliseconds. Making it faster comes
after the work above is done.

## Still to come

tbl and pic; an index; the LaTeX converter; `-man`; microtypography
(protrusion and expansion); fonts falling back for characters a font
lacks; font subsetting in PDFs; eqn's bars drawn as lines (they are
glyphs now, and copied with the text).
