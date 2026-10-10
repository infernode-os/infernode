#
# Docview - a window's document: the one view for every kind
#
# A document (a PDF, an image, a Mermaid diagram, Markdown or HTML set
# for reading, a web page) is held by its engine (docengine(2)); the
# window's view stacks its sheets in a column, scrolls it, zooms it
# (painted again at the scale, the old painting scaled meanwhile) and
# pans it. See docs/xenith-documents.md.
#

Docview: module {
	PATH: con "/dis/xenith/docview.dis";

	Fitnone, Fitwidth, Fitpage: con iota;

	# A sheet painted at a scale
	Painted: adt {
		n:	int;
		scale:	int;
		im:	ref Draw->Image;
	};

	# A window's document
	Doc: adt {
		kind:	ref Docreg->Kind;
		eng:	Docengine;
		h:	int;		# the engine's handle; -1 while it opens
		name:	string;		# what was opened: a path or a URL
		web:	int;		# a page browsed: a browser window
		err:	string;		# why it could not be shown
		shown:	int;		# the document (not its text) is in the window
		gen:	int;		# changes with what is shown; work for another is dropped
		scale:	int;		# percent of the sheets' size at 100
		fit:	int;		# Fitwidth or Fitpage: the scale follows the window
		org:	Draw->Point;	# the view's top left, in the column
		sizes:	array of Draw->Point;	# the sheets, at scale 100
		tops:	array of int;	# each sheet's top in the column, at scale
		colw:	int;		# the column's width and height, at scale
		colh:	int;
		cache:	list of ref Painted;
		painting:	int;	# a sheet is being painted
		vw:	int;		# the view's size the scale and layout were set for
		vh:	int;
		bg:	ref Draw->Image;	# the colours a flowing document was set in
		fg:	ref Draw->Image;
		accent:	ref Draw->Image;
		offb:	ref Draw->Image;	# where the body's text draws meanwhile, unseen
		word:	string;		# a word selected on the drawing
		wordat:	(int, Draw->Rect);
		findstr:	string;		# what a search is for, in lower case
		found:	list of int;	# the sheets whose text has it (where on them is
					# worked out as they are drawn)
	};

	init:	fn(mods: ref Dat->Mods);

	# The kind of document a file is, by its name and first bytes,
	# or nil if it is to be shown as text
	kind:	fn(name: string): ref Docreg->Kind;

	# Show a file as a document in w: a binary document (PDF, image)
	# from the file; a source document (Markdown, HTML, Mermaid) from
	# the window's text, unsaved changes and all
	open:	fn(w: ref Windowm->Window, name: string, k: ref Docreg->Kind): string;
	browse:	fn(w: ref Windowm->Window, url: string): string;

	# Render: the document, or its text
	render:	fn(w: ref Windowm->Window): string;

	# Done with it: the window shows its text again; or, for a window
	# going away, just let go
	close:	fn(w: ref Windowm->Window);
	release:	fn(w: ref Windowm->Window);

	# The document is in the window (not its text)
	shown:	fn(w: ref Windowm->Window): int;

	# A binary document or a web page: its text is not edited
	readonly:	fn(w: ref Windowm->Window): int;

	draw:	fn(w: ref Windowm->Window);
	scroll:	fn(w: ref Windowm->Window, dy: int);
	key:	fn(w: ref Windowm->Window, r: int): int;
	textchanged:	fn(w: ref Windowm->Window);

	# The mouse on the document: button 1 drags it (grab and pan),
	# or clicked selects the word there; button 2 executes the word;
	# button 3 follows the link or looks at the word
	button1:	fn(w: ref Windowm->Window);
	button2:	fn(w: ref Windowm->Window): (string, int);
	button3:	fn(w: ref Windowm->Window): (string, string);
	wheel:	fn(w: ref Windowm->Window, buttons: int);
	scrollclick:	fn(w: ref Windowm->Window, but: int, y: int);

	# Zoom+ Zoom- Zoom n, Fit, Fit page, Page n, NextPage, PrevPage,
	# and the engine's own: 1 if it was one
	command:	fn(w: ref Windowm->Window, cmd, arg: string): (int, string);
	commands:	fn(w: ref Windowm->Window): string;

	# The document's files (doc/ in the window's directory)
	ctlread:	fn(w: ref Windowm->Window): string;
	ctlwrite:	fn(w: ref Windowm->Window, s: string): string;
	textread:	fn(w: ref Windowm->Window): string;
	linksread:	fn(w: ref Windowm->Window): string;
	find:	fn(w: ref Windowm->Window, s: string): string;
	foundread:	fn(w: ref Windowm->Window): string;
	filesof:	fn(w: ref Windowm->Window): string;

	# Results from the work done off the main loop
	opened:	fn(w: ref Windowm->Window, gen: int, eng: Docengine, h: int, text: string, err: string);
	texted:	fn(w: ref Windowm->Window, gen: int, text: string);
	painted:	fn(w: ref Windowm->Window, gen: int, n, scale: int, im: ref Draw->Image, err: string);
	event:	fn(w: ref Windowm->Window, gen: int, e: string);
};
