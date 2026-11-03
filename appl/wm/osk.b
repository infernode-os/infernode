implement Osk;

#
# osk -- a keyboard on the screen, for a touch screen.
#
#	wm/osk [-sm] [-l layout] [-F fd] [-r tracefile]
#
# A keyboard drawn at the bottom of the screen, typed with fingers:
# its keys type into whatever has the keyboard, as a keyboard's do
# (through /dev/kbdin, cons(3)), and it never takes the keyboard
# itself -- it asks the window manager for the pointer only, and to be
# docked ("dock bottom <height>"), which wm/wm and Lucifer honour.
#
# A key types when the finger LIFTS, the key under it then: a finger
# that lands on the wrong key slides to the right one.  Words are
# decoded as they are typed (kbdecode(2)): the touches against the
# keys and a word list, so a slip onto the next key, a letter missed
# or doubled or two swapped, is put right when the word ends (a space,
# punctuation) -- and a backspace straight after takes the correction
# back.  A stroke through a word's letters types the word (a swipe).
# The likeliest words are shown above the keys; a touch on one puts it
# in.  A swipe down hides the keyboard; a swipe left from the delete
# key deletes the word before.  A long press offers a key's accents.
#
# With -s it is the system's keyboard, which Lucifer starts: hidden
# whenever a keyboard of the machine's is attached or typed on
# (/dev/keyboards), and otherwise shown once the screen is touched --
# or, with -m, when asked (show, hide on /mnt/osk/ctl: softkbd(2) asks,
# for a text field taking the keyboard), as on a phone, whose GUI says
# when a field has it.  Without -s it is shown from the start, whatever
# else is attached: it was asked for.
#
# Its files, at /mnt/osk (or served on fd with -F, for its parent to
# mount): osk(4).
#
#	ctl	show, hide, toggle, layout <name>, mode text|plain,
#		correct on|off, swipe on|off, height <pixels>,
#		record <file>|off, rect ... (accepted, not needed)
#	status	state, layout, mode, correct, swipe, height, keyboards,
#		words, shift, a line each; a read after a file's first
#		waits for a change
#	words	the words it has learned, "word count" a line;
#		a write adds them
#	keys	the keys shown and where, "name minx miny maxx maxy"
#		a line (for a test, an agent, a typist's trace)
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Rect, Point, Pointer: import draw;
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "keyboard.m";
include "kbdecode.m";
	kbdecode: Kbdecode;
	Decoder, Lexicon, Touch, Cand: import kbdecode;
include "osklayout.m";
	osklayout: Osklayout;
	Layout, Lkey: import osklayout;
include "lucitheme.m";
	lucitheme: Lucitheme;
include "tk.m";
include "icon.m";
	icon: Icon;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "arg.m";

Osk: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

LAYOUTS:	con "/lib/osk/layouts";
ORDER:		con "/lib/osk/order";
WORDS:		con "/lib/osk/en.words";
PAIRS:		con "/lib/osk/en.pairs";
ALTS:		con "/lib/osk/alternates";
IGNORE:		con "/lib/osk/ignore";

Longms:		con 420;	# a press this long offers the key's accents
Repeatms:	con 450;	# delete held this long repeats
Repeatevery:	con 65;
Doubletapms:	con 320;	# shift twice this quickly is caps lock
Dupms:		con 300;	# a pointer press this near a finger's is the finger's

# what the keyboard is showing
Off, Handle, Shown: con iota;
# shift
Unshifted, Once, Locked: con iota;
# mode: whether words are put right
Text, Plain: con iota;

stderr: ref Sys->FD;
display: ref Display;
win: ref Window;
img: ref Image;			# the window's, nil while not on the screen
theme: ref Lucitheme->Theme;
font, sfont: ref Font;

# the layouts
letters: array of ref Layout;
cur := 0;			# which letters
sym, more: ref Layout;
layer: ref Layout;		# shown
alts: list of (int, string);
lex: ref Lexicon;
dec: ref Decoder;
userwords := "";		# the learned words file
userweight := 1;		# a learned word's count
ignore: list of string;		# names of keyboards that are not keyboards

# the state
sysmode := 0;			# -s
managed := 0;			# -m: the GUI says when a text field has the keyboard
touched := 0;			# a finger has been on the screen
state := Off;
want := 1;			# asked to be shown
userhidden := 0;		# swiped down
hwkbd := 0;			# a keyboard of the machine's attached
hardlatch := 0;			# typed on one since last asked for
shift := Unshifted;
lastshift := 0;			# msec of the last shift tap
ctrl := 0;
mode := Text;
correcting := 1;
swiping := 1;
rowh := 0;			# 0: from the screen
forcedrowh := 0;
dockok := 0;			# the window manager docks

# where things are
striprect, keysrect, handlerect: Rect;

# the word being typed: its taps, what was typed for them, their case
wtaps: array of Touch;
wlit := "";
wcaps: array of int;
# what came before, as typed here (for capitals after a sentence's end)
context := "";
# the last word put right, while a backspace may take it back
rv := 0;
rvlit, rvword, rvbound: string;
rvtaps: array of Touch;
rvcaps: array of int;
rejected: list of string;	# taken back, not to be put right again this session
pending: list of (string, int);	# words typed not in the list, and how often
# the last swiped word, while a backspace takes it all
swiped := 0;
swipedtext := "";
lastspace := 0;			# msec of the last space typed after a word

# suggestions
sugg: array of string;
suggauto := -1;			# the one a space would put in

# touches
Tch: adt {
	id:	int;		# finger, or -1 for the pointer
	down:	int;		# msec
	start:	Point;
	last:	Point;
	path:	list of Point;	# newest first
	npath:	int;
	travel:	real;
	key:	ref Lkey;	# under it as it landed
	cur:	ref Lkey;	# under it now
	instrip:	int;
	inhandle:	int;
	stroke:	int;		# moved past a tap's slop
	lp:	int;		# its long press is open
	lpalts:	string;
	lpsel:	int;
	repeating:	int;
	gen:	int;
	cancelled:	int;
};
touches: list of ref Tch;
tgen := 0;
fingermode := 0;		# /dev/fingers is read
lastfinger := -100000;		# msec of the last finger landing
ptrsuppress := 0;		# the pointer's press is a finger's
ptrtouch: ref Tch;

# channels
fingerc: chan of (int, int, int, int, int);
lexc: chan of ref Lexicon;
kbdsc: chan of (int, int);
tickc: chan of int;
ctlc: chan of (string, chan of string);
statusc: chan of string;
wordsc: chan of string;

