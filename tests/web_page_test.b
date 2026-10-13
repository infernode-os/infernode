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
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
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
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
