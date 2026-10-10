implement Docengine;

#
# mmddoc - Mermaid diagrams for Xenith's document view (docengine(2)).
#
# One sheet, the diagram, drawn by mermaid(2) (loaded with the first
# diagram) to the style's width in the window's colours. Painted at
# scale 100; the view scales it.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "mermaid.m";
	mermaid: Mermaid;

include "docengine.m";

PROPFONT: con "/fonts/combined/go.14.font";
MONOFONT: con "/fonts/combined/gomono.14.font";

State: adt {
	src:	string;
	style:	ref Style;
	im:	ref Image;
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

loadmermaid(): string
{
	if(mermaid != nil)
		return nil;
	prop := Font.open(display, PROPFONT);
	if(prop == nil)
		prop = Font.open(display, "*default*");
	mono := Font.open(display, MONOFONT);
	if(mono == nil)
		mono = prop;
	m := load Mermaid Mermaid->PATH;
	if(m == nil)
		return sys->sprint("cannot load %s: %r", Mermaid->PATH);
	m->init(display, prop, mono);
	mermaid = m;
	return nil;
}

open(data: array of byte, name: string, st: ref Style): (int, string)
{
	if((err := loadmermaid()) != nil)
		return (-1, err);
	if(data == nil && (data = readfile(name)) == nil)
		return (-1, sys->sprint("cannot read %s: %r", name));
	s := ref State(string data, st, nil);
	if((err = set(s)) != nil)
		return (-1, err);
	return (add(s), nil);
}

set(s: ref State): string
{
	width := 800;
	if(s.style != nil){
		if(s.style.width > 0)
			width = s.style.width;
		mermaid->colours(s.style.bg, nil, s.style.fg, s.style.fg);
	}
	im: ref Image;
	err: string;
	{
		(im, err) = mermaid->render(s.src, width);
	} exception e {
	"*" =>
		return "mermaid: " + e;
	}
	if(im == nil)
		return "mermaid: " + err;
	s.im = im;
	return nil;
}

close(h: int)
{
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
	if(s == nil || n != 0 || s.im == nil)
		return Point(0, 0);
	return Point(s.im.r.dx(), s.im.r.dy());
}

restyle(h: int, st: ref Style): string
{
	s := get(h);
	if(s == nil)
		return "no document";
	s.style = st;
	return set(s);
}

scalable(nil: int): int
{
	return 0;
}

paint(h: int, n: int, nil: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n != 0 || s.im == nil)
		return "no such sheet";
	dst.draw(r, s.im, nil, s.im.r.min.add(org));
	return nil;
}

text(nil: int): string
{
	return nil;
}

sheettext(nil: int, nil: int): string
{
	return nil;
}

runs(nil: int, nil: int): array of Run
{
	return nil;
}

links(nil: int): array of Link
{
	return nil;
}

linkat(nil: int, nil: int, nil: Point): string
{
	return nil;
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

events(nil: int): chan of string
{
	return nil;
}

name(nil: int): string
{
	return nil;
}

click(nil: int, nil: int, nil: Point): string
{
	return nil;
}

key(nil: int, nil: int): string
{
	return nil;
}

files(nil: int): string
{
	return nil;
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
