implement MemdrawFarTest;

#
# An image whose rectangle is far from 0 in its coordinates: drawn
# on, read back, drawn from.
#
# memdraw keeps where (0,0) would be in an image's data, its byte
# offset from the data's start: the bytes in a line times r.min.y.
# That was an int, so an image whose top was further down than 2^31
# bytes of lines (row 158000 of one 3400 pixels wide at 32 bits) had
# the offset wrapped, and allocating it faulted in the emulator.  A
# strip of a long document is such an image: Xenith's Markdown is
# drawn a strip at a time into an image placed where the strip is in
# the document, so one far down a long document at 2x came out blank.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

include "testing.m";
	testing: Testing;
	T: import testing;

MemdrawFarTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/memdraw_far_test.b";

passed := 0;
failed := 0;
skipped := 0;

display: ref Display;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

W: con 3400;	# a Retina window's width

# The pixel at p of im, as 16rRRGGBB
pixel(im: ref Image, p: Point): int
{
	b := array[4] of byte;
	if(im.readpixels(Rect(p, p.add((1, 1))), b) != 4)
		return -1;
	return (int b[2]<<16) | (int b[1]<<8) | int b[0];
}

# An image W by 4 with its top at y, white, a red block drawn in it
farimage(t: ref T, y: int): ref Image
{
	im := display.newimage(Rect((0, y), (W, y+4)), Draw->XRGB32, 0, Draw->White);
	if(im == nil)
		t.fatal(sys->sprint("no image with its top at %d: %r", y));
	im.draw(Rect((100, y+1), (200, y+3)), display.color(int 16rFF0000FF), nil, (0, 0));
	return im;
}

testFar(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	for(ys := list of {0, 150000, 160000, 400000, 700000, -160000, -700000}; ys != nil; ys = tl ys){
		y := hd ys;
		im := farimage(t, y);
		t.asserteq(pixel(im, (150, y+2)), 16rFF0000, sys->sprint("top at %d: drawn where it was drawn", y));
		t.asserteq(pixel(im, (10, y+2)), 16rFFFFFF, sys->sprint("top at %d: and not elsewhere", y));
		t.asserteq(pixel(im, (W-1, y+3)), 16rFFFFFF, sys->sprint("top at %d: its last pixel its own", y));
	}
}

# Drawn from one far image into another, far elsewhere
testFarToFar(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	src := farimage(t, 500000);
	dst := display.newimage(Rect((0, -300000), (W, -300000+4)), Draw->XRGB32, 0, Draw->White);
	if(dst == nil)
		t.fatal(sys->sprint("no image: %r"));
	dst.draw(dst.r, src, nil, src.r.min);
	t.asserteq(pixel(dst, (150, -300000+2)), 16rFF0000, "the block copied");
	t.asserteq(pixel(dst, (10, -300000+2)), 16rFFFFFF, "and nothing else");
	# and onto the screen's own coordinates, as a strip is
	scr := display.newimage(Rect((0, 0), (W, 4)), Draw->XRGB32, 0, Draw->White);
	scr.draw(scr.r, src, nil, src.r.min);
	t.asserteq(pixel(scr, (150, 2)), 16rFF0000, "a far strip drawn at 0");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	display = Display.allocate(nil);

	run("Far", testFar);
	run("FarToFar", testFarToFar);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
