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

include "htmldoc.m";

pages: list of (int, ref Session);
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
		pages = (id, s) :: pages;
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
	l: list of (int, ref Session);
	for(; pages != nil; pages = tl pages)
		if((hd pages).t0 != id)
			l = hd pages :: l;
	pages = l;
}

find(id: int): ref Session
{
	for(l := pages; l != nil; l = tl l)
		if((hd l).t0 == id)
			return (hd l).t1;
	return nil;
}
