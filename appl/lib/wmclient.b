implement Wmclient;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Screen, Rect, Point, Pointer, Wmcontext, Context: import draw;
include "wmlib.m";
	wmlib: Wmlib;
	qword, splitqword, s2r: import wmlib;
include "wmclient.m";
include "lucitheme.m";


# Single subdued window border, applied uniformly to focused and
# unfocused windows so every wm app shows the same calm frame in
# Lucifer's presentation zone.  Focus state is signalled elsewhere
# (cursor, status, content), not by a brighter chrome line.
windowbordercol: int = int 16r1a1a1aff;
screenbg:        int = int 16r000000ff;	# screen fill shown between windows

# INFR-29 kbd safety net.  ctxt.kbd is unbuffered; if the wm sends
# a kbd event to a focused window whose app doesn't read it, the
# wm send blocks and the entire UI freezes.  wmclient.window()
# spawns a default drainer per Window that discards kbd events
# until the app calls startinput("kbd"), at which point the
# drainer exits so the app can read ctxt.kbd directly.
#
# State lives module-private (NOT in the Window adt) so the
# adt's interface signature stays stable — adding fields to
# Window would force a rebuild of every wm app + lucifer.
KbdState: adt {
	ctxt:	ref Draw->Wmcontext;	# identity key
	stop:	chan of int;		# send to terminate drainer
	subscribed:	int;		# set after first startinput("kbd")
};
kbdstates: list of ref KbdState;

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmlib = load Wmlib Wmlib->PATH;
	if(wmlib == nil){
		sys->fprint(sys->fildes(2), "wmclient: cannot load %s: %r\n", Wmlib->PATH);
		raise "fail:bad module";
	}
	wmlib->init();

	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		windowbordercol = th.windowborder;
		screenbg        = th.bg;
	}
}

retheme(w: ref Window)
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		windowbordercol = th.windowborder;
		screenbg        = th.bg;
	}
	drawborder(w);
}

makedrawcontext(): ref Draw->Context
{
	return wmlib->makedrawcontext();
}
		
blankwin: Window;
window(ctxt: ref Draw->Context, title: string, buts: int): ref Window
{
	w := ref blankwin;
	w.ctxt = wmlib->connect(ctxt);
	wmlib->setlabel(w.ctxt, title);
	w.display = ctxt.display;
	w.ctl = chan[2] of string;
	readscreenrect(w);

	# INFR-29 safety net: wm sends kbd events to focused windows on
	# an unbuffered chan.  Apps that don't drain it deadlock the
	# entire UI on the first keypress.  Spawn a default drainer
	# that discards kbd events; startinput("kbd") stops it so apps
	# that subscribe read ctxt.kbd as before.  No app-side change
	# required and Window adt is not extended (keeps wmclient.m's
	# interface signature stable for all callers).
	# stop is buffered (chan[1]) so startinput()'s non-blocking signal
	# can never be lost: under -c0 the spawned drainer may not have
	# parked in its alt yet when startinput fires, and an unbuffered
	# send would then hit the default branch and leave the drainer
	# running — it would then split ctxt.kbd with the real reader, so
	# each got every OTHER key ("two" typed as "w"). With a buffer the
	# signal sticks until the drainer next reaches its alt and exits.
	# (INFR-101.)
	ks := ref KbdState(w.ctxt, chan[1] of int, 0);
	kbdstates = ks :: kbdstates;
	spawn kbddrainer(ks);

	if(buts & Plain)
		return w;

	# the frame (wmlib->Border, the theme's windowborder), unless the
	# window manager frames this window itself (Lucifer's zone, Matrix)
	if(!wmlib->embedded(w.ctxt))
		w.bd = Wmlib->Border;

	w.wmctl("fixedorigin");
	return w;
}

# Default kbd drainer.  Runs until startinput("kbd") sends to the
# corresponding KbdState.stop channel.  Until then, every kbd event
# from the wm is consumed and discarded so the wm send doesn't block.
kbddrainer(ks: ref KbdState)
{
	for(;;) alt {
	<-ks.stop =>
		return;
	<-ks.ctxt.kbd =>
		;	# discard
	}
}

# Find the KbdState entry for a given Wmcontext, or nil.
findkbdstate(ctxt: ref Draw->Wmcontext): ref KbdState
{
	for(l := kbdstates; l != nil; l = tl l)
		if((hd l).ctxt == ctxt)
			return hd l;
	return nil;
}

# A press on the frame is the window manager's (wm/wm's framehit): it
# alone knows where the window really is on the screen.  Nothing here
# is the frame's any more; the app has every event.
Window.pointer(nil: self ref Window, nil: Draw->Pointer): int
{
	return 0;
}

# titlebar requested size might have changed:
# find out what size it's requesting.
sizetb(nil: ref Window)
{
	return;
}

# reshape the image; the space needed for the
# titlebar is added to r.
Window.reshape(w: self ref Window, r: Rect)
{
	w.r = w.screenr(r);
	if(w.screen == nil)
		return;
	w.wmctl(sys->sprint("!reshape . -1 %s", r2s(w.r)));
}

