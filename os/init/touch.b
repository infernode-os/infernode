implement Touch;

#
# The DSI panel's touch controller, as pointer events.
#
# The kernel's #T serves one file, /dev/touch, and each read of it is
# one 64-byte snapshot of the buffer the firmware fills from the panel's
# FT5406 controller. That layout is the panel's protocol, and the
# protocol lives here rather than in the kernel: the kernel does what a
# Limbo program cannot -- ask the firmware for the buffer, reach the
# uncached memory it lives in, and mark a frame consumed in the way the
# firmware expects -- and this program turns bytes into "m x y b" lines
# on /dev/pointer, which is the interface every pointing device on this
# system already speaks.
#
# Frame layout (the firmware's, verbatim):
#	[0]	device mode
#	[1]	gesture id
#	[2]	number of points: 0..10, or 99 when nothing has changed
#		since the last read (the kernel writes the 99)
#	[3+6i]	bits 7:6 event, bits 3:0 x high nibble
#	[4+6i]	x low byte
#	[5+6i]	bits 7:4 touch id, bits 3:0 y high nibble
#	[6+6i]	y low byte
#	[7+6i]	weight, [8+6i] area -- unused
#
# The first finger is the pointer, with button 1 held while it is down;
# lifting it releases the button. Nothing here is policy about
# orientation: if the board shows the panel mirrored or rotated, that is
# an inversion flag in this program, never a change to the kernel file.
#
# A panel has no buttons 2 and 3 and no wheel, so two gestures stand in
# for them, the ones the hosted emulator makes of a phone's touches
# (emu/port/draw-sdl3.c, INFR-163 and INFR-121), so a finger means the
# same on a Pi as on a phone:
#
#	A finger held still for Longms is button 3: button 1 goes up and
#	button 3 down where the finger is, held until it lifts. That is
#	every context menu (ftree's, wm/dir's, Xenith's, Lucifer's): hold,
#	the menu shows, slide to an item, lift to choose it. Moving more
#	than Slop before then makes it a drag; a lift before then, a tap.
#
#	Two fingers dragged are the wheel: a tick, button 8 or 16 pressed
#	and released (as mouseusb delivers a wheel), at where the fingers
#	are, for each Tick pixels they move; up shows what is below, as a
#	phone scrolls. Button 1, if the first finger had pressed it, goes
#	up first. The gesture lasts until every finger has lifted, so the
#	last one up does not press button 1 where it happens to be.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Touch: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Pollms:		con 16;		# ~60 Hz, the panel's own report rate
Maxerr:		con 100;	# consecutive failed reads before giving up
Framelen:	con 64;
Maxpoints:	con 10;
Consumed:	con 99;
Evlift:		con 1;		# a point's event: 0 down, 1 up, 2 contact
Width:		con 800;
Height:		con 480;

# the gestures: emu/port/draw-sdl3.c's LONGPRESS_MS and LONGPRESS_SLOP_PX,
# and a tick shorter than its TOUCH_SCROLL_TICK_PX (50), the panel being
# only 480 high
Longms:		con 500;	# a finger held this long is button 3
Slop:		con 16;		# pixels a held finger may wander and still be held
Tick:		con 40;		# pixels two fingers move for a wheel tick

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	if(args != nil && tl args != nil && hd tl args == "-t"){
		selftest();
		return;
	}

	fd := sys->open("/dev/touch", Sys->OREAD);
	if(fd == nil){
		sys->print("touch: no panel: %r\n");
		return;
	}
	ptr := sys->open("/dev/pointer", Sys->OWRITE);
	if(ptr == nil){
		sys->print("touch: cannot open /dev/pointer: %r\n");
		return;
	}
	# Every finger, for a program that needs them all (a keyboard on
	# the screen typed with two thumbs): /dev/fingers, pointer(3).  A
	# kernel without it still has the pointer.
	fingers = sys->open("/dev/fingers", Sys->OWRITE);
	sys->print("touch: ready, polling /dev/touch every %dms\n", Pollms);
	poll(fd, ptr);
}

fingers: ref Sys->FD;
Maxid: con 16;			# touch ids are four bits
fon := array[Maxid] of {* => 0};
fx := array[Maxid] of {* => 0};
fy := array[Maxid] of {* => 0};

#
# The frame's points to /dev/fingers: each id on the panel at its
# place, and each id that was and is not, or whose event is a lift,
# lifted.  The panel's ids are the fingers' for as long as they touch.
#
postfingers(buf: array of byte, np: int)
{
	if(fingers == nil)
		return;
	seen := array[Maxid] of {* => 0};
	for(i := 0; i < np; i++){
		(x, y, id, ev) := decode(buf, i);
		if(x < 0 || id < 0 || id >= Maxid)
			continue;
		if(ev == Evlift)
			continue;
		seen[id] = 1;
		if(!fon[id] || fx[id] != x || fy[id] != y){
			fon[id] = 1;
			fx[id] = x;
			fy[id] = y;
			postfinger(id, x, y, 1);
		}
	}
	for(id := 0; id < Maxid; id++)
		if(fon[id] && !seen[id]){
			fon[id] = 0;
			postfinger(id, fx[id], fy[id], 0);
		}
}

