implement ImgloadTest;

#
# Image loading tests: imgload (module/imgload.m), the one loader
# Xenith, the browser, wm/view and lib/scene share, and the decoders
# under it.
#
# Tests:
# - Format detection from the data, then the name
# - Which names are images (what Xenith opens as one)
# - Every format decoded from a file, its pixels checked
#   (fixtures in /tests/imgload, made by mkfixtures.py there)
# - Xenith's image renderer claims images, and not text that
#   begins like one
# - An Inferno image (image(6)) read from bytes
# - remap keeping colours exact on a display deeper than 8 bits
# - readpng and readjpg on hand-built minimal files
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";
	imageremap: Imageremap;
	readpng: RImagefile;
	readjpg: RImagefile;

include "imgload.m";
	imgload: Imgload;

include "renderer.m";

include "testing.m";
	testing: Testing;
	T: import testing;

ImgloadTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

SRCFILE: con "/tests/imgload_test.b";
FIXTURES: con "/tests/imgload";

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

# --- Format detection ---

bytes(l: list of int): array of byte
{
	a := array[len l] of byte;
	for(i := 0; l != nil; l = tl l)
		a[i++] = byte hd l;
	return a;
}

testFormatMagic(t: ref T)
{
	t.assertseq(imgload->format(bytes(137 :: 'P' :: 'N' :: 'G' :: 13 :: 10 :: 26 :: 10 :: nil), nil), "png", "PNG signature");
	t.assertseq(imgload->format(bytes(16rFF :: 16rD8 :: 16rFF :: 16rE0 :: nil), nil), "jpeg", "JFIF");
	t.assertseq(imgload->format(bytes(16rFF :: 16rD8 :: 16rFF :: 16rE1 :: nil), nil), "jpeg", "EXIF JPEG");
	t.assertnil(imgload->format(bytes(16rFF :: 16rD9 :: 16rFF :: 16rE0 :: nil), nil), "FF D9 is not JPEG");
	t.assertseq(imgload->format(array of byte "GIF89a\u0001\u0000", nil), "gif", "GIF89a");
	t.assertseq(imgload->format(array of byte "RIFF\u0000\u0000\u0000\u0000WEBPVP8 ", nil), "webp", "WebP");
	t.assertnil(imgload->format(array of byte "RIFF\u0000\u0000\u0000\u0000WAVEfmt ", nil), "a WAV file is not WebP");
	t.assertseq(imgload->format(array of byte "P6\n8 8\n255\n", nil), "ppm", "P6");
	t.assertseq(imgload->format(array of byte "P5\n8 8\n255\n", nil), "ppm", "P5 (PGM)");
	t.assertseq(imgload->format(array of byte "compressed\n", nil), "bit", "compressed Inferno image");
	t.assertnil(imgload->format(array of byte "XYZ\u0000\u0000\u0000\u0000\u0000", nil), "unknown bytes");
}

# ISO BMFF is AVIF only when a brand says so: an MP4 is not an image.
testFormatAvif(t: ref T)
{
	avif := array of byte "\u0000\u0000\u0000\u001cftypavif\u0000\u0000\u0000\u0000avifmif1miaf";
	t.assertseq(imgload->format(avif, nil), "avif", "major brand avif");
	compat := array of byte "\u0000\u0000\u0000\u001cftypmif1\u0000\u0000\u0000\u0000mif1avifmiaf";
	t.assertseq(imgload->format(compat, nil), "avif", "compatible brand avif");
	mp4 := array of byte "\u0000\u0000\u0000\u0018ftypisom\u0000\u0000\u0002\u0000isomiso2";
	t.assertnil(imgload->format(mp4, nil), "an MP4 is not AVIF");
	t.assertnil(imgload->format(mp4, "clip.mp4"), "nor by its name");
}

# SVG is text: an SVG document is one whose first element is <svg, which
# an HTML page with an inline <svg is not.
testFormatSvg(t: ref T)
{
	t.assertseq(imgload->format(array of byte "<svg xmlns=\"http://www.w3.org/2000/svg\"/>", nil), "svg", "bare <svg");
	prolog := "\ufeff<?xml version=\"1.0\"?>\n<!-- a <comment> -->\n<!DOCTYPE svg>\n<svg width=\"8\">";
	t.assertseq(imgload->format(array of byte prolog, nil), "svg", "after a BOM, declaration, comment and doctype");
	html := array of byte "<!DOCTYPE html>\n<html><body><svg width=\"8\"></svg></body></html>";
	t.assertnil(imgload->format(html, nil), "an HTML page with an inline <svg");
	t.assertnil(imgload->format(html, "page.html"), "nor by its name");
	t.assertseq(imgload->format(array of byte "<g/>", "x.svg"), "svg", "a .svg name with no <svg up front");
}

