implement Docview;

#
# A window's document: one view for every kind (docs/xenith-documents.md).
#
# The engine (docengine(2)) holds the document; the view stacks its
# sheets in a column, a gap between, and shows the part at org: fitted
# to the window's width (a PDF) or a whole sheet in view (an image), or,
# for a flowing document (Markdown, HTML, a page browsed), set to the
# window's width. A sheet an engine paints sharp at any scale (a PDF
# page) is painted at the view's, off the main loop, and kept while it
# is in or near view; until it arrives, a painting at another scale is
# shown scaled, or a blank sheet. A sheet an engine paints at scale 100
# only is painted straight onto the screen at 100, or scaled.
#
# While the document is shown the body's text frame draws off screen,
# kept up to date for Look, search and the window's files.
#

include "common.m";
include "keyboard.m";

sys: Sys;
dat: Dat;
utils: Utils;
drawm: Draw;
graph: Graph;
gui: Gui;
look: Look;
scrl: Scroll;
xenith: Xenith;
framem: Framem;
textm: Textm;
windowm: Windowm;
bufferm: Bufferm;
asyncio: Asyncio;
docreg: Docreg;

sprint: import sys;
FALSE, TRUE: import Dat;
mouse, casync: import dat;
Point, Rect, Image, Display, Font, Chans: import drawm;
warning, stralloc, strfree: import utils;
bflush: import graph;
mainwin, display: import gui;
Window: import windowm;
Text: import textm;
Buffer: import bufferm;
AsyncMsg: import asyncio;
BACK, BORD, TEXT: import Framem;
Kind: import docreg;

GAP: con 12;		# between sheets, and round a column of them
MAXDIM: con 6000;	# the largest side of a sheet painted
MINSCALE: con 5;

gens := 0;
fonts: array of ref Font;
fontsfor: array of string;

init(mods: ref Dat->Mods)
{
	sys = mods.sys;
	dat = mods.dat;
	utils = mods.utils;
	drawm = mods.draw;
	graph = mods.graph;
	gui = mods.gui;
	look = mods.look;
	scrl = mods.scroll;
	xenith = mods.xenith;
	framem = mods.framem;
	textm = mods.textm;
	windowm = mods.windowm;
	bufferm = mods.bufferm;
	asyncio = mods.asyncio;
	docreg = load Docreg Docreg->PATH;
	if(docreg != nil)
		docreg->init(display);
}

# ---- what is a document ----

kind(name: string): ref Kind
{
	if(docreg == nil || name == nil || look->isurl(name))
		return nil;
	if((k := docreg->kind(name, nil)) != nil)
		return k;
	return docreg->kind(name, head(name));
}

# The bytes a regular file begins with
head(name: string): array of byte
{
	(ok, d) := sys->stat(name);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return nil;
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[16] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return b[0:n];
}

shown(w: ref Window): int
{
	return w.doc != nil && w.doc.shown;
}

readonly(w: ref Window): int
{
	d := w.doc;
	return d != nil && (d.web || d.kind == nil || d.kind.class == Docreg->Binary);
}

flowing(d: ref Doc): int
{
	return d.web || (d.kind != nil && d.kind.class == Docreg->Source);
}

# ---- opening ----

open(w: ref Window, name: string, k: ref Kind): string
{
	if(docreg == nil)
		return "no document registry";
	if(k == nil)
		return "not a document";
	# opened again, a binary document keeps its place; a source
	# document opens on the passage its text shows (opened sets
	# it, from the line marked here as -1-line)
	org := Point(0, 0);
	if(w.doc != nil && w.doc.name == name)
		org = w.doc.org;
	drop(w);
	d := newdoc(name, k);
	# a source document is the window's text, unsaved changes and
	# all, when it is the window's file; another file is read
	data: array of byte;
	if(k.class == Docreg->Source && name == w.body.file.name){
		data = array of byte bodytext(w);
		org = Point(0, -1 - lineof(w.body, w.body.org));
	}
	d.org = org;
	w.doc = d;
	hideframe(w);
	draw(w);
	spawn opener(w.id, d.gen, k, data, name, style(w, flowwidth(w, d)));
	w.settag();
	return nil;
}

browse(w: ref Window, url: string): string
{
	if(docreg == nil)
		return "no document registry";
	d := w.doc;
	if(d != nil && d.web && d.h >= 0){
		if(!d.shown){
			d.shown = 1;
			hideframe(w);
		}
		return d.eng->command(d.h, "browse", url);
	}
	k := docreg->kindof("html");
	if(k == nil)
		return "no engine for HTML";
	if(d != nil)
		drop(w);
	d = newdoc(url, k);
	d.web = 1;
	w.doc = d;
	w.filemenu = FALSE;
	hideframe(w);
	draw(w);
	spawn opener(w.id, d.gen, k, nil, url, style(w, flowwidth(w, d)));
	return nil;
}

newdoc(name: string, k: ref Kind): ref Doc
{
	d := ref Doc;
	d.kind = k;
	d.h = -1;
	d.name = name;
	d.shown = 1;
	d.gen = ++gens;
	d.scale = 100;
	d.fit = Fitnone;
	return d;
}

opener(winid, gen: int, k: ref Kind, data: array of byte, name: string, st: ref Docengine->Style)
{
	h := -1;
	(eng, err) := docreg->engine(k);
	if(eng != nil){
		{
			(h, err) = eng->open(data, name, st);
		} exception e {
		"*" =>
			if(err == nil)
				err = e;
		}
	}
	# shown first; a binary document's text (all its pages') after
	send(ref AsyncMsg.DocOpened(winid, gen, eng, h, nil, err));
	if(h >= 0 && k.class == Docreg->Binary){
		text: string;
		{
			text = eng->text(h);
		} exception {
		"*" =>
			;
		}
		send(ref AsyncMsg.DocText(winid, gen, text));
	}
}

# A binary document's text, read after it was shown, as the window's
texted(w: ref Window, gen: int, text: string)
{
	d := w.doc;
	if(d == nil || d.gen != gen || d.h < 0 || flowing(d))
		return;
	settext(w, text);
	if(d.shown)
		draw(w);
}

