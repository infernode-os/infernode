implement Topng;

#
# topng: a picture, image(6), from standard input as a PNG on standard
# output: 8-bit RGB, through visrec(2)'s writer. Uncompressed r8g8b8 is
# taken as it is; other image(6) pictures (the screen's, a window's) go
# through the draw device.
#
#	read 189420 < /mnt/video/0/frame | i420 410 308 | topng > still.png
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "visrec.m";
	visrec: Visrec;

Topng: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if(argv != nil && tl argv != nil){
		sys->fprint(sys->fildes(2), "usage: topng < image > png\n");
		raise "fail:usage";
	}
	visrec = load Visrec Visrec->PATH;
	if(visrec == nil)
		fail(sys->sprint("cannot load Visrec: %r"));
	if((e := visrec->init()) != nil)
		fail(e);
	(pix, w, h, re) := visrec->readrgb(sys->fildes(0));
	if(pix == nil)
		fail(re);
	if((e = visrec->writepng(sys->fildes(1), pix, w, h)) != nil)
		fail(e);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "topng: %s\n", s);
	raise "fail:" + s;
}
