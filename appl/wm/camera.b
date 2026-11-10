implement Camera;

#
# wm/camera: the live camera, in a window.
#
# Shows the feed at /mnt/video/0, a vid9p-schema stream, starting
# camsrv(4) there if nothing is mounted. Holding the feed open is what
# keeps the camera on: hidden (the window manager says "visible 0") it
# lets go of the feed, and if nothing else is reading the camera goes
# off; shown again, it takes the feed back. Exit, and the same.
#
# How the camera is mounted is not this window's business: whoever
# starts camsrv says (its -r; on a board, the card's camera file), and
# the feed comes upright. The window takes the feed's size as fmt gives
# it, each time it takes the feed.
#
# What is drawn over the picture is the feed's layer/ directory as this
# name space has it (#1095, layers(2)): each file a layer of records,
# stacked in the union's order by bind -a and bind -b, taken off by
# unmount, while the window is up:
#
#	bind -a /mnt/vision/1/layer /mnt/video/0/layer
#
# The feed numbers its frames, as vid9p does: each frame is drawn with
# the records its layers have for it (the newest up to it), and their
# frame=* ones. The window starts at the newest frame and skips ahead
# when it falls behind.
#
#	+, -	move the lens's focus
#	a	autofocus, once
#	q	exit
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "sh.m";

include "i420.m";
	i420: I420;

include "layers.m";
	layers: Layers;
	Stack: import layers;
stack: ref Stack;
font: ref Font;
accent: ref Image;
colours: list of (string, ref Image);

Camera: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FEED: con "/mnt/video/0";

# a frame, as the reader got it
Pic: adt {
	w, h:	int;
	buf:	array of byte;
	n:	int;		# its number in the feed
};
shownframe := -1;		# the number of the frame shown
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
	layers = load Layers Layers->PATH;
	if(layers == nil)
		fatal(sys->sprint("cannot load %s: %r", Layers->PATH));
	if((le := layers->init()) != nil)
		fatal(le);
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
	win := wmclient->window(ctxt, "camera", Wmclient->Appl);
	if(w == 0){
		# no feed: say so in the window rather than vanish
		w = 576;
		h = 324;
		win.reshape(Rect((0, 0), (w, h)));
		win.startinput("kbd" :: "ptr" :: nil);
		win.onscreen(nil);
		note(win, "no camera: nothing at " + FEED);
		idle(win);
	}
	display := win.display;
	stack = Stack.watch(FEED + "/layer");
	font = Font.open(display, "*default*");
	(accent, colours) = layers->themed(display);
	r := Rect((0, 0), (w, h));
	frame := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	if(frame == nil)
		fatal(sys->sprint("cannot allocate a frame: %r"));
	win.reshape(r);
	win.startinput("kbd" :: "ptr" :: nil);
	win.onscreen(nil);

	rgb := array[3*w*h] of byte;
	focus = readfocus();
	got := chan of (string, ref Pic);
	more := chan of int;
	resume := chan of int;
	spawn reader(got, more, resume);
	shown := 1;
	released := 0;		# the reader has let go of the feed and waits for resume

	for(;;) alt{
	c := <-win.ctl or
	c = <-win.ctxt.ctl =>
		# Hidden, the feed is let go at the next frame (the reader is in
		# the middle of one); shown again, it is taken back only if it was
		# let go -- a hide and a show between two frames change nothing.
		if(c == "visible 0")
			shown = 0;
		else if(c == "visible 1"){
			shown = 1;
			if(released){
				released = 0;
				resume <-= 1;
			}
		}
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
	(e, pic) := <-got =>
		if(e != nil){
			# the camera went, or was never there: the reason, in the
			# window, until it is closed
			note(win, "no camera: " + e);
			idle(win);
		}
		if(!shown){
			more <-= 0;	# let go of the feed: the camera may go off
			released = 1;
			continue;
		}
		if(pic.w != w || pic.h != h){
			# the feed changed size while it was let go (turned, or
			# another mode): a new frame, and the window to fit it
			w = pic.w;
			h = pic.h;
			r = Rect((0, 0), (w, h));
			frame = display.newimage(r, Draw->RGB24, 0, Draw->Black);
			if(frame == nil)
				fatal(sys->sprint("cannot allocate a frame: %r"));
			rgb = array[3*w*h] of byte;
			win.reshape(r.addpt(win.image.r.min));	# where it is, the new size
		}
		buf := pic.buf;
		cs := (w/2)*(h/2);
		i420->rgb24(buf[0:w*h], buf[w*h:w*h+cs], buf[w*h+cs:w*h+2*cs], w, h, rgb);
		frame.writepixels(r, rgb);
		shownframe = pic.n;
		show(win, frame);
		more <-= 1;
	}
}

