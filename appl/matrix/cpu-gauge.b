implement CpuGauge;

#
# cpu-gauge — Matrix display module: CPU utilisation sparkline.
#
# Reads <mount>/cpu/current ("pct busy total") for the headline
# figure and <mount>/cpu/history (one "ts pct" line per sample,
# oldest-first, up to 60 samples) for the sparkline.  Both files
# are written by sysmon-svc.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "matrix.m";

CpuGauge: module
{
	init:		fn(display: ref Display, font: ref Font, mount: string): string;
	resize:		fn(r: Rect);
	update:		fn(): int;
	draw:		fn(dst: ref Image);
	pointer:	fn(p: ref Draw->Pointer): int;
	key:		fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
};

display_g:	ref Display;
font_g:		ref Font;
mountpath:	string;
r_g:		Rect;

# Current state.
cur_pct:	int;
busy_procs:	int;
total_procs:	int;
history:	array of int;	# percent values, oldest-first
hist_min:	int;
hist_max:	int;

bgcolor, textcol, dimcol, headcol, accentcol, bordercol, gaugecol: ref Image;

PAD:	con 10;
HDRH:	con 28;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;

	cur_pct = 0;
	busy_procs = 0;
	total_procs = 0;
	history = array[0] of int;

	loadcolors();
	return nil;
}

loadcolors()
{
	lt := load Lucitheme Lucitheme->PATH;
	if(lt != nil) {
		th := lt->gettheme();
		bgcolor   = display_g.color(th.bg);
		textcol   = display_g.color(th.text);
		dimcol    = display_g.color(th.dim);
		headcol   = display_g.color(th.accent);
		accentcol = display_g.color(th.accent);
		bordercol = display_g.color(th.border);
		gaugecol  = display_g.color(th.green);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		accentcol = display_g.color(int 16r60A5FAFF);
		bordercol = display_g.color(int 16r333355FF);
		gaugecol  = display_g.color(int 16r44FF44FF);
	}
}

resize(r: Rect) { r_g = r; }

update(): int
{
	readcurrent();
	readhistory();
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0, 0));

	# Title.
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), headcol,
		(0, 0), font_g, "CPU");
	# Headline.
	headline := sys->sprint("%d%%   %d/%d busy", cur_pct, busy_procs, total_procs);
	hdpt := Point(r_g.min.x + PAD + font_g.width("CPU") + 2*PAD,
		r_g.min.y + PAD);
	dst.text(hdpt, textcol, (0, 0), font_g, headline);

	# Header underline.
	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	# Sparkline area.
	gx := r_g.min.x + PAD;
	gy := hdry + PAD;
	gw := r_g.dx() - 2*PAD;
	gh := r_g.dy() - HDRH - 2*PAD;
	if(gw < 4 || gh < 4)
		return;

	# Frame.
	dst.draw(Rect((gx, gy), (gx + gw, gy + 1)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx, gy + gh), (gx + gw, gy + gh + 1)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx, gy), (gx + 1, gy + gh)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx + gw - 1, gy), (gx + gw, gy + gh)), bordercol, nil, (0, 0));

	# Bars.  One column per sample; right-aligned.
	n := len history;
	if(n == 0)
		return;
	colw := 2;
	cols := (gw - 2) / colw;
	if(cols < 1)
		cols = 1;
	start := 0;
	if(n > cols)
		start = n - cols;

	for(i := start; i < n; i++) {
		pct := history[i];
		bar_h := (gh - 2) * pct / 100;
		if(bar_h < 1 && pct > 0)
			bar_h = 1;
		bx := gx + 1 + (i - start) * colw;
		by := gy + gh - 1 - bar_h;
		dst.draw(Rect((bx, by), (bx + colw - 1, gy + gh - 1)),
			gaugecol, nil, (0, 0));
	}

	# Min / max readout (one decimal not needed — these are ints).
	if(n > 1) {
		readout := sys->sprint("min %d%%  max %d%%", hist_min, hist_max);
		rw := font_g.width(readout);
		dst.text(Point(r_g.max.x - PAD - rw, r_g.min.y + PAD),
			dimcol, (0, 0), font_g, readout);
	}
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }
retheme(display: ref Display) { display_g = display; loadcolors(); }
shutdown() { }

# ─── Data ──────────────────────────────────────────────────

readcurrent()
{
	c := readfile(mountpath + "/cpu/current");
	if(c == "")
		return;
	(ntoks, toks) := sys->tokenize(c, " \t\n");
	if(ntoks >= 3) {
		cur_pct = int hd toks; toks = tl toks;
		busy_procs = int hd toks; toks = tl toks;
		total_procs = int hd toks;
	}
}

readhistory()
{
	c := readfile(mountpath + "/cpu/history");
	# Count lines.
	nl := 0;
	for(i := 0; i < len c; i++)
		if(c[i] == '\n')
			nl++;
	if(nl == 0) {
		history = array[0] of int;
		return;
	}
	tmp := array[nl] of int;
	k := 0;
	start := 0;
	hist_min = 101;
	hist_max = -1;
	for(i = 0; i <= len c; i++) {
		if(i == len c || c[i] == '\n') {
			if(i > start) {
				line := c[start:i];
				(nt, toks) := sys->tokenize(line, " \t");
				if(nt >= 2) {
					toks = tl toks;	# skip ts
					p := int hd toks;
					tmp[k++] = p;
					if(p < hist_min)
						hist_min = p;
					if(p > hist_max)
						hist_max = p;
				}
			}
			start = i + 1;
		}
	}
	history = tmp[0:k];
	if(hist_min == 101)
		hist_min = 0;
	if(hist_max == -1)
		hist_max = 0;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	fd = nil;
	return out;
}
