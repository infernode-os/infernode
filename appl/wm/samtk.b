implement Samtk;

#
# The terminal's window: samterm's flayer.c, menu.c and scroll.c, and
# the mouse half of main.c, over Tk.  Plan 9's sources are the
# reference; the functions here carry their names.
#
# sam is a single window.  Each window on a file is a layer (flayer)
# inside it; layers overlap, and the list of them front to back is
# ctxt.order (sam's llist).  The window is a Tk toplevel holding one
# canvas, .c; each layer is a frame, .c.f<id>, embedded in the canvas
# as a window item tagged f<id>, laid out as flrect does: a margin of
# FLMARGIN (its outer pixel, or all of it on the current layer, in the
# border colour), the scroll bar, a gap, and the text.
#
# The pointer belongs to samterm, not to Tk.  pump() sees every event
# first: it makes a layer current, works the current layer's scroll
# bar and posts the menus as samterm's main loop does, and hands Tk
# only button 1 in the current layer's text (to select) and the menus
# once posted.  While the main loop sweeps a rectangle or waits for a
# layer to be picked (ctxt.mode == Grab), every event goes to it.
#

include "sys.m";
sys: Sys;
sprint, FD: import sys;

include "draw.m";
draw:	Draw;
Point, Rect, Font: import draw;

include "samterm.m";
Context, Flayer, Text, Section, Menu: import Samterm;

include "tkclient.m";

include "lucitheme.m";

include "samtk.m";

ctxt: ref Context;

tk:	Tk;
tkclient:	Tkclient;

# samterm/flayer.h
FLMARGIN:	con 4;
FLSCROLLWID:	con 12;
FLGAP:		con 4;

# libdraw's getrect: the width of the rubber band
Borderwidth:	con 4;

tktop := array[] of {
	"canvas .c -borderwidth 0 -width 640 -height 480",
	"pack .c -fill both -expand 1",
	"pack propagate . 0",
	# Tk delivers <Configure> to pack slaves, not to the toplevel
	"bind .c <Configure> {send wmctl resize}",
	"menu .m2",
	"menu .m2c",
	"menu .m3",
	"update",
};

# Colours.  samterm's flstart gives file layers (maincols) and the
# command window (cmdcols) each a background, a border (also the scroll
# bar) and a highlight; these come from the Lucifer theme, the halo
# theme's editbg and codebg being exactly sam's.
NCOL:	con 4;
BACK, BORD, HIGH, TEXT: con iota;
maincols := array[NCOL] of {"#ffffeaff", "#99994cff", "#eeee9eff", "#000000ff"};
cmdcols := array[NCOL] of {"#eaffeaff", "#8888ccff", "#9eeeeeff", "#000000ff"};
screenbg := "#ffffffff";
red := "#ff0000ff";

col(rgba: int): string
{
	return sprint("#%06xff", (rgba >> 8) & 16rFFFFFF);
}

init(c: ref Context)
{
	ctxt = c;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;

	tkclient = load Tkclient Tkclient->PATH;
	tkclient->init();

	lucitheme := load Lucitheme Lucitheme->PATH;
	if (lucitheme != nil) {
		th := lucitheme->gettheme();
		maincols = array[] of {col(th.editbg), col(th.accent), col(th.accent), col(th.edittext)};
		cmdcols = array[] of {col(th.codebg), col(th.diagborder), col(th.diagborder), col(th.edittext)};
		screenbg = col(th.bg);
		red = col(th.red);
	}

	# both loaders of Samtk call init; the window is made once
	if (ctxt.top == nil)
		mktop();
}

# sam's one window
mktop()
{
	(t, wmctl) := tkclient->toplevel(ctxt.ctxt, nil, "Sam", Tkclient->Appl);
	ctxt.top = t;
	ctxt.wmctl = wmctl;
	ctxt.mousec = chan[64] of string;
	ctxt.menu2c = chan[4] of string;
	ctxt.menu3c = chan[4] of string;
	tk->namechan(t, ctxt.wmctl, "wmctl");
	tk->namechan(t, ctxt.menu2c, "menu2");
	tk->namechan(t, ctxt.menu3c, "menu3");
	tkcmds(t, tktop);
	tk->cmd(t, ".c configure -background " + screenbg);

	# Appl-mode toplevels are created hidden; reveal it and wire up
	# keyboard/mouse, or the window never appears and takes no input.
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	spawn pump(t);
	tk->cmd(t, "update");
	ctxt.size = canvassize();
	sys->fprint(ctxt.logfd, "mktop: canvas %d %d\n", ctxt.size.x, ctxt.size.y);
}

canvassize(): Point
{
	return (int tk->cmd(ctxt.top, ".c cget -actwidth"),
		int tk->cmd(ctxt.top, ".c cget -actheight"));
}

