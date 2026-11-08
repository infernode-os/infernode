implement BayerTest;

#
# $Bayer: whole cells merged into I420, for every mosaic order.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "bayer.m";
	bayer: Bayer;

BayerTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/bayer_test.b";

passed := 0;
failed := 0;
skipped := 0;

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
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

put(raw: array of byte, w, x, y, v: int)
{
	o := (y*w + x)*2;
	raw[o] = byte v;
	raw[o+1] = byte (v>>8);
}

# a frame of one cell's values, repeated, in the order red says
frame(w, h, red, r, g, b: int): array of byte
{
	raw := array[w*h*2] of byte;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			c := (y&1)<<1 | (x&1);
			v := g;
			if(c == red)
				v = r;
			else if(c == (red^3))
				v = b;
			put(raw, w, x, y, v);
		}
	return raw;
}

identity(): array of byte
{
	t := array[1024] of byte;
	for(i := 0; i < len t; i++)
		t[i] = byte (i>>2);
	return t;
}

testOrders(t: ref T)
{
	lut := identity();
	for(red := 0; red < 4; red++){
		raw := frame(16, 16, red, 800, 400, 200);
		y := array[8*8] of byte;
		cb := array[4*4] of byte;
		cr := array[4*4] of byte;
		mean := array[3] of int;
		bayer->merge(raw, 16, 16, 2, red, 0, lut, lut, lut, y, cb, cr, mean);
		t.asserteq(mean[0], 800, sys->sprint("red %d: red mean", red));
		t.asserteq(mean[1], 400, sys->sprint("red %d: green mean", red));
		t.asserteq(mean[2], 200, sys->sprint("red %d: blue mean", red));
		# 200, 100, 50 through the tables: full-range BT.601
		t.asserteq(int y[0], 124, sys->sprint("red %d: luma", red));
		t.asserteq(int cb[0], 86, sys->sprint("red %d: cb", red));
		t.asserteq(int cr[0], 182, sys->sprint("red %d: cr", red));
	}
}

# a primary at full strength: its chroma is 256 before it is clamped,
# which as a byte is 0, and red and blue came out green (found in the
# simulated sensor's colour bars, on screen)
testSaturated(t: ref T)
{
	lut := identity();
	y := array[8*8] of byte;
	cb := array[4*4] of byte;
	cr := array[4*4] of byte;
	mean := array[3] of int;
	bayer->merge(frame(16, 16, 0, 1023, 0, 0), 16, 16, 2, 0, 0, lut, lut, lut, y, cb, cr, mean);
	t.asserteq(int cr[0], 255, "full red: cr");
	t.assert(int cb[0] < 128, "full red: cb");
	bayer->merge(frame(16, 16, 0, 0, 0, 1023), 16, 16, 2, 0, 0, lut, lut, lut, y, cb, cr, mean);
	t.asserteq(int cb[0], 255, "full blue: cb");
	t.assert(int cr[0] < 128, "full blue: cr");
}

testScale(t: ref T)
{
	lut := identity();
	raw := frame(16, 16, 0, 400, 400, 400);
	# one hot cell in the top left block of four: its mean is a quarter
	put(raw, 16, 0, 0, 800);
	y := array[4*4] of byte;
	cb := array[2*2] of byte;
	cr := array[2*2] of byte;
	mean := array[3] of int;
	bayer->merge(raw, 16, 16, 4, 0, 0, lut, lut, lut, y, cb, cr, mean);
	t.assert(int y[0] > int y[1], "the pixel over the hot sample is the brighter");
	t.asserteq(int cb[3], 128, "grey has no colour");
	t.asserteq(int cr[3], 128, "grey has no colour");
}

# Each output pixel a different grey, so that where each lands says how
# the picture was turned: 8 by 4 before, 4 by 8 after a quarter turn.
testRotate(t: ref T)
{
	lut := identity();
	w := 8;
	h := 4;
	raw := array[2*w*2*h*2] of byte;
	for(sy := 0; sy < 2*h; sy++)
		for(sx := 0; sx < 2*w; sx++)
			put(raw, 2*w, sx, sy, 4*(1 + sx/2 + w*(sy/2)));
	mean := array[3] of int;
	for(rot := 0; rot < 4; rot++){
		y := array[w*h] of byte;
		cb := array[(w/2)*(h/2)] of byte;
		cr := array[(w/2)*(h/2)] of byte;
		bayer->merge(raw, 2*w, 2*h, 2, 0, rot, lut, lut, lut, y, cb, cr, mean);
		ow := w;
		if(rot&1)
			ow = h;
		bad := 0;
		for(py := 0; py < h; py++)
			for(px := 0; px < w; px++){
				(ox, oy) := (px, py);
				case rot {
				1 =>	(ox, oy) = (h-1-py, px);
				2 =>	(ox, oy) = (w-1-px, h-1-py);
				3 =>	(ox, oy) = (py, w-1-px);
				}
				if(int y[oy*ow+ox] != 1 + px + w*py)
					bad++;
			}
		t.asserteq(bad, 0, sys->sprint("rot %d: pixels out of place", rot));
	}

	# a red corner, top left; turned clockwise its colour is top right
	raw = frame(2*w, 2*h, 0, 400, 400, 400);
	for(sy = 0; sy < 4; sy++)
		for(sx = 0; sx < 4; sx++)
			if((sy&1) == 0 && (sx&1) == 0)
				put(raw, 2*w, sx, sy, 1000);
			else
				put(raw, 2*w, sx, sy, 64);
	y := array[w*h] of byte;
	cb := array[(w/2)*(h/2)] of byte;
	cr := array[(w/2)*(h/2)] of byte;
	bayer->merge(raw, 2*w, 2*h, 2, 0, 1, lut, lut, lut, y, cb, cr, mean);
	t.assert(int cr[h/2-1] > 200, sys->sprint("rot 1: red at the top right: cr %d", int cr[h/2-1]));
	t.asserteq(int cr[0], 128, "rot 1: grey at the top left");
	t.assert(int y[h-1] < int y[0], "rot 1: the red corner's luma, top right");
	refused := 0;
	{
		bayer->merge(raw, 2*w, 2*h, 2, 0, 4, lut, lut, lut, y, cb, cr, mean);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "a fifth quarter is refused");
}

testBounds(t: ref T)
{
	lut := identity();
	raw := array[8*8*2] of byte;
	y := array[1] of byte;
	cb := array[1] of byte;
	cr := array[1] of byte;
	mean := array[3] of int;
	refused := 0;
	{
		bayer->merge(raw, 8, 8, 2, 0, 0, lut, lut, lut, y, cb, cr, mean);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "planes too small are refused");
	refused = 0;
	{
		bayer->merge(raw, 8, 8, 3, 0, 0, lut, lut, lut, y, cb, cr, mean);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "an odd scale is refused");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	bayer = load Bayer Bayer->PATH;
	if(bayer == nil){
		run("Loads", skipit);
	}else{
		run("Orders", testOrders);
		run("Saturated", testSaturated);
		run("Scale", testScale);
		run("Rotate", testRotate);
		run("Bounds", testBounds);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

skipit(t: ref T)
{
	t.skip("no $Bayer in this build");
}
