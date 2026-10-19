implement Docview;

#
# A window's document (docs/xenith-documents.md): shown by the view
# every program that shows documents shares (sheetview(2)) in the
# window's body.  This is Xenith's side of it: the window's text (a
# binary document's text, read-only; a source document's source), its
# tag, its doc/ files, the scroll bar, the mouse and the keys.
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
docreg: Docreg;
sheetview: Sheetview;

sprint: import sys;
FALSE, TRUE: import Dat;
Lock: import dat;
mouse: import dat;
Point, Rect, Image, Display, Font: import drawm;
warning, stralloc, strfree: import utils;
bflush: import graph;
mainwin, display: import gui;
Window: import windowm;
Text: import textm;
Buffer: import bufferm;
BACK, BORD, TEXT: import Framem;
Kind: import docreg;
View, Ev, Note, Fitnone, Fitwidth, Fitpage, GAP: import sheetview;

evc: chan of ref Ev;
views: list of (ref View, int);	# each view's window
livec: chan of int;		# an edit: the live task wakes
livewins: list of ref Window;	# windows whose documents wait to be set again
LIVEMS: con 600;		# the pause in editing after which they are
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
	docreg = load Docreg Docreg->PATH;
	if(docreg != nil)
		docreg->init(display);
	sheetview = load Sheetview Sheetview->PATH;
	if(sheetview != nil)
		sheetview->init(display);
	evc = chan of ref Ev;
	livec = chan[1] of int;
	spawn livetask();
}

events(): chan of ref Ev
{
	return evc;
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
	return d != nil && (d.v.web || d.v.kind == nil || d.v.kind.class == Docreg->Binary);
}

# ---- opening ----

open(w: ref Window, name: string, k: ref Kind): string
{
	if(sheetview == nil)
		return "no document view";
	if(k == nil)
		return "not a document";
	# opened again, a binary document keeps its place; a source
	# document opens on the passage its text shows
	org := Point(0, 0);
	if(w.doc != nil && w.doc.v.name == name)
		org = w.doc.v.org;
	drop(w);
	d := newdoc(w, k, name);
	# a source document is the window's text, unsaved changes and
	# all, when it is the window's file; another file is read
	data: array of byte;
	if(k.class == Docreg->Source && name == w.body.file.name){
		data = array of byte bodytext(w);
		d.line = lineof(w.body, w.body.org);
	}
	d.v.org = org;
	hideframe(w);
	draw(w);
	d.v.open(data, name);
	w.settag();
	return nil;
}

browse(w: ref Window, url: string): string
{
	if(sheetview == nil)
		return "no document view";
	d := w.doc;
	if(d != nil && d.v.web && d.v.h >= 0){
		if(!d.shown){
			d.shown = 1;
			hideframe(w);
		}
		return d.v.browse(url);
	}
	k := docreg->kindof("html");
	if(k == nil)
		return "no engine for HTML";
	if(d != nil)
		drop(w);
	d = newdoc(w, k, url);
	w.filemenu = FALSE;
	hideframe(w);
	draw(w);
	return d.v.browse(url);
}

newdoc(w: ref Window, k: ref Kind, name: string): ref Doc
{
	v := sheetview->new(k, name, evc);
	setview(w, v);
	d := ref Doc(v, 1, nil, -1, nil, 1, 0);
	w.doc = d;
	views = (v, w.id) :: views;
	return d;
}