screenr(): Rect
{
	return ((0, 0), canvassize());
}

# issue a batch of Tk commands to one toplevel; formerly tkclient->tkcmds
tkcmds(t: ref Tk->Toplevel, cmds: array of string)
{
	for (i := 0; i < len cmds; i++) {
		e := tk->cmd(t, cmds[i]);
		if (e != nil && e[0] == '!')
			sys->fprint(ctxt.logfd, "tk: %s: %s\n", cmds[i], e);
	}
}

cols(fl: ref Flayer): array of string
{
	if (ctxt.cmd == nil || fl.tag == ctxt.cmd.tag)
		return cmdcols;
	return maincols;
}

# flnew and flinit: a layer at r, in front of the others, not current.
# tp is set for the command window, which has its own colours.
newflayer(tag, tp: int, r: Rect): ref Flayer
{
	t := ctxt.top;
	id := ctxt.nextid++;
	o := ".c.f" + string id;
	w := o + ".i";
	n := chanadd();
	tk->namechan(t, ctxt.buttonsel[n], "button1_" + string id);
	tk->namechan(t, ctxt.keysel[n], "keys_" + string id);

	c := maincols;
	if (tp)
		c = cmdcols;
	tkcmds(t, array[] of {
		# the outer pixel of the margin is always the border colour;
		# flborder colours the rest of it on the current layer
		"frame " + o + " -borderwidth 1 -relief flat -background " + c[BORD],
		"frame " + w + " -borderwidth " + string (FLMARGIN-1) + " -relief flat -background " + c[BACK],
		"canvas " + w + ".s -borderwidth 0 -width " + string FLSCROLLWID + " -height 1 -background " + c[BORD],
		"frame " + w + ".g -borderwidth 0 -width " + string FLGAP + " -height 1 -background " + c[BACK],
		"text " + w + ".t -borderwidth 0 -width 1 -height 1 -background " + c[BACK] + " -foreground " + c[TEXT]
			+ " -selectbackground " + c[HIGH] + " -selectforeground " + c[TEXT],
		"pack " + w + " -fill both -expand 1",
		"pack " + w + ".s -side left -fill y",
		"pack " + w + ".g -side left -fill y",
		"pack " + w + ".t -side left -fill both -expand 1",
		sprint(".c create window %d %d -window %s -anchor nw -tags f%d", r.min.x, r.min.y, o, id),
		"bind " + w + ".t <Key> {send keys_" + string id + " {%A}}",
		"bind " + w + ".t <Key-\b> {send keys_" + string id + " {%A}}",
		"bind " + w + ".t <ButtonPress-1> +{send button1_" + string id + " %s %b %x %y}",
		"bind " + w + ".t <ButtonRelease-1> +{send button1_" + string id + " %s %b %x %y}",
		"bind " + w + ".t <Double-ButtonPress-1> {send button1_" + string id + " 2 %b %x %y}",
		"bind " + w + ".t <Double-ButtonRelease-1> {send button1_" + string id + " 3 %b %x %y}",
	});

	f := ref Flayer(
		tag,		# tag
		t,		# t
		"",		# tkwin
		(0, 0),		# scope
		(0, 0),		# dot
		0,		# width
		lineheight(w),	# lineheigth
		1,		# lines
		(0, 1),		# scrollbar
		-1,		# typepoint
		id,		# id
		w,		# w
		r		# r
	);
	ctxt.flayers[n] = f;
	ctxt.order = f :: ctxt.order;	# llinsert
	flrect(f, r);
	flborder(f, 0);
	sys->fprint(ctxt.logfd, "newflayer: %s at %d %d %d %d, %d lines\n",
		w, f.r.min.x, f.r.min.y, f.r.max.x, f.r.max.y, f.lines);
	return f;
}

# the height of a line of text in layer w
lineheight(w: string): int
{
	h := 0;
	fname := tk->cmd(ctxt.top, w + ".t cget -font");
	if (fname != nil && fname[0] != '!' && ctxt.ctxt != nil && ctxt.ctxt.display != nil) {
		f := Font.open(ctxt.ctxt.display, fname);
		if (f != nil)
			h = f.height;
	}
	if (h <= 0)
		h = 16;
	return h;
}

# flrect: put layer fl at r, clipped to the window, and size its text
flrect(fl: ref Flayer, r: Rect)
{
	(r, nil) = r.clip(screenr());
	fl.r = r;
	tkcmds(ctxt.top, array[] of {
		sprint(".c coords f%d %d %d", fl.id, r.min.x, r.min.y),
		sprint(".c itemconfigure f%d -width %d -height %d", fl.id, r.dx() - 2, r.dy() - 2),
		"update",
	});
	resize(fl);
}

