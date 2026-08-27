implement Tktest;

#
# Build a widget and check that it drew.
#
# Tk is where a GUI stops being "the screen works" and starts being
# something a program can be written against, so it is worth being
# precise about what this proves and what it does not.
#
# It proves: $Tk registers and loads; Tk->toplevel allocates a top level
# on a real Display; the command parser accepts commands and reports
# errors the way it is supposed to; the packer computes a geometry; and
# the widget actually puts pixels into the toplevel's image, which is
# read back through the draw protocol.
#
# It does not prove that anything reaches the screen. Compositing a
# toplevel onto the display is the window manager's job, and there is no
# window manager here yet -- Tk->toplevel deliberately takes a Display
# rather than a Wmcontext so that it can be used exactly like this,
# without one.
#
# NO TEXT, and that is deliberate rather than lazy. A label would need a
# font, fonts are files, and the root filesystem compiled into this
# kernel does not have any. Testing the widget machinery through a
# coloured frame keeps this a test of Tk rather than a test of whether
# /fonts happens to be mounted -- and fonts are a separate piece of work
# with a separate answer.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Screen, Rect, Point: import draw;

include "tk.m";
	tk: Tk;

Tktest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

#
# Put the toplevel on the screen.
#
# A toplevel starts with no image, and it does not ask for one -- the
# CLIENT offers it, which is the part that is easy to get backwards. Tk
# has a wreq channel, but that carries requests Tk raises later (a menu
# wanting its own window); the first window is placed by whoever created
# the toplevel.
#
# This is what appl/lib/tkclient.b does when there is no window manager
# to ask: allocate a Screen over the display image, take a window from
# it, and hand it to Tk with putimage. The name and request id are the
# two words Tk parses out of a reshape request; -1 is what tkclient's
# onscreen() uses for a request nobody is waiting on an answer to.
#
# Going through a Screen rather than drawing into a private buffer is
# what makes the widget composite onto the real display -- so this puts
# pixels on the panel, and the pixel read back afterwards is one
# somebody could see.
#
mapwindow(t: ref Tk->Toplevel): int
{
	di := t.display.image;
	if(di == nil)
		return -1;

	scr := Screen.allocate(di, t.display.color(Draw->Black), 0);
	if(scr == nil){
		sys->print("tktest: cannot allocate a screen\n");
		return -1;
	}
	di.draw(di.r, scr.fill, nil, scr.fill.r.min);

	r := tk->rect(t, ".", Tk->Border|Tk->Required);
	w := scr.newwindow(r, Draw->Refbackup, Draw->Nofill);
	if(w == nil){
		sys->print("tktest: cannot allocate a window\n");
		return -1;
	}

	e := tk->putimage(t, ". -1", w, nil);
	if(e != nil){
		sys->print("tktest: putimage: %s\n", e);
		return -1;
	}
	return 0;
}

#
# Tk reports failure by returning a string beginning with '!'. An empty
# string is success. Checking it matters more than usual here: a
# mistyped option is not an error the caller sees any other way, and a
# test that ignores the reply passes while building nothing.
#
cmd(t: ref Tk->Toplevel, s: string): int
{
	e := tk->cmd(t, s);
	if(e != nil && e[0] == '!'){
		sys->print("tktest: %s -> %s\n", s, e);
		return -1;
	}
	return 0;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("tktest: cannot load $Draw: %r\n");
		return;
	}
	tk = load Tk Tk->PATH;
	if(tk == nil){
		sys->print("tktest: cannot load $Tk: %r\n");
		return;
	}
	sys->print("tktest: $Tk loaded\n");

	disp := Display.allocate(nil);
	if(disp == nil){
		sys->print("tktest: cannot attach a display: %r\n");
		return;
	}

	t := tk->toplevel(disp, "");
	if(t == nil){
		sys->print("tktest: cannot make a toplevel\n");
		return;
	}
	sys->print("tktest: toplevel made\n");

	#
	# A frame of a size and colour nothing else would produce.
	# 0x336699 differs in all three channels, so a byte-order
	# mistake shows up as the wrong number rather than as a colour
	# that still looks plausible.
	#
	if(cmd(t, "frame .f -width 100 -height 60 -bg #336699") < 0)
		return;
	if(cmd(t, "pack .f") < 0)
		return;
	if(mapwindow(t) < 0)
		return;
	if(cmd(t, "update") < 0)
		return;

	#
	# The parser must also REJECT. A command language that accepts
	# everything has not been tested by anything that succeeds.
	#
	if(tk->cmd(t, "frame .g -nosuchoption 1") == nil)
		sys->print("tktest: parser accepted a bad option\n");
	else
		sys->print("tktest: parser rejects a bad option\n");

	r := tk->rect(t, ".", 0);
	sys->print("tktest: toplevel geometry %dx%d\n", r.dx(), r.dy());

	im := t.image;
	if(im == nil){
		sys->print("tktest: toplevel has no image\n");
		return;
	}

	px := array[16] of byte;
	p := Point(r.min.x + 20, r.min.y + 20);
	one := Rect(p, Point(p.x + 1, p.y + 1));
	n := im.readpixels(one, px);
	if(n < 4){
		sys->print("tktest: readpixels gave %d bytes: %r\n", n);
		return;
	}

	b := int px[0];
	g := int px[1];
	rr := int px[2];
	sys->print("tktest: widget pixel r=%#2.2x g=%#2.2x b=%#2.2x\n", rr, g, b);

	if(rr == 16r33 && g == 16r66 && b == 16r99)
		sys->print("tktest: the widget drew the colour it was given\n");
	else
		sys->print("tktest: WRONG COLOUR -- wanted r=33 g=66 b=99\n");
}
