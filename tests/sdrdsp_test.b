implement SdrdspTest;

#
# sdrdsp (module/sdrdsp.m), the arithmetic of sdr(1)'s demodulators:
# 8-bit samples summed and scaled; a filter's impulse response, its gain
# where it passes and where it stops, and its state carried from one
# call to the next; a rate changed by averaging; sound as 16-bit
# little-endian, the level taken out, clipped; rates and frequencies as
# sdrfs writes them; headers made padded to 4 bytes and read back, read
# from their start (more wanted), and refused.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "math.m";
	math: Math;

include "testing.m";
	testing: Testing;
	T: import testing;

include "sdrdsp.m";
	dsp: Sdrdsp;
	Decim, Fir, Resamp, Pcm, Hdr: import dsp;

SdrdspTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sdrdsp_test.b";

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

near(a, b, eps: real): int
{
	d := a - b;
	if(d < 0.0)
		d = -d;
	return d <= eps;
}

testDecim(t: ref T)
{
	d := Decim.new(3);
	# I 0, 255, 255 -> (510/3 - 127.5)/127.5; Q 255 thrice -> 1
	b := array[] of {byte 0, byte 255, byte 255, byte 255, byte 255, byte 255, byte 128, byte 127};
	i := array[4] of real;
	q := array[4] of real;
	n := d.run(b, 6, i, q);
	t.asserteq(n, 1, "three samples are one");
	t.assert(near(i[0], (510.0/3.0 - 127.5)/127.5, 1e-9), sys->sprint("I %g", i[0]));
	t.assert(near(q[0], 1.0, 1e-9), sys->sprint("Q %g", q[0]));
	# the sum carried into the next call
	n = d.run(b[6:], 2, i, q);
	t.asserteq(n, 0, "one sample of three: none out yet");
	n = d.run(b, 4, i, q);
	t.asserteq(n, 1, "the third");
	t.assert(near(i[0], (128.0 + 0.0 + 255.0)/3.0/127.5 - 1.0, 1e-9), sys->sprint("carried I %g", i[0]));
}

# a filter's impulse response is its taps, every nth, whatever the
# calls it is fed in
testFirImpulse(t: ref T)
{
	taps := 31;
	f := Fir.new(1, 0.1, taps);
	g := Fir.new(1, 0.1, taps);
	x := array[100] of {* => 0.0};
	x[0] = 1.0;
	y := array[100] of real;
	n := f.runr(x, 100, y);
	t.asserteq(n, 100, "one out for one in");
	sum := 0.0;
	for(j := 0; j < taps; j++)
		sum += y[j];
	t.assert(near(sum, 1.0, 1e-9), sys->sprint("gain at DC %g", sum));
	for(j = 0; j < taps; j++)
		t.assert(near(y[j], y[taps-1-j], 1e-12), sys->sprint("symmetric at %d", j));
	for(j = taps; j < 100; j++)
		if(y[j] != 0.0) {
			t.error(sys->sprint("response past its taps at %d: %g", j, y[j]));
			break;
		}
	# fed in pieces of 7, the same
	z := array[100] of real;
	o := 0;
	for(j = 0; j < 100; j += 7) {
		k := 7;
		if(j + k > 100)
			k = 100 - j;
		o += g.runr(x[j:], k, z[o:]);
	}
	t.asserteq(o, 100, "pieces: one out for one in");
	for(j = 0; j < 100; j++)
		if(!near(y[j], z[j], 1e-12)) {
			t.error(sys->sprint("pieces differ at %d: %g %g", j, y[j], z[j]));
			break;
		}
	# decimated by 4: every fourth of it, from the fourth
	h := Fir.new(4, 0.1, taps);
	n = h.runr(x, 100, z);
	t.asserteq(n, 25, "a quarter out");
	for(j = 0; j < 25; j++)
		if(!near(z[j], y[4*j+3], 1e-12)) {
			t.error(sys->sprint("decimated %d: %g, want %g", j, z[j], y[4*j+3]));
			break;
		}
}

