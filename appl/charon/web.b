implement WebBrowser;

#
# charon/web - the web browser: Tk chrome around the new engine.
#
#	web [-h] [-m mountpoint] [-g wxh] [url]
#
# The page is a Tk canvas: one image item holding the painted viewport,
# and a window item per form control, which are real Tk widgets.  The
# session behind it (Browser) is also served as files at /mnt/charon
# (charonfs), so a script or an agent drives the window it can see.
# -h runs with no window: only the files.
#
# Network access is whatever webfs at /mnt/web gives; one is started
# if none is mounted.
#
# The wheel scrolls; keys (page focused): Up/Down, PgUp/PgDn, space, Home/End scroll;
# Alt-Left/Right or Backspace go back/forward; Ctrl-L the location;
# Ctrl-F find; Ctrl-R reload; Escape stop; Ctrl-Q quit.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "arg.m";
include "lucitheme.m";
	lucitheme: Lucitheme;
	Theme: import lucitheme;
include "web/dom.m";
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
include "web/page.m";
include "web/browser.m";
	browser: Browser;
	Session, Field: import browser;
include "web/charonfs.m";
	charonfs: Charonfs;

WebBrowser: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

HOME: con "file:///tests/charon/pages/article.html";
LINE: con 40;	# pixels per arrow-key scroll

stderr: ref Sys->FD;
top: ref Toplevel;
display: ref Display;
sess: ref Session;
pageimg: ref Image;
vw, vh: int;		# the viewport
scroll := 0;
hilite: Rect;		# the find match, page coordinates
hiliting := 0;
findtext := "";
editing: ref Control;	# the text field being typed into, a Tk widget over it; nil when none
scrx, scry: int;	# the canvas's origin on the screen, as of the last click
selpending: ref Field;	# a select pressed on, whose menu the release posts
layout: Layout;
hoverurl := "";

Control: adt {
	f:	ref Field;
	w:	string;	# widget path
	x, y:	int;	# page coordinates
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr = sys->fildes(2);
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);

	headless := 0;
	mnt := "/mnt/charon";
	w := 1024;
	h := 768;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("web [-h] [-m mountpoint] [-g wxh] [url]");
	while((o := arg->opt()) != 0)
		case o {
		'h' =>	headless = 1;
		'm' =>	mnt = arg->earg();
		'g' =>
			(n, l) := sys->tokenize(arg->earg(), "x");
			if(n != 2)
				arg->usage();
			w = int hd l;
			h = int hd tl l;
		* =>	arg->usage();
		}
	argv = arg->argv();
	url := HOME;
	if(argv != nil)
		url = hd argv;

	browser = load Browser Browser->PATH;
	layout = load Layout Layout->PATH;
	charonfs = load Charonfs Charonfs->PATH;
	if(browser == nil || charonfs == nil)
		fatal(sys->sprint("cannot load the engine: %r"));
	if((err := startwebfs()) != nil)
		sys->fprint(stderr, "web: %s; http will not work\n", err);

	if(headless) {
		display = Display.allocate(nil);
		start(w, h, mnt);
		ev := sess.listen();
		sess.open(url);
		for(;;)
			<-ev;
	}

	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	lucitheme = load Lucitheme Lucitheme->PATH;
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil)
		fatal("no window context");
	wmctl: chan of string;
	(top, wmctl) = tkclient->toplevel(ctxt, sys->sprint("-width %d -height %d", w, h), "Charon", Tkclient->Appl);
	display = top.display;
	act := chan[16] of string;
	tk->namechan(top, act, "act");
	buildui();
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tk->cmd(top, "update");
	(vw, vh) = viewsize();
	start(vw, vh, mnt);
	ev := sess.listen();
	sess.open(url);

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	c = <-top.wreq =>
		tkclient->wmctl(top, c);
		if(c != nil && c[0] == '!')
			resized();
	k := <-top.ctxt.kbd =>
		key(k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	a := <-act =>
		action(a);
	e := <-ev =>
		event(e);
	}
}

