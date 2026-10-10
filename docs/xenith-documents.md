# Xenith documents: one model for every rendered file

Status: built (feat/docmodel, #823). This page is the design and what
was built; user documentation is in [XENITH.md](XENITH.md#documents).

## The problem

Xenith shows a PDF, an image, a Mermaid diagram, Markdown and HTML
through three mechanisms that grew separately:

| mechanism | for | the body holds | drawn by |
|---|---|---|---|
| image mode | images, PDF, Mermaid | PDF: extracted text; others: nothing | an image over a text frame that still draws |
| document view | Render of Markdown and HTML, browsing | the source; a page's text | a layout engine, the frame drawn off screen |
| formatter mode | Render of other text | formatted text, the raw kept aside | text |

Whether a window renders is decided in one place, `openfile`, and
only for a new window: a file named on Xenith's command line, Get,
Dump/Load, and a file plumbed to a window already open all load its
bytes as text. A PDF opened by `xen file` shows its source.

The picture and the text are unrelated: nothing maps a point on the
drawing to the text under it, so nothing on the drawing can be
selected, looked at or executed, and a search finds what cannot be
seen. Each PDF window shares one current page (module globals in
`pdfrender`). The render registry loads every renderer when Xenith
starts, twice.

## The model

A **document** is a file shown as it is meant to be seen. It is held
by an **engine**, a module that knows one kind of file, as a session
named by a handle. The window owns the **view**: one piece of code
for every kind, which scrolls, zooms and pans, and asks the engine to
paint what is in sight.

A document is a column of **sheets**: a PDF's pages; one sheet for a
picture (an image, a diagram); one sheet for a flowing document
(Markdown, HTML) laid out to the window's width. The view stacks them
with a gap between, so a PDF scrolls continuously from page to page.

Two kinds of file:

- **Source documents** — Markdown, HTML, Mermaid. The body is the
  file's text, editable; Render shows the document or the text; Put
  saves the text. The document is set again from the text when it
  changes.
- **Binary documents** — PDF, images. Always shown as the document.
  The body holds the document's text (extracted), read-only, so Look,
  search, Snarf and an agent reading `body` work as they do now; Put
  refuses rather than write text over the file.

Every way of opening a file — plumbing, a look (B3), Xenith's command
line, Get, Load, `ctl` — goes through one function that decides by
the file's name and first bytes. Get on a document opens it again as
what it is.

## Engines, loaded only when needed

The interface is `module/docengine.m`. An engine holds documents of one
kind as sessions named by a handle:

- `open` (bytes and name, or a URL; a style: the width a flowing
  document is set to, the window's fonts and colours), `close`;
- `nsheets`, `sheetsize` (at scale 100), `restyle` (a new width or
  colours), `scalable` (paints sharp at any scale, or at 100 and the
  view scales), `paint` (a sheet at a scale, the part from a point,
  into a rectangle of an image);
- `text`, `sheettext`; `runs` (the words as drawn, for hit-testing
  and marking what a search found), `links`, `linkat`; `lineto` and
  `lineat` (a source document's lines and where they are set, so a
  window keeps its place);
- `commands`, `command` (beyond the view's own);
- for a document that changes by itself or takes input (a web page):
  `events` (a channel: `done y`, `update`, `error msg`), `name` (its
  URL now), `click` and `key` (what the view is to do: `paint`,
  `layout`, `show y0 y1`), and `files` (where it is served as files).

Engines:

| engine | kind | loads, on first open | sheets |
|---|---|---|---|
| `pdfdoc` | binary | `pdf(2)` | pages |
| `imgdoc` | binary | `imgload(2)` | one |
| `mddoc` | source | `rlayout(2)` (and `mermaid(2)` for a diagram in it) | one, flowing |
| `mmddoc` | source | `mermaid(2)` | one |
| `htmldoc` | source | browser(2), Charon's engine | one, flowing |

Markdown and Mermaid never load Charon: `rlayout` is the common
typesetter, and Charon is used for HTML only.

The **registry** (`module/docreg.m`) is a table, not a set of loaded
modules: `/lib/xenith/doctypes`, one kind a line, its name, class,
engine, extensions and `magic=` prefixes —

```
pdf	binary	/dis/xenith/doc/pdfdoc.dis	.pdf	magic=%PDF-
image	binary	/dis/xenith/doc/imgdoc.dis	.png .jpg ... .bit	magic=\x89PNG ...
markdown	source	/dis/xenith/doc/mddoc.dis	.md .markdown
mermaid	source	/dis/xenith/doc/mmddoc.dis	.mmd .mermaid
html	source	/dis/xenith/doc/webdoc.dis	.html .htm
```

Reading it loads nothing; an engine is loaded the first time a
document of its kind is opened, and its own dependencies when it
opens one. One registry serves Xenith. `picture` draws a document
whole as one image, for Lucifer's presentation view, which uses the
same engines.

## The view

- **Scroll**: the wheel and the scroll bar move the column smoothly,
  across sheet boundaries; Page Up/Down a screenful. Button 1 drags
  the document in both directions (grab and pan), as now.
- **Zoom**: `Zoom+`, `Zoom-`, `Zoom n` (percent), `Fit` (the widest
  sheet to the window's width: the default for a PDF) and `Fit page`
  (a whole sheet in view: the default for a picture). Zoom keeps the
  middle of the top of the view where it was. While a sheet is painted
  again at the new scale, the old painting is shown scaled, so zooming
  never waits. A PDF page below 250% is painted at twice the scale and
  averaged down: the interpreter places glyphs on whole pixels, and at
  a low resolution type is unevenly spaced. A flowing document zoomed
  is set again to the window's width at that scale, and scaled.
- **Paging**: `Page n`, `NextPage`, `PrevPage` scroll to a sheet.
- **Cache**: the painted sheets in and near view, at the current
  scale; others are dropped as they leave.
- **Text on the drawing**, where the engine gives runs: button 1
  clicked without moving selects the word under the pointer (Snarf
  copies it); button 2 executes it; button 3 looks at it, or follows
  the link there. Search highlights its matches on the drawing.

## The namespace

Every window has a directory `doc` beside its other files (empty files
for a window showing text):

```
/mnt/xenith/<id>/doc/
	ctl	read: the state, one attribute a line —
			kind pdf
			class binary		(binary, source or web)
			name /usr/me/report.pdf
			shown 1			(the document, not its text, is shown)
			sheets 12
			sheet 3			(the sheet at the top of the view)
			scale 150
			fit width		(width, page or none)
			view 0 1840 1200 900	(x y w h of the view, in the column)
			screen 16 59 1200 887	(where the view is on the screen)
			column 1224 14000	(the column's size, at the scale)
		write: commands, one a line —
			sheet n | scale n | fit [page] | scroll dy |
			render | text | the view's and the engine's commands
	text	the document's text, read-only
	links	one link a line: sheet x0 y0 x1 y1 url (scale 100)
	find	write a string; read where it was found, one a line:
			sheet x0 y0 x1 y1
```

`image` names the document shown and its first sheet's size. A
browser window's `web` file still names the page's own file tree
(charonfs), which serves a page in more detail than `doc` does.

## Not done here

- Selecting a range of text on the drawing (dragging): button 1 drag
  is grab and pan, which is kept. A word is selected by a click.
- A source document's offsets are not mapped to its text's: a word
  selected on the drawing is a word, not a position in the source.
- HTML is not hit-tested word by word: Charon's display list has no
  text offsets yet. Links are (`linkat`), and so is a click on a page.
- An image is zoomed by scaling in software (the draw device has no
  scaling); the result is kept for each zoom level.
