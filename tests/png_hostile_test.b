implement PngHostileTest;

#
# PNG files whose headers say what no image is (appl/lib/pngload.b, the
# decoder for large images, and appl/lib/readpng.b, the one for the rest).
# A PNG comes from wherever a page, a message or a card came from, and the
# decoders took its word for its size:
#  - a width or height whose products wrap an int was sized by the wrapped
#    product: an array of a negative size, an exception in whoever opened
#    the file
#  - a PLTE chunk's length was allocated as given, 2GB for the asking
#  - an IDAT whose deflate stream is bad ended the inflater, and the
#    decoder then waited for its next message, for ever
#  - a first IDAT shorter than the zlib header took its two bytes from the
#    next chunk
# Each is refused, with an error, in time.  And a large image that is one
# (grey, 4100 by 4100, its stream in stored blocks over several IDATs, the
# stream ending before the last IDAT does) is still decoded, at half size.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "crc.m";
	crc: Crc;
include "imagefile.m";
	readpng: RImagefile;
include "imgload.m";
include "pngload.m";
	pngload: Pngload;
include "testing.m";
	testing: Testing;
	T: import testing;

PngHostileTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/png_hostile_test.b";

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

put4(a: array of byte, o, v: int)
{
	a[o] = byte (v >> 24);
	a[o+1] = byte (v >> 16);
	a[o+2] = byte (v >> 8);
	a[o+3] = byte v;
}

# a chunk: length, type, data, CRC
chunk(typ: string, data: array of byte): array of byte
{
	n := len data;
	a := array[12 + n] of byte;
	put4(a, 0, n);
	a[4:] = array of byte typ;
	a[8:] = data;
	st := crc->init(0, int 16rffffffff);
	c := crc->crc(st, a[4:8+n], 4+n);
	put4(a, 8+n, c);
	return a;
}

# a chunk's first eight bytes with a length that is not its data's
chunkhdr(typ: string, n: int): array of byte
{
	a := array[8] of byte;
	put4(a, 0, n);
	a[4:] = array of byte typ;
	return a;
}

SIG := array[] of {byte 137, byte 'P', byte 'N', byte 'G', byte 13, byte 10, byte 26, byte 10};

ihdr(w, h, depth, colortype, interlace: int): array of byte
{
	d := array[13] of {* => byte 0};
	put4(d, 0, w);
	put4(d, 4, h);
	d[8] = byte depth;
	d[9] = byte colortype;
	d[12] = byte interlace;
	return chunk("IHDR", d);
}