send(m: ref AsyncMsg)
{
	for(;;) alt {
	casync <-= m =>
		return;
	* =>
		sys->sleep(1);
	}
}

opened(w: ref Window, gen: int, eng: Docengine, h: int, text: string, err: string)
{
	d := w.doc;
	if(d == nil || d.gen != gen){
		if(eng != nil && h >= 0)
			eng->close(h);
		return;
	}
	if(h < 0){
		d.err = err;
		warning(nil, sprint("%s: %s\n", d.name, err));
		draw(w);
		return;
	}
	d.eng = eng;
	d.h = h;
	d.err = nil;
	if((c := eng->events(h)) != nil)
		spawn watch(w.id, gen, c);
	if(text != nil && !flowing(d))
		settext(w, text);
	measure(d);
	if(!flowing(d) && d.fit == Fitnone && d.scale == 100){
		if(eng->scalable(h))
			d.fit = Fitwidth;
		else
			d.fit = Fitpage;
	}
	d.vw = d.vh = 0;	# set the scale and the layout for the view
	if(d.org.y < 0){
		# a source document: from the line its text was showing
		(n, y) := eng->lineto(h, -1 - d.org.y);
		d.org = Point(0, 0);
		setlayout(w, d);
		if(n >= 0 && n < len d.tops)
			d.org = Point(0, d.tops[n] + y * d.scale / 100);
	}
	draw(w);
	w.settag();
}

watch(winid, gen: int, c: chan of string)
{
	for(;;){
		e := <-c;
		if(e == "gone")
			return;
		send(ref AsyncMsg.DocEvent(winid, gen, e));
	}
}

# A page browsed: loaded, laid out again, or failed
event(w: ref Window, gen: int, e: string)
{
	d := w.doc;
	if(d == nil || d.gen != gen || d.h < 0)
		return;
	(verb, rest) := split(e);
	case verb {
	"done" =>
		# the page's URL names the window and its text is the window's
		if((u := d.eng->name(d.h)) != nil){
			d.name = u;
			if(u != w.body.file.name)
				w.setname(u, len u);
		}
		settext(w, d.eng->text(d.h));
		measure(d);
		d.vw = d.vh = 0;
		setlayout(w, d);
		d.org = Point(0, int rest);
		d.word = nil;
		d.found = nil;
		draw(w);
		w.settag();
	"update" =>
		measure(d);
		layout(d);
		draw(w);
	"error" =>
		warning(nil, sprint("%s: %s\n", d.name, rest));
	}
}

# The window's text, set to s (a binary document's or a page's text),
# read-only and not a change to the file
settext(w: ref Window, s: string)
{
	w.nomark = 1;
	w.body.delete(0, w.body.file.buf.nc, TRUE);
	w.body.insert(0, s, len s, TRUE, 0);
	w.nomark = 0;
	w.body.file.mod = FALSE;
	w.dirty = FALSE;
	w.body.q0 = w.body.q1 = 0;
}

bodytext(w: ref Window): string
{
	nc := w.body.file.buf.nc;
	if(nc <= 0)
		return "";
	r := stralloc(nc);
	w.body.file.buf.read(0, r, 0, nc);
	s := r.s[0:nc];
	strfree(r);
	return s;
}

# The style a flowing document is set in: the window's fonts and colours
style(w: ref Window, width: int): ref Docengine->Style
{
	cols := w.body.frame.cols;
	accent := xenith->accentcol;
	if(accent == nil)
		accent = cols[TEXT];
	return ref Docengine->Style(width, getfont(0), getfont(1),
		cols[TEXT], cols[BACK], accent, xenith->tagcols[BACK]);
}

getfont(i: int): ref Font
{
	names := xenith->fontnames;
	if(fonts == nil){
		fonts = array[len names] of ref Font;
		fontsfor = array[len names] of string;
	}
	if(i >= len names || i >= len fonts)
		return graph->font;
	if(fonts[i] == nil || fontsfor[i] != names[i]){
		fonts[i] = Font.open(display, names[i]);
		fontsfor[i] = names[i];
		if(fonts[i] == nil)
			fonts[i] = graph->font;
	}
	return fonts[i];
}

# The width a flowing document is set to: the view's, at its scale
flowwidth(w: ref Window, d: ref Doc): int
{
	vw := w.body.frame.r.dx();
	if(d.scale > 0 && d.scale != 100)
		vw = vw * 100 / d.scale;
	if(vw < 50)
		vw = 50;
	return vw;
}

# ---- going back to the text ----

render(w: ref Window): string
{
	d := w.doc;
	if(d == nil){
		name := w.body.file.name;
		k := kind(name);
		if(k == nil)
			return "not a document";
		return open(w, name, k);
	}
	if(d.shown){
		hide(w);
		return nil;
	}
	if(d.kind != nil && d.kind.class == Docreg->Source && !d.web)
		return open(w, d.name, d.kind);
	d.shown = 1;
	hideframe(w);
	draw(w);
	w.settag();
	return nil;
}

# The text instead of the document, from the passage it was showing;
# a source document is dropped (its text may change), a binary
# document or a page kept to be shown again
hide(w: ref Window)
{
	d := w.doc;
	if(d == nil)
		return;
	line := -1;
	if(d.h >= 0 && d.kind != nil && d.kind.class == Docreg->Source){
		n := sheetat(d, d.org.y);
		y := 0;
		if(n >= 0 && n < len d.tops)
			y = (d.org.y - d.tops[n]) * 100 / d.scale;
		line = d.eng->lineat(d.h, n, y);
	}
	if(d.kind == nil || d.kind.class == Docreg->Source && !d.web)
		drop(w);
	else
		d.shown = 0;
	org := 0;
	if(line > 0)
		org = charofline(w.body, line);
	showframe(w, org);
}

close(w: ref Window)
{
	if(w.doc == nil)
		return;
	drop(w);
	showframe(w, 0);
}

release(w: ref Window)
{
	drop(w);
}

# The document let go: its engine's session closed, its work dropped
drop(w: ref Window)
{
	d := w.doc;
	if(d == nil)
		return;
	if(d.eng != nil && d.h >= 0)
		d.eng->close(d.h);
	d.h = -1;
	d.gen = -1;
	d.cache = nil;
	w.doc = nil;
}

