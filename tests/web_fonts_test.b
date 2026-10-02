implement WebFontsTest;

#
# Fonts for the web engine: downloaded faces (@font-face) in TrueType
# and WOFF, family matching, metrics for ex and ch.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Rect, Point, Image: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "outlinefont.m";
	ofont: OutlineFont;
	Face: import ofont;
include "woff2.m";
	woff2: Woff2;
include "web/fonts.m";
	fonts: Fonts;
	Typeface: import fonts;

WebFontsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_fonts_test.b";
display: ref Display;
DIR: con "/tests/web/fonts/";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" or "fail:skip" =>
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

readfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	n := sys->read(fd, b, len b);
	return b[0:n];
}

# Ahem: every glyph an em square, ascent 0.8em; x-height 0.8em
testAhem(t: ref T)
{
	fonts->clearfaces();
	t.assertnil(fonts->addface("ahem", 400, 0, nil, readfile(DIR + "Ahem.ttf")), "add Ahem");
	f := fonts->face("ahem" :: "serif" :: nil, 400, 0, 20.0);
	t.assert(f != nil, "face");
	t.asserteq(int f.width("xxxx"), 80, "four em squares");
	t.asserteq(int f.xheight(), 16, "x-height 0.8em");
	t.asserteq(int f.ascent, 16, "ascent");
	b := fonts->face("ahem" :: nil, 700, 1, 20.0);
	t.asserteq(int b.width("x"), 20, "the only face serves bold italic too");
	n := fonts->face("nosuch" :: "serif" :: nil, 400, 0, 20.0);
	t.assert(n.parts == nil, "an unknown family falls back to the shipped faces");
}

testWOFF(t: ref T)
{
	fonts->clearfaces();
	t.assertnil(fonts->addface("ahemw", 400, 0, nil, readfile(DIR + "Ahem.woff")), "add Ahem.woff");
	f := fonts->face("ahemw" :: nil, 400, 0, 20.0);
	t.assert(f != nil && f.parts != nil, "face from the WOFF");
	t.asserteq(int f.width("xxxx"), 80, "same metrics as the TrueType");
	t.asserteq(int f.xheight(), 16, "x-height");
	t.assertnotnil(fonts->addface("bad", 400, 0, nil, array of byte "wOFFgarbage"), "a broken WOFF is an error");
}

# a family's faces split by unicode-range: each character from the face
# that has it, the rest from the next family
testRanges(t: ref T)
{
	fonts->clearfaces();
	ahem := readfile(DIR + "Ahem.ttf");
	t.assertnil(fonts->addface("split", 400, 0, array[] of {'a', 'z'}, ahem), "lower case part");
	f := fonts->face("split" :: "sans-serif" :: nil, 400, 0, 20.0);
	t.asserteq(int f.width("ab"), 40, "in range: Ahem");
	t.assert(int f.width("AB") != 40, "out of range: the next family");
}

# CSS font matching: the nearest weight, preferring heavier for bold
testWeights(t: ref T)
{
	fonts->clearfaces();
	ahem := readfile(DIR + "Ahem.ttf");
	dv := readfile(Fonts->DIR + "/DejaVuSans.ttf");
	fonts->addface("w", 300, 0, nil, ahem);
	fonts->addface("w", 800, 0, nil, dv);
	t.asserteq(int fonts->face("w" :: nil, 400, 0, 20.0).width("x"), 20, "400 takes 300 (lighter first)");
	t.assert(int fonts->face("w" :: nil, 600, 0, 20.0).width("x") != 20, "600 takes 800 (heavier first)");
}

# WOFF2 against the font it was made from: every character's advance,
# and its glyph drawn, the same
woff2vs(t: ref T, file: string)
{
	ttf := readfile(DIR + "DejaVuSubset.ttf");
	(sf, err) := woff2->decode(readfile(DIR + file));
	t.assertnil(err, file + " decodes");
	if(sf == nil)
		return;
	(a, e1) := ofont->open(ttf, "ttf");
	(b, e2) := ofont->open(sf, "ttf");
	t.assertnil(e1, "the TTF opens");
	t.assertnil(e2, file + " opens as TrueType");
	if(a == nil || b == nil)
		return;
	t.asserteq(b.nglyphs, a.nglyphs, "glyphs");
	t.asserteq(b.ascent, a.ascent, "ascent");
	ia := display.newimage(Rect((0, 0), (80, 80)), Draw->GREY8, 0, Draw->White);
	ib := display.newimage(Rect((0, 0), (80, 80)), Draw->GREY8, 0, Draw->White);
	pa := array[80*80] of byte;
	pb := array[80*80] of byte;
	bad := 0;
	n := 0;
	for(c := 16r21; c < 16r100; c++) {
		if(c >= 16r7F && c < 16rA1)
			continue;
		ga := a.lookup(c);
		gb := b.lookup(c);
		if(ga < 0)
			continue;
		n++;
		if(gb != ga || a.advance(ga, 40.0) != b.advance(gb, 40.0)) {
			t.error(sys->sprint("U+%04X: glyph %d/%d advance %g/%g", c, ga, gb, a.advance(ga, 40.0), b.advance(gb, 40.0)));
			bad++;
			continue;
		}
		ia.draw(ia.r, display.white, nil, (0, 0));
		ib.draw(ib.r, display.white, nil, (0, 0));
		a.drawglyph(ga, 40.0, ia, Point(20, 55), display.black);
		b.drawglyph(gb, 40.0, ib, Point(20, 55), display.black);
		ia.readpixels(ia.r, pa);
		ib.readpixels(ib.r, pb);
		for(k := 0; k < len pa; k++)
			if(pa[k] != pb[k]) {
				t.error(sys->sprint("U+%04X (glyph %d) draws differently", c, ga));
				bad++;
				break;
			}
		if(bad > 5)
			break;
	}
	t.log(sys->sprint("%s: %d characters compared", file, n));
	t.assert(n > 180, "the subset's characters were found");
}

