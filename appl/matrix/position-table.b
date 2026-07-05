implement PositionTable;

#
# position-table - Matrix display module for TBL4 portfolio positions
#
# Reads /n/tbl4/portfolio/positions/ directory, parses JSON per-position
# files, and renders a scrollable table showing:
#   Ticker | Quantity | Avg Cost | Realized P&L
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

# Flat 2D brutalist scrollbar drawn inline — no widget toolkit.
SCROLLW: con 12;

include "matrix.m";

PositionTable: module
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

# Position data
Position: adt
{
	ticker: string;
	quantity: string;
	avg_cost: string;
	realized_pnl: string;
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;
positions: array of ref Position;
scrolltop: int;

# Colours
bgcolor: ref Image;
textcol: ref Image;
dimcol: ref Image;
headcol: ref Image;
greencol: ref Image;
redcol: ref Image;
bordercol: ref Image;

ROWH: con 20;
HDRH: con 24;
PAD: con 6;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
	positions = nil;
	scrolltop = 0;
	loadcolors();
	return nil;
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor  = display_g.color(th.bg);
		textcol  = display_g.color(th.text);
		dimcol   = display_g.color(th.dim);
		headcol  = display_g.color(th.accent);
		greencol = display_g.color(th.green);
		redcol   = display_g.color(th.red);
		bordercol= display_g.color(th.border);
	} else {
		bgcolor  = display_g.color(int 16r1A1A2EFF);
		textcol  = display_g.color(int 16rDDDDDDFF);
		dimcol   = display_g.color(int 16r888888FF);
		headcol  = display_g.color(int 16r60A5FAFF);
		greencol = display_g.color(int 16r44FF44FF);
		redcol   = display_g.color(int 16rFF4444FF);
		bordercol= display_g.color(int 16r333355FF);
	}
}

resize(r: Rect)
{
	r_g = r;
}

# Visible row count for the current rect.
visrowsof(): int
{
	v := (r_g.max.y - (r_g.min.y + HDRH)) / ROWH;
	if(v < 1)
		v = 1;
	return v;
}

# Draw a flat 2D scrollbar (track + proportional thumb) in the right
# gutter when the content overflows.
drawscroll(dst: ref Image, total, visrows: int)
{
	if(total <= visrows)
		return;
	sx := r_g.max.x - SCROLLW;
	track := Rect((sx, r_g.min.y + HDRH), (r_g.max.x, r_g.max.y));
	dst.draw(track, bgcolor, nil, (0, 0));
	trough := track.dy();
	th := trough * visrows / total;
	if(th < 8)
		th = 8;
	ty := track.min.y + trough * scrolltop / total;
	if(ty + th > track.max.y)
		ty = track.max.y - th;
	if(ty < track.min.y)
		ty = track.min.y;
	dst.draw(Rect((sx, ty), (r_g.max.x, ty + th)), dimcol, nil, (0, 0));
}

update(): int
{
	oldlen := 0;
	if(positions != nil)
		oldlen = len positions;
	readpositions();
	newlen := 0;
	if(positions != nil)
		newlen = len positions;
	if(newlen != oldlen)
		return 1;
	# Could compare individual fields, but for POC, always redraw
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;

	# Background
	dst.draw(r_g, bgcolor, nil, (0, 0));

	# Title
	titlept := Point(r_g.min.x + PAD, r_g.min.y + PAD);
	dst.text(titlept, headcol, (0, 0), font_g, "Positions");

	# Header line
	hdry := r_g.min.y + HDRH;
	hdrline := Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry));
	dst.draw(hdrline, bordercol, nil, (0, 0));

	# Column headers
	cols := columnx();
	hdrpt := Point(0, r_g.min.y + PAD);
	hdrpt.x = cols[0];
	dst.text(hdrpt, dimcol, (0, 0), font_g, "Ticker");
	hdrpt.x = cols[1];
	dst.text(hdrpt, dimcol, (0, 0), font_g, "Qty");
	hdrpt.x = cols[2];
	dst.text(hdrpt, dimcol, (0, 0), font_g, "Avg Cost");
	hdrpt.x = cols[3];
	dst.text(hdrpt, dimcol, (0, 0), font_g, "Real P&L");

	if(positions == nil || len positions == 0) {
		emptypt := Point(r_g.min.x + PAD, hdry + PAD + font_g.height);
		dst.text(emptypt, dimcol, (0, 0), font_g, "No positions");
		return;
	}

	# Rows
	visrows := (r_g.max.y - hdry) / ROWH;
	if(visrows < 1)
		visrows = 1;
	if(scrolltop > len positions - visrows)
		scrolltop = len positions - visrows;
	if(scrolltop < 0)
		scrolltop = 0;

	y := hdry + 2;
	for(i := scrolltop; i < len positions && y + ROWH <= r_g.max.y; i++) {
		p := positions[i];
		pt := Point(0, y + 2);

		pt.x = cols[0];
		dst.text(pt, textcol, (0, 0), font_g, p.ticker);

		pt.x = cols[1];
		dst.text(pt, textcol, (0, 0), font_g, p.quantity);

		pt.x = cols[2];
		dst.text(pt, textcol, (0, 0), font_g, "$" + p.avg_cost);

		pt.x = cols[3];
		col := greencol;
		if(len p.realized_pnl > 0 && p.realized_pnl[0] == '-')
			col = redcol;
		dst.text(pt, col, (0, 0), font_g, "$" + p.realized_pnl);

		y += ROWH;
	}

	drawscroll(dst, len positions, visrows);
}