testFormatByName(t: ref T)
{
	text := array of byte "some text";
	t.assertseq(imgload->format(text, "/a/b.svg"), "svg", ".svg");
	t.assertseq(imgload->format(text, "/a/B.JPEG"), "jpeg", ".JPEG, any case");
	t.assertseq(imgload->format(text, "x.pgm"), "ppm", ".pgm");
	t.assertnil(imgload->format(text, "x.txt"), ".txt");
	t.assertnil(imgload->format(text, "a.png/readme"), "a directory's extension");
	t.assertnil(imgload->format(text, nil), "no name");
	# the data wins over the name
	t.assertseq(imgload->format(array of byte "GIF87a", "x.png"), "gif", "GIF data named .png");
}

# isimage is what Xenith's look asks before it opens a file as an image.
testIsimage(t: ref T)
{
	yes := "a.png" :: "/x/a.jpg" :: "a.JPG" :: "a.jpeg" :: "a.jpe" :: "a.gif" :: "a.webp" ::
		"a.avif" :: "a.svg" :: "a.SVG" :: "a.xbm" :: "a.pic" :: "a.ppm" :: "a.pgm" :: "a.bit" :: nil;
	for(; yes != nil; yes = tl yes)
		t.assert(imgload->isimage(hd yes), hd yes + " is an image");
	no := "a.txt" :: "a.b" :: "a.pdf" :: "a.pbm" :: "png" :: "a.png/b" :: "a." :: "" :: nil;
	for(; no != nil; no = tl no)
		t.assert(!imgload->isimage(hd no), hd no + " is not an image");
	exts := imgload->extensions();
	for(l := ".png" :: ".jpg" :: ".svg" :: ".webp" :: ".avif" :: ".bit" :: nil; l != nil; l = tl l)
		t.assert(contains(" " + exts + " ", " " + hd l + " "), "extensions() lists " + hd l);
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# --- Every format, decoded ---

# Decoding makes images, which needs a draw device (the GUI emulator;
# SDL_VIDEODRIVER=dummy will do).
needdisplay(t: ref T)
{
	if(display == nil)
		t.skip("no /dev/draw");
}

# The pixel at p, as (r, g, b), whatever the image's channels.
pixel(im: ref Image, p: Point): (int, int, int)
{
	one := display.newimage(Rect((0, 0), (1, 1)), Draw->RGB24, 0, Draw->Black);
	one.draw(one.r, im, nil, p);
	buf := array[3] of byte;
	one.readpixels(one.r, buf);
	return (int buf[2], int buf[1], int buf[0]);
}

near(t: ref T, got: (int, int, int), want: (int, int, int), tol: int, what: string)
{
	(r, g, b) := got;
	(wr, wg, wb) := want;
	if(abs(r - wr) > tol || abs(g - wg) > tol || abs(b - wb) > tol)
		t.error(sys->sprint("%s: pixel (%d,%d,%d), want (%d,%d,%d)", what, r, g, b, wr, wg, wb));
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

# Read a fixture both ways (by path, and as bytes as Xenith and the
# browser do), and check its size and its two halves.
checkfixture(t: ref T, name, fmt: string, top, bottom: (int, int, int), tol: int)
{
	needdisplay(t);
	path := FIXTURES + "/" + name;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		t.error(sys->sprint("%s: %r", path));
		return;
	}
	head := array[512] of byte;
	n := sys->read(fd, head, len head);
	t.assertseq(imgload->format(head[0:n], path), fmt, name + " format");

	(im, err) := imgload->readimage(path);
	if(im == nil) {
		t.error(name + ": readimage: " + err);
		return;
	}
	t.asserteq(im.r.dx(), 8, name + " width");
	t.asserteq(im.r.dy(), 8, name + " height");
	near(t, pixel(im, im.r.min.add((3, 1))), top, tol, name + " top half");
	near(t, pixel(im, im.r.min.add((3, 6))), bottom, tol, name + " bottom half");

	data := readfile(path);
	(im, err) = imgload->readimagedata(data, path);
	if(im == nil)
		t.error(name + ": readimagedata: " + err);
	else
		near(t, pixel(im, im.r.min.add((3, 6))), bottom, tol, name + " from bytes");
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	buf := array[int d.length] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return buf[0:n];
}

testDecodePng(t: ref T)		{ checkfixture(t, "rb.png", "png", (255, 0, 0), (0, 0, 255), 0); }
testDecodeJpeg(t: ref T)	{ checkfixture(t, "rb.jpg", "jpeg", (255, 0, 0), (0, 0, 255), 40); }
testDecodeGif(t: ref T)		{ checkfixture(t, "rb.gif", "gif", (255, 0, 0), (0, 0, 255), 0); }
testDecodeWebpLossless(t: ref T)	{ checkfixture(t, "rb.webp", "webp", (255, 0, 0), (0, 0, 255), 0); }
testDecodeWebpLossy(t: ref T)	{ checkfixture(t, "rbl.webp", "webp", (255, 0, 0), (0, 0, 255), 40); }

# AVIF has no decoder yet; it refuses, rather than return a picture
# that is not the image (it once returned grey).
testDecodeAvif(t: ref T)	{ refused(t, "rb.avif", "avif", "AVIF: AV1 image decoding is not implemented"); }

refused(t: ref T, name, fmt, want: string)
{
	needdisplay(t);
	path := FIXTURES + "/" + name;
	data := readfile(path);
	n := len data;
	if(n > 512)
		n = 512;
	t.assertseq(imgload->format(data[0:n], path), fmt, name + " format");
	(im, err) := imgload->readimage(path);
	t.assert(im == nil, name + " is not decoded");
	t.assertseq(err, want, name + " error");
}
# On a display of more than 8 bits, remap keeps an image's colours:
# none of these is in CMAP8's 256, so mapped to them (and dithered) it
# would come back otherwise.
testRemapTrueColour(t: ref T)
{
	needdisplay(t);
	rm := load Imageremap Imageremap->PATH;
	if(rm == nil)
		t.fatal(sys->sprint("load imageremap: %r"));
	rm->init(display);
	r := Rect((0, 0), (2, 1));

	rgb := ref RImagefile->Rawimage;
	rgb.r = r;
	rgb.nchans = 3;
	rgb.chandesc = RImagefile->CRGB;
	rgb.chans = array[] of {
		array[] of {byte 37, byte 250},
		array[] of {byte 141, byte 3},
		array[] of {byte 200, byte 99}};
	(im, err) := rm->remap(rgb, display, 1);
	if(im == nil)
		t.fatal("remap RGB: " + err);
	near(t, pixel(im, (0, 0)), (37, 141, 200), 0, "RGB, first pixel");
	near(t, pixel(im, (1, 0)), (250, 3, 99), 0, "RGB, second pixel");

	grey := ref RImagefile->Rawimage;
	grey.r = r;
	grey.nchans = 1;
	grey.chandesc = RImagefile->CY;
	grey.chans = array[] of {array[] of {byte 77, byte 133}};
	(im, err) = rm->remap(grey, display, 1);
	if(im == nil)
		t.fatal("remap grey: " + err);
	near(t, pixel(im, (0, 0)), (77, 77, 77), 0, "grey, first pixel");
	near(t, pixel(im, (1, 0)), (133, 133, 133), 0, "grey, second pixel");

	pal := ref RImagefile->Rawimage;
	pal.r = r;
	pal.nchans = 1;
	pal.chandesc = RImagefile->CRGB1;
	pal.cmap = array[] of {byte 11, byte 22, byte 33, byte 201, byte 102, byte 53};
	pal.chans = array[] of {array[] of {byte 1, byte 0}};
	(im, err) = rm->remap(pal, display, 1);
	if(im == nil)
		t.fatal("remap paletted: " + err);
	near(t, pixel(im, (0, 0)), (201, 102, 53), 0, "paletted, first pixel");
	near(t, pixel(im, (1, 0)), (11, 22, 33), 0, "paletted, second pixel");
}

testDecodeSvg(t: ref T)		{ checkfixture(t, "rb.svg", "svg", (255, 0, 0), (0, 0, 255), 0); }
testDecodePpm(t: ref T)		{ checkfixture(t, "rb.ppm", "ppm", (255, 0, 0), (0, 0, 255), 0); }
testDecodePgm(t: ref T)		{ checkfixture(t, "wb.pgm", "ppm", (255, 255, 255), (0, 0, 0), 0); }
testDecodeXbm(t: ref T)		{ checkfixture(t, "bw.xbm", "xbm", (0, 0, 0), (255, 255, 255), 0); }
testDecodePic(t: ref T)		{ checkfixture(t, "rb.pic", "pic", (255, 0, 0), (0, 0, 255), 0); }

# An Inferno image arrives at Xenith as bytes: the draw device reads
# it through a pipe.
testDecodeBit(t: ref T)
{
	needdisplay(t);
	src := display.newimage(Rect((0, 0), (8, 8)), Draw->RGB24, 0, Draw->Blue);
	src.draw(Rect((0, 0), (8, 4)), display.color(Draw->Red), nil, (0, 0));
	path := "/tmp/imgload_test.bit";
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("create %s: %r", path));
	if(display.writeimage(fd, src) < 0)
		t.fatal(sys->sprint("writeimage: %r"));
	fd = nil;
	data := readfile(path);
	sys->remove(path);
	(im, err) := imgload->readimagedata(data, "x.bit");
	if(im == nil)
		t.fatal("readimagedata: " + err);
	t.asserteq(im.r.dx(), 8, "width");
	near(t, pixel(im, (3, 1)), (255, 0, 0), 0, "top half");
	near(t, pixel(im, (3, 6)), (0, 0, 255), 0, "bottom half");
}

