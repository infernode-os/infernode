# Xenith documents: one model for every rendered file

Status: design, being built (feat/docmodel).

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

```
module/docengine.m

Docengine: module {
	Style: adt {			# what a flowing document is set in
		width:	int;		# the width to set it to, in pixels
		font, codefont:	ref Draw->Font;
		fg, bg, accent, codebg:	ref Draw->Image;
	};
	Run: adt {			# a word as drawn, for hit-testing
		text:	string;
		r:	Draw->Rect;	# on its sheet, at scale 100
	};

	init:	fn(d: ref Draw->Display): string;
	open:	fn(data: array of byte, name: string, s: ref Style): (int, string);
	close:	fn(h: int);

	nsheets:	fn(h: int): int;
	sheetsize:	fn(h: int, n: int): Draw->Point;	# at scale 100
	restyle:	fn(h: int, s: ref Style): string;	# a new width or colours
	paint:	fn(h: int, n: int, scale: int, dst: ref Draw->Image,
			r: Draw->Rect, org: Draw->Point): string;

	text:	fn(h: int): string;
	runs:	fn(h: int, n: int): array of Run;	# nil: cannot tell
	linkat:	fn(h: int, n: int, p: Draw->Point): string;
	commands:	fn(h: int): list of string;	# beyond the view's own
	command:	fn(h: int, cmd, arg: string): string;
};
```

`paint` draws sheet `n` at `scale` (percent of its size at 100), the
point `org` of the scaled sheet at `r.min` of `dst`. A vector document
(PDF, Markdown, a diagram) is painted at the scale asked for, so text
stays sharp when zoomed; an image is scaled.

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

The **registry** is a table, not a set of loaded modules:
`/lib/xenith/doctypes`, one line to a kind —

```
# engine			kind	extensions		magic
/dis/xenith/doc/pdfdoc.dis	binary	.pdf			%PDF-
/dis/xenith/doc/imgdoc.dis	binary	.png .jpg .jpeg .gif .webp .bmp .ppm .pgm .pbm .xbm .pic
/dis/xenith/doc/mddoc.dis	source	.md .markdown
/dis/xenith/doc/mmddoc.dis	source	.mmd .mermaid
/dis/xenith/doc/htmldoc.dis	source	.html .htm
```

Reading it loads nothing; an engine is loaded the first time a
document of its kind is opened, and its own dependencies when it
opens one. One registry serves Xenith.

## The view

- **Scroll**: the wheel and the scroll bar move the column smoothly,
  across sheet boundaries; Page Up/Down a screenful. Button 1 drags
  the document in both directions (grab and pan), as now.
- **Zoom**: `Zoom+`, `Zoom-`, `Zoom n` (percent), `Fit` (the widest
  sheet to the window's width: the default for documents) and `Page`
  (a whole sheet in view: the default for pictures). Zoom keeps the
  point under the pointer, or the top of the view, where it was.
  While a sheet is painted again at the new scale, the old painting
  is shown scaled, so zooming never waits.
- **Paging**: `Page n`, `NextPage`, `PrevPage` scroll to a sheet.
- **Cache**: the painted sheets in and near view, at the current
  scale; others are dropped as they leave.
- **Text on the drawing**, where the engine gives runs: button 1
  clicked without moving selects the word under the pointer (Snarf
  copies it); button 2 executes it; button 3 looks at it, or follows
  the link there. Search highlights its matches on the drawing.

## The namespace

Every window with a document has a directory `doc` beside its other
files:

```
/mnt/xenith/<id>/doc/
	ctl	read: the state, one attribute a line —
			kind pdf
			class binary
			name /usr/me/report.pdf
			sheets 12
			sheet 3			(the sheet at the top of the view)
			scale 150
			view 0 1840 1200 900	(x y w h of the view, at that scale)
		write: commands, one a line —
			sheet n | scale n | fit | page | scroll dy |
			render | text	(a source document: show it, or its text)
	text	the document's text (extracted, or as set), read-only
	links	one link a line: sheet x0 y0 x1 y1 url (scale 100)
	find	write a string; read its matches, one a line:
			sheet x0 y0 x1 y1
	sheets/<n>/size	w h at scale 100
	sheets/<n>/text	that sheet's text
```

`image` keeps its meaning (the rendered image's path and size). A
browser window's `web` file still names the page's own file tree
(charonfs), which serves a page in more detail than `doc` does.

## Not done here

- Selecting a range of text on the drawing (dragging): button 1 drag
  is grab and pan, which is kept. A word is selected by a click.
- A source document's offsets are not mapped to its text's: a word
  selected on the drawing is a word, not a position in the source.