# a sine's level through the filter, once it has settled
level(f: ref Fir, freq: real, cplx: int): real
{
	m := 4000;
	x := array[m] of real;
	xq := array[m] of real;
	for(j := 0; j < m; j++) {
		x[j] = math->cos(2.0 * Math->Pi * freq * real j);
		xq[j] = math->sin(2.0 * Math->Pi * freq * real j);
	}
	y := array[m] of real;
	yq := array[m] of real;
	n: int;
	if(cplx)
		n = f.run(x, xq, m, y, yq);
	else
		n = f.runr(x, m, y);
	peak := 0.0;
	for(j = n/2; j < n; j++) {
		v := y[j];
		if(cplx)
			v = math->sqrt(y[j]*y[j] + yq[j]*yq[j]);
		if(v < 0.0)
			v = -v;
		if(v > peak)
			peak = v;
	}
	return peak;
}

testFirResponse(t: ref T)
{
	# passes below cutoff (0.0625), stops well beyond
	for(c := 0; c < 2; c++) {
		p := level(Fir.new(1, 0.0625, 96), 0.02, c);
		t.assert(near(p, 1.0, 0.01), sys->sprint("passband (complex %d): %g", c, p));
		s := level(Fir.new(1, 0.0625, 96), 0.15, c);
		t.assert(s < 1e-3, sys->sprint("stopband (complex %d): %g", c, s));
	}
	# complex: a negative frequency as a positive
	p := level(Fir.new(1, 0.0625, 96), -0.02, 1);
	t.assert(near(p, 1.0, 0.01), sys->sprint("negative frequency: %g", p));
}

testResamp(t: ref T)
{
	# 5 to 2: each out two and a half in, the one between shared
	r := Resamp.new(5, 2);
	x := array[] of {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0};
	y := array[10] of real;
	n := r.run(x, 10, y);
	t.asserteq(n, 4, "ten in, four out");
	# (1+2+3/2)/2.5, (3/2+4+5)/2.5, ...
	want := array[] of {1.8, 4.2, 6.8, 9.2};
	for(j := 0; j < n && j < len want; j++)
		t.assert(near(y[j], want[j], 1e-9), sys->sprint("%d: %g, want %g", j, y[j], want[j]));
	# the same rate: each sample as it was
	r = Resamp.new(48000, 48000);
	n = r.run(x, 10, y);
	t.asserteq(n, 10, "the same rate");
	t.assert(near(y[9], 10.0, 1e-9), "unchanged");
}

testPcm(t: ref T)
{
	p := Pcm.new(48000, 2);
	p.a = 0.0;	# the level not followed, to see the values
	y := array[] of {0.5, -0.5, 2.0};
	b := array[3*4] of byte;
	n := p.run(y, 3, 1.0, b);
	t.asserteq(n, 12, "two channels of two bytes");
	v := int b[0] | (int b[1] << 8);
	t.asserteq(v, 16384, "0.5, little-endian");
	t.asserteq(int b[2] | (int b[3] << 8), v, "the same in each channel");
	v = int b[4] | (int b[5] << 8);
	t.asserteq(v, 16r10000 - 16384, "-0.5");
	t.asserteq(int b[8] | (int b[9] << 8), 32767, "clipped");
	t.asserteq(p.clipped, 1, "the clip counted");
	# a constant level taken out
	p = Pcm.new(1000, 1);
	c := array[5000] of {* => 0.3};
	o := array[2*5000] of byte;
	p.run(c, 5000, 1.0, o);
	v = int o[2*4999] | (int o[2*4999+1] << 8);
	if(v >= 16r8000)
		v -= 16r10000;
	t.assert(v > -50 && v < 50, sys->sprint("a constant taken out: %d", v));
}

testRate(t: ref T)
{
	t.asserteq(dsp->rate("2.4M"), 2400000, "2.4M");
	t.asserteq(dsp->rate("240k"), 240000, "240k");
	t.asserteq(dsp->rate("2048000"), 2048000, "plain");
	t.asserteq(dsp->rate("22.05k"), 22050, "22.05k");
	t.asserteq(dsp->rate("fast"), 0, "not a rate");
	t.asserteq(dsp->rate(""), 0, "nothing");
	t.asserteq(dsp->rate("-5"), 0, "negative");
}

testHertz(t: ref T)
{
	t.assert(dsp->hertz("99.5M") == big 99500000, "99.5M");
	t.assert(dsp->hertz("1090000000") == big 1090000000, "plain");
	t.assert(dsp->hertz("1.09G") == big 1090000000, "1.09G");
	t.assert(dsp->hertz("162.025M") == big 162025000, "162.025M");
	t.assert(dsp->hertz("99.5") < big 0, "a fraction of a hertz");
	t.assert(dsp->hertz("loud") < big 0, "not a frequency");
	t.assert(dsp->hertz("") < big 0, "nothing");
}

