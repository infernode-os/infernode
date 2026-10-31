implement WebPageTest;

#
# The page pipeline (page(2)): what a page asks for, in what order.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
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
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
