implement Jspage;

#
# jspage - a page loaded in a browsing session with its scripts on,
# and its text printed once they have run.
#
#	jspage [-w ms] [-d] [-c node] url
#
# -w: how long to let the page's scripts run after it is shown (1000 ms);
# -c: click node first; -d: print the document tree, not its text.
# Console output goes to standard error.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
include "web/page.m";
include "web/browser.m";
	browser: Browser;
	Session: import browser;

Jspage: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr := sys->fildes(2);
	wait := 1000;
	dump := 0;
	click := 0;
	for(args = tl args; args != nil && len hd args > 1 && (hd args)[0] == '-'; args = tl args)
		case hd args {
		"-w" =>
			args = tl args;
			wait = int hd args;
		"-d" =>
			dump = 1;
		"-c" =>
			args = tl args;
			click = int hd args;
		* =>
			sys->fprint(stderr, "usage: jspage [-w ms] [-d] [-c node] url\n");
			raise "fail:usage";
		}
	if(args == nil) {
		sys->fprint(stderr, "usage: jspage [-w ms] [-d] [-c node] url\n");
		raise "fail:usage";
	}
	url := hd args;
	disp := Display.allocate(nil);
	browser = load Browser Browser->PATH;
	dom = load Dom Dom->PATH;
	if(disp == nil || browser == nil) {
		sys->fprint(stderr, "jspage: no display or browser: %r\n");
		raise "fail:init";
	}
	if((err := browser->init(disp)) != nil) {
		sys->fprint(stderr, "jspage: %s\n", err);
		raise "fail:init";
	}
	startwebfs();
	s := Session.new(1024, 768);
	s.configure("scripts on");
	ev := s.listen();
	s.open(url);
	for(;;) {
		e := <-ev;
		if(len e >= 4 && e[0:4] == "done" || len e >= 5 && e[0:5] == "error") {
			if(e[0] == 'e')
				sys->fprint(stderr, "jspage: %s\n", e);
			break;
		}
	}
	sys->sleep(wait);
	if(click) {
		if((err := s.click(click)) != nil)
			sys->fprint(stderr, "jspage: click: %s\n", err);
		sys->sleep(wait);
	}
	if(dump)
		sys->print("%s", s.pg.doc.dump());
	else
		sys->print("%s\n", s.text());
	sys->print("title: %s\n", s.pg.title);
	s.stop();
	s.open("about:blank");
	sys->sleep(100);
	halt();
}

startwebfs()
{
	(ok, nil) := sys->stat(Page->WEBFS + "/clone");
	if(ok >= 0)
		return;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return;
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		(ok, nil) = sys->stat(Page->WEBFS + "/clone");
		if(ok >= 0)
			return;
		sys->sleep(20);
	}
}

halt()
{
	fd := sys->open("#c/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}
