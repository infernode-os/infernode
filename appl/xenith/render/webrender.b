implement Renderer;

#
# webrender.b - HTML, set by Charon's engine (htmldoc), as an image:
# what Xenith shows for a web page it opens.  The page is laid out
# the body's width and painted whole, up to Maxheight; its text is
# the body's.  Relative references are found from the hint, the URL
# or file the page came from.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "renderer.m";
include "htmldoc.m";
	htmldoc: Htmldoc;

display: ref Display;
serial := 0;	# renders so far: each is its own page in htmldoc
Maxheight: con 16384;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
}

info(): ref RenderInfo
{
	return ref RenderInfo("HTML (Charon)", ".html .htm .xhtml", 1);
}

canrender(data: array of byte, nil: string): int
{
	if(data == nil || len data < 6)
		return 0;
	s := lower(string data[0:min(len data, 256)]);
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r')
			continue;
		if(c != '<')
			break;
		rest := s[i:];
		if(prefix(rest, "<!doctype html"))
			return 95;
		if(prefix(rest, "<html"))
			return 90;
		if(prefix(rest, "<head") || prefix(rest, "<body"))
			return 85;
		return 35;	# any tag suggests HTML
	}
	return 0;
}

render(data: array of byte, hint: string, width, height: int,
       progress: chan of ref RenderProgress): (ref Image, string, string)
{
	if(display == nil)
		return (nil, nil, "no display");
	if(data == nil || len data == 0)
		return (nil, nil, "no data");
	if(htmldoc == nil){
		htmldoc = load Htmldoc Htmldoc->PATH;
		if(htmldoc == nil)
			return (nil, nil, sys->sprint("cannot load %s: %r", Htmldoc->PATH));
		if((err := htmldoc->init(display)) != nil){
			htmldoc = nil;
			return (nil, nil, err);
		}
	}
	if(width <= 0)
		width = 800;
	if(height <= 0)
		height = display.image.r.dy();

	serial++;
	id := -serial;	# windows' pages have ids from 1
	url := hint;
	if(url != nil && url[0] == '/')
		url = "file://" + url;
	(h, err) := htmldoc->set(id, data, url, width, height);
	if(err != nil){
		htmldoc->drop(id);
		return (nil, nil, err);
	}
	if(h < 1)
		h = 1;
	if(h > Maxheight)
		h = Maxheight;
	im := display.newimage(Rect((0, 0), (width, h)), display.image.chans, 0, Draw->White);
	if(im != nil)
		htmldoc->paint(id, im, 0);
	text := htmldoc->text(id);
	htmldoc->drop(id);
	if(im == nil)
		return (nil, text, sys->sprint("no image: %r"));
	return (im, text, nil);
}

commands(): list of ref Command
{
	return nil;
}

command(cmd: string, nil: string, nil: array of byte, nil: string, nil, nil: int): (ref Image, string)
{
	return (nil, "unknown command: " + cmd);
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}