# flclose: the layer goes; the caller sees to which and work
flclose(fl: ref Flayer)
{
	ctxt.order = dellist(ctxt.order, fl);
	for (i := 0; i < len ctxt.flayers; i++)
		if (ctxt.flayers[i] == fl) {
			chandel(i);
			break;
		}
	tkcmds(ctxt.top, array[] of {
		sprint(".c delete f%d", fl.id),
		"destroy .c.f" + string fl.id,
		"update",
	});
	fl.t = nil;
}

# flborder: the current layer's margin is all border colour
flborder(fl: ref Flayer, wide: int)
{
	if (fl == nil || fl.t == nil)
		return;
	c := cols(fl);
	bg := c[BACK];
	if (wide)
		bg = c[BORD];
	tk->cmd(ctxt.top, fl.w + " configure -background " + bg + "; update");
}

# flwhich: the frontmost layer containing p; the origin means the front one
flwhich(p: Point): ref Flayer
{
	if (p.x == 0 && p.y == 0) {
		if (ctxt.order != nil)
			return hd ctxt.order;
		return nil;
	}
	for (l := ctxt.order; l != nil; l = tl l)
		if (p.in((hd l).r))
			return hd l;
	return nil;
}

# flupfront: bring fl to the front
flupfront(fl: ref Flayer)
{
	ctxt.order = fl :: dellist(ctxt.order, fl);
	tk->cmd(ctxt.top, sprint(".c raise f%d; update", fl.id));
}

# main.c's current: nw (or nothing) becomes the layer typing goes to
current(nw: ref Flayer)
{
	if (ctxt.which != nil)
		flborder(ctxt.which, 0);
	if (nw != nil) {
		flupfront(nw);
		flborder(nw, 1);
		if ((i := whichtext(nw.tag)) >= 0) {
			t := ctxt.texts[i];
			t.flayers = nw :: dellist(t.flayers, nw);	# t->front
			if (t != ctxt.cmd)
				ctxt.work = nw;
		}
		tk->cmd(ctxt.top, "focus " + nw.w + ".t; update");
	}
	ctxt.which = nw;
}

# flresize: the window changed size; scale every layer with it.
# Returns 0 if nothing changed.
flresize(): int
{
	dr := screenr();
	old := ctxt.size;
	if (dr.dx() <= 0 || dr.dy() <= 0 || dr.max.eq(old))
		return 0;
	ctxt.size = dr.max;
	for (l := ctxt.order; l != nil; l = tl l) {
		fl := hd l;
		r := fl.r;
		if (old.x > 0 && old.y > 0)
			r = Rect((r.min.x*dr.dx()/old.x, r.min.y*dr.dy()/old.y),
				(r.max.x*dr.dx()/old.x, r.max.y*dr.dy()/old.y));
		(r, nil) = r.clip(dr);
		if (r.dx() < 100)
			r.min.x = dr.min.x;
		if (r.dx() < 100)
			r.max.x = dr.max.x;
		if (r.dy() < 2*FLMARGIN + fl.lineheigth)
			r.min.y = dr.min.y;
		if (r.dy() < 2*FLMARGIN + fl.lineheigth)
			r.max.y = dr.max.y;
		flrect(fl, r);
	}
	return 1;
}

# ---- the pointer, while the main loop holds it ----

mbuttons := 0;		# buttons, as of the last event readmouse saw

readmouse(): (int, Point)
{
	(n, l) := sys->tokenize(<-ctxt.mousec, " ");
	if (n != 3)
		return (mbuttons, (0, 0));
	mbuttons = int hd l;
	return (mbuttons, (int hd tl l, int hd tl tl l));
}

grab()
{
	# drop anything left from before
	drain: for (;;) alt {
	<-ctxt.mousec =>
		;
	* =>
		break drain;
	}
	mbuttons = ctxt.mbuttons;
	ctxt.mode = Samterm->Grab;
}

ungrab()
{
	ctxt.mode = Samterm->Normal;
}

setcursor(name: string)
{
	if (name == "")
		tk->cmd(ctxt.top, "cursor -default; update");
	else
		tk->cmd(ctxt.top, "cursor -bitmap " + name + "; update");
}

# samterm's cursor variable: the lock arrow while the host has the lock
lockcursor()
{
	if (ctxt.lock)
		setcursor("cursor.lockarrow");
	else
		setcursor("");
}

# libdraw's getrect, with button 3: sweep a rectangle.  Any other
# button abandons it, giving a zero rectangle.
getrect(): Rect
{
	t := ctxt.top;
	but := 4;
	r, rc: Rect;
	p: Point;
	b: int;

	grab();
	setcursor("cursor.sweep");
	while (mbuttons)
		(b, p) = readmouse();
	cancel := 0;
	for (;;) {
		(b, p) = readmouse();
		if (b & but)
			break;
		if (b & (7^but)) {
			cancel = 1;
			break;
		}
	}
	if (!cancel) {
		r.min = r.max = p;
		do {
			rc = r.canon();
			drawgetrect(rc, 1);
			(b, p) = readmouse();
			r.max = p;
		} while (b == but);
		drawgetrect(rc, 0);
	}
	setcursor("");
	if (b & (7^but)) {
		rc = ((0, 0), (0, 0));
		while (b)
			(b, p) = readmouse();
	}
	ungrab();
	tk->cmd(t, "update");
	return rc;
}

