implement I420;

#
# i420 w h: one I420 frame (the format a video feed serves: camsrv(4),
# vid9p) from standard input, as an uncompressed image(6) picture,
# r8g8b8, on standard output, for topng(1), tojpg(1) or anything else
# that takes a picture. Full-range BT.601, as camsrv makes them.
#
#	read 189420 < /mnt/video/0/frame | i420 410 308 | topng > still.png
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "visrec.m";
	visrec: Visrec;

I420: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("i420 w h");
	while(arg->opt() != 0)
		arg->usage();
	argv = arg->argv();
	if(len argv != 2)
		arg->usage();
	w := int hd argv;
	h := int hd tl argv;
	if(w < 1 || h < 1 || w > 16384 || h > 16384)
		fail(sys->sprint("bad size %s %s", hd argv, hd tl argv));
	visrec = load Visrec Visrec->PATH;
	if(visrec == nil)
		fail(sys->sprint("cannot load Visrec: %r"));
	if((e := visrec->init()) != nil)
		fail(e);
	cw := (w+1)/2;
	ch := (h+1)/2;
	n := w*h + 2*cw*ch;
	f := array[n] of byte;
	got := 0;
	stdin := sys->fildes(0);
	while(got < n){
		m := sys->read(stdin, f[got:], n - got);
		if(m <= 0)
			break;
		got += m;
	}
	if(got < n)
		fail(sys->sprint("short frame: %d bytes of %d for %d by %d", got, n, w, h));
	pix := array[3*w*h] of byte;
	u := w*h;
	v := u + cw*ch;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			yy := int f[y*w + x];
			cb := int f[u + (y/2)*cw + x/2] - 128;
			cr := int f[v + (y/2)*cw + x/2] - 128;
			# full range: R = Y + 1.402 Cr, G = Y - 0.344 Cb - 0.714 Cr, B = Y + 1.772 Cb
			r := yy + (91881*cr + 32768)/65536;
			g := yy - (22554*cb + 46802*cr - 32768)/65536;
			b := yy + (116130*cb + 32768)/65536;
			o := 3*(y*w + x);
			pix[o] = clamp(b);	# r8g8b8 in memory: blue first
			pix[o+1] = clamp(g);
			pix[o+2] = clamp(r);
		}
	if((e = visrec->writeimage(sys->fildes(1), pix, w, h)) != nil)
		fail(e);
}

clamp(v: int): byte
{
	if(v < 0)
		return byte 0;
	if(v > 255)
		return byte 255;
	return byte v;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "i420: %s\n", s);
	raise "fail:" + s;
}
