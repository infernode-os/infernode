#
# Troffpage - troff's output, its pages drawn
#
# troff(1) writes a device-independent description of its pages
# (troff(6)); this reads one and paints its pages, sharp at any
# scale, with the outline fonts its device's font descriptions name
# (outlinefont(2)), and finds their text, words and links.
#
# Sizes and points are in points: a page is painted at scale 1.0
# with 72 pixels to the inch.
#

Troffpage: module
{
	PATH:	con "/dis/lib/troffpage.dis";

	# a word as set, where it is on its page
	Word: adt {
		text:	string;
		r:	Draw->Rect;
	};

	# a link, where it is
	Link: adt {
		page:	int;
		r:	Draw->Rect;
		url:	string;
	};

	Doc: adt {
		dev:	string;		# the device it was set for
		res:	int;		# its units to the inch
		width:	int;		# the pages' size, in points
		height:	int;
		npages:	int;
		x:	int;		# private

		# page n (from 0) at scale into r of dst, the point org of the
		# scaled page at r.min
		paint:	fn(d: self ref Doc, n: int, scale: real, dst: ref Draw->Image,
				r: Draw->Rect, org: Draw->Point): string;
		text:	fn(d: self ref Doc, n: int): string;
		words:	fn(d: self ref Doc, n: int): array of Word;
		links:	fn(d: self ref Doc, n: int): array of Link;
		close:	fn(d: self ref Doc);
	};

	init:	fn(d: ref Draw->Display): string;

	# A document from troff's output; fontdir is the directory of
	# the device's descriptions (nil: /lib/troff/dev and its name).
	# Its pages are the size papersize names in it (x X papersize
	# WxH, in points), else letter, or A4 if its page length is.
	open:	fn(data: array of byte, fontdir: string): (ref Doc, string);

	# Whether data begins as troff's output does
	istroff:	fn(data: array of byte): int;
};