# The body's text frame drawn off screen, its tick gone
hideframe(w: ref Window)
{
	f := w.body.frame;
	if(f.ticked)
		framem->frtick(f, framem->frptofchar(f, f.p0), 0);
	f.tick = nil;
	d := w.doc;
	if(d == nil)
		return;
	if(d.offb == nil || !d.offb.r.eq(w.body.all))
		d.offb = display.newimage(w.body.all, mainwin.chans, 0, Draw->Nofill);
	if(d.offb != nil)
		f.b = d.offb;
}

# The text frame on the screen again, from character org
showframe(w: ref Window, org: int)
{
	w.body.frame.b = mainwin;
	w.body.org = org;
	w.body.lastsr = Rect((0, 0), (0, 0));
	framem->frinittick(w.body.frame);
	framem->frdelete(w.body.frame, 0, w.body.frame.nchars);
	w.body.redraw(w.body.frame.r, w.body.frame.font, mainwin, -1);
	w.body.fill();
	scrl->scrdraw(w.body);
	w.settag();
}

# A source document's text changed while shown: set again, in place
textchanged(w: ref Window)
{
	d := w.doc;
	if(d == nil || !d.shown || d.web || d.kind == nil || d.kind.class != Docreg->Source)
		return;
	org := d.org;
	scale := d.scale;
	open(w, d.name, d.kind);
	if(w.doc != nil){
		w.doc.org = org;
		w.doc.scale = scale;
	}
}

# ---- layout ----

measure(d: ref Doc)
{
	n := d.eng->nsheets(d.h);
	d.sizes = array[n] of Point;
	for(i := 0; i < n; i++)
		d.sizes[i] = d.eng->sheetsize(d.h, i);
}

maxdim(d: ref Doc): int
{
	m := 1;
	for(i := 0; i < len d.sizes; i++){
		if(d.sizes[i].x > m)
			m = d.sizes[i].x;
		if(d.sizes[i].y > m && !flowing(d))
			m = d.sizes[i].y;
	}
	return m;
}

clampscale(d: ref Doc, s: int): int
{
	if(s < MINSCALE)
		s = MINSCALE;
	if(!flowing(d)){
		m := maxdim(d);
		if(m * s / 100 > MAXDIM)
			s = MAXDIM * 100 / m;
	}else if(s > 800)
		s = 800;
	if(s < 1)
		s = 1;
	return s;
}

# The scale a fit gives, for the view's size
fitscale(d: ref Doc, vw, vh: int): int
{
	if(len d.sizes == 0)
		return d.scale;
	maxw := 1;
	for(i := 0; i < len d.sizes; i++)
		if(d.sizes[i].x > maxw)
			maxw = d.sizes[i].x;
	vw -= 2*GAP;
	vh -= 2*GAP;
	if(vw < 10)
		vw = 10;
	if(vh < 10)
		vh = 10;
	s := vw * 100 / maxw;
	if(d.fit == Fitpage){
		first := d.sizes[0];
		if(first.y > 0 && vh * 100 / first.y < s)
			s = vh * 100 / first.y;
	}
	return clampscale(d, s);
}

layout(d: ref Doc)
{
	pad := GAP;
	if(flowing(d))
		pad = 0;
	n := len d.sizes;
	d.tops = array[n] of int;
	y := pad;
	w := 0;
	for(i := 0; i < n; i++){
		d.tops[i] = y;
		y += d.sizes[i].y * d.scale / 100 + pad;
		if((sw := d.sizes[i].x * d.scale / 100) > w)
			w = sw;
	}
	d.colw = w + 2*pad;
	d.colh = y;
}

# Scale and layout for the window as it is now: a flowing document set
# again to its width, a fitted one scaled again, keeping its place
setlayout(w: ref Window, d: ref Doc)
{
	fr := w.body.frame.r;
	frac := 0;
	if(d.colh > 0)
		frac = d.org.y * 1000 / d.colh;
	if(flowing(d)){
		cols := w.body.frame.cols;
		if(d.vw != fr.dx() || d.bg != cols[BACK] || d.fg != cols[TEXT] || d.accent != xenith->accentcol){
			d.bg = cols[BACK];
			d.fg = cols[TEXT];
			d.accent = xenith->accentcol;
			d.eng->restyle(d.h, style(w, flowwidth(w, d)));
			measure(d);
			d.cache = nil;
		}
	}else if(d.fit != Fitnone){
		s := fitscale(d, fr.dx(), fr.dy());
		if(s != d.scale){
			d.scale = s;
			d.word = nil;
		}
	}
	d.vw = fr.dx();
	d.vh = fr.dy();
	layout(d);
	if(d.colh > 0)
		d.org.y = frac * d.colh / 1000;
}

# The sheet at y in the column (the last whose top is at or above it)
sheetat(d: ref Doc, y: int): int
{
	# the tops rise down the column: halve it (a document of twenty
	# thousand pages is drawn on every scroll)
	lo := 0;
	hi := len d.tops - 1;
	while(lo < hi){
		m := (lo + hi + 1) / 2;
		if(d.tops[m] <= y + GAP)
			lo = m;
		else
			hi = m - 1;
	}
	return lo;
}

# Where sheet n is on the screen
sheetrect(w: ref Window, d: ref Doc, n: int): Rect
{
	fr := w.body.frame.r;
	sw := d.sizes[n].x * d.scale / 100;
	sh := d.sizes[n].y * d.scale / 100;
	x := (d.colw - sw) / 2;
	if(d.colw < fr.dx())
		x += (fr.dx() - d.colw) / 2;
	else
		x -= d.org.x;
	y := d.tops[n] - d.org.y;
	return Rect((fr.min.x + x, fr.min.y + y), (fr.min.x + x + sw, fr.min.y + y + sh));
}

