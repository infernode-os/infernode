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
| `tbl` | Tables | Plan 9's tbl, translated (byte-identical output) |
| `pic` | Pictures | Plan 9's pic, translated (byte-identical output; its grammar through Inferno's yacc) |
| `refer` | Citations by key from BibTeX's and refer's databases; with `-S chicago`, the *Chicago Manual of Style*'s notes and bibliography (18th edition) | Neatrefer, translated, with a BibTeX reader and styles of its own |
| `tr2pdf` | Troff's output as PDF: OpenType fonts embedded, subset to the glyphs used, compressed, with ToUnicode maps (text can be searched and copied) | Neatpost's PDF writer, translated |
| `mkfn` | Font descriptions for troff from OpenType, TrueType and AFM fonts, with each glyph's bounding box (CFF's too) | Neatmkfn, translated |
| `mkindex` | A book's index from troff's output: makeindex's entries, sorted word by word as the *Chicago Manual* sorts, Greek and accents included | |
| `book2tex` | A book written with `-mbook` as LaTeX, for LuaLaTeX, for a publisher who wants it | |
| `book` | Runs them: refer, pic, tbl and eqn (each if there is anything for it), troff `-mbook` until its references settle, tr2pdf | |

`troff`, `eqn`, `tbl`, `pic`, and `refer` without a style, write what
the C programs they came from write, byte for byte, but where those
loop for ever or crash; `tr2pdf -c` and `mkfn -c` do too.
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
| `.index "term!sub"` | `\index{term!sub}` (makeindex's syntax) |
| `.printindex` | `\printindex` |
| `$...$` (after `delim $$`) | `$...$` |
| `.EQ` ... `.EN`; `.EQ (1.1)` | `\[...\]`; `equation` with `\tag{1.1}` |
| `.TS` ... `.TE` | `tabular` (in a `table`) |
| `.PS` ... `.PE` | `picture` (or TikZ) |
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

## Drafts and the book as it goes to press: `book -f`

`book` sets a draft; `book -f` sets the book as it goes to press, with
microtypography, as LaTeX's microtype (with pdfTeX) sets a book:
punctuation, hyphens, quotation marks and a few letters hang into the
margins (*protrusion*), so that the text's edges look straight rather
than measure straight; and a justified line's glyphs widen or narrow by
up to 2% (*expansion*), so that its spaces vary less from line to line.
A paragraph is filled knowing both, so its lines break better too.

It is troff's (`-mbook` turns it on when the register `book-final` is
set, as `book -f` sets it):

    .mtpc R 0 700 . \(hy         \" font R: these hang right by 0.7 of their width
    .mtpc R 500 300 “            \" left by half, right by 0.3
    .mtp 1                       \" protrusion on, in this environment
    .mte 20 20 5                 \" expansion: stretch, shrink, step (thousandths)

The codes are in thousandths of each glyph's width, as pdfTeX's
`\lpcode` and `\rpcode`; `-mbook`'s follow microtype's defaults. A
line's first glyph protrudes left, its last (or the hyphen inserted)
right; a first line indented by `.ti` (a paragraph's) does not protrude
left.

Expansion treats a line's glyphs as giving like its spaces: the line's
lack or excess is divided between them as their give divides it (as
pdfTeX's), the glyphs' share rounded to a step. troff scales the glyphs'
advances, and says by how much (`x X mtx 15`, thousandths) for tr2pdf,
which draws their shapes as scaled (`Tz`), each where troff put it.
With `.mtp 0` and `.mte 0`, the defaults, troff sets as C Neatroff does.

## Widows and orphans: `.wo`

A paragraph is broken by a page only with two lines at least on either
side: its first line is not left alone at a page's foot (an orphan), nor
its last carried alone to the next page's head (a widow), as LaTeX's
penalties keep them. Where one would be, a line more goes with it to
the next page and this one is a line short, or the whole paragraph goes.
troff does it (`.wo 1`, in an environment) as it fills: the page's last
lines are set only when what follows them is known, and a note that
moves the foot up is allowed for. `-mbook` sets it in drafts as in the
book as it goes to press, so the two break their pages alike. With
`.wo 0`, the default, troff sets as C Neatroff does.

## The index: `.index` and `mkindex`

An entry is written as LaTeX's `\index` (makeindex's syntax), on a line
of its own before the line its word begins:

    .index "virtue"
    virtue is ...
    .index "virtue!and justice"           \" a subentry (up to three levels)
    .index "aretē@ἀρετή"                  \" sorted as aretē, set as ἀρετή
    .index "polis|see{city}"
    .index "Plato|seealso{Socrates}"
    .index "tragedy|("  ...  .index "tragedy|)"   \" a range
    .index "soul|textbf"                  \" its page in bold (textit, emph)

`.index` puts the entry into troff's output where the word after it is
set (`x X idx`), so it gives that page even when the line or its note
goes to the next; each page's foot writes its folio (`x X folio`).
`mkindex book.out` reads them back and writes the index for
`.printindex`, which sets it in two columns at the end of the book.
The order is the *Manual*'s, word by word (New York before Newark), case,
accents, breathings and troff's escapes aside (Ætna and ἀρετή under a);
three pages or more in a row are a range, a range's end abbreviated as
the *Manual* abbreviates it (101–8); a page is given once, in bold or
italic if any entry on it asks; *See also* follows an entry's
subentries. `book` runs `mkindex` after each pass and sets the book
again until the index, too, no longer changes.

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

## Tables and pictures: `tbl` and `pic`

Tables are written in tbl's language, pictures in pic's (Lesk's and
Kernighan's); `book` runs each when a book has any. Under `-mbook` a
table's rules are drawn as lines (troff's `.rules`, which draws `\l`'s
and `\L`'s of rule characters as lines rather than setting a font's
glyphs side by side), and a picture is centred with space about it.

## Fonts

The device `utf` (`lib/troff/devutf`) sets in Libertinus: Serif (R, I,
B, BI), Sans (HR, HI, HB), Mono (CR), Math (S), with Greek. Its
descriptions are made by `mkfn` (`lib/troff/devutf/mkdesc`). Another
font, Minion Pro for one, is described the same way:

    mkfn -b -l -o -r7200 -Slatn,grek -tMR -f/fonts/minion/MinionPro-Regular.otf /fonts/minion/MinionPro-Regular.otf >/lib/troff/devutf/MR

Glyphs beyond U+FFFF (mathematical alphanumerics, for one) are
described without names: a Limbo string's characters are 16 bits.

A character none of Libertinus's fonts has (✓, ☐, many symbols) is set
in the fallback, DejaVu Sans (`DF`, a special font `-mbook` mounts: troff
looks for a glyph in it when the font set in lacks one). One no font has
is said (`troff: no font has 中 (U+4E2D)`), once, where C Neatroff drops
it without a word (`.mg 1`, as `-mbook` sets it).

## Fonts in the PDF

`tr2pdf` embeds each OpenType (CFF) font subset to the glyphs the book
uses: the glyphs it does not use, and the subroutines only they call,
are emptied (the glyphs keep their numbers, so the text is unchanged),
and the tables only typesetting needs (GSUB, GPOS, GDEF, MATH) are left
out; a TrueType font (the fallback) likewise, by its glyf and loca, a
composite glyph keeping its components; the font is named as a subset (`ABCDEF+LibertinusSerif-Regular`).
A book's PDF is a fifth of what it was, or less; every page is drawn as
with the fonts whole (`tr2pdf -W`), pixel for pixel. A font it cannot
read so (CID-keyed, Type 1 charstrings) is embedded whole.

## Speed

On a 2.8 GHz Xeon, the 62-page benchmark book takes troff 2.9 seconds
(C Neatroff: 1.05), about 0.2 seconds to start and 45 milliseconds a
page; a page is painted in about 20 milliseconds. Making it faster comes
after the work above is done.

## LaTeX for a publisher: `book2tex`

    book2tex -p works.bib -o book.tex book.ms

writes the book as LaTeX, each of `-mbook`'s macros as the LaTeX the
table above gives it. The LaTeX is for LuaLaTeX, set as `book` sets
it:
- Libertinus, through `fontspec` and `unicode-math`.
- The page and margins, from `.papersize` and `.margins`.
- `microtype`.
- Citations by `biblatex-chicago` (its notes, the *Chicago Manual*'s
  as refer's `-S chicago`), from the BibTeX database `-p` names.
- Endnotes by `endnotes`, under each chapter's heading.
- The index by `imakeidx`, its entries makeindex's as `.index` has
  them.

Set it with:

    lualatex book; biber book; makeindex book; lualatex book; lualatex book

Troff's escapes become LaTeX's: `\fI` and `\fB` become `\emph` and
`\textbf`, a character named becomes the character, `\*` strings are
expanded. LaTeX's special characters are escaped, and troff's two
hyphens stay two.

eqn's equations become LaTeX's mathematics:
- `sub`, `sup`, `over`, `sqrt`, `from` and `to` (an operator's
  limits), `left` and `right`, `pile`, `matrix`, accents, fonts and
  defines.
- `.EQ (1.1)` is numbered with `\tag`.
- An equation between `delim`'s characters is inline.

tbl's tables become `tabular`s, with their rules, spans and text
blocks. A picture is drawn by `pic`, `troff` and `tr2pdf` as a PDF the
size of the picture (`book-pic1.pdf`, beside `-o`'s file) and
included.

Anything with no LaTeX of its own (a macro of the book's own, say) is
kept as a comment and named on standard error.

## Still to come

`-man`; eqn's bars drawn as lines (they are
glyphs now, and copied with the text).
