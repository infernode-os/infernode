implement WebBrowserTest;

#
# The browsing session, driven only through /mnt/charon as an agent or
# a shell script would: navigation and history, text, links, forms,
# find, events, the image, and dom/<n>/{tag,attrs,box,style}.
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
include "web/browser.m";
	browser: Browser;
	Session: import browser;
include "web/charonfs.m";
	charonfs: Charonfs;

WebBrowserTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_browser_test.b";
DIR: con "file:///tests/charon/browser/";
MNT: con "/mnt/charon";

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

rd(f: string): string
{
	fd := sys->open(MNT + "/" + f, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: %r");
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

wr(f, s: string): string
{
	fd := sys->open(MNT + "/" + f, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	if(sys->fprint(fd, "%s", s) < 0)
		return sys->sprint("%r");
	return nil;
}

# Write a ctl command and wait for the load it starts: the event file
# is opened first, so the answer cannot be missed.
nav(t: ref T, cmd: string): string
{
	ev := sys->open(MNT + "/event", Sys->OREAD);
	if(ev == nil)
		t.fatal(sys->sprint("open event: %r"));
	if((err := wr("ctl", cmd)) != nil)
		return "ctl: " + err;
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(ev, buf, len buf);
		if(n <= 0)
			return "event: eof";
		e := string buf[0:n];
		if(prefix(e, "done") || prefix(e, "error"))
			return chomp(e);
	}
}

chomp(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		return s[0:len s - 1];
	return s;
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

lines(s: string): list of string
{
	(nil, l) := sys->tokenize(s, "\n");
	return l;
}

# the node whose attrs include "id <id>"
byid(id: string): int
{
	fd := sys->open(MNT + "/dom", Sys->OREAD);
	if(fd == nil)
		return 0;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			return 0;
		for(i := 0; i < n; i++)
			for(l := lines(rd("dom/" + d[i].name + "/attrs")); l != nil; l = tl l)
				if(hd l == "id " + id)
					return int d[i].name;
	}
}

testOpen(t: ref T)
{
	t.assertseq(nav(t, "open " + DIR + "a.html"), "done " + DIR + "a.html", "load event");
	t.assertseq(rd("status"), "done\n", "status");
	t.assertseq(rd("title"), "Page A\n", "title");
	t.assertseq(rd("url"), DIR + "a.html\n", "url");
	text := rd("text");
	t.log(text);
	l := lines(text);
	t.assert(l != nil && hd l == "First heading", "first block is the heading: " + text);
	t.assert(contains(text, "\nA paragraph with a link to B and emphasis.\n"), "inline text joins into one line");
	t.assert(contains(text, "one\n") && contains(text, "two\n"), "list items");
	t.assert(contains(text, "c1\tc2\n"), "table row cells are tab separated");
	t.assert(contains(text, "picture link"), "alt text stands in for an image");
}

testLinks(t: ref T)
{
	links := rd("links");
	t.log(links);
	l := lines(links);
	t.asserteq(len l, 2, "two links");
	if(len l == 2) {
		t.assertseq(hd l, "1 " + DIR + "b.html link to B", "link 1");
		t.assertseq(hd tl l, "2 " + DIR + "a.html#sec picture link", "an image link takes its alt");
	}
}

testHistory(t: ref T)
{
	t.assertseq(nav(t, "follow 1"), "done " + DIR + "b.html", "follow");
	t.assertseq(rd("title"), "Page B\n", "followed to B");
	t.assertseq(nav(t, "back"), "done " + DIR + "a.html", "back");
	t.assertseq(nav(t, "forward"), "done " + DIR + "b.html", "forward");
	t.assertseq(nav(t, "back"), "done " + DIR + "a.html", "back again");
	t.assertseq(nav(t, "back"), "ctl: no previous page", "nothing before A");
	t.assertseq(wr("ctl", "bogus"), "unknown command bogus", "unknown ctl");
}

testFragment(t: ref T)
{
	t.assertseq(nav(t, "follow 2"), "done " + DIR + "a.html#sec", "in-page link");
	t.assertseq(rd("title"), "Page A\n", "same page");
	box := byid("box");
	t.assert(box != 0, "found #box");
	b := chomp(rd(sys->sprint("dom/%d/box", box)));
	t.log("box: " + b);
	(n, f) := sys->tokenize(b, " ");
	t.asserteq(n, 5, "one box line");
	if(n == 5) {
		t.assertseq(hd f, "block", "block box");
		t.asserteq(int hd tl f, 8 + 20, "x: body margin + margin-left");
		t.asserteq(int hd tl tl tl f, 100, "width");
		t.asserteq(int hd tl tl tl tl f, 50, "height");
	}
	t.assertseq(rd(sys->sprint("dom/%d/tag", box)), "div\n", "tag");
	st := rd(sys->sprint("dom/%d/style", box));
	t.assert(contains(st, "display block"), "style has display: " + st);
	sec := byid("sec");
	t.assert(sec != 0, "found #sec");
	t.assertseq(rd(sys->sprint("dom/%d/text", sec)), "Second section", "element text");
	# the fragment named it the :target and the view moved to it
	t.assertseq(nav(t, "back"), "done " + DIR + "a.html", "back from the fragment");
}

testFind(t: ref T)
{
	t.assertnil(wr("find", "SECOND"), "write find");
	t.assertseq(rd("find"), "Second section\n", "case-insensitive match");
	t.assertnil(wr("find", "zzz"), "write find");
	t.assertseq(rd("find"), "", "no match");
}

testImage(t: ref T)
{
	img := rd("image");
	t.assert(len img > 60, sys->sprint("image has data (%d bytes)", len img));
	t.assert(contains(img[0:60], "r8g8b8") || contains(img[0:60], "x8r8g8b8"), "image(6) header: " + img[0:60]);
}

testForms(t: ref T)
{
	t.assertseq(nav(t, "open " + DIR + "form.html"), "done " + DIR + "form.html", "load form");
	f := rd("forms");
	t.log(f);
	t.assert(contains(f, " text q hello\n"), "text field");
	t.assert(contains(f, " checkbox cb yes\n"), "unchecked checkbox");
	t.assert(contains(f, " radio r 1 checked\n"), "checked radio");
	t.assert(contains(f, " select s b\n\toption alpha alpha\n\toption b beta selected\n"), "select and options");
	t.assert(contains(f, " textarea t some text\n"), "textarea");
	t.assert(contains(f, "\n0 "), "a control outside any form is form 0");

	# node numbers, by name
	q := 0; cb := 0; r2 := 0; s := 0; ta := 0; go := 0;
	for(l := lines(f); l != nil; l = tl l) {
		(n, w) := sys->tokenize(hd l, " ");
		if(n < 4 || (hd l)[0] == '\t')
			continue;
		node := int hd tl w;
		name := hd tl tl tl w;
		case name {
		"q" => q = node;
		"cb" => cb = node;
		"r" => if(n >= 5 && hd tl tl tl tl w == "2") r2 = node;
		"s" => s = node;
		"t" => ta = node;
		"go" => go = node;
		}
	}
	t.assert(q != 0 && cb != 0 && r2 != 0 && s != 0 && ta != 0 && go != 0, "found the fields");

	t.assertnil(wr("ctl", sys->sprint("set %d world & more", q)), "set text");
	t.assertnil(wr("ctl", sys->sprint("click %d", cb)), "click checkbox");
	t.assertnil(wr("ctl", sys->sprint("set %d on", r2)), "set radio 2");
	t.assertnil(wr("ctl", sys->sprint("set %d alpha", s)), "choose an option");
	t.assertnil(wr("ctl", sys->sprint("set %d two\nlines", ta)), "set textarea");
	t.assertseq(wr("ctl", sys->sprint("set %d x", go)), "cannot set a submit", "a button has no value to set");
	f = rd("forms");
	t.assert(contains(f, " radio r 1\n"), "radio 1 went off: " + f);
	t.assert(contains(f, " radio r 2 checked\n"), "radio 2 on");
	t.assert(contains(f, " checkbox cb yes checked\n"), "checkbox on");
	t.assert(contains(rd("text"), "world & more"), "the page shows the new value");

	want := DIR + "b.html?q=world+%26+more&cb=yes&r=2&s=alpha&t=two%0Alines&h=x+y&go=Go";
	t.assertseq(nav(t, sys->sprint("click %d", go)), "done " + want, "submit by clicking the button");
	t.assertseq(rd("title"), "Page B\n", "landed on the action");
}

postname: string;

# The posted session, mounted from a separate name space as an agent's
# tool would: the same session, its own connection.
# <meta http-equiv=refresh content="0; url=b.html"> goes to B once A has loaded
testRefresh(t: ref T)
{
	ev := sys->open(MNT + "/event", Sys->OREAD);
	if(ev == nil)
		t.fatal(sys->sprint("open event: %r"));
	if((err := wr("ctl", "open " + DIR + "refresh.html")) != nil)
		t.fatal("ctl: " + err);
	buf := array[1024] of byte;
	got: list of string;
	for(ndone := 0; ndone < 2; ) {
		n := sys->read(ev, buf, len buf);
		if(n <= 0)
			t.fatal("event: eof");
		e := chomp(string buf[0:n]);
		if(prefix(e, "done") || prefix(e, "error")) {
			got = e :: got;
			ndone++;
		}
	}
	t.assertseq(hd tl got, "done " + DIR + "refresh.html", "the refreshing page loads first");
	t.assertseq(hd got, "done " + DIR + "b.html", "then the refresh target");
	t.assertseq(rd("title"), "Page B\n", "B is showing");
}

testPosted(t: ref T)
{
	t.assertseq(postname, "fs", "posted as fs");
	c := chan of string;
	spawn otherns(c);
	t.assertseq(<-c, "Page B\n", "title through the posted file");
}

otherns(c: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	sys->unmount(nil, MNT);
	fd := sys->open("#scharontest/" + postname, Sys->ORDWR);
	if(fd == nil) {
		c <-= sys->sprint("open: %r");
		return;
	}
	if(sys->mount(fd, nil, MNT, Sys->MREPL, nil) < 0) {
		c <-= sys->sprint("mount: %r");
		return;
	}
	c <-= rd("title");
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

	sys->pctl(Sys->FORKNS, nil);
	disp := Display.allocate(nil);
	browser = load Browser Browser->PATH;
	charonfs = load Charonfs Charonfs->PATH;
	if(browser == nil || charonfs == nil) {
		sys->fprint(sys->fildes(2), "cannot load: %r\n");
		raise "fail:load";
	}
	if((err := browser->init(disp)) != nil || (err = charonfs->init()) != nil) {
		sys->fprint(sys->fildes(2), "init: %s\n", err);
		raise "fail:init";
	}
	s := Session.new(800, 600);
	if((err = charonfs->serve(browser, s, disp, MNT)) != nil) {
		sys->fprint(sys->fildes(2), "serve: %s\n", err);
		raise "fail:serve";
	}

	(posted, perr) := charonfs->post("charontest");
	if(perr != nil)
		sys->fprint(sys->fildes(2), "post: %s\n", perr);
	postname = posted;

	run("Open", testOpen);
	run("Links", testLinks);
	run("History", testHistory);
	run("Fragment", testFragment);
	run("Find", testFind);
	run("Image", testImage);
	run("Forms", testForms);
	run("Refresh", testRefresh);
	run("Posted", testPosted);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
