implement WebPageTest;

#
# The page pipeline (page(2)): what a page asks for, in what order;
# what it lays out.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Rect, Point, Image: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
	layout: Layout;
	Box: import layout;
include "web/page.m";
	page: Page;
	Pg: import page;

WebPageTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_page_test.b";

passed := 0;
failed := 0;
skipped := 0;

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

# The pictures are fetched in the order wanted gives, a few at a time:
# from the top of the page down, whatever the document's order, so a
# long page's last pictures do not hold up the ones it opens on
testWantedOrder(t: ref T)
{
	src := "<body style='margin:0'><div style='height:1500px'></div>" +
		"<img src=far.png style='position:absolute;top:1000px;width:10px;height:10px'>" +
		"<img src=near.png style='position:absolute;top:300px;width:10px;height:10px'>" +
		"<div style='position:absolute;top:0;height:50px;width:50px;background:url(top.png)'></div>";
	f := "/tmp/web_page_test.html";
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("create %s: %r", f));
	b := array of byte src;
	sys->write(fd, b, len b);
	fd = nil;
	(pg, err) := page->begin("file://" + f, "GET", nil, nil, 800, 600);	# laid out, no picture fetched
	sys->remove(f);
	if(pg == nil)
		t.fatal("begin: " + err);
	got := "";
	for(l := pg.wanted(); l != nil; l = tl l)
		got += " " + hd l;
	t.log("wanted:" + got);
	t.assertseq(got, " file:///tmp/top.png file:///tmp/near.png file:///tmp/far.png", "top to bottom");
}

# A page for a screen of two pixels to the px (page->scale(2.0), a
# Retina display): every length twice as many pixels, the default font
# and a checkbox's size too, as sharp, not scaled up; media queries
# still in CSS px, the viewport's width over the scale
testScale(t: ref T)
{
	src := "<style>@media (min-width: 700px) { #mq { width: 300px } }</style>" +
		"<body style='margin:0'><div id=d style='width:100px;height:50px;border:medium solid'></div>" +
		"<p id=p style='margin:0'>words</p><input id=c type=checkbox>" +
		"<div id=mq style='width:200px;height:10px'></div>";
	f := "/tmp/web_page_scale.html";
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("create %s: %r", f));
	b := array of byte src;
	sys->write(fd, b, len b);
	fd = nil;
	page->scale(2.0);
	(pg, err) := page->begin("file://" + f, "GET", nil, nil, 1200, 800);	# 600 by 400 CSS px
	page->scale(1.0);
	sys->remove(f);
	if(pg == nil)
		t.fatal("begin: " + err);
	layout = page->layoutmod();
	d := boxof(pg.doc, pg.root, "d");
	if(d == nil)
		t.fatal("no box for #d");
	t.asserteq(d.w, 2*(100+2*3), "100px wide with medium borders, at two pixels to the px");
	t.asserteq(d.h, 2*(50+2*3), "50px high with medium borders");
	if((p := boxof(pg.doc, pg.root, "p")) != nil)
		t.assert(p.h >= 2*16 && p.h <= 2*24, sys->sprint("a line of the 16px font: %d pixels", p.h));
	else
		t.error("no box for #p");
	if((c := boxof(pg.doc, pg.root, "c")) != nil)
		t.assert(c.w >= 2*13, sys->sprint("a checkbox 13px square, at least: %d", c.w));
	else
		t.error("no box for #c");
	if((mq := boxof(pg.doc, pg.root, "mq")) != nil)
		t.asserteq(mq.w, 2*200, "the viewport 600px wide: (min-width: 700px) does not match");
	else
		t.error("no box for #mq");
}

# a page of src, laid out at w by h, no picture fetched
pageof(t: ref T, src: string, w, h: int): ref Pg
{
	f := "/tmp/web_page_test_src.html";
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("create %s: %r", f));
	b := array of byte src;
	sys->write(fd, b, len b);
	fd = nil;
	(pg, err) := page->begin("file://" + f, "GET", nil, nil, w, h);
	sys->remove(f);
	if(pg == nil)
		t.fatal("begin: " + err);
	layout = page->layoutmod();
	return pg;
}

