implement Graph;

#
# Tests of Xenith's frame (appl/xenith/frame.b, libframe in Acme): the
# layer that lays text out in a rectangle, draws it, and redraws it as
# text is inserted, deleted and selected. No display, font or GUI
# emulator is needed, so they run on headless builds and in CI.
#
# frame.b draws only through the Graph module it is handed in its Mods.
# This module is that Graph: it wires itself ("$self") into the frame
# module it loads, measures every character as W pixels wide, and
# replays each draw and string onto a simulated screen, one value per
# pixel.
#
# After each edit, screencheck() compares that screen, pixel by pixel,
# with the screen the frame's text ought to produce, computed by an
# independent model of the layout rules (wrap at the right edge,
# newline, tab stops every 8 characters, truncation at the bottom).
# That catches what golden draw-op baselines catch (a stale glyph, a
# blit to the wrong place, a missed clear, text drawn over text) with
# no baseline to keep: a failure prints the screen and the expected
# screen as text.
#
# Why the tests live in a Graph rather than in xenith_frame_test.b:
# a module implementing two interfaces cannot be loaded as one with
# module data (Graph has font) -- the link wants a .mp entry the
# compiler does not emit -- so this module implements Graph alone, and
# tests/xenith_frame_test.b, which the test runner finds, loads it and
# calls init(nil) to run the suite.
#
include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";
	drawm: Draw;
	Point, Rect, Image, Font, Chans: import drawm;

# Xenith's module interfaces, as appl/xenith/common.m includes them,
# so that Dat->Mods matches the one frame.dis was compiled against
include "bufio.m";
include "plumbmsg.m";
include "workdir.m";
include "styx.m";
include "../appl/xenith/xenith.m";
include "../appl/xenith/dat.m";
include "../appl/xenith/gui.m";
include "../appl/xenith/graph.m";
include "../appl/xenith/frame.m";
include "../appl/xenith/util.m";
include "../appl/xenith/regx.m";
include "../appl/xenith/text.m";
include "../appl/xenith/file.m";
include "../appl/xenith/wind.m";
include "../appl/xenith/row.m";
include "../appl/xenith/col.m";
include "../appl/xenith/buff.m";
include "../appl/xenith/disk.m";
include "../appl/xenith/xfid.m";
include "../appl/xenith/exec.m";
include "../appl/xenith/look.m";
include "../appl/xenith/time.m";
include "../appl/xenith/scrl.m";
include "../appl/xenith/fsys.m";
include "../appl/xenith/edit.m";
include "../appl/xenith/elog.m";
include "../appl/xenith/ecmd.m";
include "../appl/xenith/styxaux.m";
include "../appl/xenith/imgload.m";
include "renderer.m";
include "../appl/xenith/render.m";
include "formatter.m";
include "../appl/xenith/format.m";
include "../appl/xenith/asyncio.m";

	Frame: import Framem;

include "testing.m";
	testing: Testing;
	T: import testing;

# characters are W pixels wide and H high; the frame is COLS characters
# wide and ROWS lines high
W: con 6;
H: con 10;
COLS: con 10;
ROWS: con 5;

# the frame sits INSET pixels into a larger screen image, so that any
# drawing outside it shows up, over a part-line strip it must leave alone
INSET: con 8;
SCRW: con 2*INSET + COLS*W;
SCRH: con 2*INSET + ROWS*H + 4;

# simulated pixel values that are not frame colours (Framem->BACK..HTEXT)
OUTSIDE: con 8;		# the screen beyond the frame's rectangle
TICKPIX: con 9;		# the typing tick's image
CORRUPT: con 99;	# a glyph drawn over a different glyph

# A simulated image: one fill value per pixel, or a glyph.
# glyph[i] >= 0 is a rune drawn in colour col[i] over fill bg[i],
# dx[i] pixels into it; glyph[i] < 0 means fill[i] is the pixel.
Simg: adt {
	img:	ref Image;
	name:	string;
	r:	Rect;
	solid:	int;		# >= 0: a replicated one-colour image
	fill:	array of int;
	glyph:	array of int;
	bg:	array of int;
	col:	array of int;
	dx:	array of int;
	quirk:	array of int;	# 1: painted by libframe's right-edge quirk (see draw)
};

