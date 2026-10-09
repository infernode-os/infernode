implement ReadwebpTest;

#
# The WebP decoder (appl/lib/readwebp.b), pixel for pixel.
#
# Each fixture in /tests/imgload made by mkfixtures.py there is
# decoded, and its every frame compared with what libwebp decodes it
# to: webp.md5 holds, for each, its size, its frames and the MD5 of
# every frame's R, G, B and A planes in turn (A all 255 when the
# decoder says the image is opaque).
#
# Tests:
# - Lossy (VP8): prediction, coefficients, the loop filter, and the
#   chroma upsampled and converted to RGB as libwebp does
# - Lossy with its alpha in an ALPH chunk, compressed and filtered
# - Lossless (VP8L) with alpha: its transforms and colour cache
# - Lossless with a palette of a few colours, packed several to a pixel
# - An animation: frames smaller than the canvas, one disposed of,
#   others blended over what is left; read gives only the first
# - What is not WebP, or is broken or too large, is refused
#
# No display is needed: the decoder makes Rawimages, not Images.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";
	readwebp: RImagefile;
	Rawimage: import RImagefile;

include "keyring.m";
	keyring: Keyring;

include "testing.m";
	testing: Testing;
	T: import testing;

ReadwebpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

SRCFILE: con "/tests/readwebp_test.b";
FIXTURES: con "/tests/imgload";

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

# What libwebp makes of a fixture, from webp.md5
Want: adt {
	w, h:	int;
	nframes:	int;
	md5:	string;
};

want(t: ref T, name: string): ref Want
{
	b := bufio->open(FIXTURES + "/webp.md5", Bufio->OREAD);
	if(b == nil)
		t.fatal(sys->sprint("%s/webp.md5: %r", FIXTURES));
	while((l := b.gets('\n')) != nil) {
		(n, f) := sys->tokenize(l, " \n");
		if(n == 5 && hd f == name) {
			f = tl f;
			w := int hd f;
			h := int hd tl f;
			nf := int hd tl tl f;
			return ref Want(w, h, nf, hd tl tl tl f);
		}
	}
	t.fatal(name + " is not in webp.md5");
	return nil;
}

# The MD5 of frames' R, G, B and A planes, in hex
digest(frames: array of ref Rawimage): string
{
	state: ref Keyring->DigestState;
	for(i := 0; i < len frames; i++) {
		c := frames[i].chans;
		for(j := 0; j < 3; j++)
			state = keyring->md5(c[j], len c[j], nil, state);
		if(len c > 3)
			state = keyring->md5(c[3], len c[3], nil, state);
		else {
			opaque := array[len c[0]] of {* => byte 255};
			state = keyring->md5(opaque, len opaque, nil, state);
		}
	}
	d := array[Keyring->MD5dlen] of byte;
	keyring->md5(nil, 0, d, state);
	s := "";
	for(i = 0; i < len d; i++)
		s += sys->sprint("%02x", int d[i]);
	return s;
}

decode(t: ref T, name: string, multi: int): array of ref Rawimage
{
	path := FIXTURES + "/" + name + ".webp";
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		t.fatal(sys->sprint("%s: %r", path));
	if(multi) {
		(a, err) := readwebp->readmulti(b);
		if(a == nil)
			t.fatal(name + ": " + err);
		return a;
	}
	(r, err) := readwebp->read(b);
	if(r == nil)
		t.fatal(name + ": " + err);
	return array[] of {r};
}

# Decode a fixture and compare it with libwebp's decoding
check(t: ref T, name: string, chandesc: int)
{
	w := want(t, name);
	a := decode(t, name, 1);
	t.asserteq(len a, w.nframes, name + " frames");
	r := a[0].r;
	t.asserteq(r.max.x - r.min.x, w.w, name + " width");
	t.asserteq(r.max.y - r.min.y, w.h, name + " height");
	t.asserteq(a[0].chandesc, chandesc, name + " channels");
	t.assertseq(digest(a), w.md5, name + " pixels, as libwebp decodes them");
}

