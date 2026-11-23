#
# Mdhtml - Markdown to HTML, as Markdown.pl does it
#
# For pages a browser shows (wercfs(4)): raw HTML is passed through,
# images are images, links and references are links.  Rlayout's
# parsemd is the parser for drawing Markdown; this is the one for
# writing it out as HTML.  See mdhtml(2).
#

Mdhtml: module {
	PATH: con "/dis/lib/mdhtml.dis";

	init: fn();

	# A Markdown document as HTML
	html: fn(text: string): string;

	# The same for text that is not the page's author's: no HTML of
	# the writer's (a tag is its characters), and a link or image goes
	# only to http, https, mailto or a place with no scheme; any other
	# is left as it was written.  What it gives can be put in a page
	# beside the site's own.
	htmlsafe: fn(text: string): string;

	# s with & < > and " as entities, for text or an attribute's value
	escape: fn(s: string): string;
};
