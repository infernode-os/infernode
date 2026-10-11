implement Page;

#
# page - show documents: PDFs, images, Markdown, Mermaid, HTML
#
#	page [-r quarters] [-w | -f | -z percent] [file ...]
#
# Each file is shown by the engine for its kind (docengine(2)), through
# the view Xenith's windows use (sheetview(2)): a column of its pages,
# scrolled, dragged (button 1) and zoomed.  Several files are one
# document: paging on past a file's last page goes to the next file.
# With no file, the document is read from standard input.  Only the
# file shown is held open.
#
# Button 3 is the menu: paging, zoom, fit, turning, finding, going to
# a page, writing the page shown as an image, and the pages and files.
#
# Keys: space and Page Down a screen on, backspace and Page Up back;
# Up and Down scroll; n or Right the next page, p or Left the last;
# Home and End; + and - zoom; w fits the width, f a whole page; r and
# R turn the pages right and left; / finds; g goes to a page; W writes
# the page shown; q quits.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "arg.m";

include "keyboard.m";

include "docengine.m";
include "docreg.m";
	docreg: Docreg;
	Kind: import docreg;

include "sheetview.m";
	sheetview: Sheetview;
	View, Ev, Note: import sheetview;

include "lucitheme.m";

Page: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# A file of the document, held open while it is shown
Part: adt {
	name:	string;		# a path, or "stdin"
	data:	array of byte;	# standard input's, kept
	kind:	ref Kind;
	v:	ref View;	# while it is shown
	n:	int;		# its pages, once known (0 until opened)
};

MAXREAD: con 64*1024*1024;