testUnrecognised(t: ref T)
{
	needdisplay(t);
	(im, err) := imgload->readimagedata(array of byte "just some text here", "notes.txt");
	t.assert(im == nil, "text is not an image");
	t.assertseq(err, "unrecognized image format", "error");
	(im, err) = imgload->readimagedata(array of byte "GIF89a broken", "x.gif");
	t.assert(im == nil, "a truncated GIF");
	t.assert(err != nil && err[0:4] == "GIF:", "error names the format: " + err);
}

testReader(t: ref T)
{
	(rd, err) := imgload->reader("gif");
	t.assert(rd != nil, "a GIF decoder: " + err);
	(rd2, nil) := imgload->reader("gif");
	t.assert(rd2 != rd, "a fresh decoder each time");
	(rd, err) = imgload->reader("ppm");
	t.assert(rd == nil && err != nil, "PPM is read by imgload itself");
}

# --- Xenith's image renderer ---

testRenderer(t: ref T)
{
	needdisplay(t);
	r := load Renderer "/dis/xenith/render/imgrender.dis";
	if(r == nil)
		t.skip(sys->sprint("imgrender: %r"));
	r->init(display);
	ri := r->info();
	t.assert(contains(" " + ri.extensions + " ", " .svg "), "it claims .svg");
	t.assert(contains(" " + ri.extensions + " ", " .webp "), "it claims .webp");
	png := readfile(FIXTURES + "/rb.png");
	svg := readfile(FIXTURES + "/rb.svg");
	t.asserteq(r->canrender(png, nil), 100, "PNG data, no name");
	t.asserteq(r->canrender(svg, "rb.svg"), 90, "an SVG named so");
	t.asserteq(r->canrender(array of byte "#define X 1\n#define Y 2\n", "x.h"), 0, "a C header is not an XBM");
	t.asserteq(r->canrender(array of byte "P3 is the plan\n", "notes.txt"), 0, "text starting P3 is not a PPM");
	html := array of byte "<!DOCTYPE html><html><svg></svg></html>";
	t.asserteq(r->canrender(html, "page.html"), 0, "an HTML page with inline SVG");
}

