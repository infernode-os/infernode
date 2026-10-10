implement PdftextTest;

#
# pdf(2)'s text: glyphs found and placed as the PDF says, measured as
# drawn.  Each test builds a small PDF: a standard font not embedded
# (its metrics), Widths, word spacing, TJ kerning inside a word, an
# Encoding's Differences, streams through chains of filters (ASCII85,
# RunLength, ASCIIHex, LZW), where the ink of a word lands, text cut
# by a clipping rectangle, a Type 3
# glyph, and an embedded Type 1 font whose glyphs come from a
# subroutine and a seac.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

include "pdf.m";
	pdf: PDF;
	Doc: import pdf;

include "testing.m";
	testing: Testing;
	T: import testing;

PdftextTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/pdftext_test.b";

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

# A PDF of one page (612 by 792) showing content, with the objects
# given numbered from 5 (the font F1 is 5 0 R).
mkpdf(content: string, contentdict: string, objs: list of string): array of byte
{
	o := array[4 + len objs] of string;
	o[0] = "<< /Type /Catalog /Pages 2 0 R >>";
	o[1] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>";
	o[2] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " +
		"/Resources << /Font << /F1 5 0 R >> >> >>";
	o[3] = "<< /Length " + string len content + contentdict + " >>\nstream\n" + content + "\nendstream";
	i := 4;
	for(; objs != nil; objs = tl objs)
		o[i++] = hd objs;
	body := "%PDF-1.4\n";
	offs := array[len o] of int;
	for(i = 0; i < len o; i++){
		offs[i] = len body;
		body += string (i+1) + " 0 obj\n" + o[i] + "\nendobj\n";
	}
	xref := len body;
	body += "xref\n0 " + string (len o + 1) + "\n0000000000 65535 f \n";
	for(i = 0; i < len o; i++)
		body += sys->sprint("%010d 00000 n \n", offs[i]);
	body += "trailer\n<< /Size " + string (len o + 1) + " /Root 1 0 R >>\nstartxref\n" + string xref + "\n%%EOF\n";
	b := array[len body] of byte;
	for(i = 0; i < len body; i++)
		b[i] = byte body[i];
	return b;
}

HELVETICA: con "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";

open(t: ref T, data: array of byte): ref Doc
{
	(doc, err) := pdf->open(data, nil);
	if(doc == nil)
		t.fatal("open: " + err);
	return doc;
}

words(doc: ref Doc): array of (string, Rect)
{
	l := doc.words(1);
	w := array[len l] of (string, Rect);
	for(i := 0; l != nil; l = tl l)
		w[i++] = hd l;
	return w;
}

near(t: ref T, got, want: int, what: string)
{
	d := got - want;
	if(d < 0)
		d = -d;
	if(d > 1)
		t.error(sys->sprint("%s: got %d, want %d", what, got, want));
}

# Helvetica's widths (H e l l o = 2278, space 278, W o r l d = 2611
# thousandths) at 12 points, from x 100: the substitute face has them.
testStandardMetrics(t: ref T)
{
	w := words(open(t, mkpdf("BT /F1 12 Tf 100 700 Td (Hello World) Tj ET", "", HELVETICA :: nil)));
	if(len w != 2)
		t.fatal(sys->sprint("%d words, want 2", len w));
	t.assertseq(w[0].t0, "Hello", "first word");
	t.assertseq(w[1].t0, "World", "second word");
	near(t, w[0].t1.min.x, 100, "Hello starts");
	near(t, w[0].t1.max.x, 127, "Hello ends");	# 100 + 27.3
	near(t, w[1].t1.min.x, 130, "World starts");	# 100 + 30.7
	near(t, w[1].t1.max.x, 162, "World ends");	# 130.7 + 31.3
}