start(w, h: int, mnt: string)
{
	if((err := browser->init(display)) != nil || (err = charonfs->init()) != nil)
		fatal(err);
	sess = Session.new(w, h);
	if((err = charonfs->serve(browser, sess, display, mnt)) != nil)
		sys->fprint(stderr, "web: %s\n", err);
	# for name spaces other than this one, Veltro's included
	(nil, perr) := charonfs->post(Charonfs->SPEC);
	if(perr != nil)
		sys->fprint(stderr, "web: post: %s\n", perr);
}

startwebfs(): string
{
	if(webfsup())
		return nil;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return sys->sprint("cannot load webfs: %r");
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		if(webfsup())
			return nil;
		sys->sleep(20);
	}
	return "webfs did not start";
}

fatal(s: string)
{
	sys->fprint(stderr, "web: %s\n", s);
	raise "fail:" + s;
}

# ---- the window ----

buildui()
{
	th := theme();
	bg := col(th.bg);
	fg := col(th.text);
	ebg := col(th.editbg);
	cmds := array[] of {
		". configure -background " + bg,
		"frame .bar -background " + bg,
		"button .bar.back -text {◀} -command {send act back}",
		"button .bar.fwd -text {▶} -command {send act forward}",
		"button .bar.reload -text {⟳} -command {send act reload}",
		"entry .bar.url -background " + ebg + " -foreground " + col(th.edittext),
		"bind .bar.url <Key-\n> {send act go}",
		"pack .bar.back .bar.fwd .bar.reload -side left",
		"pack .bar.url -side left -fill x -expand 1",
		"frame .view",
		"scrollbar .view.sb -command {send act sb}",
		"canvas .view.c -borderwidth 0 -highlightthickness 0 -background white",
		"image create bitmap page",
		".view.c create image 0 0 -anchor nw -image page -tags pageitem",
		"pack .view.sb -side right -fill y",
		"pack .view.c -side left -fill both -expand 1",
		"label .status -anchor w -background " + col(th.editstatus) + " -foreground " + col(th.editstattext),
		"pack .bar -side top -fill x",
		"pack .status -side bottom -fill x",
		"pack .view -side top -fill both -expand 1",
		"pack propagate . 0",
		"bind .view.c <Button-1> {send act click %x %y %X %Y}",
		"bind .view.c <ButtonRelease-1> {send act release}",
		"bind .view.c <Motion> {send act hover %x %y}",
		"bind .view.c <Button-3> {send act menu %X %Y}",
		"bind .view.c <ButtonPress-4> {send act wheel -1}",
		"bind .view.c <ButtonPress-5> {send act wheel 1}",
		"bind .view <Configure> {send act resized}",
		"menu .ctx",
		".ctx add command -label {Back} -command {send act back}",
		".ctx add command -label {Forward} -command {send act forward}",
		".ctx add command -label {Reload} -command {send act reload}",
		".ctx add command -label {Find...} -command {send act find}",
		".ctx add separator",
		".ctx add command -label {Quit} -command {send act quit}",
	};
	for(i := 0; i < len cmds; i++) {
		e := tk->cmd(top, cmds[i]);
		if(e != nil && e[0] == '!')
			sys->fprint(stderr, "web: tk: %s: %s\n", cmds[i], e);
	}
	for(l := ".bar.back" :: ".bar.fwd" :: ".bar.reload" :: nil; l != nil; l = tl l)
		tk->cmd(top, hd l + " configure -background " + bg + " -foreground " + fg + " -borderwidth 0");
}

viewsize(): (int, int)
{
	w := int tk->cmd(top, ".view.c cget -actwidth");
	h := int tk->cmd(top, ".view.c cget -actheight");
	if(w < 50)
		w = 50;
	if(h < 50)
		h = 50;
	return (w, h);
}

