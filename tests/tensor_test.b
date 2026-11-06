implement TensorTest;

#
# $Tensor (libinterp/tensor.c, module/tensor.m) against Limbo references:
# convolutions of the shapes that take its edges (more than one block of
# depth and of columns, output channels and pixels not a multiple of 8,
# stride 2, padding, depthwise, every activation), add, the activations,
# max pooling, up2, space to depth, letterbox, the real conversions, and
# its refusals (short arrays, a misaligned slice, nil, bad parameters).
# Skips where $Tensor is not built in.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "testing.m";
	testing: Testing;
	T: import testing;
include "tensor.m";
	tensor: Tensor;

TensorTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tensor_test.b";

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

seed := 12345;

rnd(): real
{
	seed = seed*1103515245 + 12345;
	return real ((seed >> 8) & 16rFFFF) / 32768.0 - 1.0;
}

rnds(n: int): array of real
{
	a := array[n] of real;
	for(i := 0; i < n; i++)
		a[i] = rnd();
	return a;
}

tobytes(r: array of real): array of byte
{
	b := array[4*len r] of byte;
	tensor->fromreal(r, b);
	return b;
}

toreals(b: array of byte): array of real
{
	r := array[len b/4] of real;
	tensor->toreal(b, r);
	return r;
}

actref(x: real, act: int): real
{
	case act {
	Tensor->Relu =>
		if(x < 0.0)
			return 0.0;
		return x;
	Tensor->Sigmoid =>
		return 1.0 / (1.0 + math->exp(-x));
	Tensor->Silu =>
		return x / (1.0 + math->exp(-x));
	}
	return x;
}

convref(in: array of real, c, h, w: int, wt: array of real, oc, kh, kw, stride, pad, group: int,
	bias: array of real, act: int): (array of real, int, int)
{
	oh := (h + 2*pad - kh)/stride + 1;
	ow := (w + 2*pad - kw)/stride + 1;
	icg := c / group;
	ocg := oc / group;
	out := array[oc*oh*ow] of real;
	for(o := 0; o < oc; o++){
		g := o / ocg;
		for(y := 0; y < oh; y++)
			for(x := 0; x < ow; x++){
				s := bias[o];
				for(i := 0; i < icg; i++)
					for(ky := 0; ky < kh; ky++)
						for(kx := 0; kx < kw; kx++){
							iy := y*stride - pad + ky;
							ix := x*stride - pad + kx;
							if(iy < 0 || iy >= h || ix < 0 || ix >= w)
								continue;
							s += in[((g*icg + i)*h + iy)*w + ix] * wt[((o*icg + i)*kh + ky)*kw + kx];
						}
				out[(o*oh + y)*ow + x] = actref(s, act);
			}
	}
	return (out, oh, ow);
}

close(t: ref T, got, want: array of real, tol: real, what: string): int
{
	if(len got != len want){
		t.error(sys->sprint("%s: %d values, want %d", what, len got, len want));
		return 0;
	}
	for(i := 0; i < len got; i++){
		d := got[i] - want[i];
		if(d < 0.0)
			d = -d;
		m := want[i];
		if(m < 0.0)
			m = -m;
		if(d > tol*(1.0 + m)){
			t.error(sys->sprint("%s: [%d] = %g, want %g", what, i, got[i], want[i]));
			return 0;
		}
	}
	return 1;
}

Shape: adt {
	c, h, w, oc, kh, kw, stride, pad, group, act: int;
};

testConv(t: ref T)
{
	shapes := array[] of {
		Shape(3, 7, 9, 5, 3, 3, 1, 1, 1, Tensor->None),
		Shape(12, 10, 10, 16, 3, 3, 2, 1, 1, Tensor->Silu),
		Shape(20, 5, 13, 9, 1, 1, 1, 0, 1, Tensor->Relu),
		Shape(40, 13, 13, 11, 3, 3, 1, 1, 1, Tensor->Sigmoid),	# K=360 > 256, N=169 > 128
		Shape(300, 3, 50, 17, 1, 1, 1, 0, 1, Tensor->Silu),	# K=300, N=150
		Shape(6, 9, 11, 6, 3, 3, 2, 1, 6, Tensor->Silu),	# depthwise, stride 2
		Shape(8, 6, 6, 8, 5, 5, 1, 2, 8, Tensor->None),		# depthwise 5x5
		Shape(1, 1, 1, 1, 1, 1, 1, 0, 1, Tensor->None),
		Shape(4, 8, 8, 85, 1, 1, 1, 0, 1, Tensor->Sigmoid),	# a head's 85 outputs
	};
	for(i := 0; i < len shapes; i++){
		s := shapes[i];
		in := rnds(s.c*s.h*s.w);
		wt := rnds(s.oc*(s.c/s.group)*s.kh*s.kw);
		bias := rnds(s.oc);
		(want, oh, ow) := convref(in, s.c, s.h, s.w, wt, s.oc, s.kh, s.kw, s.stride, s.pad, s.group, bias, s.act);
		out := array[4*s.oc*oh*ow] of byte;
		tensor->conv(tobytes(in), s.c, s.h, s.w, tobytes(wt), s.oc, s.kh, s.kw, s.stride, s.pad, s.group,
			tobytes(bias), s.act, out);
		what := sys->sprint("conv c=%d %dx%d oc=%d k=%dx%d s=%d p=%d g=%d act=%d", s.c, s.h, s.w, s.oc,
			s.kh, s.kw, s.stride, s.pad, s.group, s.act);
		if(close(t, toreals(out), want, 1.0e-4, what))
			t.log(what + ": ok");
	}
}

