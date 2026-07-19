implement CompList;

#
# comp-list — the composition picker AS a composition module.
#
# Lists every composition under the mount (normally
# /lib/matrix/compositions); a click writes "load <name>" to
# /mnt/matrix/ctl — the same verb sh and agents use.  The default
# empty-state picker is just the `picker` crystallisation wiring this
# module, so users and agents can customise or replace the picker like
# any other composition.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "readdir.m";
	readdir: Readdir;

include "lucitheme.m";

include "matrix.m";

CompList: module
{
	init:	fn(display: ref Display, font: ref Font, mount: string): string;
	resize:	fn(r: Rect);
	update:	fn(): int;
	draw:	fn(dst: ref Image);
	pointer:	fn(p: ref Draw->Pointer): int;
	key:	fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;
names: array of string;
rows: array of Rect;
lastsig: string;
lastbtn: int;

bgcolor, rowcolor, textcolor, dimcolor: ref Image;

PAD: con 12;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		return sys->sprint("cannot load %s: %r", Readdir->PATH);
	display_g = display;
	font_g = font;
	mountpath = mount;
	loadcolors();
	rescan();
	return nil;
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor   = display_g.color(th.bg);
		rowcolor  = display_g.color(th.border);
		textcolor = display_g.color(th.text);
		dimcolor  = display_g.color(th.dim);
	} else {
		bgcolor   = display_g.color(int 16r080808FF);
		rowcolor  = display_g.color(int 16r333355FF);
		textcolor = display_g.color(int 16rDDDDDDFF);
		dimcolor  = display_g.color(int 16r888888FF);
	}
}

rescan(): int
{
	(entries, n) := readdir->init(mountpath, Readdir->NAME);
	sig := "";
	nn := 0;
	tmp := array[n] of string;
	for(i := 0; i < n; i++) {
		nm := entries[i].name;
		if(nm == "" || nm[0] == '.' || nm == "picker")
			continue;	# the picker doesn't list itself
		tmp[nn++] = nm;
		sig += nm + "\n";
	}
	if(sig == lastsig)
		return 0;
	lastsig = sig;
	names = tmp[0:nn];
	rows = array[nn] of Rect;
	return 1;
}

resize(r: Rect)
{
	r_g = r;
}

update(): int
{
	return rescan();
}

draw(dst: ref Image)
{
	if(dst == nil || font_g == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0, 0));
	rowh := font_g.height + 8;
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD),
		textcolor, (0, 0), font_g, "Matrix — click a composition to load");
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD + rowh),
		dimcolor, (0, 0), font_g, "(this picker is itself the `picker` composition — edit it)");
	y := r_g.min.y + PAD + 2*rowh + rowh/2;
	for(i := 0; i < len names; i++) {
		row := Rect((r_g.min.x + PAD, y), (r_g.max.x - PAD, y + rowh));
		dst.draw(row, rowcolor, nil, (0, 0));
		dst.text(Point(row.min.x + PAD, y + (rowh - font_g.height)/2),
			textcolor, (0, 0), font_g, names[i]);
		rows[i] = row;
		y += rowh + 4;
		if(y >= r_g.max.y - rowh)
			break;
	}
}

pointer(p: ref Draw->Pointer): int
{
	# edge-triggered button-1: load on press
	b := p.buttons & 1;
	hit := 0;
	if(b && !lastbtn) {
		for(i := 0; i < len names; i++)
			if(rows[i].contains(p.xy)) {
				fd := sys->open("/mnt/matrix/ctl", Sys->OWRITE);
				if(fd != nil) {
					c := array of byte ("load " + names[i]);
					sys->write(fd, c, len c);
				}
				hit = 1;
				break;
			}
	}
	lastbtn = b;
	return hit;
}

key(nil: int): int { return 0; }

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

shutdown()
{
	names = nil;
	rows = nil;
}
