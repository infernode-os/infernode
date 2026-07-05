implement NetGauge;

#
# net-gauge — Matrix display module: network connection census.
#
# Reads <mount>/net/current ("tcp total connected announced" and
# "udp total connected announced") for the headline counts and
# <mount>/net/history (one "ts tcp_total tcp_conn udp_total" line
# per sample, oldest-first) for the sparkline of TCP connections.
# Both files are written by sysmon-svc.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "matrix.m";

NetGauge: module
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

# Current census.
tcp_tot, tcp_conn, tcp_ann: int;
udp_tot, udp_conn, udp_ann: int;
history:	array of int;	# tcp totals, oldest-first
hist_max:	int;

bgcolor, textcol, dimcol, headcol, bordercol, gaugecol: ref Image;

PAD:	con 10;
HDRH:	con 28;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
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
		bordercol = display_g.color(th.border);
		gaugecol  = display_g.color(th.yellow);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		bordercol = display_g.color(int 16r333355FF);
		gaugecol  = display_g.color(int 16rFFFF44FF);
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

	# Title + headline counts.
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), headcol,
		(0, 0), font_g, "NET");
	headline := sys->sprint("tcp %d (%d est, %d lis)   udp %d",
		tcp_tot, tcp_conn, tcp_ann, udp_tot);
	hdpt := Point(r_g.min.x + PAD + font_g.width("NET") + 2*PAD,
		r_g.min.y + PAD);
	dst.text(hdpt, textcol, (0, 0), font_g, headline);

	# Header underline.
	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	# Sparkline area: TCP conversation totals over time.
	gx := r_g.min.x + PAD;
	gy := hdry + PAD;
	gw := r_g.dx() - 2*PAD;
	gh := r_g.dy() - HDRH - 2*PAD;
	if(gw < 4 || gh < 4)
		return;

	dst.draw(Rect((gx, gy), (gx + gw, gy + 1)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx, gy + gh), (gx + gw, gy + gh + 1)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx, gy), (gx + 1, gy + gh)), bordercol, nil, (0, 0));
	dst.draw(Rect((gx + gw - 1, gy), (gx + gw, gy + gh)), bordercol, nil, (0, 0));

	n := len history;
	if(n == 0)
		return;
	top := hist_max;
	if(top < 1)
		top = 1;
	colw := 2;
	cols := (gw - 2) / colw;
	if(cols < 1)
		cols = 1;
	start := 0;
	if(n > cols)
		start = n - cols;

	for(i := start; i < n; i++) {
		v := history[i];
		bar_h := (gh - 2) * v / top;
		if(bar_h < 1 && v > 0)
			bar_h = 1;
		bx := gx + 1 + (i - start) * colw;
		by := gy + gh - 1 - bar_h;
		dst.draw(Rect((bx, by), (bx + colw - 1, gy + gh - 1)),
			gaugecol, nil, (0, 0));
	}

	if(n > 1) {
		readout := sys->sprint("peak %d", hist_max);
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
	c := readfile(mountpath + "/net/current");
	if(c == "")
		return;
	start := 0;
	for(i := 0; i <= len c; i++) {
		if(i == len c || c[i] == '\n') {
			if(i > start) {
				(nt, toks) := sys->tokenize(c[start:i], " \t");
				if(nt >= 4) {
					proto := hd toks; toks = tl toks;
					tot := int hd toks; toks = tl toks;
					conn := int hd toks; toks = tl toks;
					ann := int hd toks;
					case proto {
					"tcp" =>
						tcp_tot = tot; tcp_conn = conn; tcp_ann = ann;
					"udp" =>
						udp_tot = tot; udp_conn = conn; udp_ann = ann;
					}
				}
			}
			start = i + 1;
		}
	}
}

readhistory()
{
	c := readfile(mountpath + "/net/history");
	nl := 0;
	for(i := 0; i < len c; i++)
		if(c[i] == '\n')
			nl++;
	if(nl == 0) {
		history = array[0] of int;
		hist_max = 0;
		return;
	}
	tmp := array[nl] of int;
	k := 0;
	start := 0;
	hist_max = 0;
	for(i = 0; i <= len c; i++) {
		if(i == len c || c[i] == '\n') {
			if(i > start) {
				(nt, toks) := sys->tokenize(c[start:i], " \t");
				if(nt >= 4) {
					toks = tl toks;	# skip ts
					v := int hd toks;
					tmp[k++] = v;
					if(v > hist_max)
						hist_max = v;
				}
			}
			start = i + 1;
		}
	}
	history = tmp[0:k];
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
