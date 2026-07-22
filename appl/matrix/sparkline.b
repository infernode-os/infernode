implement Sparkline;

#
# sparkline — the minimal anti-aliased trend strip.
#
# Reads the same history shape as line-plot ("[ts] v1 [v2 ...]" per
# line) and draws ONE smooth line — the last value column — plus the
# current value as a headline.  No axes, no chrome: compose several in
# a column for an at-a-glance board.
#
# Composition usage:
#     ... sparkline /tmp/matrix/sysmon-svc/cpu/history
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "aadraw.m";
	aad: AAdraw;

include "matrix.m";

Sparkline: module
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

vals: array of real;
lastraw: string;
title: string;

bgcolor, textcol, dimcol, acccol: ref Image;

PAD: con 8;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	display_g = display;
	font_g = font;
	mountpath = mount;
	aad = load AAdraw AAdraw->PATH;
	if(aad != nil)
		aad->init(display);
	# title: the last two path components ("cpu/history" beats "history")
	title = mount;
	slashes := 0;
	for(i := len mount - 1; i >= 0; i--)
		if(mount[i] == '/') {
			slashes++;
			if(slashes == 2) {
				title = mount[i+1:];
				break;
			}
		}
	loadcolors();
	reload();
	return nil;
}

loadcolors()
{
	bgc := int 16r080808FF; txc := int 16rCCCCCCFF;
	dmc := int 16r444444FF; acc := int 16rE8553AFF;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgc = th.bg; txc = th.text; dmc = th.dim; acc = th.accent;
	}
	bgcolor = display_g.color(bgc);
	textcol = display_g.color(txc);
	dimcol  = display_g.color(dmc);
	acccol  = display_g.color(acc);
}

reload(): int
{
	fd := sys->open(mountpath, Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	s := string buf[0:n];
	if(s == lastraw)
		return 0;
	lastraw = s;
	(nil, lines) := sys->tokenize(s, "\n");
	vl: list of real;
	for(; lines != nil; lines = tl lines) {
		(nt, toks) := sys->tokenize(hd lines, " \t");
		if(nt == 0)
			continue;
		# last column is the plotted value
		v := 0.0;
		for(; toks != nil; toks = tl toks)
			v = real hd toks;
		vl = v :: vl;
	}
	vals = array[len vl] of real;
	for(i := len vals - 1; i >= 0; i--) {
		vals[i] = hd vl;
		vl = tl vl;
	}
	return 1;
}

resize(r: Rect)
{
	r_g = r;
}

update(): int
{
	return reload();
}

draw(dst: ref Image)
{
	if(dst == nil || font_g == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0, 0));
	n := len vals;
	cur := "-";
	if(n > 0)
		cur = sys->sprint("%.4g", vals[n-1]);
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), dimcol, (0, 0), font_g, title);
	cw := font_g.width(cur);
	dst.text(Point(r_g.max.x - PAD - cw, r_g.min.y + PAD), textcol, (0, 0), font_g, cur);
	if(n < 2)
		return;
	lo := vals[0]; hi := vals[0];
	for(i := 1; i < n; i++) {
		if(vals[i] < lo) lo = vals[i];
		if(vals[i] > hi) hi = vals[i];
	}
	if(hi - lo < 1.0e-9)
		hi = lo + 1.0;
	strip := Rect((r_g.min.x + PAD, r_g.min.y + PAD + font_g.height + 4),
		      (r_g.max.x - PAD, r_g.max.y - PAD));
	if(strip.dy() < 4)
		return;
	pts := array[n] of Point;
	for(i = 0; i < n; i++) {
		x := strip.min.x + i * (strip.dx() - 1) / (n - 1);
		y := strip.max.y - 1 - int ((vals[i] - lo) / (hi - lo) * real (strip.dy() - 2));
		pts[i] = Point(x, y);
	}
	if(aad != nil) {
		aad->polyline(dst, pts, 2, acccol);
		aad->disc(dst, pts[n-1], 3, 3, acccol);
	} else
		dst.poly(pts, 0, 0, 0, acccol, (0, 0));
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

shutdown()
{
	vals = nil;
}
