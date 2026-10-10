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
		asked:	list of string;	# images clicked for, with images click
		allimages:	int;	# every image wanted, whatever the setting

		relayout:	fn(p: self ref Pg, width, height: int);
		update:	fn(p: self ref Pg);	# restyle and relayout after the document changed
		restyle:	fn(p: self ref Pg);	# restyle only (computed styles for a script), the layout as it was
		target:	fn(p: self ref Pg, fragment: string): int;	# make the element a #fragment names the :target; its y
		paint:	fn(p: self ref Pg, dst: ref Draw->Image, scroll: Draw->Point);
		pageheight:	fn(p: self ref Pg): int;
		# progressively: the URLs of images it shows and has not got,
		# then those that have come, laid out with them
		wanted:	fn(p: self ref Pg): list of string;
		install:	fn(p: self ref Pg, pics: list of ref Pic);
		frames:	fn(p: self ref Pg);	# fetch and draw its <iframe>s
		# with images click: the URLs of the images shown where node n's
		# image is (it and any it overlays) that have not come, wanted
		# from now on; nil if n shows none to get
		want:	fn(p: self ref Pg, n: int): list of string;
		wantall:	fn(p: self ref Pg);	# every image wanted, as with images on
	};

	# The engine's settings, for everything that uses it (Charon,
	# Xenith's Render), one line each as Charon's ctl takes them:
	#	images on | click	click: an image loads when clicked; data:
	#				and file: images, which cost no fetch, always do
	#	fonts web | system	system: no @font-face fonts are fetched
	#	effects on | off	off: no shadows or filters are drawn
	#	scripts on | off	on: a page's scripts run, each page's in a
	#				realm confined to the network (Browser; jsdom.m)
	# The user's settings file holds the same lines.  It is read when
	# the module starts and again when it has changed, so a setting
	# saved by one program reaches the others.
	SETTINGS:	con "lib/charon/settings";	# in the user's home, /usr/<user>
	setting:	fn(name: string): string;
	set:	fn(line: string): string;	# "name value"; nil, or what is wrong with it
	settings:	fn(): string;		# every setting, a line each
	save:	fn(): string;		# the settings, into the user's file

	# an image fetched and decoded; img nil and err set if it failed
	Pic: adt {
		url:	string;
		img:	ref Draw->Image;
		svg:	array of byte;	# an SVG image's source, to draw again at another size
		err:	string;
		raw:	ref Draw->Image;	# as stored, when its EXIF orientation turned img; nil if it did not (image-orientation: none)
		nw, nh:	int;		# its natural size; img may hold fewer pixels, at the size it is shown
		data:	array of byte;	# a raster image's encoded bytes, to decode again larger
		ctype:	string;
	};

	open:	fn(url: string, width, height: int): (ref Pg, string);
	# a form submission: method "GET" or "POST", body sent with ctype
	request:	fn(url, method, ctype: string, body: array of byte, width, height: int): (ref Pg, string);
	# the document and its style sheets, laid out with no images yet;
	# open and request are begin, every image wanted, then frames
	begin:	fn(url, method, ctype: string, body: array of byte, width, height: int): (ref Pg, string);
	# a document already in hand, as if fetched from url with content type ctype
	parse:	fn(data: array of byte, ctype, url: string, width, height: int): ref Pg;
	picture:	fn(url: string, data: array of byte, ctype, err: string): ref Pic;
	fetch:	fn(url: string): (array of byte, string, string);	# (data, content type, error)
	# fetch, saying an image will do: image/webp first, as browsers do
	fetchimage:	fn(url: string): (array of byte, string, string);
	decodeimage:	fn(data: array of byte, ctype, url: string): ref Draw->Image;
};
