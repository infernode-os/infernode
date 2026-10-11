#
# Docview - a window's document: the one view for every kind
#
# A document (a PDF, an image, a Mermaid diagram, Markdown or HTML set
# for reading, a web page) is held by its engine (docengine(2)) and
# shown by the view every program that shows documents shares
# (sheetview(2)), in the window's body.  This module is Xenith's side:
# the window's text, its tag, its doc/ files, the mouse and keys.  See
# docs/xenith-documents.md.
#

Docview: module {
	PATH: con "/dis/xenith/docview.dis";

	# A window's document
	Doc: adt {
		v:	ref Sheetview->View;
		shown:	int;		# the document (not its text) is in the window
		offb:	ref Draw->Image;	# where the body's text draws meanwhile, unseen
		line:	int;		# a source document's line to open at, or -1
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

	# The views' work done off the main loop arrives on events(), to
	# be handed to handle() on it
	events:	fn(): chan of ref Sheetview->Ev;
	handle:	fn(e: ref Sheetview->Ev);
};
