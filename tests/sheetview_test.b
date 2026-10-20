implement SheetviewTest;

#
# The document view (sheetview(2)) on an image of its own, with a PDF of
# three pages made here: opened through its events, fitted, painted
# (ink where the text is), paged, zoomed, a search finding the page a
# word is on, the sheets turned (their sizes, and a point on the screen
# taken back to the page), its place kept when it is resized, and the
# way it last moved.  A web page is painted from a band round the view,
# or, with a header fixed to the window, all of what is shown.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "docengine.m";
include "docreg.m";
	docreg: Docreg;

include "sheetview.m";
	sheetview: Sheetview;
	View, Ev, Note: import sheetview;

include "testing.m";
	testing: Testing;
	T: import testing;

SheetviewTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sheetview_test.b";

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

# Three pages, 400 by 500 points, each saying which it is; page 2 also
# says "zebra"
threepages(): array of byte
{
	o := array[9] of string;
	o[0] = "<< /Type /Catalog /Pages 2 0 R >>";
	o[1] = "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>";
	for(i := 0; i < 3; i++){
		o[2+i] = sprint("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Contents %d 0 R " +
			"/Resources << /Font << /F1 9 0 R >> >> >>", 6+i);
		c := sprint("BT /F1 36 Tf 50 400 Td (Page %d) Tj ET", i+1);
		if(i == 1)
			c += " BT /F1 24 Tf 50 200 Td (zebra) Tj ET";
		o[5+i] = "<< /Length " + string len c + " >>\nstream\n" + c + "\nendstream";
	}
	o[8] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>";
	body := "%PDF-1.4\n";
	offs := array[len o] of int;
	for(i = 0; i < len o; i++){
		offs[i] = len body;
		body += string (i+1) + " 0 obj\n" + o[i] + "\nendobj\n";
	}
	x := len body;
	body += "xref\n0 " + string (len o + 1) + "\n0000000000 65535 f \n";
	for(i = 0; i < len o; i++)
		body += sprint("%010d 00000 n \n", offs[i]);
	body += "trailer\n<< /Size " + string (len o + 1) + " /Root 1 0 R >>\nstartxref\n" + string x + "\n%%EOF\n";
	b := array[len body] of byte;
	for(i = 0; i < len body; i++)
		b[i] = byte body[i];
	return b;
}

# A view of the three pages, opened, drawn on an image 500 by 400
opened(t: ref T): ref View
{
	if(display == nil)
		t.skip("no display");
	c := chan[16] of ref Ev;	# nothing is left blocked sending after a test
	v := sheetview->new(docreg->kindof("pdf"), "three.pdf", c);
	v.dst = display.newimage(Rect((0, 0), (500, 400)), Draw->RGB24, 0, Draw->Black);
	v.r = v.dst.r;
	v.bg = display.color(int 16r808080FF);
	v.open(threepages(), "three.pdf");
	if(!until(v, "opened"))
		t.fatal("not opened: " + v.err);
	return v;
}

# Events handled until a note of the kind named, or 5 s
until(v: ref View, want: string): int
{
	tick := chan of int;
	spawn timer(tick, 5000);
	for(;;) alt {
	e := <-v.c =>
		n := v.handle(e);
		if(n == nil)
			continue;
		got := "";
		pick o := n {
		Opened =>	got = "opened";
		Redraw =>	got = "redraw";
		Text =>	got = "text";
		Failed =>	got = "failed"; return 0;
		* =>	got = "other";
		}
		if(got == want)
			return 1;
	<-tick =>
		return 0;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

# The view drawn until its sheets in view are painted
drawn(v: ref View)
{
	for(i := 0; i < 6; i++){
		v.draw();
		if(!v.painting)
			return;
		until(v, "redraw");
	}
	v.draw();
}

# How many dark pixels in r of the view's image
ink(v: ref View, r: Rect): int
{
	(r, nil) = r.clip(v.dst.r);
	b := array[r.dx() * 3] of byte;
	n := 0;
	for(y := r.min.y; y < r.max.y; y++){
		v.dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), b);
		for(x := 0; x < r.dx(); x++)
			if(int b[3*x+1] < 100)
				n++;
	}
	return n;
}

testOpen(t: ref T)
{
	v := opened(t);
	t.asserteq(len v.sizes, 3, "three sheets");
	t.asserteq(v.sizes[0].x, 400, "400 points wide at scale 100");
	t.asserteq(v.fit, Sheetview->Fitwidth, "a PDF fitted to the width");
	# 500 wide less the gap each side: 476 / 400
	t.asserteq(v.scale, (500 - 2*Sheetview->GAP) * 100 / 400, "the scale the width gives");
	v.close();
}