simgs: list of ref Simg;
screen: ref Simg;
ops: list of string;		# draw log for the operation under test, newest first
nops := 0;
drawerr: string;		# first drawing fault seen (unknown image, mask, ...)

fakefont: ref Font;
cols: array of ref Image;

start(): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	framem = load Framem Framem->PATH;
	if(framem == nil)
		return sprint("cannot load %s: %r", Framem->PATH);
	graph := load Graph "$self";
	if(graph == nil)
		return sprint("cannot load the simulated screen as Graph: %r");
	mods := ref Dat->Mods;
	mods.sys = sys;
	mods.draw = drawm;
	mods.graph = graph;
	framem->init(mods);
	fakefont = ref Font("fake", H, H-2, nil);
	font = fakefont;
	return nil;
}

framem: Framem;

fits(s: string): int
{
	return layout(s).n;
}

startop()
{
	ops = nil;
	nops = 0;
}

#
# Graph, as the frame sees it
#

# Graph's init. The frame never calls it: the test shim does, with
# nil, to run the suite (see the comment at the top).
init(mods: ref Dat->Mods)
{
	if(mods == nil)
		runsuite();
}

balloc(r: Rect, nil: Chans, col: int): ref Image
{
	return newimg("balloc", r, col).img;
}

draw(d: ref Image, r: Rect, s: ref Image, m: ref Image, p: Point)
{
	logop(sprint("draw %s %s <- %s %s", imgname(d), rs(r), imgname(s), ps(p)));
	di := findimg(d);
	si := findimg(s);
	if(di == nil || si == nil){
		fault("draw with an unknown image");
		return;
	}
	if(m != nil)
		fault("draw with a mask");
	if(di.solid >= 0){
		fault("draw onto a colour");
		return;
	}
	# libframe's frselectpaint, painting from the right edge, starts a
	# pixel short of it (p0.x = f->r.max.x-1, in plan9port too), and so
	# paints over the last pixel column of a full line: of its last
	# glyph, or of a selected newline there. Nothing else paints a
	# one-pixel column there (characters are W wide), so such pixels
	# are marked, and the mark goes wherever later blits carry them.
	quirk := r.dx() == 1 && r.min.x == FR.max.x-1;
	r = cliprect(r, di.r);
	if(r.dx() <= 0 || r.dy() <= 0)
		return;
	if(si.solid >= 0){
		for(y := r.min.y; y < r.max.y; y++)
			for(x := r.min.x; x < r.max.x; x++){
				i := pix(di, x, y);
				di.fill[i] = si.solid;
				di.glyph[i] = -1;
				di.quirk[i] = quirk;
			}
		return;
	}
	# copy, through a snapshot so overlapping blits read the old pixels
	n := r.dx()*r.dy();
	f := array[n] of int;
	g := array[n] of int;
	b := array[n] of int;
	c := array[n] of int;
	x0 := array[n] of int;
	q := array[n] of int;
	ok := array[n] of int;
	k := 0;
	for(y := r.min.y; y < r.max.y; y++)
		for(x := r.min.x; x < r.max.x; x++){
			sx := p.x + (x-r.min.x);
			sy := p.y + (y-r.min.y);
			ok[k] = (Point(sx, sy)).in(si.r);
			if(ok[k]){
				i := pix(si, sx, sy);
				f[k] = si.fill[i];
				g[k] = si.glyph[i];
				b[k] = si.bg[i];
				c[k] = si.col[i];
				x0[k] = si.dx[i];
				q[k] = si.quirk[i];
			}
			k++;
		}
	k = 0;
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			if(ok[k]){
				i := pix(di, x, y);
				di.fill[i] = f[k];
				di.glyph[i] = g[k];
				di.bg[i] = b[k];
				di.col[i] = c[k];
				di.dx[i] = x0[k];
				di.quirk[i] = q[k];
			}
			k++;
		}
}