clamporg(w: ref Window, d: ref Doc)
{
	fr := w.body.frame.r;
	mx := d.colw - fr.dx();
	my := d.colh - fr.dy();
	if(mx < 0)
		mx = 0;
	if(my < 0)
		my = 0;
	if(d.org.x > mx)
		d.org.x = mx;
	if(d.org.y > my)
		d.org.y = my;
	if(d.org.x < 0)
		d.org.x = 0;
	if(d.org.y < 0)
		d.org.y = 0;
}

# ---- drawing ----

draw(w: ref Window)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	fr := w.body.frame.r;
	cols := w.body.frame.cols;
	hideframe(w);
	if(d.h < 0){
		mainwin.draw(fr, cols[BACK], nil, Point(0, 0));
		msg := "Loading " + d.name;
		if(d.err != nil)
			msg = d.name + ": " + d.err;
		mainwin.text(fr.min.add(Point(10, 10)), cols[TEXT], Point(0, 0), graph->font, msg);
		d.colh = 0;
		scrollbar(w);
		return;
	}
	if(d.vw != fr.dx() || d.vh != fr.dy() || flowing(d) && (d.bg != cols[BACK] || d.fg != cols[TEXT] || d.accent != xenith->accentcol))
		setlayout(w, d);
	clamporg(w, d);

	oclip := mainwin.clipr;
	mainwin.clipr = fr;
	mainwin.draw(fr, cols[BACK], nil, Point(0, 0));
	for(n := sheetat(d, d.org.y); n < len d.sizes; n++){
		sr := sheetrect(w, d, n);
		if(sr.max.y <= fr.min.y)
			continue;
		if(sr.min.y >= fr.max.y)
			break;
		paintsheet(w, d, n, sr, fr);
	}
	marks(w, d);
	mainwin.clipr = oclip;
	scrollbar(w);
	requestpaint(w);
}

# Sheet n, at sr on the screen, the part of it in fr
paintsheet(w: ref Window, d: ref Doc, n: int, sr, fr: Rect)
{
	(vis, ok) := sr.clip(fr);
	if(!ok)
		return;
	scalable := d.eng->scalable(d.h);
	if(!scalable && d.scale == 100){
		# straight onto the screen
		if((err := d.eng->paint(d.h, n, 100, mainwin, vis, vis.min.sub(sr.min))) != nil)
			blank(vis);
		return;
	}
	if(!scalable && flowing(d)){
		# zoomed: the part in view, at 100, scaled up
		pr := Rect(vis.min.sub(sr.min).mul(100).div(d.scale), vis.max.sub(sr.min).mul(100).div(d.scale));
		if(pr.dx() <= 0 || pr.dy() <= 0)
			return;
		im := display.newimage(Rect((0, 0), (pr.dx(), pr.dy())), mainwin.chans, 0, Draw->White);
		if(im == nil || d.eng->paint(d.h, n, 100, im, im.r, pr.min) != nil){
			blank(vis);
			return;
		}
		quickdraw(mainwin, vis, im, im.r);
		return;
	}
	if((p := cached(d, n, d.scale)) != nil){
		mainwin.draw(vis, p.im, nil, p.im.r.min.add(vis.min.sub(sr.min)));
		return;
	}
	# meanwhile: a painting at another scale, scaled; or a blank sheet
	for(l := d.cache; l != nil; l = tl l){
		p = hd l;
		if(p.n == n && p.im != nil){
			sw := sr.dx();
			sh := sr.dy();
			if(sw <= 0 || sh <= 0)
				break;
			pw := p.im.r.dx();
			ph := p.im.r.dy();
			src := Rect(vis.min.sub(sr.min), vis.max.sub(sr.min));
			src = Rect((src.min.x * pw / sw, src.min.y * ph / sh), (src.max.x * pw / sw, src.max.y * ph / sh));
			quickdraw(mainwin, vis, p.im, src.addpt(p.im.r.min));
			return;
		}
	}
	blank(vis);
}

blank(r: Rect)
{
	mainwin.draw(r, display.white, nil, Point(0, 0));
}

cached(d: ref Doc, n, scale: int): ref Painted
{
	for(l := d.cache; l != nil; l = tl l)
		if((hd l).n == n && (hd l).scale == scale)
			return hd l;
	return nil;
}

# src of im drawn into r, scaled by nearest neighbour, in a draw a
# row and a draw a column: fast enough to show while the real painting
# is made
quickdraw(dst: ref Image, r: Rect, im: ref Image, src: Rect)
{
	rw := r.dx();
	rh := r.dy();
	sw := src.dx();
	sh := src.dy();
	if(rw <= 0 || rh <= 0 || sw <= 0 || sh <= 0)
		return;
	if(rw == sw && rh == sh){
		dst.draw(r, im, nil, src.min);
		return;
	}
	# rows first, into an image as wide as the source part
	t := display.newimage(Rect((0, 0), (sw, rh)), im.chans, 0, Draw->Nofill);
	if(t == nil)
		return;
	for(y := 0; y < rh; y++)
		t.draw(Rect((0, y), (sw, y+1)), im, nil, Point(src.min.x, src.min.y + y * sh / rh));
	for(x := 0; x < rw; x++)
		dst.draw(Rect((r.min.x + x, r.min.y), (r.min.x + x + 1, r.max.y)), t, nil, Point(x * sw / rw, 0));
}

# The word selected and what a search found, marked on the drawing
marks(w: ref Window, d: ref Doc)
{
	col := xenith->accentcol;
	if(col == nil)
		col = w.body.frame.cols[TEXT];
	if(d.word != nil){
		(n, r) := d.wordat;
		mark(w, d, n, r, col);
	}
	if(d.found == nil)
		return;
	# what was found on the sheets in view
	fr := w.body.frame.r;
	for(n := sheetat(d, d.org.y); n < len d.sizes; n++){
		sr := sheetrect(w, d, n);
		if(sr.min.y >= fr.max.y)
			break;
		if(sr.max.y > fr.min.y && isfound(d, n))
			for(rl := foundon(d, n); rl != nil; rl = tl rl)
				mark(w, d, n, hd rl, col);
	}
}

isfound(d: ref Doc, n: int): int
{
	for(l := d.found; l != nil; l = tl l)
		if(hd l == n)
			return 1;
		else if(hd l > n)
			return 0;
	return 0;
}