testPaint(t: ref T)
{
	v := opened(t);
	drawn(v);
	sr := v.sheetrect(0);
	# "Page 1" at 36 points, 100 from the top, 50 in, at the view's scale
	s := v.scale;
	text := Rect((50*s/100, 64*s/100), (200*s/100, 104*s/100)).addpt(sr.min);
	t.assert(ink(v, text) > 100, sys->sprint("ink where the text is (%d)", ink(v, text)));
	blank := Rect((50*s/100, 300*s/100), (300*s/100, 350*s/100)).addpt(sr.min);
	t.asserteq(ink(v, blank), 0, "none where there is none");
	v.close();
}

testPaging(t: ref T)
{
	v := opened(t);
	v.layout();
	(ok, err) := v.command("NextPage", nil);
	t.assert(ok && err == nil, "NextPage taken");
	t.asserteq(v.sheetat(v.org.y), 1, "on the second sheet");
	v.command("Page", "3");
	t.asserteq(v.sheetat(v.org.y), 2, "Page 3");
	v.command("Zoom", "50");
	t.asserteq(v.scale, 50, "Zoom 50");
	t.asserteq(v.fit, Sheetview->Fitnone, "no longer fitted");
	v.command("Fit", "page");
	v.layout();
	t.asserteq(v.fit, Sheetview->Fitpage, "Fit page");
	t.assert(v.size(0).y * v.scale / 100 <= 400, "a whole sheet in view");
	(ok, nil) = v.command("Frobnicate", nil);
	t.asserteq(ok, 0, "not a command");
	v.close();
}

testFind(t: ref T)
{
	v := opened(t);
	v.layout();
	err := v.find("ZEBRA");
	t.assert(err == nil, "found: " + err);
	t.assert(v.found != nil && hd v.found == 1 && tl v.found == nil, "on the second sheet alone");
	t.asserteq(v.sheetat(v.org.y + v.r.dy() / 3), 1, "the second sheet brought into view");
	rl := v.foundon(1);
	t.assert(rl != nil, "where on it");
	if(rl != nil)
		t.assert((hd rl).min.y > 250 && (hd rl).max.y < 320, sys->sprint("its box, 300 down (%d)", (hd rl).min.y));
	t.assertseq(v.find("aardvark"), "not found", "not there");
	v.close();
}

testTurn(t: ref T)
{
	v := opened(t);
	v.layout();
	v.rotate(1);
	v.layout();
	sz := v.size(0);
	t.assert(sz.x == 500 && sz.y == 400, "turned, 500 wide by 400");
	# the engine's point (50, 100) on the first sheet, turned right, is
	# at (h - y, x) = (400, 50), scale 100
	sr := v.sheetrect(0);
	s := v.scale;
	p := sr.min.add(Point(400*s/100, 50*s/100));
	(n, ep) := v.at(p);
	t.asserteq(n, 0, "on the first sheet");
	t.assert(abs(ep.x - 50) <= 1 && abs(ep.y - 100) <= 1, sys->sprint("back at (50, 100): (%d, %d)", ep.x, ep.y));
	drawn(v);
	v.rotate(3);
	v.layout();
	t.asserteq(v.size(0).x, 400, "turned back");
	v.close();
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

testKeepPlace(t: ref T)
{
	v := opened(t);
	v.layout();
	v.gotosheet(1);
	before := v.sheetat(v.org.y);
	into := v.org.y - v.tops[before];
	# narrower and shorter: fitted again, at a smaller scale
	v.r = Rect((0, 0), (400, 300));
	v.layout();
	t.asserteq(v.sheetat(v.org.y), before, "still at the second sheet");
	want := into * v.scale / ((500 - 2*Sheetview->GAP) * 100 / 400);
	got := v.org.y - v.tops[before];
	t.assert(abs(got - want) <= 1, sys->sprint("as far into it, scaled: %d, want %d", got, want));
	v.close();
}

testDirection(t: ref T)
{
	v := opened(t);
	v.layout();
	v.scroll(100);
	t.asserteq(v.dir, 1, "down");
	v.scroll(-50);
	t.asserteq(v.dir, -1, "up");
	v.close();
}

# A long web page (an HTML file), drawn on an image 500 by 400, with
# top at the start of its body
htmlview(t: ref T, top: string): ref View
{
	if(display == nil)
		t.skip("no display");
	page := "<html><body>" + top;
	for(i := 0; i < 60; i++)
		page += sprint("<h2>Part %d</h2><p>Some words in part %d, enough of them to wrap onto a second line in a view five hundred wide.</p>", i, i);
	page += "</body></html>";
	c := chan[16] of ref Ev;
	v := sheetview->new(docreg->kindof("html"), "long.html", c);
	v.dst = display.newimage(Rect((0, 0), (500, 400)), Draw->RGB24, 0, Draw->Black);
	v.r = v.dst.r;
	v.bg = display.color(int 16r808080FF);
	v.style = ref Docengine->Style(0, nil, nil, nil, nil, nil, nil, 0);
	v.open(array of byte page, "long.html");
	if(!until(v, "opened"))
		t.fatal("not opened: " + v.err);
	return v;
}

# Whether r of a and of b are the same pixels
same(a, b: ref Image, r: Rect): int
{
	ba := array[r.dx() * 3] of byte;
	bb := array[r.dx() * 3] of byte;
	for(y := r.min.y; y < r.max.y; y++){
		a.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), ba);
		b.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), bb);
		for(i := 0; i < len ba; i++)
			if(ba[i] != bb[i])
				return 0;
	}
	return 1;
}

