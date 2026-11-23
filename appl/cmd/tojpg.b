implement Tojpg;

#
# tojpg [-q quality]: a picture, image(6), from standard input as a
# baseline JPEG on standard output (jpegenc(2), 4:2:0, quality 1 to 100,
# 85 if not given). Read as topng(1) reads it.
#
#	read 189420 < /mnt/video/0/frame | i420 410 308 | tojpg > still.jpg
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "visrec.m";
	visrec: Visrec;
include "jpeg.m";
	jpegenc: Jpegenc;

Tojpg: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("tojpg [-q quality] < image > jpeg");
	q := 85;
	while((c := arg->opt()) != 0)
		case c {
		'q' =>	q = int arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil || q < 1 || q > 100)
		arg->usage();
	visrec = load Visrec Visrec->PATH;
	if(visrec == nil)
		fail(sys->sprint("cannot load Visrec: %r"));
	if((e := visrec->init()) != nil)
		fail(e);
	jpegenc = load Jpegenc Jpegenc->PATH;
	if(jpegenc == nil)
		fail(sys->sprint("cannot load Jpegenc: %r"));
	(pix, w, h, re) := visrec->readrgb(sys->fildes(0));
	if(pix == nil)
		fail(re);
	# to I420, full-range BT.601: jpegenc's planes
	cw := (w+1)/2;
	ch := (h+1)/2;
	y := array[w*h] of byte;
	u := array[cw*ch] of {* => byte 128};
	v := array[cw*ch] of {* => byte 128};
	su := array[cw*ch] of {* => 0};
	sv := array[cw*ch] of {* => 0};
	sn := array[cw*ch] of {* => 0};
	for(j := 0; j < h; j++)
		for(i := 0; i < w; i++){
			o := 3*(j*w + i);
			b := int pix[o];
			g := int pix[o+1];
			r := int pix[o+2];
			y[j*w + i] = clamp((19595*r + 38470*g + 7471*b + 32768) >> 16);
			k := (j/2)*cw + i/2;
			su[k] += -11059*r - 21709*g + 32768*b;
			sv[k] += 32768*r - 27439*g - 5329*b;
			sn[k]++;
		}
	for(k := 0; k < cw*ch; k++){
		u[k] = clamp(128 + rdiv(su[k], sn[k] << 16));
		v[k] = clamp(128 + rdiv(sv[k], sn[k] << 16));
	}
	(jp, je) := jpegenc->encode(w, h, y, u, v, q);
	if(jp == nil)
		fail(je);
	if(sys->write(sys->fildes(1), jp, len jp) != len jp)
		fail(sys->sprint("write: %r"));
}

# a/b rounded to nearest, either sign
rdiv(a, b: int): int
{
	if(a >= 0)
		return (a + b/2)/b;
	return -((-a + b/2)/b);
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
	sys->fprint(sys->fildes(2), "tojpg: %s\n", s);
	raise "fail:" + s;
}
