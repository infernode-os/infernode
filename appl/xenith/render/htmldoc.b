implement Htmldoc;

#
# htmldoc.b - HTML set by Charon's engine for Xenith (see htmldoc.m).
# Each page is a browser(2) Session, so links, text and painting are
# the browser's own.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point: import draw;
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

include "htmldoc.m";

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Held: adt {
	id:	int;
	s:	ref Session;
	ev:	chan of string;	# a browsed page's events, nil for one set
	fs:	Charonfs;	# a browsed page's files, posted
	path:	string;	# where: #sxenith/<id>
};

display: ref Display;
pages: list of ref Held;
inited := 0;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(inited)
		return nil;
	browser = load Browser Browser->PATH;
	if(browser == nil)
		return sys->sprint("cannot load %s: %r", Browser->PATH);
	if((err := browser->init(d)) != nil)
		return err;
	display = d;
	inited = 1;
	return nil;
}

set(id: int, data: array of byte, url: string, width, height: int): (int, string)
{
	if(!inited)
		return (0, "htmldoc not initialised");
	s := find(id);
	if(s == nil) {
		s = Session.new(width, height);
		pages = ref Held(id, s, nil, nil, nil) :: pages;
	} else if(s.width != width || s.height != height)
		s.resize(width, height);
	if((err := s.show(data, "text/html", url)) != nil)
		return (0, err);
	return (s.pageheight(), nil);
}

paint(id: int, dst: ref Image, y: int)
{
	s := find(id);
	if(s != nil)
		s.paint(dst, Point(0, y));
}

linkat(id: int, x, y: int): string
{
	s := find(id);
	if(s == nil)
		return nil;
	return s.linkat(x, y);
}

text(id: int): string
{
	s := find(id);
	if(s == nil)
		return nil;
	return s.text();
}

drop(id: int)
{
	l: list of ref Held;
	for(; pages != nil; pages = tl pages){
		p := hd pages;
		if(p.id != id)
			l = p :: l;
		else if(p.ev != nil){
			if(p.fs != nil)
				p.fs->unpost();
			# whoever reads the page's events stops
			p.s.unlisten(p.ev);
			p.s.stop();
			alt {
			p.ev <-= "gone" =>	;
			* =>	;
			}
		}
	}
	pages = l;
}

find(id: int): ref Session
{
	for(l := pages; l != nil; l = tl l)
		if((hd l).id == id)
			return (hd l).s;
	return nil;
}

# ---- browsing ----

browse(id: int, url: string, width, height: int): (chan of string, string)
{
	if(!inited)
		return (nil, "htmldoc not initialised");
	if(isweb(url) && (err := startwebfs()) != nil)
		return (nil, err);
	s := find(id);
	c: chan of string;
	if(s == nil) {
		s = Session.new(width, height);
		c = s.listen();
		h := ref Held(id, s, c, nil, nil);
		pages = h :: pages;
		postpage(h);
	} else if(s.width != width || s.height != height)
		s.resize(width, height);
	s.open(url);
	return (c, nil);
}

click(id: int, x, y: int): (int, string)
{
	s := find(id);
	if(s == nil)
		return (0, "no page");
	n := s.nodeat(x, y);
	if(n == 0)
		return (0, nil);
	if(s.linkat(x, y) == nil && !clickable(s, x, y))
		return (0, nil);
	return (1, s.click(n));
}

# A form control under x, y: a click on one acts (the engine's click
# does nothing elsewhere, such as on plain text).
clickable(s: ref Session, x, y: int): int
{
	f := s.fields();
	for(i := 0; i < len f; i++) {
		(ok, r) := s.boxof(f[i].node);
		if(ok && Point(x, y).in(r))
			return 1;
	}
	return 0;
}

back(id: int): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	return s.goback();
}

forward(id: int): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	return s.goforward();
}

reload(id: int): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	s.reload();
	return nil;
}

stop(id: int): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	s.stop();
	return nil;
}

url(id: int): string
{
	s := find(id);
	if(s == nil)
		return nil;
	return s.url;
}

title(id: int): string
{
	s := find(id);
	if(s == nil)
		return nil;
	return s.title;
}

height(id: int): int
{
	s := find(id);
	if(s == nil)
		return 0;
	return s.pageheight();
}

scroll(id: int): int
{
	s := find(id);
	if(s == nil)
		return 0;
	return s.scroll;
}

resize(id: int, width, height: int)
{
	s := find(id);
	if(s != nil && (s.width != width || s.height != height))
		s.resize(width, height);
}

isweb(url: string): int
{
	return (len url >= 7 && url[0:7] == "http://") || (len url >= 8 && url[0:8] == "https://");
}

# webfs at /mnt/web, as Charon starts it: what a page can reach on the
# network is what is mounted there.
startwebfs(): string
{
	if(webfsup())
		return nil;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return sys->sprint("cannot load webfs: %r");
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		if(webfsup())
			return nil;
		sys->sleep(20);
	}
	return "webfs did not start";
}

webfsup(): int
{
	(ok, d) := sys->stat("/mnt/web/clone");
	return ok >= 0 && d.dtype == 'M';
}

# ---- forms ----

fields(id: int): array of ref Field
{
	s := find(id);
	if(s == nil)
		return nil;
	f := s.fields();
	a := array[len f] of ref Field;
	for(i := 0; i < len f; i++) {
		(nil, r) := s.boxof(f[i].node);
		a[i] = ref Field(f[i].node, f[i].form, f[i].kind, f[i].name,
			f[i].value, f[i].checked, f[i].options, r);
	}
	return a;
}

setfield(id: int, node: int, value: string): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	return s.set(node, value);
}

submit(id: int, form: int): string
{
	s := find(id);
	if(s == nil)
		return "no page";
	return s.submit(form, 0);
}

# ---- the page as files ----
#
# A browsed page is served as Charon's is (charonfs: url, title, text,
# links, forms, ctl, dom/, ...), by a charonfs of its own, posted as
# #sxenith/<id> so that a process in another name space (a script, an
# agent granted it) can mount it.  Xenith's window file web names it.

postpage(h: ref Held)
{
	fs := load Charonfs Charonfs->PATH;
	if(fs == nil || fs->init() != nil || fs->serve(browser, h.s, display, nil) != nil)
		return;
	# two Xenith in one emu number their windows alike
	name := string h.id;
	for(i := 1; i < 32 && fs->postas("xenith", name) != nil; i++)
		name = sys->sprint("%d.%d", h.id, i);
	if(i == 32)
		return;
	h.fs = fs;
	h.path = "#sxenith/" + name;
}

posted(id: int): string
{
	for(l := pages; l != nil; l = tl l)
		if((hd l).id == id)
			return (hd l).path;
	return nil;
}