# the lines of a header made and read back, padded to 4 as auplay(1)
# requires, whatever their length
testHeader(t: ref T)
{
	for(n := 0; n < 8; n++) {
		s := "rate 2400000\nenc cu8\nfreq 99500000\n" + "x" + string array[n] of {* => byte 'y'} + " 1\n";
		h := dsp->header(s);
		t.asserteq(len h % 4, 0, sys->sprint("padded to 4: %d", len h));
		t.assert(len h >= len s + 1 && len h <= len s + 4, sys->sprint("padded by at most 3: %d for %d", len h, len s));
		t.assert(h[len h - 1] == byte '\n' && h[len h - 2] == byte '\n', "an empty line at its end");
		(r, k, e) := Hdr.read(h, len h);
		t.assertnil(e, "read back");
		t.asserteq(k, len h, "all of it");
		if(r == nil)
			continue;
		t.assertseq(r.text(), s, "its lines, without the padding");
	}
	# a line with no newline is given one
	h := dsp->header("rate 8000");
	t.assertseq(string h, "rate 8000 \n\n", "rate 8000, padded");
}

testHdrRead(t: ref T)
{
	b := array of byte "rate 2400000\nenc cu8\nfreq 99.5M  \n\n";
	all := array[len b + 4] of byte;
	all[0:] = b;
	all[len b:] = array[] of {byte 0, byte 255, byte 1, byte 254};
	(h, k, e) := Hdr.read(all, len all);
	t.assertnil(e, "a header");
	t.asserteq(k, len b, "its length, not the samples after it");
	if(h == nil)
		t.fatal("no header");
	t.asserteq(h.rate, 2400000, "rate");
	t.assertseq(h.enc, "cu8", "enc");
	t.assert(h.freq == big 99500000, sys->sprint("freq %bd", h.freq));
	t.assertseq(h.text(), "rate 2400000\nenc cu8\nfreq 99.5M\n", "lines, blanks taken out");

	# only its start: read more, at every length short of the end
	for(n := 0; n < len b; n++) {
		(nil, k, e) = Hdr.read(b, n);
		t.asserteq(k, 0, sys->sprint("%d bytes of it: more wanted (%s)", n, e));
	}

	# no freq, other lines kept
	(h, k, e) = Hdr.read(array of byte "rate 250k\ngain 20\n\n", 19);
	t.assertnil(e, "no freq");
	if(h != nil) {
		t.asserteq(h.rate, 250000, "250k");
		t.assert(h.freq == big -1, "no freq: -1");
		t.assert(h.enc == nil, "no enc: nil");
		t.assertseq(h.text(), "rate 250k\ngain 20\n", "every line");
	}

	# refused
	refused := array[] of {
		("samples", string array[] of {byte 0, byte 255, byte 1, byte 254, byte 2, byte 253}, "no header"),
		("not rate first", "freq 99M\nrate 2400000\n\n", "no header"),
		("a bad rate", "rate fast\n\n", "bad header line: rate fast"),
		("a bad freq", "rate 2400000\nfreq loud\n\n", "bad header line: freq loud"),
		("no rate", "rate\nenc cu8\n\n", "bad header: no rate"),
		("binary", "rate 2400000\n\001\002\n\n", "no header: not text"),
	};
	for(i := 0; i < len refused; i++) {
		(what, s, want) := refused[i];
		x := array of byte s;
		(h, k, e) = Hdr.read(x, len x);
		t.asserteq(k, -1, what + ": refused");
		t.assertseq(e, want, what);
	}
	long := array[Sdrdsp->Maxhdr + 10] of {* => byte 'a'};
	long[0:] = array of byte "rate 1\n";
	(nil, k, e) = Hdr.read(long, len long);
	t.asserteq(k, -1, "too long: refused");
	t.assertseq(e, "header too long", "too long");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	dsp = load Sdrdsp Sdrdsp->PATH;
	if(testing == nil || dsp == nil || math == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	dsp->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Decim", testDecim);
	run("FirImpulse", testFirImpulse);
	run("FirResponse", testFirResponse);
	run("Resamp", testResamp);
	run("Pcm", testPcm);
	run("Rate", testRate);
	run("Hertz", testHertz);
	run("Header", testHeader);
	run("HdrRead", testHdrRead);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
