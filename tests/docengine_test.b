implement DocengineTest;

#
# The document registry (docreg(2)) and engines (docengine(2)) on
# their own, as Xenith's document view uses them:
#
#	the kinds, by name and by the bytes a file begins with;
#	no engine loaded until a document of its kind is opened, and
#	then only that one;
#	each engine: sheets, their sizes, painting, text; a PDF painted
#	at twice the scale is twice the size; Markdown set again to a
#	new width, and its lines mapped to the document and back;
#	PDF documents each keep their own pages.
#
# Painting needs a draw device (the GUI emulator; SDL_VIDEODRIVER=dummy
# will do): without one the engine tests skip.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "docengine.m";
include "docreg.m";
	docreg: Docreg;
	Kind: import docreg;

include "testing.m";
	testing: Testing;
	T: import testing;

DocengineTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/docengine_test.b";

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

needdisplay(t: ref T)
{
	if(display == nil)
		t.skip("no /dev/draw");
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[0] of byte;
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		c := array[len b + n] of byte;
		c[0:] = b;
		c[len b:] = buf[0:n];
		b = c;
	}
	return b;
}

contains(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

testKinds(t: ref T)
{
	k := docreg->kind("/a/b/Report.PDF", nil);
	t.assert(k != nil && k.name == "pdf", "a .PDF is a pdf, whatever its case");
	t.asserteq(k.class, Docreg->Binary, "a PDF is a binary document");
	k = docreg->kind("/a/notes.md", nil);
	t.assert(k != nil && k.name == "markdown" && k.class == Docreg->Source, "a .md is Markdown, a source document");
	k = docreg->kind("/a/flow.mmd", nil);
	t.assert(k != nil && k.name == "mermaid", "a .mmd is Mermaid");
	k = docreg->kind("/a/page.html", nil);
	t.assert(k != nil && k.name == "html", "a .html is HTML");
	k = docreg->kind("/a/pic.webp", nil);
	t.assert(k != nil && k.name == "image", "a .webp is an image");
	k = docreg->kind("/a/report", array of byte "%PDF-1.4\n");
	t.assert(k != nil && k.name == "pdf", "a file beginning %PDF- is a PDF, whatever its name");
	png := array[] of {byte 16r89, byte 'P', byte 'N', byte 'G', byte 13, byte 10};
	k = docreg->kind("/a/noext", png);
	t.assert(k != nil && k.name == "image", "a file beginning \\x89PNG is an image");
	t.assert(docreg->kind("/a/prog.b", array of byte "implement X;") == nil, "a .b is not a document");
	t.assert(docreg->kind("/a/dir.d/plain", nil) == nil, "a dot in a directory is not an extension");
}

testLazy(t: ref T)
{
	t.assert(docreg->loaded() == nil, "no engine is loaded before a document is opened");
	needdisplay(t);
	(e, err) := docreg->engine(docreg->kindof("pdf"));
	if(e == nil)
		t.fatal(err);
	l := docreg->loaded();
	t.assert(contains(l, "/dis/xenith/doc/pdfdoc.dis"), "the PDF engine is loaded for a PDF");
	t.asserteq(len l, 1, "and no other");
	(e2, nil) := docreg->engine(docreg->kindof("pdf"));
	t.assert(e2 == e, "the same engine serves the next PDF");
}

openfile(t: ref T, kind, path: string, data: array of byte, st: ref Docengine->Style): (Docengine, int)
{
	(e, err) := docreg->engine(docreg->kindof(kind));
	if(e == nil)
		t.fatal(kind + ": " + err);
	h: int;
	(h, err) = e->open(data, path, st);
	if(h < 0)
		t.fatal(path + ": " + err);
	return (e, h);
}

painted(t: ref T, e: Docengine, h, n, scale: int, what: string): ref Image
{
	sz := e->sheetsize(h, n);
	if(e->scalable(h))
		sz = Point(sz.x * scale / 100, sz.y * scale / 100);
	im := display.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->Blue);
	if(im == nil)
		t.fatal("no image");
	if((err := e->paint(h, n, scale, im, im.r, Point(0, 0))) != nil)
		t.fatal(what + ": paint: " + err);
	return im;
}

