implement LlmSessions;

#
# llm-sessions - Matrix display module: per-session token-count
# timeline (Gantt-style multi-track view).  Each tracked session
# is drawn as one horizontal row whose height encodes the sample's
# token count over the visible time window.
#
# Reads the recorder's output tree:
#
#     <mount>/sessions          list of active session ids
#     <mount>/<id>/history      "<ms> <tokens> <limit>" per sample,
#                                oldest first
#
# Time axis is anchored to the most recent sample observed across
# all sessions; older samples slide off the left edge.  No history
# is kept in this module — the recorder owns the ring.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "lucitheme.m";

include "matrix.m";

LlmSessions: module
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

Sample: adt {
	ms:     int;
	tokens: int;
	limit:  int;
};

Track: adt {
	id:      int;
	samples: array of Sample;
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;

tracks: array of Track;
tmin, tmax: int;  # ms range across all tracks
peakcap: int;     # max(limit) across all tracks, for y-scale

bgcolor:  ref Image;
textcol:  ref Image;
dimcol:   ref Image;
headcol:  ref Image;
trackbg:  ref Image;
tokcol:   ref Image;
bordercol: ref Image;

PAD: con 10;
HDRH: con 28;
LABELW: con 60;
TRACKH: con 28;
TRACKGAP: con 4;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
	tracks = array[0] of Track;
	tmin = tmax = peakcap = 0;

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
		trackbg   = display_g.color(th.border);
		tokcol    = display_g.color(th.accent);
		bordercol = display_g.color(th.border);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		trackbg   = display_g.color(int 16r24243EFF);
		tokcol    = display_g.color(int 16rD946EFFF);
		bordercol = display_g.color(int 16r333355FF);
	}
}

resize(r: Rect) { r_g = r; }

update(): int
{
	ids := readsessions();
	new := array[len ids] of Track;
	tmin = 0;
	tmax = 0;
	peakcap = 0;
	for(i := 0; i < len ids; i++) {
		new[i] = readhistory(ids[i]);
		for(j := 0; j < len new[i].samples; j++) {
			s := new[i].samples[j];
			if(tmin == 0 || s.ms < tmin) tmin = s.ms;
			if(s.ms > tmax) tmax = s.ms;
			if(s.limit > peakcap) peakcap = s.limit;
		}
	}
	tracks = new;
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;

	dst.draw(r_g, bgcolor, nil, (0, 0));

	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD),
		headcol, (0, 0), font_g, "Sessions over time");

	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	if(len tracks == 0) {
		dst.text(Point(r_g.min.x + PAD, hdry + PAD),
			dimcol, (0, 0), font_g, "no active sessions");
		return;
	}

	# Time-axis bounds — if all samples share one ms, force a 1-tick width.
	span := tmax - tmin;
	if(span <= 0) span = 1;
	if(peakcap <= 0) peakcap = 1;

	tx0 := r_g.min.x + PAD + LABELW;
	tx1 := r_g.max.x - PAD;
	tw := tx1 - tx0;
	if(tw < 10) return;

	y := hdry + PAD;
	for(i := 0; i < len tracks; i++) {
		drawtrack(dst, y, tracks[i], tx0, tw, span);
		y += TRACKH + TRACKGAP;
		if(y >= r_g.max.y - PAD)
			break;
	}
}

drawtrack(dst: ref Image, y: int, t: Track, tx0, tw, span: int)
{
	# Label
	dst.text(Point(r_g.min.x + PAD, y + (TRACKH - font_g.height) / 2),
		dimcol, (0, 0), font_g, sys->sprint("sess %-3d", t.id));

	# Track background
	dst.draw(Rect((tx0, y), (tx0 + tw, y + TRACKH)),
		trackbg, nil, (0, 0));

	# Sample bars — each sample is a vertical tick whose height encodes
	# tokens/peakcap.  Width is tw/RING_N at most; clamp to 1px minimum.
	n := len t.samples;
	if(n == 0)
		return;
	w := tw / n;
	if(w < 1) w = 1;
	for(j := 0; j < n; j++) {
		s := t.samples[j];
		x := tx0 + (s.ms - tmin) * tw / span;
		h := TRACKH * s.tokens / peakcap;
		if(h < 1) h = 1;
		if(h > TRACKH) h = TRACKH;
		dst.draw(Rect((x, y + TRACKH - h), (x + w, y + TRACKH)),
			tokcol, nil, (0, 0));
	}
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }
retheme(display: ref Display) { display_g = display; loadcolors(); }
shutdown()
{
	tracks = nil;
	bgcolor = textcol = dimcol = headcol = nil;
	trackbg = tokcol = bordercol = nil;
}

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
	out := array[n] of int;
	for(j := n - 1; j >= 0; j--) {
		out[j] = hd ids;
		ids = tl ids;
	}
	return out;
}

readhistory(id: int): Track
{
	t := Track(id, array[0] of Sample);
	text := readf(sys->sprint("%s/%d/history", mountpath, id));
	if(text == nil)
		return t;

	# First pass: count lines.
	count := 0;
	start := 0;
	i := 0;
	for(; i <= len text; i++) {
		if(i == len text || text[i] == '\n') {
			if(i > start)
				count++;
			start = i + 1;
		}
	}
	if(count == 0)
		return t;

	t.samples = array[count] of Sample;
	idx := 0;
	start = 0;
	i = 0;
	for(; i <= len text; i++) {
		if(i == len text || text[i] == '\n') {
			if(i > start) {
				line := text[start:i];
				(nt, toks) := sys->tokenize(line, " \t");
				if(nt >= 3) {
					ms := int hd toks; toks = tl toks;
					tok := int hd toks; toks = tl toks;
					lim := int hd toks;
					t.samples[idx++] = Sample(ms, tok, lim);
				}
			}
			start = i + 1;
		}
	}
	# Shrink if some lines were malformed.
	if(idx < count) {
		trimmed := array[idx] of Sample;
		trimmed[0:] = t.samples[0:idx];
		t.samples = trimmed;
	}
	return t;
}

readf(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return nil;
	return string buf[0:n];
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