testLossy(t: ref T)		{ check(t, "webp-lossy", RImagefile->CRGB); }
testLossyAlpha(t: ref T)	{ check(t, "webp-lossya", RImagefile->CRGBA); }
testLossless(t: ref T)		{ check(t, "webp-lossless", RImagefile->CRGBA); }
testPalette(t: ref T)		{ check(t, "webp-pal", RImagefile->CRGB); }

testAnimation(t: ref T)
{
	check(t, "webp-anim", RImagefile->CRGBA);
	a := decode(t, "webp-anim", 1);
	if(len a == 3) {
		t.asserteq(a[0].fields, 50, "first frame's duration");
		t.asserteq(a[2].fields, 70, "last frame's duration");
	}

	# read: the first frame alone
	one := decode(t, "webp-anim", 0);
	t.assertseq(digest(one), digest(a[0:1]), "read gives the first frame");
}

# A file's bytes, refused with an error that has want in it
refused(t: ref T, what: string, data: array of byte, want: string)
{
	(r, err) := readwebp->read(bufio->aopen(data));
	t.assert(r == nil, what + " is not decoded");
	if(!contains(err, want))
		t.error(sys->sprint("%s: error %q, want one with %q", what, err, want));
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

readfile(t: ref T, path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("%s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		t.fatal(sys->sprint("%s: %r", path));
	buf := array[int d.length] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		t.fatal(sys->sprint("%s: %r", path));
	return buf[0:n];
}

# A RIFF WEBP file of one chunk
riff(id: string, data: array of byte): array of byte
{
	n := 4 + 8 + len data;
	b := array[8 + n] of byte;
	b[0:] = array of byte "RIFF";
	put32(b, 4, n);
	b[8:] = array of byte "WEBP";
	b[12:] = array of byte id;
	put32(b, 16, len data);
	b[20:] = data;
	return b;
}

put32(b: array of byte, o, v: int)
{
	b[o] = byte v;
	b[o+1] = byte (v >> 8);
	b[o+2] = byte (v >> 16);
	b[o+3] = byte (v >> 24);
}

testRefused(t: ref T)
{
	refused(t, "text", array of byte "not an image at all, only words", "not a WebP file");
	refused(t, "a WAV file", array of byte "RIFF\u0004\u0000\u0000\u0000WAVEfmt ", "not a WebP file");
	refused(t, "no chunks", array of byte "RIFF\u0004\u0000\u0000\u0000WEBP", "no image data");

	ll := readfile(t, FIXTURES + "/webp-lossless.webp");
	refused(t, "truncated lossless", ll[0:len ll / 2], "VP8L: truncated");

	# 16384 by 16384, and nothing else: refused before any is made
	huge := array[25] of {* => byte 0};
	huge[0] = byte 16r2F;
	put32(huge, 1, 16r3FFF | (16r3FFF << 14));
	refused(t, "a huge lossless image", riff("VP8L", huge), "too large");
	key := array[30] of {* => byte 0};
	key[3:] = array[] of {byte 16r9D, byte 16r01, byte 16r2A, byte 16rFF, byte 16r3F, byte 16rFF, byte 16r3F};
	refused(t, "a huge lossy image", riff("VP8 ", key), "too large");

	# a lossy frame that is not a key frame: WebP has only those
	key[0] = byte 1;
	refused(t, "an inter frame", riff("VP8 ", key), "not a key frame");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	keyring = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	readwebp = load RImagefile RImagefile->READWEBPPATH;
	if(readwebp == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", RImagefile->READWEBPPATH);
		raise "fail:cannot load readwebp";
	}
	readwebp->init(bufio);

	run("Lossy", testLossy);
	run("LossyAlpha", testLossyAlpha);
	run("Lossless", testLossless);
	run("Palette", testPalette);
	run("Animation", testAnimation);
	run("Refused", testRefused);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