# Where on sheet n the search's string is: the words that have it
# (or a phrase's first word), at scale 100
foundon(d: ref Doc, n: int): list of Rect
{
	runs := d.eng->runs(d.h, n);
	r: list of Rect;
	for(i := len runs - 1; i >= 0; i--)
		if(contains(lower(runs[i].text), d.findstr))
			r = runs[i].r :: r;
	if(r == nil){
		(nil, f) := sys->tokenize(d.findstr, " \t");
		if(f != nil)
			for(i = len runs - 1; i >= 0; i--)
				if(contains(lower(runs[i].text), hd f))
					r = runs[i].r :: r;
	}
	return r;
}

mark(w: ref Window, d: ref Doc, n: int, r: Rect, col: ref Image)
{
	if(n < 0 || n >= len d.sizes)
		return;
	sr := sheetrect(w, d, n);
	s := d.scale;
	rr := Rect(r.min.mul(s).div(100), r.max.mul(s).div(100)).addpt(sr.min).inset(-1);
	mainwin.border(rr, 2, col, Point(0, 0));
}

# The scroll bar's thumb where the view is in the column
scrollbar(w: ref Window)
{
	d := w.doc;
	sr := w.body.scrollr;
	cols := w.body.frame.cols;
	if(sr.dy() <= 0)
		return;
	mainwin.draw(sr, cols[BORD], nil, Point(0, 0));
	total := d.colh;
	h := w.body.frame.r.dy();
	if(total > 0){
		oy := d.org.y;
		y0 := sr.min.y + sr.dy() * oy / total;
		bot := oy + h;
		if(bot > total)
			bot = total;
		y1 := sr.min.y + sr.dy() * bot / total;
		if(y1 < y0 + 2)
			y1 = y0 + 2;
		mainwin.draw(Rect((sr.min.x, y0), (sr.max.x - 1, y1)), cols[BACK], nil, Point(0, 0));
		mainwin.draw(Rect((sr.max.x - 1, y0), (sr.max.x, y1)), cols[BORD], nil, Point(0, 0));
	}
	w.body.lastsr = Rect((0, 0), (0, 0));	# scrdraw redraws for the text
}

# ---- painting, off the main loop ----

# The first sheet in or next to the view that has no painting at the
# view's scale, painted: one at a time for a window
requestpaint(w: ref Window)
{
	d := w.doc;
	if(d == nil || d.h < 0 || d.painting)
		return;
	scalable := d.eng->scalable(d.h);
	if(!scalable && (d.scale == 100 || flowing(d)))
		return;
	fr := w.body.frame.r;
	first := -1;
	last := -1;
	for(n := sheetat(d, d.org.y); n < len d.sizes; n++){
		sr := sheetrect(w, d, n);
		if(sr.min.y >= fr.max.y)
			break;
		if(sr.max.y <= fr.min.y)
			continue;
		if(first < 0)
			first = n;
		last = n;
	}
	if(first < 0)
		return;
	prune(d, first - 1, last + 1);
	for(n = first; n <= last + 1 && n < len d.sizes; n++){
		if(cached(d, n, d.scale) != nil)
			continue;
		sz := Point(d.sizes[n].x * d.scale / 100, d.sizes[n].y * d.scale / 100);
		if(sz.x <= 0 || sz.y <= 0 || sz.x > MAXDIM || sz.y > MAXDIM)
			continue;
		d.painting = 1;
		spawn painter(w.id, d.gen, d.eng, d.h, n, d.scale, scalable, d.sizes[n]);
		return;
	}
}

# Paintings kept: the view's scale for sheets first..last; one at
# another scale for those, to show until theirs is painted
prune(d: ref Doc, first, last: int)
{
	keep: list of ref Painted;
	for(l := d.cache; l != nil; l = tl l){
		p := hd l;
		if(p.n < first || p.n > last)
			continue;
		if(p.scale != d.scale && (cached(d, p.n, d.scale) != nil || otherkept(keep, p.n)))
			continue;
		keep = p :: keep;
	}
	d.cache = keep;
}

otherkept(l: list of ref Painted, n: int): int
{
	for(; l != nil; l = tl l)
		if((hd l).n == n)
			return 1;
	return 0;
}

painter(winid, gen: int, eng: Docengine, h, n, scale, scalable: int, size: Point)
{
	err: string;
	sz := Point(size.x * scale / 100, size.y * scale / 100);
	im: ref Image;
	{
		if(scalable){
			# painted at the scale: the engine places and smooths
			# what it draws at the image's resolution
			im = display.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->White);
			if(im == nil)
				err = sprint("no image: %r");
			else
				err = eng->paint(h, n, scale, im, im.r, Point(0, 0));
		}else{
			full := display.newimage(Rect((0, 0), size), mainwin.chans, 0, Draw->White);
			if(full == nil)
				err = sprint("no image: %r");
			else if((err = eng->paint(h, n, 100, full, full.r, Point(0, 0))) == nil)
				im = boxscale(full, sz);
		}
	} exception e {
	"*" =>
		err = "paint: " + e;
	}
	if(err != nil)
		im = nil;
	send(ref AsyncMsg.DocPainted(winid, gen, n, scale, im, err));
}

painted(w: ref Window, gen: int, n, scale: int, im: ref Image, err: string)
{
	d := w.doc;
	if(d == nil || d.gen != gen)
		return;
	d.painting = 0;
	if(err != nil){
		warning(nil, sprint("%s: page %d: %s\n", d.name, n+1, err));
		# not asked again at this scale
		d.cache = ref Painted(n, scale, nil) :: d.cache;
		return;
	}
	d.cache = ref Painted(n, scale, im) :: d.cache;
	if(d.shown)
		draw(w);
}