# The view where the window's body is, in its colours and fonts
setview(w: ref Window, v: ref View)
{
	cols := w.body.frame.cols;
	accent := xenith->accentcol;
	if(accent == nil)
		accent = cols[TEXT];
	v.dst = mainwin;
	v.r = w.body.frame.r;
	v.bg = cols[BACK];
	v.mark = accent;
	v.font = graph->font;
	v.style = ref Docengine->Style(0, getfont(0), getfont(1),
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

# The view's work, done off the main loop, for its window
handle(e: ref Ev)
{
	w: ref Window;
	for(l := views; l != nil; l = tl l)
		if((hd l).t0 == e.v){
			w = look->lookid((hd l).t1, 0);
			break;
		}
	if(w == nil || w.col == nil || w.doc == nil || w.doc.v != e.v && w.doc.next != e.v){
		# nothing to show it in
		pick o := e {
		Opened =>
			if(o.eng != nil && o.h >= 0)
				o.eng->close(o.h);
		}
		return;
	}
	# What the document does to the window (its name, its text) is done
	# with the window locked, as the mouse's work is, and as through its
	# files ('F'). Done with only the row locked, the window's owner was
	# whatever a 9P request for it left, none once it was answered: a
	# program reading the window's events (an Acme client; a script)
	# was sent the page's new text from no one, which Xenith takes for
	# a fault, and quit.
	w.lock('F');
	{
		handle1(w, e);
	} exception {
	"*" =>
		w.unlock();
		raise;
	}
	w.unlock();
}

handle1(w: ref Window, e: ref Ev)
{
	d := w.doc;
	if(e.v == d.next){
		nextevent(w, e);
		return;
	}
	v := d.v;
	setview(w, v);
	note := v.handle(e);
	if(note == nil)
		return;
	pick n := note {
	Opened =>
		if(d.line >= 0 && v.flowing()){
			# a source document: from the line its text was showing
			(s, y) := v.eng->lineto(v.h, d.line);
			v.layout();
			if(s >= 0 && s < len v.tops)
				v.org = Point(0, v.tops[s] + y * v.scale / 100);
			d.line = -1;
		}
		draw(w);
		w.settag();
	Failed =>
		warning(nil, sprint("%s: %s\n", v.name, n.err));
		if(v.kind != nil && v.kind.class == Docreg->Source && !v.web){
			# a source document that cannot be set (one too long
			# for an image of it, say) is its text: shown again,
			# where it was, not hidden behind the error
			line := d.line;
			drop(w);
			org := 0;
			if(line > 0)
				org = charofline(w.body, line);
			showframe(w, org);
			w.settag();
			return;
		}
		draw(w);
	Text =>
		settext(w, n.text);
		draw(w);
	Loaded =>
		# a page loaded: its URL names the window, its text is the window's
		if(n.name != nil && n.name != w.body.file.name)
			w.setname(n.name, len n.name);
		settext(w, n.text);
		draw(w);
		w.settag();
	Error =>
		warning(nil, sprint("%s: %s\n", v.name, n.err));
	Redraw =>
		draw(w);
	}
}

# An event for the view setting the document again: shown in place of
# the old one once it is open, dropped if it cannot be
nextevent(w: ref Window, e: ref Ev)
{
	d := w.doc;
	nv := d.next;
	setview(w, nv);
	note := nv.handle(e);
	if(note == nil)
		return;
	pick n := note {
	Opened =>
		old := d.v;
		d.v = nv;
		d.next = nil;
		dropview(old);
		draw(w);
		w.settag();
	Failed =>
		d.next = nil;
		dropview(nv);
		warning(nil, sprint("%s: %s\n", nv.name, n.err));
	}
}

# What a click or a key's result asks the window for
noted(w: ref Window, n: ref Note)
{
	if(n == nil)
		return;
	pick o := n {
	Error =>
		warning(nil, sprint("%s: %s\n", w.doc.v.name, o.err));
	}
	draw(w);
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
	v := d.v;
	if(v.kind != nil && v.kind.class == Docreg->Source && !v.web)
		return open(w, v.name, v.kind);
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
	v := d.v;
	line := -1;
	if(v.h >= 0 && v.kind != nil && v.kind.class == Docreg->Source){
		n := v.sheetat(v.org.y);
		y := 0;
		if(n >= 0 && n < len v.tops)
			y = (v.org.y - v.tops[n]) * 100 / v.scale;
		line = v.eng->lineat(v.h, n, y);
	}
	if(v.kind == nil || v.kind.class == Docreg->Source && !v.web)
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
	if(d.next != nil)
		dropview(d.next);
	dropview(d.v);
	w.doc = nil;
}

dropview(v: ref View)
{
	v.close();
	nv: list of (ref View, int);
	for(l := views; l != nil; l = tl l)
		if((hd l).t0 != v)
			nv = hd l :: nv;
	views = nv;
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
# The document set again from the window's text, typing and all: when
# the editing pauses (live, edited), when the file is Put, or when
# doc/ctl says refresh.  A new view is opened beside the old,
# which stays on the screen until the new one is open (nextevent).
refresh(w: ref Window): string
{
	d := w.doc;
	if(d == nil || !d.shown || d.v.web || d.v.kind == nil || d.v.kind.class != Docreg->Source)
		return "not a source document shown";
	f := w.body.file;
	for(i := 0; i < f.ntext; i++)
		if(f.text[i].ncache > 0)
			f.text[i].commit(TRUE);
	if(d.next != nil)
		dropview(d.next);
	nv := sheetview->new(d.v.kind, d.v.name, evc);
	setview(w, nv);
	views = (nv, w.id) :: views;
	d.next = nv;
	data: array of byte;
	if(nv.name == f.name)
		data = array of byte bodytext(w);
	nv.open(data, nv.name);
	# the reader's place: where, how large, fitted and turned as before
	nv.org = d.v.org;
	nv.scale = d.v.scale;
	nv.fit = d.v.fit;
	nv.rot = d.v.rot;
	d.liveat = 0;
	return nil;
}

# ---- live: set again as the text is edited ----

# a window's text edited: the windows showing its file as a source
# document (its Zerox twins, or itself) marked, and the live task woken
edited(w: ref Window)
{
	if(w == nil || w.body.file == nil)
		return;
	f := w.body.file;
	marked := 0;
	for(i := 0; i < f.ntext; i++){
		u := f.text[i].w;
		if(u == nil || u.doc == nil)
			continue;
		d := u.doc;
		if(!d.live || !d.shown || d.v.web || d.v.kind == nil || d.v.kind.class != Docreg->Source)
			continue;
		if(d.liveat == 0){
			for(l := livewins; l != nil; l = tl l)
				if(hd l == u)
					break;
			if(l == nil)
				livewins = u :: livewins;
		}
		d.liveat = sys->millisec();
		if(d.liveat == 0)
			d.liveat = 1;
		marked = 1;
	}
	if(marked)
		alt{
		livec <-= 1 =>
			;
		* =>
			;	# already woken
		}
}

# wait for an edit; then, each time the editing has paused LIVEMS,
# set again the documents edited, until none waits
livetask()
{
	for(;;){
		<-livec;
		n := 1;
		while(n > 0){
			sys->sleep(LIVEMS / 3);
			row := dat->row;
			row.qlock.lock();
			n = livedue();
			row.qlock.unlock();
		}
	}
}

# the documents whose editing has paused set again; how many still wait
livedue(): int
{
	now := sys->millisec();
	keep: list of ref Window;
	for(l := livewins; l != nil; l = tl l){
		w := hd l;
		d := w.doc;
		if(d == nil || d.liveat == 0 || !d.live || !d.shown)
			continue;
		if(now - d.liveat < LIVEMS){
			keep = w :: keep;
			continue;
		}
		if((e := refresh(w)) != nil)
			warning(nil, sprint("%s: %s\n", w.body.file.name, e));
	}
	livewins = keep;
	n := 0;
	for(l = keep; l != nil; l = tl l)
		n++;
	return n;
}

# ---- drawing ----

draw(w: ref Window)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	hideframe(w);
	setview(w, d.v);
	d.v.draw();
	scrollbar(w);
	viewing(d.v);
}

# Where the view is, told the engine: a page browsed keeps it for Back
viewing(v: ref View)
{
	if(v.h < 0 || v.eng == nil)
		return;
	n := v.sheetat(v.org.y);
	if(n < 0 || n >= len v.tops)
		return;
	v.eng->viewing(v.h, n, (v.org.y - v.tops[n]) * 100 / v.scale);
}

# The scroll bar's thumb where the view is in the column
scrollbar(w: ref Window)
{
	v := w.doc.v;
	sr := w.body.scrollr;
	cols := w.body.frame.cols;
	if(sr.dy() <= 0)
		return;
	mainwin.draw(sr, cols[BORD], nil, Point(0, 0));
	total := v.colh;
	h := w.body.frame.r.dy();
	if(total > 0){
		oy := v.org.y;
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

# ---- moving about ----

scroll(w: ref Window, dy: int)
{
	d := w.doc;
	if(d == nil || !d.shown)
		return;
	d.v.scroll(dy);
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
	if(off < 0)
		off = 0;
	if(off > sr.dy())
		off = sr.dy();	# (2 dragged past the bar's ends: the top, the end)
	case but {
	1 =>	scroll(w, -off);
	3 =>	scroll(w, off);
	2 =>
		if(sr.dy() > 0){
			d.v.pan(Point(d.v.org.x, d.v.colh * off / sr.dy()));
			draw(w);
		}
	}
}

key(w: ref Window, r: int): int
{
	d := w.doc;
	if(d == nil || !d.shown)
		return 0;
	v := d.v;
	if(v.h >= 0 && (res := v.eng->key(v.h, r)) != nil){
		noted(w, v.result(res));
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
	v := d.v;
	p0 := mouse.xy;
	o0 := v.org;
	moved := 0;
	while(mouse.buttons & 1){
		dp := p0.sub(mouse.xy);
		if(dp.x != 0 || dp.y != 0)
			moved = 1;
		if(moved){
			v.pan(o0.add(dp));
			draw(w);
		}
		frgetmouse();
	}
	if(moved || v.h < 0)
		return;
	(n, p) := v.at(p0);
	if(n < 0)
		return;
	if((res := v.eng->click(v.h, n, p)) != nil){
		noted(w, v.result(res));
		return;
	}
	(word, r, k) := v.wordof(n, p);
	v.select(n, word, r);
	if(word != nil)
		selectword(w, v, n, k, word);
	draw(w);
}

# The word clicked on the drawing selected in the window's text too,
# so Snarf, Look and the rest take it: the occurrence of it whose
# place among its kind matches its place among the words drawn (the
# text and the drawing go in the same order)
selectword(w: ref Window, v: ref View, n, k: int, word: string)
{
	nth := 0;
	for(m := 0; m <= n; m++){
		runs := v.eng->runs(v.h, m);
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
	if(d == nil || !d.shown || d.v.h < 0)
		return (nil, 0);
	p0 := mouse.xy;
	while(mouse.buttons)
		frgetmouse();
	(n, p) := d.v.at(p0);
	if(n < 0)
		return (nil, 0);
	(word, nil, nil) := d.v.wordof(n, p);
	return (word, word != nil);
}

# Button 3: the link there, or the word to be looked at; on a page
# browsed, the page's click
button3(w: ref Window): (string, string)
{
	d := w.doc;
	if(d == nil || !d.shown || d.v.h < 0)
		return (nil, nil);
	v := d.v;
	p0 := mouse.xy;
	while(mouse.buttons)
		frgetmouse();
	(n, p) := v.at(p0);
	if(n < 0)
		return (nil, nil);
	if(v.web){
		if((res := v.eng->click(v.h, n, p)) != nil)
			noted(w, v.result(res));
		return (nil, nil);
	}
	# a link to a page of the document is followed here
	(u, followed) := v.linkat(n, p);
	if(followed){
		draw(w);
		return (nil, nil);
	}
	if(u != nil)
		return (u, nil);
	(word, nil, nil) := v.wordof(n, p);
	return (nil, word);
}

# ---- commands ----

command(w: ref Window, cmd, arg: string): (int, string)
{
	d := w.doc;
	if(d == nil)
		return (0, nil);
	(ok, err) := d.v.command(cmd, arg);
	if(ok)
		draw(w);
	return (ok, err);
}

# The view's commands for the tag
commands(w: ref Window): string
{
	d := w.doc;
	if(d == nil || !d.shown)
		return nil;
	s := "";
	for(l := d.v.commands(); l != nil; l = tl l)
		s += " " + hd l;
	return s;
}

# ---- the document's files ----

ctlread(w: ref Window): string
{
	d := w.doc;
	if(d == nil)
		return nil;
	v := d.v;
	class := "binary";
	if(v.web)
		class = "web";
	else if(v.kind != nil && v.kind.class == Docreg->Source)
		class = "source";
	kind := "";
	if(v.kind != nil)
		kind = v.kind.name;
	s := sprint("kind %s\nclass %s\nname %s\n", kind, class, v.name);
	if(v.h < 0){
		if(v.err != nil)
			return s + "error " + v.err + "\n";
		return s + "loading\n";
	}
	fr := w.body.frame.r;
	fit := "none";
	if(v.fit == Fitwidth)
		fit = "width";
	else if(v.fit == Fitpage)
		fit = "page";
	s += sprint("shown %d\nsheets %d\nsheet %d\nscale %d\nfit %s\n", d.shown, len v.sizes, v.sheetat(v.org.y) + 1, v.scale, fit);
	s += sprint("view %d %d %d %d\n", v.org.x, v.org.y, fr.dx(), fr.dy());
	s += sprint("screen %d %d %d %d\n", fr.min.x, fr.min.y, fr.max.x, fr.max.y);
	s += sprint("column %d %d\n", v.colw, v.colh);
	if(v.kind != nil && v.kind.class == Docreg->Source)
		s += sprint("live %d\n", d.live);
	return s;
}

ctlwrite(w: ref Window, s: string): string
{
	d := w.doc;
	(nil, l) := sys->tokenize(s, " \t\n");
	if(l == nil)
		return nil;
	cmd := hd l;
	arg := "";
	if(tl l != nil)
		arg = hd tl l;
	if(d == nil){
		# a window showing its text: render shows the file as the
		# document it is, or its text as the kind named (render
		# markdown), for a window whose name says nothing (a
		# program's, like Agent's)
		if(cmd != "render")
			return "no document";
		if(arg == "")
			return render(w);
		k := docreg->kindof(arg);
		if(k == nil || k.class != Docreg->Source)
			return "not a kind of source document: " + arg;
		return open(w, w.body.file.name, k);
	}
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
	"refresh" =>
		return refresh(w);
	"live" =>
		d.live = 1;
	"nolive" =>
		d.live = 0;
		d.liveat = 0;
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
	if(d == nil || d.v.h < 0)
		return nil;
	return d.v.eng->text(d.v.h);
}

linksread(w: ref Window): string
{
	d := w.doc;
	if(d == nil || d.v.h < 0)
		return nil;
	s := "";
	l := d.v.eng->links(d.v.h);
	for(i := 0; i < len l; i++){
		r := l[i].r;
		s += sprint("%d %d %d %d %d %s\n", l[i].sheet + 1, r.min.x, r.min.y, r.max.x, r.max.y, l[i].url);
	}
	return s;
}

# s found on the drawing, marked; nil, or why not
find(w: ref Window, s: string): string
{
	d := w.doc;
	if(d == nil || d.v.h < 0)
		return "no document";
	err := d.v.find(s);
	draw(w);
	return err;
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
	for(l := d.v.found; l != nil; l = tl l){
		if(k++ >= MAXFOUND){
			s += sprint("%d\n", hd l + 1);
			continue;
		}
		for(rl := d.v.foundon(hd l); rl != nil; rl = tl rl){
			r := hd rl;
			s += sprint("%d %d %d %d %d\n", hd l + 1, r.min.x, r.min.y, r.max.x, r.max.y);
		}
	}
	return s;
}

filesof(w: ref Window): string
{
	d := w.doc;
	if(d == nil || d.v.h < 0)
		return nil;
	return d.v.eng->files(d.v.h);
}

# ---- little things ----

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