resized()
{
	(w, h) := viewsize();
	if(w == vw && h == vh)
		return;
	vw = w;
	vh = h;
	endedit(1);
	sess.resize(vw, vh);
	pageimg = nil;
	redraw();
}

# Paint the viewport and put it in the canvas.
redraw()
{
	if(pageimg == nil || pageimg.r.dx() != vw || pageimg.r.dy() != vh)
		pageimg = display.newimage(Rect((0, 0), (vw, vh)), display.image.chans, 0, Draw->White);
	if(pageimg == nil)
		return;
	pageimg.draw(pageimg.r, display.white, nil, (0, 0));
	sess.paint(pageimg, Point(0, scroll));
	if(hiliting) {
		r := hilite.subpt(Point(0, scroll));
		y := display.color(int 16rFFFF0060);
		pageimg.draw(r, y, nil, (0, 0));
	}
	tk->putimage(top, "page", pageimg, nil);
	tk->cmd(top, ".view.c coords pageitem 0 0");
	placecontrols();
	setscrollbar();
	tk->cmd(top, "update");
}

pageheight(): int
{
	h := sess.pageheight();
	if(h < vh)
		h = vh;
	return h;
}

setscrollbar()
{
	h := real pageheight();
	tk->cmd(top, sys->sprint(".view.sb set %g %g", real scroll / h, real (scroll + vh) / h));
}

scrollto(y: int)
{
	max := pageheight() - vh;
	if(y > max)
		y = max;
	if(y < 0)
		y = 0;
	if(y == scroll)
		return;
	scroll = y;
	redraw();
}

# ---- events from the session ----

event(e: string)
{
	(verb, rest) := split(e);
	case verb {
	"loading" =>
		status("Loading " + rest + " ...");
		tk->cmd(top, ".bar.reload configure -text {✕} -command {send act stop}");
		tk->cmd(top, "update");
	"shown" =>
		# a new page, or a new place in this one; its images still coming
		shown();
		if(sess.status != "done")
			status("Loading images ...");
	"done" =>
		tk->cmd(top, ".bar.reload configure -text {⟳} -command {send act reload}");
		redraw();
		title := sess.title;
		if(title == "")
			title = sess.url;
		status(title);
		if(sess.pg != nil && sess.pg.errors != nil)
			status(sys->sprint("%s — %d %s failed", title, len sess.pg.errors, plural(len sess.pg.errors, "resource")));
	"error" =>
		tk->cmd(top, ".bar.reload configure -text {⟳} -command {send act reload}");
		shown();
		status("Error: " + rest);	# the page shown says so too (browser.b's errorpage)
	"stopped" =>
		tk->cmd(top, ".bar.reload configure -text {⟳} -command {send act reload}");
		status("Stopped");
	"update" =>
		redraw();
		(got, n) := split(rest);
		if(n != nil && got != n)
			status(sys->sprint("Loading images ... %s of %s", got, n));
	}
}

# The session is showing another page, or another place in it.
shown()
{
	tk->cmd(top, ".bar.url delete 0 end");
	tk->cmd(top, ".bar.url insert 0 " + tk->quote(sess.url));
	title := sess.title;
	if(title == "")
		title = sess.url;
	tkclient->settitle(top, title + " — Charon");
	hiliting = 0;
	scroll = 0;
	scrollto(sess.scroll);
	endedit(0);
	redraw();
}

# ---- user actions ----