postfinger(id, x, y, on: int)
{
	s := sys->sprint("f%d %d %d %d", id, x, y, on);
	a := array of byte s;
	if(sys->write(fingers, a, len a) < 0){
		sys->print("touch: write to /dev/fingers failed: %r\n");
		fingers = nil;
	}
}

poll(fd, ptr: ref Sys->FD)
{
	buf := array[Framelen] of byte;
	nerr := 0;
	g := ref Gest;
	for(;;){
		sys->sleep(Pollms);
		n := sys->read(fd, buf, len buf);
		if(n < Framelen){
			if(++nerr >= Maxerr){
				sys->print("touch: /dev/touch stopped answering\n");
				return;
			}
			continue;
		}
		nerr = 0;
		np := int buf[2];
		out: list of string;
		if(np == Consumed || np > Maxpoints)
			out = g.tick(sys->millisec());	# a finger held still sends nothing new
		else {
			postfingers(buf, np);
			out = g.frame(points(buf, np), sys->millisec());
		}
		for(; out != nil; out = tl out)
			if(!post(ptr, hd out))
				return;
	}
}

# The fingers on the panel in a frame, in its order: those lifted left out.
points(buf: array of byte, np: int): list of (int, int)
{
	l: list of (int, int);
	for(i := np-1; i >= 0; i--){
		(x, y, nil, ev) := decode(buf, i);
		if(x < 0 || y < 0 || ev == Evlift)
			continue;
		l = (x, y) :: l;
	}
	return l;
}

#
# The pointer's state machine: the fingers of each frame in, what to
# write to /dev/pointer out. Apart from the panel and the clock, so
# selftest can drive it.
#
Gest: adt {
	down:	int;	# a button is held: btn
	btn:	int;	# 1, or 4 once a held finger became button 3
	armed:	int;	# the finger may yet be held long enough
	t0:	int;	# when it landed
	x0, y0:	int;	# where
	multi:	int;	# a two-finger drag, until every finger is up
	nf:	int;	# fingers in the last frame
	sy:	int;	# the fingers' y when last counted
	acc:	int;	# pixels moved not yet a tick
	x, y:	int;	# where the pointer is

	frame:	fn(g: self ref Gest, pts: list of (int, int), now: int): list of string;
	tick:	fn(g: self ref Gest, now: int): list of string;
};

Gest.frame(g: self ref Gest, pts: list of (int, int), now: int): list of string
{
	out: list of string;
	nf := len pts;
	if(nf == 0){
		if(g.down)
			out = m(g.x, g.y, 0) :: out;
		g.down = g.armed = g.multi = 0;
		g.nf = 0;
		return rev(out);
	}
	if(nf >= 2 || g.multi){
		if(!g.multi){
			if(g.down)
				out = m(g.x, g.y, 0) :: out;
			g.down = g.armed = 0;
			g.multi = 1;
			g.acc = 0;
		}
		if(nf >= 2){
			(x1, y1) := hd pts;
			(x2, y2) := hd tl pts;
			cy := (y1 + y2) / 2;
			if(nf != g.nf)
				g.sy = cy;	# a finger came or went: the middle jumps
			g.x = (x1 + x2) / 2;
			g.y = cy;
			g.acc += cy - g.sy;
			g.sy = cy;
			# fingers up (y falls): what is below shows, the wheel's down
			for(; g.acc <= -Tick; g.acc += Tick)
				out = m(g.x, g.y, 0) :: m(g.x, g.y, 16) :: out;
			for(; g.acc >= Tick; g.acc -= Tick)
				out = m(g.x, g.y, 0) :: m(g.x, g.y, 8) :: out;
		}
		g.nf = nf;
		return rev(out);
	}
	g.nf = nf;
	(x, y) := hd pts;
	if(!g.down){
		g.down = 1;
		g.btn = 1;
		g.armed = 1;
		g.t0 = now;
		(g.x0, g.y0) = (x, y);
		(g.x, g.y) = (x, y);
		return m(x, y, 1) :: nil;
	}
	if(g.armed && (x-g.x0)*(x-g.x0) + (y-g.y0)*(y-g.y0) > Slop*Slop)
		g.armed = 0;
	if(x != g.x || y != g.y){
		(g.x, g.y) = (x, y);
		out = m(x, y, g.btn) :: out;
	}
	for(t := g.tick(now); t != nil; t = tl t)
		out = hd t :: out;	# after the move
	return rev(out);
}

Gest.tick(g: self ref Gest, now: int): list of string
{
	if(g.down && g.armed && g.btn == 1 && now - g.t0 >= Longms){
		g.armed = 0;
		g.btn = 4;
		return m(g.x, g.y, 4) :: nil;	# button 1 up, button 3 down
	}
	return nil;
}