recfd: ref Sys->FD;

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	# a group of its own, which its exit kills: Lucifer starts it
	# with a spawn, in Lucifer's
	sys->pctl(Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	kbdecode = load Kbdecode Kbdecode->PATH;
	osklayout = load Osklayout Osklayout->PATH;
	lucitheme = load Lucitheme Lucitheme->PATH;
	icon = load Icon Icon->PATH;
	if(draw == nil || wmclient == nil || kbdecode == nil || osklayout == nil || lucitheme == nil)
		fatal(sys->sprint("cannot load a module: %r"));
	kbdecode->init();
	osklayout->init();

	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("wm/osk [-sm] [-l layout] [-F fd] [-r tracefile]");
	first := "";
	servefd := -1;
	recfile := "";
	while((c := arg->opt()) != 0)
		case c {
		's' =>	sysmode = 1;
		'm' =>	managed = 1;
		'l' =>	first = arg->earg();
		'F' =>	servefd = int arg->earg();
		'r' =>	recfile = arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	arg = nil;
	if(recfile != nil)
		record(recfile);

	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display = ctxt.display;
	wmclient->init();
	theme = lucitheme->gettheme();
	if(icon != nil && icon->init(display) != nil)
		icon = nil;

	loadlayouts(first);
	ignore = readlines(IGNORE);
	# the word list is read while the keyboard is already typing: until
	# it is, words are typed as they are tapped
	lex = Lexicon.new();
	dec = Decoder.new(lex, nil);
	lexc = chan[1] of ref Lexicon;
	spawn loadwords(lexc);

	fingerc = chan[64] of (int, int, int, int, int);
	kbdsc = chan of (int, int);
	tickc = chan[4] of int;
	ctlc = chan of (string, chan of string);
	statusc = chan[1] of string;
	wordsc = chan[1] of string;

	startserver(servefd);

	win = wmclient->window(ctxt, "osk", Wmclient->Plain);
	win.startinput("ptr" :: nil);	# never the keyboard: it types to whoever has it

	if(sysmode){
		want = 0;
		spawn kbdsproc(kbdsc);
	}
	spawn fingerproc(fingerc);
	sreqc = chan[4] of ref Sreq;
	srepc = chan[4] of (int, array of ref Cand, string);
	spawn suggester(sreqc, srepc);
	restate();
	statuschanged();
	loop();
}

fatal(s: string)
{
	sys->fprint(stderr, "osk: %s\n", s);
	raise "fail:" + s;
}

#
# Layouts and words
#

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

readlines(path: string): list of string
{
	r: list of string;
	(nil, l) := sys->tokenize(readfile(path), "\n");
	for(; l != nil; l = tl l)
		if(len hd l > 0 && (hd l)[0] != '#')
			r = hd l :: r;
	return r;
}

home(): string
{
	h := readfile("/env/home");
	if(h == nil)
		return "/usr/" + readfile("/dev/user");
	return h;
}

statedir(): string
{
	d := home() + "/lib/osk";
	(ok, nil) := sys->stat(d);
	if(ok < 0){
		sys->create(home() + "/lib", Sys->OREAD, Sys->DMDIR|8r755);
		fd := sys->create(d, Sys->OREAD, Sys->DMDIR|8r755);
		if(fd == nil)
			return nil;
	}
	return d;
}

loadlayouts(first: string)
{
	names: list of string;
	for(ls := readlines(ORDER); ls != nil; ls = tl ls){
		(nil, ws) := sys->tokenize(hd ls, " \t");
		for(; ws != nil; ws = tl ws)
			names = hd ws :: names;
	}
	if(names == nil)
		names = "colemak" :: "dvorak" :: "qwerty" :: nil;
	nl: list of ref Layout;
	n := 0;
	for(; names != nil; names = tl names){
		(l, err) := Layout.read(LAYOUTS + "/" + hd names);
		if(l == nil){
			sys->fprint(stderr, "osk: %s\n", err);
			continue;
		}
		nl = l :: nl;
		n++;
	}
	if(n == 0)
		fatal("no letters' layout in " + LAYOUTS);
	letters = array[n] of ref Layout;
	for(i := 0; nl != nil; nl = tl nl)
		letters[i++] = hd nl;
	err: string;
	(sym, err) = Layout.read(LAYOUTS + "/symbols");
	if(sym == nil)
		sys->fprint(stderr, "osk: %s\n", err);
	(more, err) = Layout.read(LAYOUTS + "/more");
	if(more == nil)
		sys->fprint(stderr, "osk: %s\n", err);
	alts = osklayout->alternates(readfile(ALTS));
	# the layout last used, unless one was named
	if(first == nil && (d := statedir()) != nil){
		(nil, f) := sys->tokenize(readfile(d + "/layout"), " \t\n");
		if(f != nil)
			first = hd f;
	}
	cur = 0;
	for(i = 0; i < len letters; i++)
		if(letters[i].name == first)
			cur = i;
	layer = letters[cur];
}

loadwords(c: chan of ref Lexicon)
{
	nl := Lexicon.new();
	err := nl.read(WORDS, 1);
	if(err != nil)
		sys->fprint(stderr, "osk: %s: words are not put right\n", err);
	else if((err = nl.readpairs(PAIRS)) != nil)
		sys->fprint(stderr, "osk: %s: no word before is taken into account\n", err);
	# a word of the typist's counts as a common one: about the 2500th
	# commonest of the list's
	uw := nl.total / 20000.0;
	if(uw < 1.0)
		uw = 1.0;
	if(uw > 1.0e7)
		uw = 1.0e7;
	userweight = int uw;
	if((d := statedir()) != nil){
		userwords = d + "/words";
		nl.read(userwords, userweight);
	}
	c <-= nl;
}

# the word list, read: the decoder is made again on it
newwords(l: ref Lexicon)
{
	lex = l;
	dec = Decoder.new(lex, nil);
	if(img != nil && state == Shown){
		dec.setkeys(letters[cur].dkeys());
		if(layer == letters[cur])
			loadoffsets();
	}
	statuschanged();
}

savelayout()
{
	if((d := statedir()) == nil)
		return;
	fd := sys->create(d + "/layout", Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s\n", letters[cur].name);
}

learnword(w: string)
{
	if(lex.lookup(w) > 0 && !isrejected(w))
		return;
	lex.add(w, userweight);
	if(userwords == nil)
		return;
	fd := sys->open(userwords, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(userwords, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	sys->seek(fd, big 0, Sys->SEEKEND);
	sys->fprint(fd, "%s\t1\n", w);
	statuschanged();
}

offsetsfile(): string
{
	if((d := statedir()) == nil)
		return nil;
	return d + "/offsets." + letters[cur].name;
}

loadoffsets()
{
	if((f := offsetsfile()) != nil && layer == letters[cur])
		dec.setoffsets(readfile(f));
}

saveoffsets()
{
	if((f := offsetsfile()) == nil || layer != letters[cur])
		return;
	s := dec.offsets();
	if(s == nil)
		return;
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

#
# Showing and hiding
#

# what to show, from what has been asked and what is attached
restate()
{
	ns: int;
	if(!sysmode){
		ns = Shown;
		if(userhidden)
			ns = Handle;
	}else if(!(want || !managed && touched) || hwkbd)
		ns = Off;
	else if(userhidden || hardlatch)
		ns = Handle;
	else
		ns = Shown;
	if(ns == state && img != nil)
		return;
	if(ns == state && ns == Off)
		return;
	state = ns;
	place();
	statuschanged();
}

screenr(): Rect
{
	r := win.displayr;
	if(r.dx() <= 0 || r.dy() <= 0)
		r = display.image.r;
	return r;
}

computerowh(sr: Rect): int
{
	if(forcedrowh > 0)
		return forcedrowh;
	h := sr.dy() * 9 / 100;
	w := sr.dx() * 115 / 1000;
	if(w < h)
		h = w;
	if(h < 36)
		h = 36;
	if(h > 120)
		h = 120;
	return h;
}

height(): int
{
	case state {
	Shown =>
		return rowh * 3 / 4 + len layer.rows * rowh + rowh/8;
	Handle =>
		h := rowh * 2 / 3;
		if(h < 24)
			h = 24;
		return h;
	}
	return 0;
}

place()
{
	sr := screenr();
	rowh = computerowh(sr);
	pickfonts();
	h := height();
	e := win.wmctl(sys->sprint("dock bottom %d", h));
	dockok = e == nil;
	if(h == 0){
		if(img != nil)
			win.wmctl("delete .");
		img = nil;
		return;
	}
	# the window manager may give the strip only once it has laid out
	# the screen again; it then asks for the window (wmctl's "!reshape")
	win.r = Rect((sr.min.x, sr.max.y - h), sr.max);
	win.onscreen("exact");
	img = win.image;
	geometry();
	redraw();
}

geometry()
{
	if(img == nil)
		return;
	r := img.r;
	# a window taller than the keyboard (a window manager that does not
	# dock it, as Lucifer's zone for an app): the keys along its bottom
	if(r.dy() > height() && height() > 0)
		r.min.y = r.max.y - height();
	handlerect = r;
	sh := rowh * 3 / 4;
	striprect = Rect(r.min, (r.max.x, r.min.y + sh));
	keysrect = Rect((r.min.x, r.min.y + sh), (r.max.x, r.max.y - rowh/8));
	if(state == Shown){
		layer.place(keysrect);
		dec.setkeys(letters[cur].dkeys());
		if(layer == letters[cur])
			loadoffsets();
	}
}

pickfonts()
{
	font = pickfont(rowh * 45 / 100, 0);
	sfont = pickfont(rowh * 36 / 100, 0);
}

fontsizes := array[] of {14, 16, 18, 20, 22, 24, 27, 28, 32, 36};

pickfont(px, nil: int): ref Font
{
	best := fontsizes[0];
	for(i := 0; i < len fontsizes; i++)
		if(fontsizes[i] <= px)
			best = fontsizes[i];
	f := Font.open(display, sys->sprint("/fonts/combined/go.%d.font", best));
	if(f == nil)
		f = Font.open(display, "*default*");
	return f;
}

#
# Drawing
#

colour(c: int): ref Image
{
	return display.color(c);
}

redraw()
{
	if(img == nil)
		return;
	img.draw(img.r, colour(theme.header), nil, (0, 0));
	if(state == Handle){
		drawhandle();
		img.flush(Draw->Flushnow);
		return;
	}
	drawstrip();
	for(i := 0; i < len layer.rows; i++)
		for(j := 0; j < len layer.rows[i]; j++)
			drawkey(layer.rows[i][j], 0);
	img.flush(Draw->Flushnow);
}

drawhandle()
{
	r := handlerect;
	sz := r.dy() * 3 / 4;
	c := Point(r.max.x - sz - r.dy()/2, r.min.y + (r.dy() - sz)/2);
	glyph("keyboard", Rect(c, c.add((sz, sz))), theme.text2);
}

glyph(name: string, r: Rect, col: int): int
{
	if(icon == nil)
		return 0;
	(i, m, err) := icon->paint(name, r.dx(), col);
	if(err != nil || i == nil)
		return 0;
	img.draw(r, i, m, (0, 0));
	return 1;
}

keylabel(k: ref Lkey): (string, string)	# text, or glyph name
{
	case k.kind {
	Osklayout->Kchar =>
		c := k.c;
		if(shift != Unshifted)
			c = k.shifted;
		s := "";
		s[0] = c;
		return (s, nil);
	Osklayout->Kshift =>
		if(shift == Locked)
			return (nil, "arrow-big-up-lines");
		return ("shift", "arrow-big-up");
	Osklayout->Kdel =>
		return ("del", "backspace");
	Osklayout->Kenter =>
		return ("enter", "corner-down-left");
	Osklayout->Kspace =>
		return (letters[cur].name, nil);
	Osklayout->Knext =>
		return ("next", "world");
	Osklayout->Kctrl =>
		return ("ctrl", nil);
	Osklayout->Klayer =>
		case k.name {
		"sym" =>	return ("?123", nil);
		"more" =>	return ("=\\<", nil);
		"abc" =>	return ("abc", nil);
		}
		return (k.name, nil);
	Osklayout->Kspecial =>
		case k.name {
		"left" =>	return ("left", "arrow-left");
		"right" =>	return ("right", "arrow-right");
		"up" =>		return ("up", "arrow-up");
		"down" =>	return ("down", "arrow-down");
		}
		return (k.name, nil);
	}
	return (k.name, nil);
}

gap(): int
{
	g := rowh / 14;
	if(g < 2)
		g = 2;
	return g;
}

drawkey(k: ref Lkey, pressed: int)
{
	if(img == nil || state != Shown)
		return;
	g := gap();
	outer := k.r;
	r := outer.inset(g);
	img.draw(outer, colour(theme.header), nil, (0, 0));
	bg := theme.input;
	fg := theme.text;
	if(k.kind != Osklayout->Kchar && k.kind != Osklayout->Kspace)
		bg = theme.border;
	if(k.kind == Osklayout->Kshift && shift != Unshifted || k.kind == Osklayout->Kctrl && ctrl)
		bg = theme.accent;
	if(pressed){
		bg = theme.accent;
		fg = theme.bg;
	}
	img.draw(r, colour(bg), nil, (0, 0));
	(s, gname) := keylabel(k);
	if(gname != nil){
		sz := r.dy() * 55 / 100;
		if(sz > r.dx() - 2*g)
			sz = r.dx() - 2*g;
		c := Point(r.min.x + (r.dx() - sz)/2, r.min.y + (r.dy() - sz)/2);
		if(glyph(gname, Rect(c, c.add((sz, sz))), fg))
			return;
	}
	f := font;
	if(len s > 1)
		f = sfont;
	w := f.width(s);
	p := Point(r.min.x + (r.dx() - w)/2, r.min.y + (r.dy() - f.height)/2);
	img.text(p, colour(fg), (0, 0), f, s);
}

# the key's character large above it, while a finger is on it
drawpreview(k: ref Lkey)
{
	if(img == nil || k.kind != Osklayout->Kchar)
		return;
	(s, nil) := keylabel(k);
	w := k.r.dx() * 13 / 10;
	h := rowh * 11 / 10;
	x := (k.r.min.x + k.r.max.x - w)/2;
	if(x < img.r.min.x)
		x = img.r.min.x;
	if(x + w > img.r.max.x)
		x = img.r.max.x - w;
	y := k.r.min.y - h + gap();
	if(y < img.r.min.y)
		y = img.r.min.y;
	r := Rect((x, y), (x + w, y + h));
	img.draw(r, colour(theme.accent), nil, (0, 0));
	f := pickfont(rowh * 7 / 10, 0);
	tw := f.width(s);
	img.text((x + (w - tw)/2, y + (h - f.height)/2), colour(theme.bg), (0, 0), f, s);
}

drawlongpress(t: ref Tch)
{
	if(img == nil)
		return;
	n := len t.lpalts;
	w := rowh * 9 / 10;
	h := rowh;
	x := t.key.r.min.x;
	if(x + n*w > img.r.max.x)
		x = img.r.max.x - n*w;
	if(x < img.r.min.x)
		x = img.r.min.x;
	y := t.key.r.min.y - h;
	if(y < img.r.min.y)
		y = img.r.min.y;
	for(i := 0; i < n; i++){
		r := Rect((x + i*w, y), (x + (i+1)*w, y + h));
		bg := theme.menubg;
		fg := theme.text;
		if(i == t.lpsel){
			bg = theme.accent;
			fg = theme.bg;
		}
		img.draw(r, colour(bg), nil, (0, 0));
		img.border(r, 1, colour(theme.border), (0, 0));
		s := "";
		s[0] = t.lpalts[i];
		if(shift != Unshifted)
			s[0] = upper(s[0]);
		tw := font.width(s);
		img.text((r.min.x + (w - tw)/2, r.min.y + (h - font.height)/2), colour(fg), (0, 0), font, s);
	}
}

lpindex(t: ref Tch, p: Point): int
{
	n := len t.lpalts;
	w := rowh * 9 / 10;
	x := t.key.r.min.x;
	if(x + n*w > img.r.max.x)
		x = img.r.max.x - n*w;
	if(x < img.r.min.x)
		x = img.r.min.x;
	i := (p.x - x) / w;
	if(i < 0)
		i = 0;
	if(i >= n)
		i = n-1;
	return i;
}

drawstrip()
{
	if(img == nil || state != Shown)
		return;
	r := striprect;
	img.draw(r, colour(theme.header), nil, (0, 0));
	# the hide gesture's handle, at the right
	hz := r.dy() * 3 / 5;
	hc := Point(r.max.x - hz - r.dy()/3, r.min.y + (r.dy() - hz)/2);
	glyph("keyboard-hide", Rect(hc, hc.add((hz, hz))), theme.dim);
	if(sugg == nil)
		return;
	n := len sugg;
	sw := (hc.x - r.min.x) / 3;
	for(i := 0; i < n && i < 3; i++){
		s := sugg[i];
		if(s == nil)
			continue;
		cr := Rect((r.min.x + i*sw, r.min.y), (r.min.x + (i+1)*sw, r.max.y));
		fg := theme.text2;
		if(i == suggauto)
			fg = theme.accent;
		f := sfont;
		for(; f.width(s) > cr.dx() - 8 && len s > 1; )
			s = s[0:len s - 1];
		w := f.width(s);
		img.text((cr.min.x + (cr.dx() - w)/2, cr.min.y + (cr.dy() - f.height)/2), colour(fg), (0, 0), f, s);
		if(i > 0)
			img.draw(Rect((cr.min.x, cr.min.y + cr.dy()/4), (cr.min.x+1, cr.max.y - cr.dy()/4)), colour(theme.border), nil, (0, 0));
	}
}

# the suggestion under p, or -1
suggat(p: Point): int
{
	r := striprect;
	hz := r.dy() * 3 / 5;
	hx := r.max.x - hz - r.dy()/3;
	if(p.x >= hx - r.dy()/3)
		return -2;		# the hide handle
	sw := (hx - r.min.x) / 3;
	if(sw <= 0)
		return -1;
	i := (p.x - r.min.x) / sw;
	if(sugg == nil || i < 0 || i >= len sugg || sugg[i] == nil)
		return -1;
	return i;
}

drawtrail(a, b: Point)
{
	if(img == nil)
		return;
	r := rowh / 12;
	if(r < 2)
		r = 2;
	img.line(a, b, Draw->Enddisc, Draw->Enddisc, r, colour(theme.accent), (0, 0));
	img.flush(Draw->Flushnow);
}

#
# The main loop
#

loop()
{
	for(;;) alt {
	p := <-win.ctxt.ptr =>
		pointer(p);
	(id, x, y, on, ms) := <-fingerc =>
		finger(id, Point(x, y), on, ms);
	(n, last) := <-kbdsc =>
		keyboards(n, last);
	g := <-tickc =>
		tick(g);
	(s, rc) := <-ctlc =>
		rc <-= ctl(s);
	(g, c, corr) := <-srepc =>
		suggested(g, c, corr);
	l := <-lexc =>
		newwords(l);
	s := <-win.ctl or
	s = <-win.ctxt.ctl =>
		wmctl(s);
	k := <-win.ctxt.kbd =>
		k = 0;		# never started; drained by wmclient
	}
}

wmctl(s: string)
{
	if(s == "exit"){
		# all of it: the files' server, the fingers' reader, the
		# suggester and the word list's reader are processes of its
		# group (wmclient's exit kills the group)
		saveoffsets();
		win.wmctl("exit");
		exit;
	}
	if(s == "retheme"){
		theme = lucitheme->gettheme();
		redraw();
		return;
	}
	if(len s > 0 && s[0] == '!'){
		# the window manager moved us, or the screen changed
		if(win.wmctl(s) == nil){
			img = win.image;
			if(img != nil && (rowh != computerowh(screenr()))){
				place();
				return;
			}
			geometry();
			redraw();
		}
		return;
	}
	win.wmctl(s);
}

keyboards(n, last: int)
{
	hw := n > 0;
	if(last == 1)
		hardlatch = 1;
	if(hw != hwkbd || last == 1){
		hwkbd = hw;
		restate();
	}
}

#
# Touches: fingers and the pointer
#

finger(id: int, p: Point, on, ms: int)
{
	record1(sys->sprint("f %d %d %d %d %d", id, p.x, p.y, on, ms));
	if(on && !touched){
		# a touch screen, and no GUI to say when a field takes the
		# keyboard: show it now, if no keyboard is attached
		touched = 1;
		if(sysmode && !managed)
			restate();
	}
	t := findtouch(id);
	if(on && t == nil){
		lastfinger = ms;
		# the pointer's press, made from this finger, is not another touch
		if(ptrtouch != nil && ms - ptrtouch.down < Dupms){
			ptrtouch.cancelled = 1;
			droptouch(ptrtouch);
			ptrtouch = nil;
			ptrsuppress = 1;
		}
		touchdown(id, p, ms);
	}else if(on && t != nil)
		touchmove(t, p);
	else if(!on && t != nil)
		touchup(t, p);
}

pointer(p: ref Pointer)
{
	if(win.pointer(*p))
		return;
	record1(sys->sprint("m %d %d %d %d", p.xy.x, p.xy.y, p.buttons, p.msec));
	b := p.buttons & 7;
	if(b && ptrtouch == nil && !ptrsuppress){
		# a finger is down or has just landed: this is it, again
		if(fingermode && (touches != nil || p.msec - lastfinger < Dupms)){
			ptrsuppress = 1;
			return;
		}
		ptrtouch = touchdown(-1, p.xy, p.msec);
		return;
	}
	if(b == 0){
		ptrsuppress = 0;
		if(ptrtouch != nil){
			t := ptrtouch;
			ptrtouch = nil;
			touchup(t, p.xy);
		}
		return;
	}
	if(ptrtouch != nil)
		touchmove(ptrtouch, p.xy);
}

findtouch(id: int): ref Tch
{
	for(l := touches; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

droptouch(t: ref Tch)
{
	nl: list of ref Tch;
	for(l := touches; l != nil; l = tl l)
		if(hd l != t)
			nl = hd l :: nl;
	touches = nil;
	for(; nl != nil; nl = tl nl)
		touches = hd nl :: touches;
}

ntouches(): int
{
	n := 0;
	for(l := touches; l != nil; l = tl l)
		n++;
	return n;
}

touchdown(id: int, p: Point, ms: int): ref Tch
{
	if(img == nil || !p.in(img.r))
		return nil;
	t := ref Tch(id, ms, p, p, p :: nil, 1, 0.0, nil, nil, 0, 0, 0, 0, nil, 0, 0, ++tgen, 0);
	if(state == Handle){
		t.inhandle = 1;
		touches = t :: touches;
		return t;
	}
	if(p.in(striprect))
		t.instrip = 1;
	else{
		t.key = layer.keyat(p);
		t.cur = t.key;
		if(t.key != nil){
			drawkey(t.key, 1);
			drawpreview(t.key);
			img.flush(Draw->Flushnow);
			case t.key.kind {
			Osklayout->Kchar =>
				if(altsfor(t.key.c) != nil)
					spawn timer(Longms, t.gen);
			Osklayout->Kdel =>
				spawn timer(Repeatms, t.gen);
			}
		}
	}
	touches = t :: touches;
	return t;
}

touchmove(t: ref Tch, p: Point)
{
	if(t == nil)
		return;
	d := dist(t.last, p);
	t.travel += d;
	if(t.npath < 512){
		t.path = p :: t.path;
		t.npath++;
	}
	if(t.lp){
		i := lpindex(t, p);
		if(i != t.lpsel){
			t.lpsel = i;
			drawlongpress(t);
			img.flush(Draw->Flushnow);
		}
		t.last = p;
		return;
	}
	slop := real keywidth() * 0.45;
	if(!t.stroke && dist(t.start, p) > slop && !t.repeating){
		t.stroke = 1;
		t.gen = ++tgen;		# no long press now
		if(t.key != nil)
			redraw();
	}
	if(t.stroke){
		if(!t.instrip && !t.inhandle && layer == letters[cur] && swiping && ntouches() == 1
		   && t.key != nil && t.key.kind == Osklayout->Kchar)
			drawtrail(t.last, p);
	}else if(!t.instrip && !t.inhandle && t.key != nil){
		k := layer.keyat(p);
		if(k != t.cur){
			if(t.cur != nil)
				redraw();
			t.cur = k;
			if(k != nil){
				drawkey(k, 1);
				drawpreview(k);
			}
			img.flush(Draw->Flushnow);
		}
	}
	t.last = p;
}

touchup(t: ref Tch, p: Point)
{
	if(t == nil)
		return;
	if(p.x != t.last.x || p.y != t.last.y)
		touchmove(t, p);
	droptouch(t);
	t.gen = ++tgen;
	if(t.cancelled)
		return;
	if(t.inhandle){
		userhidden = 0;
		hardlatch = 0;
		restate();
		return;
	}
	if(t.instrip){
		stripup(t, p);
		return;
	}
	if(t.lp){
		c := t.lpalts[t.lpsel];
		if(shift != Unshifted)
			c = upper(c);
		redraw();
		typechar(c, Touch(0, 0, c), shift != Unshifted);
		unshift();
		return;
	}
	if(t.repeating){
		redraw();
		return;
	}
	if(t.stroke){
		strokeup(t);
		return;
	}
	k := layer.keyat(p);
	redraw();
	if(k != nil)
		press(k, p);
}

stripup(t: ref Tch, p: Point)
{
	dy := p.y - t.start.y;
	dx := p.x - t.start.x;
	if(dx < 0)
		dx = -dx;
	if(dy > rowh && dy > 2*dx){
		hide();
		return;
	}
	if(t.stroke)
		return;
	i := suggat(p);
	if(i == -2){
		hide();
		return;
	}
	if(i >= 0)
		choose(sugg[i]);
}

hide()
{
	userhidden = 1;
	saveoffsets();
	restate();
}

strokeup(t: ref Tch)
{
	pts := array[t.npath] of Point;
	i := t.npath;
	for(l := t.path; l != nil && i > 0; l = tl l)
		pts[--i] = hd l;
	pts = pts[i:];
	if(len pts < 2)
		return;
	a := pts[0];
	b := pts[len pts - 1];
	dx := b.x - a.x;
	dy := b.y - a.y;
	adx := dx;
	if(adx < 0)
		adx = -adx;
	kw := keywidth();
	# down, mostly straight down, across most of the keys: hide
	if(dy > 2*rowh && adx < kw*6/10){
		hide();
		return;
	}
	# from delete, leftwards: delete a word for each key's width
	if(t.key != nil && t.key.kind == Osklayout->Kdel && dx < -kw){
		n := -dx / (3*kw);
		if(n < 1)
			n = 1;
		for(; n > 0; n--)
			deleteword();
		return;
	}
	if(t.key == nil || t.key.kind != Osklayout->Kchar || layer != letters[cur] || !swiping || ntouches() > 0){
		# not a swipe: the key it ended on, as a tap would
		k := layer.keyat(b);
		if(k != nil)
			press(k, b);
		return;
	}
	path := array[len pts] of Touch;
	for(i = 0; i < len pts; i++)
		path[i] = Touch(pts[i].x, pts[i].y, 0);
	if(wlit != nil)
		endword(" ");
	dec.setcontext(prevword());
	c := dec.swipe(path, 4);
	if(len c == 0){
		k := layer.keyat(b);
		if(k != nil)
			press(k, b);
		return;
	}
	swipeword(c);
}

keywidth(): int
{
	if(len layer.rows == 0 || len layer.rows[0] == 0)
		return 40;
	k := layer.rows[0][0];
	return int (real k.r.dx() / k.width);
}

dist(a, b: Point): real
{
	dx := real (a.x - b.x);
	dy := real (a.y - b.y);
	return math_sqrt(dx*dx + dy*dy);
}

math_sqrt(x: real): real
{
	# Newton, enough for distances in pixels
	if(x <= 0.0)
		return 0.0;
	r := x;
	if(r > 1.0)
		r = x / 2.0;
	for(i := 0; i < 20; i++)
		r = (r + x/r) / 2.0;
	return r;
}

timer(ms, g: int)
{
	sys->sleep(ms);
	tickc <-= g;
}

tick(g: int)
{
	for(l := touches; l != nil; l = tl l){
		t := hd l;
		if(t.gen != g || t.stroke || t.cancelled)
			continue;
		if(t.key == nil)
			return;
		case t.key.kind {
		Osklayout->Kchar =>
			a := altsfor(t.key.c);
			if(a == nil)
				return;
			t.lp = 1;
			t.lpalts = a;
			t.lpsel = 0;
			drawlongpress(t);
			img.flush(Draw->Flushnow);
		Osklayout->Kdel =>
			t.repeating++;
			if(t.repeating > 12 && wlit == nil)
				deleteword();
			else
				del();
			spawn timer(Repeatevery, t.gen);
		}
		return;
	}
}

altsfor(c: int): string
{
	for(l := alts; l != nil; l = tl l){
		(k, s) := hd l;
		if(k == c)
			return s;
	}
	return nil;
}

#
# What the keys do
#

typeit(s: string)
{
	if(s == nil)
		return;
	fd := sys->open("/dev/kbdin", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("/dev/keyboard", Sys->OWRITE);	# an older emu
	if(fd == nil)
		return;
	b := array of byte s;
	sys->write(fd, b, len b);
	record1("t " + quote(s));
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\b'){
			if(len context > 0)
				context = context[0:len context - 1];
		}else
			context[len context] = c;
	}
	if(len context > 64)
		context = context[len context - 64:];
}

quote(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'\n' =>	r += "\\n";
		'\b' =>	r += "\\b";
		'\t' =>	r += "\\t";
		'\\' =>	r += "\\\\";
		* =>	r[len r] = s[i];
		}
	return r;
}

# the character c as a string (string c is its number)
runestr(c: int): string
{
	s := "";
	s[0] = c;
	return s;
}

backspaces(n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s[i] = '\b';
	return s;
}

upper(c: int): int
{
	if(c >= 'a' && c <= 'z')
		return c - 'a' + 'A';
	if(c >= 16rE0 && c <= 16rFE && c != 16rF7)
		return c - 16r20;
	return c;
}

isletter(c: int): int
{
	f := kbdecode->fold(c);
	return f >= 'a' && f <= 'z' || c >= 16rDF && c <= 16rFF && c != 16rF7;
}

isword(c: int): int
{
	return isletter(c) || c == '\'';
}

unshift()
{
	if(shift == Once){
		shift = Unshifted;
		redraw();
		statuschanged();
	}
}

press(k: ref Lkey, p: Point)
{
	case k.kind {
	Osklayout->Kchar =>
		c := k.c;
		if(shift != Unshifted)
			c = k.shifted;
		if(ctrl){
			ctrl = 0;
			if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '@' && c <= '_'){
				endword(nil);
				typeit(runestr(c & 16r1f));
				redraw();
				return;
			}
		}
		t := Touch(p.x, p.y, 0);
		if(layer != letters[cur])
			t = Touch(0, 0, c);
		typechar(c, t, shift != Unshifted);
		unshift();
	Osklayout->Kspace =>
		space();
	Osklayout->Kenter =>
		endword("\n");
	Osklayout->Kdel =>
		del();
	Osklayout->Kshift =>
		now := sys->millisec();
		if(shift == Unshifted)
			shift = Once;
		else if(shift == Once && now - lastshift < Doubletapms)
			shift = Locked;
		else
			shift = Unshifted;
		lastshift = now;
		redraw();
		statuschanged();
	Osklayout->Kctrl =>
		ctrl = !ctrl;
		redraw();
	Osklayout->Klayer =>
		case k.name {
		"sym" =>	if(sym != nil) layer = sym;
		"more" =>	if(more != nil) layer = more;
		* =>		layer = letters[cur];
		}
		relayer();
	Osklayout->Knext =>
		saveoffsets();
		endword(nil);
		cur = (cur + 1) % len letters;
		layer = letters[cur];
		savelayout();
		relayer();
		statuschanged();
	Osklayout->Kspecial =>
		endword(nil);
		typeit(runestr(k.c));
		forget();
	}
}

relayer()
{
	if(len layer.rows != len letters[cur].rows)
		place();	# another height
	else{
		geometry();
		redraw();
	}
}

# a character typed: into the word if it is a letter, else the word ends
typechar(c: int, t: Touch, capped: int)
{
	swiped = 0;
	rv = 0;
	if(isword(c) && (wlit != nil || c != '\'')){
		wtaps = appendtouch(wtaps, t);
		wcaps = appendint(wcaps, capped);
		wlit[len wlit] = c;
		typeit(runestr(c));
		suggest();
		return;
	}
	s := "";
	s[0] = c;
	endword(s);
}

appendtouch(a: array of Touch, t: Touch): array of Touch
{
	b := array[len a + 1] of Touch;
	b[0:] = a;
	b[len a] = t;
	return b;
}

appendint(a: array of int, v: int): array of int
{
	b := array[len a + 1] of int;
	b[0:] = a;
	b[len a] = v;
	return b;
}

space()
{
	now := sys->millisec();
	# two spaces after a word: the end of a sentence
	if(mode == Text && wlit == nil && !rv && now - lastspace < 600 && len context >= 2
	   && context[len context - 1] == ' ' && isword(context[len context - 2])){
		typeit("\b. ");
		lastspace = 0;
		shift = Once;
		redraw();
		statuschanged();
		return;
	}
	hadword := wlit != nil || swiped;
	endword(" ");
	if(hadword)
		lastspace = now;
}

# the word ends with boundary (nil: it ends, nothing typed after it)
endword(boundary: string)
{
	swiped = 0;
	if(wlit == nil){
		typeit(boundary);
		autocap();
		clearsugg();
		return;
	}
	lit := wlit;
	taps := wtaps;
	caps := wcaps;
	word := lit;
	if(mode == Text && correcting && boundary != nil && !isrejected(lit)){
		dec.setcontext(prevword());
		c := dec.taps(taps, 4);
		corr := dec.correct(taps, c);
		if(corr != nil){
			word = withcase(corr, caps);
			if(word == lit)
				word = lit;
		}
	}
	if(word != lit){
		typeit(backspaces(len lit) + word + boundary);
		rv = 1;
		rvlit = lit;
		rvword = word;
		rvbound = boundary;
		rvtaps = taps;
		rvcaps = caps;
		record1("c " + lit + " " + word);
	}else{
		typeit(boundary);
		rv = 0;
		if(boundary != nil)
			typed(lit);
	}
	learntaps(taps, word);
	wlit = nil;
	wtaps = nil;
	wcaps = nil;
	autocap();
	clearsugg();
}

# a word committed as typed: one not in the list, typed twice, is learned
typed(w: string)
{
	if(lex.lookup(w) > 0 || len w < 2 || !kbdecode->wordlike(w))
		return;
	np: list of (string, int);
	n := 0;
	for(l := pending; l != nil; l = tl l){
		(pw, pn) := hd l;
		if(pw == w)
			n = pn;
		else
			np = (pw, pn) :: np;
	}
	n++;
	if(n >= 2 || isrejected(w)){
		learnword(w);
		pending = np;
		return;
	}
	pending = (w, n) :: np;
}

isrejected(w: string): int
{
	for(l := rejected; l != nil; l = tl l)
		if(hd l == w)
			return 1;
	return 0;
}

# where the taps landed, for the letters of the word they were meant as
learntaps(taps: array of Touch, word: string)
{
	if(len taps != len word || lex.lookup(word) == 0)
		return;
	for(i := 0; i < len taps; i++)
		dec.learn(kbdecode->fold(word[i]), taps[i]);
}

withcase(w: string, caps: array of int): string
{
	n := 0;
	for(i := 0; i < len caps; i++)
		if(caps[i])
			n++;
	if(len caps > 1 && n == len caps){
		r := "";
		for(i = 0; i < len w; i++)
			r[i] = upper(w[i]);
		return r;
	}
	if(len caps > 0 && caps[0] && len w > 0){
		r := w;
		r[0] = upper(r[0]);
		return r;
	}
	return w;
}

autocap()
{
	if(mode != Text || shift != Unshifted)
		return;
	n := len context;
	if(n >= 2 && context[n-1] == ' ' && (context[n-2] == '.' || context[n-2] == '?' || context[n-2] == '!')
	   || n >= 1 && context[n-1] == '\n' && n >= 2 && context[n-2] != '\n'){
		if(context[n-1] == '\n')
			return;		# a new line is not a new sentence in code
		shift = Once;
		redraw();
		statuschanged();
	}
}

del()
{
	if(rv){
		# taking back the correction just made
		rv = 0;
		typeit(backspaces(len rvword + len rvbound) + rvlit);
		rejected = rvlit :: rejected;
		wlit = rvlit;
		wtaps = rvtaps;
		wcaps = rvcaps;
		record1("u " + rvlit);
		suggest();
		return;
	}
	if(swiped){
		swiped = 0;
		typeit(backspaces(len swipedtext));
		clearsugg();
		return;
	}
	typeit("\b");
	if(wlit != nil){
		wlit = wlit[0:len wlit - 1];
		wtaps = wtaps[0:len wtaps - 1];
		wcaps = wcaps[0:len wcaps - 1];
		if(wlit == nil)
			clearsugg();
		else
			suggest();
	}
}

deleteword()
{
	rv = 0;
	if(wlit != nil){
		typeit(backspaces(len wlit));
		wlit = nil;
		wtaps = nil;
		wcaps = nil;
		clearsugg();
		return;
	}
	if(swiped){
		del();
		return;
	}
	# what was typed here before: back over blanks, then the word
	n := 0;
	i := len context - 1;
	for(; i >= 0 && (context[i] == ' ' || context[i] == '\t'); i--)
		n++;
	for(; i >= 0 && !(context[i] == ' ' || context[i] == '\t' || context[i] == '\n'); i--)
		n++;
	if(n == 0)
		n = 1;
	typeit(backspaces(n));
}

# the word typed before the one being typed: the word of the context
# before the word being typed (and the blanks after it), if a sentence
# has not ended since
prevword(): string
{
	i := len context - 1 - len wlit;
	for(; i >= 0 && (context[i] == ' ' || context[i] == '\t'); i--)
		;
	e := i + 1;
	for(; i >= 0 && isword(context[i]); i--)
		;
	if(e - (i+1) <= 0)
		return nil;
	return context[i+1:e];
}

# the caret is somewhere this keyboard did not put it
forget()
{
	wlit = nil;
	wtaps = nil;
	wcaps = nil;
	rv = 0;
	swiped = 0;
	context = "";
	clearsugg();
}

swipeword(c: array of ref Cand)
{
	rv = 0;
	if(wlit != nil)
		endword(" ");
	pre := "";
	n := len context;
	if(n > 0 && context[n-1] != ' ' && context[n-1] != '\n' && context[n-1] != '\t'
	   && context[n-1] != '(' && context[n-1] != '"')
		pre = " ";
	w := c[0].word;
	if(shift != Unshifted){
		caps := array[len w] of {* => shift == Locked};
		caps[0] = 1;
		w = withcase(w, caps);
	}
	typeit(pre + w);
	unshift();
	record1("s " + w);
	swiped = 1;
	swipedtext = pre + w;
	sugg = array[3] of string;
	for(i := 1; i < len c && i <= 3; i++)
		sugg[i-1] = c[i].word;
	suggauto = -1;
	drawstrip();
	img.flush(Draw->Flushnow);
}

# a suggestion touched: it in place of the word typed (or swiped)
choose(w: string)
{
	if(w == nil)
		return;
	if(swiped){
		pre := "";
		if(len swipedtext > 0 && swipedtext[0] == ' ')
			pre = " ";
		typeit(backspaces(len swipedtext) + pre + w);
		swipedtext = pre + w;
		learnword(w);
		clearsugg();
		return;
	}
	if(wlit == nil)
		return;
	if(w == quoted(wlit))
		w = wlit;
	if(wcaps != nil)
		w = withcase(w, wcaps);
	typeit(backspaces(len wlit) + w + " ");
	if(w == wlit)
		learnword(w);
	learntaps(wtaps, w);
	wlit = nil;
	wtaps = nil;
	wcaps = nil;
	rv = 0;
	lastspace = sys->millisec();
	autocap();
	clearsugg();
}

quoted(w: string): string
{
	return "\"" + w + "\"";
}

# The suggestions are decoded by a process of its own, with a decoder
# of its own on the same words, so that a slow machine's decoding never
# holds up a touch: a request is the word so far, and a reply that is
# not for the word typed now is dropped.
Sreq: adt {
	gen:	int;
	taps:	array of Touch;
	prev:	string;
	correct:	int;
	offsets:	string;		# the main decoder's, when changed
	keys:	array of Kbdecode->Key;
	lex:	ref Lexicon;
};
sreqc: chan of ref Sreq;
srepc: chan of (int, array of ref Cand, string);
sgen := 0;
soffsets := "";

suggester(req: chan of ref Sreq, rep: chan of (int, array of ref Cand, string))
{
	d: ref Decoder;
	l: ref Lexicon;
	for(;;){
		r := <-req;
		# only the latest request matters
		for(;;) alt {
		n := <-req =>
			r = n;
		* =>
			break;
		}
		if(r.lex != l || d == nil){
			l = r.lex;
			d = Decoder.new(l, r.keys);
		}else if(r.keys != nil)
			d.setkeys(r.keys);
		if(r.offsets != nil)
			d.setoffsets(r.offsets);
		d.setcontext(r.prev);
		c := d.taps(r.taps, 6);
		corr: string;
		if(r.correct)
			corr = d.correct(r.taps, c);
		rep <-= (r.gen, c, corr);
	}
}

suggest()
{
	if(wlit == nil){
		clearsugg();
		return;
	}
	o := dec.offsets();
	if(o == soffsets)
		o = nil;
	else
		soffsets = o;
	r := ref Sreq(++sgen, wtaps, prevword(), mode == Text && correcting && !isrejected(wlit), o, letters[cur].dkeys(), lex);
	alt {
	sreqc <-= r =>
		;
	* =>
		# it is busy, with older ones waiting: the oldest goes
		alt {
		<-sreqc =>
			;
		* =>
			;
		}
		sreqc <-= r;
	}
}

# the suggester's answer: shown, if it is for the word as typed now
suggested(g: int, c: array of ref Cand, corr: string)
{
	if(g != sgen || wlit == nil)
		return;
	sugg = array[3] of string;
	suggauto = -1;
	# what was typed, then the likeliest others
	sugg[0] = quoted(wlit);
	j := 1;
	if(corr != nil){
		sugg[1] = withcase(corr, wcaps);
		suggauto = 1;
		j = 2;
	}
	for(i := 0; i < len c && j < 3; i++){
		w := withcase(c[i].word, wcaps);
		if(w == wlit || j == 2 && w == sugg[1])
			continue;
		sugg[j++] = w;
	}
	drawstrip();
	img.flush(Draw->Flushnow);
}

clearsugg()
{
	sugg = nil;
	suggauto = -1;
	if(img != nil && state == Shown){
		drawstrip();
		img.flush(Draw->Flushnow);
	}
}

#
# /dev/fingers and /dev/keyboards
#

fingerproc(c: chan of (int, int, int, int, int))
{
	fd := sys->open("/dev/fingers", Sys->OREAD);
	if(fd == nil)
		return;		# the pointer will do
	fingermode = 1;
	buf := array[128] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		(nf, f) := sys->tokenize(string buf[0:n], " f");
		if(nf < 5)
			continue;
		id := int hd f; f = tl f;
		x := int hd f; f = tl f;
		y := int hd f; f = tl f;
		on := int hd f; f = tl f;
		ms := int hd f;
		c <-= (id, x, y, on, ms);
	}
	fingermode = 0;
}

kbdsproc(c: chan of (int, int))
{
	fd := sys->open("/dev/keyboards", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[4096] of byte;
	lastkind := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			return;
		nk := 0;
		kind := "";
		(nil, lines) := sys->tokenize(string buf[0:n], "\n");
		for(; lines != nil; lines = tl lines){
			(nf, f) := sys->tokenize(hd lines, " ");
			if(nf >= 2 && hd f == "keyboard"){
				if(!ignored(hd lines))
					nk++;
			}else if(nf >= 2 && hd f == "last")
				kind = hd tl f;
		}
		hard := 0;
		if(kind == "hard" && lastkind != "" && lastkind != "hard")
			hard = 1;	# typed on, since it was last read
		if(kind == "hard" && lastkind == "")
			hard = 0;	# what was, before we were here
		lastkind = kind;
		c <-= (nk, hard);
	}
}

ignored(line: string): int
{
	for(l := ignore; l != nil; l = tl l)
		if(contains(lowers(line), lowers(hd l)))
			return 1;
	return 0;
}

lowers(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

contains(s, t: string): int
{
	if(len t == 0)
		return 0;
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

#
# Recording what is touched and typed (osk(1)'s -r): the traces a
# typist's own typing gives, for tests and tuning
#

record(path: string): string
{
	recfd = nil;
	if(path == nil || path == "off")
		return nil;
	recfd = sys->create(path, Sys->OWRITE, 8r644);
	if(recfd == nil)
		return sys->sprint("%s: %r", path);
	return nil;
}

record1(s: string)
{
	if(recfd != nil)
		sys->fprint(recfd, "%s\n", s);
}

recordlayout()
{
	if(recfd == nil || img == nil)
		return;
	l := letters[cur];
	sys->fprint(recfd, "layout %s %d %d %d %d\n", l.name, keysrect.min.x, keysrect.min.y, keysrect.max.x, keysrect.max.y);
}

#
# The control file and the rest of /mnt/osk
#

ctl(s: string): string
{
	(nf, f) := sys->tokenize(s, " \t\n");
	if(nf == 0)
		return nil;
	case hd f {
	"show" =>
		want = 1;
		userhidden = 0;
		hardlatch = 0;
		forget();
		restate();
	"hide" =>
		want = 0;
		saveoffsets();
		forget();
		restate();
	"toggle" =>
		if(state == Shown){
			userhidden = 1;
			saveoffsets();
		}else{
			want = 1;
			userhidden = 0;
			hardlatch = 0;
		}
		restate();
	"layout" =>
		if(nf != 2)
			return "usage: layout name";
		for(i := 0; i < len letters; i++)
			if(letters[i].name == hd tl f){
				saveoffsets();
				endword(nil);
				cur = i;
				layer = letters[cur];
				savelayout();
				relayer();
				statuschanged();
				return nil;
			}
		return "no layout " + hd tl f;
	"mode" =>
		if(nf != 2)
			return "usage: mode text|plain";
		case hd tl f {
		"text" =>	mode = Text;
		"plain" =>	mode = Plain;
		* =>		return "usage: mode text|plain";
		}
		statuschanged();
	"correct" or "swipe" =>
		if(nf != 2 || hd tl f != "on" && hd tl f != "off")
			return sys->sprint("usage: %s on|off", hd f);
		v := hd tl f == "on";
		if(hd f == "correct")
			correcting = v;
		else
			swiping = v;
		statuschanged();
	"height" =>
		if(nf != 2)
			return "usage: height pixels";
		forcedrowh = int hd tl f;
		if(forcedrowh != 0 && forcedrowh < 20)
			return "too small";
		if(state != Off)
			place();
		statuschanged();
	"record" =>
		if(nf != 2)
			return "usage: record file|off";
		e := record(hd tl f);
		if(e == nil)
			recordlayout();
		return e;
	"\u0001keys" =>
		return keyslist();	# the keys file's, not a ctl request
	"learn" =>
		for(f = tl f; f != nil; f = tl f)
			if(kbdecode->wordlike(hd f))
				learnword(hd f);
	"rect" or "ontop" =>
		;	# keyboard avoidance: a docked keyboard needs none
	* =>
		return "unknown ctl request";
	}
	return nil;
}

# the keys shown, where they are: "name minx miny maxx maxy" a line,
# name the character a key types or its word (shift, space, ...)
keyslist(): string
{
	if(img == nil || state != Shown)
		return "";
	r := "";
	for(i := 0; i < len layer.rows; i++)
		for(j := 0; j < len layer.rows[i]; j++){
			k := layer.rows[i][j];
			name := k.name;
			if(k.kind == Osklayout->Kchar){
				name = "";
				name[0] = k.c;
			}
			r += sys->sprint("%s %d %d %d %d\n", name, k.r.min.x, k.r.min.y, k.r.max.x, k.r.max.y);
		}
	return r;
}

statustext(): string
{
	st := "hidden";
	case state {
	Shown =>	st = "shown";
	Handle =>	st = "handle";
	}
	m := "text";
	if(mode == Plain)
		m = "plain";
	on := array[] of {"off", "on"};
	h := 0;
	if(img != nil)
		h = img.r.dy();
	shifts := array[] of {"none", "once", "locked"};
	return sys->sprint("state %s\nlayout %s\nmode %s\ncorrect %s\nswipe %s\nheight %d\nkeyboards %d\nwords %d\nshift %s\n",
		st, letters[cur].name, m, on[correcting], on[swiping], h, hwkbd, lex.nterm, shifts[shift]);
}

statuschanged()
{
	s := statustext();
	alt {
	statusc <-= s =>
		;
	* =>
		# the server has not taken the last one: replace it
		alt {
		<-statusc =>
			;
		* =>
			;
		}
		alt {
		statusc <-= s =>
			;
		* =>
			;
		}
	}
}

Qdir, Qctl, Qstatus, Qwords, Qkeys: con iota;

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "osk";
	d.gid = "osk";
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

startserver(fdn: int)
{
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	if(styx == nil || styxservers == nil || nametree == nil){
		sys->fprint(stderr, "osk: cannot serve its files: %r\n");
		return;
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();
	fd: ref Sys->FD;
	if(fdn >= 0)
		fd = sys->fildes(fdn);
	else{
		p := array[2] of ref Sys->FD;
		if(sys->pipe(p) < 0){
			sys->fprint(stderr, "osk: pipe: %r\n");
			return;
		}
		fd = p[1];
		spawn mountit(p[0]);
	}
	if(fd == nil){
		sys->fprint(stderr, "osk: no fd %d to serve on\n", fdn);
		return;
	}
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, dir("ctl", 8r666, Qctl));
	tree.create(big Qdir, dir("status", 8r444, Qstatus));
	tree.create(big Qdir, dir("words", 8r666, Qwords));
	tree.create(big Qdir, dir("keys", 8r444, Qkeys));
	(tc, srv) := Styxserver.new(fd, Navigator.new(treeop), big Qdir);
	spawn serve(tc, srv, tree);
}

mountit(fd: ref Sys->FD)
{
	if(sys->mount(fd, nil, "/mnt/osk", Sys->MREPL, nil) < 0)
		sys->fprint(stderr, "osk: cannot mount /mnt/osk: %r\n");
}

keystext := "";

Reader: adt {
	fid:	int;
	seen:	int;		# the status generation it last read
	pending:	ref Tmsg.Read;
};

serve(tc: chan of ref Tmsg, srv: ref Styxserver, tree: ref Tree)
{
	status := "";
	gen := 0;
	readers: list of ref Reader;
	for(;;) alt {
	s := <-statusc =>
		if(s == status)
			break;
		status = s;
		gen++;
		for(l := readers; l != nil; l = tl l){
			r := hd l;
			if(r.pending != nil){
				srv.reply(styxservers->readstr(r.pending, status));
				r.pending = nil;
				r.seen = gen;
			}
		}
	tmsg := <-tc =>
		if(tmsg == nil){
			tree.quit();
			return;
		}
		pick tm := tmsg {
		Readerror =>
			tree.quit();
			return;
		Flush =>
			for(l := readers; l != nil; l = tl l)
				if((hd l).pending != nil && (hd l).pending.tag == tm.oldtag)
					(hd l).pending = nil;
			srv.reply(ref Rmsg.Flush(tm.tag));
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			case int c.path {
			Qdir =>
				srv.read(tm);
			Qctl =>
				srv.reply(styxservers->readstr(tm, ""));
			Qstatus =>
				r: ref Reader;
				for(l := readers; l != nil; l = tl l)
					if((hd l).fid == tm.fid)
						r = hd l;
				if(r == nil){
					r = ref Reader(tm.fid, gen, nil);
					readers = r :: readers;
					srv.reply(styxservers->readstr(tm, status));
					break;
				}
				if(tm.offset > big 0 && r.seen == gen){
					# the rest of what it was reading
					srv.reply(styxservers->readstr(tm, status));
					break;
				}
				if(r.seen != gen){
					r.seen = gen;
					tm.offset = big 0;
					srv.reply(styxservers->readstr(tm, status));
					break;
				}
				if(r.pending != nil){
					srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
					break;
				}
				tm.offset = big 0;
				r.pending = tm;
			Qwords =>
				srv.reply(styxservers->readstr(tm, readfile(userwords)));
			Qkeys =>
				if(tm.offset == big 0){
					rc := chan of string;
					ctlc <-= ("\u0001keys", rc);
					keystext = <-rc;
				}
				srv.reply(styxservers->readstr(tm, keystext));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			case int c.path {
			Qctl =>
				rc := chan of string;
				ctlc <-= (string tm.data, rc);
				if((e := <-rc) != nil)
					srv.reply(ref Rmsg.Error(tm.tag, e));
				else
					srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			Qwords =>
				rc := chan of string;
				ws := "";
				(nil, lines) := sys->tokenize(string tm.data, "\n");
				for(; lines != nil; lines = tl lines){
					(nf, f) := sys->tokenize(hd lines, " \t");
					if(nf > 0)
						ws += " " + hd f;
				}
				ctlc <-= ("learn" + ws, rc);
				<-rc;
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			}
		Clunk =>
			nl: list of ref Reader;
			for(l := readers; l != nil; l = tl l)
				if((hd l).fid != tm.fid)
					nl = hd l :: nl;
			readers = nl;
			srv.clunk(tm);
		* =>
			srv.default(tmsg);
		}
	}
}