action(a: string)
{
	(verb, rest) := split(a);
	case verb {
	"go" =>
		u := tk->cmd(top, ".bar.url get");
		tk->cmd(top, "focus .view.c");
		sess.open(u);
	"back" =>
		report(sess.goback());
	"forward" =>
		report(sess.goforward());
	"reload" =>
		sess.reload();
	"stop" =>
		sess.stop();
	"quit" =>
		exit;
	"resized" =>
		resized();
	"menu" =>
		tk->cmd(top, ".ctx post " + rest);
	"find" =>
		status("Find: ");
		findmode = 1;
		findbuf = "";
	"sb" =>
		(sv, sa) := split(rest);
		case sv {
		"moveto" =>
			scrollto(int (real sa * real pageheight()));
		"scroll" =>
			(n, unit) := split(sa);
			d := int n * LINE;
			if(prefix(unit, "page"))
				d = int n * (vh - LINE);
			scrollto(scroll + d);
		}
	"release" =>
		if((f := selpending) != nil) {
			selpending = nil;
			postselect(f);
		}
	"wheel" =>
		scrollto(scroll + int rest * 2 * LINE);	# the wheel: two lines a notch
	"click" =>
		tk->cmd(top, "focus .view.c");
		(x, y) := xy(rest);
		(nil, l) := sys->tokenize(rest, " ");
		if(len l == 4)	# where the canvas is on the screen, for a menu posted from it
			(scrx, scry) = (int hd tl tl l - x, int hd tl tl tl l - y);
		n := sess.nodeat(x, y + scroll);
		endedit(1);
		if(n != 0) {
			f := fieldat(n);
			if(f != nil && istext(f.kind))
				startedit(f);
			else if(f != nil && f.kind == "select")
				selpending = f;	# posted when the button comes up: a menu posted on the press goes with the release
			else
				report(sess.click(n));
		}
	"hover" =>
		(x, y) := xy(rest);
		u := sess.linkat(x, y + scroll);
		if(u != hoverurl) {
			hoverurl = u;
			if(u != nil)
				status(u);
			else
				status(sess.title);
		}
	"submit" =>
		# Enter in a text field: what was typed, then its form
		f := editing;
		endedit(1);
		if(f != nil && f.f.form != 0)
			report(sess.submit(f.f.form, 0));
	"cancel" =>
		endedit(0);
	"choose" =>
		# an option of a select by its place, not its text: send keeps
		# Tk's quoting, so a value came back as {Dark}
		(sn, si) := split(rest);
		if((f := fieldat(int sn)) != nil) {
			i := int si;
			for(o := f.options; o != nil && i > 0; o = tl o)
				i--;
			if(o != nil)
				report(sess.set(f.node, (hd o).t0));
		}
	}
}

report(err: string)
{
	if(err != nil)
		status(err);
}

findmode := 0;
findbuf := "";

Kup: con 16rFF52;
Kdown: con 16rFF54;
Kleft: con 16rFF51;
Kright: con 16rFF53;
Kpgup: con 16rFF55;
Kpgdown: con 16rFF56;
Khome: con 16rFF61;
Kend: con 16rFF57;
Kesc: con 27;
Kbs: con 8;

key(k: int)
{
	if(findmode) {
		findkey(k);
		return;
	}
	case k {
	'q' & 16r1F =>
		exit;
	'l' & 16r1F =>
		tk->cmd(top, "focus .bar.url");
		tk->cmd(top, ".bar.url selection range 0 end");
		tk->cmd(top, "update");
		return;
	'f' & 16r1F =>
		action("find");
		return;
	'r' & 16r1F =>
		sess.reload();
		return;
	'g' & 16r1F =>
		findnext();
		return;
	}
	focus := tk->cmd(top, "focus");
	if(focus != "" && focus != ".view.c" && focus != ".") {
		tk->keyboard(top, k);
		return;
	}
	case k {
	Kup =>		scrollto(scroll - LINE);
	Kdown =>	scrollto(scroll + LINE);
	Kpgup =>	scrollto(scroll - (vh - LINE));
	Kpgdown or ' ' =>	scrollto(scroll + (vh - LINE));
	Khome =>	scrollto(0);
	Kend =>	scrollto(pageheight());
	Kbs or Kleft =>	report(sess.goback());
	Kright =>	report(sess.goforward());
	Kesc =>	sess.stop();
	* =>
		tk->keyboard(top, k);
	}
}