# the rubber band: Borderwidth pixels inside rc, in red
drawgetrect(rc: Rect, up: int)
{
	t := ctxt.top;
	if (!up) {
		tk->cmd(t, ".c delete sweep; update");
		return;
	}
	if (rc.dx() < 2*Borderwidth)
		rc.max.x = rc.min.x + 2*Borderwidth;
	if (rc.dy() < 2*Borderwidth)
		rc.max.y = rc.min.y + 2*Borderwidth;
	h := Borderwidth/2;
	if (tk->cmd(t, ".c find withtag sweep") == "")
		tk->cmd(t, sprint(".c create rectangle 0 0 0 0 -outline %s -width %d -tags sweep", red, Borderwidth));
	tk->cmd(t, sprint(".c coords sweep %d %d %d %d; .c raise sweep; update",
		rc.min.x + h, rc.min.y + h, rc.max.x - h, rc.max.y - h));
}

# main.c's getr: sweep a rectangle for a new layer.  A click takes the
# whole window or, while the command window has one layer, the part of
# it on the clicked side of the command window.  Fails if the result is
# no bigger than 100 by 40.
getr(): (int, Rect)
{
	rp := getrect();
	scr := screenr();
	if (rp.max.x && rp.max.x-rp.min.x <= 5 && rp.max.y-rp.min.y <= 5) {
		p := rp.min;
		rp = scr;
		if (ctxt.cmd != nil && len ctxt.cmd.flayers == 1) {
			r := (hd ctxt.cmd.flayers).r;
			if (p.y <= r.min.y)
				rp.max.y = r.min.y;
			else if (p.y >= r.max.y)
				rp.min.y = r.max.y;
			if (p.x <= r.min.x)
				rp.max.x = r.min.x;
			else if (p.x >= r.max.x)
				rp.min.x = r.max.x;
		}
	}
	ok: int;
	(rp, ok) = rp.clip(scr);
	return (ok && rp.max.x-rp.min.x > 100 && rp.max.y-rp.min.y > 40, rp);
}

# menu3hit's choice of layer: the bullseye, then buttons(Down).  The
# caller acts on the buttons and the point, then calls buttonsup.
getpick(): (int, Point)
{
	grab();
	setcursor("cursor.bullseye");
	b: int;
	p: Point;
	do
		(b, p) = readmouse();
	while (b == 0);
	return (b, p);
}

# buttons(Up), and the pointer goes back to Tk
buttonsup()
{
	while (ctxt.mode == Samterm->Grab && mbuttons)
		readmouse();
	ungrab();
	lockcursor();
}

# ---- menus: menu.c's genmenu2, genmenu2c and genmenu3 ----

menu2str := array [] of {
	"cut",
	"paste",
	"snarf",
	"look",
};

menu3str := array [] of {
	"new",
	"zerox",
	"resize",
	"close",
	"write",
};

paren(s: string): string
{
	return "(" + s + ")";
}

# rebuild the menus, as samterm generates them each time they are shown
menus()
{
	t := ctxt.top;
	locked := ctxt.lock != 0;
	if (ctxt.which != nil && (j := whichtext(ctxt.which.tag)) >= 0 && ctxt.texts[j].lock)
		locked = 1;

	m2 := array[NMENU2+1] of string;
	m2[0] = ".m2 delete 0 end";
	n := 1;
	for (i := 0; i < NMENU2; i++) {
		p: string;
		if (i == Search) {
			if (ctxt.pat == nil)
				break;
			p = "/" + ctxt.pat;
		} else
			p = menu2str[i];
		if (locked && i != Search && i != Look)
			p = paren(p);
		m2[n++] = additem(".m2", "menu2", i, p, menu2cmd(i));
	}
	tkcmds(t, m2[0:n]);

	m2c := array[NMENU2+1] of string;
	m2c[0] = ".m2c delete 0 end";
	for (i = 0; i < NMENU2; i++) {
		p: string;
		if (i == Send)
			p = "send";
		else
			p = menu2str[i];
		if (locked)
			p = paren(p);
		m2c[i+1] = additem(".m2c", "menu2", i, p, menu2cmd(i));
	}
	tkcmds(t, m2c);

	m3 := array[1+NMENU3+len ctxt.menus] of string;
	m3[0] = ".m3 delete 0 end";
	for (i = 0; i < NMENU3; i++) {
		p := menu3str[i];
		if (ctxt.lock)
			p = paren(p);
		m3[i+1] = additem(".m3", "menu3", i, p, menu3str[i]);
	}
	for (i = 0; i < len ctxt.menus; i++)
		m3[1+NMENU3+i] = additem(".m3", "menu3", NMENU3+i, genmenu3(i),
			"file " + string ctxt.menus[i].tag);
	tkcmds(t, m3);
}