# Widths the PDF gives are the advances, whatever the face's.
testWidths(t: ref T)
{
	ws := "";
	for(i := 32; i <= 126; i++)
		ws += " 500";
	f := "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 126 /Widths [" + ws + "] >>";
	w := words(open(t, mkpdf("BT /F1 12 Tf 100 700 Td (Hello World) Tj ET", "", f :: nil)));
	if(len w != 2)
		t.fatal(sys->sprint("%d words, want 2", len w));
	near(t, w[0].t1.max.x, 130, "Hello ends");	# 5 * 6
	near(t, w[1].t1.min.x, 136, "World starts");
}

# Tw widens the space (code 32) and nothing else.
testWordSpacing(t: ref T)
{
	w := words(open(t, mkpdf("BT /F1 12 Tf 10 Tw 100 700 Td (Hello World) Tj ET", "", HELVETICA :: nil)));
	if(len w != 2)
		t.fatal(sys->sprint("%d words, want 2", len w));
	near(t, w[0].t1.max.x, 127, "Hello ends");
	near(t, w[1].t1.min.x, 140, "World starts");	# 130.7 + 10
}

# A small TJ adjustment is kerning: the word is one word.
testKernInWord(t: ref T)
{
	w := words(open(t, mkpdf("BT /F1 12 Tf 100 700 Td [(Wor) -20 (ld)] TJ ET", "", HELVETICA :: nil)));
	if(len w != 1)
		t.fatal(sys->sprint("%d words, want 1", len w));
	t.assertseq(w[0].t0, "World", "kerned word");
}

# Differences name the glyph a code shows (here A shows B).
testDifferences(t: ref T)
{
	f := "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Differences [65 /B] >> >>";
	w := words(open(t, mkpdf("BT /F1 12 Tf 100 700 Td (A) Tj ET", "", f :: nil)));
	if(len w != 1)
		t.fatal(sys->sprint("%d words, want 1", len w));
	t.assertseq(w[0].t0, "B", "code 65 is B");
}

# A content stream through each chain of filters.
testFilters(t: ref T)
{
	cases := array[] of {
		(A85content, " /Filter /ASCII85Decode", "ASCII85"),
		(A85rlecontent, " /Filter [/ASCII85Decode /RunLengthDecode]", "ASCII85, RunLength"),
		(Hexlzwcontent, " /Filter [/ASCIIHexDecode /LZWDecode]", "ASCIIHex, LZW"),
	};
	for(i := 0; i < len cases; i++){
		(c, d, what) := cases[i];
		text := open(t, mkpdf(c, d, HELVETICA :: nil)).extracttext(1);
		if(!contains(text, "Filtered"))
			t.error(what + ": text " + text);
	}
}

contains(s, w: string): int
{
	for(i := 0; i + len w <= len s; i++)
		if(s[i:i+len w] == w)
			return 1;
	return 0;
}

# The ink of a word lands where its box says: rendered at 144 dpi (two
# pixels to the point), Hello at 12 points from (100, 700).
testInk(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	(im, err) := open(t, mkpdf("BT /F1 12 Tf 100 700 Td (Hello) Tj ET", "", HELVETICA :: nil)).renderpage(1, 144);
	if(im == nil)
		t.fatal("render: " + err);
	(x0, y0, x1, y1) := inkbox(im);
	t.log(sys->sprint("ink %d %d %d %d", x0, y0, x1, y1));
	near(t, x0, 201, "ink left");	# H's side bearing, 0.08 em
	near(t, x1, 253, "ink right");	# 100 + 27.3 less o's bearing, by two
	near(t, y1, 184, "ink bottom");	# the baseline: (792 - 700) * 2
	if(y0 < 184 - 2*9 || y0 > 184 - 2*8)
		t.error(sys->sprint("ink top %d: H's cap height is 0.72 em", y0));
}

