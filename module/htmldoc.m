#
# Htmldoc - HTML set by Charon's engine (browser(2)) for Xenith.
#
# A window's HTML is a page held here under the window's id, so
# Xenith need not include the engine's interfaces: Render on an HTML
# file sets its text (unsaved edits too) as a page and paints the part
# in view; Render opening a URL takes the whole page as an image.
#
Htmldoc: module
{
	PATH:	con "/dis/xenith/render/htmldoc.dis";

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
};