# --- Module loading tests ---

# Test that readpng module can be loaded
testReadpngLoads(t: ref T)
{
	if(readpng == nil){
		readpng = load RImagefile RImagefile->READPNGPATH;
		if(readpng == nil){
			t.fatal("cannot load readpng module from " + RImagefile->READPNGPATH);
			return;
		}
		readpng->init(bufio);
	}
	t.log("readpng module loaded successfully");
}

# Test that readjpg module can be loaded
testReadjpgLoads(t: ref T)
{
	if(readjpg == nil){
		readjpg = load RImagefile RImagefile->READJPGPATH;
		if(readjpg == nil){
			t.fatal("cannot load readjpg module from " + RImagefile->READJPGPATH);
			return;
		}
		readjpg->init(bufio);
	}
	t.log("readjpg module loaded successfully");
}

# Test that imageremap module loads
testImageremapLoads(t: ref T)
{
	if(imageremap == nil){
		imageremap = load Imageremap Imageremap->PATH;
		if(imageremap == nil){
			t.fatal("cannot load imageremap module");
			return;
		}
		# Note: imageremap->init() requires a Display, skip in headless
	}
	t.log("imageremap module loaded successfully");
}

# --- PNG decode tests ---

# Test decoding a minimal valid 1x1 red PNG (8-bit RGB, no interlace)
testDecodePng1x1(t: ref T)
{
	if(readpng == nil){
		readpng = load RImagefile RImagefile->READPNGPATH;
		if(readpng == nil){
			t.skip("readpng not available");
			return;
		}
		readpng->init(bufio);
	}

	# Minimal 1x1 red PNG (pre-computed)
	# This is a valid PNG with IHDR, IDAT, IEND
	png := mkpng1x1red();
	fd := bufio->aopen(png);
	if(fd == nil){
		t.fatal("cannot create bufio from PNG data");
		return;
	}

	(raw, err) := readpng->read(fd);
	fd.close();

	if(raw == nil){
		t.fatal(sys->sprint("readpng->read failed: %s", err));
		return;
	}

	t.asserteq(raw.r.max.x, 1, "PNG width should be 1");
	t.asserteq(raw.r.max.y, 1, "PNG height should be 1");
	t.asserteq(raw.nchans, 3, "PNG should have 3 channels (RGB)");
	t.assert(raw.chans != nil, "PNG chans should not be nil");
	t.asserteq(len raw.chans, 3, "PNG should have 3 channel arrays");

	# Check pixel data: red = (255, 0, 0) in R, G, B channels
	if(len raw.chans[0] > 0 && len raw.chans[1] > 0 && len raw.chans[2] > 0){
		t.asserteq(int raw.chans[0][0], 255, "red channel should be 255");
		t.asserteq(int raw.chans[1][0], 0, "green channel should be 0");
		t.asserteq(int raw.chans[2][0], 0, "blue channel should be 0");
	}
	t.log("1x1 red PNG decoded successfully");
}

