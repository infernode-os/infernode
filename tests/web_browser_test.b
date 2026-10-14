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

# As nav, but the answer is the one about url: events about any other
# page (a reload superseded by this load, say) are passed over.
navto(t: ref T, cmd, url: string): string
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
		e := chomp(string buf[0:n]);
		if(e == "done " + url || e == "error " + url)
			return e;
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

# A link in a paragraph is an inline box: its box is where its words
# are, not nothing at the paragraph's corner
testInlineBox(t: ref T)
{
	a := byattr("href b.html");
	t.assert(a != 0, "found the link");
	b := chomp(rd(sys->sprint("dom/%d/box", a)));
	t.log("box: " + b);
	(n, f) := sys->tokenize(b, " ");
	t.asserteq(n, 5, "one piece, on one line");
	if(n == 5) {
		t.assertseq(hd f, "inline", "inline box");
		t.assert(int hd tl f > 8 + 40, "x: after the paragraph's first words: " + b);
		t.assert(int hd tl tl tl f > 30, "width of its words: " + b);
		t.assert(int hd tl tl tl tl f > 10, "a line's height: " + b);
	}
}

# the node whose attrs include this line
byattr(line: string): int
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
				if(hd l == line)
					return int d[i].name;
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

# the draw device's display; nil with none (a headless emu)
disp: ref Display;
sess: ref Session;

# Scrolling through ctl is the window's scrolling too: its view
# follows the event
testScroll(t: ref T)
{
	ev := sys->open(MNT + "/event", Sys->OREAD);
	if(ev == nil)
		t.fatal(sys->sprint("open event: %r"));
	if((err := wr("ctl", "scroll 120")) != nil)
		t.fatal("ctl: " + err);
	buf := array[256] of byte;
	n := sys->read(ev, buf, len buf);
	t.assertseq(chomp(string buf[0:n]), "scroll 120", "the event a window scrolls by");
	wr("ctl", "scroll 0");
}

# Back and Fwd come back to where the view was on the page (as the
# window said, viewing), not to its top
testBackPlace(t: ref T)
{
	t.assertseq(nav(t, "open " + DIR + "a.html"), "done " + DIR + "a.html", "open A");
	sess.viewing(137);
	t.assertseq(nav(t, "follow 1"), "done " + DIR + "b.html", "follow to B");
	t.asserteq(sess.scroll, 0, "a new page from its top");
	sess.viewing(55);
	t.assertseq(nav(t, "back"), "done " + DIR + "a.html", "back to A");
	t.asserteq(sess.scroll, 137, "A where it was left");
	t.assertseq(nav(t, "forward"), "done " + DIR + "b.html", "forward to B");
	t.asserteq(sess.scroll, 55, "B where it was left");
	t.assertseq(nav(t, "back"), "done " + DIR + "a.html", "back to A again");
	t.asserteq(sess.scroll, 137, "A where it was left, again");
	sess.viewing(0);
}

