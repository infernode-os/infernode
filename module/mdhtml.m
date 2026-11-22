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

	# s with & < > and " as entities, for text or an attribute's value
	escape: fn(s: string): string;
};
