#
# Sheetview - a document's sheets in a column, on an image
#
# The view every program that shows documents shares (Xenith's
# windows, wm/page): an engine (docengine(2)) holds the document; the
# view stacks its sheets in a column, a gap between, and draws the part
# at org into a rectangle of an image, fitted to its width (a PDF), a
# whole sheet in view (a picture), or, for a flowing document (Markdown,
# HTML, a page browsed), set to its width.  A sheet an engine paints
# sharp at any scale is painted at the view's, off the caller's thread,
# and kept while in or near view; until it arrives, one at another scale
# is shown scaled, or a blank sheet.
#
# The view never calls its caller: what is done off the caller's thread
# (opening, a binary document's text, a painting, an engine's events)
# arrives as an Ev on the channel the caller gave; the caller hands it
# to the view's handle(), on its own thread, and acts on the Note that
# comes back.  Everything else is called on the caller's thread.
#

Sheetview: module {
	PATH: con "/dis/lib/sheetview.dis";

	Fitnone, Fitwidth, Fitpage: con iota;
	GAP: con 12;		# between sheets, and round a column of them

	# A sheet painted at a scale (nil im: it could not be)
	Painted: adt {
		n:	int;
		scale:	int;
		im:	ref Draw->Image;
	};

	# Work done off the caller's thread, for handle()
	Ev: adt {
		v:	ref View;
		gen:	int;
		pick {
		Opened =>
			eng:	Docengine;
			h:	int;	# -1: not opened
			err:	string;
		Text =>
			text:	string;	# a binary document's, read after it is shown
		Painted =>
			n, scale:	int;
			im:	ref Draw->Image;
			err:	string;
		Engine =>
			e:	string;	# docengine(2): events
		}
	};

	# What the caller is to do about an Ev handled, a click or a key.
	# handle() and the calls that move the view do not draw: the caller
	# draws (draw()) when it is showing the view.
	Note: adt {
		pick {
		Redraw =>
		Opened =>	# open: draw it
		Failed =>
			err:	string;
		Text =>		# a binary document's text, or a page's (Loaded)
			text:	string;
		Loaded =>	# a page browsed loaded: its name (a URL) and text
			name:	string;
			text:	string;
		Error =>	# the document's own, not its view's
			err:	string;
		}
	};

	View: adt {
		# set by the caller, and set again as they change
		dst:	ref Draw->Image;	# drawn on
		r:	Draw->Rect;		# the part of dst shown
		bg:	ref Draw->Image;	# round the sheets
		mark:	ref Draw->Image;	# a word selected, what was found
		font:	ref Draw->Font;	# for "Loading" and the like
		style:	ref Docengine->Style;	# a flowing document's fonts and colours

		# the document
		kind:	ref Docreg->Kind;
		name:	string;		# what was opened: a path or a URL
		web:	int;		# a page browsed
		eng:	Docengine;
		h:	int;		# the engine's handle; -1 while it opens
		err:	string;		# why it could not be opened
		gen:	int;		# changes with what is shown; work for another is dropped
		c:	chan of ref Ev;

		# the view
		scale:	int;		# percent of the sheets' size at 100
		rot:	int;		# quarter turns clockwise (not a flowing document)
		dir:	int;		# the way it last moved: 1 down, -1 up (read ahead so)
		fit:	int;		# Fitwidth, Fitpage: the scale follows the rectangle
		org:	Draw->Point;	# the view's top left, in the column
		sizes:	array of Draw->Point;	# the sheets, at scale 100, as the engine has them (unturned)
		tops:	array of int;	# each sheet's top in the column, at scale
		colw, colh:	int;	# the column's size, at scale
		cache:	list of ref Painted;
		painting:	int;
		vw, vh:	int;		# the size the scale and layout were set for
		styled:	ref Docengine->Style;	# the style a flowing document was set in
		word:	string;		# a word selected on the drawing
		wordat:	(int, Draw->Rect);
		findstr:	string;	# what a search is for, in lower case
		found:	list of int;	# the sheets whose text has it

		# opened from data (or, nil, the file or URL name); a page
		# browsed is web.  The engine is loaded and the document
		# opened off the caller's thread: Ev.Opened, then for a binary
		# document Ev.Text.
		open:	fn(v: self ref View, data: array of byte, name: string);
		browse:	fn(v: self ref View, url: string): string;
		close:	fn(v: self ref View);

		handle:	fn(v: self ref View, e: ref Ev): ref Note;

		flowing:	fn(v: self ref View): int;	# set to the width, one sheet
		draw:	fn(v: self ref View);
		layout:	fn(v: self ref View);	# for r, scale and style as they are now
		scroll:	fn(v: self ref View, dy: int);
		pan:	fn(v: self ref View, org: Draw->Point);
		zoom:	fn(v: self ref View, scale: int);
		setfit:	fn(v: self ref View, fit: int);
		gotosheet:	fn(v: self ref View, n: int);
		rotate:	fn(v: self ref View, quarters: int);	# clockwise
		size:	fn(v: self ref View, n: int): Draw->Point;	# sheet n at 100, turned
		sheetat:	fn(v: self ref View, y: int): int;	# at y in the column
		sheetrect:	fn(v: self ref View, n: int): Draw->Rect;	# on dst
		at:	fn(v: self ref View, p: Draw->Point): (int, Draw->Point);	# the sheet and point (the engine's, scale 100) under p

		# the words drawn, where the engine knows them
		wordof:	fn(v: self ref View, n: int, p: Draw->Point): (string, Draw->Rect, int);
		select:	fn(v: self ref View, n: int, word: string, r: Draw->Rect);
		find:	fn(v: self ref View, s: string): string;
		foundon:	fn(v: self ref View, n: int): list of Draw->Rect;

		# an engine's answer to a click or a key: done here
		result:	fn(v: self ref View, res: string): ref Note;

		# Zoom+ Zoom- Zoom n, Fit [page], Page n, NextPage, PrevPage, and
		# the engine's own: 1 if it was one, and why it failed
		command:	fn(v: self ref View, cmd, arg: string): (int, string);
		commands:	fn(v: self ref View): list of string;
	};

	init:	fn(d: ref Draw->Display);
	new:	fn(k: ref Docreg->Kind, name: string, c: chan of ref Ev): ref View;

	# an image scaled, by nearest neighbour (quick) or by averaging
	quickdraw:	fn(dst: ref Draw->Image, r: Draw->Rect, im: ref Draw->Image, src: Draw->Rect);
	boxscale:	fn(im: ref Draw->Image, sz: Draw->Point): ref Draw->Image;
};
