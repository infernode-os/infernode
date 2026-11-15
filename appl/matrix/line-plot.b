implement LinePlot;

#
# line-plot — generic anti-aliased series plot.
#
# Point it at ANY history-style file: one sample per line, optionally
# led by a timestamp, one or more numeric columns —
#     [ts] v1 [v2 ...]
# Every value column becomes an anti-aliased polyline (strokepath), auto-
# scaled to the union range, with min/max labels, a zero line when the
# range crosses zero, and the file's basename as title.  Where the
# first column is a time in seconds since the epoch (history-svc's
# rings), the points are placed by time, a gap in the samples is left
# as a gap, the axis is labelled with the times at its ends, and the
# newest value follows the title.  The sysmon
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
	Display, Font, Image, Path, Point, Rect: import drawm;

include "lucitheme.m";

include "daytime.m";
	daytime: Daytime;


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
times: array of int;		# each sample's time, where the file has epoch times
newest: string;		# the newest line's values, as written
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
	daytime = load Daytime Daytime->PATH;
	display_g = display;
	font_g = font;
	mountpath = mount;
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
	# a day of minutes is 25K: read it all
	s := "";
	buf := array[16384] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	if(s == "")
		return 0;
	if(s == lastraw)
		return 0;
	lastraw = s;

	(nil, lines) := sys->tokenize(s, "\n");
	rows: list of array of real;
	tss: list of int;
	ncol := 0;
	allepoch := 1;
	now := 0;
	if(daytime != nil)
		now = daytime->now();
	for(; lines != nil; lines = tl lines) {
		(nt, toks) := sys->tokenize(hd lines, " \t");
		if(nt == 0)
			continue;
		# a leading timestamp column is dropped when there is more
		# than one column (history-ring convention: "ts v1 v2 ...")
		vals: list of string;
		if(nt >= 2){
			vals = tl toks;
			t := int hd toks;
			# seconds since the epoch: within ten years before now, a
			# day after (an uptime in milliseconds is far from it)
			if(now == 0 || t < now - 10*365*86400 || t > now + 86400)
				allepoch = 0;
			tss = t :: tss;
			newest = hd tl toks;
			for(v := tl tl toks; v != nil; v = tl v)
				newest += " " + hd v;
		}else{
			vals = toks;
			allepoch = 0;
		}
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
	times = nil;
	if(allepoch && len tss == ns && ns > 0){
		times = array[ns] of int;
		for(i = ns - 1; tss != nil; tss = tl tss)
			times[i--] = hd tss;
	}else
		newest = nil;
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
	tp := dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), textcol, (0, 0), font_g, title);
	if(newest != nil && nsamp > 0)
		dst.text(tp.add((font_g.width("  "), 0)), palette[0], (0, 0), font_g, newest);
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
	hs := fmtr(hi);
	if(times == nil){
		dst.text(Point(plot.min.x, plot.max.y + 2), dimcol, (0, 0), font_g, fmtr(lo));
		dst.text(Point(plot.max.x - font_g.width(hs), r_g.min.y + PAD), dimcol, (0, 0), font_g, hs);
	}else{
		# the times along the bottom, the range inside the plot's left edge
		t0 := times[0];
		t1 := times[nsamp-1];
		ls := clock(t0, t1 - t0);
		rs := clock(t1, t1 - t0);
		dst.text(Point(plot.min.x, plot.max.y + 2), dimcol, (0, 0), font_g, ls);
		dst.text(Point(plot.max.x - font_g.width(rs), plot.max.y + 2), dimcol, (0, 0), font_g, rs);
		dst.text(Point(plot.min.x + 3, plot.min.y + 2), dimcol, (0, 0), font_g, hs);
		dst.text(Point(plot.min.x + 3, plot.max.y - 2 - font_g.height), dimcol, (0, 0), font_g, fmtr(lo));
	}

	gap := gapafter();
	for(c := 0; c < len series; c++) {
		col := palette[c % len palette];
		pts := array[nsamp] of Point;
		for(i := 0; i < nsamp; i++) {
			x: int;
			if(times != nil && times[nsamp-1] > times[0])
				x = plot.min.x + int (real (times[i] - times[0]) / real (times[nsamp-1] - times[0]) * real (plot.dx() - 1));
			else
				x = plot.min.x + i * (plot.dx() - 1) / (nsamp - 1);
			y := plot.max.y - 1 - int ((series[c][i] - lo) / (hi - lo) * real (plot.dy() - 2));
			pts[i] = Point(x, y);
		}
		# a run of samples with no gap is one line; a lone sample a dot
		s := 0;
		for(i = 1; i <= nsamp; i++)
			if(i == nsamp || (gap > 0 && times[i] - times[i-1] > gap)){
				if(i - s >= 2)
					polyline(dst, pts[s:i], 2.0, col);
				else
					dst.fillellipse(pts[s], 1, 1, col, (0, 0));
				s = i;
			}
	}
}

# where the samples are timed, the space between two that is a gap:
# three times the usual interval (the median), or none
gapafter(): int
{
	if(times == nil || nsamp < 3)
		return 0;
	d := array[nsamp-1] of int;
	for(i := 1; i < nsamp; i++)
		d[i-1] = times[i] - times[i-1];
	# the median, by halving: the smallest interval at least half are within
	a := 1;
	b := 0;
	for(i = 0; i < len d; i++)
		if(d[i] > b)
			b = d[i];
	while(a < b){
		mid := a + (b - a) / 2;
		n := 0;
		for(i = 0; i < len d; i++)
			if(d[i] <= mid)
				n++;
		if(2 * n >= len d)
			b = mid;
		else
			a = mid + 1;
	}
	return 3 * a;
}

# a time as the clock shows it here; with the day too where the span is
# more than half a day
clock(t, span: int): string
{
	if(daytime == nil)
		return string t;
	tm := daytime->local(t);
	s := sys->sprint("%02d:%02d", tm.hour, tm.min);
	if(span > 12*3600)
		s = sys->sprint("%d %s %s", tm.mday, month(tm.mon), s);
	return s;
}

month(m: int): string
{
	names := array[] of {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
	if(m < 0 || m >= len names)
		return "?";
	return names[m];
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

# a polyline through pixel centres, anti-aliased (Image.strokepath)
polyline(dst: ref Image, pts: array of Point, w: real, col: ref Image)
{
	p := Path.new().moveto(real pts[0].x + 0.5, real pts[0].y + 0.5);
	for(i := 1; i < len pts; i++)
		p.lineto(real pts[i].x + 0.5, real pts[i].y + 0.5);
	dst.strokepath(p, w, Draw->Capround, Draw->Joinround, col, pts[0]);
}
