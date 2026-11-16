RImagefile: module 
{
	READGIFPATH:	con "/dis/lib/readgif.dis";
	READJPGPATH:	con "/dis/lib/readjpg.dis";
	READXBMPATH:	con "/dis/lib/readxbitmap.dis";
	READPICPATH:	con "/dis/lib/readpicfile.dis";
	READPNGPATH:	con "/dis/lib/readpng.dis";
	READWEBPPATH:	con "/dis/lib/readwebp.dis";
	READAVIFPATH:	con "/dis/lib/readavif.dis";
	READSVGPATH:	con "/dis/lib/readsvg.dis";

	Rawimage: adt
	{
		r:	Draw->Rect;
		cmap:    array of byte;
		transp:  int;	# transparency flag (only for nchans=1)
		trindex: byte;	# transparency index
		nchans:  int;
		chans:   array of array of byte;
		chandesc:int;

		fields:	int;    # defined by format
	};

	# chandesc
	CRGB:   con 0;  # three channels, no map
	CY:     con 1;  # one channel, luminance
	CRGB1:  con 2;  # one channel, map present
	CRGBA:  con 3;  # four channels: R, G, B, A

	init:	fn(bufio: Bufio);
	read:	fn(fd: ref Bufio->Iobuf): (ref Rawimage, string);
	readmulti:	fn(fd: ref Bufio->Iobuf): (array of ref Rawimage, string);
};

WImagefile: module 
{
	WRITEGIFPATH:	con "/dis/lib/writegif.dis";

	init:	fn(bufio: Bufio);
#	write:	fn(fd: ref Bufio->Iobuf, ref RImagefile->Rawimage): string;
	writeimage:	fn(fd: ref Bufio->Iobuf, image: ref Draw->Image): string;
};


Imageremap: module
{
	PATH:	con "/dis/lib/imageremap.dis";

	init:	fn(d: ref Draw->Display);
	remap:	fn(i: ref RImagefile->Rawimage, d: ref Draw->Display, errdiff: int): (ref Draw->Image, string);
};

Jpegscaled: module
{
	PATH:	con "/dis/lib/readjpg.dis";	# readjpg(2) implements this too
	# The image decoded at the smallest of 1, 1/2, 1/4 and 1/8 of its
	# size that is at least minw wide and minh high (libjpeg's
	# scale_num/scale_denom, by reduced inverse DCTs): (image, its own
	# width and height, nil), or nil and the reason.  0 by 0 is the
	# whole size.
	scaled:	fn(d: array of byte, minw, minh: int): (ref RImagefile->Rawimage, int, int, string);
};