testElementwise(t: ref T)
{
	a := rnds(37);
	b := rnds(37);
	out := array[4*37] of byte;
	tensor->add(tobytes(a), tobytes(b), out);
	want := array[37] of real;
	for(i := 0; i < 37; i++)
		want[i] = a[i] + b[i];
	close(t, toreals(out), want, 1.0e-6, "add");
	acts := array[] of {Tensor->None, Tensor->Relu, Tensor->Sigmoid, Tensor->Silu};
	x := array[41] of real;
	for(i = 0; i < 41; i++)
		x[i] = real (i - 20) * 2.5;	# -50 to 50, past where exp saturates
	for(k := 0; k < len acts; k++){
		out = array[4*41] of byte;
		tensor->act(tobytes(x), out, acts[k]);
		want = array[41] of real;
		for(i = 0; i < 41; i++)
			want[i] = actref(x[i], acts[k]);
		close(t, toreals(out), want, 1.0e-5, sys->sprint("act %d", acts[k]));
	}
	# in place
	xb := tobytes(x);
	tensor->act(xb, xb, Tensor->Relu);
	for(i = 0; i < 41; i++)
		want[i] = actref(x[i], Tensor->Relu);
	close(t, toreals(xb), want, 0.0, "act in place");
}

testPool(t: ref T)
{
	(c, h, w) := (3, 7, 6);
	in := rnds(c*h*w);
	for(k := 1; k <= 5; k += 2){
		p := k/2;
		out := array[4*c*h*w] of byte;
		tensor->maxpool(tobytes(in), c, h, w, k, 1, p, out);
		want := array[c*h*w] of real;
		for(ch := 0; ch < c; ch++)
			for(y := 0; y < h; y++)
				for(x := 0; x < w; x++){
					m := -1.0e30;
					for(dy := -p; dy <= p; dy++)
						for(dx := -p; dx <= p; dx++){
							(iy, ix) := (y+dy, x+dx);
							if(iy >= 0 && iy < h && ix >= 0 && ix < w && in[(ch*h+iy)*w+ix] > m)
								m = in[(ch*h+iy)*w+ix];
						}
					want[(ch*h+y)*w+x] = m;
				}
		close(t, toreals(out), want, 1.0e-6, sys->sprint("maxpool %d", k));
	}
}

testUpS2d(t: ref T)
{
	(c, h, w) := (2, 3, 4);
	in := rnds(c*h*w);
	out := array[4*c*4*h*w] of byte;
	tensor->up2(tobytes(in), c, h, w, out);
	want := array[c*4*h*w] of real;
	for(ch := 0; ch < c; ch++)
		for(y := 0; y < 2*h; y++)
			for(x := 0; x < 2*w; x++)
				want[(ch*2*h + y)*2*w + x] = in[(ch*h + y/2)*w + x/2];
	close(t, toreals(out), want, 0.0, "up2");

	(h, w) = (4, 6);
	in = rnds(c*h*w);
	out = array[4*c*h*w] of byte;
	tensor->s2d(tobytes(in), c, h, w, out);
	want = array[c*h*w] of real;
	dys := array[] of {0, 1, 0, 1};
	dxs := array[] of {0, 0, 1, 1};
	for(q := 0; q < 4; q++)
		for(ch = 0; ch < c; ch++)
			for(yy := 0; yy < h/2; yy++)
				for(xx := 0; xx < w/2; xx++)
					want[((q*c + ch)*(h/2) + yy)*(w/2) + xx] = in[(ch*h + 2*yy + dys[q])*w + 2*xx + dxs[q]];
	close(t, toreals(out), want, 0.0, "s2d");
}

