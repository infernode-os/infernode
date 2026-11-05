implement Dialpad;

#
# dialpad -- a telephone keypad, for a touch screen.
#
#	wm/dialpad [-q] [-a audiodev] [-p phonedir] [-s speechdir] [-k keysfile] [number]
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
# Each key sounds its Touch-Tone pair while it is held (a tap at least
# Tonems): a row's low tone, 697, 770, 852 or 941 Hz, with a column's
# high one, 1209, 1336 or 1477 Hz, the frequencies Bell Labs chose so
# that no pair is a harmonic of another and speech seldom makes one;
# the high tone a little louder, as a line loses more of it.  They go
# to audiodev (/dev/audio, audio(3)) as 16-bit stereo, paced to the
# time they take, so a held key does not fill the device's queue.  -q
# is silence.  A device that will not open is told once and left.
#
# In a call, a digit is not added to the number: it is sent down the
# line, "dtmf <digit>" written to the phone file, for the menus and
# voicemail at the other end.  What sends it is the platform's (a
# modem's AT+VTS); one that cannot says why, under the number.
#
# The microphone key listens (speechdir/hear, speech9p's) for a number
# or a name, read as dialspeech(2) reads it: "five five five one two",
# "nine one one", "555-1234", or "Mom", "Sarah at work", a name found
# in phonedir/contacts, the address book the agent's contacts tool
# reads.  It is put on the keypad.  Said after "call" or "dial", it is
# dialled after Autodialms, the line under the number saying who; any
# touch or key in that time stops it, so a name heard wrong is not
# rung.
#
# The phone file's reads are the call's state ("<state> <handle>
# <time>", devphone(3)): while a call is dialing, ringing or connected,
# Call is Hang up, which writes "hangup".  Where the platform reports
# no state (Android's own call screen has the call), Call stays Call.
#
# With -k, each time the keys are laid out their places are written to
# keysfile, "name minx miny maxx maxy" a line (as wm/osk's keys file):
# the digits by themselves, star, hash, call, delete and mic, and the
# number shown above them; for a test, an agent, a typist's trace.
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
include "math.m";
	math: Math;
include "dialspeech.m";
	dialspeech: Dialspeech;

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
# How far up its ascent a digit's middle is, in hundredths: where a
# star in the number is centred.  Measured on the Go fonts' digits.
Digitmid:	con 41;
Maxdigits:	con 64;
Autodialms:	con 3000;	# a number said after "call" is dialled after this
Hearms:		con 5000;	# listened for this long
Heartimeout:	con 30000;	# and its words waited for this long

# The tones
Rate:		con 44100;
Tonems:		con 120;	# a tap sounds at least this long
Chunkms:	con 10;	# written this much at a time
Leadms:		con 40;	# kept at most this far ahead of the clock
Attackms:	con 3;	# faded in and out over these, not clicked
Releasems:	con 6;
Idlems:		con 3000;	# the device let go after this long quiet
Lowamp:		con 9000.0;	# of 32767: together under full scale
Highamp:	con 11000.0;
lowhz := array[] of {697, 770, 852, 941};
highhz := array[] of {1209, 1336, 1477, 1633};