menu2cmd(i: int): string
{
	case i {
	Cut =>	return "cut";
	Paste =>	return "paste";
	Snarf =>	return "snarf";
	Look =>	return "look";
	}
	return "search";	# Search, or Send in the command window
}

additem(m, c: string, i: int, label, cmd: string): string
{
	return sprint("%s add command -text %s -command {send %s %d %s}",
		m, tk->quote(label), c, i, cmd);
}

NBUF:	con 64;

# a file's entry: ' modified, - + * for no, one or several windows,
# . current, then its name, padded to the widest
genmenu3(n: int): string
{
	m := ctxt.menus[n];
	if (n == 0)	# unless we've been fooled, this is cmd
		return m.name;
	mw := 7;	# len "~~sam~~"
	for (i := 1; i < len ctxt.menus; i++)
		if ((w := len ctxt.menus[i].name + 4) > mw)
			mw = w;
	if (mw > NBUF)
		mw = NBUF;
	t := m.text;
	buf := "    ";
	buf[0] = m.mod;
	buf[1] = '-';
	if (t != nil) {
		if (len t.flayers == 1)
			buf[1] = '+';
		else if (len t.flayers > 1)
			buf[1] = '*';
		wk := ctxt.work;
		if (wk != nil && wk.t != nil && wk.tag == t.tag) {
			buf[2] = '.';
			if (t.state & Samterm->LDirty)
				buf[0] = '\'';
		}
	}
	name := m.name;
	if (len name > NBUF-4-2)
		name = name[0:NBUF/2-4] + "..." + name[len name - (NBUF/2-4):];
	buf += name;
	while (len buf < mw)
		buf[len buf] = ' ';
	return buf;
}

hsetpat(s: string)
{
	if (len s > 15)
		s = s[0:15];
	ctxt.pat = s;
}

# libdraw's menuhit puts the menu's last choice under the pointer,
# centred on it
postmenu(m: string, hit: int, xy: Point)
{
	t := ctxt.top;
	menus();
	nitem := int tk->cmd(t, m + " index end") + 1;
	if (hit < 0 || hit >= nitem)
		hit = 0;
	y0 := int tk->cmd(t, m + " yposition " + string hit);
	ih := lineheight(".m2");
	if (nitem > 1)
		ih = int tk->cmd(t, m + " yposition 1") - int tk->cmd(t, m + " yposition 0");
	wid := int tk->cmd(t, m + " cget -actwidth");
	if (wid <= 0)
		wid = int tk->cmd(t, m + " cget -width");
	tk->cmd(t, sprint("%s activate %d; %s post %d %d; grab set %s",
		m, hit, m, xy.x - wid/2, xy.y - y0 - ih/2, m));
}

titlectl(menu: string)
{
	tkclient->wmctl(ctxt.top, menu);
}

dellist(fls: list of ref Flayer, fl: ref Flayer): list of ref Flayer
{
	if (fls == nil) return nil;
	if (hd fls == fl) return dellist(tl fls, fl);
	return hd fls :: dellist(tl fls, fl);
}

append(fls: list of ref Flayer, fl: ref Flayer): list of ref Flayer
{
	if (fls == nil) return fl :: nil;
	return hd fls :: append(tl fls, fl);
}

# a file's name changed
settitle(t: ref Text, s: string)
{
	for (fls := t.flayers; fls != nil; fls = tl fls)
		(hd fls).tkwin = s;
}

resize(fl: ref Flayer)
{
	fl.width = int tk->cmd(ctxt.top, fl.w + ".t cget -actwidth");
	fl.lines = int tk->cmd(ctxt.top, fl.w + ".t cget -actheight") / fl.lineheigth;
	if (fl.lines < 1)
		fl.lines = 1;
}

setdot(fl: ref Flayer, l1, l2: int)
{
	tk->cmd(fl.t, fl.w + ".t tag remove sel 0.0 end");

	fl.dot.first = l1;
	fl.dot.last = l2;
	if (l2 <= fl.scope.first)
		tk->cmd(fl.t, fl.w + ".t mark set insert 0.0");
	else if (fl.scope.last <= l1)
		tk->cmd(fl.t, fl.w + ".t mark set insert end");
	else {
		tk->cmd(fl.t, fl.w + sprint(".t mark set insert 0.0+%dchars",
				l1-fl.scope.first));
		if (l1 != l2)
			tk->cmd(fl.t, fl.w + sprint(".t tag add sel 0.0+%dchars 0.0+%dchars",
				l1-fl.scope.first,
				l2-fl.scope.first));
	}
	tk->cmd(fl.t, "update");
}

