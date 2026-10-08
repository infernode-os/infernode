implement ReadwebpTest;

#
# readwebp against libwebp: every vector in tests/web/webp/vectors
# (made by mkvectors.py there: lossless, lossy, alpha in each encoding
# and filter, token partitions, both loop filters, animations) decoded
# and compared, pixel by pixel, with libwebp's own decoding of it,
# kept beside it as a PNG.  Colour within the vector's tolerance,
# alpha exactly.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";
	Rawimage: import RImagefile;

include "testing.m";
	testing: Testing;
	T: import testing;

ReadwebpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/readwebp_test.b";
DIR: con "/tests/web/webp/";

passed := 0;
failed := 0;
skipped := 0;

webp: RImagefile;
png: RImagefile;

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

# the vector being run (a test function takes only its T)
vname: string;
vframes: int;
vtol: int;

open(t: ref T, file: string): ref Iobuf
{
	f := bufio->open(DIR + file, Bufio->OREAD);
	if(f == nil)
		t.fatal(sys->sprint("open %s: %r", file));
	return f;
}

testVector(t: ref T)
{
	if(vframes == 0) {
		(got, err) := webp->read(open(t, vname + ".webp"));
		if(got == nil)
			t.fatal(vname + ": " + err);
		compare(t, vname, got, ref1(t, vname + ".png"));
		return;
	}
	(frames, err) := webp->readmulti(open(t, vname + ".webp"));
	if(frames == nil)
		t.fatal(vname + ": " + err);
	t.asserteq(len frames, vframes, vname + " frames");
	for(i := 0; i < len frames && i < vframes; i++) {
		n := sys->sprint("%s.%d", vname, i);
		compare(t, n, frames[i], ref1(t, n + ".png"));
	}
	# read() is the first frame
	(first, nil) := webp->read(open(t, vname + ".webp"));
	if(first != nil)
		compare(t, vname + " read", first, ref1(t, vname + ".0.png"));
}

ref1(t: ref T, file: string): ref Rawimage
{
	(r, err) := png->read(open(t, file));
	if(r == nil)
		t.fatal(file + ": " + err);
	return r;
}

compare(t: ref T, name: string, got, want: ref Rawimage)
{
	w := want.r.max.x - want.r.min.x;
	h := want.r.max.y - want.r.min.y;
	gw := got.r.max.x - got.r.min.x;
	gh := got.r.max.y - got.r.min.y;
	if(gw != w || gh != h) {
		t.error(sys->sprint("%s: %dx%d, want %dx%d", name, gw, gh, w, h));
		return;
	}
	worst := 0;
	bad := 0;
	first := "";
	for(i := 0; i < w*h; i++) {
		(r, g, b, a) := pixel(got, i);
		(wr, wg, wb, wa) := pixel(want, i);
		d := max(abs(r - wr), max(abs(g - wg), abs(b - wb)));
		if(wa == 0 && a == 0)
			d = 0;	# a transparent pixel's colour is anything
		if(d > worst)
			worst = d;
		if(d > vtol || a != wa) {
			if(bad++ == 0)
				first = sys->sprint("(%d,%d) got %d %d %d %d, want %d %d %d %d",
					i % w, i / w, r, g, b, a, wr, wg, wb, wa);
		}
	}
	t.log(sys->sprint("%s: %dx%d, largest colour difference %d", name, w, h, worst));
	if(bad > 0)
		t.error(sys->sprint("%s: %d of %d pixels differ beyond %d, first at %s", name, bad, w*h, vtol, first));
}

pixel(raw: ref Rawimage, i: int): (int, int, int, int)
{
	case raw.chandesc {
	RImagefile->CRGBA =>
		return (int raw.chans[0][i], int raw.chans[1][i], int raw.chans[2][i], int raw.chans[3][i]);
	RImagefile->CRGB =>
		return (int raw.chans[0][i], int raw.chans[1][i], int raw.chans[2][i], 255);
	RImagefile->CY =>
		v := int raw.chans[0][i];
		return (v, v, v, 255);
	RImagefile->CRGB1 =>
		k := 3 * int raw.chans[0][i];
		return (int raw.cmap[k], int raw.cmap[k+1], int raw.cmap[k+2], 255);
	}
	return (-1, -1, -1, -1);
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	webp = load RImagefile RImagefile->READWEBPPATH;
	png = load RImagefile RImagefile->READPNGPATH;
	if(testing == nil || bufio == nil || webp == nil || png == nil) {
		sys->fprint(sys->fildes(2), "cannot load: %r\n");
		raise "fail:load";
	}
	testing->init();
	webp->init(bufio);
	png->init(bufio);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	m := bufio->open(DIR + "vectors", Bufio->OREAD);
	if(m == nil) {
		sys->fprint(sys->fildes(2), "no vectors: %r\n");
		raise "fail:vectors";
	}
	while((l := m.gets('\n')) != nil) {
		(n, f) := sys->tokenize(l, " \t\n");
		if(n != 3)
			continue;
		vname = hd f;
		vframes = int hd tl f;
		vtol = int hd tl tl f;
		run(vname, testVector);
	}

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
