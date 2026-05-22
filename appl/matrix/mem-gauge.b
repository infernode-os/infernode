implement MemGauge;

#
# mem-gauge — Matrix display module: memory pool bars.
#
# Reads <mount>/mem/current — verbatim /dev/memory output, one
# line per pool, fields:
#   cursize maxsize hw nalloc nfree nbrk poolmax name
# We render three pools (main / heap / image) as horizontal
# "used / max" bars with cur and max labels in KB.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "matrix.m";

MemGauge: module
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

Pool: adt {
	name:	string;
	cur:	big;
	max:	big;
};

display_g:	ref Display;
font_g:		ref Font;
mountpath:	string;
r_g:		Rect;

pools:		array of Pool;

bgcolor, textcol, dimcol, headcol, bordercol, barcol, barhi: ref Image;

PAD:	con 10;
HDRH:	con 28;
ROWH:	con 38;	# per-pool row height (label + bar)

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
	pools = array[0] of Pool;

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
		barcol    = display_g.color(th.green);
		barhi     = display_g.color(th.yellow);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		bordercol = display_g.color(int 16r333355FF);
		barcol    = display_g.color(int 16r44FF44FF);
		barhi     = display_g.color(int 16rFFFF44FF);
	}
}

resize(r: Rect) { r_g = r; }

update(): int
{
	parsemem();
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0, 0));

	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), headcol,
		(0, 0), font_g, "Memory");

	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	y := hdry + PAD;
	for(i := 0; i < len pools; i++) {
		drawpool(dst, pools[i], y);
		y += ROWH;
	}
}

drawpool(dst: ref Image, p: Pool, y: int)
{
	if(p.max <= big 0)
		return;
	label := p.name;
	val := sys->sprint("%bd / %bd KB", p.cur / big 1024, p.max / big 1024);

	dst.text(Point(r_g.min.x + PAD, y), textcol,
		(0, 0), font_g, label);
	vw := font_g.width(val);
	dst.text(Point(r_g.max.x - PAD - vw, y), dimcol,
		(0, 0), font_g, val);

	# Bar below the labels.
	bary := y + 18;
	bx := r_g.min.x + PAD;
	bw := r_g.dx() - 2 * PAD;
	bh := 8;
	# Frame.
	dst.draw(Rect((bx, bary), (bx + bw, bary + bh)),
		bordercol, nil, (0, 0));
	# Fill.
	fillw := int (big bw * p.cur / p.max);
	if(fillw > bw)
		fillw = bw;
	col := barcol;
	# Highlight if > 80%.
	if(p.cur * big 100 > p.max * big 80)
		col = barhi;
	dst.draw(Rect((bx + 1, bary + 1), (bx + 1 + fillw - 2, bary + bh - 1)),
		col, nil, (0, 0));
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }
retheme(display: ref Display) { display_g = display; loadcolors(); }
shutdown() { }

# ─── Parsing ───────────────────────────────────────────────

parsemem()
{
	c := readfile(mountpath + "/mem/current");
	if(c == "")
		return;
	tmp: array of Pool;
	tmp = array[8] of Pool;
	k := 0;
	start := 0;
	for(i := 0; i <= len c; i++) {
		if(i == len c || c[i] == '\n') {
			if(i > start) {
				line := c[start:i];
				p := parseline(line);
				if(p.name != nil && k < len tmp) {
					tmp[k++] = p;
				}
			}
			start = i + 1;
		}
	}
	pools = tmp[0:k];
}

parseline(line: string): Pool
{
	p: Pool;
	(nt, toks) := sys->tokenize(line, " \t");
	if(nt < 8)
		return p;
	cur := big hd toks; toks = tl toks;
	max := big hd toks; toks = tl toks;
	# skip hw nalloc nfree nbrk poolmax
	for(k := 0; k < 5; k++)
		toks = tl toks;
	p.name = hd toks;
	p.cur = cur;
	p.max = max;
	return p;
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
