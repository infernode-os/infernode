implement Lens;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Rect, Point, Image, Screen, Pointer: import draw;
	display: ref Display;
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "menuhit.m";
	menuhit: Menuhit;
	Menu, Mousectl: import menuhit;

# related to us
disp, screen, back: ref Image;
font: ref Font;
ptrchan: chan of Point;
zoom: int;
window: ref Image;
last: Point;
looked := 0;

Lens: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	menuhit = load Menuhit Menuhit->PATH;
	menu := ref Menu(array[] of {"exit"}, nil, 0);


	display = ctxt.display;	# assume always works
	disp = display.image;
	
	
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	w := wmclient->window(ctxt, "Lens", Wmclient->Appl);
	w.reshape(Rect((0, 0), (300, 300)));
	w.startinput("kbd"::"ptr" :: nil);
	w.onscreen(nil);
	menuhit->init(w);
	back = display.rgb(16r40, 16r40, 16r40);
	font = Font.open(display, "*default*");
	zoom = 5;
	ptrchan = chan of Point;
	newscreen(w.image);
	spawn lens();
	for(;;) alt{
	ctl := <-w.ctl or
	ctl = <-w.ctxt.ctl =>
		w.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!'){
			newscreen(w.image);
			if(looked)
				ptrchan <-= last;
		}
	p := <-w.ctxt.ptr =>
		if(w.pointer(*p))
			;
		else if(p.buttons & 1){
			# Button 1 held: magnify around the pointer.  The window
			# manager (and Lucifer's zone) keeps sending the pointer
			# to the window a press began in until the buttons are
			# up, so a drag reaches past the lens's own window.  On
			# its own, the pointer is only ever over the lens itself,
			# which is all a lens that followed it unpressed showed.
			ptrchan <-= p.xy;
		} else if(p.buttons & (2|4)){
			# Button 2, or button 3 -- the SDL3 gesture layer's
			# long-press on a touchscreen (emu/port/draw-sdl3.c
			# touch_lp_*, INFR-160/163) -- raises the exit menu.
			# Button 1 used to as well, so the lens could never be
			# dragged and showed nothing but its own red fill.
			mc := ref Mousectl(w.ctxt.ptr, p.buttons, p.xy, p.msec);
			n := menuhit->menuhit(p.buttons, mc, menu, nil);
			if(n == 0){
				postnote(1, sys->pctl(0, nil), "kill");
				exit;
			}
		}
	k := <-w.ctxt.kbd =>
		processkbd(k);
	}
}

postnote(t : int, pid : int, note : string) : int
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if (fd == nil)
		return -1;
	if (t == 1)
		note += "grp";
	sys->fprint(fd, "%s", note);
	fd = nil;
	return 0;
}

processkbd(kbd: int)
{
	case kbd {
		'1' or '2' or '3' or '4' or '5' or '6' or '7' or '8' or '9' => zoom = kbd-16r30;
		'0' => zoom = 10;
		* => return;
	}
	if(looked)
		ptrchan <-= last;
}

# The image the lens is drawn in, the size of the window it is given,
# not the one it asked for: in Lucifer's zone the zone, where a 300x300
# image sat in its corner.  Until the first drag it says how to use it.
newscreen(img: ref Image)
{
	window = img;
	screen = display.newimage(Rect((0, 0), (img.r.dx(), img.r.dy())), Draw->RGB24, 0, Draw->Nofill);
	if(screen == nil){
		sys->fprint(sys->fildes(2), "lens: no image memory (screen): %r\n");
		raise "fail:no memory";
	}
	screen.draw(screen.r, back, nil, (0, 0));
	if(font != nil){
		hint := array[] of {"Hold button 1 and drag", "to magnify.  Keys 1-9, 0: zoom"};
		y := (screen.r.dy() - len hint * font.height) / 2;
		for(i := 0; i < len hint; i++){
			x := (screen.r.dx() - font.width(hint[i])) / 2;
			screen.text((x, y), display.white, (0, 0), font, hint[i]);
			y += font.height;
		}
	}
	flush();
}

flush()
{
	window.draw(window.r, screen, nil, (0,0));
	window.flush(Draw->Flushnow);
}

lens()
{
	for(;;) {
		p := <-ptrchan;
		last = p;
		looked = 1;
		z := zoom;
		w := screen.r.dx();
		h := screen.r.dy();
		# the part of the display shown, one pixel of it per z x z square
		sw := (w + z - 1) / z;
		sh := (h + z - 1) / z;
		if(sw > disp.r.dx())
			sw = disp.r.dx();
		if(sh > disp.r.dy())
			sh = disp.r.dy();
		o := p.sub((sw / 2, sh / 2));
		if(o.x < disp.r.min.x)
			o.x = disp.r.min.x;
		if(o.x > disp.r.max.x - sw)
			o.x = disp.r.max.x - sw;
		if(o.y < disp.r.min.y)
			o.y = disp.r.min.y;
		if(o.y > disp.r.max.y - sh)
			o.y = disp.r.max.y - sh;

		# One read of the display and one write of the lens: it was
		# a draw per pixel, thousands for each movement of the mouse.
		src := display.newimage(Rect((0, 0), (sw, sh)), Draw->RGB24, 0, Draw->Nofill);
		if(src == nil)
			continue;
		src.draw(src.r, disp, nil, o);
		pix := array[3 * sw * sh] of byte;
		if(src.readpixels(src.r, pix) != len pix)
			continue;
		out := array[3 * w * h] of byte;
		bpl := 3 * w;
		for(y := 0; y < h; y += z){
			srow := 3 * sw * (y / z);
			drow := bpl * y;
			for(x := 0; x < w; x++){
				si := srow + 3 * (x / z);
				di := drow + 3 * x;
				out[di] = pix[si];
				out[di+1] = pix[si+1];
				out[di+2] = pix[si+2];
			}
			# the rest of this square's rows are the same row
			for(k := 1; k < z && y + k < h; k++)
				out[drow + k * bpl:] = out[drow:drow + bpl];
		}
		screen.writepixels(screen.r, out);
		flush();
	}
}
