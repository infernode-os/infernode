#
# fonts.m - faces for the web engine.
#
# face() maps a computed style's font-family list, weight, style and
# size to a face: one of the shipped TrueType families (DejaVu Sans,
# Serif and Sans Mono, in four styles each, under /fonts/ttf/dejavu),
# drawn from outlines at exactly the size asked for.  Characters a face
# lacks fall back to the bitmap Unicode font, which covers CJK and
# symbols.  Faces are cached; glyphs are cached by outlinefont(2).
#
Fonts: module
{
	PATH:	con "/dis/lib/web/fonts.dis";
	DIR:	con "/fonts/ttf/dejavu";

	init:	fn(d: ref Draw->Display): string;

	Typeface: adt {
		outline:	ref OutlineFont->Face;
		size:	real;		# px
		ascent, descent:	real;	# px, both positive
		normal:	real;		# line-height: normal, px
		space:	real;		# width of U+0020
		fallback:	ref Draw->Font;
		parts:	array of ref Part;	# a web family: its faces, by unicode-range
		next:	cyclic ref Typeface;	# the next family, for what this one lacks
		nokern:	int;		# kerning off

		width:	fn(f: self ref Typeface, s: string): real;
		has:	fn(f: self ref Typeface, c: int): int;	# a glyph for c, in it or its fallbacks (not the bitmap fallback)
		ligspan:	fn(f: self ref Typeface, a, b: string): int;	# how many characters of b a ligature begun in a takes
		xheight:	fn(f: self ref Typeface): real;
		kernpair:	fn(f: self ref Typeface, a, b: int): real;	# px between the characters a and b	# px: the top of "x" (the ex unit)
		draw:	fn(f: self ref Typeface, dst: ref Draw->Image, p: Draw->Point, s: string, src: ref Draw->Image, rtl: int): real;	# p is on the baseline; s in logical order, drawn from the right if rtl
	};

	# one face of a web font family, for the code points in ranges
	# (pairs, inclusive; nil for all)
	Part: adt {
		outline:	ref OutlineFont->Face;
		ranges:	array of int;
	};

	face:	fn(family: list of string, weight, italic: int, size: real): ref Typeface;

	# the face's average character width (OS/2 xAvgCharWidth) and the
	# width of its bounding box, in pixels; 0 where the font has none
	xmetrics:	fn(f: ref Typeface): (real, real);

	# @font-face: register a downloaded face (TrueType, OpenType or WOFF;
	# family lower case) for this module instance's documents.
	addface:	fn(family: string, weight, italic: int, ranges: array of int, data: array of byte): string;
	clearfaces:	fn();
};