stderr: ref Sys->FD;
display: ref Display;
top: ref Tk->Toplevel;
evc: chan of ref Ev;
parts: array of ref Part;
cur := -1;
buf: ref Image;		# the panel's image, drawn by the view
bgcol, markcol: ref Image;
font: ref Font;
style: ref Docengine->Style;
c_bg, c_fg, c_accent: string;
prompting := 0;
promptkind := "";
status := "";
rot := 0;
scale := 0;		# from -z, else the fit
fit := Sheetview->Fitnone;
lastsheet := -1;	# where a turn to the last page goes, on a part changed

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	stderr = sys->fildes(2);
	sys->pctl(Sys->NEWPGRP, nil);

	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("page [-r quarters] [-w | -f | -z percent] [file ...]");
	while((c := arg->opt()) != 0)
		case c {
		'r' =>	rot = int arg->earg();
		'w' =>	fit = Sheetview->Fitwidth;
		'f' =>	fit = Sheetview->Fitpage;
		'z' =>	scale = int arg->earg();
		* =>	arg->usage();
		}
	files := arg->argv();

	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;
	docreg = load Docreg Docreg->PATH;
	sheetview = load Sheetview Sheetview->PATH;
	if(docreg == nil || sheetview == nil){
		sys->fprint(stderr, "page: cannot load the document modules: %r\n");
		raise "fail:load";
	}
	docreg->init(display);
	sheetview->init(display);
	evc = chan of ref Ev;

	# the parts: the files named, or standard input
	l: list of ref Part;
	if(files == nil){
		data := readall(sys->fildes(0));
		if(data == nil){
			sys->fprint(stderr, "page: nothing on standard input\n");
			raise "fail:empty";
		}
		l = ref Part("stdin", data, docreg->kind(nil, data), nil, 0) :: nil;
	}else
		for(; files != nil; files = tl files){
			f := hd files;
			k := docreg->kind(f, nil);
			if(k == nil)
				k = docreg->kind(f, head(f));
			if(k == nil){
				sys->fprint(stderr, "page: %s: not a document page shows\n", f);
				continue;
			}
			l = ref Part(f, nil, k, nil, 0) :: l;
		}
	parts = array[len l] of ref Part;
	for(i := len parts - 1; l != nil; l = tl l)
		parts[i--] = hd l;
	if(len parts == 0 || parts[0].kind == nil){
		sys->fprint(stderr, "page: nothing to show\n");
		raise "fail:nothing";
	}

	colours();
	dr := display.image.r;
	w := dr.dx() * 2 / 3;
	h := dr.dy() - 60;
	if(w < 400) w = 400;
	if(h < 300) h = 300;
	wmctl: chan of string;
	(top, wmctl) = tkclient->toplevel(ctxt, sprint("-width %d -height %d", w, h), "page", Tkclient->Appl);
	act := chan[16] of string;
	tk->namechan(top, act, "act");
	ui := array[] of {
		"pack propagate . 0",
		". configure -background " + c_bg,
		"panel .p -bd 0 -background " + c_bg,
		"label .s -anchor w -background " + c_bg + " -foreground " + c_fg,
		"entry .e -background " + c_bg + " -foreground " + c_fg,
		"pack .s -side bottom -fill x",
		"pack .p -side top -fill both -expand 1",
		"bind .p <ButtonPress-1> {send act down %x %y}",
		# Inferno Tk has no <B1-Motion>: motion is taken while dragging
		"bind .p <Motion> {send act drag %x %y}",
		# a resize reaches a packed widget, not the toplevel
		"bind .p <Configure> {send act resized}",
		"bind .p <ButtonRelease-1> {send act up %x %y}",
		# as Plan 9's page: button 2 the operations, button 3 the pages
		"bind .p <ButtonPress-2> {send act menu %X %Y}",
		"bind .p <ButtonPress-3> {send act pages %X %Y}",
		"bind .p <ButtonPress-4> {send act wheel -1}",
		"bind .p <ButtonPress-5> {send act wheel 1}",
		"bind .e <Key-\n> {send act promptdone}",
		"update",
	};
	for(i = 0; i < len ui; i++)
		tkcmd(ui[i]);
	tkcmd(sprint("bind .e <Key-%c> {send act promptcancel}", 16r1b));
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	show(0, 0);

	dragfrom := Point(0, 0);
	orgfrom := Point(0, 0);
	dragging := 0;
	for(;;) alt {
	wc := <-wmctl or
	wc = <-top.ctxt.ctl or
	wc = <-top.wreq =>
		# wreq makes a posted menu's window
		tkclient->wmctl(top, wc);
		if(wc != nil && len wc > 0 && wc[0] == '!')
			redraw();
	k := <-top.ctxt.kbd =>
		if(prompting)
			tk->keyboard(top, k);
		else
			key(k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	e := <-evc =>
		handle(e);
	a := <-act =>
		(nil, t) := sys->tokenize(a, " ");
		if(t == nil)
			continue;
		v := view();
		case hd t {
		"down" =>
			dragfrom = xy(t);
			dragging = 1;
			if(v != nil)
				orgfrom = v.org;
		"drag" =>
			if(dragging && v != nil){
				v.pan(orgfrom.add(dragfrom.sub(xy(t))));
				redraw();
			}
		"up" =>
			dragging = 0;
		"resized" =>
			redraw();
		"wheel" =>
			if(v != nil && tl t != nil){
				v.scroll(int hd tl t * 3 * 16);
				redraw();
			}
		"menu" =>
			menu(t);
		"pages" =>
			pagesmenu(t);
		"promptdone" =>
			s := tkcmd(".e get");
			endprompt();
			prompted(s);
		"promptcancel" =>
			endprompt();
		* =>
			command(hd t, tl t);
		}
	}
}

# ---- the parts ----

view(): ref View
{
	if(cur < 0 || cur >= len parts)
		return nil;
	return parts[cur].v;
}

# Part i shown, from its page n (-1: its last); the part shown before is
# let go
show(i, n: int)
{
	if(i < 0 || i >= len parts)
		return;
	if(i != cur){
		if(cur >= 0 && parts[cur].v != nil){
			parts[cur].v.close();
			parts[cur].v = nil;
		}
		cur = i;
		p := parts[cur];
		p.v = sheetview->new(p.kind, p.name, evc);
		setview(p.v);
		p.v.rot = rot;
		lastsheet = n;
		p.v.open(p.data, p.name);
		settitle();
		redraw();
		return;
	}
	v := parts[cur].v;
	if(v == nil)
		return;
	if(n < 0)
		n = len v.sizes - 1;
	v.gotosheet(n);
	redraw();
}

