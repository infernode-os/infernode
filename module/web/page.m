#
# page.m - a web page: fetched, parsed, styled, laid out, painted.
#
# The pipeline glued together.  open() fetches a document and what it
# needs (style sheets, @imports, images), and lays it out for a
# viewport; paint() draws any part of it.  Fetching goes through
# fetch(): file: and data: URLs directly, http: and https: through
# webfs at /mnt/web, so what a page can reach is what the namespace
# has mounted there.
#
Page: module
{
	PATH:	con "/dis/lib/web/page.dis";
	WEBFS:	con "/mnt/web";

	init:	fn(d: ref Draw->Display): string;

	Pg: adt {
		url:	string;		# after redirects and <base>
		doc:	ref Dom->Doc;
		styles:	ref Style->Styles;
		computed:	ref Style->Computed;
		root:	ref Layout->Box;
		env:	ref Style->Env;
		title:	string;
		width, height:	int;	# viewport
		errors:	list of string;	# what could not be fetched, most recent first
		objects:	list of (int, int, string);	# <object>s that render (see Layout->setobjects)
		pics:	list of ref Pic;	# the images it has, decoded

		relayout:	fn(p: self ref Pg, width, height: int);
		update:	fn(p: self ref Pg);	# restyle and relayout after the document changed
		target:	fn(p: self ref Pg, fragment: string): int;	# make the element a #fragment names the :target; its y
		paint:	fn(p: self ref Pg, dst: ref Draw->Image, scroll: Draw->Point);
		pageheight:	fn(p: self ref Pg): int;
		# progressively: the URLs of images it shows and has not got,
		# then those that have come, laid out with them
		wanted:	fn(p: self ref Pg): list of string;
		install:	fn(p: self ref Pg, pics: list of ref Pic);
		frames:	fn(p: self ref Pg);	# fetch and draw its <iframe>s
	};

	# an image fetched and decoded; img nil and err set if it failed
	Pic: adt {
		url:	string;
		img:	ref Draw->Image;
		svg:	array of byte;	# an SVG image's source, to draw again at another size
		err:	string;
	};

	open:	fn(url: string, width, height: int): (ref Pg, string);
	# a form submission: method "GET" or "POST", body sent with ctype
	request:	fn(url, method, ctype: string, body: array of byte, width, height: int): (ref Pg, string);
	# the document and its style sheets, laid out with no images yet;
	# open and request are begin, every image wanted, then frames
	begin:	fn(url, method, ctype: string, body: array of byte, width, height: int): (ref Pg, string);
	picture:	fn(url: string, data: array of byte, ctype, err: string): ref Pic;
	fetch:	fn(url: string): (array of byte, string, string);	# (data, content type, error)
	decodeimage:	fn(data: array of byte, ctype, url: string): ref Draw->Image;
};