# A select draws its arrow, unless its appearance is none: then the
# page draws one (DuckDuckGo's chevron, an ::after), and there were two
testSelectArrow(t: ref T)
{
	pg := pageof(t, "<select id=a><option>All Regions</select>" +
		"<select id=n style='appearance:none'><option>Any Time</select>" +
		"<select id=w style='-webkit-appearance:none'><option>Any Time</select>", 800, 600);
	if((a := boxof(pg.doc, pg.root, "a")) != nil)
		t.assertseq(a.text, "All Regions ▾", "appearance auto: the arrow");
	else
		t.error("no box for #a");
	if((n := boxof(pg.doc, pg.root, "n")) != nil)
		t.assertseq(n.text, "Any Time", "appearance none: no arrow");
	else
		t.error("no box for #n");
	if((w := boxof(pg.doc, pg.root, "w")) != nil)
		t.assertseq(w.text, "Any Time", "-webkit-appearance none: no arrow");
	else
		t.error("no box for #w");
}

# A grid's min-content size counts a track with a length for its
# minimum at that length, whatever its items: a minmax(0, 1fr) column
# adds nothing (an fr's flex fraction is zero there, Grid §12.7.1).
# Tailwind's hero, an auto column's item beside such a grid holding a
# 1536px carousel, was laid out 4017px wide in a 1200px grid
testGridMinContent(t: ref T)
{
	pg := pageof(t, "<style>body{margin:0} .w{width:2000px;height:1px}</style>" +
		"<div id=o style='display:grid;width:600px'><div id=i>" +
		"<div id=g style='display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px'>" +
		"<div style='overflow:hidden'><div class=w></div></div><div><div class=w></div></div><div>c</div></div>" +
		"<div id=t style='display:grid;grid-template-columns:minmax(0,100px) 50px'><div><div class=w></div></div><div></div></div>" +
		"</div></div>", 1280, 800);
	if((i := boxof(pg.doc, pg.root, "i")) != nil)
		t.asserteq(i.w, 600, "the auto column's item: the grid's width, not its 2000px items'");
	else
		t.error("no box for #i");
	if((g := boxof(pg.doc, pg.root, "g")) != nil)
		t.asserteq(g.w, 600, "the minmax(0, 1fr) grid fills it");
	else
		t.error("no box for #g");
	if((k := boxof(pg.doc, pg.root, "t")) != nil)
		t.asserteq(k.w, 600, "minmax(0, 100px) and 50px: a block, as wide as its container");
	else
		t.error("no box for #t");
}

# font: 0/0 a, the image-replacement idiom, sets a size of 0 and a
# line height of 0: the 0 was taken for a weight, the rule dropped, and
# weather.gov's header drew its text over its picture of that text
testFontZero(t: ref T)
{
	pg := pageof(t, "<style>div{margin:0}</style>" +
		"<div id=z style='font:0/0 serif'>text</div>" +
		"<div id=g style='font:0/0 a'><span style='font:3px/1 a'>x</span></div>" +
		"<div id=w style='font:700 20px/30px serif'>bold</div>", 800, 600);
	if((z := boxof(pg.doc, pg.root, "z")) != nil)
		t.asserteq(z.h, 0, "font: 0/0: no height");
	else
		t.error("no box for #z");
	if((g := boxof(pg.doc, pg.root, "g")) != nil)
		t.asserteq(g.h, 3, "a 3px/1 span inside it: 3 high");
	else
		t.error("no box for #g");
	if((w := boxof(pg.doc, pg.root, "w")) != nil)
		t.asserteq(w.h, 30, "a weight before the size is still a weight");
	else
		t.error("no box for #w");
}