# what a key does
Kdigit, Kcall, Kdel, Kmic: con iota;

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
speechdir := "/mnt/speech";
listening := 0;		# a mic's words awaited, from hear number listening
hearc: chan of (int, string, string);	# (listening, words, why not)
dialing := 0;		# a call said, to be dialled when dialc says
dialc: chan of int;
audiodev := "/dev/audio";
quiet := 0;
tonec: chan of int;		# the key sounding, 0 for none
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
swallow := 0;		# the touch that stopped a call said, until let go
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
		arg->setusage("wm/dialpad [-q] [-a audiodev] [-p phonedir] [-s speechdir] [-k keysfile] [number]");
		while((o := arg->opt()) != 0)
			case o {
			'q' =>	quiet = 1;
			'a' =>	audiodev = arg->earg();
			'p' =>	phonedir = arg->earg();
			's' =>	speechdir = arg->earg();
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
	hearc = chan[4] of (int, string, string);
	dialc = chan[4] of int;
	tonec = chan[16] of int;
	math = load Math Math->PATH;
	if(!quiet && math != nil)
		spawn sounder();
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
	(h, words, herr) := <-hearc =>
		if(h == listening && h > 0)
			heard(words, herr);
	g := <-dialc =>
		if(g == dialing && g > 0){
			dialing = 0;
			call();
			redraw();
		}
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

# In a call, a digit goes down the line rather than into the number.
sendtone(c: int)
{
	s := "";
	s[0] = c;
	if((e := phonewrite("dtmf " + s)) != nil)
		setstatus("tone not sent: " + e, theme.red);
	else
		setstatus("sent " + s, theme.green);
}

istone(c: int): int
{
	return c >= '0' && c <= '9' || c == '*' || c == '#';
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
	if(stopdial())
		return;
	case k {
	'\n' or '\r' =>
		call();
	'\b' or 16r7F =>
		delete();
	27 =>
		number = "";
	* =>
		if(k == Sextile)
			k = '*';
		if(istone(k)){
			sound(k);
			sound(0);
			if(incall){
				sendtone(k);
				break;
			}
		}
		add(k);
	}
	redraw();
}

act(k: ref Key, long: int)
{
	case k.kind {
	Kdigit =>
		if(incall)
			sendtone(k.c);
		else if(long && k.c == '0')
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
	Kmic =>
		listen();
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
	if(p.buttons != 0 && press == nil && stopdial()){
		press = nil;
		swallow = 1;	# the touch that stopped it does nothing else
		return;
	}
	if(swallow){
		if(p.buttons == 0)
			swallow = 0;
		return;
	}
	if(p.buttons & 4){
		# a touch held, or button 3: the key's other meaning, once
		if(press == nil && (k := keyat(p.xy)) != nil){
			press = k;
			pgen++;
			longdone = 1;
			soundkey(k);
			sound(0);
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
			soundkey(k);
			redraw();
		}
		return;
	}
	if(press != nil){
		k := press;
		press = nil;
		pgen++;
		sound(0);
		if(!longdone)
			act(k, 0);
		else
			redraw();
	}
	longdone = 0;
}

#
# Voice
#

listen()
{
	if(listening)
		return;
	if(incall){
		setstatus("not while in a call", theme.text2);
		return;
	}
	if(dialspeech == nil){
		dialspeech = load Dialspeech Dialspeech->PATH;
		if(dialspeech == nil){
			setstatus(sys->sprint("no dialspeech: %r"), theme.red);
			return;
		}
		dialspeech->init();
	}
	(ok, nil) := sys->stat(speechdir + "/hear");
	if(ok < 0){
		setstatus("no speech here: " + speechdir + "/hear", theme.red);
		return;
	}
	listening = ++hears;
	setstatus("listening", theme.accent);
	spawn hear(listening);
	spawn hearlimit(listening);
}
hears := 0;

# The words heard: speechdir/hear started, then read to its end.
hear(n: int)
{
	fd := sys->open(speechdir + "/hear", Sys->ORDWR);
	if(fd == nil){
		hearc <-= (n, nil, sys->sprint("%s/hear: %r", speechdir));
		return;
	}
	b := array of byte sys->sprint("start %d", Hearms);
	if(sys->write(fd, b, len b) != len b){
		hearc <-= (n, nil, sys->sprint("hear: %r"));
		return;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	words := "";
	buf := array[1024] of byte;
	while((r := sys->read(fd, buf, len buf)) > 0)
		words += string buf[0:r];
	if(r < 0){
		hearc <-= (n, nil, sys->sprint("hear: %r"));
		return;
	}
	hearc <-= (n, words, nil);
}

hearlimit(n: int)
{
	sys->sleep(Heartimeout);
	hearc <-= (n, nil, "nothing heard");
}

heard(words, err: string)
{
	listening = 0;
	if(err != nil){
		setstatus(err, theme.red);
		redraw();
		return;
	}
	said := dialspeech->parse(words);
	who: string;
	case said.what {
	Dialspeech->Number =>
		if(len said.number > Maxdigits){
			setstatus("too long a number", theme.red);
			redraw();
			return;
		}
		number = said.number;
		who = number;
	Dialspeech->Name =>
		(num, cname, ckind, e) := dialspeech->lookup(readall(phonedir + "/contacts"), said.name, said.kind);
		if(e != nil){
			setstatus(e, theme.red);
			redraw();
			return;
		}
		number = "";
		for(i := 0; i < len num; i++)
			add(num[i]);	# what a phone dials of it: no blanks, dashes
		who = cname;
		if(ckind != nil)
			who += " (" + ckind + ")";
	* =>
		setstatus("heard nothing to dial", theme.text2);
		redraw();
		return;
	}
	if(said.call && number != ""){
		dialing = ++dials;
		setstatus(sys->sprint("calling %s in %d s: touch to stop", who, Autodialms/1000), theme.green);
		spawn dialafter(dialing);
	}else
		setstatus(who, theme.text2);
	redraw();
}
dials := 0;

dialafter(g: int)
{
	sys->sleep(Autodialms);
	dialc <-= g;
}

# A call said and not yet dialled is stopped: whether there was one.
stopdial(): int
{
	if(!dialing)
		return 0;
	dialing = 0;
	setstatus("stopped", theme.text2);
	redraw();
	return 1;
}

readall(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

#
# Touch tones
#

# The tone of the key under a finger (none for Call and delete).
soundkey(k: ref Key)
{
	if(k != nil && k.kind == Kdigit)
		sound(k.c);
	else
		sound(0);
}

sound(c: int)
{
	if(quiet || tonec == nil)
		return;
	alt {
	tonec <-= c =>
		;
	* =>
		;	# the sounder is behind: a tone dropped, never the keypad held
	}
}

# A key's pair: its row's low tone and its column's high one.
pair(c: int): (int, int)
{
	grid := "123A456B789C*0#D";
	for(i := 0; i < len grid; i++)
		if(grid[i] == c)
			return (lowhz[i/4], highhz[i%4]);
	return (0, 0);
}

# Owns the audio device: sounds the key last sent on tonec until a 0,
# and at least Tonems; lets the device go after Idlems of quiet.
sounder()
{
	fd: ref Sys->FD;
	idlec := chan[16] of int;
	igen := 0;
	cur := 0;		# the key sounding
	held := 0;
	(f1, f2) := (0, 0);
	(ph1, ph2) := (0.0, 0.0);
	frames := 0;		# since the tone began
	t0 := 0;
	minframes := Rate * Tonems / 1000;
	chunk := Rate * Chunkms / 1000;
	for(;;){
		if(cur == 0){
			if(fd != nil){
				igen++;
				spawn idle(igen, idlec);
			}
			alt {
			k := <-tonec =>
				if(k == 0)
					continue;
				if(fd == nil && (fd = opendev()) == nil){
					quiet = 1;
					return;
				}
				cur = k;
				held = 1;
				(f1, f2) = pair(k);
				(ph1, ph2) = (0.0, 0.0);
				frames = 0;
				t0 = sys->millisec();
			g := <-idlec =>
				if(g == igen)
					fd = nil;
			}
			continue;
		}
		# while the key is down, a slide to another changes the pair;
		# once it is let go, nothing more is read until its tone is
		# done, so taps queued behind it each sound in turn
		if(held) alt {
		k := <-tonec =>
			if(k == 0)
				held = 0;
			else if(k != cur){
				cur = k;
				(f1, f2) = pair(k);
			}
		* =>
			;
		}
		end := !held && frames >= minframes;
		n := chunk;
		if(end)
			n = Rate * Releasems / 1000;
		(b, p1, p2) := tone(n, frames, end, f1, f2, ph1, ph2);
		(ph1, ph2) = (p1, p2);
		if(sys->write(fd, b, len b) != len b){
			sys->fprint(stderr, "dialpad: %s: %r: no tones\n", audiodev);
			quiet = 1;
			return;
		}
		frames += n;
		if(end){
			cur = 0;
			continue;
		}
		# no further ahead of the clock than Leadms
		ahead := frames * 1000 / Rate - (sys->millisec() - t0);
		if(ahead > Leadms)
			sys->sleep(ahead - Leadms);
	}
}

opendev(): ref Sys->FD
{
	fd := sys->open(audiodev, Sys->OWRITE);
	if(fd == nil){
		sys->fprint(stderr, "dialpad: %s: %r: no tones\n", audiodev);
		return nil;
	}
	# its format, where it is an audio(3) device: audiodev's ctl beside
	# it.  The output's only ("out"): the format is the device's, not
	# this open's, and a bare "rate" would change the microphone's too,
	# under whatever is recording (speech9p's 16 kHz)
	if(len audiodev >= 5 && audiodev[len audiodev - 5:] == "audio"){
		cfd := sys->open(audiodev + "ctl", Sys->OWRITE);
		if(cfd != nil)
			sys->fprint(cfd, "out rate %d\nout chans 2\nout bits 16\nout enc pcm\n", Rate);
	}
	return fd;
}

idle(g: int, c: chan of int)
{
	sys->sleep(Idlems);
	alt {
	c <-= g =>
		;
	* =>
		;
	}
}

# n frames of the pair, 16-bit little-endian stereo, from frame "at" of
# the tone: faded in over its first Attackms, and out over all n when
# it is the last; the phases after it.
tone(n, at, last, f1, f2: int, ph1, ph2: real): (array of byte, real, real)
{
	b := array[n*4] of byte;
	d1 := 2.0 * Math->Pi * real f1 / real Rate;
	d2 := 2.0 * Math->Pi * real f2 / real Rate;
	attack := Rate * Attackms / 1000;
	for(i := 0; i < n; i++){
		env := 1.0;
		if(at + i < attack)
			env = real (at + i) / real attack;
		if(last)
			env *= real (n - i) / real n;
		v := int (env * (Lowamp * math->sin(ph1) + Highamp * math->sin(ph2)));
		ph1 += d1;
		ph2 += d2;
		b[4*i] = b[4*i+2] = byte v;
		b[4*i+1] = b[4*i+3] = byte (v >> 8);
	}
	# kept small, so sin stays exact over a long hold
	twopi := 2.0 * Math->Pi;
	while(ph1 > twopi)
		ph1 -= twopi;
	while(ph2 > twopi)
		ph2 -= twopi;
	return (b, ph1, ph2);
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
	keys = array[15] of ref Key;
	for(i := 0; i < 12; i++)
		keys[i] = ref Key(Kdigit, digits[i], subs[i], Rect((0, 0), (0, 0)));
	keys[12] = ref Key(Kcall, 0, nil, Rect((0, 0), (0, 0)));
	keys[13] = ref Key(Kdel, 0, nil, Rect((0, 0), (0, 0)));
	keys[14] = ref Key(Kmic, 0, nil, Rect((0, 0), (0, 0)));
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
	keys[14].r = Rect((o.x, yy), (o.x + kw, yy + u));

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
		Kmic =>	name = "mic";
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
	t += sys->sprint("number %d %d %d %d\n", disprect.min.x, disprect.min.y, disprect.max.x, disprect.max.y);
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

# the size below px that pickfont has
smaller(px: int): int
{
	for(i := len fontsizes - 1; i >= 0; i--)
		if(fontsizes[i] < px && (i == 0 || fontsizes[i-1] < fontsizes[i]))
			return fontsizes[i];
	return fontsizes[0];
}

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
		# smaller digits before fewer: a number's start (its +, its
		# country) is what says where it rings.  Only one too long at
		# the smallest size loses its start, to an ellipsis.
		px := disprect.dy() * 55 / 100;
		while(numwidth(f, number) > disprect.dx() && px > fontsizes[0]){
			px = smaller(px);
			f = pickfont(px);
		}
		s := number;
		if(numwidth(f, s) > disprect.dx()){
			while(len s > 1 && numwidth(f, "…" + s) > disprect.dx())
				s = s[1:];
			s = "…" + s;
		}
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
		if(k.c == '*' && icon != nil){
			# the sextile at the key's centre, not set as text
			star(r.min.add(r.max).div(2), starsize(font), fg);
			return;
		}
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
	Kmic =>
		fg := theme.text2;
		if(listening){
			# listening: as a recorder's red light
			img.draw(r, colour(theme.red), nil, (0, 0));
			fg = theme.bg;
		}else if(down)
			fg = theme.accent;
		if(!glyph("microphone", r, fg))
			textin(r, sfont, "Speak", fg);
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
			# centred on the digits' middle, as a keypad's star is
			pad := f.width(" ")/4;
			star(Point(x + pad + sz/2, y + f.ascent - f.ascent*Digitmid/100), sz, col);
			x += sz + 2*pad;
			continue;
		}
		img.text((x, y), colour(col), (0, 0), f, c);
		x += f.width(c);
	}
}

# The sextile, sz pixels square, centred on c.
star(c: Point, sz, col: int)
{
	(gi, m, err) := icon->paint("asterisk", sz, col);
	if(err != nil || gi == nil)
		return;
	p := c.sub((sz/2, sz/2));
	img.draw(Rect(p, p.add((sz, sz))), gi, m, (0, 0));
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