stringx(d: ref Image, p: Point, nil: ref Font, s: string, c: ref Image)
{
	logop(sprint("string %s %s %q in %s", imgname(d), ps(p), s, imgname(c)));
	di := findimg(d);
	ci := findimg(c);
	if(di == nil || ci == nil || ci.solid < 0){
		fault("string with an unknown image or colour");
		return;
	}
	x := p.x;
	for(j := 0; j < len s; j++){
		w := charwidth(nil, s[j]);
		for(k := 0; k < w; k++){
			for(y := p.y; y < p.y+H; y++){
				if(!(Point(x+k, y)).in(di.r))
					continue;
				i := pix(di, x+k, y);
				if(di.glyph[i] < 0){
					di.bg[i] = di.fill[i];
				}else if(di.glyph[i] != s[j] || di.dx[i] != k){
					di.glyph[i] = -1;
					di.fill[i] = CORRUPT;
					continue;
				}
				di.glyph[i] = s[j];
				di.col[i] = ci.solid;
				di.dx[i] = k;
				di.quirk[i] = 0;
			}
		}
		x += w;
	}
}

cursorset(nil: Point)
{
}

cursorswitch(nil: ref Dat->Cursor)
{
}

charwidth(nil: ref Font, c: int): int
{
	if(c == 0)
		return 0;	# no glyph: the frame substitutes one
	return W;
}

strwidth(nil: ref Font, p: string): int
{
	n := 0;
	for(i := 0; i < len p; i++)
		n += charwidth(nil, p[i]);
	return n;
}

binit()
{
}

bflush()
{
}

berror(s: string)
{
	raise "fail:frame berror: "+s;
}

#
# The simulated screen
#

newimg(name: string, r: Rect, v: int): ref Simg
{
	n := r.dx()*r.dy();
	im := ref Image(r, r, 32, Chans(0), 0, nil, nil, name);
	si := ref Simg(im, name, r, -1,
		array[n] of int, array[n] of int, array[n] of int, array[n] of int, array[n] of int,
		array[n] of {* => 0});
	for(i := 0; i < n; i++){
		si.fill[i] = v;
		si.glyph[i] = -1;
	}
	simgs = si :: simgs;
	return si;
}

newcolour(name: string, v: int): ref Image
{
	r := Rect((0, 0), (1, 1));
	im := ref Image(r, r, 32, Chans(0), 1, nil, nil, name);
	simgs = ref Simg(im, name, r, v, nil, nil, nil, nil, nil, nil) :: simgs;
	return im;
}

findimg(im: ref Image): ref Simg
{
	for(l := simgs; l != nil; l = tl l)
		if((hd l).img == im)
			return hd l;
	return nil;
}

imgname(im: ref Image): string
{
	if(im == nil)
		return "nil";
	si := findimg(im);
	if(si == nil)
		return "?";
	return si.name;
}

pix(si: ref Simg, x, y: int): int
{
	return (y-si.r.min.y)*si.r.dx() + (x-si.r.min.x);
}

cliprect(r, c: Rect): Rect
{
	if(r.min.x < c.min.x) r.min.x = c.min.x;
	if(r.min.y < c.min.y) r.min.y = c.min.y;
	if(r.max.x > c.max.x) r.max.x = c.max.x;
	if(r.max.y > c.max.y) r.max.y = c.max.y;
	return r;
}

logop(s: string)
{
	nops++;
	if(nops <= 400)
		ops = s :: ops;
}

fault(s: string)
{
	if(drawerr == nil)
		drawerr = s;
}

rs(r: Rect): string
{
	return sprint("(%d,%d)-(%d,%d)", r.min.x, r.min.y, r.max.x, r.max.y);
}

ps(p: Point): string
{
	return sprint("(%d,%d)", p.x, p.y);
}

#
# A fresh frame on a fresh screen
#

FR: con Rect((INSET, INSET), (INSET+COLS*W, INSET+ROWS*H));

newframe(): ref Frame
{
	simgs = nil;
	ops = nil;
	nops = 0;
	drawerr = nil;
	screen = newimg("screen", Rect((0, 0), (SCRW, SCRH)), OUTSIDE);
	entire := Rect(FR.min, (FR.max.x, FR.max.y+4));
	for(y := entire.min.y; y < entire.max.y; y++)
		for(x := entire.min.x; x < entire.max.x; x++)
			screen.fill[pix(screen, x, y)] = Framem->BACK;	# as Text clears it
	names := array[] of {"back", "high", "bord", "text", "htext"};
	cols = array[Framem->NCOL] of ref Image;
	for(i := 0; i < Framem->NCOL; i++)
		cols[i] = newcolour(names[i], i);
	f := framem->newframe();
	# the tick, made here rather than by frinittick, which wants a window
	tr := Rect((0, 0), (3, H));
	f.tick = newimg("tick", tr, TICKPIX).img;
	f.tickback = newimg("tickback", tr, OUTSIDE).img;
	framem->frinit(f, entire, fakefont, screen.img, cols);
	return f;
}

