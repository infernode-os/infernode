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
		embolden:	int;	# synthetic bold: each glyph drawn again this many pixels to its right
		feats:	list of (string, int);	# OpenType features set over the defaults (font-variant, font-feature-settings): (tag, value), later replacing earlier
		fkey:	string;		# names feats and lang
		lang:	string;		# font-language-override: the OpenType language system ("TRK "), or nil

		width:	fn(f: self ref Typeface, s: string): real;
		has:	fn(f: self ref Typeface, c: int): int;	# a glyph for c, in it or its fallbacks (not the bitmap fallback)
		ligspan:	fn(f: self ref Typeface, a, b: string): int;	# how many characters of b a ligature begun in a takes
		xheight:	fn(f: self ref Typeface): real;
		kernpair:	fn(f: self ref Typeface, a, b: int): real;	# px between the characters a and b	# px: the top of "x" (the ex unit)
		draw:	fn(f: self ref Typeface, dst: ref Draw->Image, p: Draw->Point, s: string, src: ref Draw->Image, rtl: int): real;	# p is on the baseline; s in logical order, drawn from the right if rtl
		drawat:	fn(f: self ref Typeface, dst: ref Draw->Image, p: Draw->Point, dx: real, s: string, src: ref Draw->Image, rtl: int): real;	# as draw, from dx (a fraction) past p: each glyph is placed by its own position from there, rounded once
	};

	# one face of a web font family, for the code points in ranges
	# (pairs, inclusive; nil for all)
	Part: adt {
		outline:	ref OutlineFont->Face;
		ranges:	array of int;
		feats:	list of (string, int);	# its @font-face font-feature-settings, under the Typeface's
		fkey:	string;
	};

	face:	fn(family: list of string, weight, italic: int, size: real): ref Typeface;
	# f with the OpenType features set (tag, value; value 0 turns one
	# off, n > 1 chooses an alternate) over the defaults (Fonts 4
	# §7.1: ccmp, locl, rlig, calt, clig, liga, kern, mark, mkmk), nokern
	# for font-kerning: none (a setting of "kern" replaces it), lang
	# font-language-override's OpenType language system or nil; the
	# same Typeface for the same arguments
	features:	fn(f: ref Typeface, feats: list of (string, int), nokern: int, lang: string): ref Typeface;
	# @font-feature-values (Fonts 4 §6.9.1): the values a family gives
	# name for a kind of alternate ("styleset", "swash", ...); add
	# replaces what was there; clearfaces forgets them all
	addfeaturevalues:	fn(family, kind, name: string, vals: array of int);
	featurevalues:	fn(family, kind, name: string): array of int;
	# the same with what a variable web face's axes take besides the
	# weight (Fonts 4 §7.2): style (0 normal, 1 italic, 2 oblique) and
	# oblique's angle in degrees, font-stretch (a percentage), and
	# font-variation-settings, (axis tag, value), which override them;
	# synth, font-synthesis's bits (1 weight, 2 style): a bold the
	# family has no face heavy enough for is made up
	facevar:	fn(family: list of string, weight, style: int, slant, stretch, size: real, vars: list of (string, real), synth: int): ref Typeface;

	# what an @font-face rule says of its face (Fonts 4 §4): ranges of
	# weight and stretch (0, 0 for auto: the font's own), its style
	# (-1 auto, 0 normal, 1 italic, 2 oblique amin to amax degrees), and
	# its font-variation-settings
	Desc: adt {
		wmin, wmax:	int;
		smin, smax:	real;
		style:	int;
		amin, amax:	real;
		vars:	list of (string, real);
		feats:	list of (string, int);	# font-feature-settings
	};

	# the face's average character width (OS/2 xAvgCharWidth) and the
	# width of its bounding box, in pixels; 0 where the font has none
	xmetrics:	fn(f: ref Typeface): (real, real);

	# @font-face: register a downloaded face (TrueType, OpenType or WOFF;
	# family lower case) for this module instance's documents.
	addface:	fn(family: string, weight, italic: int, ranges: array of int, data: array of byte): string;
	addfacedesc:	fn(family: string, d: ref Desc, ranges: array of int, data: array of byte): string;
	# Forget the downloaded faces, and give them back: they are closed
	# (OutlineFont's Face.close) once nothing draws with them.
	clearfaces:	fn(): list of ref OutlineFont->Face;
	closefaces:	fn(l: list of ref OutlineFont->Face);
};
