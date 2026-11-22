#
# Visrec: what vision(1)'s commands share (#1086): records and pictures.
#
# A record is one line of attr=value fields (docs/9p-data-conventions.md),
# a value with blanks or quotes in it quoted as sh quotes. A box is a
# record with x0 y0 x1 y1 (pixels; x0 y0 inside, x1 y1 just past), named
# by label=, or else by class= and score=.
#
# Pictures are Draw->RGB24 pixels, blue, green, red in memory, w by h,
# as Visnet->readpixels gives them. Nothing here needs a display.
#
Visrec: module
{
	PATH:	con	"/dis/lib/visrec.dis";

	Rec: adt {
		kv:	list of (string, string);	# in the order written

		get:	fn(r: self ref Rec, k: string): string;
		# the box, if the record is one: (x0, y0, x1, y1, ok)
		box:	fn(r: self ref Rec): (int, int, int, int, int);
		# what to write by a box: label=, or class= and score=
		label:	fn(r: self ref Rec): string;
		text:	fn(r: self ref Rec): string;
	};

	init:	fn(): string;
	parse:	fn(line: string): ref Rec;
	# fields as a record line, without a newline
	format:	fn(kv: list of (string, string)): string;

	# boxes drawn on a picture, each with its label above it, in a
	# colour chosen by its name
	drawbox:	fn(pix: array of byte, w, h: int, x0, y0, x1, y1: int, label: string);
	# a box's pixels, as a picture of its own: (pixels, w, h)
	crop:	fn(pix: array of byte, w, h: int, x0, y0, x1, y1: int): (array of byte, int, int);

	# a picture as an uncompressed image(6) file, r8g8b8, or as a PNG
	writeimage:	fn(fd: ref Sys->FD, pix: array of byte, w, h: int): string;
	writepng:	fn(fd: ref Sys->FD, pix: array of byte, w, h: int): string;
};