# im scaled to sz, averaging the pixels each new one covers (smooth,
# for an image made smaller), or repeating them (made larger)
boxscale(im: ref Image, sz: Point): ref Image
{
	iw := im.r.dx();
	ih := im.r.dy();
	if(sz.x <= 0 || sz.y <= 0)
		return nil;
	if(sz.x >= iw && sz.y >= ih){
		out := display.newimage(Rect((0, 0), sz), im.chans, 0, Draw->Nofill);
		if(out != nil)
			quickdraw(out, out.r, im, im.r);
		return out;
	}
	src := im;
	if(!src.chans.eq(Draw->RGB24)){
		rgb := display.newimage(src.r, Draw->RGB24, 0, Draw->Black);
		if(rgb != nil){
			rgb.draw(rgb.r, src, nil, src.r.min);
			src = rgb;
		}
	}
	out := display.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->Black);
	if(out == nil)
		return nil;
	rowbuf := array[iw * 3] of byte;
	outrow := array[sz.x * 3] of byte;
	acc := array[sz.x * 3] of int;
	cnt := array[sz.x] of int;
	for(oy := 0; oy < sz.y; oy++){
		y0 := oy * ih / sz.y;
		y1 := (oy + 1) * ih / sz.y;
		if(y1 <= y0)
			y1 = y0 + 1;
		for(i := 0; i < len acc; i++)
			acc[i] = 0;
		for(i = 0; i < len cnt; i++)
			cnt[i] = 0;
		for(y := y0; y < y1 && y < ih; y++){
			src.readpixels(Rect((src.r.min.x, src.r.min.y + y), (src.r.max.x, src.r.min.y + y + 1)), rowbuf);
			for(ox := 0; ox < sz.x; ox++){
				x0 := ox * iw / sz.x;
				x1 := (ox + 1) * iw / sz.x;
				if(x1 <= x0)
					x1 = x0 + 1;
				for(x := x0; x < x1 && x < iw; x++){
					acc[ox*3] += int rowbuf[x*3];
					acc[ox*3+1] += int rowbuf[x*3+1];
					acc[ox*3+2] += int rowbuf[x*3+2];
					cnt[ox]++;
				}
			}
		}
		for(ox := 0; ox < sz.x; ox++){
			c := cnt[ox];
			if(c < 1)
				c = 1;
			outrow[ox*3] = byte (acc[ox*3] / c);
			outrow[ox*3+1] = byte (acc[ox*3+1] / c);
			outrow[ox*3+2] = byte (acc[ox*3+2] / c);
		}
		out.writepixels(Rect((0, oy), (sz.x, oy + 1)), outrow);
	}
	return out;
}

# ---- moving about ----

scroll(w: ref Window, dy: int)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	d.org.y += dy;
	draw(w);
}

wheel(w: ref Window, buttons: int)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	step := w.body.frame.font.height * 3;
	if(buttons & 8)
		step = -step;
	scroll(w, step);
}

# A click on the scroll bar, as acme's: 1 back and 3 on by the distance
# from its top, 2 to that point in the column
scrollclick(w: ref Window, but: int, y: int)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	sr := w.body.scrollr;
	off := y - sr.min.y;
	case but {
	1 =>	scroll(w, -off);
	3 =>	scroll(w, off);
	2 =>
		if(sr.dy() > 0){
			d.org.y = d.colh * off / sr.dy();
			draw(w);
		}
	}
}

key(w: ref Window, r: int): int
{
	d := w.doc;
	if(d == nil || !d.shown)
		return 0;
	if(d.h >= 0 && (res := d.eng->key(d.h, r)) != nil){
		result(w, d, res);
		return 1;
	}
	h := w.body.frame.r.dy();
	lh := w.body.frame.font.height;
	case r {
	Dat->Kscrolldown or Keyboard->Down =>	scroll(w, lh * 3);
	Dat->Kscrollup or Keyboard->Up =>	scroll(w, -lh * 3);
	Keyboard->Pgdown =>	scroll(w, h - lh);
	Keyboard->Pgup =>	scroll(w, -(h - lh));
	Keyboard->Home =>	scroll(w, -(1<<30));
	Keyboard->End =>	scroll(w, 1<<30);
	* =>
		if(readonly(w))
			return 1;	# a binary document's text is not typed into
		hide(w);	# typing goes to the text
		return 0;
	}
	return 1;
}

# What an engine's click or key asks for
result(w: ref Window, d: ref Doc, res: string)
{
	(verb, rest) := split(res);
	case verb {
	"layout" =>
		measure(d);
		layout(d);
	"show" =>
		(nil, l) := sys->tokenize(rest, " ");
		if(l != nil && tl l != nil){
			y0 := int hd l * d.scale / 100;
			y1 := int hd tl l * d.scale / 100;
			h := w.body.frame.r.dy();
			if(len d.tops > 0)
				(y0, y1) = (y0 + d.tops[0], y1 + d.tops[0]);
			if(y0 < d.org.y || y1 > d.org.y + h)
				d.org.y = y0 - h / 3;
		}
	"error" =>
		warning(nil, sprint("%s: %s\n", d.name, rest));
	}
	draw(w);
}

# The sheet and the point on it (scale 100) under p on the screen
at(w: ref Window, d: ref Doc, p: Point): (int, Point)
{
	fr := w.body.frame.r;
	for(n := sheetat(d, d.org.y + p.y - fr.min.y); n >= 0 && n < len d.sizes; n--){
		sr := sheetrect(w, d, n);
		if(p.in(sr))
			return (n, p.sub(sr.min).mul(100).div(d.scale));
		if(sr.max.y < p.y)
			break;
	}
	return (-1, Point(0, 0));
}

frgetmouse()
{
	bflush();
	*mouse = *<-dat->cmouse;
}

# Button 1: the document dragged (grab and pan); clicked, not moved,
# the page's click, or the word there selected
button1(w: ref Window)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	p0 := mouse.xy;
	o0 := d.org;
	moved := 0;
	while(mouse.buttons & 1){
		dp := p0.sub(mouse.xy);
		if(dp.x != 0 || dp.y != 0)
			moved = 1;
		if(moved){
			d.org = o0.add(dp);
			draw(w);
		}
		frgetmouse();
	}
	if(moved || d.h < 0)
		return;
	(n, p) := at(w, d, p0);
	if(n < 0)
		return;
	if((res := d.eng->click(d.h, n, p)) != nil){
		result(w, d, res);
		return;
	}
	(word, r, k) := wordat(d, n, p);
	d.word = word;
	d.wordat = (n, r);
	if(word != nil)
		selectword(w, d, n, k, word);
	draw(w);
}

