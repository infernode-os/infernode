implement Drawtest;

#
# Draw a rectangle and read it back.
#
# This is the end-to-end check for the graphics stack, and it is worth
# saying what "end to end" means here, because the pieces are in four
# different places and only the last of them is board-specific:
#
#	$Draw		libinterp/draw.c -- the builtin module a Limbo
#			program loads. It is a CLIENT of the draw
#			protocol, not an implementation of it.
#	libdraw		the client library $Draw is written against:
#			Display, Image, allocwindow, string drawing.
#	devdraw		os/port/devdraw.c -- serves /dev/draw, and does
#			every pixel of the compositing through libmemdraw.
#	screen.c	the board's half: where the framebuffer is and
#			what shape it is.
#
# A program that loads $Draw, attaches a Display and gets a rectangle of
# the colour it asked for has been through all four. Nothing shorter
# does: attaching alone proves the connection header, not the pixels,
# and the framebuffer test already in the harness proves the pixels but
# writes them from C without going near the draw protocol at all.
#
# The pixel is read back through Image.readpixels -- the protocol's own
# read -- rather than by peeking at the framebuffer, so that what is
# checked is what a graphical program would actually see.
#
# ATTACHING TAKES THE SCREEN. Display.allocate is what calls
# attachscreen, and attachscreen stops the framebuffer console: from
# then on the pixels belong to the draw device and kernel messages go to
# the serial console only. That is the intended behaviour and not a side
# effect of testing -- but it does mean this is not something to run
# absent-mindedly on a machine whose only console is the panel.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Chans: import draw;

Drawtest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("drawtest: cannot load $Draw: %r\n");
		return;
	}
	sys->print("drawtest: $Draw loaded\n");

	disp := Display.allocate(nil);
	if(disp == nil){
		sys->print("drawtest: cannot attach a display: %r\n");
		return;
	}

	scr := disp.image;
	if(scr == nil){
		sys->print("drawtest: display has no image\n");
		return;
	}
	sys->print("drawtest: display %dx%d depth %d chans %s\n",
		scr.r.dx(), scr.r.dy(), scr.depth, scr.chans.text());

	#
	# A colour that cannot be confused with anything already there.
	#
	# Not black, which is what a cleared framebuffer holds, and not
	# white, which is what the console's text is drawn in. A byte
	# value that differs in all three channels also catches a
	# byte-order mistake: red and blue swapped is the classic way for
	# this to be wrong, and it would draw perfectly while reading
	# back the wrong number.
	#
	Colour: con int 16r336699FF;	# r=0x33 g=0x66 b=0x99

	col := disp.color(Colour);
	if(col == nil){
		sys->print("drawtest: cannot allocate a colour\n");
		return;
	}

	r := Rect(Point(10, 10), Point(60, 40));
	scr.draw(r, col, nil, Point(0, 0));

	#
	# Read one pixel back. The rectangle is a single pixel, so the
	# reply is exactly one pixel's worth of bytes -- four here, and
	# checked rather than assumed, because a short read that is not
	# noticed compares uninitialised memory and passes.
	#
	px := array[16] of byte;
	one := Rect(Point(20, 20), Point(21, 21));
	n := scr.readpixels(one, px);
	if(n <= 0){
		sys->print("drawtest: readpixels failed (%d): %r\n", n);
		return;
	}
	if(n < 4){
		sys->print("drawtest: readpixels gave %d bytes, wanted 4\n", n);
		return;
	}

	#
	# x8r8g8b8 with blue at the lowest address, which is what
	# mailbox.c asked the firmware for and what screen.c declares. So
	# the bytes come back b, g, r, x.
	#
	b := int px[0];
	g := int px[1];
	rr := int px[2];
	sys->print("drawtest: pixel r=%#2.2x g=%#2.2x b=%#2.2x\n", rr, g, b);

	if(rr == 16r33 && g == 16r66 && b == 16r99)
		sys->print("drawtest: drew and read back the colour asked for\n");
	else
		sys->print("drawtest: WRONG COLOUR -- wanted r=33 g=66 b=99\n");
}
