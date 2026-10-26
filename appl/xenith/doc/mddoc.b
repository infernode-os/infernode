implement Docengine;

#
# mddoc - Markdown for Xenith's document view (docengine(2)).
#
# The text set by rlayout(2), the common typesetter (Go and its bold,
# italic and medium, headings larger, tables ruled, Mermaid diagrams
# drawn), to the style's width: one flowing sheet. Charon is not
# loaded. Each block's first line in the text and its top in the
# document are kept, so the window keeps its place between the two.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "rlayout.m";
	rlayout: Rlayout;

include "docengine.m";

PROPFONT: con "/fonts/combined/go.14.font";
MONOFONT: con "/fonts/combined/gomono.14.font";

# A document is laid out, not drawn: each strip the view asks for is
# drawn when it is painted.  An image of the whole of a long one, at
# twice the scale on a Retina display, is tens of thousands of pixels
# tall; image memory is soon too fragmented for one of those, and set
# again as it is edited, there are two.
State: adt {
	src:	string;
	style:	ref Style;
	doc:	list of ref Rlayout->DocNode;
	rs:	ref Rlayout->Style;
	size:	Point;	# the document's, laid out
	laid:	ref Rlayout->Laid;
	text:	string;
	lines:	array of int;	# each block's first line in the text
	ys:	array of int;	# and its top in the document
	words:	array of Rlayout->Word;	# the words drawn, where
};

display: ref Display;
docs: array of ref State;
# a document's opener runs on a proc of its own (sheetview), beside
# another's and the closes Xenith makes: two at once took one slot,
# one document lost and two windows sharing the other
docslock: chan of int;
propfont, monofont: ref Font;

init(d: ref Display): string
{
	if(docslock == nil)
		docslock = chan[1] of int;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
	return nil;
}

loadlayout(): string
{
	if(rlayout != nil)
		return nil;
	r := load Rlayout Rlayout->PATH;
	if(r == nil)
		return sys->sprint("cannot load %s: %r", Rlayout->PATH);
	r->init(display);
	rlayout = r;
	return nil;
}

open(data: array of byte, name: string, st: ref Style): (int, string)
{
	if((err := loadlayout()) != nil)
		return (-1, err);
	if(data == nil && (data = readfile(name)) == nil)
		return (-1, sys->sprint("cannot read %s: %r", name));
	s := ref State(string data, st, nil, nil, Point(0, 0), nil, nil, nil, nil, nil);
	if((err = set(s)) != nil)
		return (-1, err);
	return (add(s), nil);
}

# Set the text again in the state's style
set(s: ref State): string
{
	st := s.style;
	if(st == nil)
		st = ref Style(800, nil, nil, nil, nil, nil, nil, 0);
	if(st.font == nil){
		if(propfont == nil && (propfont = Font.open(display, PROPFONT)) == nil)
			propfont = Font.open(display, "*default*");
		st.font = propfont;
	}
	if(st.codefont == nil){
		if(monofont == nil && (monofont = Font.open(display, MONOFONT)) == nil)
			monofont = st.font;
		st.codefont = monofont;
	}
	if(st.fg == nil)
		st.fg = display.black;
	if(st.bg == nil)
		st.bg = display.white;
	if(st.accent == nil)
		st.accent = st.fg;
	if(st.codebg == nil)
		st.codebg = st.bg;
	width := st.width;
	if(width <= 0)
		width = 800;
	rs := ref Rlayout->Style(width, 4, st.font, st.codefont,
		st.fg, st.bg, st.accent, st.codebg, 150);
	{
		(doc, lines) := rlayout->parsemdlines(s.src);
		laid := rlayout->measure(doc, rs);
		if(laid == nil)
			return "render failed: no font";
		s.doc = doc;
		s.rs = rs;
		s.laid = laid;
		s.size = Point(width, laid.height);
		s.lines = lines;
		s.ys = laid.ys;
		s.words = laid.words;
		s.text = rlayout->totext(doc);
	} exception e {
	"*" =>
		return "render failed: " + e;
	}
	s.style = st;
	return nil;
}

close(h: int)
{
	docslock <-= 1;
	if(h >= 0 && h < len docs)
		docs[h] = nil;
	<-docslock;
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
	if(s == nil || n != 0 || s.laid == nil)
		return Point(0, 0);
	return s.size;
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

pinned(nil: int): int
{
	return 0;
}

paint(h: int, n: int, nil: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n != 0 || s.laid == nil)
		return "no such sheet";
	# the strip at org, the size of r, drawn where it is in the document
	strip := Rect(org, org.add(r.size()));
	im := display.newimage(strip, Draw->RGB24, 0, Draw->Nofill);
	if(im == nil)
		return sys->sprint("no image memory for a strip %d by %d", strip.dx(), strip.dy());
	rlayout->drawband(s.doc, s.rs, im, s.laid);
	dst.draw(r, im, nil, org);
	return nil;
}

text(h: int): string
{
	if((s := get(h)) == nil)
		return nil;
	return s.text;
}

sheettext(h: int, n: int): string
{
	if(n != 0)
		return nil;
	return text(h);
}

runs(h: int, n: int): array of Run
{
	s := get(h);
	if(s == nil || n != 0)
		return nil;
	r := array[len s.words] of Run;
	for(i := 0; i < len r; i++)
		r[i] = Run(s.words[i].text, s.words[i].r);
	return r;
}

links(h: int): array of Link
{
	s := get(h);
	if(s == nil)
		return nil;
	l: list of ref Link;
	for(i := 0; i < len s.words; i++)
		if((u := s.words[i].link) != nil)
			l = ref Link(0, s.words[i].r, u) :: l;
	a := array[len l] of Link;
	for(i = len a; l != nil; l = tl l)
		a[--i] = *hd l;
	return a;
}

# Where line l of the text falls in the document: in the block that
# holds it, as far down as the line is through the block's lines
linkat(h: int, n: int, p: Point): string
{
	s := get(h);
	if(s == nil || n != 0)
		return nil;
	for(i := 0; i < len s.words; i++){
		w := s.words[i];
		if(w.link != nil && p.in(w.r))
			return w.link;
	}
	return nil;
}

lineto(h: int, n: int): (int, int)
{
	s := get(h);
	if(s == nil)
		return (0, 0);
	(l, y) := (s.lines, s.ys);
	if(l == nil || len l == 0 || len y < len l)
		return (0, 0);
	k := 0;
	while(k+1 < len l && l[k+1] <= n)
		k++;
	if(n < l[k])
		return (0, 0);
	if(k+1 < len l && l[k+1] > l[k])
		return (0, y[k] + (n - l[k]) * (y[k+1] - y[k]) / (l[k+1] - l[k]));
	return (0, y[k]);
}

# The line of the text at height y of the document: the inverse
lineat(h: int, nil: int, y: int): int
{
	s := get(h);
	if(s == nil)
		return 0;
	(l, ys) := (s.lines, s.ys);
	if(l == nil || len l == 0 || len ys < len l)
		return 0;
	k := 0;
	while(k+1 < len l && ys[k+1] <= y)
		k++;
	if(y < ys[k])
		return l[k];
	if(k+1 < len l && ys[k+1] > ys[k])
		return l[k] + (y - ys[k]) * (l[k+1] - l[k]) / (ys[k+1] - ys[k]);
	return l[k];
}

viewing(nil: int, nil: int, nil: int)
{
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
	docslock <-= 1;
	h := add0(s);
	<-docslock;
	return h;
}

add0(s: ref State): int
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