# The word clicked on the drawing selected in the window's text too,
# so Snarf, Look and the rest take it: the occurrence of it whose
# place among its kind matches its place among the words drawn (the
# text and the drawing go in the same order)
selectword(w: ref Window, d: ref Doc, n, k: int, word: string)
{
	nth := 0;
	for(m := 0; m <= n; m++){
		runs := d.eng->runs(d.h, m);
		last := len runs;
		if(m == n)
			last = k;
		for(i := 0; i < last; i++)
			if(runs[i].text == word)
				nth++;
	}
	text := bodytext(w);
	q := -1;
	for(i := 0; i + len word <= len text; i++)
		if(text[i:i+len word] == word){
			q = i;
			if(nth-- == 0)
				break;
		}
	if(q < 0)
		return;
	w.body.q0 = q;
	w.body.q1 = q + len word;
	w.body.file.curtext = w.body;
	dat->seltext = w.body;
	dat->argtext = w.body;
}

# Button 2: the word there, to be executed
button2(w: ref Window): (string, int)
{
	d := w.doc;
	if(d == nil || !d.shown || d.h < 0)
		return (nil, 0);
	p0 := mouse.xy;
	while(mouse.buttons)
		frgetmouse();
	(n, p) := at(w, d, p0);
	if(n < 0)
		return (nil, 0);
	(word, nil, nil) := wordat(d, n, p);
	return (word, word != nil);
}

# Button 3: the link there, or the word to be looked at; on a page
# browsed, the page's click
button3(w: ref Window): (string, string)
{
	d := w.doc;
	if(d == nil || !d.shown || d.h < 0)
		return (nil, nil);
	p0 := mouse.xy;
	while(mouse.buttons)
		frgetmouse();
	(n, p) := at(w, d, p0);
	if(n < 0)
		return (nil, nil);
	if(d.web){
		if((res := d.eng->click(d.h, n, p)) != nil)
			result(w, d, res);
		return (nil, nil);
	}
	if((u := d.eng->linkat(d.h, n, p)) != nil)
		return (u, nil);
	(word, nil, nil) := wordat(d, n, p);
	return (nil, word);
}

# The word at p on sheet n, where it is, and which of the sheet's
# words it is, from the engine's runs
wordat(d: ref Doc, n: int, p: Point): (string, Rect, int)
{
	runs := d.eng->runs(d.h, n);
	for(i := 0; i < len runs; i++)
		if(p.in(runs[i].r))
			return (runs[i].text, runs[i].r, i);
	return (nil, Rect((0, 0), (0, 0)), -1);
}

# ---- commands ----

zoom(w: ref Window, d: ref Doc, s: int)
{
	s = clampscale(d, s);
	if(s == d.scale)
		return;
	fr := w.body.frame.r;
	# the point at the top of the view, in the middle, stays
	cx := d.org.x + fr.dx() / 2;
	cy := d.org.y;
	old := d.scale;
	d.scale = s;
	d.fit = Fitnone;
	d.word = nil;
	if(flowing(d)){
		frac := 0;
		if(d.colh > 0)
			frac = cy * 1000 / d.colh;
		d.eng->restyle(d.h, style(w, flowwidth(w, d)));
		measure(d);
		layout(d);
		d.org = Point(0, frac * d.colh / 1000);
	}else{
		layout(d);
		d.org = Point(cx * s / old - fr.dx() / 2, cy * s / old);
	}
	draw(w);
}

gotosheet(w: ref Window, d: ref Doc, n: int)
{
	if(n < 0)
		n = 0;
	if(n >= len d.tops)
		n = len d.tops - 1;
	if(n < 0)
		return;
	d.org.y = d.tops[n] - GAP;
	draw(w);
}

command(w: ref Window, cmd, arg: string): (int, string)
{
	d := w.doc;
	if(d == nil)
		return (0, nil);
	if(d.h < 0)
		return (1, "not loaded yet");
	case cmd {
	"Zoom+" =>
		zoom(w, d, d.scale * 5 / 4 + 1);
	"Zoom-" =>
		zoom(w, d, d.scale * 4 / 5);
	"Zoom" =>
		if(arg == nil)
			return (1, "Zoom: percent?");
		zoom(w, d, int arg);
	"Fit" =>
		if(flowing(d)){
			zoom(w, d, 100);
			return (1, nil);
		}
		d.fit = Fitwidth;
		if(arg == "page")
			d.fit = Fitpage;
		d.vw = d.vh = 0;
		d.word = nil;
		draw(w);
	"Page" =>
		if(arg == nil)
			return (1, "Page: which?");
		gotosheet(w, d, int arg - 1);
	"NextPage" =>
		gotosheet(w, d, sheetat(d, d.org.y) + 1);
	"PrevPage" =>
		gotosheet(w, d, sheetat(d, d.org.y) - 1);
	* =>
		for(l := d.eng->commands(d.h); l != nil; l = tl l)
			if(hd l == cmd)
				return (1, d.eng->command(d.h, cmd, arg));
		return (0, nil);
	}
	return (1, nil);
}

# The view's commands for the tag
commands(w: ref Window): string
{
	d := w.doc;
	if(d == nil || !d.shown)
		return nil;
	s := "";
	if(d.web){
		# no engine until the page is open (Charon, loaded for the first
		# page, takes a while): the tag is set before then
		if(d.h >= 0)
			for(l := d.eng->commands(d.h); l != nil; l = tl l)
				s += " " + hd l;
		return s;
	}
	s = " Zoom+ Zoom- Fit";
	if(len d.sizes > 1)
		s += " PrevPage NextPage";
	if(d.h >= 0)
		for(l := d.eng->commands(d.h); l != nil; l = tl l)
			s += " " + hd l;
	return s;
}

# ---- the document's files ----

