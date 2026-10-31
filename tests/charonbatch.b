implement CharonBatch;

#
# charonbatch - render many pages in one emu, for conformance runs.
#
#	charonbatch width height list
#
# list has a line "url outimg" per page, or "url outimg -d" to print
# the page's box tree on stderr too (to compare a page laid out after
# others with the same page alone).  Each page is laid out for a
# width x height viewport and that viewport is written to outimg as an
# image(6).  One line goes to stdout per page, "ok outimg <ms>" or
# "fail outimg <reason>", so a driver can resume after a crash or a
# hang (tools/wpt-reftest.py does).  Halts emu when done.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "web/dom.m";
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
	layout: Layout;
include "web/page.m";
	page: Page;
	Pg: import page;

CharonBatch: module
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
	bufio = load Bufio Bufio->PATH;
	stdout := sys->fildes(1);
	if(len args != 4) {
		sys->fprint(sys->fildes(2), "usage: charonbatch width height list\n");
		halt();
		return;
	}
	w := int hd tl args;
	h := int hd tl tl args;
	lfile := hd tl tl tl args;
	disp := Display.allocate(nil);
	page = load Page Page->PATH;
	err := "no display or page module";
	if(disp != nil && page != nil)
		err = page->init(disp);
	if(err != nil) {
		sys->fprint(sys->fildes(2), "charonbatch: cannot start: %s\n", err);
		halt();
		return;
	}
	startwebfs();
	f := bufio->open(lfile, Bufio->OREAD);
	if(f == nil) {
		sys->fprint(sys->fildes(2), "charonbatch: %s: %r\n", lfile);
		halt();
		return;
	}
	img := disp.newimage(Rect((0, 0), (w, h)), Draw->XRGB32, 0, Draw->White);
	while((l := f.gets('\n')) != nil) {
		(n, fl) := sys->tokenize(l, " \t\n");
		if(n != 2 && !(n == 3 && hd tl tl fl == "-d"))
			continue;
		url := hd fl;
		out := hd tl fl;
		t0 := sys->millisec();
		e := render(disp, img, url, out, w, h, n == 3);
		if(e != nil)
			sys->fprint(stdout, "fail %s %s\n", out, e);
		else
			sys->fprint(stdout, "ok %s %d\n", out, sys->millisec() - t0);
	}
	halt();
}

render(disp: ref Display, img: ref Draw->Image, url, out: string, w, h, dump: int): string
{
	{
		(p, err) := page->open(url, w, h);
		if(p == nil)
			return err;
		img.draw(img.r, disp.white, nil, (0, 0));
		p.paint(img, Point(0, fragscroll(p, url)));
		if(dump) {
			if(layout == nil) {
				layout = load Layout Layout->PATH;
				layout->init(disp);
			}
			sys->fprint(sys->fildes(2), "%s", layout->dump(p.root));
		}
		fd := sys->create(out, Sys->OWRITE, 8r644);
		if(fd == nil)
			return sys->sprint("create: %r");
		# uncompressed: the host side reads thousands of these
		hdr := sys->sprint("%11s %11d %11d %11d %11d ", "x8r8g8b8", img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
		buf := array[img.r.dx() * img.r.dy() * 4] of byte;
		if(img.readpixels(img.r, buf) < 0)
			return sys->sprint("readpixels: %r");
		if(sys->write(fd, array of byte hdr, len hdr) != len hdr || sys->write(fd, buf, len buf) != len buf)
			return sys->sprint("write: %r");
		return nil;
	} exception e {
	"*" =>
		return "exception: " + e;
	}
}

startwebfs()
{
	if(webfsup())
		return;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return;
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		if(webfsup())
			return;
		sys->sleep(20);
	}
}

halt()
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}

# a webfs is mounted there, not merely a file by that name
webfsup(): int
{
	(ok, d) := sys->stat("/mnt/web/clone");
	return ok >= 0 && d.dtype == 'M';
}

# a URL's #fragment scrolls to its target, as in the window
fragscroll(p: ref Pg, url: string): int
{
	for(i := 0; i < len url; i++)
		if(url[i] == '#')
			return p.target(url[i+1:]);
	return 0;
}