# What the view shows of its one sheet, painted by the engine at once
direct(v: ref View): ref Image
{
	im := display.newimage(v.dst.r, Draw->RGB24, 0, Draw->White);
	sr := v.sheetrect(0);
	(vis, nil) := sr.clip(v.r);
	v.eng->paint(v.h, 0, 100, im, vis, vis.min.sub(sr.min));
	return im;
}

# A flowing document is painted off the image, into a band round the
# view: a scroll within it paints nothing, one past it paints only
# what it exposes, and what is shown is what the engine paints
testBand(t: ref T)
{
	v := htmlview(t, nil);
	v.draw();
	b := v.band;
	t.assert(b != nil, "a band painted");
	if(b == nil)
		t.fatal("no band");
	t.assert(v.bandr.min.y <= 0 && v.bandr.max.y >= 400 - Sheetview->GAP, "it holds the view");
	v.scroll(40);
	v.draw();
	t.assert(v.band == b, "a scroll within it paints nothing");
	sr := v.sheetrect(0);
	(vis, nil) := sr.clip(v.r);
	t.assert(same(v.dst, direct(v), vis), "what is shown is the page");
	old := v.bandr;
	for(i := 0; i < 8; i++){
		v.scroll(60);
		v.draw();
	}
	t.assert(v.band != b, "a scroll past it moves it");
	t.assert(v.bandr.min.y > old.min.y && v.bandr.min.y < old.max.y, sys->sprint("keeping what it held (%d..%d, was %d..%d)", v.bandr.min.y, v.bandr.max.y, old.min.y, old.max.y));
	sr = v.sheetrect(0);
	(vis, nil) = sr.clip(v.r);
	t.assert(same(v.dst, direct(v), vis), "what is shown after it moved is the page");
	v.result("paint");
	t.assert(v.band == nil, "a page changed by a click or key is painted again");
	v.close();
}

# A page with a header fixed to the top of the window is painted where
# the view is, all of it, as it scrolls: a strip painted as the top of
# the window had a header of its own (bbc.com's, down the page)
testPinned(t: ref T)
{
	v := htmlview(t, "<div style=\"position: fixed; top: 0; left: 0; right: 0; height: 40px; background: red\"></div>");
	t.assert(v.eng->pinned(v.h), "the page has a part pinned to the view");
	v.draw();
	for(i := 0; i < 12; i++){
		v.scroll(30);
		v.draw();
	}
	t.assert(v.org.y > 0, "the view scrolled");
	t.assert(v.band == nil, "it is not painted into a band");
	(n, first, last) := reds(v.dst);
	t.asserteq(n, 40, sys->sprint("the header's rows red, and only those (%d..%d)", first, last));
	t.asserteq(first, 0, "at the top of the view");
	sr := v.sheetrect(0);
	(vis, nil) := sr.clip(v.r);
	t.assert(same(v.dst, direct(v), vis), "what is shown is the page");
	v.close();

	v = htmlview(t, nil);
	t.assert(!v.eng->pinned(v.h), "a page with nothing fixed has nothing pinned");
	v.close();
}

# The rows of im red at its right edge: how many, the first and last
reds(im: ref Image): (int, int, int)
{
	b := array[3] of byte;
	n := 0;
	first := -1;
	last := -1;
	x := im.r.max.x - 2;
	for(y := im.r.min.y; y < im.r.max.y; y++){
		im.readpixels(Rect((x, y), (x+1, y+1)), b);
		# RGB24 is stored b g r
		if(int b[2] > 200 && int b[1] < 60 && int b[0] < 60){
			if(first < 0)
				first = y;
			last = y;
			n++;
		}
	}
	return (n, first, last);
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
	docreg = load Docreg Docreg->PATH;
	sheetview = load Sheetview Sheetview->PATH;
	if(docreg == nil || sheetview == nil){
		sys->fprint(sys->fildes(2), "cannot load docreg or sheetview: %r\n");
		raise "fail:load";
	}
	docreg->init(display);
	sheetview->init(display);

	run("Open", testOpen);
	run("Paint", testPaint);
	run("Paging", testPaging);
	run("Find", testFind);
	run("Turn", testTurn);
	run("KeepPlace", testKeepPlace);
	run("Direction", testDirection);
	run("Band", testBand);
	run("Pinned", testPinned);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