testImage(t: ref T)
{
	if(disp == nil)
		t.skip("no display: nothing is rendered");
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

# A page that cannot be fetched shows a page saying so, not a blank
# one; the session keeps its URL to reload, and back leaves it.
testUnreachable(t: ref T)
{
	before := chomp(rd("url"));
	bad := DIR + "no-such-page.html";
	e := nav(t, "open " + bad);
	t.assert(prefix(e, "error "), "an error event: " + e);
	t.assertseq(rd("url"), bad + "\n", "the URL that failed");
	t.assertseq(rd("title"), "Cannot load page\n", "the error page is showing");
	text := rd("text");
	t.log(text);
	t.assert(contains(text, "Cannot load this page"), "it says so: " + text);
	t.assert(contains(text, "no-such-page.html"), "and names the page");
	t.assertseq(nav(t, "back"), "done " + before, "back to the page before");
}

# What the page's scripts write to the console is the page's console
# file, not the terminal; what it could not fetch, its errors file.
# With scripts on, noscript is not shown.
testConsole(t: ref T)
{
	# Turning scripts on reloads the page showing (Session.configure),
	# whose done can come after the next load's event file is open.
	if((err := wr("ctl", "scripts on")) != nil)
		t.fatal("scripts on: " + err);
	e := navto(t, "open " + DIR + "console.html", DIR + "console.html");
	t.assertseq(e, "done " + DIR + "console.html", "loaded");
	cl := "";
	for(i := 0; i < 50; i++) {
		cl = rd("console");
		if(contains(cl, "hello"))
			break;
		sys->sleep(100);
	}
	t.assertseq(cl, "hello from the page\n", "console");
	errs := rd("errors");
	t.assert(contains(errs, "no-such-sheet.css: "), "errors: " + errs);
	text := rd("text");
	t.assert(!contains(text, "without scripts"), "noscript not shown: " + text);
	t.assert(!contains(rd("links"), "b.html"), "nor its link");
	e = nav(t, "scripts off");	# reloads the page, without its scripts
	t.assertseq(e, "done " + DIR + "console.html", "reloaded");
	t.assert(contains(rd("text"), "without scripts"), "scripts off: noscript shown");
	t.assertseq(rd("console"), "", "and nothing written to the console");
}

# A page left while its script runs: the realm is killed holding the
# session's lock, and the next page loads all the same
testLeaveBusy(t: ref T)
{
	scripts(t, "on");
	navto(t, "open " + DIR + "busy.html", DIR + "busy.html");
	sys->sleep(1500);	# its script is running, the lock held
	c := chan of string;
	spawn navasync(c, "open " + DIR + "b.html", DIR + "b.html");
	tick := chan of int;
	spawn ticker(tick, 20000);
	alt {
	e := <-c =>
		t.assertseq(e, "done " + DIR + "b.html", "the next page loads");
		scripts(t, "off");
	<-tick =>
		t.fatal("the next page did not load in 20 s: the session's lock was never had again");
	}
}

# navto, its answer sent on c, so a test can wait for it with a limit
navasync(c: chan of string, cmd, url: string)
{
	ev := sys->open(MNT + "/event", Sys->OREAD);
	if(ev == nil || wr("ctl", cmd) != nil) {
		c <-= "cannot";
		return;
	}
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(ev, buf, len buf);
		if(n <= 0) {
			c <-= "event: eof";
			return;
		}
		e := chomp(string buf[0:n]);
		if(e == "done " + url || e == "error " + url) {
			c <-= e;
			return;
		}
	}
}

# scripts on or off: the page showing is loaded again with them or
# without, and that is waited for (its done must not answer the next)
scripts(t: ref T, v: string)
{
	u := chomp(rd("url"));
	e := navto(t, "scripts " + v, u);
	if(e != "done " + u)
		t.fatal("scripts " + v + ": " + e);
}

ticker(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

# A page left as soon as it is shown, while its script engine is still
# loading: the realm is killed, and only the realm (it killed every
# other process of the browser's, these files' server among them)
testLeaveEarly(t: ref T)
{
	scripts(t, "on");
	for(i := 0; i < 3; i++) {
		wr("ctl", "open " + DIR + "busy.html");
		for(j := 0; j < 200; j++) {
			st := rd("status");
			if(!prefix(st, "loading " + DIR) || prefix(st, "loading images"))
				break;
			sys->sleep(5);
		}
		c := chan of string;
		spawn navasync(c, "open " + DIR + "b.html", DIR + "b.html");
		tick := chan of int;
		spawn ticker(tick, 20000);
		alt {
		e := <-c =>
			t.assertseq(e, "done " + DIR + "b.html", sys->sprint("left early, %d: the next page loads", i));
		<-tick =>
			t.fatal(sys->sprint("left early, %d: the next page did not load in 20 s", i));
		}
	}
	t.assertseq(rd("title"), "Page B\n", "the files still answer");
	scripts(t, "off");
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
	disp = Display.allocate(nil);
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
	s := sess = Session.new(800, 600);
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
	run("InlineBox", testInlineBox);
	run("History", testHistory);
	run("Fragment", testFragment);
	run("Find", testFind);
	run("Scroll", testScroll);
	run("BackPlace", testBackPlace);
	run("Image", testImage);
	run("Forms", testForms);
	run("Refresh", testRefresh);
	run("Unreachable", testUnreachable);
	run("LeaveBusy", testLeaveBusy);
	run("LeaveEarly", testLeaveEarly);
	run("Posted", testPosted);
	run("Console", testConsole);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
