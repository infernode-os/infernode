implement Camera;

#
# wm/camera: the live camera, in a window.
#
# Shows the feed at /mnt/video/0, a vid9p-schema stream, starting
# camsrv(4) there if nothing is mounted. Holding the feed open is what
# keeps the camera on; exit and, if nothing else is reading, it goes off.
#
#	+, -	move the lens's focus
#	a	autofocus, once
#	q	exit
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "sh.m";

include "i420.m";
	i420: I420;

Camera: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FEED: con "/mnt/video/0";
FOCUSSTEP: con 32;

focus := 512;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	i420 = load I420 I420->PATH;
	if(i420 == nil)
		fatal("cannot load $I420");
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	(w, h) := readfmt();
	if(w == 0){
		sh := load Sh Sh->PATH;
		if(sh != nil)
			sh->system(ctxt, "mount -A {camsrv} /mnt/video");
		(w, h) = readfmt();
	}
	if(w == 0)
		fatal("no feed at " + FEED);

	win := wmclient->window(ctxt, "camera", Wmclient->Appl);
	display := win.display;
	r := Rect((0, 0), (w, h));
	frame := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	if(frame == nil)
		fatal(sys->sprint("cannot allocate a frame: %r"));
	win.reshape(r);
	win.startinput("kbd" :: "ptr" :: nil);
	win.onscreen(nil);

	rgb := array[3*w*h] of byte;
	focus = readfocus();
	cs := (w/2)*(h/2);
	buf := array[w*h + 2*cs] of byte;
	got := chan of string;
	more := chan of int;
	spawn reader(buf, got, more);

	for(;;) alt{
	c := <-win.ctl or
	c = <-win.ctxt.ctl =>
		win.wmctl(c);
		# a new size is a new image, none of it ours yet
		if(c != nil && c[0] == '!'){
			win.image.draw(win.image.r, display.black, nil, Point(0, 0));
			show(win, frame);
		}
	k := <-win.ctxt.kbd =>
		case k {
		'q' =>
			win.wmctl("exit");
		'+' or '=' =>
			setfocus(focus + FOCUSSTEP);
		'-' =>
			setfocus(focus - FOCUSSTEP);
		'a' =>
			ctl("focus auto");
		}
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	e := <-got =>
		if(e != nil)
			fatal(e);
		i420->rgb24(buf[0:w*h], buf[w*h:w*h+cs], buf[w*h+cs:w*h+2*cs], w, h, rgb);
		frame.writepixels(r, rgb);
		show(win, frame);
		more <-= 1;
	}
}

show(w: ref Window, frame: ref Image)
{
	i := w.image;
	o := i.r.min.add(Point((i.r.dx()-frame.r.dx())/2, (i.r.dy()-frame.r.dy())/2));
	i.draw(frame.r.addpt(o), frame, nil, frame.r.min);
	i.flush(Draw->Flushnow);
}

# the server paces this: a read waits for the next frame
reader(buf: array of byte, got: chan of string, more: chan of int)
{
	fd := sys->open(FEED + "/frame", Sys->OREAD);
	if(fd == nil){
		got <-= sys->sprint("%s/frame: %r", FEED);
		return;
	}
	for(;;){
		n := 0;
		while(n < len buf){
			m := sys->read(fd, buf[n:], len buf - n);
			if(m <= 0){
				got <-= sys->sprint("camera: %r");
				return;
			}
			n += m;
		}
		got <-= nil;
		<-more;
	}
}

readfmt(): (int, int)
{
	fd := sys->open(FEED + "/fmt", Sys->OREAD);
	if(fd == nil)
		return (0, 0);
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return (0, 0);
	(nt, t) := sys->tokenize(string b[0:n], " \n");
	if(nt < 2)
		return (0, 0);
	return (int hd t, int hd tl t);
}

# where the lens is: the feed's, not this window's to choose
readfocus(): int
{
	fd := sys->open(FEED + "/ctl", Sys->OREAD);
	if(fd == nil)
		return 512;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 512;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nt, t) := sys->tokenize(hd l, " ");
		if(nt == 2 && hd t == "focus" && int hd tl t >= 0)
			return int hd tl t;
	}
	return 512;
}

setfocus(n: int)
{
	if(n < 0)
		n = 0;
	if(n > 1023)
		n = 1023;
	focus = n;
	ctl(sys->sprint("focus %d", n));
}

ctl(s: string)
{
	fd := sys->open(FEED + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm/camera: %s\n", s);
	raise "fail:error";
}