panic(s: string)
{
	stderr := sys->fildes(2);
	sys->fprint(stderr, "Panic: %s\n", s);
	f := sys->sprint("#p/%d/ctl", ctxt.pgrp);
	if ((fd := sys->open(f, sys->OWRITE)) != nil)
		sys->write(fd, array of byte "killgrp\n", 8);
	exit;
}

whichmenu(tag: int): int
{
	for (i := 0; i < len ctxt.menus; i++)
		if (ctxt.menus[i].tag == tag)
			return i;
	return -1;
}

whichtext(tag: int): int
{
	for (i := 0; i < len ctxt.texts; i++)
		if (ctxt.texts[i].tag == tag)
			return i;
	return -1;
}


buttonselect(fl: ref Flayer, s: string): int
{
	tag := fl.tag;
	if ((i := whichtext(tag)) < 0) panic("buttonselect: whichtext");
	t := ctxt.texts[i];

	(n, l) := sys->tokenize(s, " ");
	if (n != 4) panic("buttonselect");

	# ignore mouse down -- wait for mouse up
	if (hd l == "1" || hd l == "3") return -1;

	if (ctxt.which != fl) {
		# the pointer goes to Tk only in the current layer
		current(fl);
		return -1;
	}

	if (hd l == "2") {
		# Double click
		l = tl tl l;
		s = tk->cmd(fl.t, fl.w + ".t index @" + hd l + "," + hd tl l);
		fl.dot.first = fl.dot.last = coord2pos(t, fl, s);
		return 1;
	}

	rg := tk->cmd(fl.t, fl.w + ".t tag ranges sel");
	if (rg == "") {
		# Nothing selected, find insertion point
		l = tl tl l;
		s = tk->cmd(fl.t, fl.w + ".t index @" + hd l + "," + hd tl l);
		fl.dot.first = fl.dot.last = coord2pos(t, fl, s);
	} else {
		(n, l) = sys->tokenize(rg, " ");
		#if (n == 4 && hd tl l == hd tl tl l)
		#	lst := hd tl tl tl l;
		#else if (n != 2) panic("buttonselect: tag ranges");
		#else lst = hd tl l;
		# We only have one contiguous selection, so, take the
		# first as dot.first and the last as dot.last
		fst:=hd l;
		lst:=fst;
		while(l!=nil){
			lst=hd l;
			l = tl l;
		}
		fl.dot.first = coord2pos(t, fl, fst);
		fl.dot.last = coord2pos(t, fl, lst);
		tk->cmd(fl.t, fl.w + ".t mark set insert " + fst);
		tk->cmd(fl.t, "update");
	}
	return 0;
}

coord2pos(t: ref Text, fl: ref Flayer, s: string): int
{
	x, y: int;

	(n, l) := sys->tokenize(s, ".");
	if (n != 2) panic("coord2pos");
	y = (int hd l) - 1;
	x = int hd tl l;
	if (x == 0 && y == 0) return fl.scope.first;
	first := fl.scope.first;
	for (scts := t.sects; scts != nil; scts = tl scts) {
		sct := hd scts;
		if (first >= sct.nrunes) {
			first -= sct.nrunes;
			continue;
		}
		if (first > 0) i := first; else i = 0;
		while (i < len sct.text) {
			if (y) {
				if (sct.text[i++] == '\n') y--;
			} else {
				if (x <= 1)
					return fl.scope.first - first + i + x;
				if (sct.text[i++] == '\n') panic("coord2pos");
				x--;
			}
		}
		if (len sct.text < sct.nrunes) panic("coord2pos: hole");
		first -= sct.nrunes;
	}
	if (x <= 0 && y == 0) return t.nrunes;
	panic("coord2pos: can't find");
	return(-1);
}


flclear(fl: ref Flayer)
{
	tk->cmd(fl.t, fl.w + ".t delete 0.0 end");
	tk->cmd(fl.t, "update");
}

flinsert(fl: ref Flayer, l: int, s: string)
{
	offset := l-fl.scope.first;
	tk->cmd(fl.t, fl.w + ".t insert 0.0+" + string offset + "chars '" + s);
	setdot(fl, fl.dot.first, fl.dot.last);
}

fldelexcess(fl: ref Flayer)
{
	tk->cmd(fl.t, fl.w + ".t delete " + string (fl.lines+1) + ".0 end");
}

