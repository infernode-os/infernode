#
# Docengine - one kind of document, for Xenith's document view
#
# An engine holds documents of one kind (PDF, image, Markdown,
# Mermaid, HTML) as sessions named by a handle, and paints them for
# the view, which belongs to the window: it scrolls, zooms and pans
# one column of sheets for every kind (docs/xenith-documents.md).
#
# Engines are loaded by the document registry (docreg(2)) the first
# time a document of their kind is opened, never before; what an
# engine needs beyond that (the PDF interpreter, the typesetter,
# Charon's engine) it loads in open. Each engine is one module
# instance, shared by every window showing its kind.
#
# A document is a column of sheets: a PDF's pages, or one sheet for a
# picture or for a flowing document laid out to the style's width.
# Sizes and points are in pixels at scale 100, on the sheet.
#

Docengine: module
{
	# What a document is set in: a flowing document is laid out to
	# width; the colours are the window's (or the theme's).
	Style: adt {
		width:	int;
		font:	ref Draw->Font;
		codefont:	ref Draw->Font;
		fg:	ref Draw->Image;
		bg:	ref Draw->Image;
		accent:	ref Draw->Image;
		codebg:	ref Draw->Image;
	};

	# A word as drawn, where it is on its sheet
	Run: adt {
		text:	string;
		r:	Draw->Rect;
	};

	# A link, where it is
	Link: adt {
		sheet:	int;
		r:	Draw->Rect;
		url:	string;
	};

	init:	fn(d: ref Draw->Display): string;

	# A document from its bytes and name (a path or URL; for a file
	# too large to have been read whole, data may be nil and the
	# engine reads the file). Returns a handle, or an error.
	open:	fn(data: array of byte, name: string, s: ref Style): (int, string);
	close:	fn(h: int);

	nsheets:	fn(h: int): int;
	sheetsize:	fn(h: int, n: int): Draw->Point;

	# Set again for a new style: a new width, or the window's colours.
	# A paged document or a picture may ignore it.
	restyle:	fn(h: int, s: ref Style): string;

	# 1 if the engine paints sharp at any scale; 0 if it paints at
	# scale 100 only, and the view scales what it paints.
	scalable:	fn(h: int): int;

	# Sheet n at scale (percent) into dst's rectangle r, the point
	# org of the scaled sheet at r.min.
	paint:	fn(h: int, n: int, scale: int, dst: ref Draw->Image,
			r: Draw->Rect, org: Draw->Point): string;

	# The document's text: extracted from a binary document, as set
	# from a source document; and one sheet's.
	text:	fn(h: int): string;
	sheettext:	fn(h: int, n: int): string;

	# The words on sheet n, as drawn, for hit-testing and showing
	# what a search found; nil if the engine cannot tell.
	runs:	fn(h: int, n: int): array of Run;

	# The document's links, and the link at p on sheet n (or nil)
	links:	fn(h: int): array of Link;
	linkat:	fn(h: int, n: int, p: Draw->Point): string;

	# For a source document: where line l of its text is set
	# (sheet, y), and the line set at y on a sheet; so a window
	# keeps its place going from the text to the document and back.
	lineto:	fn(h: int, l: int): (int, int);
	lineat:	fn(h: int, n: int, y: int): int;

	# Commands the engine adds to the view's own (Zoom, Fit, Page
	# and paging are the view's).
	commands:	fn(h: int): list of string;
	command:	fn(h: int, cmd, arg: string): string;
};