#
# The model: where each character of text goes, by the layout rules
#

Lay: adt {
	n:	int;		# characters that fit
	x:	array of int;
	y:	array of int;
	w:	array of int;	# width drawn: W, a tab's width, or the rest of the line
	wrapped:	array of int;	# 1 if a wrap (not a newline) put it on its line
};

layout(s: string): ref Lay
{
	l := ref Lay(0, array[len s] of int, array[len s] of int, array[len s] of int, array[len s] of int);
	minx := FR.min.x;
	maxx := FR.max.x;
	maxy := FR.max.y;
	maxtab := 8*W;
	x := minx;
	y := FR.min.y;
	for(i := 0; i < len s; i++){
		c := s[i];
		minw := W;
		if(c == '\n')
			minw = 0;
		wrap := 0;
		if(minw > maxx-x){
			x = minx;
			y += H;
			wrap = 1;
		}
		if(y >= maxy)
			break;
		w := W;
		if(c == '\n')
			w = maxx-x;
		else if(c == '\t'){
			t := x + maxtab;
			t -= (t-minx)%maxtab;
			if(t-x < W || t > maxx)
				t = x+W;
			w = t-x;
		}
		l.x[i] = x;
		l.y[i] = y;
		l.w[i] = w;
		l.wrapped[i] = wrap;
		if(c == '\n'){
			x = minx;
			y += H;
		}else
			x += w;
		l.n = i+1;
	}
	return l;
}

# The text the frame holds, read back from its boxes
frametext(f: ref Frame): string
{
	s := "";
	for(i := 0; i < f.nbox; i++){
		b := f.box[i];
		if(b.nrune < 0)
			s[len s] = b.bc;
		else
			s += b.ptr[0:b.nrune];
	}
	return s;
}

# The screen as text, one character per W-wide cell, for failure reports:
# the glyph, '.' background, '#' highlight, '!' corrupt, ' ' outside
picture(scr: ref Simg, rows: int): string
{
	s := "";
	for(row := 0; row < rows; row++){
		y := FR.min.y + row*H;
		s += "\t|";
		for(x := FR.min.x; x < FR.max.x; x += W){
			i := pix(scr, x, y);
			if(scr.glyph[i] >= 0)
				s[len s] = scr.glyph[i];
			else case scr.fill[i] {
			Framem->BACK =>	s += ".";
			Framem->HIGH =>	s += "#";
			CORRUPT =>	s += "!";
			TICKPIX =>	s += "^";
			* =>		s += " ";
			}
		}
		s += "|\n";
	}
	return s;
}

recentops(): string
{
	s := "";
	n := 0;
	for(l := ops; l != nil && n < 12; l = tl l){
		s = "\t" + hd l + "\n" + s;
		n++;
	}
	return s;
}