fldelete(fl: ref Flayer, l1, l2: int)
{
	s: string;
	if (l1 <= fl.scope.first) {
		if (l2 >= fl.scope.last) {
			s = fl.w + sprint(".t delete 0.0 end");
			fl.scope.first = fl.scope.last = l1;
		} else {
			s = fl.w + sprint(".t delete 0.0 0.0+%dchars",
				l2 - fl.scope.first);
			fl.scope.last -= l2 - l1;
			fl.scope.first = l1;
		}
	} else {
		if (l2 >= fl.scope.last) {
			s = fl.w + sprint(".t delete 0.0+%dchars end",
				l1 - fl.scope.first);
			fl.scope.last = l1;
		} else {
			s = fl.w + sprint(".t delete 0.0+%dchars 0.0+%dchars",
				l1 - fl.scope.first, l2 - fl.scope.first);
			fl.scope.last -= l2 - l1;	
		}
	}
	if (fl.dot.first >= l2) fl.dot.first -= l2-l1;
	else if (fl.dot.first > l1) fl.dot.first = l1;
	if (fl.dot.last >= l2) fl.dot.last -= l2-l1;
	else if (fl.dot.last > l1) fl.dot.last = l1;
	tk->cmd(fl.t, s);
	setdot(fl, fl.dot.first, fl.dot.last);
	tk->cmd(fl.t, "update");
}


# ---- the scroll bar: scroll.c ----

# where the scroll bar of fl is, in canvas coordinates (flrect's l->scroll)
scrollrect(fl: ref Flayer): Rect
{
	s := fl.r.inset(FLMARGIN);
	s.max.x = fl.r.min.x + FLMARGIN + FLSCROLLWID + (FLGAP - FLMARGIN);
	return s;
}

scrpos(r: Rect, p0, p1, tot: int): Rect
{
	q := r;
	h := q.max.y - q.min.y;
	if (tot == 0)
		return q;
	if (tot > 1024*1024) {
		tot >>= 10;
		p0 >>= 10;
		p1 >>= 10;
	}
	if (p0 > 0)
		q.min.y += h*p0/tot;
	if (p1 < tot)
		q.max.y -= h*(tot-p1)/tot;
	if (q.max.y < q.min.y+2) {
		if (q.min.y+2 <= r.max.y)
			q.max.y = q.min.y+2;
		else
			q.min.y = q.max.y-2;
	}
	return q;
}

# scrdraw: the bar is the border colour; the part of the file in the
# layer is the background colour, less the bar's last column
setscrollbar(t: ref Text, fl: ref Flayer)
{
	if (fl.t == nil)
		return;
	h := int tk->cmd(fl.t, fl.w + ".s cget -actheight");
	r1 := Rect((0, 0), (FLSCROLLWID, h));
	r2 := scrpos(r1, fl.scope.first, fl.scope.last, t.nrunes);
	fl.scrollbar = fl.scope;
	c := cols(fl);
	tk->cmd(fl.t, sprint("%s.s delete all; %s.s create rectangle %d %d %d %d -fill %s -outline %s -width 0; update",
		fl.w, fl.w, r2.min.x, r2.min.y, r2.max.x - 2, r2.max.y - 1, c[BACK], c[BACK]));
}

# scroll.c's scroll: where a release of but at canvas height y goes.
# Button 1: lines to move back; 2: the place in the file; 3: the
# character starting the line at y.
scrollp0(t: ref Text, fl: ref Flayer, but, y: int): int
{
	s := scrollrect(fl);
	h := s.dy();
	tot := t.nrunes;
	my := y;
	if (my < s.min.y)
		my = s.min.y;
	if (my >= s.max.y)
		my = s.max.y;
	case but {
	1 =>
		return (my - s.min.y)/fl.lineheigth + 1;
	2 =>
		if (my > s.max.y-2)
			my = s.max.y-2;
		if (h <= 0)
			return 0;
		if (tot > 1024*1024)
			return int (((big (tot>>10))*big (my-s.min.y)/big h)<<10);
		return int (big tot*big (my-s.min.y)/big h);
	}
	p0 := charofy(t, fl, my);
	if (p0 > tot)
		p0 = tot;
	return p0;
}

# frcharofpt at the left of the line at canvas height y
charofy(t: ref Text, fl: ref Flayer, y: int): int
{
	ty := y - (fl.r.min.y + FLMARGIN);
	if (ty < 0)
		ty = 0;
	s := tk->cmd(fl.t, fl.w + ".t index @0," + string ty);
	if (s == nil || s[0] == '!')
		return fl.scope.first;
	return coord2pos(t, fl, s);
}

# ---- the pointer: samterm's main loop, the part that reads the mouse ----

