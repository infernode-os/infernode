#
# layout.m - boxes: from a styled document to geometry, and painting.
#
# build() makes the box tree (CSS Display 3): elements generate block,
# inline or atomic boxes according to their display, text generates text
# runs, ::before/::after and list markers generate their boxes, and
# anonymous blocks wrap inline content that sits beside blocks.
#
# lay() gives every box its geometry (CSS 2.2 §9-§10): block formatting
# with margin collapsing, inline formatting into line boxes, and the
# other formatting contexts as they are implemented.  Coordinates are
# relative: a box's x, y are its border box's offset from its parent
# box's border box; a line's and a fragment's are from the box whose
# content they are.
#
# paint() draws a laid-out tree; boxat() finds what is under a point.
#
Layout: module
{
	PATH:	con "/dis/lib/web/layout.dis";

	init:	fn(d: ref Draw->Display): string;
	fontmod:	fn(): Fonts;	# the Fonts instance layout measures with, for @font-face
	# What each <object>'s data turned out to be, told to build before
	# it runs: (node, Oimage or Odoc, url).  An <object> not listed shows
	# its contents instead (its fallback).
	Oimage, Odoc: con 1+iota;
	setobjects:	fn(objs: list of (int, int, string));
	# background and list-style images: what a style asks for, and the
	# decoded images to paint, by absolute URL
	bgurls:	fn(st: ref Style->St): list of string;
	setbgimage:	fn(url: string, img: ref Draw->Image);
	clearbgimages:	fn();

	# box kinds (the formatting a box establishes or takes part in)
	Kblock, Kinline, Ktext, Kbr, Kreplaced, Kflex, Kgrid, Ktable, Krow, Kcell, Kmarker: con iota;

	Box: adt {
		kind:	int;
		inl:	int;		# inline-level (atomic inlines are Kblock etc. with inl set)
		node:	int;		# generating node, 0 if anonymous
		st:	ref Style->St;
		x, y, w, h:	int;	# border box
		mt, mr, mb, ml:	int;	# used margins
		bt, br, bb, bl:	int;	# used borders
		pt, pr, pb, pl:	int;	# used padding
		base:	int;		# atomic inline: baseline offset from the margin-box top
		kids:	cyclic array of ref Box;
		text:	string;		# Ktext, Kmarker
		lines:	cyclic array of ref Line;	# a block container with inline content
		iw, ih:	int;		# replaced: intrinsic size (0 if unknown)
		img:	ref Draw->Image;	# replaced: content, set by whoever loads url
		url:	string;		# replaced: what to load (absolute)
		parent:	cyclic ref Box;
		pos:	cyclic list of ref Box;	# absolutely positioned boxes this one contains
		hint:	int;		# replaced: text is a placeholder, drawn dimmed
		imn, imx:	int;	# min- and max-content widths, cached during one layout
		iex:	int;		# the horizontal edges they include
		igen:	int;		# the layout they were measured in (0: none)
		seq:	int;		# position in tree order once laid out, for painting
		# a subgrid: the tracks, line names and gap of its parent's axis it spans, set by the parent each layout
		subcw, subrh:	array of int;
		subcnames, subrnames:	array of list of string;
		subcgap, subrgap:	int;
		doc:	ref Dom->Doc;	# the root box's document (nil elsewhere)
		tb:	ref Tb;		# a table's collapsed borders, once laid out
		clip:	int;		# content clipped to the border box (a cell crossing a collapsed column)
		fl:	ref Style->St;	# ::first-line's style, if rules give the element one
	};

	# one border of a table's collapsed model: what won at a grid
	# line segment (CSS 2.2 §17.6.2)
	Bd: adt {
		w:	int;
		style:	int;
		color:	int;
		origin:	int;	# 0 cell, 1 row, 2 row group, 3 column, 4 column group, 5 table
	};

	# a table's collapsed borders: the grid lines' positions in its
	# border box and the border at each segment of them
	Tb: adt {
		ncols, nrows:	int;
		cols, rows:	array of int;	# ncols+1, nrows+1 line positions
		v:	array of ref Bd;	# vertical segments: row r, line c at r*(ncols+1) + c
		h:	array of ref Bd;	# horizontal segments: line r, column c at r*ncols + c
		rtl:	int;		# the columns run right to left: logical column c is the (ncols-1-c)th from the left
	};

	Line: adt {
		y, h, base:	int;	# relative to the containing box's border box
		frags:	cyclic array of ref Frag;
		fl:	ref Style->St;	# the ::first-line style that applies to it, if any
	};

	# fragment kinds
	Ftext, Fatomic, Fspan: con iota;

	Frag: adt {
		kind:	int;
		x, y, w, h:	int;	# relative to the containing box's border box
		base:	int;		# Ftext: baseline y
		box:	cyclic ref Box;	# the text run, atomic box, or (Fspan) inline box
		text:	string;
		face:	ref Fonts->Typeface;
		first, last:	int;	# Fspan: this is the box's first/last fragment
		deco:	int;		# Ftext: text-decoration lines, as propagated
		decocolor:	int;
		level:	int;		# bidi embedding level (odd: right to left)
		tls:	int;		# Ftext: the letter spacing after its last character, trimmed at a line's end
	};

	build:	fn(d: ref Dom->Doc, c: ref Style->Computed): ref Box;
	lay:	fn(root: ref Box, width, height: int);
	paint:	fn(root: ref Box, dst: ref Draw->Image, origin: Draw->Point, clip: Draw->Rect);
	height:	fn(root: ref Box): int;		# the page's height, for scrolling
	boxat:	fn(root: ref Box, p: Draw->Point): (int, ref Box);	# node and box under p
	boxes:	fn(root: ref Box, n: int): list of ref Box;	# the boxes node n generated
	dump:	fn(root: ref Box): string;	# "kind node x y w h" per box, indented
};
