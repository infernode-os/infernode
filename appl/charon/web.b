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
controls: array of ref Control;	# Tk widgets over the page's form controls
hoverurl := "";

Control: adt {
	f:	ref Field;
	w:	string;	# widget path
	x, y:	int;	# page coordinates
	var:	string;	# check/radio variable
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
		"bind .view.c <Button-1> {send act click %x %y}",
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
	syncfields();
	sess.resize(vw, vh);
	pageimg = nil;
	rebuildcontrols();
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
	"done" or "error" =>
		tk->cmd(top, ".bar.reload configure -text {⟳} -command {send act reload}");
		tk->cmd(top, ".bar.url delete 0 end");
		tk->cmd(top, ".bar.url insert 0 " + tk->quote(sess.url));
		title := sess.title;
		if(title == "")
			title = sess.url;
		tkclient->settitle(top, title + " — Charon");
		status(title);
		hiliting = 0;
		scroll = 0;
		scrollto(sess.scroll);
		rebuildcontrols();
		redraw();
		if(verb == "error")
			status("Error: " + rest);	# the page shown says so too (browser.b's errorpage)
		else if(sess.pg != nil && sess.pg.errors != nil)
			status(sys->sprint("%s — %d %s failed", title, len sess.pg.errors, plural(len sess.pg.errors, "resource")));
	"stopped" =>
		tk->cmd(top, ".bar.reload configure -text {⟳} -command {send act reload}");
		status("Stopped");
	"update" =>
		refreshcontrols();
	}
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
	"wheel" =>
		scrollto(scroll + int rest * 2 * LINE);	# the wheel: two lines a notch
	"click" =>
		tk->cmd(top, "focus .view.c");
		(x, y) := xy(rest);
		n := sess.nodeat(x, y + scroll);
		if(n != 0) {
			syncfields();
			report(sess.click(n));
			refreshcontrols();
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
	"ctl" =>
		# a form control's own action: click <i> | choose <i> <option>
		(what, args) := split(rest);
		(si, sopt) := split(args);
		i := int si;
		if(i < 0 || i >= len controls)
			break;
		c := controls[i];
		syncfields();
		case what {
		"click" =>
			report(sess.click(c.f.node));
		"choose" =>
			report(sess.set(c.f.node, sopt));
		"submit" =>
			report(sess.submit(c.f.form, 0));
		}
		refreshcontrols();
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

# ---- form controls as Tk widgets ----

rebuildcontrols()
{
	for(i := 0; i < len controls; i++)
		tk->cmd(top, "destroy " + controls[i].w);
	tk->cmd(top, ".view.c delete ctl");
	fields := sess.fields();
	l: list of ref Control;
	n := 0;
	for(i = 0; i < len fields; i++) {
		f := fields[i];
		if(f.kind == "hidden")
			continue;
		(ok, r) := sess.boxof(f.node);
		if(!ok || r.dx() <= 0 || r.dy() <= 0)
			continue;
		w := sys->sprint(".view.c.f%d", n);
		c := ref Control(f, w, r.min.x, r.min.y, nil);
		if(!makewidget(c, n))
			continue;
		tkc(sys->sprint(".view.c create window %d %d -anchor nw -window %s -width %d -height %d -tags {ctl c%d}",
			r.min.x, r.min.y - scroll, w, r.dx(), r.dy(), n));
		l = c :: l;
		n++;
	}
	controls = array[n] of ref Control;
	for(; l != nil; l = tl l)
		controls[--n] = hd l;
}

makewidget(c: ref Control, i: int): int
{
	f := c.f;
	w := c.w;
	font := " -font /fonts/combined/unicode.sans.12.font";
	# the page's colours, not the chrome's theme
	field := " -background white -foreground black -highlightthickness 0";
	button := " -background #e9e9edff -foreground black -activebackground #d0d0d7ff -activeforeground black";
	case f.kind {
	"submit" or "button" or "reset" or "image" =>
		label := f.value;
		if(label == "")
			label = f.kind;
		tkc(sys->sprint("button %s -text %s -command {send act ctl click %d}%s%s", w, tk->quote(label), i, font, button));
	"checkbox" or "radio" =>
		c.var = sys->sprint("v%d", i);
		cmd := "checkbutton";
		if(f.kind == "radio")
			cmd = "radiobutton -value 1";
		tkc(sys->sprint("%s %s -variable %s -command {send act ctl click %d} -background white -activebackground white -foreground black -selectcolor black -highlightthickness 0",
			cmd, w, c.var, i));
		setcheck(c);
	"select" =>
		tkc(sys->sprint("menubutton %s -text %s -menu %s.m -relief raised%s%s", w, tk->quote(label(f)), w, font, button));
		tkc(sys->sprint("menu %s.m", w));
		k := 0;
		for(o := f.options; o != nil; o = tl o) {
			(v, lab, nil) := hd o;
			tkc(sys->sprint("%s.m add command -label %s -command {send act ctl choose %d %s}",
				w, tk->quote(lab), i, tk->quote(v)));
			k++;
		}
	"textarea" =>
		tkc(sys->sprint("text %s -wrap word%s%s", w, font, field));
		tkc(sys->sprint("%s insert 1.0 %s", w, tk->quote(f.value)));
	"file" =>
		return 0;
	* =>
		show := "";
		if(f.kind == "password")
			show = " -show •";
		tkc(sys->sprint("entry %s%s%s%s", w, show, font, field));
		tkc(sys->sprint("%s insert 0 %s", w, tk->quote(f.value)));
		if(f.form != 0)
			tkc(sys->sprint("bind %s <Key-\n> {send act ctl submit %d}", w, i));
	}
	return 1;
}

label(f: ref Field): string
{
	for(o := f.options; o != nil; o = tl o)
		if((hd o).t0 == f.value)
			return (hd o).t1 + " ▾";
	return f.value + " ▾";
}

setcheck(c: ref Control)
{
	v := "0";
	if(c.f.checked)
		v = "1";
	tk->cmd(top, sys->sprint("variable %s %s", c.var, v));
}

# Move the widgets with the page.
placecontrols()
{
	for(i := 0; i < len controls; i++) {
		c := controls[i];
		tk->cmd(top, sys->sprint(".view.c coords c%d %d %d", i, c.x, c.y - scroll));
	}
}

# Typed text goes into the document before anything reads it.
syncfields()
{
	for(i := 0; i < len controls; i++) {
		c := controls[i];
		v: string;
		case c.f.kind {
		"textarea" =>
			v = tk->cmd(top, c.w + " get 1.0 end");
			if(len v > 0 && v[len v - 1] == '\n')
				v = v[0:len v - 1];
		"text" or "password" or "search" or "email" or "url" or "tel" or "number" or
		"date" or "time" or "datetime-local" or "month" or "week" or "color" or "range" =>
			v = tk->cmd(top, c.w + " get");
		* =>
			continue;
		}
		if(v != c.f.value) {
			sess.set(c.f.node, v);
			c.f.value = v;
		}
	}
}

# After the session changed fields: their state, and the page.
refreshcontrols()
{
	fields := sess.fields();
	for(i := 0; i < len controls; i++) {
		c := controls[i];
		for(j := 0; j < len fields; j++)
			if(fields[j].node == c.f.node) {
				c.f = fields[j];
				break;
			}
		case c.f.kind {
		"checkbox" or "radio" =>
			setcheck(c);
		"select" =>
			tk->cmd(top, c.w + " configure -text " + tk->quote(label(c.f)));
		"textarea" =>
			if(tk->cmd(top, c.w + " get 1.0 end") != c.f.value + "\n") {
				tk->cmd(top, c.w + " delete 1.0 end");
				tk->cmd(top, c.w + " insert 1.0 " + tk->quote(c.f.value));
			}
		"submit" or "button" or "reset" or "image" or "file" or "hidden" =>
			;
		* =>
			if(tk->cmd(top, c.w + " get") != c.f.value) {
				tk->cmd(top, c.w + " delete 0 end");
				tk->cmd(top, c.w + " insert 0 " + tk->quote(c.f.value));
			}
		}
	}
	redraw();
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
