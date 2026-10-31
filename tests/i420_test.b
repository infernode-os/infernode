implement I420Test;

#
# The emulator's built-in $I420 converter against the Limbo loop of
# appl/mpeg/remap24.b, which it replaces: the pixels must be the same,
# byte for byte, and remap24 must give them through its Remap interface.
#
# Run: emu -r. /dis/tests/i420_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../appl/mpeg/mpegio.m";
	Mpegi, YCbCr: import Mpegio;

include "i420.m";
	i420: I420;

include "testing.m";
	testing: Testing;
	T: import testing;

I420Test: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/i420_test.b";

passed  := 0;
failed  := 0;
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

# remap24.b's loop, as it was before $I420: the reference
B: con 16;
M: con (1 << B);
B0: con int (-0.34414 * real M);
B1: con int (1.772 * real M);
R0: con int (1.402 * real M);
R1: con int (-0.71414 * real M);
CLOFF: con 255;

reference(p: ref YCbCr, w, h: int): array of byte
{
	clamp := array[CLOFF + 256 + CLOFF] of byte;
	for(i := 0; i < len clamp; i++)
		if(i < CLOFF)
			clamp[i] = byte 0;
		else if(i < CLOFF + 256)
			clamp[i] = byte (i - CLOFF);
		else
			clamp[i] = byte 255;
	w2 := w >> 1;
	h2 := h >> 1;
	b0r1 := array[w2] of int;
	b1 := array[w2] of int;
	r0 := array[w2] of int;
	out := array[3*w*h] of byte;
	m := 0;
	n := 0;
	x := 0;
	for(i = 0; i < h2; i++) {
		for(j := 0; j < w2; j++) {
			cb := int p.Cb[m] - 128;
			cr := int p.Cr[m] - 128;
			b0r1[j] = B0 * cb + R1 * cr;
			b1[j] = B1 * cb;
			r0[j] = R0 * cr;
			m++;
		}
		for(j = 0; j < 2; j++)
			for(k := 0; k < w2; k++)
				for(l := 0; l < 2; l++) {
					y := int p.Y[n++] << B;
					out[x++] = clamp[((y + b1[k]) >> B) + CLOFF];
					out[x++] = clamp[((y + b0r1[k]) >> B) + CLOFF];
					out[x++] = clamp[((y + r0[k]) >> B) + CLOFF];
				}
	}
	return out;
}

# planes of a w by h frame: every Y against every chroma pair appears in
# the 16 by 16 frames, and a pseudo-random fill elsewhere
frame(w, h, seed: int): ref YCbCr
{
	c := (w/2)*(h/2);
	p := ref YCbCr(array[w*h] of byte, array[c] of byte, array[c] of byte);
	for(i := 0; i < len p.Y; i++) {
		seed = seed*1103515245 + 12345;
		p.Y[i] = byte (seed >> 16);
	}
	for(i = 0; i < c; i++) {
		seed = seed*1103515245 + 12345;
		p.Cb[i] = byte (seed >> 16);
		seed = seed*1103515245 + 12345;
		p.Cr[i] = byte (seed >> 16);
	}
	return p;
}

# the extremes, where the clamping happens
extremes(): ref YCbCr
{
	w := 16;
	h := 16;
	p := ref YCbCr(array[w*h] of byte, array[64] of byte, array[64] of byte);
	v := array[] of {0, 1, 16, 127, 128, 129, 235, 255};
	for(i := 0; i < w*h; i++)
		p.Y[i] = byte v[i % len v];
	for(i = 0; i < 64; i++) {
		p.Cb[i] = byte v[i % len v];
		p.Cr[i] = byte v[(i / len v) % len v];
	}
	return p;
}

firstdiff(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return i;
	return -1;
}

needi420(t: ref T)
{
	if(i420 == nil)
		t.skip("no $I420 in this emulator");
}

same(t: ref T, p: ref YCbCr, w, h: int, what: string)
{
	want := reference(p, w, h);
	got := array[3*w*h] of byte;
	i420->rgb24(p.Y, p.Cb, p.Cr, w, h, got);
	d := firstdiff(got, want);
	t.asserteq(d, -1, sys->sprint("%s %dx%d: first differing byte", what, w, h));
}

testExtremes(t: ref T)
{
	needi420(t);
	same(t, extremes(), 16, 16, "extremes");
}

testSizes(t: ref T)
{
	needi420(t);
	sizes := array[] of {(2, 2), (4, 2), (2, 6), (18, 10), (320, 240), (1280, 720)};
	for(i := 0; i < len sizes; i++) {
		(w, h) := sizes[i];
		same(t, frame(w, h, i+1), w, h, "random");
	}
}

# remap24 through its Remap interface: the builtin where there is one
testRemap24(t: ref T)
{
	remap := load Remap Remap->PATH24;
	if(remap == nil)
		t.fatal(sys->sprint("cannot load %s: %r", Remap->PATH24));
	w := 1280;
	h := 720;
	m := ref Mpegi;
	m.width = w;
	m.height = h;
	remap->init(m);
	p := frame(w, h, 99);
	d := firstdiff(remap->remap(p), reference(p, w, h));
	t.asserteq(d, -1, "remap24 1280x720: first differing byte");
}

# does the conversion refuse these arguments?
refused(y, cb, cr: array of byte, w, h: int, out: array of byte): int
{
	{
		i420->rgb24(y, cb, cr, w, h, out);
	} exception {
	"*" =>
		return 1;
	}
	return 0;
}

testBadArgs(t: ref T)
{
	needi420(t);
	p := frame(4, 4, 7);
	t.assert(refused(p.Y, p.Cb, p.Cr, 3, 4, array[36] of byte), "odd width refused");
	t.assert(refused(p.Y, p.Cb, p.Cr, 4, 4, array[47] of byte), "short output refused");
	t.assert(refused(p.Y, p.Cb, p.Cr, 8, 4, array[96] of byte), "short planes refused");
	t.assert(refused(nil, p.Cb, p.Cr, 4, 4, array[48] of byte), "nil plane refused");
	t.assert(!refused(p.Y, p.Cb, p.Cr, 4, 4, array[48] of byte), "exact sizes accepted");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	i420 = load I420 I420->PATH;

	run("Extremes", testExtremes);
	run("Sizes", testSizes);
	run("Remap24", testRemap24);
	run("BadArgs", testBadArgs);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