setview(v: ref View)
{
	v.dst = buf;
	if(buf != nil)
		v.r = buf.r;
	v.bg = bgcol;
	v.mark = markcol;
	if(font == nil)
		font = openfont("/fonts/combined/go.14.font");
	v.font = font;
	if(style == nil){
		# Xenith's faces: a flowing document reads as it does there
		code := openfont("/fonts/combined/gomono.14.font");
		style = ref Docengine->Style(0, font, code, display.black, display.white, markcol, display.white);
	}
	v.style = style;
}

handle(e: ref Ev)
{
	p: ref Part;
	for(i := 0; i < len parts; i++)
		if(parts[i].v == e.v)
			p = parts[i];
	if(p == nil){
		pick o := e {
		Opened =>
			if(o.eng != nil && o.h >= 0)
				o.eng->close(o.h);
		}
		return;
	}
	v := p.v;
	note := v.handle(e);
	if(note == nil)
		return;
	pick n := note {
	Opened =>
		p.n = len v.sizes;
		if(scale > 0)
			v.zoom(scale);
		else if(fit != Sheetview->Fitnone)
			v.setfit(fit);
		if(lastsheet != 0){
			v.layout();
			if(lastsheet < 0)
				v.gotosheet(len v.sizes - 1);
			else
				v.gotosheet(lastsheet);
			lastsheet = 0;
		}
		redraw();
	Failed =>
		setstatus(p.name + ": " + n.err);
		redraw();
	Loaded =>
		p.name = n.name;
		settitle();
		redraw();
	Error =>
		setstatus(p.name + ": " + n.err);
	Redraw =>
		redraw();
	}
}

# ---- drawing ----

redraw()
{
	# the panel's image, as big as the panel
	w := int tkcmd(".p cget -actwidth");
	h := int tkcmd(".p cget -actheight");
	if(w < 1) w = 1;
	if(h < 1) h = 1;
	if(buf == nil || buf.r.dx() != w || buf.r.dy() != h){
		buf = display.newimage(Rect((0, 0), (w, h)), top.image.chans, 0, Draw->Nofill);
		if(buf == nil)
			return;
		tk->putimage(top, ".p", buf, nil);
	}
	v := view();
	if(v != nil){
		setview(v);
		v.draw();
		s := sprint("%s", parts[cur].name);
		if(len parts > 1)
			s += sprint("  (%d of %d)", cur + 1, len parts);
		if(v.h >= 0 && len v.sizes > 0){
			s += sprint("  page %d of %d", v.sheetat(v.org.y) + 1, len v.sizes);
			if(!v.flowing())
				s += sprint("  %d%%", v.scale);
		}
		if(status != nil)
			s += "  " + status;
		tkcmd(".s configure -text " + tk->quote(s));
	}
	tkcmd(".p dirty; update");
}

setstatus(s: string)
{
	status = s;
	redraw();
}

settitle()
{
	tkclient->settitle(top, "page " + parts[cur].name);
}

colours()
{
	bg := int 16r303030FF;
	fg := int 16rE0E0E0FF;
	accent := int 16rE07000FF;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil){
		th := lucitheme->gettheme();
		bg = th.bg;
		fg = th.text;
		accent = th.accent;
	}
	bgcol = display.color(bg);
	markcol = display.color(accent);
	c_bg = sprint("#%06xff", (bg >> 8) & 16rFFFFFF);
	c_fg = sprint("#%06xff", (fg >> 8) & 16rFFFFFF);
	c_accent = sprint("#%06xff", (accent >> 8) & 16rFFFFFF);
}

# ---- doing things ----

