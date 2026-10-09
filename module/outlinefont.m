#
# OutlineFont - vector outline font rendering
#
# General-purpose module for parsing and rendering outline fonts.
# Consumers provide raw font program bytes; the module returns
# rendered glyphs and metrics.  Decoupled from PDF — usable by
# any application that needs vector text rendering.
#
# Currently supports CFF (Compact Font Format / Type 2).
#

OutlineFont: module {
	PATH: con "/dis/lib/outlinefont.dis";

	init:	fn(d: ref Draw->Display);

	# Parse font from raw data.  format: "cff" or "ttf"
	open:	fn(data: array of byte, format: string): (ref Face, string);
	# A TrueType variable font (fvar, gvar) at the axis values given in
	# user units, ("wght", 700.0) and the like; the face itself when it
	# has no axes.  axes() lists them: (tag, min, default, max).
	vary:	fn(f: ref Face, values: list of (string, real)): ref Face;
	axes:	fn(f: ref Face): list of (string, real, real, real);

	Face: adt {
		nglyphs:	int;	# number of glyphs
		upem:		int;	# units per em
		ascent:		int;	# in font units
		descent:	int;	# in font units (negative)
		name:		string;	# font name from the font program
		iscid:		int;	# 1 if CID-keyed font

		# Map CID to GID (for CID-keyed fonts).  Returns -1 if not found.
		cidtogid:	fn(f: self ref Face, cid: int): int;

		# GID for a character via cmap, or -1 if the font has no glyph for it.
		lookup:	fn(f: self ref Face, charcode: int): int;

		# Map character code to GID via cmap (TrueType).  Identity for CFF.
		chartogid:	fn(f: self ref Face, charcode: int): int;

		# Render glyph at given size.  Returns advance width in pixels.
		drawglyph:	fn(f: self ref Face, gid: int, size: real,
				   dst: ref Draw->Image, p: Draw->Point,
				   src: ref Draw->Image): int;

		# Get glyph advance width in pixels at given size
		glyphwidth:	fn(f: self ref Face, gid: int, size: real): int;

		# Unrounded advance width in pixels (for text layout)
		advance:	fn(f: self ref Face, gid: int, size: real): real;

		# Kerning between two glyphs ('kern' table), in font units
		kern:	fn(f: self ref Face, left, right: int): int;

		# GSUB.  ligatures() applies the ligature lookups of the
		# features named (e.g. "liga", "clig", "rlig") to a run of
		# glyphs, in the order given; subst() is a single substitution
		# under a feature ("init", "medi", "fina", "isol"), or gid;
		# hasfeature() says whether the font has the feature at all.
		# with, for each glyph returned, how many of the given glyphs it stands for
		ligatures:	fn(f: self ref Face, gids: array of int, feats: list of string): (array of int, array of int);
		subst:	fn(f: self ref Face, feat: string, gid: int): int;
		hasfeature:	fn(f: self ref Face, feat: string): int;

		# GPOS.  markanchor() places a combining mark on its base: the
		# mark's origin relative to the base's, in font units, or ok 0
		# when the font attaches no such pair.  kern() above consults
		# GPOS pair adjustment when there is no 'kern' table.
		markanchor:	fn(f: self ref Face, base, mark: int): (int, int, int);

		# The glyph's top (yMax), in font units; 0 if unknown (CFF)
		ymax:	fn(f: self ref Face, gid: int): int;

		# OS/2 xAvgCharWidth and the width of head's bounding box
		# (xMax - xMin), in font units; 0 where the font has none (CFF)
		xmetrics:	fn(f: self ref Face): (int, int);

		# Get scaled metrics: (height, ascent, descent) in pixels
		metrics:	fn(f: self ref Face, size: real): (int, int, int);
	};
};
