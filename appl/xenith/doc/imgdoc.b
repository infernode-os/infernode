implement Docengine;

#
# imgdoc - images for Xenith's document view (docengine(2)).
#
# One sheet, the image, decoded by imgload(2), loaded with the first
# image. Painted at scale 100; the view scales it.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "bufio.m";
include "imagefile.m";
include "imgload.m";
	imgload: Imgload;

include "docengine.m";

State: adt {
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

open(data: array of byte, name: string, nil: ref Style): (int, string)
{
	if(imgload == nil){
		l := load Imgload Imgload->PATH;
		if(l == nil)
			return (-1, sys->sprint("cannot load %s: %r", Imgload->PATH));
		l->init(display);
		imgload = l;
	}
	im: ref Image;
	err: string;
	{
		if(data != nil)
			(im, err) = imgload->readimagedata(data, name);
		else
			(im, err) = imgload->readimage(name);
	} exception e {
	"*" =>
		return (-1, "image: " + e);
	}
	if(im == nil){
		if(err == nil)
			err = "cannot decode";
		return (-1, err);
	}
	return (add(ref State(im)), nil);
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
	if(s == nil || n != 0)
		return Point(0, 0);
	return Point(s.im.r.dx(), s.im.r.dy());
}

restyle(nil: int, nil: ref Style): string
{
	return nil;
}

scalable(nil: int): int
{
	return 0;
}

paint(h: int, n: int, nil: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n != 0)
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
