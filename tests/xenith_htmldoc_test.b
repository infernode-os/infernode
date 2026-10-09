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

# The next event from c starting with what, others skipped; nil after
# five seconds
waitfor(c: chan of string, what: string): string
{
	tick := chan of int;
	spawn timer(tick, 5000);
	for(;;) alt {
	e := <-c =>
		if(len e >= len what && e[0:len what] == what)
			return e;
	<-tick =>
		return nil;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>	;
	* =>	;
	}
}

PAGE2: con "file://" + DIR + "page2.html#top";
ev: chan of string;

testBrowse(t: ref T)
{
	err: string;
	(ev, err) = htmldoc->browse(3, URL, 400, 300);
	t.assertnil(err, "browse");
	if(ev == nil)
		t.fatal("no event channel for a new page");
	t.assert(waitfor(ev, "done") != nil, "the page loads");
	t.assertseq(htmldoc->url(3), URL, "its URL");
	t.assertseq(htmldoc->title(3), "Index", "its title");
	t.assert(htmldoc->height(3) >= 150, "its height");
	t.assert(contains(htmldoc->text(3), "Hello from the index."), "its text");
}

testFollow(t: ref T)
{
	(hit, err) := htmldoc->click(3, 300, 250);
	t.asserteq(hit, 0, "nothing on the page there");
	t.assertnil(err, "and no error");
	(hit, err) = htmldoc->click(3, 10, 110);
	t.asserteq(hit, 1, "a click on the link");
	t.assertnil(err, "follows it");
	t.assert(waitfor(ev, "done") != nil, "the next page loads");
	t.assertseq(htmldoc->url(3), PAGE2, "the link's page");
	t.assertseq(htmldoc->title(3), "Page two", "its title");
}

testHistory(t: ref T)
{
	t.assertnil(htmldoc->back(3), "Back");
	t.assert(waitfor(ev, "done") != nil, "loads");
	t.assertseq(htmldoc->url(3), URL, "Back is the first page");
	t.assertnil(htmldoc->forward(3), "Fwd");
	t.assert(waitfor(ev, "done") != nil, "loads");
	t.assertseq(htmldoc->url(3), PAGE2, "Fwd is the second again");
	t.assertnil(htmldoc->reload(3), "Reload");
	t.assert(waitfor(ev, "done") != nil, "loads");
	t.assertseq(htmldoc->url(3), PAGE2, "the same page");
	t.assertseq(htmldoc->forward(3), "no next page", "Fwd at the end of the history");
	(nil, err) := htmldoc->browse(3, URL, 400, 300);
	t.assertnil(err, "browse again in the same window");
	t.assert(waitfor(ev, "done") != nil, "loads");
	t.assertnil(htmldoc->back(3), "and Back has where it was");
	t.assert(waitfor(ev, "done") != nil, "loads");
	t.assertseq(htmldoc->url(3), PAGE2, "the page before");
}

testControl(t: ref T)
{
	(c, err) := htmldoc->browse(4, "file://" + DIR + "form.html", 400, 300);
	t.assertnil(err, "browse a form");
	t.assert(c != nil && waitfor(c, "done") != nil, "it loads");
	(hit, cerr) := htmldoc->click(4, 5, 5);
	t.asserteq(hit, 1, "a click on the checkbox acts");
	t.assertnil(cerr, "without error");
	(hit, nil) = htmldoc->click(4, 10, 50);
	t.asserteq(hit, 0, "a click on plain text does nothing");
	htmldoc->drop(4);
	t.assert(waitfor(c, "gone") != nil, "a dropped page's reader is told");
}

field(t: ref T, id: int, name: string): ref Htmldoc->Field
{
	f := htmldoc->fields(id);
	for(i := 0; i < len f; i++)
		if(f[i].name == name)
			return f[i];
	t.fatal("no field " + name);
	return nil;
}

# The page's pixels in r
pixels(id: int, r: Rect): array of byte
{
	im := disp.newimage(Rect((0, 0), (400, 300)), Draw->RGB24, 0, Draw->White);
	htmldoc->paint(id, im, 0);
	b := array[r.dx() * r.dy() * 3] of byte;
	im.readpixels(r, b);
	return b;
}

testFields(t: ref T)
{
	(c, err) := htmldoc->browse(5, "file://" + DIR + "fields.html", 400, 300);
	t.assertnil(err, "browse");
	t.assert(c != nil && waitfor(c, "done") != nil, "it loads");
	pw := field(t, 5, "pw");
	t.assertseq(pw.kind, "password", "a password field");
	t.assertseq(pw.value, "abcdef", "its value");
	t.assert(pw.box.dx() >= 200 && pw.box.dy() >= 30, sys->sprint("its box, border and padding too: %d by %d", pw.box.dx(), pw.box.dy()));
	tx := field(t, 5, "t");
	t.assert(tx.box.min.y >= pw.box.max.y, "the text field below it");
	s := field(t, 5, "s");
	t.assertseq(s.value, "b", "the select's selected option");

	# what a password field shows does not depend on what is in it
	before := pixels(5, pw.box);
	t.assertnil(htmldoc->setfield(5, pw.node, "ghijkl"), "set the password");
	t.assertseq(field(t, 5, "pw").value, "ghijkl", "the password's new value");
	t.assert(same(before, pixels(5, pw.box)), "a password is drawn masked");

	# and a text field's does
	before = pixels(5, tx.box);
	t.assertnil(htmldoc->setfield(5, tx.node, "ghijkl"), "set the text");
	t.assert(!same(before, pixels(5, tx.box)), "a text field shows its text");

	t.assertnil(htmldoc->setfield(5, s.node, "c"), "choose an option");
	t.assertseq(field(t, 5, "s").value, "c", "the select's new value");
	htmldoc->drop(5);
}

testSubmit(t: ref T)
{
	(c, err) := htmldoc->browse(6, "file://" + DIR + "search.html", 400, 300);
	t.assertnil(err, "browse");
	t.assert(c != nil && waitfor(c, "done") != nil, "it loads");
	q := field(t, 6, "q");
	t.assertnil(htmldoc->setfield(6, q.node, "plan 9"), "type");
	t.assertnil(htmldoc->submit(6, q.form), "submit");
	t.assert(waitfor(c, "done") != nil, "the result loads");
	u := htmldoc->url(6);
	t.assert(contains(u, "result.html?q=plan+9") || contains(u, "result.html?q=plan%209"), "the form's URL with the field: " + u);
	t.assertseq(htmldoc->title(6), "Result", "the result page");
	htmldoc->drop(6);
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
	run("Browse", testBrowse);
	run("Follow", testFollow);
	run("History", testHistory);
	run("Control", testControl);
	run("Fields", testFields);
	run("Submit", testSubmit);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
