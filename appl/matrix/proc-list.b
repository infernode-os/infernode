implement ProcList;

#
# proc-list — Matrix display module: live process table.
#
# Reads <mount>/proc/list (one /prog/<pid>/status snapshot per
# row, fields: pid grpid user time state size_K module — fixed-
# width as emitted by devprog.c).
#
# Interactive: click a row to select.  Pressing the 'k' key with
# a row selected writes "kill" to /prog/<pid>/ctl — the wm/task
# replacement.  (Limited deliberately: requires an explicit key
# after selection, not a single click, to avoid kill-by-misclick.)
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect, Pointer: import drawm;

include "lucitheme.m";

include "matrix.m";

ProcList: module
{
	init:		fn(display: ref Display, font: ref Font, mount: string): string;
	resize:		fn(r: Rect);
	update:		fn(): int;
	draw:		fn(dst: ref Image);
	pointer:	fn(p: ref Pointer): int;
	key:		fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
};

Row: adt {
	pid:	string;
	grp:	string;
	user:	string;
	time:	string;
	state:	string;
	size:	string;
	mod:	string;
};

display_g:	ref Display;
font_g:		ref Font;
mountpath:	string;
r_g:		Rect;

rows:		array of Row;
sel_pid:	string;		# pid of selected row, or "" for none
lastbtn1:	int;
scroll:		int;		# top row index displayed

bgcolor, textcol, dimcol, headcol, bordercol, selcol, killcol: ref Image;

PAD:	con 10;
HDRH:	con 28;
COLH:	con 22;	# column-header line height
ROWH:	con 22;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;

	display_g = display;
	font_g = font;
	mountpath = mount;
	rows = array[0] of Row;
	sel_pid = "";
	lastbtn1 = 0;
	scroll = 0;

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
		selcol    = display_g.color(th.menuhilit);
		killcol   = display_g.color(th.red);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		textcol   = display_g.color(int 16rDDDDDDFF);
		dimcol    = display_g.color(int 16r888888FF);
		headcol   = display_g.color(int 16r60A5FAFF);
		bordercol = display_g.color(int 16r333355FF);
		selcol    = display_g.color(int 16r2A2A4EFF);
		killcol   = display_g.color(int 16rFF4444FF);
	}
}

resize(r: Rect) { r_g = r; }

update(): int
{
	parselist();
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0, 0));

	# Title bar.
	title := sys->sprint("Processes (%d)", len rows);
	dst.text(Point(r_g.min.x + PAD, r_g.min.y + PAD), headcol,
		(0, 0), font_g, title);
	if(sel_pid != "") {
		hint := sys->sprint("[selected: %s — press 'k' to kill]", sel_pid);
		hw := font_g.width(hint);
		dst.text(Point(r_g.max.x - PAD - hw, r_g.min.y + PAD),
			killcol, (0, 0), font_g, hint);
	}

	hdry := r_g.min.y + HDRH;
	dst.draw(Rect((r_g.min.x, hdry - 1), (r_g.max.x, hdry)),
		bordercol, nil, (0, 0));

	# Column header.
	cols := layout();
	dst.text(Point(cols[0], hdry + 2), dimcol, (0, 0), font_g, "PID");
	dst.text(Point(cols[1], hdry + 2), dimcol, (0, 0), font_g, "STATE");
	dst.text(Point(cols[2], hdry + 2), dimcol, (0, 0), font_g, "MEM");
	dst.text(Point(cols[3], hdry + 2), dimcol, (0, 0), font_g, "MOD");

	# Body.
	bodyy := hdry + COLH;
	avail := r_g.max.y - bodyy - PAD;
	visible := avail / ROWH;
	if(visible < 1)
		return;

	# Clamp scroll.
	if(scroll < 0)
		scroll = 0;
	if(scroll > len rows - visible && scroll > 0)
		scroll = len rows - visible;
	if(scroll < 0)
		scroll = 0;

	for(i := 0; i < visible && scroll + i < len rows; i++) {
		row := rows[scroll + i];
		y := bodyy + i * ROWH;
		# Selection highlight.
		if(row.pid == sel_pid)
			dst.draw(Rect((r_g.min.x + 2, y - 2),
				(r_g.max.x - 2, y + ROWH - 2)),
				selcol, nil, (0, 0));
		dst.text(Point(cols[0], y), textcol, (0, 0), font_g, row.pid);
		dst.text(Point(cols[1], y), textcol, (0, 0), font_g, row.state);
		dst.text(Point(cols[2], y), textcol, (0, 0), font_g, row.size);
		dst.text(Point(cols[3], y), dimcol,  (0, 0), font_g, row.mod);
	}
}

