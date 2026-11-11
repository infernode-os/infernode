implement JpegTest;

#
# jpegenc(2) and readjpg's planes (module/jpeg.m): I420 frames encoded
# and decoded back to I420 with no RGB between.  A frame of gradients,
# edges and noise comes back within JPEG's error at qualities 50, 75 and
# 90, the error falling and the size growing with quality; sizes not a
# multiple of 16 and odd sizes (padded by repeating the edge); the same
# bytes for the same frame; the output read by readjpg as an ordinary
# RGB image too; short planes, a bad size or quality refused; a JPEG
# that is not 4:2:0 refused by planes.  That a decoder written elsewhere
# reads it is checked once, by hand (PIL), not here.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
include "imagefile.m";
include "jpeg.m";
	enc: Jpegenc;
	jp: Jpegplanes;
include "math.m";
	math: Math;
include "testing.m";
	testing: Testing;
	T: import testing;

JpegTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jpeg_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# a frame of gradients, a few hard edges and some noise
frame(w, h: int): (array of byte, array of byte, array of byte)
{
	cw := (w + 1) / 2;
	ch := (h + 1) / 2;
	y := array[w*h] of byte;
	u := array[cw*ch] of byte;
	v := array[cw*ch] of byte;
	seed := 12345;
	for(r := 0; r < h; r++)
		for(c := 0; c < w; c++){
			seed = seed * 1103515245 + 12345;
			p := (c * 200) / w + (r * 40) / h + ((seed >> 16) & 7);
			if((c / 37 + r / 23) % 3 == 0)
				p = 255 - p;	# an edge every so often
			if(p > 255)
				p = 255;
			y[r*w+c] = byte p;
		}
	for(r = 0; r < ch; r++)
		for(k := 0; k < cw; k++){
			u[r*cw+k] = byte (64 + (k * 128) / cw);
			v[r*cw+k] = byte (192 - (r * 128) / ch);
		}
	return (y, u, v);
}