findkey(k: int)
{
	case k {
	'\n' or '\r' =>
		findmode = 0;
		findtext = findbuf;
		hilite = Rect((0, 0), (0, 0));
		findnext();
	Kesc =>
		findmode = 0;
		status(sess.title);
	Kbs =>
		if(len findbuf > 0)
			findbuf = findbuf[0:len findbuf - 1];
		status("Find: " + findbuf);
	* =>
		if(k >= ' ') {
			findbuf[len findbuf] = k;
			status("Find: " + findbuf);
		}
	}
}

findnext()
{
	if(findtext == "") {
		action("find");
		return;
	}
	after := -1;
	if(hiliting)
		after = hilite.min.y;
	(ok, r) := sess.findat(findtext, after);
	if(!ok && after >= 0)
		(ok, r) = sess.findat(findtext, -1);	# wrap
	if(!ok) {
		hiliting = 0;
		status(findtext + ": not found");
		redraw();
		return;
	}
	hilite = r;
	hiliting = 1;
	status("Found: " + findtext + "   (Ctrl-G: next)");
	if(r.min.y < scroll || r.max.y > scroll + vh)
		scroll = r.min.y - vh/3;
	scrollto(scroll);
	redraw();
}

# ---- form controls ----
#
# The page draws every control as its CSS has it (the engine knows the
# fonts, colours, borders and placeholders; a Tk widget over it showed
# none of them).  A click goes to the session, which checks a box,
# picks a radio, submits a form or follows a label; a select posts a
# menu of its options; a text field being typed into is a Tk widget,
# borderless, in the field's own colours, laid over its padding box
# until Enter, Escape or a click elsewhere.

fieldat(n: int): ref Field
{
	fields := sess.fields();
	for(i := 0; i < len fields; i++)
		if(fields[i].node == n)
			return fields[i];
	return nil;
}

istext(kind: string): int
{
	case kind {
	"text" or "password" or "search" or "email" or "url" or "tel" or "number" or "textarea" =>
		return 1;
	}
	return 0;
}

# the node's border box in page coordinates, and the box
fieldbox(n: int): (int, Rect, ref Layout->Box)
{
	pg := sess.pg;
	if(pg == nil)
		return (0, Rect((0, 0), (0, 0)), nil);
	for(l := layout->boxes(pg.root, n); l != nil; l = tl l) {
		b := hd l;
		x := 0;
		y := 0;
		for(a := b; a != nil; a = a.parent) {
			x += a.x;
			y += a.y;
		}
		return (1, Rect((x, y), (x + b.w, y + b.h)), b);
	}
	return (0, Rect((0, 0), (0, 0)), nil);
}

startedit(f: ref Field)
{
	(ok, r, b) := fieldbox(f.node);
	if(!ok)
		return;
	# inside the border and padding, as the text is drawn
	cr := Rect((r.min.x + b.bl + b.pl, r.min.y + b.bt + b.pt), (r.max.x - b.br - b.pr, r.max.y - b.bb - b.pb));
	if(cr.dx() < 8 || cr.dy() < 8)
		cr = r;
	st := b.st;
	bg := "white";
	if((st.bgcolor & 255) == 255)
		bg = col(st.bgcolor);
	opts := sys->sprint(" -font %s -background %s -foreground %s -borderwidth 0 -highlightthickness 0 -relief flat",
		fontfor(st.fontsize, f.kind == "textarea"), bg, col(st.color));
	w := ".view.c.edit";
	if(f.kind == "textarea") {
		tkc("text " + w + " -wrap word" + opts);
		tkc(w + " insert 1.0 " + tk->quote(f.value));
	} else {
		show := "";
		if(f.kind == "password")
			show = " -show •";
		tkc("entry " + w + show + opts);
		tkc(w + " insert 0 " + tk->quote(f.value));
		tkc("bind " + w + " <Key-\n> {send act submit}");
	}
	tkc("bind " + w + " <Key-\u001b> {send act cancel}");
	tkc(sys->sprint(".view.c create window %d %d -anchor nw -window %s -width %d -height %d -tags edit",
		cr.min.x, cr.min.y - scroll, w, cr.dx(), cr.dy()));
	tkc("focus " + w);
	editing = ref Control(f, w, cr.min.x, cr.min.y);
	if(f.kind != "textarea") {
		# the cursor at the end, the view from the start: set before
		# the widget had its width, the view scrolled the text away
		tkc("update");
		tkc(w + " icursor end");
		tkc(w + " xview 0");
	}
	redraw();
}