# Every pointer event comes here first.  As samterm's main loop does,
# on a press: button 1 in a layer that is not current makes it current;
# any button in the current layer's scroll bar scrolls it; button 1
# elsewhere in the current layer selects (Tk does that); button 2
# shows menu 2 for the current layer and button 3 shows menu 3.  What
# sam acts on goes to the main loop on ctxt.mousec.
pump(t: ref Tk->Toplevel)
{
	ob := 0;		# buttons before this event
	swallow := 0;		# sam took the press: Tk sees nothing till all are up
	scrbut := 0;		# the button working a scroll bar
	scrfl: ref Flayer;
	for(;;) alt {
	c := <-t.ctxt.kbd =>
		tk->keyboard(t, c);
	p := <-t.ctxt.ptr =>
		b := p.buttons & 7;
		pb := ob;
		ob = b;
		ctxt.mbuttons = b;
		if (ctxt.mode == Samterm->Grab) {
			q := canvaspt(t, p.xy);
			alt {
			ctxt.mousec <-= sprint("%d %d %d", b, q.x, q.y) =>
				;
			* =>
				;
			}
			swallow = b != 0;
			continue;
		}
		if (scrbut) {
			if ((b & scrbut) == 0) {
				q := canvaspt(t, p.xy);
				s := scrollrect(scrfl);
				in := q.x >= s.min.x && q.x < s.max.x;
				sendmouse(sprint("scroll %d %d %d %d", scrfl.id, butno(scrbut), q.y, in));
				scrbut = 0;
				swallow = b != 0;
			}
			continue;
		}
		if (swallow) {
			if (b == 0)
				swallow = 0;
			continue;
		}
		if (pb == 0 && b != 0) {
			q := canvaspt(t, p.xy);
			nw := flwhich(q);
			w := ctxt.which;
			scr := w != nil && w.t != nil && q.in(scrollrect(w));
			if (b & 1) {
				if (nw != nil && nw != w) {
					sendmouse("current " + string nw.id);
					swallow = 1;
					continue;
				}
				if (scr) {
					(scrbut, scrfl) = (1, w);
					continue;
				}
				if (nw == nil) {
					swallow = 1;
					continue;
				}
			} else if (b & 2) {
				if (w == nil || w.t == nil) {
					swallow = 1;
					continue;
				}
				if (scr) {
					(scrbut, scrfl) = (2, w);
					continue;
				}
				# Tk sees the press first, so the grab the menu
				# takes holds the button: the menu gets the release
				tk->pointer(t, *p);
				if (ctxt.cmd != nil && w.tag == ctxt.cmd.tag)
					postmenu(".m2c", ctxt.hit2c, p.xy);
				else
					postmenu(".m2", ctxt.hit2, p.xy);
				continue;
			} else if (b & 4) {
				if (scr) {
					(scrbut, scrfl) = (4, w);
					continue;
				}
				tk->pointer(t, *p);
				postmenu(".m3", ctxt.hit3, p.xy);
				continue;
			}
		}
		tk->pointer(t, *p);
	c := <-t.ctxt.ctl or
	c = <-t.wreq =>
		tkclient->wmctl(t, c);
	}
}

butno(b: int): int
{
	case b {
	1 =>	return 1;
	2 =>	return 2;
	}
	return 3;
}

sendmouse(s: string)
{
	alt {
	ctxt.mousec <-= s =>
		;
	* =>
		sys->fprint(ctxt.logfd, "pump: dropped %s\n", s);
	}
}

canvaspt(t: ref Tk->Toplevel, p: Point): Point
{
	return (int tk->cmd(t, ".c canvasx " + string p.x),
		int tk->cmd(t, ".c canvasy " + string p.y));
}

# a slot for a new layer in ctxt.flayers and its channel arrays
chanadd(): int
{
	l := len ctxt.flayers;

	keysel := array [l+1] of chan of string;
	keysel[0:] = ctxt.keysel;
	keysel[l] = chan of string;
	ctxt.keysel = keysel;
	buttonsel := array [l+1] of chan of string;
	buttonsel[0:] = ctxt.buttonsel;
	buttonsel[l] = chan of string;
	ctxt.buttonsel = buttonsel;
	flayers := array [l+1] of ref Flayer;
	flayers[0:] = ctxt.flayers;
	flayers[l] = nil;
	ctxt.flayers = flayers;
	return l;
}

chandel(n: int)
{
	l := len ctxt.flayers;
	if (n >= l)
		panic("chandel");

	keysel := array [l-1] of chan of string;
	keysel[0:] = ctxt.keysel[0:n];
	keysel[n:] = ctxt.keysel[n+1:];
	ctxt.keysel = keysel;
	buttonsel := array [l-1] of chan of string;
	buttonsel[0:] = ctxt.buttonsel[0:n];
	buttonsel[n:] = ctxt.buttonsel[n+1:];
	ctxt.buttonsel = buttonsel;
	flayers := array [l-1] of ref Flayer;
	flayers[0:] = ctxt.flayers[0:n];
	flayers[n:] = ctxt.flayers[n+1:];
	ctxt.flayers = flayers;
}