# Text is clipped: Hello under a clip 20 points wide (to x 120, pixel
# 240 at 144 dpi) has no ink past it, and is drawn up to it.
testClip(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	c := "q 100 690 20 30 re W n BT /F1 12 Tf 100 700 Td (Hello) Tj ET Q";
	(im, err) := open(t, mkpdf(c, "", HELVETICA :: nil)).renderpage(1, 144);
	if(im == nil)
		t.fatal("render: " + err);
	(x0, nil, x1, nil) := inkbox(im);
	t.log(sys->sprint("ink %d to %d", x0, x1));
	near(t, x0, 201, "ink left");
	t.assert(x1 <= 240, sys->sprint("ink to %d, past the clip at 240", x1));
	t.assert(x1 >= 236, sys->sprint("ink to %d, not up to the clip at 240", x1));
}

# the box of the pixels darker than mid-grey
inkbox(im: ref Image): (int, int, int, int)
{
	w := im.r.dx();
	h := im.r.dy();
	row := array[w * 3] of byte;
	x0 := w;
	y0 := h;
	x1 := y1 := -1;
	for(y := 0; y < h; y++){
		im.readpixels(Rect((0, y), (w, y+1)), row);
		for(x := 0; x < w; x++)
			if(int row[3*x+1] < 128){
				if(x < x0) x0 = x;
				if(x > x1) x1 = x;
				if(y < y0) y0 = y;
				if(y > y1) y1 = y;
			}
	}
	return (x0, y0, x1 + 1, y1 + 1);
}

dark(im: ref Image, x, y: int): int
{
	px := array[3] of byte;
	im.readpixels(Rect((x, y), (x+1, y+1)), px);
	return int px[1] < 128;
}

# A Type 3 glyph is its content stream through the font matrix: a
# square a thousand units on a side is the font size on a side.
testType3(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	proc := "1000 0 0 0 1000 1000 d1 0 0 1000 1000 re f";
	f := "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] " +
		"/CharProcs << /sq 6 0 R >> /Encoding << /Differences [97 /sq] >> /FirstChar 97 /LastChar 98 /Widths [1000 1000] >>";
	p := "<< /Length " + string len proc + " >>\nstream\n" + proc + "\nendstream";
	(im, err) := open(t, mkpdf("BT /F1 20 Tf 100 700 Td (a) Tj ET", "", f :: p :: nil)).renderpage(1, 72);
	if(im == nil)
		t.fatal("render: " + err);
	t.assert(dark(im, 110, 82), "inside the square");	# x 100-120, y 72-92
	t.assert(!dark(im, 125, 82), "past the square");
	t.assert(!dark(im, 110, 95), "below the square");
}