putimage(w: ref Window, i: ref Image)
{
	if(w.screen != nil && i == w.screen.image)
		return;
#	display := w.ctxt.ctxt.display;
	w.screen = Screen.allocate(i, w.display.color(screenbg), 0);
	ir := i.r.inset(w.bd);
	if(ir.dx() < 0)
		ir.max.x = ir.min.x;
	if(ir.dy() < 0)
		ir.max.y = ir.min.y;
	if(ir.dy() < 0)
		ir.max.y = ir.min.y;
	w.image = w.screen.newwindow(ir, Draw->Refnone, Draw->Nofill);
	# INFR-27: Pre-fill w.image with the screen background so that
	# any region the app doesn't paint (notably the 1-pixel ring
	# inside w.image when an app uses w.imager(w.image.r) for its
	# content rect — fractals, keyring, settings, wallet) shows a
	# dark, themed colour instead of undefined display memory
	# (often white). Apps that fill w.image.r themselves overwrite
	# this and pay nothing.
	if(w.image != nil)
		w.image.draw(w.image.r, w.display.color(screenbg), nil, (0, 0));
	drawborder(w);
	w.r = i.r;
}

# return a rectangle suitable to hold image r when the
# titlebar and border are included.
Window.screenr(w: self ref Window, r: Rect): Rect
{
	return r.inset(-w.bd);
}

# return the available space inside r when space for
# border and titlebar is taken away.
Window.imager(w: self ref Window, r: Rect): Rect
{
	r = r.inset(w.bd);
	if(r.dx() < 0)
		r.max.x = r.min.x;
	if(r.dy() < 0)
		r.max.y = r.min.y;
	return r;
}

# draw the frame: w.bd wide, in the theme's windowborder whatever the
# focus, as tkclient's relief solid is.
drawborder(w: ref Window)
{
	if(w.screen == nil)
		return;
	col := w.display.color(windowbordercol);
	i := w.screen.image;
	r := w.screen.image.r;
	i.draw((r.min, (r.min.x+w.bd, r.max.y)), col, nil, (0, 0));
	i.draw(((r.min.x+w.bd, r.min.y), (r.max.x, r.min.y+w.bd)), col, nil, (0, 0));
	i.draw(((r.max.x-w.bd, r.min.y+w.bd), r.max), col, nil, (0, 0));
	i.draw(((r.min.x+w.bd, r.max.y-w.bd), (r.max.x-w.bd, r.max.y)), col, nil, (0, 0));
}

readscreenrect(w: ref Window)
{
	if((fd := sys->open("/chan/wmrect", Sys->OREAD)) != nil){
		buf := array[12*4] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0){
			(w.displayr, nil) = s2r(string buf[0:n], 0);
			return;
		}
	}
	w.displayr = w.display.image.r;
}

Window.onscreen(w: self ref Window, how: string)
{
	if(how == nil)
		how = "place";
	w.wmctl(sys->sprint("!reshape . -1 %s %q", r2s(w.r), how));
}

Window.startinput(w: self ref Window, devs: list of string)
{
	for(; devs != nil; devs = tl devs) {
		# INFR-29 safety net: an app subscribing to kbd takes
		# ownership of ctxt.kbd, so signal the default drainer
		# to exit.  Idempotent — only the first "kbd" subscription
		# triggers; later calls find subscribed=1 and do nothing.
		if(hd devs == "kbd") {
			ks := findkbdstate(w.ctxt);
			if(ks != nil && !ks.subscribed) {
				ks.subscribed = 1;
				alt {
				ks.stop <-= 1 => ;
				* => ;	# drainer already gone
				}
			}
		}
		w.wmctl(sys->sprint("start %q", hd devs));
	}
}

# commands originating both from tkclient and wm (via ctl)
Window.wmctl(w: self ref Window, req: string): string
{
	(c, next) := qword(req, 0);
	case c {
	"exit" =>
		sys->fprint(sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE), "killgrp");
		exit;
	"rect" =>
		(w.displayr, nil) = s2r(req, next);
	"haskbdfocus" =>
		w.focused = int qword(req, next).t0;
		drawborder(w);
	"retheme" =>
		# a live theme switch (Lucifer sends it to the apps it hosts)
		retheme(w);
	"task" =>
		title := "";
		wmreq(w, sys->sprint("task %q", title), next);
		w.saved = w.r.min;
	"untask" =>
		wmreq(w, req, next);
	* =>
		return wmreq(w, req, next);
	}
	return nil;
}

wmreq(w: ref Window, req: string, e: int): string
{
	name: string;
	if(req != nil && req[0] == '!'){
		(name, e) = qword(req, e);
		if(name != ".")
			return "invalid window name";
	}
	if(w.ctxt.connfd != nil){
		if(sys->fprint(w.ctxt.connfd, "%s", req) == -1)
			return sys->sprint("%r");
		if(req[0] == '!')
			recvimage(w);
		return nil;
	}
	# if we're getting an image and there's no window manager,
	# then there's only one image to get...
	if(req[0] == '!')
		putimage(w, w.ctxt.ctxt.display.image);
	else{
		(nil, nil, err) := wmlib->wmctl(w.ctxt, req);
		return err;
	}
	return nil;
}

recvimage(w: ref Window)
{
	i := <-w.ctxt.images;
	if(i == nil)
		i = <-w.ctxt.images;
	putimage(w, i);
}

Window.settitle(w: self ref Window, name: string): string
{
	wmlib->setlabel(w.ctxt, name);
	return nil;
}

snarfget(): string
{
	return wmlib->snarfget();
}

snarfput(buf: string)
{
	return wmlib->snarfput(buf);
}

r2s(r: Rect): string
{
	return sys->sprint("%d %d %d %d", r.min.x, r.min.y, r.max.x, r.max.y);
}
