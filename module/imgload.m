#
# imgload - read an image file of any format the system decodes
#
# One place that decides what a file is and which decoder reads it, so
# every program shows the same formats: Xenith, the browser, wm/view,
# lib/scene.  The format comes from the data (a file's leading bytes)
# and, where the data says nothing (SVG, PPM by extension alone), from
# the name.  Large PNGs and PPMs are subsampled as they decode, so a
# photograph does not need its full size in memory.
#
# The decoders themselves are the RImagefile modules of imagefile.m;
# a program that wants every frame of an animation, or a transparency
# mask, asks for the decoder with reader() and drives it itself.
#
Imgload: module {
	PATH: con "/dis/lib/imgload.dis";

	# Progress callback info for progressive decoding
	ImgProgress: adt {
		image: ref Draw->Image;  # Image being decoded
		rowsdone: int;           # Rows decoded so far
		rowstotal: int;          # Total rows
	};

	init: fn(d: ref Draw->Display);

	# The format of an image, from its first bytes (512 find an SVG
	# behind an XML prologue) and its name: "png", "jpeg", "gif", "webp",
	# "avif", "svg", "ppm" (PGM too), "xbm", "pic", "bit" (an
	# Inferno image, image(6)), or nil if neither says.
	format: fn(head: array of byte, name: string): string;

	# Whether a file name has the extension of a format this module
	# reads.  For programs deciding, before opening it, whether a
	# file is an image.  This, format and extensions need no init.
	isimage: fn(name: string): int;

	# Every such extension, with its dot, separated by spaces.
	extensions: fn(): string;

	# The decoder for a format, a new instance loaded and initialised.  PPM and
	# Inferno images have none: this module reads them itself.
	reader: fn(fmt: string): (RImagefile, string);

	readimage: fn(path: string): (ref Draw->Image, string);
	readimagedata: fn(data: array of byte, hint: string): (ref Draw->Image, string);

	# Progressive image decode - sends progress updates to channel
	# Returns (image, error) when complete
	readimagedataprogressive: fn(data: array of byte, hint: string,
	                             progress: chan of ref ImgProgress): (ref Draw->Image, string);
};
