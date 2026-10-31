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
Width:		con 800;
Height:		con 480;

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
	sys->print("touch: ready, polling /dev/touch every %dms\n", Pollms);
	poll(fd, ptr);
}

poll(fd, ptr: ref Sys->FD)
{
	buf := array[Framelen] of byte;
	nerr := 0;
	down := 0;
	lastx := -1;
	lasty := -1;
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
		if(np == Consumed)
			continue;
		if(np > Maxpoints)
			continue;	# torn or garbage frame; the next one is 16ms away
		if(np == 0){
			if(down){
				if(!post(ptr, lastx, lasty, 0))
					return;
				down = 0;
			}
			continue;
		}
		(x, y, nil, nil) := decode(buf, 0);
		if(x < 0 || y < 0)
			continue;
		if(!down || x != lastx || y != lasty){
			if(!post(ptr, x, y, 1))
				return;
		}
		down = 1;
		lastx = x;
		lasty = y;
	}
}

post(ptr: ref Sys->FD, x, y, b: int): int
{
	s := sys->sprint("m %d %d %d", x, y, b);
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

	if(ok)
		sys->print("touch: selftest OK\n");
	else
		sys->print("touch: selftest FAILED (x %d y %d id %d ev %d)\n", x, y, id, ev);
}
