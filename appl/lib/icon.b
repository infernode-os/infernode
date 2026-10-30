implement Icon;

#
# icon - the interface's glyphs (icon(2)): /icons/ui/NAME.svg drawn by
# readsvg at the size asked for, its coverage kept as a GREY8 mask and
# painted in the caller's colour.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;

include "tk.m";
	tk: Tk;

include "bufio.m";
	bufio: Bufio;

include "imagefile.m";
	readsvg: RImagefile;

include "icon.m";

display: ref Display;

# the masks drawn, by name and size
Drawn: adt {
	name:	string;
	size:	int;
	mask:	ref Image;
};
drawn: list of ref Drawn;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	if(d == nil)
		return "icon: no display";
	display = d;
	return nil;
}

mask(name: string, size: int): (ref Image, string)
{
	if(display == nil)
		return (nil, "icon: not initialised");
	if(size <= 0 || size > 1024)
		return (nil, sys->sprint("icon: bad size %d", size));
	for(l := drawn; l != nil; l = tl l)
		if((hd l).name == name && (hd l).size == size)
			return ((hd l).mask, nil);
	if(name == nil || badname(name))
		return (nil, "icon: bad name " + name);

	svg := readfile(DIR + "/" + name + ".svg");
	if(svg == nil)
		return (nil, sys->sprint("icon: %s: %r", name));
	svg = sized(svg, size);
	if(readsvg == nil){
		readsvg = load RImagefile RImagefile->READSVGPATH;
		if(readsvg == nil)
			return (nil, sys->sprint("icon: cannot load %s: %r", RImagefile->READSVGPATH));
		readsvg->init(bufio);
	}
	(raw, err) := readsvg->read(bufio->sopen(svg));
	if(raw == nil)
		return (nil, "icon: " + name + ": " + err);
	if(raw.nchans != 4 || raw.r.dx() != size || raw.r.dy() != size)
		return (nil, sys->sprint("icon: %s: drawn as %dx%d, not %dx%d", name, raw.r.dx(), raw.r.dy(), size, size));

	m := display.newimage(Rect((0, 0), (size, size)), Draw->GREY8, 0, Draw->Black);
	if(m == nil)
		return (nil, sys->sprint("icon: %s: cannot make a %dx%d mask: %r", name, size, size));
	m.writepixels(m.r, raw.chans[3]);	# the alpha: one byte a pixel, by rows, as GREY8
	drawn = ref Drawn(name, size, m) :: drawn;
	return (m, nil);
}

paint(name: string, size, colour: int): (ref Image, ref Image, string)
{
	(m, err) := mask(name, size);
	if(m == nil)
		return (nil, nil, err);
	i := display.newimage(m.r, Draw->RGBA32, 0, colour);
	if(i == nil)
		return (nil, nil, sys->sprint("icon: %s: cannot make a %dx%d image: %r", name, size, size));
	return (i, m, nil);
}

tkimage(t: ref Tk->Toplevel, tkname, name: string, size, colour: int): string
{
	if(tk == nil)
		tk = load Tk Tk->PATH;
	(i, m, err) := paint(name, size, colour);
	if(i == nil)
		return err;
	ty := tk->cmd(t, "image type " + tkname);
	if(ty == nil || ty[0] == '!'){
		e := tk->cmd(t, "image create bitmap " + tkname);
		if(e != nil && e[0] == '!')
			return "icon: " + e;
	}
	e := tk->putimage(t, tkname, i, m);
	if(e != nil && e[0] == '!')
		return "icon: " + e;
	return nil;
}

# A name is a file in DIR, not a path out of it.
badname(name: string): int
{
	for(i := 0; i < len name; i++)
		if(name[i] == '/')
			return 1;
	return name == "." || name == "..";
}

#
# The SVG with its root's width and height made size: Tabler's glyphs
# are 24 by 24 with a viewBox of 0 0 24 24, which readsvg scales to the
# width and height it is given.  Only the root's own attributes change
# (not stroke-width, nor an element's width).
#
sized(svg: string, size: int): string
{
	start := find(svg, "<svg", 0);
	if(start < 0)
		return svg;
	end := find(svg, ">", start);
	if(end < 0)
		return svg;
	root := svg[start:end];
	root = setattr(root, "width", string size);
	root = setattr(root, "height", string size);
	return svg[0:start] + root + svg[end:];
}

# attribute attr of tag set to v: replaced where it is, added if absent
setattr(tag, attr, v: string): string
{
	pat := attr + "=\"";
	for(i := find(tag, pat, 0); i >= 0; i = find(tag, pat, i + 1)){
		if(i == 0 || !isspace(tag[i-1]))
			continue;	# stroke-width, not width
		vs := i + len pat;
		ve := find(tag, "\"", vs);
		if(ve < 0)
			break;
		return tag[0:vs] + v + tag[ve:];
	}
	return tag + " " + attr + "=\"" + v + "\"";
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

find(s, pat: string, from: int): int
{
	for(i := from; i + len pat <= len s; i++)
		if(s[i:i+len pat] == pat)
			return i;
	return -1;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	if(n < 0)
		return nil;
	return s;
}