testLetterbox(t: ref T)
{
	# a 2x2 picture, blue, green, red in memory: red, green / blue, white
	pix := array[] of {
		byte 0, byte 0, byte 255,	byte 0, byte 255, byte 0,
		byte 255, byte 0, byte 0,	byte 255, byte 255, byte 255,
	};
	out := array[4*3*4*4] of byte;
	# scaled by 1 into the top left of 4x4: the rest is fill
	tensor->letterbox(pix, 2, 2, 1.0, 114, 0, out, 4, 4);
	r := toreals(out);
	# channel 0 is red: pixel (0,0) is red
	if(r[0] != 255.0 || r[16] != 0.0 || r[32] != 0.0)
		t.error(sys->sprint("rgb (0,0): %g %g %g, want 255 0 0", r[0], r[16], r[32]));
	if(r[3] != 114.0 || r[15] != 114.0 || r[2*16+15] != 114.0)
		t.error("fill not 114 outside the picture");
	tensor->letterbox(pix, 2, 2, 1.0, 114, 1, out, 4, 4);
	r = toreals(out);
	if(r[0] != 0.0 || r[32] != 255.0)
		t.error(sys->sprint("bgr (0,0): %g .. %g, want 0 .. 255", r[0], r[32]));
	# scaled by 2: bilinear, half-pixel centres; the corners are the pixels
	tensor->letterbox(pix, 2, 2, 2.0, 0, 0, out, 4, 4);
	r = toreals(out);
	if(r[0] != 255.0 || r[15] != 255.0 || r[16+3] != 255.0)
		t.error(sys->sprint("scaled corners: %g %g %g", r[0], r[15], r[19]));
	if(r[1] <= 0.0 || r[1] >= 255.0)
		t.error(sys->sprint("scaled (0,1) red %g not between", r[1]));
}

refused(t: ref T, what: string, f: ref fn())
{
	{
		f();
		t.error(what + ": not refused");
	} exception e {
	"array bounds error" or "dereference of nil" =>
		t.log(what + ": refused: " + e);
	"*" =>
		t.error(what + ": wrong exception: " + e);
	}
}

ib: array of byte;
wb: array of byte;
bb: array of byte;
ob: array of byte;

shortout()	{ tensor->conv(ib, 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob[0:4*3*16-4]); }
shortin()	{ tensor->conv(ib[0:4*2*16-4], 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob); }
shortwt()	{ tensor->conv(ib, 2, 4, 4, wb[0:4], 3, 3, 3, 1, 1, 1, bb, 0, ob); }
shortbias()	{ tensor->conv(ib, 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb[0:8], 0, ob); }
misaligned()	{ tensor->conv(ib[2:], 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob); }
badgroup()	{ tensor->conv(ib, 2, 4, 4, wb, 3, 3, 3, 1, 1, 2, bb, 0, ob); }
badpad()	{ tensor->conv(ib, 2, 4, 4, wb, 3, 3, 3, 1, 3, 1, bb, 0, ob); }
badact()	{ tensor->conv(ib, 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 9, ob); }
nilin()		{ tensor->conv(nil, 2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob); }
same()		{ tensor->conv(ob, 3, 4, 4, wb, 3, 1, 1, 1, 0, 1, bb, 0, ob); }
negdim()	{ tensor->conv(ib, -2, 4, 4, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob); }
huge()		{ tensor->conv(ib, 2, 1<<20, 1<<20, wb, 3, 3, 3, 1, 1, 1, bb, 0, ob); }
addlen()	{ tensor->add(ib, ib[0:8], ob); }
poolout()	{ tensor->maxpool(ib, 2, 4, 4, 3, 1, 1, ob[0:12]); }
s2dodd()	{ tensor->s2d(ib, 2, 3, 4, ob); }
lbshort()	{ tensor->letterbox(array[5] of byte, 2, 2, 1.0, 0, 0, ob, 2, 2); }
lbscale()	{ tensor->letterbox(array[12] of byte, 2, 2, -1.0, 0, 0, ob, 2, 2); }
realen()	{ tensor->toreal(ib, array[3] of real); }

testRefusals(t: ref T)
{
	ib = array[4*2*16] of byte;
	wb = array[4*3*2*9] of byte;
	bb = array[4*3] of byte;
	ob = array[4*3*16] of byte;
	refused(t, "short out", shortout);
	refused(t, "short in", shortin);
	refused(t, "short weights", shortwt);
	refused(t, "short bias", shortbias);
	refused(t, "a slice at 2 bytes", misaligned);
	refused(t, "group neither 1 nor c", badgroup);
	refused(t, "pad as large as the kernel", badpad);
	refused(t, "no such activation", badact);
	refused(t, "nil input", nilin);
	refused(t, "out the same array as in", same);
	refused(t, "negative channels", negdim);
	refused(t, "a tensor too large", huge);
	refused(t, "add, lengths differ", addlen);
	refused(t, "maxpool, short out", poolout);
	refused(t, "s2d, odd rows", s2dodd);
	refused(t, "letterbox, short picture", lbshort);
	refused(t, "letterbox, negative scale", lbscale);
	refused(t, "toreal, lengths differ", realen);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	tensor = load Tensor Tensor->PATH;
	if(tensor == nil){
		sys->print("SKIP: $Tensor is not built in here\n");
		skipped++;
		testing->summary(passed, failed, skipped);
		return;
	}
	sys->print("tensor: %s\n", tensor->kind());
	run("Conv", testConv);
	run("Elementwise", testElementwise);
	run("Pool", testPool);
	run("Up2S2d", testUpS2d);
	run("Letterbox", testLetterbox);
	run("Refusals", testRefusals);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
