implement LlmContext;

#
# llm-context - Matrix display module: per-session context-window
# utilisation bars.  Reads the recorder's output tree:
#
#     <mount>/sessions          list of active session ids
#     <mount>/<id>/current      "<ms> <model> <tokens> <limit>"
#
# Renders one horizontal bar per session: filled portion = tokens,
# empty portion = remaining context budget, watermark line at the
# session's high-water mark from <mount>/<id>/history.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "matrix.m";

LlmContext: module
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

SessView: adt {
	id:        int;
	model:     string;
	tokens:    int;
	limit:     int;
	watermark: int;
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;

sessions: array of SessView;

bgcolor:  ref Image;
textcol:  ref Image;
dimcol:   ref Image;
headcol:  ref Image;
barfg:    ref Image;
barbg:    ref Image;
watcol:   ref Image;
bordercol: ref Image;

PAD: con 10;
HDRH: con 28;
ROWH: con 36;       # full row height (label + bar + gap)
BARH: con 14;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
	sessions = array[0] of SessView;

	loadcolors();
	return nil;
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor   = display_g.color(th.bg);
		textcol   = display_g.color(th.text);
		dimcol    = display_g.color(th.dim);
		headcol   = display_g.color(th.accent);
		barfg     = display_g.color(th.accent);
		barbg     = display_g.color(th.border);
		watcol    = display_g.color(th.yellow);
		bordercol = display_g.color(th.border);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		barfg     = display_g.color(int 16rD946EFFF);
		barbg     = display_g.color(int 16r333355FF);
		watcol    = display_g.color(int 16rFFFF44FF);
		bordercol = display_g.color(int 16r333355FF);
	}
}

resize(r: Rect) { r_g = r; }

update(): int
{
	ids := readsessions();
	new := array[len ids] of SessView;
	for(i := 0; i < len ids; i++) {
		new[i] = readcurrent(ids[i]);
		new[i].watermark = readwatermark(ids[i]);
	}
	sessions = new;
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;

	dst.draw(r_g, bgcolor, nil, (0, 0));

	# Title
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD),
		headcol, (0, 0), font_g, "Context Window");

	# Header rule
	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	if(len sessions == 0) {
		dst.text(Point(r_g.min.x + PAD, hdry + PAD),
			dimcol, (0, 0), font_g, "no active sessions");
		return;
	}

	y := hdry + PAD;
	for(i := 0; i < len sessions; i++) {
		drawrow(dst, y, sessions[i]);
		y += ROWH;
		if(y >= r_g.max.y - PAD)
			break;
	}
}

drawrow(dst: ref Image, y: int, s: SessView)
{
	# Label: "id  model        12345/200000"
	label := sys->sprint("%-3d %-22s %6d / %d", s.id, s.model, s.tokens, s.limit);
	dst.text(Point(r_g.min.x + PAD, y), textcol, (0, 0), font_g, label);

	# Bar geometry
	bx0 := r_g.min.x + PAD;
	bx1 := r_g.max.x - PAD;
	bw := bx1 - bx0;
	by := y + font_g.height + 4;

	# Background
	dst.draw(Rect((bx0, by), (bx1, by + BARH)), barbg, nil, (0, 0));

	# Filled portion
	filled := 0;
	if(s.limit > 0)
		filled = bw * s.tokens / s.limit;
	if(filled < 0) filled = 0;
	if(filled > bw) filled = bw;
	if(filled > 0)
		dst.draw(Rect((bx0, by), (bx0 + filled, by + BARH)),
			barfg, nil, (0, 0));

	# Watermark tick
	if(s.watermark > 0 && s.watermark <= s.limit) {
		wx := bx0 + bw * s.watermark / s.limit;
		dst.draw(Rect((wx, by - 2), (wx + 1, by + BARH + 2)),
			watcol, nil, (0, 0));
	}
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }
retheme(display: ref Display) { display_g = display; loadcolors(); }
shutdown() { }

# ── Data ─────────────────────────────────────────────────────

readsessions(): array of int
{
	text := readf(mountpath + "/sessions");
	if(text == nil)
		return array[0] of int;
	ids: list of int;
	n := 0;
	start := 0;
	for(i := 0; i <= len text; i++) {
		if(i == len text || text[i] == '\n') {
			if(i > start) {
				s := text[start:i];
				if(isnumeric(s)) {
					ids = int s :: ids;
					n++;
				}
			}
			start = i + 1;
		}
	}
	# Reverse to original order.
	out := array[n] of int;
	for(j := n - 1; j >= 0; j--) {
		out[j] = hd ids;
		ids = tl ids;
	}
	return out;
}

readcurrent(id: int): SessView
{
	v := SessView(id, "?", 0, 0, 0);
	text := trim(readf(sys->sprint("%s/%d/current", mountpath, id)));
	if(text == nil)
		return v;
	(ntoks, toks) := sys->tokenize(text, " \t");
	if(ntoks < 4)
		return v;
	toks = tl toks;             # skip ms
	v.model = hd toks; toks = tl toks;
	v.tokens = int hd toks; toks = tl toks;
	v.limit = int hd toks;
	return v;
}

readwatermark(id: int): int
{
	text := readf(sys->sprint("%s/%d/history", mountpath, id));
	if(text == nil)
		return 0;
	max := 0;
	start := 0;
	for(i := 0; i <= len text; i++) {
		if(i == len text || text[i] == '\n') {
			if(i > start) {
				line := text[start:i];
				(nt, t) := sys->tokenize(line, " \t");
				if(nt >= 2) {
					t = tl t;
					n := int hd t;
					if(n > max) max = n;
				}
			}
			start = i + 1;
		}
	}
	return max;
}

readf(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

trim(s: string): string
{
	if(s == nil)
		return nil;
	end := len s;
	while(end > 0 && (s[end-1] == '\n' || s[end-1] == ' ' || s[end-1] == '\t'))
		end--;
	return s[0:end];
}

isnumeric(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}
