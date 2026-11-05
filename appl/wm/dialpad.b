implement Dialpad;

#
# dialpad -- a telephone keypad, for a touch screen.
#
#	wm/dialpad [-p phonedir] [-k keysfile] [number]
#
# Twelve keys and Call, as a phone's: the number typed is dialled by a
# write of "dial <number>" to phonedir/phone (/phone, devphone(3)), the
# file an agent's dial tool writes, so what the radio does with it --
# Android's call screen, iOS's confirmation, an AT command on a board's
# modem -- is the platform's, not the keypad's.  Where /phone is a
# phone's, mounted over 9P from a desktop, the call goes out on the
# phone.
#
# A key types when the finger lifts, the key under it then, as wm/osk's
# do: a finger that lands on the wrong key slides to the right one.
# Held (or button 3, which is what a touch held becomes), 0 is +, and
# delete clears the number.  Call with no number dials the last one
# again.  The keyboard types the same: digits, * # +, Backspace,
# Escape to clear, Enter to call.
#
# The phone file's reads are the call's state ("<state> <handle>
# <time>", devphone(3)): while a call is dialing, ringing or connected,
# Call is Hang up, which writes "hangup".  Where the platform reports
# no state (Android's own call screen has the call), Call stays Call.
#
# With -k, each time the keys are laid out their places are written to
# keysfile, "name minx miny maxx maxy" a line (as wm/osk's keys file):
# the digits by themselves, star, hash, call and delete; for a test, an
# agent, a typist's trace.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Rect, Point, Pointer: import draw;
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "lucitheme.m";
	lucitheme: Lucitheme;
include "tk.m";
include "icon.m";
	icon: Icon;
include "arg.m";

Dialpad: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

Longms:		con 500;	# a press this long is a key's other meaning
# The star key's mark is the sextile, six arms 60 degrees apart, one
# upright, as Bell Labs drew it for the Touch-Tone keypad: drawn (the
# asterisk glyph, icon(2)), on the key and in the number, not a font's
# star; what is typed and dialled is the '*' the network takes.  The
# sextile's own rune, typed, is taken for one.
Sextile:	con 16r26B9;
Maxdigits:	con 64;

# what a key does
Kdigit, Kcall, Kdel: con iota;

Key: adt {
	kind:	int;
	c:	int;		# the rune a digit key types
	sub:	string;	# the letters under it
	r:	Rect;
};

stderr: ref Sys->FD;
display: ref Display;
win: ref Window;
img: ref Image;
theme: ref Lucitheme->Theme;
font, sfont: ref Font;

phonedir := "/phone";
keysfile := "";
keystext := "";		# what keysfile holds
number := "";
last := "";		# the number last dialled, for a redial
status := "";
statuscol := 0;
incall := 0;

keys: array of ref Key;
disprect, statusrect: Rect;

press: ref Key;		# the key under a finger that is down
pgen := 0;		# which press a tick is for
longdone := 0;		# the press has had its long meaning
tickc: chan of int;

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	lucitheme = load Lucitheme Lucitheme->PATH;
	icon = load Icon Icon->PATH;
	stderr = sys->fildes(2);
	if(draw == nil || wmclient == nil || lucitheme == nil){
		sys->fprint(stderr, "dialpad: cannot load modules: %r\n");
		raise "fail:load";
	}

	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("wm/dialpad [-p phonedir] [-k keysfile] [number]");
		while((o := arg->opt()) != 0)
			case o {
			'p' =>	phonedir = arg->earg();
			'k' =>	keysfile = arg->earg();
			* =>	arg->usage();
			}
		args = arg->argv();
	}
	if(args != nil)
		for(n := hd args; len n > 0; n = n[1:])
			add(n[0]);

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "dialpad", Wmclient->Appl);
	display = win.display;
	if(icon != nil && icon->init(display) != nil)
		icon = nil;
	theme = lucitheme->gettheme();

	makekeys();
	win.reshape(Rect((0, 0), (300, 460)));
	win.startinput("kbd" :: "ptr" :: nil);
	win.onscreen(nil);
	img = win.image;
	redraw();

	tickc = chan[4] of int;
	eventc := chan of string;
	spawn events(phonedir + "/phone", eventc);

	for(;;) alt {
	s := <-win.ctl or
	s = <-win.ctxt.ctl =>
		wmctl(s);
	p := <-win.ctxt.ptr =>
		if(!win.pointer(*p))
			pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	g := <-tickc =>
		if(g == pgen && press != nil && !longdone){
			longdone = 1;
			act(press, 1);
		}
	l := <-eventc =>
		phoneevent(l);
	}
}