show(w: ref Window, frame: ref Image)
{
	i := w.image;
	o := i.r.min.add(Point((i.r.dx()-frame.r.dx())/2, (i.r.dy()-frame.r.dy())/2));
	i.draw(frame.r.addpt(o), frame, nil, frame.r.min);
	# the feed's layers over it, as they are for this frame
	if(stack != nil)
		layers->draw(stack.due(shownframe), i, frame.r.addpt(o), frame.r.dx(), frame.r.dy(), font, accent, colours);
	i.flush(Draw->Flushnow);
}

# The server paces this: a read of the next frame waits for it. Frames
# are numbered (frame n at n*framesize): it starts at the newest and,
# if it falls behind ("frame expired"), goes on from the newest again.
# It is a camera's window, so it keeps to the live edge: more than
# Behind frames behind the newest (a feed across a network it cannot
# read as fast as the feed makes them) it goes on from the newest, not
# showing seconds-old frames until they expire, while a layer drawn
# over them (a detector's, keyed to frames now) has nothing for them.
# After each frame it waits to be told to go on (1) or to let go of the
# feed (0), in which case it closes it and waits for resume. Each time
# it takes the feed it asks its size, which may have changed meanwhile.
reader(got: chan of (string, ref Pic), more, resume: chan of int)
{
	for(;;){
		(w, h) := readfmt();
		if(w == 0){
			got <-= (sys->sprint("%s/fmt: %r", FEED), nil);
			return;
		}
		pic := ref Pic(w, h, array[w*h + 2*(w/2)*(h/2)] of byte, 0);
		buf := pic.buf;
		fd := sys->open(FEED + "/frame", Sys->OREAD);
		if(fd == nil){
			got <-= (sys->sprint("%s/frame: %r", FEED), nil);
			return;
		}
		f := newest();
		for(;;){
			(n, e) := readat(fd, buf, f);
			if(e == "frame expired"){
				f = newest();
				continue;
			}
			if(n < len buf){
				if(e == nil)
					e = "end of the feed";
				got <-= ("camera: " + e, nil);
				return;
			}
			pic.n = f++;
			if((nf := newest()) - f > Behind)
				f = nf;
			got <-= (nil, pic);
			if(<-more == 0)
				break;
		}
		fd = nil;		# the feed let go: the camera may go off
		<-resume;
	}
}

Behind: con 3;	# frames behind the newest that a reader may be

# frame f, whole, at its offset: (bytes, error)
readat(fd: ref Sys->FD, b: array of byte, f: int): (int, string)
{
	got := 0;
	while(got < len b){
		m := sys->pread(fd, b[got:], len b - got, big f * big len b + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
}

# where a live reader starts: the newest frame (status frames= less one)
# if it is still kept (not below first=), else the next, which a read
# waits for
newest(): int
{
	fd := sys->open(FEED + "/status", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[512] of byte;
	k := sys->read(fd, b, len b);
	if(k <= 0)
		return 0;
	(frames, first) := (0, 0);
	(nil, t) := sys->tokenize(string b[0:k], " \t\n");
	for(; t != nil; t = tl t){
		(key, v) := splitkv(hd t);
		case key {
		"frames" =>	frames = int v;
		"first" =>	first = int v;
		}
	}
	if(frames > first)
		return frames - 1;
	return frames;
}

splitkv(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '=')
			return (s[0:i], s[i+1:]);
	return (s, nil);
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

# a line of text where the picture would be
note(win: ref Window, msg: string)
{
	i := win.image;
	d := win.display;
	i.draw(i.r, d.black, nil, Point(0, 0));
	f := Font.open(d, "*default*");
	if(f != nil){
		p := i.r.min.add(Point(8, i.r.dy()/2 - f.height/2));
		i.text(p, d.white, Point(0, 0), f, msg);
	}
	i.flush(Draw->Flushnow);
	sys->fprint(sys->fildes(2), "wm/camera: %s\n", msg);
}

# nothing more to show: keep the window, with its message, until it goes
idle(win: ref Window)
{
	for(;;) alt{
	c := <-win.ctl or
	c = <-win.ctxt.ctl =>
		win.wmctl(c);
	k := <-win.ctxt.kbd =>
		if(k == 'q')
			win.wmctl("exit");
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	}
}