# Column x-positions: PID, STATE, MEM, MODULE.
layout(): array of int
{
	cols := array[4] of int;
	cols[0] = r_g.min.x + PAD;
	cols[1] = r_g.min.x + r_g.dx() * 18 / 100;
	cols[2] = r_g.min.x + r_g.dx() * 40 / 100;
	cols[3] = r_g.min.x + r_g.dx() * 58 / 100;
	return cols;
}

pointer(p: ref Pointer): int
{
	if(p == nil)
		return 0;
	# Edge-triggered button-1 (so dragging doesn't reselect).
	btn := p.buttons & 1;
	if(btn && !lastbtn1) {
		lastbtn1 = 1;
		# Which row?
		hdry := r_g.min.y + HDRH;
		bodyy := hdry + COLH;
		if(p.xy.y < bodyy) {
			lastbtn1 = btn;
			return 0;
		}
		idx := (p.xy.y - bodyy) / ROWH + scroll;
		if(idx >= 0 && idx < len rows) {
			if(sel_pid == rows[idx].pid)
				sel_pid = "";	# toggle off
			else
				sel_pid = rows[idx].pid;
		}
		return 1;
	}
	if(!btn)
		lastbtn1 = 0;
	# Mouse wheel: buttons 4 / 5 scroll.
	if(p.buttons & 8) {	# wheel up
		scroll -= 3;
		return 1;
	}
	if(p.buttons & 16) {	# wheel down
		scroll += 3;
		return 1;
	}
	return 0;
}

key(k: int): int
{
	if(k == 'k' && sel_pid != "") {
		killproc(sel_pid);
		sel_pid = "";
		return 1;
	}
	if(k == 16r7F) {	# Up arrow approx
		scroll--;
		return 1;
	}
	return 0;
}

retheme(display: ref Display) { display_g = display; loadcolors(); }
shutdown() { }

# ─── Data ──────────────────────────────────────────────────

# Parse fixed-width /prog/<pid>/status snapshot.  Tokenisation
# is enough — fields are space-separated.
parselist()
{
	c := readfile(mountpath + "/proc/list");
	if(c == "") {
		rows = array[0] of Row;
		return;
	}
	# Count lines.
	nl := 0;
	for(i := 0; i < len c; i++)
		if(c[i] == '\n')
			nl++;
	if(nl == 0) {
		rows = array[0] of Row;
		return;
	}
	tmp := array[nl] of Row;
	k := 0;
	start := 0;
	for(i = 0; i <= len c; i++) {
		if(i == len c || c[i] == '\n') {
			if(i > start) {
				r := parsestatus(c[start:i]);
				if(r.pid != "")
					tmp[k++] = r;
			}
			start = i + 1;
		}
	}
	rows = tmp[0:k];
}

parsestatus(line: string): Row
{
	r: Row;
	(nt, toks) := sys->tokenize(line, " \t");
	if(nt < 7)
		return r;
	r.pid = hd toks; toks = tl toks;
	r.grp = hd toks; toks = tl toks;
	r.user = hd toks; toks = tl toks;
	r.time = hd toks; toks = tl toks;
	r.state = hd toks; toks = tl toks;
	r.size = hd toks; toks = tl toks;
	r.mod = hd toks;
	return r;
}

killproc(pid: string)
{
	path := "/prog/" + pid + "/ctl";
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return;
	cmd := array of byte "kill";
	sys->write(fd, cmd, len cmd);
	fd = nil;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	buf := array[16384] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	fd = nil;
	return out;
}