ctlread(w: ref Window): string
{
	d := w.doc;
	if(d == nil)
		return nil;
	class := "binary";
	if(d.web)
		class = "web";
	else if(d.kind != nil && d.kind.class == Docreg->Source)
		class = "source";
	kind := "";
	if(d.kind != nil)
		kind = d.kind.name;
	s := sprint("kind %s\nclass %s\nname %s\n", kind, class, d.name);
	if(d.h < 0){
		if(d.err != nil)
			return s + "error " + d.err + "\n";
		return s + "loading\n";
	}
	fr := w.body.frame.r;
	fit := "none";
	if(d.fit == Fitwidth)
		fit = "width";
	else if(d.fit == Fitpage)
		fit = "page";
	s += sprint("shown %d\nsheets %d\nsheet %d\nscale %d\nfit %s\n", d.shown, len d.sizes, sheetat(d, d.org.y) + 1, d.scale, fit);
	s += sprint("view %d %d %d %d\n", d.org.x, d.org.y, fr.dx(), fr.dy());
	s += sprint("screen %d %d %d %d\n", fr.min.x, fr.min.y, fr.max.x, fr.max.y);
	s += sprint("column %d %d\n", d.colw, d.colh);
	return s;
}

ctlwrite(w: ref Window, s: string): string
{
	d := w.doc;
	if(d == nil){
		# a window showing its text: render shows the file as the
		# document it is
		if(s == "render")
			return render(w);
		return "no document";
	}
	(nil, l) := sys->tokenize(s, " \t\n");
	if(l == nil)
		return nil;
	cmd := hd l;
	arg := "";
	if(tl l != nil)
		arg = hd tl l;
	case cmd {
	"sheet" =>
		(nil, err) := command(w, "Page", arg);
		return err;
	"scale" =>
		(nil, err) := command(w, "Zoom", arg);
		return err;
	"fit" =>
		(nil, err) := command(w, "Fit", arg);
		return err;
	"scroll" =>
		scroll(w, int arg);
	"render" =>
		if(!d.shown)
			return render(w);
	"text" =>
		if(d.shown)
			hide(w);
	* =>
		(ok, err) := command(w, cmd, arg);
		if(!ok)
			return "bad doc ctl: " + cmd;
		return err;
	}
	return nil;
}

textread(w: ref Window): string
{
	d := w.doc;
	if(d == nil || d.h < 0)
		return nil;
	return d.eng->text(d.h);
}

linksread(w: ref Window): string
{
	d := w.doc;
	if(d == nil || d.h < 0)
		return nil;
	s := "";
	l := d.eng->links(d.h);
	for(i := 0; i < len l; i++){
		r := l[i].r;
		s += sprint("%d %d %d %d %d %s\n", l[i].sheet + 1, r.min.x, r.min.y, r.max.x, r.max.y, l[i].url);
	}
	return s;
}

# s found on the drawing, marked; nil, or why not.  The sheets that
# have it are found by their text; where on them, by their words, only
# for a sheet shown (a document's words are many, its text is at hand).
find(w: ref Window, s: string): string
{
	d := w.doc;
	if(d == nil || d.h < 0)
		return "no document";
	d.found = nil;
	d.findstr = nil;
	if(s == nil){
		draw(w);
		return nil;
	}
	ls := lower(s);
	f: list of int;
	for(n := len d.sizes - 1; n >= 0; n--){
		t := d.eng->sheettext(d.h, n);
		if(t == nil){
			# an engine without a sheet's text: its words
			runs := d.eng->runs(d.h, n);
			for(i := 0; i < len runs; i++)
				t += runs[i].text + " ";
		}
		if(contains(lower(t), ls))
			f = n :: f;
	}
	if(f == nil)
		return "not found";
	d.found = f;
	d.findstr = ls;
	n = hd f;
	y := d.tops[n];
	if((rl := foundon(d, n)) != nil)
		y += (hd rl).min.y * d.scale / 100;
	h := w.body.frame.r.dy();
	if(y < d.org.y || y > d.org.y + h)
		d.org.y = y - h / 3;
	draw(w);
	return nil;
}

# Where the search's string is, one place a line: sheet x0 y0 x1 y1,
# for the first MAXFOUND sheets that have it; then each further sheet
# that has it, by its number alone (where on a sheet takes reading
# its words, and a long document's are many).
MAXFOUND: con 100;

foundread(w: ref Window): string
{
	d := w.doc;
	if(d == nil)
		return nil;
	s := "";
	k := 0;
	for(l := d.found; l != nil; l = tl l){
		if(k++ >= MAXFOUND){
			s += sprint("%d\n", hd l + 1);
			continue;
		}
		for(rl := foundon(d, hd l); rl != nil; rl = tl rl){
			r := hd rl;
			s += sprint("%d %d %d %d %d\n", hd l + 1, r.min.x, r.min.y, r.max.x, r.max.y);
		}
	}
	return s;
}

filesof(w: ref Window): string
{
	d := w.doc;
	if(d == nil || d.h < 0)
		return nil;
	return d.eng->files(d.h);
}

# ---- little things ----

split(e: string): (string, string)
{
	for(i := 0; i < len e; i++)
		if(e[i] == ' ')
			return (e[0:i], e[i+1:]);
	return (e, "");
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

contains(s, t: string): int
{
	if(len t == 0)
		return 1;
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

# The line (from 0) holding character q of t
lineof(t: ref Textm->Text, q: int): int
{
	n := 0;
	r := stralloc(4096);
	for(p := 0; p < q; ){
		m := q - p;
		if(m > 4096)
			m = 4096;
		t.file.buf.read(p, r, 0, m);
		for(i := 0; i < m; i++)
			if(r.s[i] == '\n')
				n++;
		p += m;
	}
	strfree(r);
	return n;
}

# The character that starts line n (from 0) of t
charofline(t: ref Textm->Text, n: int): int
{
	if(n <= 0)
		return 0;
	nc := t.file.buf.nc;
	r := stralloc(4096);
	for(p := 0; p < nc; ){
		m := nc - p;
		if(m > 4096)
			m = 4096;
		t.file.buf.read(p, r, 0, m);
		for(i := 0; i < m; i++)
			if(r.s[i] == '\n' && --n == 0){
				strfree(r);
				return p + i + 1;
			}
		p += m;
	}
	strfree(r);
	return nc;
}