key(k: int)
{
	v := view();
	if(v == nil)
		return;
	case k {
	' ' or Keyboard->Pgdown =>	screen(1);
	'\b' or Keyboard->Pgup =>	screen(-1);
	Keyboard->Down =>	v.scroll(48); redraw();
	Keyboard->Up =>	v.scroll(-48); redraw();
	'n' or Keyboard->Right =>	command("next", nil);
	'p' or Keyboard->Left =>	command("prev", nil);
	Keyboard->Home =>	show(0, 0);
	Keyboard->End =>	show(len parts - 1, -1);
	'+' or '=' =>	command("zoomin", nil);
	'-' =>	command("zoomout", nil);
	'w' =>	command("fitwidth", nil);
	'f' =>	command("fitpage", nil);
	'r' =>	command("right", nil);
	'R' =>	command("left", nil);
	'/' =>	startprompt("find", "find");
	'g' =>	startprompt("goto", "page");
	'W' =>	startprompt("write", "write to");
	'q' or Keyboard->Del =>	command("exit", nil);
	}
}

# A screen on (1) or back (-1), on into the next part from a part's end
screen(d: int)
{
	v := view();
	if(v == nil)
		return;
	h := v.r.dy() - 32;
	if(h < 32)
		h = 32;
	if(d > 0 && v.org.y + v.r.dy() >= v.colh && cur + 1 < len parts){
		show(cur + 1, 0);
		return;
	}
	if(d < 0 && v.org.y <= 0 && cur > 0){
		show(cur - 1, -1);
		return;
	}
	v.scroll(d * h);
	redraw();
}

command(cmd: string, args: list of string)
{
	v := view();
	status = nil;
	case cmd {
	"next" =>
		if(v == nil)
			return;
		n := v.sheetat(v.org.y) + 1;
		if(n >= len v.sizes && cur + 1 < len parts)
			show(cur + 1, 0);
		else
			show(cur, n);
	"prev" =>
		if(v == nil)
			return;
		n := v.sheetat(v.org.y) - 1;
		if(n < 0 && cur > 0)
			show(cur - 1, -1);
		else if(n >= 0)
			show(cur, n);
	"zoomin" =>	viewcmd("Zoom+", nil);
	"zoomout" =>	viewcmd("Zoom-", nil);
	"fitwidth" =>	viewcmd("Fit", nil);
	"fitpage" =>	viewcmd("Fit", "page");
	"right" or "left" =>
		q := 1;
		if(cmd == "left")
			q = 3;
		rot = (rot + q) & 3;
		if(v != nil){
			v.rotate(q);
			redraw();
		}
	"find" =>	startprompt("find", "find");
	"goto" =>	startprompt("goto", "page");
	"write" =>	startprompt("write", "write to");
	"part" =>
		if(args != nil)
			show(int hd args, 0);
	"sheet" =>
		if(args != nil)
			show(cur, int hd args);
	"exit" =>
		if(v != nil)
			v.close();
		tkclient->wmctl(top, "exit");
		exit;
	}
}

viewcmd(cmd, arg: string)
{
	v := view();
	if(v == nil)
		return;
	(nil, err) := v.command(cmd, arg);
	if(err != nil)
		status = err;
	redraw();
}

# ---- the menus ----
# As Plan 9's page: button 2 raises the operations, button 3 the pages
# to choose from.  Each is posted where the button went down.

menu(t: list of string)
{
	tk->cmd(top, "destroy .m");	# the last one, if any
	tkcmd("menu .m");
	item(".m", "next page", "next");
	item(".m", "previous page", "prev");
	tkcmd(".m add separator");
	item(".m", "zoom in", "zoomin");
	item(".m", "zoom out", "zoomout");
	item(".m", "fit width", "fitwidth");
	item(".m", "fit page", "fitpage");
	item(".m", "turn right", "right");
	item(".m", "turn left", "left");
	tkcmd(".m add separator");
	item(".m", "find...", "find");
	item(".m", "go to page...", "goto");
	item(".m", "write page...", "write");
	tkcmd(".m add separator");
	item(".m", "exit", "exit");
	post(t);
}

