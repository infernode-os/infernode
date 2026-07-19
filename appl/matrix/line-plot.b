implement LinePlot;

#
# line-plot — generic anti-aliased series plot.
#
# Point it at ANY history-style file: one sample per line, optionally
# led by a timestamp, one or more numeric columns —
#     [ts] v1 [v2 ...]
# Every value column becomes an anti-aliased polyline (aadraw), auto-
# scaled to the union range, with min/max labels, a zero line when the
# range crosses zero, and the file's basename as title.  The sysmon
# and llm-recorder history rings already have this shape, and any
# agent can produce it with echo >> — this is the composable
# "graph this file" view.
#
# Composition usage:
#     ... line-plot /tmp/matrix/sysmon-svc/cpu/history
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

LinePlot: module
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

series: array of array of real;	# [col][sample]
nsamp: int;
lo, hi: real;
lastraw: string;
title: string;

bgcolor, gridcol, textcol, dimcol: ref Image;
palette: array of ref Image;

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
	bgc := int 16r080808FF; brc := int 16r131313FF;
	txc := int 16rCCCCCCFF; dmc := int 16r444444FF;
	acc := int 16rE8553AFF;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgc = th.bg; brc = th.border; txc = th.text; dmc = th.dim;
		acc = th.accent;
	}
	bgcolor = display_g.color(bgc);
	gridcol = display_g.color(brc);
	textcol = display_g.color(txc);
	dimcol  = display_g.color(dmc);
	palette = array[] of {
		display_g.color(acc),
		display_g.color(int 16r35C7FFFF),	# cyan
		display_g.color(int 16r5BE37AFF),	# green
		display_g.color(int 16rF2C14EFF),	# amber
		display_g.color(txc),
	};
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
	rows: list of array of real;
	ncol := 0;
	for(; lines != nil; lines = tl lines) {
		(nt, toks) := sys->tokenize(hd lines, " \t");
		if(nt == 0)
			continue;
		# a leading timestamp column is dropped when there is more
		# than one column (history-ring convention: "ts v1 v2 ...")
		vals: list of string;
		if(nt >= 2)
			vals = tl toks;
		else
			vals = toks;
		nv := len vals;
		row := array[nv] of real;
		i := 0;
		for(; vals != nil; vals = tl vals)
			row[i++] = real hd vals;
		if(nv > ncol)
			ncol = nv;
		rows = row :: rows;
	}
	ns := len rows;
	series = array[ncol] of array of real;
	for(c := 0; c < ncol; c++)
		series[c] = array[ns] of { * => 0.0 };
	i := ns - 1;		# rows list is newest-first; store oldest-first
	for(; rows != nil; rows = tl rows) {
		row := hd rows;
		for(c = 0; c < len row; c++)
			series[c][i] = row[c];
		i--;
	}
	nsamp = ns;
	lo = 0.0; hi = 1.0;
	first := 1;
	for(c = 0; c < ncol; c++)
		for(i = 0; i < ns; i++) {
			v := series[c][i];
			if(first) { lo = v; hi = v; first = 0; }
			if(v < lo) lo = v;
			if(v > hi) hi = v;
		}
	if(hi - lo < 1.0e-9) { hi = lo + 1.0; }
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
	fh := font_g.height;
	plot := Rect((r_g.min.x + PAD, r_g.min.y + PAD + fh + 4),
		     (r_g.max.x - PAD, r_g.max.y - PAD - fh - 4));
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), textcol, (0, 0), font_g, title);
	if(nsamp < 2 || plot.dx() < 8 || plot.dy() < 8) {
		dst.text(Point(plot.min.x, plot.min.y), dimcol, (0, 0), font_g, "no data");
		return;
	}
	# frame + zero line
	dst.border(plot, 1, gridcol, (0, 0));
	if(lo < 0.0 && hi > 0.0) {
		zy := plot.max.y - int ((0.0 - lo) / (hi - lo) * real plot.dy());
		dst.draw(Rect((plot.min.x, zy), (plot.max.x, zy + 1)), gridcol, nil, (0, 0));
	}
	# range labels
	dst.text(Point(plot.min.x, plot.max.y + 2), dimcol, (0, 0), font_g, fmtr(lo));
	hs := fmtr(hi);
	dst.text(Point(plot.max.x - font_g.width(hs), r_g.min.y + PAD), dimcol, (0, 0), font_g, hs);

	for(c := 0; c < len series; c++) {
		col := palette[c % len palette];
		pts := array[nsamp] of Point;
		for(i := 0; i < nsamp; i++) {
			x := plot.min.x + i * (plot.dx() - 1) / (nsamp - 1);
			y := plot.max.y - 1 - int ((series[c][i] - lo) / (hi - lo) * real (plot.dy() - 2));
			pts[i] = Point(x, y);
		}
		if(aad != nil)
			aad->polyline(dst, pts, 2, col);
		else
			dst.poly(pts, 0, 0, 0, col, (0, 0));
	}
}

fmtr(v: real): string
{
	av := v; if(av < 0.0) av = -av;
	if(av >= 1000.0)
		return sys->sprint("%.0f", v);
	if(av >= 10.0)
		return sys->sprint("%.1f", v);
	return sys->sprint("%.2f", v);
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
	series = nil;
}