wmctl(s: string)
{
	if(s == "exit"){
		win.wmctl("exit");
		exit;
	}
	if(s == "retheme"){
		win.wmctl(s);	# the frame, which wmclient draws
		theme = lucitheme->gettheme();
		redraw();
		return;
	}
	e := win.wmctl(s);
	if(e == nil && len s > 0 && s[0] == '!'){
		img = win.image;
		redraw();
	}
}

#
# The number
#

add(c: int)
{
	case c {
	'0' to '9' or '*' or '#' =>
		;
	'+' =>
		if(number != "")	# a country's prefix, so first or nowhere
			return;
	* =>
		return;
	}
	if(len number >= Maxdigits)
		return;
	number[len number] = c;
}

delete()
{
	if(len number > 0)
		number = number[0:len number - 1];
}

call()
{
	if(incall){
		if(phonewrite("hangup") == nil)
			setstatus("hanging up", theme.text2);
		return;
	}
	if(number == ""){
		if(last == "")
			return;
		number = last;
	}
	if((e := phonewrite("dial " + number)) != nil){
		setstatus(e, theme.red);
		return;
	}
	last = number;
	setstatus("calling " + number, theme.text2);
}

phonewrite(s: string): string
{
	f := phonedir + "/phone";
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("no phone here: %s: %r", f);
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

setstatus(s: string, col: int)
{
	status = s;
	statuscol = col;
}

# The call's state, from the phone file's reads: "<state> <handle> <time>".
events(f: string, c: chan of string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[512] of byte;
	part := "";
	while((n := sys->read(fd, buf, len buf)) > 0){
		part += string buf[0:n];
		for(;;){
			i := 0;
			while(i < len part && part[i] != '\n')
				i++;
			if(i == len part)
				break;
			c <-= part[0:i];
			part = part[i+1:];
		}
	}
}

phoneevent(l: string)
{
	(nil, f) := sys->tokenize(l, " \t");
	if(f == nil)
		return;
	state := hd f;
	who := "";
	if(tl f != nil)
		who = hd tl f;
	case state {
	"dialing" or "incoming" or "ringing" or "connected" or "active" or "held" =>
		incall = 1;
		setstatus(state + " " + who, theme.green);
	"disconnected" or "ended" or "idle" =>
		incall = 0;
		setstatus("call ended", theme.text2);
	* =>
		return;
	}
	redraw();
}

#
# Input
#

key(k: int)
{
	case k {
	'\n' or '\r' =>
		call();
	'\b' or 16r7F =>
		delete();
	27 =>
		number = "";
	Sextile =>
		add('*');
	* =>
		add(k);
	}
	redraw();
}

act(k: ref Key, long: int)
{
	case k.kind {
	Kdigit =>
		if(long && k.c == '0')
			add('+');
		else
			add(k.c);
	Kdel =>
		if(long)
			number = "";
		else
			delete();
	Kcall =>
		call();
	}
	redraw();
}

keyat(p: Point): ref Key
{
	for(i := 0; i < len keys; i++)
		if(keys[i].r.contains(p))
			return keys[i];
	return nil;
}

pointer(p: Pointer)
{
	if(p.buttons & 4){
		# a touch held, or button 3: the key's other meaning, once
		if(press == nil && (k := keyat(p.xy)) != nil){
			press = k;
			pgen++;
			longdone = 1;
			act(k, 1);
		}
		return;
	}
	if(p.buttons & 1){
		k := keyat(p.xy);
		if(k != press){
			# down, or a slide to another key: it is that key's press now
			press = k;
			longdone = 0;
			pgen++;
			if(k != nil)
				spawn ticker(pgen);
			redraw();
		}
		return;
	}
	if(press != nil){
		k := press;
		press = nil;
		pgen++;
		if(!longdone)
			act(k, 0);
		else
			redraw();
	}
	longdone = 0;
}

ticker(g: int)
{
	sys->sleep(Longms);
	tickc <-= g;
}

#
# Drawing
#

makekeys()
{
	digits := "123456789*0#";
	subs := array[] of {"", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""};
	keys = array[14] of ref Key;
	for(i := 0; i < 12; i++)
		keys[i] = ref Key(Kdigit, digits[i], subs[i], Rect((0, 0), (0, 0)));
	keys[12] = ref Key(Kcall, 0, nil, Rect((0, 0), (0, 0)));
	keys[13] = ref Key(Kdel, 0, nil, Rect((0, 0), (0, 0)));
}

# Units of u: the number 1.4, its status 0.6, then five rows of keys,
# each 1 high and 1.25 wide, with gaps of an eighth.
layout()
{
	r := img.r;
	u := r.dy() * 10 / 78;
	if((w := r.dx() * 10 / 42) < u)
		u = w;
	if(u < 8)
		u = 8;
	kw := u * 5 / 4;
	g := u / 8;
	gw := 3*kw + 2*g;
	gh := 14*u/10 + 6*u/10 + 5*u + 5*g;
	o := Point(r.min.x + (r.dx() - gw)/2, r.min.y + (r.dy() - gh)/2);

	disprect = Rect(o, (o.x + gw, o.y + 14*u/10));
	statusrect = Rect((o.x, disprect.max.y), (o.x + gw, disprect.max.y + 6*u/10));
	y := statusrect.max.y + g;
	for(i := 0; i < 12; i++){
		x := o.x + (i%3)*(kw + g);
		yy := y + (i/3)*(u + g);
		keys[i].r = Rect((x, yy), (x + kw, yy + u));
	}
	yy := y + 4*(u + g);
	keys[12].r = Rect((o.x + kw + g, yy), (o.x + 2*kw + g, yy + u));
	keys[13].r = Rect((o.x + 2*(kw + g), yy), (o.x + 3*kw + 2*g, yy + u));

	font = pickfont(u * 45 / 100);
	sfont = pickfont(u * 20 / 100);
	if(keysfile != nil)
		writekeys();
}

writekeys()
{
	t := "";
	for(i := 0; i < len keys; i++){
		k := keys[i];
		name: string;
		case k.kind {
		Kcall =>	name = "call";
		Kdel =>	name = "delete";
		* =>
			case k.c {
			'*' =>	name = "star";
			'#' =>	name = "hash";
			* =>	name = "";
				name[0] = k.c;
			}
		}
		t += sys->sprint("%s %d %d %d %d\n", name, k.r.min.x, k.r.min.y, k.r.max.x, k.r.max.y);
	}
	if(t == keystext)
		return;
	fd := sys->create(keysfile, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "dialpad: %s: %r\n", keysfile);
		keysfile = nil;
		return;
	}
	b := array of byte t;
	sys->write(fd, b, len b);
	keystext = t;
}

