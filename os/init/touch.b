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
# A panel has no buttons 2 and 3 and no wheel, so a finger held still is
# button 3 and two dragged are the wheel: touchgest(2) makes them, for
# this panel and a USB touchscreen (mouseusb) alike, and as the hosted
# emulator makes them of a phone's touches.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "touchgest.m";
	touchgest: Touchgest;
	Gest: import touchgest;

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

# the gestures' distances, in this panel's pixels: emu/port/draw-sdl3.c's
# slop, and a step shorter than its 50, the panel being only 480 high
Slop:		con 16;		# pixels a held finger may wander and still be held
Step:		con 40;		# pixels two fingers move for a wheel tick

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	touchgest = load Touchgest Touchgest->PATH;
	if(touchgest == nil){
		sys->print("touch: cannot load %s: %r\n", Touchgest->PATH);
		return;
	}

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
	g := Gest.new("m", Slop, Step);
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

	# the gestures are touchgest(2)'s, tested on their own
	# (tests/touchgest_test.b); here, that this panel's frames reach
	# them: a frame's fingers, and a hold
	buf[2] = byte 1;
	buf[3] = byte (16r80 | 0);
	buf[4] = byte 100;
	buf[5] = byte 0;
	buf[6] = byte 200;
	g := Gest.new("m", Slop, Step);
	e := expect("a tap", g.frame(points(buf, 1), 0), "m 100 200 1") +
		expect("held", g.tick(Touchgest->Longms), "m 100 200 4");
	buf[3] = byte (16r40 | 0);	# event 1: lifted
	e += expect("a lifted point is no finger", g.frame(points(buf, 1), 0), "m 100 200 0");

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
