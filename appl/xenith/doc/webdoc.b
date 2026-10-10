implement Docengine;

#
# webdoc - HTML files for Xenith's document view (docengine(2)).
#
# One flowing sheet: the page laid out by Charon's engine through
# htmldoc (style sheets, images and links found from the file's
# directory, the page's own colours), to the style's width; the part
# in view painted as it scrolls. htmldoc, and Charon's engine with it,
# is loaded with the first HTML document, and only for HTML.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "htmldoc.m";
	htmldoc: Htmldoc;

include "docengine.m";

State: adt {
	data:	array of byte;
	url:	string;
	width:	int;
	height:	int;
};

display: ref Display;
docs: array of ref State;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
	return nil;
}

loadhtmldoc(): string
{
	if(htmldoc != nil)
		return nil;
	h := load Htmldoc Htmldoc->PATH;
	if(h == nil)
		return sys->sprint("cannot load %s: %r", Htmldoc->PATH);
	if((err := h->init(display)) != nil)
		return err;
	htmldoc = h;
	return nil;
}

open(data: array of byte, name: string, st: ref Style): (int, string)
{
	if((err := loadhtmldoc()) != nil)
		return (-1, err);
	if(data == nil && (data = readfile(name)) == nil)
		return (-1, sys->sprint("cannot read %s: %r", name));
	url := name;
	if(len url > 0 && url[0] == '/')
		url = "file://" + url;
	width := 800;
	if(st != nil && st.width > 0)
		width = st.width;
	s := ref State(data, url, width, 0);
	h := add(s);
	if((err = set(h, s)) != nil){
		docs[h] = nil;
		return (-1, err);
	}
	return (h, nil);
}

set(h: int, s: ref State): string
{
	ht: int;
	err: string;
	{
		(ht, err) = htmldoc->set(h, s.data, s.url, s.width, 600);
	} exception e {
	"*" =>
		return "html: " + e;
	}
	if(err != nil)
		return "html: " + err;
	s.height = ht;
	return nil;
}

close(h: int)
{
	if(get(h) != nil && htmldoc != nil)
		htmldoc->drop(h);
	if(h >= 0 && h < len docs)
		docs[h] = nil;
}

nsheets(h: int): int
{
	if(get(h) == nil)
		return 0;
	return 1;
}

sheetsize(h: int, n: int): Point
{
	s := get(h);
	if(s == nil || n != 0)
		return Point(0, 0);
	return Point(s.width, s.height);
}

restyle(h: int, st: ref Style): string
{
	s := get(h);
	if(s == nil)
		return "no document";
	if(st == nil || st.width <= 0 || st.width == s.width)
		return nil;
	s.width = st.width;
	return set(h, s);
}

scalable(nil: int): int
{
	return 0;
}

# The page from org down, into r of dst
paint(h: int, n: int, nil: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n != 0)
		return "no such sheet";
	im := display.newimage(Rect((0, 0), (r.dx(), r.dy())), dst.chans, 0, Draw->White);
	if(im == nil)
		return sys->sprint("no image: %r");
	htmldoc->paint(h, im, org.y);
	dst.draw(r, im, nil, Point(org.x, 0));
	return nil;
}

text(h: int): string
{
	if(get(h) == nil)
		return nil;
	return htmldoc->text(h);
}

sheettext(h: int, n: int): string
{
	if(n != 0)
		return nil;
	return text(h);
}

runs(nil: int, nil: int): array of Run
{
	return nil;
}

links(nil: int): array of Link
{
	return nil;
}

linkat(h: int, n: int, p: Point): string
{
	if(get(h) == nil || n != 0)
		return nil;
	return htmldoc->linkat(h, p.x, p.y);
}

lineto(nil: int, nil: int): (int, int)
{
	return (0, 0);
}

lineat(nil: int, nil: int, nil: int): int
{
	return 0;
}

commands(nil: int): list of string
{
	return nil;
}

command(nil: int, cmd, nil: string): string
{
	return "unknown command " + cmd;
}

add(s: ref State): int
{
	for(i := 0; i < len docs; i++)
		if(docs[i] == nil){
			docs[i] = s;
			return i;
		}
	n := array[len docs + 4] of ref State;
	n[0:] = docs;
	n[len docs] = s;
	h := len docs;
	docs = n;
	return h;
}

get(h: int): ref State
{
	d := docs;
	if(h < 0 || h >= len d)
		return nil;
	return d[h];
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[0] of byte;
	buf := array[65536] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0){
		n := array[len b + m] of byte;
		n[0:] = b;
		n[len b:] = buf[0:m];
		b = n;
	}
	return b;
}