# Test readpng rejects invalid data gracefully
testPngInvalidData(t: ref T)
{
	if(readpng == nil){
		readpng = load RImagefile RImagefile->READPNGPATH;
		if(readpng == nil){
			t.skip("readpng not available");
			return;
		}
		readpng->init(bufio);
	}

	# Feed garbage bytes
	garbage := array[64] of { * => byte 16rAA };
	fd := bufio->aopen(garbage);
	if(fd == nil){
		t.fatal("cannot create bufio from garbage data");
		return;
	}

	(raw, err) := readpng->read(fd);
	fd.close();

	t.assert(raw == nil || err != nil, "readpng should fail on garbage data");
	t.log(sys->sprint("readpng rejected garbage: %s", err));
}

# --- JPEG decode tests ---

# Test decoding a minimal valid 1x1 JPEG
testDecodeJpeg1x1(t: ref T)
{
	if(readjpg == nil){
		readjpg = load RImagefile RImagefile->READJPGPATH;
		if(readjpg == nil){
			t.skip("readjpg not available");
			return;
		}
		readjpg->init(bufio);
	}

	jpg := mkjpeg1x1();
	fd := bufio->aopen(jpg);
	if(fd == nil){
		t.fatal("cannot create bufio from JPEG data");
		return;
	}

	(raw, err) := readjpg->read(fd);
	fd.close();

	if(raw == nil){
		t.fatal(sys->sprint("readjpg->read failed: %s", err));
		return;
	}

	t.asserteq(raw.r.max.x, 1, "JPEG width should be 1");
	t.asserteq(raw.r.max.y, 1, "JPEG height should be 1");
	t.assert(raw.nchans == 1 || raw.nchans == 3, "JPEG should have 1 or 3 channels");
	t.assert(raw.chans != nil, "JPEG chans should not be nil");
	t.log(sys->sprint("1x1 JPEG decoded: %dx%d, %d chans",
		raw.r.max.x, raw.r.max.y, raw.nchans));
}

# Test readjpg rejects invalid data gracefully
testJpegInvalidData(t: ref T)
{
	if(readjpg == nil){
		readjpg = load RImagefile RImagefile->READJPGPATH;
		if(readjpg == nil){
			t.skip("readjpg not available");
			return;
		}
		readjpg->init(bufio);
	}

	garbage := array[64] of { * => byte 16rBB };
	fd := bufio->aopen(garbage);
	if(fd == nil){
		t.fatal("cannot create bufio from garbage data");
		return;
	}

	(raw, err) := readjpg->read(fd);
	fd.close();

	t.assert(raw == nil || err != nil, "readjpg should fail on garbage data");
	t.log(sys->sprint("readjpg rejected garbage: %s", err));
}

# --- Test data construction ---

# Build a CRC32 table and compute CRC for PNG chunks
crctable: array of int;

initcrc()
{
	crctable = array[256] of int;
	for(n := 0; n < 256; n++){
		c := n;
		for(k := 0; k < 8; k++){
			if(c & 1)
				c = int 16rEDB88320 ^ (c >> 1);
			else
				c = c >> 1;
		}
		crctable[n] = c;
	}
}