#
# screencheck: the frame holds want (the model's text) with selection
# [f.p0, f.p1), and the screen shows exactly that
#
screencheck(f: ref Frame, want: string): string
{
	if(drawerr != nil){
		return sprint("%s\n%s", drawerr, recentops());
	}
	got := frametext(f);
	if(got != want){
		return sprint("frame holds %q, want %q", got, want);
	}
	if(f.nchars != len want){
		return sprint("nchars %d, want %d", f.nchars, len want);
	}
	l := layout(want);
	if(l.n != len want){
		return sprint("frame holds %d characters, only %d fit", len want, l.n);
	}

	# where the frame says each character is, and back
	for(p := 0; p < len want; p++){
		pt := framem->frptofchar(f, p);
		if(pt.x != l.x[p] || pt.y != l.y[p]){
			return sprint("frptofchar(%d) = %s, want (%d,%d)\n%s",
				p, ps(pt), l.x[p], l.y[p], picture(screen, ROWS));
		}
		if(want[p] != '\n' && want[p] != '\t'){
			q := framem->frcharofpt(f, (pt.x+W/2, pt.y+H/2));
			if(q != p){
				return sprint("frcharofpt(frptofchar(%d)) = %d", p, q);
			}
		}
	}

	# the tick, if it is on, sits just left of p0: take it off to compare
	if(f.ticked){
		pt := framem->frptofchar(f, f.p0);
		for(y := pt.y; y < pt.y+H; y++)
			if(screen.fill[pix(screen, pt.x-1, y)] != TICKPIX || screen.glyph[pix(screen, pt.x-1, y)] >= 0){
				return sprint("tick not drawn at %s\n%s", ps(pt), picture(screen, ROWS));
			}
		framem->frtick(f, pt, 0);
		if(f.ticked){
			return "tick would not go off";
		}
	}

	# the expected screen
	exp := newimg("expected", screen.r, OUTSIDE);
	simgs = tl simgs;	# not one the frame may draw on
	for(y := FR.min.y; y < FR.max.y+4; y++)
		for(x := FR.min.x; x < FR.max.x; x++)
			exp.fill[pix(exp, x, y)] = Framem->BACK;
	# pixels that may be background or highlight: the end of a wrapped
	# line next to the selection, which the frame highlights or not,
	# and any marked as painted by the right-edge quirk (see draw)
	either := array[len exp.fill] of {* => 0};
	for(p = 0; p < len want; p++){
		sel := f.p0 <= p && p < f.p1;
		bg := Framem->BACK;
		fg := Framem->TEXT;
		if(sel){
			bg = Framem->HIGH;
			fg = Framem->HTEXT;
		}
		if(l.wrapped[p] && p > 0){
			prevsel := f.p0 <= p-1 && p-1 < f.p1;
			if(sel || prevsel){
				gy := l.y[p] - H;
				gx := l.x[p-1] + l.w[p-1];
				for(y = gy; y < gy+H; y++)
					for(x := gx; x < FR.max.x; x++)
						either[pix(exp, x, y)] = 1;
			}
		}
		for(y = l.y[p]; y < l.y[p]+H; y++)
			for(x := l.x[p]; x < l.x[p]+l.w[p]; x++){
				i := pix(exp, x, y);
				if(want[p] == '\n' || want[p] == '\t')
					exp.fill[i] = bg;
				else{
					exp.glyph[i] = want[p];
					exp.bg[i] = bg;
					exp.col[i] = fg;
					exp.dx[i] = x-l.x[p];
				}
			}
	}
	for(y = 0; y < SCRH; y++)
		for(x = 0; x < SCRW; x++){
			i := pix(exp, x, y);
			if(samepix(screen, exp, i))
				continue;
			if((either[i] || screen.quirk[i]) && screen.glyph[i] < 0 &&
			   (screen.fill[i] == Framem->BACK || screen.fill[i] == Framem->HIGH))
				continue;
			return sprint("pixel (%d,%d) is %s, want %s\nscreen:\n%sexpected:\n%slast drawing:\n%s",
				x, y, pixname(screen, i), pixname(exp, i),
				picture(screen, ROWS), picture(exp, ROWS), recentops());
		}
	return nil;
}

samepix(a, b: ref Simg, i: int): int
{
	if(a.glyph[i] != b.glyph[i])
		return 0;
	if(a.glyph[i] < 0)
		return a.fill[i] == b.fill[i];
	return a.bg[i] == b.bg[i] && a.col[i] == b.col[i] && a.dx[i] == b.dx[i];
}

colname(v: int): string
{
	names := array[] of {"back", "high", "bord", "text", "htext"};
	if(v >= 0 && v < len names)
		return names[v];
	case v {
	OUTSIDE =>	return "outside";
	TICKPIX =>	return "tick";
	CORRUPT =>	return "corrupt (glyph over glyph)";
	}
	return string v;
}

pixname(si: ref Simg, i: int): string
{
	if(si.glyph[i] < 0)
		return colname(si.fill[i]);
	g := "";
	g[0] = si.glyph[i];
	return sprint("glyph %q in %s on %s", g, colname(si.col[i]), colname(si.bg[i]));
}

SRCFILE: con "/tests/xenith_framesuite.b";