# An embedded Type 1 font (FontFile): A is a square drawn by a
# subroutine, B a seac of A on A; 600 units, at 20 points from x 101.
testType1(t: ref T)
{
	if(display == nil)
		t.skip("no display");
	ff := "<< /Length " + string len Squarefont + " /Length1 " + string Squarelen1 +
		" /Length2 " + string (len Squarefont - Squarelen1) + " /Length3 0 >>\nstream\n" + Squarefont + "\nendstream";
	desc := "<< /Type /FontDescriptor /FontName /Squares /Flags 4 /FontBBox [0 0 700 700] " +
		"/ItalicAngle 0 /Ascent 700 /Descent 0 /CapHeight 600 /StemV 80 /FontFile 7 0 R >>";
	f := "<< /Type /Font /Subtype /Type1 /BaseFont /Squares /FirstChar 65 /LastChar 66 /Widths [700 700] /FontDescriptor 6 0 R >>";
	(im, err) := open(t, mkpdf("BT /F1 20 Tf 100 700 Td (AB) Tj ET", "", f :: desc :: ff :: nil)).renderpage(1, 72);
	if(im == nil)
		t.fatal("render: " + err);
	(x0, y0, x1, y1) := inkbox(im);
	t.log(sys->sprint("ink %d %d %d %d", x0, y0, x1, y1));
	t.assert(dark(im, 107, 86), "A, from its subroutine");	# x 101-113, y 80-92
	t.assert(dark(im, 121, 86), "B, the seac");		# x 115-127
	t.assert(!dark(im, 114, 86), "between them");
	near(t, x0, 101, "A's left");
	near(t, x1, 127, "B's right");
	near(t, y0, 80, "the top");
	near(t, y1, 92, "the baseline");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	display = Display.allocate(nil);
	pdf = load PDF PDF->PATH;
	if(pdf == nil){
		sys->fprint(sys->fildes(2), "cannot load pdf: %r\n");
		raise "fail:cannot load pdf";
	}
	pdf->init(display);

	run("StandardMetrics", testStandardMetrics);
	run("Widths", testWidths);
	run("WordSpacing", testWordSpacing);
	run("KernInWord", testKernInWord);
	run("Differences", testDifferences);
	run("Filters", testFilters);
	run("Ink", testInk);
	run("Clip", testClip);
	run("Type3", testType3);
	run("Type1", testType1);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

# Fixtures, made by encoding: a Type 1 font program (clear text, then
# the eexec part in hex) and a content stream,
#	BT /F1 12 Tf 100 700 Td (Filtered) Tj ET
# through ASCII85; RunLength then ASCII85; LZW then ASCIIHex.

Squarefont: con
	"%!PS-AdobeFont-1.0: Squares 001.000\n11 dict begin\n/FontName /Squ" +
	"ares def\n/FontType 1 def\n/FontMatrix [0.001 0 0 0.001 0 0] reado" +
	"nly def\n/FontBBox {0 0 700 700} readonly def\n/Encoding StandardE" +
	"ncoding def\ncurrentdict end\ncurrentfile eexec\nd9d66f633b846a989b" +
	"9974b0179fc6cc4452954d3a4fc272596999ba876cc696185cbab11491f08a05" +
	"3b187b0adb1613ea4e6a25c471c0db78b865e8f6845f9a8691983ad38c1c60b0" +
	"4b9cd89e6f23c5c81e5bc47a690c9c1bd2f0f746dd5119f9018438935532e4db" +
	"08dc5657ede48df658558a32e44deb4ec223d46b4fdb204a68a918f6801d38d6" +
	"5d8e2e358104dbed45bbd90ed077b253cacafedfd337fc937ea0d018501ebe3e" +
	"2fd93efd72a84b69863c0672025030aaa0b77292db0526502c52b5d49e23ec03" +
	"68e370af7e9ec141f64086dca836526f1797f6a9f1ab914fd9c4e3d677b961f1" +
	"4ae08bcaa788cc6e9c2b3cdbe2228276b6c9ca22319734018377807df80aa88f" +
	"cdfabb55f50adce82fc861c0d9ed9868db23ba169de82a6bc4d6b05ea358ec0f" +
	"8ccfb7e0604a614c105896dab8b46fcbe2800e31e3bd7ef1cba472270bfbdda7" +
	"6d81c209999dddd797c3d5ec7e1712a1f382099e7e206e1a698daa9fe4b1c2a4" +
	"46c3ea32bd16d2ec3060eb0c044e9df81b2cec0bd34994a2c01db5c7984a6a88" +
	"a6c26772a40566ecea6aa3ccd2a4ab983473d720961ab79c8fd94237c294a6d7" +
	"569b8cddbab704dca3ab7466244bb3\n000000000000000000000000000000000" +
	"0000000000000000000000000000000\ncleartomark\n";

Squarelen1: con 238;
A85content: con
	"6<#'\\7PQ#?1*BP.+>GQ(+?(u.+B2ko-q7oeFCfK(A18X#C*5rE~>";

A85rlecontent: con
	"-ULcT01IZ=0eskNAfrf^0H`;.0Ha>*+=K]nCij6/ARm54<,*OE<.F~>";

Hexlzwcontent: con
	"80108a820179186220188c84054334206030100de1f0b320805046349b0e8653" +
	"9194c829859a840452a404>";