pngcrc(data: array of byte): array of byte
{
	if(crctable == nil)
		initcrc();

	c := int 16rFFFFFFFF;
	for(i := 0; i < len data; i++)
		c = crctable[(c ^ int data[i]) & 16rFF] ^ (c >> 8);
	c = c ^ int 16rFFFFFFFF;

	crc := array[4] of byte;
	crc[0] = byte(c >> 24);
	crc[1] = byte(c >> 16);
	crc[2] = byte(c >> 8);
	crc[3] = byte c;
	return crc;
}

# Build a minimal 1x1 red PNG (8-bit RGB, no interlace)
mkpng1x1red(): array of byte
{
	# PNG signature
	sig := array[] of {byte 137, byte 80, byte 78, byte 71,
	                    byte 13, byte 10, byte 26, byte 10};

	# IHDR: 1x1, 8-bit, RGB (colortype 2), no interlace
	ihdrdata := array[] of {
		byte 0, byte 0, byte 0, byte 1,  # width = 1
		byte 0, byte 0, byte 0, byte 1,  # height = 1
		byte 8,                            # bit depth = 8
		byte 2,                            # color type = 2 (RGB)
		byte 0,                            # compression = 0
		byte 0,                            # filter = 0
		byte 0                             # interlace = 0
	};
	ihdrtypedata := array[4 + len ihdrdata] of byte;
	ihdrtypedata[0:] = array[] of {byte 'I', byte 'H', byte 'D', byte 'R'};
	ihdrtypedata[4:] = ihdrdata;
	ihdrcrc := pngcrc(ihdrtypedata);

	# IDAT: zlib header + deflate block with row data
	# Row data: filter=0, R=255, G=0, B=0
	# zlib: 78 01 = CMF=78 (deflate, window 7), FLG=01 (no dict, FCHECK=1)
	# deflate final block, no compression:
	#   01 = BFINAL=1, BTYPE=00 (no compression)
	#   04 00 FB FF = LEN=4, NLEN=~4
	#   00 FF 00 00 = filter(0), R(255), G(0), B(0)
	# adler32 of uncompressed: s1=256, s2=512 => 00 02 01 00
	idatpayload := array[] of {
		byte 16r78, byte 16r01,             # zlib header
		byte 16r01,                          # BFINAL=1, BTYPE=00
		byte 16r04, byte 16r00,             # LEN=4
		byte 16rFB, byte 16rFF,             # NLEN=~4
		byte 16r00,                          # filter byte = None
		byte 16rFF, byte 16r00, byte 16r00, # R=255, G=0, B=0
		byte 16r00, byte 16r02, byte 16r01, byte 16r00  # adler32
	};
	idattypedata := array[4 + len idatpayload] of byte;
	idattypedata[0:] = array[] of {byte 'I', byte 'D', byte 'A', byte 'T'};
	idattypedata[4:] = idatpayload;
	idatcrc := pngcrc(idattypedata);

	# IEND
	iendtypedata := array[] of {byte 'I', byte 'E', byte 'N', byte 'D'};
	iendcrc := pngcrc(iendtypedata);

	# Assemble full PNG
	total := len sig
		+ 4 + 4 + len ihdrdata + 4      # IHDR chunk
		+ 4 + 4 + len idatpayload + 4   # IDAT chunk
		+ 4 + 4 + 0 + 4;                # IEND chunk

	png := array[total] of byte;
	off := 0;

	# Signature
	png[off:] = sig;
	off += len sig;

	# IHDR
	putbe32(png, off, len ihdrdata); off += 4;
	png[off:] = ihdrtypedata;
	off += len ihdrtypedata;
	png[off:] = ihdrcrc; off += 4;

	# IDAT
	putbe32(png, off, len idatpayload); off += 4;
	png[off:] = idattypedata;
	off += len idattypedata;
	png[off:] = idatcrc; off += 4;

	# IEND
	putbe32(png, off, 0); off += 4;
	png[off:] = iendtypedata;
	off += len iendtypedata;
	png[off:] = iendcrc; off += 4;

	return png;
}

