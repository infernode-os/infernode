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
		Shape(5, 16, 23, 5, 3, 3, 1, 1, 5, Tensor->Silu),	# depthwise 3x3 s1, NEON's interior, odd width
		Shape(4, 17, 30, 4, 3, 3, 2, 1, 4, Tensor->Silu),	# depthwise 3x3 s2, NEON's interior
		Shape(3, 9, 41, 3, 3, 3, 2, 1, 3, Tensor->None),	# s2, an odd width, row end
		Shape(2, 4, 4, 2, 3, 3, 1, 0, 2, Tensor->None),		# no padding, small
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
	(c, h, w) := (3, 15, 14);
	in := rnds(c*h*w);
	# the SPP block's 5, 9 and 13, with padding; and stride 2, no padding
	cases := array[] of {(1, 1, 0), (3, 1, 1), (5, 1, 2), (9, 1, 4), (13, 1, 6), (2, 2, 0), (3, 2, 1)};
	for(i := 0; i < len cases; i++){
		(k, s, p) := cases[i];
		oh := (h + 2*p - k) / s + 1;
		ow := (w + 2*p - k) / s + 1;
		out := array[4*c*oh*ow] of byte;
		tensor->maxpool(tobytes(in), c, h, w, k, s, p, out);
		want := array[c*oh*ow] of real;
		for(ch := 0; ch < c; ch++)
			for(y := 0; y < oh; y++)
				for(x := 0; x < ow; x++){
					m := -1.0e30;
					for(dy := 0; dy < k; dy++)
						for(dx := 0; dx < k; dx++){
							(iy, ix) := (y*s - p + dy, x*s - p + dx);
							if(iy >= 0 && iy < h && ix >= 0 && ix < w && in[(ch*h+iy)*w+ix] > m)
								m = in[(ch*h+iy)*w+ix];
						}
					want[(ch*oh+y)*ow+x] = m;
				}
		close(t, toreals(out), want, 0.0, sys->sprint("maxpool %d stride %d", k, s));
	}
}

