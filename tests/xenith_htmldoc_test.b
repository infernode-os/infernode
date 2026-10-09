implement XenithHtmldocTest;

#
# htmldoc: what Xenith's Render shows for an HTML file, set by
# Charon's engine.  The page's style sheet and links are found from
# the file's directory; a second set (the text edited) replaces the
# page; a window's page is its own.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "htmldoc.m";
	htmldoc: Htmldoc;

XenithHtmldocTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/xenith_htmldoc_test.b";
DIR: con "/tests/xenith/html/";
URL: con "file://" + DIR + "index.html";

passed := 0;
failed := 0;
skipped := 0;
disp: ref Display;

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

readall(path: string): array of byte
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# the colour of the pixel at x, y of im, as the bytes of a 1x1 RGB24 image
pixel(im: ref Image, x, y: int): array of byte
{
	one := disp.newimage(Rect((0, 0), (1, 1)), Draw->RGB24, 0, Draw->Nofill);
	one.draw(one.r, im, nil, (x, y));
	b := array[3] of byte;
	one.readpixels(one.r, b);
	return b;
}

colour(rgba: int): array of byte
{
	one := disp.newimage(Rect((0, 0), (1, 1)), Draw->RGB24, 0, rgba);
	b := array[3] of byte;
	one.readpixels(one.r, b);
	return b;
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

testSet(t: ref T)
{
	data := readall(DIR + "index.html");
	if(data == nil)
		t.fatal(sys->sprint("cannot read the fixture: %r"));
	(h, err) := htmldoc->set(1, data, URL, 400, 300);
	t.assertnil(err, "set");
	t.assert(h >= 150, sys->sprint("page height %d takes in the paragraph at 150", h));
	t.assert(contains(htmldoc->text(1), "Hello from the index."), "the page's text");
}

# the style sheet is the file's neighbour: the red box is at 0,0
testStyleSheet(t: ref T)
{
	im := disp.newimage(Rect((0, 0), (400, 300)), Draw->RGB24, 0, Draw->White);
	htmldoc->paint(1, im, 0);
	t.assert(same(pixel(im, 10, 10), colour(int 16rFF0000FF)), "the style sheet's red box is painted");
	t.assert(same(pixel(im, 300, 10), colour(Draw->White)), "the page around it is white");
	# painted from y=20 down, the box's bottom is at 30
	htmldoc->paint(1, im, 20);
	t.assert(same(pixel(im, 10, 25), colour(int 16rFF0000FF)), "scrolled: the box is still above 30");
	t.assert(same(pixel(im, 10, 35), colour(Draw->White)), "scrolled: below it, the page");
}

testLink(t: ref T)
{
	t.assertseq(htmldoc->linkat(1, 10, 110), "file://" + DIR + "page2.html#top", "the link, from the file's directory");
	t.assertnil(htmldoc->linkat(1, 300, 250), "no link where there is none");
}

# Render again after an edit: the text as it is now
testEdited(t: ref T)
{
	(nil, err) := htmldoc->set(1, array of byte "<p>Edited, not saved</p>", URL, 400, 300);
	t.assertnil(err, "set again");
	txt := htmldoc->text(1);
	t.assert(contains(txt, "Edited, not saved"), "the new text: " + txt);
	t.assert(!contains(txt, "Hello from the index."), "not the old");
	t.assertnil(htmldoc->linkat(1, 10, 110), "the old page's link is gone");
}

testWindows(t: ref T)
{
	(nil, err) := htmldoc->set(2, array of byte "<p>Window two</p>", "file:///tmp/two.html", 400, 300);
	t.assertnil(err, "a second window");
	t.assert(contains(htmldoc->text(1), "Edited, not saved"), "the first window's page is unchanged");
	htmldoc->drop(2);
	t.assertnil(htmldoc->text(2), "a dropped page is gone");
	t.assert(contains(htmldoc->text(1), "Edited"), "and the other is not");
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

	disp = Display.allocate(nil);
	if(disp == nil) {
		sys->fprint(sys->fildes(2), "no display: %r\n");
		raise "fail:display";
	}
	htmldoc = load Htmldoc Htmldoc->PATH;
	if(htmldoc == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Htmldoc->PATH);
		raise "fail:load";
	}
	if((err := htmldoc->init(disp)) != nil) {
		sys->fprint(sys->fildes(2), "init: %s\n", err);
		raise "fail:init";
	}

	run("Set", testSet);
	run("StyleSheet", testStyleSheet);
	run("Link", testLink);
	run("Edited", testEdited);
	run("Windows", testWindows);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