# Build a minimal 1x1 grayscale JPEG (baseline, JFIF)
# This is the smallest valid JFIF JPEG that readjpg can decode
mkjpeg1x1(): array of byte
{
	# Minimal JFIF 1x1 grayscale JPEG
	# Constructed from JPEG spec:
	#   SOI, APP0 (JFIF), DQT, SOF0, DHT (DC), DHT (AC), SOS, data, EOI
	jpg := array[] of {
		# SOI
		byte 16rFF, byte 16rD8,

		# APP0 - JFIF marker
		byte 16rFF, byte 16rE0,
		byte 16r00, byte 16r10,  # length = 16
		byte 'J', byte 'F', byte 'I', byte 'F', byte 0,  # JFIF\0
		byte 16r01, byte 16r01,  # version 1.1
		byte 16r00,              # aspect ratio units = none
		byte 16r00, byte 16r01,  # X density = 1
		byte 16r00, byte 16r01,  # Y density = 1
		byte 16r00, byte 16r00,  # no thumbnail

		# DQT - quantization table (all 1s for simplicity)
		byte 16rFF, byte 16rDB,
		byte 16r00, byte 16r43,  # length = 67
		byte 16r00,              # table 0, 8-bit precision
		# 64 quantization values (all 1 for lossless-ish)
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,
		byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1,

		# SOF0 - Start of Frame (baseline, 1x1, 1 component grayscale)
		byte 16rFF, byte 16rC0,
		byte 16r00, byte 16r0B,  # length = 11
		byte 16r08,              # 8-bit precision
		byte 16r00, byte 16r01,  # height = 1
		byte 16r00, byte 16r01,  # width = 1
		byte 16r01,              # 1 component
		byte 16r01,              # component ID = 1
		byte 16r11,              # H=1, V=1
		byte 16r00,              # quant table 0

		# DHT - DC Huffman table (class 0, table 0)
		# Minimal table: just code for category 0 (DC=0)
		byte 16rFF, byte 16rC4,
		byte 16r00, byte 16r1F,  # length = 31
		byte 16r00,              # DC table, ID 0
		# 16 count bytes: 1 code of length 1, rest 0
		byte 16r00, byte 16r01, byte 16r05, byte 16r01,
		byte 16r01, byte 16r01, byte 16r01, byte 16r01,
		byte 16r01, byte 16r00, byte 16r00, byte 16r00,
		byte 16r00, byte 16r00, byte 16r00, byte 16r00,
		# values
		byte 16r00, byte 16r01, byte 16r02, byte 16r03,
		byte 16r04, byte 16r05, byte 16r06, byte 16r07,
		byte 16r08, byte 16r09, byte 16r0A, byte 16r0B,

		# DHT - AC Huffman table (class 1, table 0)
		byte 16rFF, byte 16rC4,
		byte 16r00, byte 16rB5,  # length = 181
		byte 16r10,              # AC table, ID 0
		# Standard luminance AC table counts
		byte 16r00, byte 16r02, byte 16r01, byte 16r03,
		byte 16r03, byte 16r02, byte 16r04, byte 16r03,
		byte 16r05, byte 16r05, byte 16r04, byte 16r04,
		byte 16r00, byte 16r00, byte 16r01, byte 16r7D,
		# Standard luminance AC table values (162 values)
		byte 16r01, byte 16r02, byte 16r03, byte 16r00,
		byte 16r04, byte 16r11, byte 16r05, byte 16r12,
		byte 16r21, byte 16r31, byte 16r41, byte 16r06,
		byte 16r13, byte 16r51, byte 16r61, byte 16r07,
		byte 16r22, byte 16r71, byte 16r14, byte 16r32,
		byte 16r81, byte 16r91, byte 16rA1, byte 16r08,
		byte 16r23, byte 16r42, byte 16rB1, byte 16rC1,
		byte 16r15, byte 16r52, byte 16rD1, byte 16rF0,
		byte 16r24, byte 16r33, byte 16r62, byte 16r72,
		byte 16r82, byte 16r09, byte 16r0A, byte 16r16,
		byte 16r17, byte 16r18, byte 16r19, byte 16r1A,
		byte 16r25, byte 16r26, byte 16r27, byte 16r28,
		byte 16r29, byte 16r2A, byte 16r34, byte 16r35,
		byte 16r36, byte 16r37, byte 16r38, byte 16r39,
		byte 16r3A, byte 16r43, byte 16r44, byte 16r45,
		byte 16r46, byte 16r47, byte 16r48, byte 16r49,
		byte 16r4A, byte 16r53, byte 16r54, byte 16r55,
		byte 16r56, byte 16r57, byte 16r58, byte 16r59,
		byte 16r5A, byte 16r63, byte 16r64, byte 16r65,
		byte 16r66, byte 16r67, byte 16r68, byte 16r69,
		byte 16r6A, byte 16r73, byte 16r74, byte 16r75,
		byte 16r76, byte 16r77, byte 16r78, byte 16r79,
		byte 16r7A, byte 16r83, byte 16r84, byte 16r85,
		byte 16r86, byte 16r87, byte 16r88, byte 16r89,
		byte 16r8A, byte 16r92, byte 16r93, byte 16r94,
		byte 16r95, byte 16r96, byte 16r97, byte 16r98,
		byte 16r99, byte 16r9A, byte 16rA2, byte 16rA3,
		byte 16rA4, byte 16rA5, byte 16rA6, byte 16rA7,
		byte 16rA8, byte 16rA9, byte 16rAA, byte 16rB2,
		byte 16rB3, byte 16rB4, byte 16rB5, byte 16rB6,
		byte 16rB7, byte 16rB8, byte 16rB9, byte 16rBA,
		byte 16rC2, byte 16rC3, byte 16rC4, byte 16rC5,
		byte 16rC6, byte 16rC7, byte 16rC8, byte 16rC9,
		byte 16rCA, byte 16rD2, byte 16rD3, byte 16rD4,
		byte 16rD5, byte 16rD6, byte 16rD7, byte 16rD8,
		byte 16rD9, byte 16rDA, byte 16rE1, byte 16rE2,
		byte 16rE3, byte 16rE4, byte 16rE5, byte 16rE6,
		byte 16rE7, byte 16rE8, byte 16rE9, byte 16rEA,
		byte 16rF1, byte 16rF2, byte 16rF3, byte 16rF4,
		byte 16rF5, byte 16rF6, byte 16rF7, byte 16rF8,
		byte 16rF9, byte 16rFA,

		# SOS - Start of Scan
		byte 16rFF, byte 16rDA,
		byte 16r00, byte 16r08,  # length = 8
		byte 16r01,              # 1 component
		byte 16r01,              # component 1
		byte 16r00,              # DC table 0, AC table 0
		byte 16r00,              # Ss = 0
		byte 16r3F,              # Se = 63
		byte 16r00,              # Ah=0, Al=0

		# Entropy-coded data: DC=128 (gray), all AC=0
		# DC category 8 (value 128): Huffman code for cat 8 then 8 bits
		# With standard luminance DC table, cat 8 = code 111110 (6 bits)
		# Then value 128 = 10000000 (8 bits)
		# Then EOB (AC): code 1010 (4 bits) from standard AC table
		# Total: 111110 10000000 1010 = 18 bits
		# Padded: 11111010 00000010 10111111 (fill bits)
		byte 16rFA, byte 16r02, byte 16rBF,

		# EOI
		byte 16rFF, byte 16rD9
	};
	return jpg;
}