# The pages near the one shown, the first and last, and the files
pagesmenu(t: list of string)
{
	tk->cmd(top, "destroy .m");
	tkcmd("menu .m");
	v := view();
	if(v != nil && len v.sizes > 0){
		n := len v.sizes;
		at := v.sheetat(v.org.y);
		lo := at - 8;
		hi := at + 8;
		if(lo < 0)
			lo = 0;
		if(hi >= n)
			hi = n - 1;
		if(lo > 0)
			item(".m", "1", "sheet 0");
		for(i := lo; i <= hi; i++){
			label := string (i + 1);
			if(i == at)
				label += "  *";
			item(".m", label, sprint("sheet %d", i));
		}
		if(hi < n - 1)
			item(".m", string n, sprint("sheet %d", n - 1));
	}
	if(len parts > 1){
		tkcmd("menu .m.f");
		for(i := 0; i < len parts; i++)
			item(".m.f", sprint("%d  %s", i + 1, parts[i].name), sprint("part %d", i));
		if(v != nil && len v.sizes > 0)
			tkcmd(".m add separator");
		tkcmd(".m add cascade -label files -menu .m.f");
	}
	post(t);
}

post(t: list of string)
{
	x := "40";
	y := "40";
	if(t != nil && tl t != nil && tl tl t != nil){
		x = hd tl t;
		y = hd tl tl t;
	}
	tkcmd(".m post " + x + " " + y);
}

item(m, label, verb: string)
{
	tkcmd(sprint("%s add command -label %s -command {send act %s}", m, tk->quote(label), verb));
}

# ---- asking for a string ----

startprompt(kind, label: string)
{
	prompting = 1;
	promptkind = kind;
	tkcmd(".s configure -text " + tk->quote(label + ":"));
	tkcmd(".e delete 0 end");
	tkcmd("pack .e -side bottom -fill x -before .s");
	tkcmd("focus .e");
	tkcmd("update");
}

endprompt()
{
	prompting = 0;
	tkcmd("pack forget .e");
	tkcmd("focus .p");
	tkcmd("update");
}

prompted(s: string)
{
	v := view();
	if(v == nil || s == nil){
		redraw();
		return;
	}
	case promptkind {
	"find" =>
		if((err := v.find(s)) != nil)
			status = s + ": " + err;
		else
			status = sprint("%s: on %d pages", s, len v.found);
		redraw();
	"goto" =>
		show(cur, int s - 1);
	"write" =>
		status = writepage(v, s);
		redraw();
	}
}

# The page shown, at the scale shown, as an image file
writepage(v: ref View, file: string): string
{
	if(v.h < 0)
		return "not open yet";
	n := v.sheetat(v.org.y);
	im: ref Image;
	for(l := v.cache; l != nil; l = tl l)
		if((hd l).n == n && (hd l).scale == v.scale && (hd l).im != nil)
			im = (hd l).im;
	if(im == nil){
		sz := v.size(n);
		im = display.newimage(Rect((0, 0), (sz.x * v.scale / 100, sz.y * v.scale / 100)), Draw->RGB24, 0, Draw->White);
		if(im == nil)
			return sprint("no image: %r");
		if((err := v.eng->paint(v.h, n, v.scale, im, im.r, (0, 0))) != nil)
			return err;
	}
	fd := sys->create(file, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sprint("%s: %r", file);
	if(display.writeimage(fd, im) < 0)
		return sprint("%s: %r", file);
	return sprint("page %d written to %s", n + 1, file);
}

# ---- little things ----

openfont(name: string): ref Font
{
	f := Font.open(display, name);
	if(f == nil)
		f = Font.open(display, "*default*");
	return f;
}

tkcmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(stderr, "page: tk: %s: %s\n", s, r);
	return r;
}

xy(t: list of string): Point
{
	if(t == nil || tl t == nil || tl tl t == nil)
		return Point(0, 0);
	return Point(int hd tl t, int hd tl tl t);
}

head(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[16] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return b[0:n];
}

readall(fd: ref Sys->FD): array of byte
{
	b := array[65536] of byte;
	t := 0;
	for(;;){
		if(t == len b){
			if(len b >= MAXREAD)
				break;
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		n := sys->read(fd, b[t:], len b - t);
		if(n <= 0)
			break;
		t += n;
	}
	if(t == 0)
		return nil;
	return b[0:t];
}
