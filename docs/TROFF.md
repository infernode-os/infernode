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
chapter's on the right. Footnotes are numbered in each chapter. Endnotes
are gathered under their chapters' names for `.notes`.

Footnotes are set at the foot of their marks' pages, in order:
- A note too long for the room left is begun there if three of its
  lines fit, and goes on at the next page's foot, as LaTeX splits a
  note. A shorter note that doesn't fit goes whole to the next page.
- troff fills a paragraph at once, so a mark may be several lines into
  text not yet set. `.fe` counts those lines (troff's `.pend` register).
- The page's foot sets only the notes whose marks went out on it.
  troff learns which as each line goes out (an `\X'nr fn-out N'` in the
  mark): a line the widows' rule moved on takes its note with it.

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

## Reading it on a screen: links and bookmarks

The PDF is made to be read as well as printed, as hyperref makes
LaTeX's:
- **Links.** These are links to where they lead:
  - each line of the contents;
  - `\*[ref]` and `\*[pageref]`;
  - a footnote's or endnote's mark (and the note's number, back to the
    mark);
  - each page in the index.
- **Bookmarks.** The bookmarks are the contents: parts, chapters and
  sections, each under the one it is in.
- **Page labels.** Each page is labelled as it is numbered, so a viewer
  shows iv, not 4.
- **Information.** `.title` and `.author` become the PDF's information.

The macros put destinations and bookmarks where their headings, labels
and notes are set (`x X dest name`, `x X outline level title`), and
links on text (`x X link #name width height`). tr2pdf takes the page
and the place from where they land: a heading is found wherever troff
put it. Each page's folio (`x X folio`) gives its label and its
destination for the index (`pg-` and the folio). `mkindex -l`, as
`book` runs it, writes each page as a link (`\*[book-pl folio shown]`).

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
table's rules, and an equation's (its fractions', radicals', bars and
underlines), are drawn as lines, and a picture is centred with space
about it.

The rules come from troff's `.rules`. It draws `\l`'s and `\L`'s of
rule characters as lines, not as a font's glyphs set side by side,
which leave joins and are copied with the text. Each line is a filled
rectangle exactly where the glyphs' ink would be. Its place and
thickness come from the glyph's bounding box: the character's own, or
the one its `.char` gives it (eqnrc's rules are Libertinus Math's).
eqn and tbl place the rules by those boxes, so each lands where its
glyphs would have.

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

A pair is kerned as its font kerns it, once. Libertinus's Latin and
Greek share their kerning lookups. Neatmkfn wrote a lookup once for
each script, and troff, with no script chosen, performed every copy:
every pair in every book set before this was kerned twice (AV by -224
units at 10 points, not the font's -112). Neatmkfn also left out the
pairs a kerning class table gives its first glyphs' class 0 (D in DA,
DV and DY). `mkfn` now writes a shared lookup once, with no script,
and class 0 as every glyph of the table's coverage given no other
class. `tests/host/troff_test.sh` checks every pair of letters in
Libertinus Serif and Sans against the font's GPOS.

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

On a 2.8 GHz Xeon, the 62-page benchmark book (`-ms`) takes troff 1.36
seconds compiled (`emu -c1`), 22 milliseconds a page; C Neatroff takes
0.58. It took 2.34 before the changes below. A 39-page `-mbook` book
with notes on every page takes 0.77 seconds a pass. A page is painted
in about 20 milliseconds.

The time went where a translation from C puts it: a string made for
every character, an array allocated and zeroed for every word, a
function called to read a field. What was done about it, the output
the same byte for byte:
- A font's glyphs by name kept by character (names of one character,
  or two ASCII ones), and a word's layout (GSUB, GPOS) kept by its
  glyphs and the font's state, so neither dictionaries nor the rules
  are searched again for a word set before.
- Buffers kept between words, or made the size they need; escape
  sequences' names and arguments sliced from their strings.
- Strings for the output's commonest pieces (`hN`, `cX`, `\h'Nu'`, a
  word's font, size and colour) kept, not formatted each time.
- Paragraph filling's cost figured in `int` where it cannot overflow.

The profile is flat now: no function takes more than 4 per cent. What
remains is Dis's: reference counting on every pointer copied, frames
made and returned from (together a fifth of the time), allocation and
freeing (an eighth), and calls.

Profiling compiled code: `prof` counts the interpreter's instructions,
and is no guide to where compiled code spends its time. Sample the
emulator's program counter (ptrace) instead, run with `-c5` so that the
compiler prints where each Dis instruction's code begins, and map the
samples through the module's `.sbl` to source lines. Compile troff with
its included files put into one (`include "x.b"` replaced by the file),
so that every line has one file to be in.

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

## Manual pages: `-man` and `man -t`

`troff -man` sets a manual page as Plan 9's printed manual is set: 9
on 11 points, 6.5 inches wide, its head the page's name and section,
its foot the folio. Headings are bold at the margin and the text 3.6
ems in; commands and literals (`.B`, `.L`) are in constant width.
Libertinus Sans stands for Plan 9's Lucida Sans, Libertinus Mono for
its constant width. `man -t ls` writes troff's output for `ls(1)`;
`man -t ls | tr2pdf >ls.pdf` makes a PDF of it.

`lib/tmac/tmac.an` is written for this troff. Plan 9's macros keep a
paragraph's tag in a string made from a diversion, which Neatroff's
diversions cannot be (they hold requests); with Plan 9's file, C
Neatroff and troff alike set every page with its macros' bodies
printed as text. The macros are those InferNode's pages use:
`.TH .SH .SS .PP .LP .P .IP .TP .HP .RS .RE .PD .TF .EX .EE .SM`, and
the fonts' `.B .I .L .R` and their alternations (`.BR .IR` ...). A
tag is set as a line of its own, and its paragraph goes back up
beside it if the tag fits the indent. An alternation takes as many
words as it is given (Plan 9's take six). Arguments are compared
between BELs, as Plan 9's are, so an argument may hold a quote.
`tests/host/man_test.sh` sets every page of the manual, and checks
each macro by where it puts its words.

The toolchain's own pages are `troff(1)`, `eqn(1)`, `tbl(1)`, `pic(1)`,
`refer(1)`, `tr2pdf(1)`, `mkfn(1)`, `book(1)` (with `book2tex` and
`mkindex`) and `troff(6)`, the macro packages.

## Still to come

Nothing on the list. A test book like the one this was made for
(its notes, index, tables, equations and Greek) is the next measure.