# Take what was typed into the page (keep) or drop it, and put the
# widget away.
endedit(keep: int)
{
	c := editing;
	if(c == nil)
		return;
	editing = nil;
	if(keep) {
		v: string;
		if(c.f.kind == "textarea") {
			v = tk->cmd(top, c.w + " get 1.0 end");
			if(len v > 0 && v[len v - 1] == '\n')
				v = v[0:len v - 1];
		} else
			v = tk->cmd(top, c.w + " get");
		if(v != c.f.value)
			report(sess.set(c.f.node, v));
	}
	tk->cmd(top, ".view.c delete edit");
	tk->cmd(top, "destroy " + c.w);
	tk->cmd(top, "focus .view.c");
	redraw();
}

# a select's options as a menu, under it
postselect(f: ref Field)
{
	(ok, r, nil) := fieldbox(f.node);
	if(!ok)
		return;
	tk->cmd(top, "destroy .selm");
	tkc("menu .selm");
	i := 0;
	for(o := f.options; o != nil; o = tl o) {
		(nil, lab, nil) := hd o;
		tkc(sys->sprint(".selm add command -label %s -command {send act choose %d %d}",
			tk->quote(lab), f.node, i++));
	}
	tkc(sys->sprint(".selm post %d %d", scrx + r.min.x, scry + r.max.y - scroll));
}

# The Go face nearest the field's size: Tk draws only bitmap fonts,
# and these are the sizes there are.
fontfor(px: real, mono: int): string
{
	sizes := array[] of {14, 16, 18, 20, 21, 22, 24, 27, 28, 32, 36};
	n := sizes[0];
	for(i := 0; i < len sizes; i++)
		if(real sizes[i] - px < px - real n)
			n = sizes[i];
	face := "go";
	if(mono)
		face = "gomono";
	return sys->sprint("/fonts/combined/%s.%d.font", face, n);
}

# Keep the widget being typed into over its field as the page scrolls.
placecontrols()
{
	if(editing != nil)
		tk->cmd(top, sys->sprint(".view.c coords edit %d %d", editing.x, editing.y - scroll));
}

# ---- small things ----

tkc(c: string): string
{
	e := tk->cmd(top, c);
	if(e != nil && e[0] == '!')
		sys->fprint(stderr, "web: tk: %s: %s\n", c, e);
	return e;
}

status(s: string)
{
	tk->cmd(top, ".status configure -text " + tk->quote(s));
	tk->cmd(top, "update");
}

theme(): ref Theme
{
	th: ref Theme;
	if(lucitheme != nil)
		th = lucitheme->gettheme();
	if(th == nil)
		th = ref Theme;
	return th;
}

col(v: int): string
{
	return sys->sprint("#%06xff", (v >> 8) & 16rFFFFFF);
}

xy(s: string): (int, int)
{
	(nil, l) := sys->tokenize(s, " ");
	if(len l < 2)
		return (0, 0);
	return (int hd l, int hd tl l);
}

split(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ') {
			j := i;
			while(j < len s && s[j] == ' ')
				j++;
			return (s[0:i], s[j:]);
		}
	return (s, "");
}

plural(n: int, s: string): string
{
	if(n == 1)
		return s;
	return s + "s";
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# a webfs is mounted there, not merely a file by that name
webfsup(): int
{
	(ok, d) := sys->stat("/mnt/web/clone");
	return ok >= 0 && d.dtype == 'M';
}