m(x, y, b: int): string
{
	return sys->sprint("m %d %d %d", x, y, b);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

post(ptr: ref Sys->FD, s: string): int
{
	a := array of byte s;
	if(sys->write(ptr, a, len a) < 0){
		sys->print("touch: write to /dev/pointer failed: %r\n");
		return 0;
	}
	return 1;
}

#
# One point out of a frame: (x, y, id, event). Coordinates are 12-bit
# fields and can exceed the panel; they are clamped to it. A frame too
# short to hold point i gives (-1, -1, -1, -1).
#
decode(buf: array of byte, i: int): (int, int, int, int)
{
	o := 3 + 6*i;
	if(o + 3 >= len buf)
		return (-1, -1, -1, -1);
	xh := int buf[o];
	ev := (xh >> 6) & 3;
	x := ((xh & 15) << 8) | int buf[o+1];
	yh := int buf[o+2];
	id := (yh >> 4) & 15;
	y := ((yh & 15) << 8) | int buf[o+3];
	if(x >= Width)
		x = Width - 1;
	if(y >= Height)
		y = Height - 1;
	return (x, y, id, ev);
}

#
# The decoder and the press/release state machine, checked without a
# panel. This is the only part of the driver an emulator can exercise:
# QEMU does not implement the firmware's touch tags.
#
selftest()
{
	buf := array[Framelen] of { * => byte 0 };
	buf[2] = byte 1;
	buf[3] = byte (16r80 | 2);	# event 2 (contact), x high nibble 2
	buf[4] = byte 16r34;		# x = 0x234 = 564
	buf[5] = byte (16r50 | 1);	# id 5, y high nibble 1
	buf[6] = byte 16rC8;		# y = 0x1C8 = 456
	(x, y, id, ev) := decode(buf, 0);
	ok := x == 564 && y == 456 && id == 5 && ev == 2;

	buf[3] = byte 15;		# x high nibble 15 -> 0xFFF, clamps to 799
	buf[4] = byte 16rFF;
	buf[5] = byte 15;
	buf[6] = byte 16rFF;
	(x, y, nil, nil) = decode(buf, 0);
	ok = ok && x == Width-1 && y == Height-1;

	(x, y, nil, nil) = decode(buf, Maxpoints+1);
	ok = ok && x == -1 && y == -1;

	if(!ok){
		sys->print("touch: selftest FAILED (x %d y %d id %d ev %d)\n", x, y, id, ev);
		return;
	}

	# the gestures: each a run of frames, at times, and what it posts
	one := (100, 200) :: nil;
	g := ref Gest;
	e := expect("a tap", g.frame(one, 0), "m 100 200 1") +
		expect("its lift", g.frame(nil, 50), "m 100 200 0");
	g = ref Gest;
	g.frame(one, 0);
	e += expect("held, not yet long", g.tick(Longms-1), nil) +
		expect("held long: button 3", g.tick(Longms), "m 100 200 4") +
		expect("then nothing more", g.tick(2*Longms), nil) +
		expect("sliding to an item", g.frame((100, 260) :: nil, 2*Longms), "m 100 260 4") +
		expect("lifting chooses it", g.frame(nil, 2*Longms), "m 100 260 0");
	g = ref Gest;
	g.frame(one, 0);
	e += expect("wobbling within the slop", g.frame((110, 205) :: nil, 100), "m 110 205 1") +
		expect("still held", g.frame((110, 205) :: nil, Longms), "m 110 205 4");
	g = ref Gest;
	g.frame(one, 0);
	e += expect("a drag", g.frame((100, 230) :: nil, 100), "m 100 230 1") +
		expect("a drag is no hold", g.tick(5*Longms), nil);
	g = ref Gest;
	g.frame(one, 0);
	e += expect("a second finger lets button 1 go",
			g.frame((100, 200) :: (200, 200) :: nil, 30), "m 100 200 0") +
		expect("up a tick: the wheel's down",
			g.frame((100, 200-Tick) :: (200, 200-Tick) :: nil, 60),
			"m 150 160 16 m 150 160 0") +
		expect("down two ticks: the wheel's up, twice",
			g.frame((100, 200+Tick) :: (200, 200+Tick) :: nil, 90),
			"m 150 240 8 m 150 240 0 m 150 240 8 m 150 240 0") +
		expect("no hold while scrolling", g.tick(5*Longms), nil) +
		expect("one finger left: nothing", g.frame((100, 300) :: nil, 120), nil) +
		expect("nor while it rests", g.tick(10*Longms), nil) +
		expect("all up: nothing to release", g.frame(nil, 150), nil) +
		expect("the next touch is a press", g.frame(one, 200), "m 100 200 1");

	if(e == nil)
		sys->print("touch: selftest OK\n");
	else
		sys->print("touch: selftest FAILED:%s\n", e);
}

# "" if got is want (its lines joined by blanks), else what differed
expect(what: string, got: list of string, want: string): string
{
	s := "";
	for(; got != nil; got = tl got){
		if(s != "")
			s += " ";
		s += hd got;
	}
	if(s == want)
		return "";
	return sys->sprint(" [%s: got '%s', want '%s']", what, s, want);
}