passed := 0;
failed := 0;
skipped := 0;

#
# Edits, applied to the frame and to the model alike.
# The model then drops what no longer fits, as the frame must.
#

model: string;

# the frame holds the model's text, and the screen shows it
check(t: ref T, f: ref Frame, what: string): int
{
	err := screencheck(f, model);
	if(err != nil){
		t.error(what+": "+err);
		return 0;
	}
	return 1;
}

ins(t: ref T, f: ref Frame, p: int, s: string): int
{
	startop();
	framem->frinsert(f, s, len s, p);
	model = model[0:p] + s + model[p:];
	model = model[0:fits(model)];
	return check(t, f, sprint("insert %q at %d", s, p));
}

del(t: ref T, f: ref Frame, p0, p1: int): int
{
	startop();
	framem->frdelete(f, p0, p1);
	if(p1 > len model)
		p1 = len model;
	model = model[0:p0] + model[p1:];
	return check(t, f, sprint("delete %d,%d", p0, p1));
}

# select [p0, p1) as Text does: unpaint the old selection, paint the new
sel(t: ref T, f: ref Frame, p0, p1: int): int
{
	startop();
	if(f.p0 != f.p1)
		framem->frdrawsel(f, framem->frptofchar(f, f.p0), f.p0, f.p1, 0);
	f.p0 = p0;
	f.p1 = p1;
	framem->frdrawsel(f, framem->frptofchar(f, p0), p0, p1, 1);
	return check(t, f, sprint("select %d,%d", p0, p1));
}

fresh(t: ref T, s: string): ref Frame
{
	f := newframe();
	model = "";
	if(!check(t, f, "empty frame"))
		return nil;
	if(s != nil && !ins(t, f, 0, s))
		return nil;
	return f;
}

#
# The tests
#

testEmpty(t: ref T)
{
	f := fresh(t, nil);
	if(f == nil)
		return;
	t.asserteq(f.nlines, 0, "nlines");
	t.asserteq(f.maxlines, ROWS, "maxlines");
	t.asserteq(f.lastlinefull, 0, "lastlinefull");
}

testInsertPlain(t: ref T)
{
	f := fresh(t, "hello");
	if(f == nil)
		return;
	t.asserteq(f.nlines, 1, "nlines");
	ins(t, f, 5, " world");		# wraps after 10 characters
	t.asserteq(f.nlines, 2, "nlines after wrap");
	ins(t, f, 0, ">");
	ins(t, f, 6, "_");
}

testInsertNewlines(t: ref T)
{
	f := fresh(t, "ab\ncd\n\nef");
	if(f == nil)
		return;
	t.asserteq(f.nlines, 4, "nlines");
	ins(t, f, 3, "\n");
	ins(t, f, 0, "\n");
	ins(t, f, len model, "\n");
}

testInsertTabs(t: ref T)
{
	f := fresh(t, "a\tb");		# tab stop at 8 characters
	if(f == nil)
		return;
	ins(t, f, 0, "\t");
	ins(t, f, 2, "xxxxxxxx\t");	# a tab at the right edge
	ins(t, f, len model, "\tz");
}

testWrapExact(t: ref T)
{
	# a line of exactly COLS characters, then one more
	f := fresh(t, "0123456789");
	if(f == nil)
		return;
	t.asserteq(f.nlines, 1, "a full line is one line");
	ins(t, f, 10, "a");
	ins(t, f, 10, "\n");
	del(t, f, 10, 11);
}

testOverflow(t: ref T)
{
	# more than fits: the frame keeps the first ROWS lines only
	f := fresh(t, "1\n2\n3\n4\n5\n6\n7\n");
	if(f == nil)
		return;
	t.asserteq(f.lastlinefull, 1, "lastlinefull");
	t.asserteq(f.nlines, ROWS, "nlines");
	ins(t, f, 0, "0\n");		# pushes a line off the bottom
	ins(t, f, 2, "0123456789abcdefghijklmnopqrstuvwxyz");
}

# The deletion cases Edwood's frame tests found bugs in (2026-06/07)
testDeleteOnlyCharOfLine(t: ref T)
{
	f := fresh(t, "abc\nd\nefg\n");
	if(f == nil)
		return;
	del(t, f, 4, 5);		# the d: its line is left empty
	del(t, f, 4, 5);		# then the empty line
}