# IEEE half: known patterns, integers exact, both the NEON loop and the C
# tail (a length of 4n+3), and back
testHalf(t: ref T)
{
	vals := array[] of {1.0, -2.0, 0.0, 65504.0, 1.0e6, 0.1, 5.96046447753906e-8, 0.333333333, -0.0, 2049.0, 2051.0};
	want := array[] of {16r3c00, 16rc000, 16r0000, 16r7bff, 16r7c00, 16r2e66, 16r0001, 16r3555, 16r8000, 16r6800, 16r6802};
	for(rep := 0; rep < 2; rep++){
		# twice: alone (the C tail) and as the first of 12 (NEON's)
		n := len vals;
		if(rep)
			n = 12;
		r := array[n] of real;
		for(i := 0; i < n; i++)
			r[i] = vals[i % len vals];
		hb := array[2*n] of byte;
		tensor->tohalf(tobytes(r), hb);
		for(i = 0; i < len vals; i++){
			got := int hb[2*i] | int hb[2*i+1] << 8;
			t.asserteq(got, want[i], sys->sprint("half of %g (pass %d)", vals[i], rep));
		}
	}
	# 0 .. 2048 exact both ways, 2051 elements: NEON and the tail
	n := 2051;
	r := array[n] of real;
	for(i := 0; i < n; i++)
		r[i] = real (i % 2049);
	hb := array[2*n] of byte;
	tensor->tohalf(tobytes(r), hb);
	back := array[4*n] of byte;
	tensor->fromhalf(hb, back);
	close(t, toreals(back), r, 0.0, "integers to 2048 through half");
	# and a real's rounding error within half's
	for(i = 0; i < n; i++)
		r[i] = real i * 0.0137 - 9.0;
	tensor->tohalf(tobytes(r), hb);
	tensor->fromhalf(hb, back);
	close(t, toreals(back), r, 0.0005, "reals through half");
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

clamp255(v: real): real
{
	if(v < 0.0)
		return 0.0;
	if(v > 255.0)
		return 255.0;
	return v;
}

bilin(p: array of byte, w, h: int, sx, sy: real): real
{
	if(sx < 0.0)
		sx = 0.0;
	if(sy < 0.0)
		sy = 0.0;
	x0 := int sx;
	if(real x0 > sx)
		x0--;
	y0 := int sy;
	if(real y0 > sy)
		y0--;
	if(x0 > w-1)
		x0 = w-1;
	if(y0 > h-1)
		y0 = h-1;
	x1 := x0+1;
	if(x1 > w-1)
		x1 = w-1;
	y1 := y0+1;
	if(y1 > h-1)
		y1 = h-1;
	fx := sx - real x0;
	fy := sy - real y0;
	return (1.0-fy)*((1.0-fx)*real p[y0*w+x0] + fx*real p[y0*w+x1]) + fy*((1.0-fx)*real p[y1*w+x0] + fx*real p[y1*w+x1]);
}

testLetterboxI420(t: ref T)
{
	(w, h) := (8, 6);
	y := array[w*h] of byte;
	cb := array[(w/2)*(h/2)] of byte;
	cr := array[(w/2)*(h/2)] of byte;
	for(i := 0; i < len y; i++)
		y[i] = byte (16 + 9*i);
	for(i = 0; i < len cb; i++){
		cb[i] = byte (40 + 15*i);
		cr[i] = byte (220 - 13*i);
	}
	(ow, oh) := (12, 12);
	scale := 1.5;	# 12x9, the rest fill
	out := array[4*3*ow*oh] of byte;
	tensor->letterboxi420(y, cb, cr, w, h, scale, 114, 0, out, ow, oh);
	got := toreals(out);
	want := array[3*ow*oh] of real;
	(rw, rh) := (int (real w*scale), int (real h*scale));
	if(real rw > real w*scale)
		rw--;
	if(real rh > real h*scale)
		rh--;
	for(yy := 0; yy < oh; yy++)
		for(xx := 0; xx < ow; xx++){
			if(yy >= rh || xx >= rw){
				for(c := 0; c < 3; c++)
					want[(c*oh + yy)*ow + xx] = 114.0;
				continue;
			}
			sy := (real yy + 0.5) * real h / real rh - 0.5;
			sx := (real xx + 0.5) * real w / real rw - 0.5;
			l := bilin(y, w, h, sx, sy);
			u := bilin(cb, w/2, h/2, (sx - 0.5)/2.0, (sy - 0.5)/2.0) - 128.0;
			v := bilin(cr, w/2, h/2, (sx - 0.5)/2.0, (sy - 0.5)/2.0) - 128.0;
			want[(0*oh + yy)*ow + xx] = clamp255(l + 1.402*v);
			want[(1*oh + yy)*ow + xx] = clamp255(l - 0.34414*u - 0.71414*v);
			want[(2*oh + yy)*ow + xx] = clamp255(l + 1.772*u);
		}
	close(t, got, want, 1.0e-3, "letterboxi420 against the reference");
	# pure red, as full-range JPEG gives it: Y 76, Cb 85, Cr 255
	for(i = 0; i < len y; i++)
		y[i] = byte 76;
	for(i = 0; i < len cb; i++){
		cb[i] = byte 85;
		cr[i] = byte 255;
	}
	tensor->letterboxi420(y, cb, cr, w, h, 1.0, 0, 0, out[0:4*3*w*h], w, h);
	r := toreals(out[0:4*3*w*h]);
	if(r[0] < 250.0 || r[w*h] > 5.0 || r[2*w*h] > 5.0)
		t.error(sys->sprint("red came out %g %g %g", r[0], r[w*h], r[2*w*h]));
	tensor->letterboxi420(y, cb, cr, w, h, 1.0, 0, 1, out[0:4*3*w*h], w, h);
	r = toreals(out[0:4*3*w*h]);
	if(r[2*w*h] < 250.0 || r[0] > 5.0)
		t.error(sys->sprint("red, bgr, came out %g .. %g", r[0], r[2*w*h]));
}

i420odd()	{ tensor->letterboxi420(array[15] of byte, array[4] of byte, array[4] of byte, 5, 3, 1.0, 0, 0, ob, 2, 2); }
i420short()	{ tensor->letterboxi420(array[15] of byte, array[4] of byte, array[4] of byte, 4, 4, 1.0, 0, 0, ob, 2, 2); }

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
halflen()	{ tensor->tohalf(array[16] of byte, array[6] of byte); }
halfsame()	{ b := array[16] of byte; tensor->fromhalf(b[0:8], b); }

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
	refused(t, "tohalf, lengths differ", halflen);
	refused(t, "fromhalf into its own array", halfsame);
	refused(t, "letterboxi420, odd width", i420odd);
	refused(t, "letterboxi420, short luma", i420short);
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
	run("Half", testHalf);
	run("Letterbox", testLetterbox);
	run("LetterboxI420", testLetterboxI420);
	run("Refusals", testRefusals);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