cat(l: list of array of byte): array of byte
{
	n := 0;
	for(m := l; m != nil; m = tl m)
		n += len hd m;
	a := array[n] of byte;
	o := 0;
	for(; l != nil; l = tl l){
		a[o:] = hd l;
		o += len hd l;
	}
	return a;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# which decoder
Large, Progressive, Small: con iota;

Res: adt {
	im:	ref Image;
	raw:	ref RImagefile->Rawimage;
	err:	string;		# the decoder's
	exc:	string;		# an exception it raised instead
};

loader(which: int, file: array of byte, pidc: chan of int, done: chan of ref Res)
{
	pidc <-= sys->pctl(0, nil);
	r := ref Res;
	{
		fd := bufio->aopen(file);
		case which {
		Large =>
			(r.im, r.err) = pngload->loadpng(fd, "test.png");
		Progressive =>
			(r.im, r.err) = pngload->loadpngprogressive(fd, "test.png", nil);
		Small =>
			(r.raw, r.err) = readpng->read(fd);
		}
	} exception e {
	"*" =>
		r.exc = e;
	}
	done <-= r;
}

# the decoder's answer, given 60 seconds; nil if it gave none
decode(which: int, file: array of byte): ref Res
{
	pidc := chan of int;
	done := chan[1] of ref Res;
	spawn loader(which, file, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 60000);
	alt{
	r := <-done =>
		return r;
	<-tc =>
		kill(pid);
		return nil;
	}
}

# file is refused by decoder which, saying want
refused(t: ref T, which: int, file: array of byte, want, what: string)
{
	r := decode(which, file);
	if(r == nil){
		t.error(what + ": the decoder never answered");
		return;
	}
	if(r.exc != nil){
		t.error(what + ": the decoder raised " + r.exc);
		return;
	}
	if(r.im != nil || r.raw != nil){
		t.error(what + ": decoded");
		return;
	}
	t.assert(contains(r.err, want), what + " is refused: " + r.err);
}

needdisplay(t: ref T)
{
	if(display == nil)
		t.skip("no /dev/draw");
}

# widths and heights whose products do not fit an int
testSizes(t: ref T)
{
	needdisplay(t);
	for(which := Large; which <= Progressive; which++){
		# 1 by 2^31-1, interlaced: half of it by a third of an int
		refused(t, which, cat(SIG :: ihdr(1, 16r7fffffff, 8, 2, 1) :: nil), "too large", "a height of 2^31-1");
		# 100000 squared wraps to a positive int, and its half-size negative
		refused(t, which, cat(SIG :: ihdr(100000, 100000, 8, 2, 1) :: nil), "too large", "100000 by 100000, interlaced");
		refused(t, which, cat(SIG :: ihdr(100000, 100000, 8, 2, 0) :: nil), "too large", "100000 by 100000");
		# three bytes a pixel wraps the row to three bytes
		refused(t, which, cat(SIG :: ihdr(1431655766, 1, 8, 2, 0) :: nil), "too large", "a row whose bytes wrap");
		# within each limit and past them together: no factor is enough
		refused(t, which, cat(SIG :: ihdr(1 << 20, 1 << 20, 8, 0, 0) :: nil), "too large", "2^20 by 2^20");
		refused(t, which, cat(SIG :: ihdr(1 << 20, 1 << 20, 8, 0, 1) :: nil), "too large", "2^20 by 2^20, interlaced");
		# 16 bits deep goes to the other decoder, whatever its size
		refused(t, which, cat(SIG :: ihdr(65536, 65536, 16, 2, 0) :: nil), "too large", "65536 by 65536 of 16 bits");
	}
}

# the same of the decoder for small images, which is given any that is not 8 bits deep
testSmallSizes(t: ref T)
{
	iend := chunk("IEND", nil);
	refused(t, Small, cat(SIG :: ihdr(65536, 65536, 16, 2, 0) :: iend :: nil), "too large", "65536 by 65536 (a product of 0)");
	refused(t, Small, cat(SIG :: ihdr(46341, 46341, 8, 0, 0) :: iend :: nil), "too large", "46341 by 46341 (a negative product)");
	refused(t, Small, cat(SIG :: ihdr(16r7fffffff, 1, 1, 0, 0) :: iend :: nil), "too large", "a width of 2^31-1");
	refused(t, Small, cat(SIG :: ihdr(1, 16r7fffffff, 8, 6, 1) :: iend :: nil), "too large", "a height of 2^31-1");
	refused(t, Small, cat(SIG :: ihdr(20000, 20000, 8, 6, 0) :: iend :: nil), "too large", "20000 by 20000");
}

# 4100 by 4100 is past the size decoded whole: the large decoder's
BIG: con 4100;

testChunks(t: ref T)
{
	needdisplay(t);
	for(which := Large; which <= Progressive; which++){
		# a palette of 2GB, and one that is no number of colours
		refused(t, which, cat(SIG :: ihdr(BIG, BIG, 8, 3, 0) :: chunkhdr("PLTE", 16r7fffffff) :: nil), "bad PLTE", "a PLTE of 2^31-1 bytes");
		refused(t, which, cat(SIG :: ihdr(BIG, BIG, 8, 3, 0) :: chunk("PLTE", array[4] of {* => byte 0}) :: nil), "bad PLTE", "a PLTE of 4 bytes");

		# a zlib header, then a block of a type there is none of
		bad := array[] of {byte 16r78, byte 16r01, byte 16r07, byte 0, byte 0, byte 0, byte 0, byte 0};
		refused(t, which, cat(SIG :: ihdr(BIG, BIG, 8, 0, 0) :: chunk("IDAT", bad) :: chunk("IEND", nil) :: nil), "inflate error", "an IDAT that is not deflate");

		# a first IDAT with less than the zlib header in it
		refused(t, which, cat(SIG :: ihdr(BIG, BIG, 8, 0, 0) :: chunk("IDAT", array[1] of {byte 16r78}) :: chunk("IEND", nil) :: nil), "IDAT too short", "a first IDAT of one byte");

		# a chunk that says it is longer than the file
		refused(t, which, cat(SIG :: ihdr(BIG, BIG, 8, 0, 0) :: chunkhdr("tEXt", 1 << 30) :: array[100] of {* => byte 'x'} :: nil), "EOF", "a chunk longer than its file");
	}
}

# raw as a zlib stream of stored blocks
stored(raw: array of byte): array of byte
{
	nb := (len raw + 65534) / 65535;
	z := array[2 + len raw + 5*nb + 4] of byte;
	z[0] = byte 16r78;
	z[1] = byte 16r01;
	o := 2;
	for(i := 0; i < len raw; i += 65535){
		n := len raw - i;
		final := 1;
		if(n > 65535){
			n = 65535;
			final = 0;
		}
		z[o++] = byte final;
		z[o++] = byte n;
		z[o++] = byte (n >> 8);
		z[o++] = byte ~n;
		z[o++] = byte (~n >> 8);
		z[o:] = raw[i:i+n];
		o += n;
	}
	# Adler-32
	a := 1;
	b := 0;
	for(i = 0; i < len raw; ){
		e := i + 5000;
		if(e > len raw)
			e = len raw;
		for(; i < e; i++){
			a += int raw[i];
			b += a;
		}
		a %= 65521;
		b %= 65521;
	}
	put4(z, o, (b << 16) | a);
	return z;
}

# a large image that is one: its left half white, its right half black
testLargeDecodes(t: ref T)
{
	needdisplay(t);
	row := array[1 + BIG] of {* => byte 0};
	for(x := 0; x < BIG/2; x++)
		row[1+x] = byte 255;
	raw := array[BIG * len row] of byte;
	for(y := 0; y < BIG; y++)
		raw[y * len row:] = row;
	z := stored(raw);
	raw = nil;

	# three IDATs: the last holds the stream's end and bytes past it
	third := len z / 3;
	last := array[len z - 2*third + 40] of {* => byte 16r55};
	last[0:] = z[2*third:];
	file := cat(SIG :: ihdr(BIG, BIG, 8, 0, 0) ::
		chunk("tEXt", array of byte "Comment\0a chunk to pass over") ::
		chunk("IDAT", z[0:third]) :: chunk("IDAT", z[third:2*third]) :: chunk("IDAT", last) ::
		chunk("IDAT", array[10] of {* => byte 16raa}) ::
		chunk("IEND", nil) :: nil);
	z = nil;

	for(which := Large; which <= Progressive; which++){
		r := decode(which, file);
		if(r == nil)
			t.fatal("the decoder never answered");
		if(r.exc != nil)
			t.fatal("the decoder raised " + r.exc);
		if(r.im == nil)
			t.fatal("not decoded: " + r.err);
		im := r.im;
		t.asserteq(im.r.dx(), BIG/2, "width, at half size");
		t.asserteq(im.r.dy(), BIG/2, "height, at half size");
		px := array[3] of byte;
		pts := array[] of {(10, 10), (BIG/4 - 2, BIG/2 - 1), (BIG/4 + 2, 10), (BIG/2 - 1, BIG/2 - 1)};
		want := array[] of {255, 255, 0, 0};
		for(i := 0; i < len pts; i++){
			(px0, py0) := pts[i];
			im.readpixels(Rect((px0, py0), (px0+1, py0+1)), px);
			t.asserteq(int px[0], want[i], sys->sprint("the pixel at %d,%d", px0, py0));
		}
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	crc = load Crc Crc->PATH;
	readpng = load RImagefile RImagefile->READPNGPATH;
	pngload = load Pngload Pngload->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || bufio == nil || crc == nil || readpng == nil || pngload == nil){
		sys->fprint(sys->fildes(2), "cannot load testing, bufio, crc, readpng or pngload: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	readpng->init(bufio);
	display = Display.allocate(nil);
	if(display != nil)
		pngload->init(display);

	run("Sizes", testSizes);
	run("SmallSizes", testSmallSizes);
	run("Chunks", testChunks);
	run("LargeDecodes", testLargeDecodes);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