testWOFF2(t: ref T)
{
	woff2vs(t, "DejaVuSubset.woff2");
}

testWOFF2hmtx(t: ref T)
{
	woff2vs(t, "DejaVuSubset-hmtx.woff2");
}

# OpenType with CFF outlines, as Font Awesome is: upem 512, the
# language icon U+F1AB 576 units wide, the magnifier U+F002 512
# GSUB ligatures: liga.ttf (made by fontTools) has f i -> f_i (600
# units) and f f i -> f_f_i (1100); f is 500, i 300
testLigatures(t: ref T)
{
	t.assertnil(fonts->addface("lig", 400, 0, nil, readfile(DIR + "liga.ttf")), "add liga.ttf");
	f := fonts->face("lig" :: nil, 400, 0, 100.0);
	t.assert(f != nil, "face");
	t.assert(f.width("f") == 50.0 && f.width("i") == 30.0, sys->sprint("single glyphs: %g %g", f.width("f"), f.width("i")));
	t.assert(f.width("fi") == 60.0, sys->sprint("fi is one ligature glyph: %g", f.width("fi")));
	t.assert(f.width("ffi") == 110.0, sys->sprint("the longest ligature wins: %g", f.width("ffi")));
	t.assert(f.width("if") == 80.0, sys->sprint("no ligature backwards: %g", f.width("if")));
	t.assert(f.width("fi fi") == 145.0, sys->sprint("ligatures around a space: %g", f.width("fi fi")));
}

testOTF(t: ref T)
{
	(a, err) := ofont->open(readfile(DIR + "FASubset.otf"), "ttf");
	t.assertnil(err, "an OTTO font opens");
	if(a == nil)
		return;
	(sf, e2) := woff2->decode(readfile(DIR + "FASubset.woff2"));
	t.assertnil(e2, "its WOFF2 decodes");
	(b, e3) := ofont->open(sf, "ttf");
	t.assertnil(e3, "and opens");
	if(b == nil)
		return;
	lang := a.lookup(16rF1AB);
	mag := a.lookup(16rF002);
	t.assert(lang > 0 && mag > 0, "both icons mapped");
	t.assert(a.lookup('A') < 0, "nothing else");
	t.asserteq(int a.advance(lang, 64.0), 72, "language icon: 576/512 em");
	t.asserteq(int a.advance(mag, 64.0), 64, "magnifier: 1 em");
	t.asserteq(a.ascent * 512 / a.upem, 448, "ascent from hhea, in the outlines' units");
	ia := display.newimage(Rect((0, 0), (100, 100)), Draw->GREY8, 0, Draw->White);
	ib := display.newimage(Rect((0, 0), (100, 100)), Draw->GREY8, 0, Draw->White);
	a.drawglyph(lang, 64.0, ia, Point(10, 70), display.black);
	b.drawglyph(b.lookup(16rF1AB), 64.0, ib, Point(10, 70), display.black);
	pa := array[100*100] of byte;
	pb := array[100*100] of byte;
	ia.readpixels(ia.r, pa);
	ib.readpixels(ib.r, pb);
	ink := 0;
	outside := 0;
	same := 1;
	for(k := 0; k < len pa; k++) {
		if(pa[k] != pb[k])
			same = 0;
		if(int pa[k] < 128) {
			ink++;
			(x, y) := (k % 100, k / 100);
			# the em box: x 10..82, y 70-56..70+8
			if(x < 9 || x > 83 || y < 13 || y > 79)
				outside++;
		}
	}
	t.log(sys->sprint("ink %d, outside the em box %d", ink, outside));
	t.assert(ink > 800, "the icon is drawn");
	t.asserteq(outside, 0, "and within its em box");
	t.assert(same, "the WOFF2 draws the same");
}

testWOFF2face(t: ref T)
{
	fonts->clearfaces();
	t.assertnil(fonts->addface("dv", 400, 0, nil, readfile(DIR + "DejaVuSubset.woff2")), "add a WOFF2 face");
	f := fonts->face("dv" :: nil, 400, 0, 20.0);
	t.assert(f != nil && f.parts != nil, "a face from it");
	(nil, err) := woff2->decode(array of byte "wOF2 not really a font");
	t.assertnotnil(err, "a broken WOFF2 is an error");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	fonts = load Fonts Fonts->PATH;
	display = Display.allocate(nil);
	ofont = load OutlineFont OutlineFont->PATH;
	woff2 = load Woff2 Woff2->PATH;
	if(ofont == nil || woff2 == nil) {
		sys->fprint(sys->fildes(2), "cannot load outlinefont or woff2: %r\n");
		raise "fail:load";
	}
	ofont->init(display);
	if(fonts == nil || (err := fonts->init(display)) != nil) {
		sys->fprint(sys->fildes(2), "cannot load fonts: %r\n");
		raise "fail:load";
	}
	run("Ahem", testAhem);
	run("WOFF", testWOFF);
	run("Ranges", testRanges);
	run("Weights", testWeights);
	run("WOFF2", testWOFF2);
	run("WOFF2hmtx", testWOFF2hmtx);
	run("WOFF2face", testWOFF2face);
	run("Ligatures", testLigatures);
	run("OTF", testOTF);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
