#
# browser.m - a browsing session: the page being shown, how it got
# there, and what can be done to it.
#
# A Session is what a browser window is, without the window: history,
# navigation, form state, and the views of the page that a reader who
# is not looking at pixels wants (its text, links and form fields).
# The Tk front end and /mnt/charon (charonfs) are both clients of one.
#
# Navigation is asynchronous: open() starts a load and returns, and
# the session announces "loading <url>", then "shown <url>" once the
# document is laid out, "update <got> <of>" as its images arrive and
# it is laid out again with them, and "done <url>" (or "error <msg>")
# to its listeners.  A newer navigation supersedes one still loading.
#
# Form state is the document: setting a field changes its value,
# checked or selected attribute (or a textarea's text), and the page
# restyles and relays out.
#
Browser: module
{
	PATH:	con "/dis/lib/web/browser.dis";

	init:	fn(d: ref Draw->Display): string;

	Link: adt {
		node:	int;
		url:	string;	# absolute
		text:	string;
	};

	Field: adt {
		form:	int;	# 1.. in document order; 0 for a control in no form
		node:	int;
		kind:	string;	# text, password, checkbox, radio, submit, select, textarea, ...
		name:	string;
		value:	string;
		checked:	int;	# checkbox, radio
		options:	list of (string, string, int);	# select: (value, label, selected)
	};

	Session: adt {
		pg:	ref Page->Pg;	# nil until something has loaded
		url:	string;
		title:	string;
		status:	string;	# "", "loading <url>", "loading images <url>", "done", "error <msg>"
		back, fwd:	list of string;
		width, height:	int;
		scroll:	int;	# where the last navigation asks the view to be (a #fragment)
		gen:	int;
		lk:	chan of int;
		listeners:	list of chan of string;

		new:	fn(width, height: int): ref Session;
		open:	fn(s: self ref Session, url: string);
		# data as the page at url, now: an editor's preview of a
		# file, or a document a program made.  No history is kept
		# for a page shown again at the same URL, and the view stays
		# where it was (scroll is not reset).
		show:	fn(s: self ref Session, data: array of byte, ctype, url: string): string;
		goback:	fn(s: self ref Session): string;
		goforward:	fn(s: self ref Session): string;
		reload:	fn(s: self ref Session);
		stop:	fn(s: self ref Session);
		resize:	fn(s: self ref Session, width, height: int);
		listen:	fn(s: self ref Session): chan of string;
		unlisten:	fn(s: self ref Session, c: chan of string);

		text:	fn(s: self ref Session): string;	# one block per line
		links:	fn(s: self ref Session): array of ref Link;
		fields:	fn(s: self ref Session): array of ref Field;
		find:	fn(s: self ref Session, what: string): string;	# lines of text() containing it
		set:	fn(s: self ref Session, node: int, value: string): string;
		submit:	fn(s: self ref Session, form, submitter: int): string;
		follow:	fn(s: self ref Session, n: int): string;	# links()[n-1]
		click:	fn(s: self ref Session, node: int): string;	# a link, button or control; an image not yet loaded (Page's images click)
		images:	fn(s: self ref Session);	# load every image the page has, whatever the setting
		# change one of the engine's settings ("images click"), and the
		# page with it: images on loads what it lacks, fonts loads it
		# again, effects draws it again
		configure:	fn(s: self ref Session, line: string): string;
		nodeat:	fn(s: self ref Session, x, y: int): int;	# page coordinates
		paint:	fn(s: self ref Session, dst: ref Draw->Image, scroll: Draw->Point);
		boxof:	fn(s: self ref Session, n: int): (int, Draw->Rect);	# node n's first border box, page coordinates
		linkat:	fn(s: self ref Session, x, y: int): string;	# the URL of the link under a point
		findat:	fn(s: self ref Session, what: string, after: int): (int, Draw->Rect);	# next text match below y=after
		pageheight:	fn(s: self ref Session): int;
		dom:	fn(s: self ref Session, n: int, what: string): (string, string);	# tag attrs text style box children
	};

	# the engine's settings (Page->setting and the rest, for the page
	# module this one uses)
	setting:	fn(name: string): string;
	settings:	fn(): string;
	savesettings:	fn(): string;

	resolve:	fn(base, rel: string): string;
	linkstext:	fn(l: array of ref Link): string;	# "n url text" lines
	fieldstext:	fn(f: array of ref Field): string;	# "form node kind name value [checked]" lines
};
