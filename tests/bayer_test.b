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

get(raw: array of byte, w, x, y: int): int
{
	o := (y*w + x)*2;
	return int raw[o] | int raw[o+1]<<8;
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

# The means over unclipped cells: a block with a sample at or above
# clip is left out of mean[3..5], and only of them
testClip(t: ref T)
{
	lut := identity();
	w := 16;
	h := 8;
	raw := frame(w, h, 0, 300, 400, 500);
	# one red sample clipped, in the output pixel at (0,0)
	put(raw, w, 0, 0, 1023);
	y := array[(w/2)*(h/2)] of byte;
	cb := array[(w/4)*(h/4)] of byte;
	cr := array[(w/4)*(h/4)] of byte;
	mean := array[6] of int;
	bayer->merge(raw, w, h, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 1000);
	t.assert(mean[0] > 300, "the plain red mean counts the clipped sample");
	t.asserteq(mean[3], 300, "the unclipped red mean does not");
	t.asserteq(mean[4], 400, "green over the unclipped");
	t.asserteq(mean[5], 500, "blue over the unclipped");
	bayer->merge(raw, w, h, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
	t.asserteq(mean[3], mean[0], "clip 0 leaves none out");
	# everything clipped: the unclipped means are 0
	raw = frame(w, h, 0, 1023, 1023, 1023);
	bayer->merge(raw, w, h, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 1000);
	t.asserteq(mean[4], 0, "nothing unclipped: 0");
	# three entries are still enough, as before
	m3 := array[3] of int;
	bayer->merge(raw, w, h, 2, 0, 0, lut, lut, lut, y, cb, cr, m3, 1000);
	t.asserteq(m3[1], 1023, "a three-entry mean still works");
	refused := 0;
	{
		bayer->merge(raw, w, h, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, -1);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "a negative clip is refused");
}

# NDVI from the raw channels: (NIR-VIS)/(NIR+VIS) as 128 + 127 times it,
# black taken off, the floor, the turn, the figures, the refusals
testNdvi(t: ref T)
{
	w := 16;
	h := 8;
	black := 64;
	# red (near-infrared) 300 above black, blue (visible) 100: NDVI 0.5
	raw := frame(w, h, 0, black+300, black+50, black+100);
	out := array[(w/2)*(h/2)] of byte;
	st := array[5] of int;
	bayer->ndvi(raw, w, h, 2, 0, 0, 0, 2, black, 16, out, st);
	t.asserteq(int out[0], 192, "0.5 is 128 + 64");
	t.asserteq(int out[len out - 1], 192, "and so is every pixel");
	t.asserteq(st[0], 503, "the mean in thousandths (64/127)");
	t.asserteq(st[2], 503, "the median");
	t.asserteq(st[4], len out, "every pixel a reading");
	# visible over infrared: negative
	raw = frame(w, h, 0, black+100, black+50, black+300);
	bayer->ndvi(raw, w, h, 2, 0, 0, 0, 2, black, 16, out, st);
	t.asserteq(int out[0], 64, "-0.5 is 128 - 64");
	t.asserteq(st[0], -503, "a negative mean");
	# equal: 128; under the floor: 0, no reading
	raw = frame(w, h, 0, black+200, black+200, black+200);
	bayer->ndvi(raw, w, h, 2, 0, 0, 0, 2, black, 16, out, st);
	t.asserteq(int out[3], 128, "equal channels: 0, 128");
	raw = frame(w, h, 0, black+5, black, black+5);
	bayer->ndvi(raw, w, h, 2, 0, 0, 0, 2, black, 16, out, st);
	t.asserteq(int out[3], 0, "under the floor: no reading");
	t.asserteq(st[4], 0, "no readings");
	t.asserteq(st[0], 0, "and figures of 0");
	# channels chosen: green as visible
	raw = frame(w, h, 0, black+300, black+100, black+300);
	bayer->ndvi(raw, w, h, 2, 0, 0, 0, 1, black, 16, out, st);
	t.asserteq(int out[0], 192, "red over green");
	# the turn: a quarter turn writes the picture h by w
	raw = frame(w, h, 0, black+300, black+50, black+100);
	put(raw, w, 0, 0, black+100);		# the top left pixel's red: NDVI 0
	o2 := array[(w/2)*(h/2)] of byte;
	bayer->ndvi(raw, w, h, 2, 0, 1, 0, 2, black, 16, o2, st);
	t.asserteq(int o2[h/2 - 1], 128, "turned: the top left pixel is at the top right");
	# refused
	bad := array[] of {(3, 2), (0, 0), (0, -1)};
	for(i := 0; i < len bad; i++){
		(ni, vi) := bad[i];
		refused := 0;
		{
			bayer->ndvi(raw, w, h, 2, 0, 0, ni, vi, black, 16, out, st);
		} exception {
		* =>
			refused = 1;
		}
		t.assert(refused, sys->sprint("channels %d %d refused", ni, vi));
	}
	refused := 0;
	{
		bayer->ndvi(raw, w, h, 2, 0, 0, 0, 2, black, 16, out, array[3] of int);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "figures with fewer than four entries refused");
}

# Lens shading: gains from a corner-to-corner grid, bilinear, black kept,
# held at max; refusals
testShade(t: ref T)
{
	w := 32;
	h := 16;
	black := 64;
	gw := 3;
	gh := 3;
	n := gw*gh;
	tab := array[4*n] of {* => 2048};	# a gain of two everywhere
	raw := frame(w, h, 0, black+100, black+100, black+100);
	bayer->shade(raw, w, h, black, 1023, tab, gw, gh);
	t.asserteq(get(raw, w, 5, 3), black+200, "a gain of two doubles what is above black");
	t.asserteq(get(raw, w, 0, 0), black+200, "at a corner too");
	# one at the left, two at the right: the middle about one and a half
	for(q := 0; q < 4; q++)
		for(j := 0; j < gh; j++){
			tab[q*n + j*gw + 0] = 1024;
			tab[q*n + j*gw + 1] = 1536;
			tab[q*n + j*gw + 2] = 2048;
		}
	raw = frame(w, h, 0, black+400, black+400, black+400);
	bayer->shade(raw, w, h, black, 1023, tab, gw, gh);
	t.asserteq(get(raw, w, 0, 4), black+400, "the left edge: one");
	t.asserteq(get(raw, w, w-1, 4), 1023, "the right edge: two, held at max");
	mid := get(raw, w, 16, 4) - black;
	t.assert(mid >= 590 && mid <= 610, sys->sprint("the middle about one and a half: %d above black", mid));
	# at and below black: left alone
	raw = frame(w, h, 0, black, black-10, black);
	bayer->shade(raw, w, h, black, 1023, tab, gw, gh);
	t.asserteq(get(raw, w, 31, 1), black, "black left as it is");
	t.asserteq(get(raw, w, 31, 0) , black-10, "below black too");
	refused := 0;
	{
		bayer->shade(raw, w, h, black, 1023, array[4*n-1] of int, gw, gh);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "a short table refused");
	refused = 0;
	{
		bayer->shade(raw, w, h, black, black, tab, gw, gh);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "a max not above black refused");
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
		bayer->merge(raw, 16, 16, 2, red, 0, lut, lut, lut, y, cb, cr, mean, 0);
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
	bayer->merge(frame(16, 16, 0, 1023, 0, 0), 16, 16, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
	t.asserteq(int cr[0], 255, "full red: cr");
	t.assert(int cb[0] < 128, "full red: cb");
	bayer->merge(frame(16, 16, 0, 0, 0, 1023), 16, 16, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
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
	bayer->merge(raw, 16, 16, 4, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
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
		bayer->merge(raw, 2*w, 2*h, 2, 0, rot, lut, lut, lut, y, cb, cr, mean, 0);
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
	bayer->merge(raw, 2*w, 2*h, 2, 0, 1, lut, lut, lut, y, cb, cr, mean, 0);
	t.assert(int cr[h/2-1] > 200, sys->sprint("rot 1: red at the top right: cr %d", int cr[h/2-1]));
	t.asserteq(int cr[0], 128, "rot 1: grey at the top left");
	t.assert(int y[h-1] < int y[0], "rot 1: the red corner's luma, top right");
	refused := 0;
	{
		bayer->merge(raw, 2*w, 2*h, 2, 0, 4, lut, lut, lut, y, cb, cr, mean, 0);
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
		bayer->merge(raw, 8, 8, 2, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "planes too small are refused");
	refused = 0;
	{
		bayer->merge(raw, 8, 8, 3, 0, 0, lut, lut, lut, y, cb, cr, mean, 0);
	} exception {
	* =>
		refused = 1;
	}
	t.assert(refused, "an odd scale is refused");
}

# A scale large enough that a cell's sum of 16-bit samples passes an int
# (258: 2*129*129*65535).  The green sum went negative and indexed before
# its table: the tables here are slices far into arrays that are zero but
# for the byte such an index reads.
testLargeScale(t: ref T)
{
	rw := 516;
	rh := 516;
	s := 258;
	raw := array[rw*rh*2] of {* => byte 16rff};
	y := array[4] of byte;
	cb := array[1] of byte;
	cr := array[1] of byte;
	mean := array[3] of int;
	n := (s/2)*(s/2);
	gi := int (big 2 * big n * big 65535) / (2*n);	# as an int held it
	t.assert(gi < 0, "the green sum does not fit an int");
	bigr := array[200000] of {* => byte 0};
	bigg := array[200000] of {* => byte 0};
	bigb := array[200000] of {* => byte 0};
	lr := bigr[100000:100256];
	lg := bigg[100000:100256];
	lb := bigb[100000:100256];
	lr[255] = byte 255;
	lg[255] = byte 255;
	lb[255] = byte 255;
	bigg[100000+gi] = byte 77;
	bayer->merge(raw, rw, rh, s, 0, 0, lr, lg, lb, y, cb, cr, mean, 0);
	for(i := 0; i < 4; i++)
		t.asserteq(int y[i], 255, sys->sprint("saturated samples at scale 258: luma %d is the table's last entry", i));
	t.asserteq(mean[0], 65535, "mean red");
	t.asserteq(mean[1], 65535, "mean green");
	t.asserteq(mean[2], 65535, "mean blue");
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
		run("LargeScale", testLargeScale);
		run("Clip", testClip);
		run("Ndvi", testNdvi);
		run("Shade", testShade);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

skipit(t: ref T)
{
	t.skip("no $Bayer in this build");
}