# Some pixel of im is not blue (the image's fill): something was painted
someink(im: ref Image): int
{
	w := im.r.dx();
	buf := array[w * 3] of byte;
	for(y := 0; y < im.r.dy(); y += 7){
		im.readpixels(Rect((0, y), (w, y + 1)), buf);
		for(i := 0; i < len buf; i += 3)
			if(!(buf[i] == byte 255 && buf[i+1] == byte 0 && buf[i+2] == byte 0))
				return 1;
	}
	return 0;
}

testPdf(t: ref T)
{
	needdisplay(t);
	(e, h) := openfile(t, "pdf", "/tests/render/square.pdf", nil, nil);
	t.assert(e->nsheets(h) >= 1, "a PDF has its pages as sheets");
	sz := e->sheetsize(h, 0);
	t.assert(sz.x > 100 && sz.y > 100, sys->sprint("a page's size at scale 100 is its size in points (got %d %d)", sz.x, sz.y));
	t.asserteq(e->scalable(h), 1, "a PDF paints sharp at any scale");
	im := painted(t, e, h, 0, 100, "PDF at 100");
	t.assert(someink(im), "a page is painted");
	im2 := painted(t, e, h, 0, 200, "PDF at 200");
	t.asserteq(im2.r.dx(), 2 * im.r.dx(), "at scale 200 a page is twice as wide");
	# part of a page, from a point in it
	part := display.newimage(Rect((0, 0), (40, 40)), Draw->RGB24, 0, Draw->Blue);
	t.assertnil(e->paint(h, 0, 200, part, part.r, Point(sz.x/2, sz.y/2)), "part of a page is painted from a point in it");
	e->close(h);
	t.asserteq(e->nsheets(h), 0, "a closed document has no sheets");
}

testPdfWords(t: ref T)
{
	needdisplay(t);
	(e, h) := openfile(t, "pdf", "/lib/legal/calderalic.pdf", nil, nil);
	sz := e->sheetsize(h, 0);
	runs := e->runs(h, 0);
	t.assert(len runs > 50, sys->sprint("a page's words, where they are drawn (got %d)", len runs));
	found := 0;
	for(i := 0; i < len runs; i++){
		r := runs[i].r;
		if(r.min.x < 0 || r.min.y < 0 || r.max.x > sz.x + 2 || r.max.y > sz.y + 2 || r.dx() <= 0 || r.dy() <= 0){
			t.error(sys->sprint("word %q at %d %d %d %d: not on the page", runs[i].text, r.min.x, r.min.y, r.max.x, r.max.y));
			break;
		}
		if(runs[i].text == "West")
			found = i;
	}
	t.assert(found > 0, "the word West is one of them");
	if(found > 0){
		# the address line, 240 West Center Street, near the top left
		r := runs[found].r;
		t.assert(r.min.y < sz.y / 4 && r.min.x < sz.x / 2, sys->sprint("West is near the top left (at %d %d)", r.min.x, r.min.y));
		t.assert(runs[found-1].text == "240" && runs[found-1].r.max.x <= r.min.x + 2, "after 240, to its left");
	}
	e->close(h);
}

testPdfApart(t: ref T)
{
	needdisplay(t);
	(e, h1) := openfile(t, "pdf", "/tests/render/square.pdf", nil, nil);
	(nil, h2) := openfile(t, "pdf", "/tests/render/square.pdf", nil, nil);
	t.assert(h1 != h2, "two PDFs have two handles");
	e->close(h1);
	t.assert(e->nsheets(h2) >= 1, "closing one leaves the other");
	e->close(h2);
}

testImage(t: ref T)
{
	needdisplay(t);
	(e, h) := openfile(t, "image", "/tests/imgload/rb.png", readfile("/tests/imgload/rb.png"), nil);
	t.asserteq(e->nsheets(h), 1, "an image is one sheet");
	sz := e->sheetsize(h, 0);
	t.assert(sz.x == 8 && sz.y == 8, sys->sprint("its size is the image's (got %d %d)", sz.x, sz.y));
	t.asserteq(e->scalable(h), 0, "an image is painted at scale 100, the view scales it");
	t.assert(someink(painted(t, e, h, 0, 100, "image")), "an image is painted");
	(nil, err) := e->open(array of byte "not an image at all", "/x/bad.png", nil);
	t.assert(err != nil, "what does not decode is refused");
	e->close(h);
}

style(width: int): ref Docengine->Style
{
	return ref Docengine->Style(width, nil, nil, nil, nil, nil, nil);
}