testDeleteBeforeBlankLine(t: ref T)
{
	f := fresh(t, "abc\n\ndef\n\nghi\n");
	if(f == nil)
		return;
	del(t, f, 0, 4);		# a whole line, a blank line after it
	f = fresh(t, "abc\n\ndef\n\nghi\n");
	if(f == nil)
		return;
	del(t, f, 5, 8);		# def, leaving its newline
	del(t, f, 4, 6);
}

testDeletePartialAndFirst(t: ref T)
{
	f := fresh(t, "the quick brown fox\njumps");
	if(f == nil)
		return;
	del(t, f, 4, 7);		# part of a word
	del(t, f, 0, 4);		# from the first line
	del(t, f, 0, 1);
	del(t, f, 3, len model);	# to the end
	del(t, f, 0, len model);	# everything
}

testDeleteAcrossWrap(t: ref T)
{
	f := fresh(t, "0123456789abcdefghijklmn\nxyz");
	if(f == nil)
		return;
	del(t, f, 8, 12);		# straddles the wrap
	del(t, f, 9, 21);		# joins the newline's line up
}

testSelection(t: ref T)
{
	f := fresh(t, "hello world\nsecond line\nthird");
	if(f == nil)
		return;
	sel(t, f, 2, 4);		# within a line
	sel(t, f, 6, 15);		# across a wrap and a newline
	sel(t, f, 0, len model);	# everything
	sel(t, f, 3, 3);		# nothing: back to a tick
}

testEditInsideSelection(t: ref T)
{
	f := fresh(t, "abcdefghij\nklmnop");
	if(f == nil)
		return;
	sel(t, f, 2, 8);
	ins(t, f, 4, "XY");		# inside: the selection grows
	ins(t, f, 0, "<");		# before: it moves
	del(t, f, 5, 7);		# inside: it shrinks
	del(t, f, 1, 4);		# across its start
}

# Random edits, checked after each one. Deterministic: a failure names
# the seed and step, and the same seed reproduces it.
rng := 0;

rand(n: int): int
{
	rng = rng*1103515245 + 12345;
	return ((rng>>16) & 16r7fff) % n;
}

testRandomEdits(t: ref T)
{
	alphabet := "abcdefgh  \t\n\n";
	for(seed := 1; seed <= 20; seed++){
		rng = seed;
		f := fresh(t, nil);
		if(f == nil)
			return;
		for(step := 0; step < 60; step++){
			ok: int;
			case rand(5) {
			0 or 1 or 2 =>
				n := 1 + rand(12);
				s := "";
				for(i := 0; i < n; i++)
					s[i] = alphabet[rand(len alphabet)];
				ok = ins(t, f, rand(len model + 1), s);
			3 =>
				if(len model == 0)
					continue;
				p0 := rand(len model);
				ok = del(t, f, p0, p0 + 1 + rand(len model - p0));
			4 =>
				p0 := rand(len model + 1);
				ok = sel(t, f, p0, p0 + rand(len model - p0 + 1));
			}
			if(!ok){
				t.log(sprint("seed %d, step %d", seed, step));
				return;
			}
		}
	}
}

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: "+e);
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

runsuite()
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil)
		raise "fail:cannot load testing module";
	testing->init();
	err := start();
	if(err != nil){
		sys->fprint(sys->fildes(2), "xenith_frame_test: %s\n", err);
		raise "skip:"+err;
	}

	run("Empty", testEmpty);
	run("InsertPlain", testInsertPlain);
	run("InsertNewlines", testInsertNewlines);
	run("InsertTabs", testInsertTabs);
	run("WrapExact", testWrapExact);
	run("Overflow", testOverflow);
	run("DeleteOnlyCharOfLine", testDeleteOnlyCharOfLine);
	run("DeleteBeforeBlankLine", testDeleteBeforeBlankLine);
	run("DeletePartialAndFirst", testDeletePartialAndFirst);
	run("DeleteAcrossWrap", testDeleteAcrossWrap);
	run("Selection", testSelection);
	run("EditInsideSelection", testEditInsideSelection);
	run("RandomEdits", testRandomEdits);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