fontsizes := array[] of {14, 16, 18, 20, 22, 24, 27, 28, 32, 36};

pickfont(px: int): ref Font
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

colour(c: int): ref Image
{
	return display.color(c);
}

redraw()
{
	if(img == nil)
		return;
	layout();
	img.draw(img.r, colour(theme.bg), nil, (0, 0));

	# the number, its end in view when it is too long to show whole
	f := pickfont(disprect.dy() * 55 / 100);
	if(number == "")
		textin(disprect, f, "number", theme.dim);
	else{
		s := number;
		while(len s > 1 && numwidth(f, s) > disprect.dx())
			s = s[1:];
		drawnumber(disprect, f, s, theme.text);
	}

	if(status != ""){
		t := status;
		while(len t > 1 && sfont.width(t) > statusrect.dx())
			t = t[0:len t - 1];
		textin(statusrect, sfont, t, statuscol);
	}

	for(i := 0; i < len keys; i++)
		drawkey(keys[i]);
	img.flush(Draw->Flushnow);
}

drawkey(k: ref Key)
{
	r := k.r;
	down := k == press;
	case k.kind {
	Kdigit =>
		bg := theme.input;
		fg := theme.text;
		if(down){
			bg = theme.accent;
			fg = theme.bg;
		}
		img.draw(r, colour(bg), nil, (0, 0));
		img.border(r, 1, colour(theme.border), (0, 0));
		s := "";
		s[0] = k.c;
		h := font.height;
		if(k.sub != "")
			h += sfont.height;
		y := r.min.y + (r.dy() - h)/2;
		drawnumber(Rect((r.min.x, y), (r.max.x, y + font.height)), font, s, fg);
		if(k.sub != "")
			img.text((r.min.x + (r.dx() - sfont.width(k.sub))/2, y + font.height),
				colour(fg), (0, 0), sfont, k.sub);
	Kcall =>
		bg := theme.green;
		name := "phone";
		label := "Call";
		if(incall){
			bg = theme.red;
			name = "phone-off";
			label = "End";
		}
		if(down)
			bg = theme.accent;
		img.draw(r, colour(bg), nil, (0, 0));
		if(!glyph(name, r, theme.bg))
			textin(r, font, label, theme.bg);
	Kdel =>
		fg := theme.text2;
		if(down)
			fg = theme.accent;
		if(number != "" && !glyph("backspace", r, fg))
			textin(r, sfont, "Delete", fg);
	}
}