psnr(a, b: array of byte): real
{
	if(len a != len b || len a == 0)
		return 0.0;
	s := 0.0;
	for(i := 0; i < len a; i++){
		d := real (int a[i] - int b[i]);
		s += d * d;
	}
	if(s == 0.0)
		return 99.0;
	return 10.0 * math->log10(255.0 * 255.0 * real len a / s);
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testRoundTrip(t: ref T)
{
	w := 480;
	h := 270;
	(y, u, v) := frame(w, h);
	lastsize := 0;
	lastdb := 0.0;
	for(ql := 50 :: 75 :: 90 :: nil; ql != nil; ql = tl ql){
		q := hd ql;
		(j, err) := enc->encode(w, h, y, u, v, q);
		if(j == nil)
			t.fatal(sys->sprint("q%d: %s", q, err));
		(dw, dh, dy, du, dv, derr) := jp->planes(j);
		t.assertnil(derr, sys->sprint("q%d: planes", q));
		t.assert(dw == w && dh == h, sys->sprint("q%d: %dx%d back", q, dw, dh));
		py := psnr(dy, y);
		pu := psnr(du, u);
		pv := psnr(dv, v);
		t.log(sys->sprint("q%d: %d bytes; Y %.1f U %.1f V %.1f dB", q, len j, py, pu, pv));
		t.assert(py > 26.0 && pu > 30.0 && pv > 30.0, sys->sprint("q%d: within JPEG's error (Y %.1f, U %.1f, V %.1f dB)", q, py, pu, pv));
		t.assert(len j > lastsize, sys->sprint("q%d: larger than at a lower quality (%d, %d)", q, len j, lastsize));
		t.assert(py > lastdb, sys->sprint("q%d: closer than at a lower quality", q));
		lastsize = len j;
		lastdb = py;
	}
}

testSizes(t: ref T)
{
	for(sl := (16, 16) :: (17, 9) :: (1, 1) :: (333, 201) :: (640, 360) :: nil; sl != nil; sl = tl sl){
		(w, h) := hd sl;
		(y, u, v) := frame(w, h);
		(j, err) := enc->encode(w, h, y, u, v, 85);
		if(j == nil){
			t.error(sys->sprint("%dx%d: %s", w, h, err));
			continue;
		}
		(dw, dh, dy, nil, nil, derr) := jp->planes(j);
		if(derr != nil){
			t.error(sys->sprint("%dx%d: planes: %s", w, h, derr));
			continue;
		}
		t.assert(dw == w && dh == h && len dy == w*h, sys->sprint("%dx%d back as %dx%d", w, h, dw, dh));
		if(w*h >= 64)
			t.assert(psnr(dy, y) > 26.0, sys->sprint("%dx%d: within JPEG's error (%.1f dB)", w, h, psnr(dy, y)));
	}
}

testDeterministic(t: ref T)
{
	(y, u, v) := frame(320, 240);
	(a, nil) := enc->encode(320, 240, y, u, v, 75);
	(b, nil) := enc->encode(320, 240, y, u, v, 75);
	t.assert(a != nil && same(a, b), "the same frame, the same bytes");
}

testRGBReader(t: ref T)
{
	(y, u, v) := frame(96, 64);
	(j, nil) := enc->encode(96, 64, y, u, v, 90);
	f := "/tmp/jpeg_test.jpg";
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.skip(sys->sprint("can't create %s: %r", f));
	sys->write(fd, j, len j);
	fd = nil;
	rd := load RImagefile RImagefile->READJPGPATH;
	rd->init(bufio);
	(im, err) := rd->read(bufio->open(f, Bufio->OREAD));
	sys->remove(f);
	t.assertnil(err, "readjpg reads it as an image");
	t.assert(im != nil && im.r.max.x == 96 && im.r.max.y == 64 && im.nchans == 3, "96x64, three channels");
}

testRefused(t: ref T)
{
	(y, u, v) := frame(64, 64);
	(j, err) := enc->encode(64, 64, y[0:100], u, v, 75);
	t.assert(j == nil && err != nil, "short planes refused");
	(j, err) = enc->encode(0, 64, y, u, v, 75);
	t.assert(j == nil && err != nil, "a zero width refused");
	(j, err) = enc->encode(64, 64, y, u, v, 0);
	t.assert(j == nil && err != nil, "quality 0 refused");
	(j, err) = enc->encode(64, 64, y, u, v, 101);
	t.assert(j == nil && err != nil, "quality 101 refused");
	(nil, nil, nil, nil, nil, derr) := jp->planes(array of byte "not a jpeg at all");
	t.assertnotnil(derr, "planes refuses what is not a JPEG");
	# a grey (one-component) JPEG is not 4:2:0: written by hand, the
	# smallest baseline file (SOI, DQT, SOF0 one component, DHT, SOS, data, EOI)
	(full, nil) := enc->encode(16, 16, y[0:256], u[0:64], v[0:64], 75);
	if(full != nil){
		# set the frame's component count to 1 (SOF0: FF C0, length, 8, h, w, n)
		g := array[len full] of byte;
		g[0:] = full;
		for(i := 0; i + 9 < len g; i++)
			if(g[i] == byte 16rFF && g[i+1] == byte 16rC0){
				g[i+9] = byte 1;
				break;
			}
		(nil, nil, nil, nil, nil, derr) = jp->planes(g);
		t.assertnotnil(derr, "planes refuses a frame not of three components");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	enc = load Jpegenc Jpegenc->PATH;
	jp = load Jpegplanes Jpegplanes->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := tl args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(enc == nil || jp == nil){
		sys->fprint(sys->fildes(2), "jpeg_test: can't load jpegenc or readjpg's planes: %r\n");
		raise "fail:load";
	}
	run("Jpeg/RoundTrip", testRoundTrip);
	run("Jpeg/Sizes", testSizes);
	run("Jpeg/Deterministic", testDeterministic);
	run("Jpeg/RGBReader", testRGBReader);
	run("Jpeg/Refused", testRefused);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
