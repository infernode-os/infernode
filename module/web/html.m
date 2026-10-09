#
# html.m - the HTML parser.
#
# parse() turns a byte stream into a document tree, following the
# WHATWG HTML tokenizer and tree-construction algorithms (HTML §13.2):
# implied and misnested tags, the adoption agency, foster parenting,
# tables, templates and SVG/MathML foreign content all come out as a
# browser would build them.  Scripts are kept in the tree, not run.
#
# Departures from the standard are listed at the top of html.b.
#
Html: module
{
	PATH:	con "/dis/lib/web/html.dis";

	init:	fn();

	# charset is from the transport (Content-Type) and may be nil;
	# otherwise the byte-order mark and <meta charset> decide, and
	# UTF-8 is the default.
	parse:	fn(data: array of byte, charset, url: string): ref Dom->Doc;
	parsestring:	fn(s, url: string): ref Dom->Doc;
	# An XML document (application/xhtml+xml, image/svg+xml): no
	# HTML parsing rules, CDATA sections, <x/> closes, namespaces map
	# XHTML, SVG and MathML elements to theirs.  Not validating, and
	# lenient where browsers would show an error page.
	parsexml:	fn(data: array of byte, charset, url: string): ref Dom->Doc;

	charset:	fn(data: array of byte, transport: string): string;	# the sniffing used by parse

	# A stylesheet's text (CSS Syntax 3 §3.2): from its byte order mark,
	# else the transport's charset, else its @charset rule, else the
	# referring element's charset attribute (hint), else the document's
	# encoding (docs), else UTF-8.
	cssdecode:	fn(data: array of byte, transport, hint, docs: string): string;
};
