#
# Htmldoc - HTML set by Charon's engine (browser(2)) for Xenith.
#
# A window's HTML is a page held here under the window's id, so
# Xenith need not include the engine's interfaces: Render on an HTML
# file sets its text (unsaved edits too) as a page and paints the part
# in view; a URL opened in Xenith is browsed, the window a browser
# window: links followed in it, back and forward through what it has
# shown.
#
Htmldoc: module
{
	PATH:	con "/dis/xenith/render/htmldoc.dis";

	# A form control on a browsed page (browser(2)'s Field, with its box)
	Field: adt {
		node:	int;
		form:	int;	# 1.. in document order; 0 for one in no form
		kind:	string;	# text, password, checkbox, radio, submit, select, textarea, ...
		name:	string;
		value:	string;
		checked:	int;
		options:	list of (string, string, int);	# select: (value, label, selected)
		box:	Draw->Rect;	# page coordinates
	};

	init:	fn(d: ref Draw->Display): string;

	# Set id's page to data, as the document at url (relative links,
	# style sheets and images are found from there), width wide;
	# returns the page's height, or an error.
	set:	fn(id: int, data: array of byte, url: string, width, height: int): (int, string);

	# id's page from y down, into dst.r.
	paint:	fn(id: int, dst: ref Draw->Image, y: int);

	# The URL of the link at x, y (page coordinates), or nil.
	linkat:	fn(id: int, x, y: int): string;

	# id's page as text, one block per line.
	text:	fn(id: int): string;

	# Forget id's page.
	drop:	fn(id: int);

	# Browse: id's page becomes the one at url, fetched in the
	# background (http: and https: through webfs at /mnt/web, which is
	# started if nothing is mounted there), keeping what id showed
	# before in its history.  The first call for id returns a channel
	# of the page's events, "loading url", "done url", "error message"
	# and "stopped", which the caller reads until it drops the page;
	# later calls return nil.
	browse:	fn(id: int, url: string, width, height: int): (chan of string, string);

	# What is at x, y (page coordinates) clicked: a link followed, a
	# button pressed, a box checked.  0 if nothing there takes a click.
	click:	fn(id: int, x, y: int): (int, string);

	back:	fn(id: int): string;
	forward:	fn(id: int): string;
	reload:	fn(id: int): string;
	stop:	fn(id: int): string;

	# id's page: its URL, its title, its height laid out, and where
	# its last navigation asks the view to be (a #fragment's y).
	url:	fn(id: int): string;
	title:	fn(id: int): string;
	height:	fn(id: int): int;
	scroll:	fn(id: int): int;

	# Lay id's page out again, width wide.
	resize:	fn(id: int, width, height: int);

	# id's page's form controls, in document order.
	fields:	fn(id: int): array of ref Field;

	# A control's value set (a select's: an option's value), the page
	# laid out again with it.
	setfield:	fn(id: int, node: int, value: string): string;

	# A form submitted, as its submit button would (the page loads in
	# the background: an event follows).
	submit:	fn(id: int, form: int): string;
};