# Write a big-endian 32-bit int into a byte array
putbe32(buf: array of byte, off, val: int)
{
	buf[off] = byte(val >> 24);
	buf[off+1] = byte(val >> 16);
	buf[off+2] = byte(val >> 8);
	buf[off+3] = byte val;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	imgload = load Imgload Imgload->PATH;
	if(imgload == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Imgload->PATH);
		raise "fail:cannot load imgload";
	}
	display = Display.allocate(nil);
	imgload->init(display);

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Magic byte detection tests
	run("FormatMagic", testFormatMagic);
	run("FormatAvif", testFormatAvif);
	run("FormatSvg", testFormatSvg);
	run("FormatByName", testFormatByName);
	run("Isimage", testIsimage);

	# Every format through imgload
	run("DecodePng", testDecodePng);
	run("DecodeJpeg", testDecodeJpeg);
	run("DecodeGif", testDecodeGif);
	run("DecodeWebpLossless", testDecodeWebpLossless);
	run("DecodeWebpLossy", testDecodeWebpLossy);
	run("DecodeAvif", testDecodeAvif);
	run("DecodeSvg", testDecodeSvg);
	run("DecodePpm", testDecodePpm);
	run("DecodePgm", testDecodePgm);
	run("DecodeXbm", testDecodeXbm);
	run("DecodePic", testDecodePic);
	run("DecodeBit", testDecodeBit);
	run("RemapTrueColour", testRemapTrueColour);
	run("Unrecognised", testUnrecognised);
	run("Reader", testReader);
	run("Renderer", testRenderer);

	# Module loading tests
	run("ReadpngLoads", testReadpngLoads);
	run("ReadjpgLoads", testReadjpgLoads);
	run("ImageremapLoads", testImageremapLoads);

	# PNG decode tests
	run("DecodePng1x1", testDecodePng1x1);
	run("PngInvalidData", testPngInvalidData);

	# JPEG decode tests
	run("DecodeJpeg1x1", testDecodeJpeg1x1);
	run("JpegInvalidData", testJpegInvalidData);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