testMarkdown(t: ref T)
{
	needdisplay(t);
	src := "# Title\n\nOne paragraph\nof two lines.\n\n## Second\n\nMore text.\n";
	(e, h) := openfile(t, "markdown", "/x/doc.md", array of byte src, style(500));
	t.asserteq(e->nsheets(h), 1, "Markdown is one flowing sheet");
	sz := e->sheetsize(h, 0);
	t.asserteq(sz.x, 500, "set to the style's width");
	t.assert(sz.y > 50, "as tall as it needs");
	t.assert(someink(painted(t, e, h, 0, 100, "markdown")), "Markdown is painted");
	txt := e->text(h);
	t.assert(txt != nil && len txt > 0, "its text as set");
	(nil, y0) := e->lineto(h, 0);
	(nil, y5) := e->lineto(h, 5);
	t.assert(y5 > y0, "a later line of the text is set further down");
	t.asserteq(e->lineat(h, 0, y5), 5, "and the line set there is that line");
	runs := e->runs(h, 0);
	t.assert(len runs >= 7, sys->sprint("its words, where they are drawn (got %d)", len runs));
	t.assertseq(runs[0].text, "Title", "the first word is the heading's");
	t.assertnil(e->restyle(h, style(300)), "set again to a new width");
	t.asserteq(e->sheetsize(h, 0).x, 300, "to that width");
	t.assert(docreg->loaded() != nil && !contains(docreg->loaded(), "/dis/xenith/doc/webdoc.dis"),
		"Markdown does not load the HTML engine (nor Charon's)");
	e->close(h);
}

testMarkdownLinks(t: ref T)
{
	needdisplay(t);
	src := "Some text and [a link](http://example.com/x) here, and <http://example.com/bare> too.\n";
	(e, h) := openfile(t, "markdown", "/x/links.md", array of byte src, style(600));
	runs := e->runs(h, 0);
	link: ref Docengine->Run;
	for(i := 0; i < len runs; i++)
		if(runs[i].text == "link")
			link = ref runs[i];
	if(link == nil)
		t.fatal("the link's words are not among the words drawn");
	c := link.r.min.add(link.r.max).div(2);
	t.assertseq(e->linkat(h, 0, c), "http://example.com/x", "the link's target, from a point on its words");
	t.assertnil(e->linkat(h, 0, Point(1, 1)), "no link where there is none");
	l := e->links(h);
	t.asserteq(len l, 3, "its links: two words of one, one of an autolink");
	txt := e->text(h);
	t.assert(txt != nil && !contains2(txt, "http://example.com/xa link"), "the text as set has the link's words, not its target run into them");
	e->close(h);
}

contains2(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

testMermaid(t: ref T)
{
	needdisplay(t);
	(e, h) := openfile(t, "mermaid", "/tests/render/flow.mmd", nil, style(400));
	t.asserteq(e->nsheets(h), 1, "a diagram is one sheet");
	sz := e->sheetsize(h, 0);
	t.assert(sz.x > 0 && sz.y > 0, "of some size");
	t.assert(someink(painted(t, e, h, 0, 100, "mermaid")), "a diagram is painted");
	e->close(h);
}

testHtml(t: ref T)
{
	needdisplay(t);
	page := "<html><body><h1>Heading</h1><p>Some text and <a href=\"http://example.com/x\">a link</a>.</p></body></html>";
	(e, h) := openfile(t, "html", "/x/page.html", array of byte page, style(600));
	t.asserteq(e->nsheets(h), 1, "HTML is one flowing sheet");
	sz := e->sheetsize(h, 0);
	t.asserteq(sz.x, 600, "laid out to the style's width");
	t.assert(sz.y > 0, "and as tall as the page");
	t.assert(someink(painted(t, e, h, 0, 100, "html")), "a page is painted");
	txt := e->text(h);
	t.assert(txt != nil && sys->tokenize(txt, " \n").t0 > 0, "its text");
	e->close(h);
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

	docreg = load Docreg Docreg->PATH;
	if(docreg == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Docreg->PATH);
		raise "fail:cannot load docreg";
	}
	display = Display.allocate(nil);
	docreg->init(display);

	run("Kinds", testKinds);
	run("Lazy", testLazy);
	run("Pdf", testPdf);
	run("PdfWords", testPdfWords);
	run("PdfApart", testPdfApart);
	run("Image", testImage);
	run("Markdown", testMarkdown);
	run("MarkdownLinks", testMarkdownLinks);
	run("Mermaid", testMermaid);
	run("Html", testHtml);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
