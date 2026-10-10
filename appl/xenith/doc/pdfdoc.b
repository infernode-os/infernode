implement Docengine;

#
# pdfdoc - PDF documents for Xenith's document view (docengine(2)).
#
# A sheet a page, its size at scale 100 the page's in points, so a
# page is painted at 72 * scale/100 dots to the inch: sharp at any
# zoom. pdf(2), the interpreter, is loaded with the first document;
# each document is its own Doc, so windows page on their own.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "pdf.m";
	pdf: PDF;
	Doc: import pdf;

include "docengine.m";

MAXREAD: con 64*1024*1024;

State: adt {
	doc:	ref Doc;
	sizes:	array of Point;
	text:	string;
	texts:	array of string;
	runs:	array of array of Run;
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

loadpdf(): string
{
	if(pdf != nil)
		return nil;
	p := load PDF PDF->PATH;
	if(p == nil)
		return sys->sprint("cannot load %s: %r", PDF->PATH);
	if((err := p->init(display)) != nil)
		return "pdf: " + err;
	pdf = p;
	return nil;
}

open(data: array of byte, name: string, nil: ref Style): (int, string)
{
	if((err := loadpdf()) != nil)
		return (-1, err);
	if(data == nil && (data = readfile(name)) == nil)
		return (-1, sys->sprint("cannot read %s: %r", name));
	doc: ref Doc;
	{
		(doc, err) = pdf->open(data, nil);
	} exception e {
	"*" =>
		return (-1, "PDF: " + e);
	}
	if(doc == nil)
		return (-1, "PDF: " + err);
	n := doc.pagecount();
	if(n <= 0)
		return (-1, "PDF: no pages");
	sizes := array[n] of Point;
	for(i := 0; i < n; i++){
		(w, h) := doc.pagesize(i+1);
		if(w <= 0.0 || h <= 0.0)
			(w, h) = (612.0, 792.0);
		sizes[i] = Point(int (w + 0.5), int (h + 0.5));
	}
	return (add(ref State(doc, sizes, nil, array[n] of string, array[n] of array of Run)), nil);
}

close(h: int)
{
	if((s := get(h)) != nil)
		s.doc.close();
	if(h >= 0 && h < len docs)
		docs[h] = nil;
}

nsheets(h: int): int
{
	if((s := get(h)) == nil)
		return 0;
	return len s.sizes;
}

sheetsize(h: int, n: int): Point
{
	s := get(h);
	if(s == nil || n < 0 || n >= len s.sizes)
		return Point(0, 0);
	return s.sizes[n];
}

restyle(nil: int, nil: ref Style): string
{
	return nil;
}

scalable(nil: int): int
{
	return 1;
}

paint(h: int, n: int, scale: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n < 0 || n >= len s.sizes)
		return "no such page";
	dpi := (72 * scale + 50) / 100;
	if(dpi < 1)
		dpi = 1;
	im: ref Image;
	err: string;
	{
		(im, err) = s.doc.renderpage(n+1, dpi);
	} exception e {
	"*" =>
		return "render: " + e;
	}
	if(im == nil)
		return "render: " + err;
	dst.draw(r, im, nil, im.r.min.add(org));
	return nil;
}

text(h: int): string
{
	s := get(h);
	if(s == nil)
		return nil;
	if(s.text == nil){
		{
			s.text = s.doc.extractall();
		} exception {
		"*" =>
			s.text = "";
		}
	}
	return s.text;
}

sheettext(h: int, n: int): string
{
	s := get(h);
	if(s == nil || n < 0 || n >= len s.sizes)
		return nil;
	if(s.texts[n] == nil){
		{
			s.texts[n] = s.doc.extracttext(n+1);
		} exception {
		"*" =>
			s.texts[n] = "";
		}
	}
	return s.texts[n];
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
	(ok, dir) := sys->fstat(fd);
	if(ok != 0 || dir.length <= big 0 || dir.length > big MAXREAD)
		return nil;
	n := int dir.length;
	b := array[n] of byte;
	for(t := 0; t < n; ){
		m := sys->read(fd, b[t:], n - t);
		if(m <= 0)
			return nil;
		t += m;
	}
	return b;
}
