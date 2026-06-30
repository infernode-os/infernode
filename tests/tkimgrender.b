implement Tkimgrender;
#
# tkimgrender imgfile [W H]
#
# Deterministic off-screen probe for the dynamic-image display path used
# by canvas-style apps (wm/fractals): allocate an off-screen Draw image,
# draw solid-colour rectangles into it the way the fractal compute proc
# does (Image.draw with a colour source), then composite it into a Tk
# bitmap image via tk->putimage and snapshot the toplevel.
#
# This isolates the migration's *new* surface (off-screen image ->
# putimage -> -image label) from the unchanged compute core, with no
# event loop and therefore no window-manager dependence or busy-wait.
#
include "sys.m"; sys: Sys;
include "draw.m"; draw: Draw;
	Display, Image, Screen, Rect, Point: import draw;
include "tk.m"; tk: Tk;
	Toplevel: import tk;
Tkimgrender: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	stderr := sys->fildes(2);

	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "usage: tkimgrender imgfile [W H]\n");
		raise "fail:usage";
	}
	imgfile := hd argv; argv = tl argv;
	w := 240; h := 180;
	if(len argv >= 2){
		w = int hd argv; argv = tl argv;
		h = int hd argv;
	}

	disp := Display.allocate("");
	if(disp == nil){
		sys->fprint(stderr, "tkimgrender: no display: %r\n");
		raise "fail:display";
	}
	top := tk->toplevel(disp, "");

	tkc(top, ". configure -background #080808");
	tkc(top, "image create bitmap frac");
	# label created against the still-empty bitmap, as wm/fractals buildui does
	tkc(top, "label .l -image frac -borderwidth 0");
	tkc(top, "pack .l");
	tkc(top, "pack propagate . 0");

	# off-screen image, exactly as wm/fractals allocfracimg() does
	iw := w; ih := h - 24;
	if(ih < 1) ih = 1;
	ir: Rect; ir.min = (0, 0); ir.max = (iw, ih);
	fracimg := disp.newimage(ir, disp.image.chans, 0, Draw->Nofill);
	if(fracimg == nil){
		sys->fprint(stderr, "tkimgrender: newimage failed: %r\n");
		raise "fail:newimage";
	}

	# draw recognisable horizontal colour bands the way the compute proc
	# writes scanlines: Image.draw(rect, colour-source, nil, (0,0)).
	cols := array[] of {
		int 16rE8553AFF,	# accent
		int 16rCCCCCCFF,	# text
		int 16r444444FF,	# dim
		int 16r080808FF,	# surface
	};
	bands := array[len cols] of ref Image;
	for(i := 0; i < len cols; i++)
		bands[i] = disp.color(cols[i]);
	bh := ih / len cols;
	if(bh < 1) bh = 1;
	for(y := 0; y < ih; y++){
		bi := (y / bh) % len cols;
		lr: Rect; lr.min = (0, y); lr.max = (iw, y+1);
		fracimg.draw(lr, bands[bi], nil, (0, 0));
	}

	# composite into the Tk bitmap image, exactly as blit() does. With the
	# libtk image-changed notification in place, the bound label picks up
	# the new image with no further "configure -image" needed.
	e := tk->putimage(top, "frac", fracimg, nil);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->fprint(stderr, "tkimgrender: putimage -> %s\n", e);
	tk->cmd(top, sys->sprint(". configure -width %d -height %d", w, h));
	tk->cmd(top, "update");

	# no-wm: own a screen on the display image, give the toplevel an image
	wr: Rect; wr.min = (0, 0); wr.max = (w, h);
	screen := Screen.allocate(disp.image, disp.color(int 16r080808FF), 0);
	winimg := screen.newwindow(wr, Draw->Refbackup, Draw->Nofill);
	tk->putimage(top, ". -1", winimg, nil);
	tk->cmd(top, "update");

	fd := sys->create(imgfile, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "tkimgrender: cannot create %s: %r\n", imgfile);
		raise "fail:create";
	}
	disp.writeimage(fd, winimg);
	sys->fprint(stderr, "tkimgrender: wrote %s (%dx%d)\n", imgfile, w, h);
}

tkc(top: ref Toplevel, c: string)
{
	e := tk->cmd(top, c);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "tkimgrender: %s -> %s\n", c, e);
}