# <center> and align= place their block children, and centre their
# text: a table in a <td align=center> is centred in it (plan9.io's
# were at its left), a heading in <center> is centred, a div in it
# places its own children; a table's text goes back to the start, as
# Blink's has it (Hacker News's titles, in a <center>'d table)
testAlignChildren(t: ref T)
{
	pg := pageof(t, "<body style='margin:0'><table id=o style='width:300px;border-spacing:0'><tr><td id=c align=center style='padding:0'>" +
		"<table id=i style='width:100px;border-spacing:0'><tr><td>x</td></tr></table></td></tr></table>" +
		"<center><div style='width:400px'><table id=n style='width:100px'><tr><td>y</td></tr></table></div>" +
		"<table id=t style='width:200px'><tr><td id=tc>title</td></tr></table></center>" +
		"<div align=right style='width:300px'><table id=r style='width:100px'><tr><td>z</td></tr></table></div>", 800, 600);
	if((i := boxof(pg.doc, pg.root, "i")) != nil)
		t.asserteq(absx(i), 100, "a table in a td align=center: centred");
	else
		t.error("no box for #i");
	if((n := boxof(pg.doc, pg.root, "n")) != nil)
		t.asserteq(absx(n), 350, "in <center>, a div's table: centred in the div (400 wide at 200)");
	else
		t.error("no box for #n");
	if((r := boxof(pg.doc, pg.root, "r")) != nil)
		t.asserteq(absx(r), 200, "in a div align=right, at its right");
	else
		t.error("no box for #r");
	if((tc := boxof(pg.doc, pg.root, "tc")) != nil)
		t.asserteq(tc.st.align, Style->Astart, "a <center>'d table's cell: its text at the start");
	else
		t.error("no box for #tc");
}

absx(b: ref Box): int
{
	x := 0;
	for(; b != nil; b = b.parent)
		x += b.x;
	return x;
}

# the colour at the middle of the picture a box shows, as 16rRRGGBB
midcolour(b: ref Box): int
{
	if(b == nil || b.img == nil)
		return -1;
	d := b.img.display;
	px := d.newimage(Rect((0, 0), (1, 1)), Draw->RGB24, 0, Draw->White);
	c := b.img.r.min.add(Point(b.img.r.dx()/2, b.img.r.dy()/2));
	px.draw(px.r, b.img, nil, c);
	a := array[3] of byte;
	px.readpixels(px.r, a);
	return (int a[2] << 16) | (int a[1] << 8) | int a[0];
}

# An inline svg's presentation attributes take var() from the custom
# properties of the element they are on, falling back as var() does:
# the picture is drawn from markup, where they meant nothing, and
# Stripe's customer logos (fill="var(--customerLogoColor, #003478)")
# and Sign in button were black
testSvgVars(t: ref T)
{
	pg := pageof(t, "<style>body{margin:0;--c:#00ff00} .k{--d:#ff0000}</style>" +
		"<svg id=v width=20 height=20><rect width=20 height=20 fill='var(--c)'/></svg>" +
		"<svg id=f width=20 height=20><rect width=20 height=20 fill='var(--none, #0000ff)'/></svg>" +
		"<svg id=n class=k width=20 height=20><rect width=20 height=20 fill='var(--none, var(--d))'/></svg>", 800, 600);
	for(l := ("v", 16r00FF00, "var(--c)") :: ("f", 16r0000FF, "a fallback") :: ("n", 16rFF0000, "a fallback that is a var()") :: nil; l != nil; l = tl l) {
		(id, want, what) := hd l;
		b := boxof(pg.doc, pg.root, id);
		got := midcolour(b);
		t.assert(got == want, sys->sprint("%s: %.6x, want %.6x", what, got, want));
	}
}

# the first box of the element with id
boxof(d: ref Doc, root: ref Box, id: string): ref Box
{
	for(n := 1; n < d.n; n++)
		if(d.attr(n, "id") == id) {
			l := layout->boxes(root, n);
			if(l == nil)
				return nil;
			return hd l;
		}
	return nil;
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
	dom = load Dom Dom->PATH;
	page = load Page Page->PATH;
	if(page == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Page->PATH);
		raise "fail:load";
	}
	if((err := page->init(Display.allocate(nil))) != nil) {
		sys->fprint(sys->fildes(2), "page: %s\n", err);
		raise "fail:init";
	}
	run("WantedOrder", testWantedOrder);
	run("Scale", testScale);
	run("SelectArrow", testSelectArrow);
	run("GridMinContent", testGridMinContent);
	run("SvgVars", testSvgVars);
	run("FontZero", testFontZero);
	run("AlignChildren", testAlignChildren);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
