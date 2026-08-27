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
	Display, Image, Font, Rect, Point, Chans: import draw;

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

	#
	# And text, with the font that needs no files.
	#
	# "*default*" is not a path. libdraw compiles a font into itself
	# -- defont.c, lucm/latin1.9 as a byte array -- and openfont
	# recognises that name and builds a Subfont from it rather than
	# opening anything. On a machine whose root filesystem has no
	# /fonts at all, which is this one, it is the only font there is.
	#
	# Checked in two independent ways, because they can disagree and
	# the disagreement is the interesting case: WIDTH comes from the
	# font's per-character metrics, which are unpacked from the same
	# byte array, while GLYPHS come from the font's image, which has
	# to be allocated on the display and loaded over the draw
	# protocol. A font that measures but does not draw has the
	# metrics and not the image, and looks from the outside like a
	# program with an empty window.
	#
	f := Font.open(disp, "*default*");
	if(f == nil){
		sys->print("drawtest: cannot open the built-in font: %r\n");
		return;
	}
	sys->print("drawtest: opened the built-in font %s, height %d ascent %d\n",
		f.name, f.height, f.ascent);

	w := f.width("drawn on bare metal");
	sys->print("drawtest: that string measures %d pixels\n", w);

	#
	# White ground, black text, so a row through the middle of the
	# line has both. A row rather than a point: a single pixel
	# through a proportional font lands in a gap as often as in a
	# stroke.
	#
	tr := Rect(Point(100, 100), Point(100 + w + 4, 100 + f.height));
	scr.draw(tr, disp.white, nil, Point(0, 0));
	endp := scr.text(Point(102, 100), disp.black, Point(0, 0), f,
		"drawn on bare metal");
	sys->print("drawtest: text advanced to x=%d (from 102)\n", endp.x);
	#
	# Font.bbox is NOT checked. libinterp/draw.c implements it as
	# "place holder for the real thing" -- it returns a zero
	# rectangle whatever it is asked. Nothing here depends on it and
	# Tk does not use it, but a test that asserted anything about it
	# would be asserting the placeholder.
	#

	#
	# Is a ONE-BIT MASK working?
	#
	# Glyphs are drawn as a mask: the font's cache image is GREY1 and
	# memdraw uses it to decide which pixels of the source colour land
	# on the destination. If that path is broken, text advances the
	# right number of pixels and draws nothing -- which is exactly the
	# symptom above -- while ordinary rectangle drawing, which uses no
	# mask at all, keeps working.
	#
	# So test it on its own, away from fonts: a GREY1 image with every
	# bit set, used as the matte for a solid draw. Every pixel under it
	# should change.
	#
	mr := Rect(Point(0, 0), Point(16, 16));
	mask := disp.newimage(mr, draw->GREY1, 0, 0);
	if(mask == nil){
		sys->print("drawtest: cannot allocate a GREY1 image: %r\n");
		return;
	}
	bits := array[2 * 16] of { * => byte 16rFF };	# 16x16 at 1bpp
	nb := mask.writepixels(mr, bits);
	sys->print("drawtest: wrote %d of %d bytes into the mask\n",
		nb, len bits);

	sr := Rect(Point(200, 200), Point(216, 216));
	scr.draw(sr, disp.white, nil, Point(0, 0));
	scr.draw(sr, col, mask, Point(0, 0));
	n = scr.readpixels(Rect(Point(208, 208), Point(209, 209)), px);
	if(n >= 4)
		sys->print("drawtest: through a full mask r=%#2.2x g=%#2.2x b=%#2.2x\n",
			int px[2], int px[1], int px[0]);

	rowpx := array[(w + 4) * 4] of byte;
	y := 100 + f.height / 2;
	row := Rect(Point(100, y), Point(100 + w + 4, y + 1));
	n = scr.readpixels(row, rowpx);
	if(n < len rowpx){
		sys->print("drawtest: text readpixels gave %d of %d: %r\n",
			n, len rowpx);
		return;
	}

	ink := 0;
	for(x := 0; x < w + 4; x++)
		if(int rowpx[x*4] != 16rFF || int rowpx[x*4+1] != 16rFF
		|| int rowpx[x*4+2] != 16rFF)
			ink++;
	sys->print("drawtest: %d of %d pixels on that row are ink\n",
		ink, w + 4);
	if(ink > 0)
		sys->print("drawtest: text drew with the built-in font\n");
	else
		sys->print("drawtest: NO TEXT -- the font measured but drew nothing\n");
}