columnx(): array of int
{
	cols := array[4] of int;
	w := r_g.dx();
	cols[0] = r_g.min.x + PAD;
	cols[1] = r_g.min.x + w * 20 / 100;
	cols[2] = r_g.min.x + w * 40 / 100;
	cols[3] = r_g.min.x + w * 65 / 100;
	return cols;
}

pointer(p: ref Draw->Pointer): int
{
	if(!r_g.contains(p.xy))
		return 0;
	total := len positions;
	visrows := visrowsof();
	maxtop := total - visrows;
	if(maxtop < 0)
		maxtop = 0;
	# Scroll wheel (buttons 8/16 = up/down)
	if(p.buttons & 8) {
		if(scrolltop > 0) scrolltop--;
		return 1;
	}
	if(p.buttons & 16) {
		if(scrolltop < maxtop) scrolltop++;
		return 1;
	}
	# Click/drag in the scrollbar gutter → jump proportionally.
	sx := r_g.max.x - SCROLLW;
	if(p.xy.x >= sx && (p.buttons & 7)) {
		trough := r_g.max.y - (r_g.min.y + HDRH);
		if(trough > 0) {
			scrolltop = (p.xy.y - (r_g.min.y + HDRH)) * total / trough;
			if(scrolltop > maxtop) scrolltop = maxtop;
			if(scrolltop < 0) scrolltop = 0;
		}
		return 1;
	}
	return 0;
}

key(nil: int): int
{
	return 0;
}

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

shutdown()
{
	positions = nil;
}

# ── Data reading ────────────────────────────────────────────

readpositions()
{
	posdir := mountpath + "/positions";
	fd := sys->open(posdir, Sys->OREAD);
	if(fd == nil) {
		positions = nil;
		return;
	}

	# Read directory entries
	names: list of string;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			names = dirs[i].name :: names;
	}
	fd = nil;

	# Read each position file
	plist: list of ref Position;
	count := 0;
	for(; names != nil; names = tl names) {
		name := hd names;
		content := readposfile(posdir + "/" + name);
		if(content != nil) {
			plist = content :: plist;
			count++;
		}
	}

	# Convert to array
	positions = array[count] of ref Position;
	i := 0;
	for(; plist != nil; plist = tl plist) {
		positions[i] = hd plist;
		i++;
	}
}

# Parse Plan 9 text: "asset quantity avg_cost realized_pnl"
readposfile(path: string): ref Position
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return nil;

	line := string buf[0:n];
	# Strip trailing newline
	if(len line > 0 && line[len line - 1] == '\n')
		line = line[0:len line - 1];

	(ntoks, toks) := sys->tokenize(line, " \t");
	if(ntoks < 4)
		return nil;

	p := ref Position;
	p.ticker = hd toks; toks = tl toks;
	p.quantity = hd toks; toks = tl toks;
	p.avg_cost = hd toks; toks = tl toks;
	p.realized_pnl = hd toks;
	return p;
}