# A number drawn in f, centred in r, each star a sextile as tall as a
# digit; numwidth is its width.
starsize(f: ref Font): int
{
	return f.height * 6 / 10;
}

numwidth(f: ref Font, s: string): int
{
	w := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '*' && icon != nil)
			w += starsize(f) + f.width(" ")/2;
		else
			w += f.width(s[i:i+1]);
	return w;
}

drawnumber(r: Rect, f: ref Font, s: string, col: int)
{
	x := r.min.x + (r.dx() - numwidth(f, s))/2;
	y := r.min.y + (r.dy() - f.height)/2;
	sz := starsize(f);
	for(i := 0; i < len s; i++){
		c := s[i:i+1];
		if(c == "*" && icon != nil){
			(gi, m, err) := icon->paint("asterisk", sz, col);
			pad := f.width(" ")/4;
			if(err == nil && gi != nil){
				# centred on the digits' middle, as a keypad's star is
				p := Point(x + pad, y + f.ascent - f.ascent*6/10 - sz/2);
				img.draw(Rect(p, p.add((sz, sz))), gi, m, (0, 0));
			}
			x += sz + 2*pad;
			continue;
		}
		img.text((x, y), colour(col), (0, 0), f, c);
		x += f.width(c);
	}
}

textin(r: Rect, f: ref Font, s: string, col: int)
{
	w := f.width(s);
	img.text((r.min.x + (r.dx() - w)/2, r.min.y + (r.dy() - f.height)/2), colour(col), (0, 0), f, s);
}

glyph(name: string, r: Rect, col: int): int
{
	if(icon == nil)
		return 0;
	sz := r.dy() * 55 / 100;
	(i, m, err) := icon->paint(name, sz, col);
	if(err != nil || i == nil)
		return 0;
	c := Point(r.min.x + (r.dx() - sz)/2, r.min.y + (r.dy() - sz)/2);
	img.draw(Rect(c, c.add((sz, sz))), i, m, (0, 0));
	return 1;
}
