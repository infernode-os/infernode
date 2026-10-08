implement Wm;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Screen, Display, Image, Rect, Point, Wmcontext, Pointer: import draw;
include "wmsrv.m";
	wmsrv: Wmsrv;
	Window, Client: import wmsrv;
include "wmlib.m";	# Border
include "wmclient.m";
	wmclient: Wmclient;
include "string.m";
	str: String;
include "sh.m";
include "winplace.m";
	winplace: Winplace;
include "menuhit.m";
	menuhit: Menuhit;
	Menu, Mousectl: import menuhit;

Wm: module {
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Ptrstarted, Kbdstarted, Controlstarted, Controller, Fixedorigin, Framed: con 1<<iota;
Bdwidth: con 3;
# a window is at least this big (9front's goodrect: 100 wide, a line of
# text and its borders high)
Minwidth: con 100;
Minheight: con 2*(Wmlib->Border+1)+16;
wmwin: ref Wmclient->Window;	# wm/wm's own window (for its cursor)
Sminx, Sminy, Smaxx, Smaxy: con iota;
Minx, Miny, Maxx, Maxy: con 1<<iota;
Background: con int 16r777777FF;

screen: ref Screen;
display: ref Display;
ptrfocus: ref Client;
kbdfocus: ref Client;
controller: ref Client;
allowcontrol := 1;
fakekbd: chan of string;
fakekbdin: chan of string;
buttons := 0;
presspt: Point;		# where the current press began
held := 0;		# a press wm/wm has taken is still down: the rest is wm/wm's
hidden: list of ref Client;	# rio's Hide: off the screen, listed on the menu
sweptr: Rect;			# rio's New: where the next new window goes

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "wm: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys  = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		badmodule(Draw->PATH);

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);

	wmsrv = load Wmsrv Wmsrv->PATH;
	if(wmsrv == nil)
		badmodule(Wmsrv->PATH);

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		badmodule(Wmclient->PATH);
	wmclient->init();

	winplace = load Winplace Winplace->PATH;
	if(winplace == nil)
		badmodule(Winplace->PATH);
	winplace->init();

	sys->pctl(Sys->NEWPGRP, nil);
	if (ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display = ctxt.display;
	menuhit = load Menuhit Menuhit->PATH;

	buts := Wmclient->Appl;
	if(ctxt.wm == nil)
		buts = Wmclient->Plain;
	win := wmclient->window(ctxt, "Wm", buts);
	wmwin = win;
	wmclient->win.reshape(((0, 0), (100, 100)));
	wmclient->win.onscreen("place");
	if(win.image == nil){
		sys->fprint(sys->fildes(2), "wm: cannot get image to draw on\n");
		raise "fail:no image";
	}
	wmclient->win.startinput("kbd" :: "ptr" :: nil);
	menuhit->init(win);

	wmctxt := win.ctxt;
	screen = makescreen(win.image);

	(clientwm, join, req) := wmsrv->init(nil);
	clientctxt := ref Draw->Context(ctxt.display, nil, clientwm);

	wmrectIO := sys->file2chan("/chan", "wmrect");
	if(wmrectIO == nil)
		fatal(sys->sprint("cannot make /chan/wmrect: %r"));

	# Export /chan (wmctl, wmrect) at /mnt/wm so external processes
	# like Veltro can access the wm interface without being in this namespace.
	spawn exportchan();

	sync := chan of string;
	argv = tl argv;
	if(argv != nil) {
		spawn command(clientctxt, argv, sync);
		if((e := <-sync) != nil)
			fatal("cannot run command: " + e);
	}
	wmsize := startwmsize();
	fakekbd = chan of string;
	exitc := chan of int;

	# UI test driver: synthetic input via /chan/uitest, so interaction
	# is scriptable and CI-testable (tests/host).  Writes, one command
	# per write:  "ptr X Y BUTTONS"  |  "key RUNE"  (rune as decimal).
	# Events enter the exact channels the real devices feed.
	uitest := sys->file2chan("/chan", "uitest");
	if(uitest != nil)
		spawn uitestproc(uitest, wmctxt.ptr);
	for(;;) alt {
	wmsz := <-wmsize =>
		win.image = win.screen.newwindow(wmsz, Draw->Refnone, Draw->Nofill);
		reshaped(win);
	c := <-win.ctl or
	c = <-wmctxt.ctl =>
		# XXX could implement "pleaseexit" in order that
		# applications can raise a warning message before
		# they're unceremoniously dumped.
		if(c == "exit"){
			# tell every window, hidden ones too, and go once they
			# have: exiting at once killed the minders still holding
			# their "exit", leaving the windows' programs running
			for(z := wmsrv->top(); z != nil; z = z.znext)
				z.ctl <-= "exit";
			for(hl := hidden; hl != nil; hl = tl hl)
				(hd hl).ctl <-= "exit";
			spawn exitwhenempty(exitc);
			continue;
		}
		if(c == "retheme"){
			# a live theme switch (Lucifer sends it to the apps it
			# hosts, wm/wm among them): pass it on to every window
			# here, hidden ones too, so their frames follow
			for(z := wmsrv->top(); z != nil; z = z.znext)
				spawn tellctl(z.ctl, c);
			for(hl := hidden; hl != nil; hl = tl hl)
				spawn tellctl((hd hl).ctl, c);
		}

		wmclient->win.wmctl(c);
		if(win.image != screen.image)
			reshaped(win);
	<-exitc =>
		wmclient->win.wmctl("exit");
	c := <-wmctxt.kbd or
	c = int <-fakekbd =>
		if(kbdfocus != nil)
			kbdfocus.kbd <-= c;
	p := <-wmctxt.ptr =>
		if(wmclient->win.pointer(*p))
			break;
		if(held){
			# the rest of a press wm/wm has taken: motion while it
			# is down must not reach a window, a frame or a menu
			if(p.buttons == 0)
				held = 0;
			break;
		}
		if(p.buttons && (ptrfocus == nil || buttons == 0)){
			presspt = p.xy;
			(hc, w) := framehit(p.xy);
			if(hc != nil){
				# a window's border: wm/wm's, as rio's -- button 1 or
				# 2 reshapes from the nearest edge or corner, 3 moves
				# -- one drag while the button is held, no mode.  The
				# client never sees the press.
				hc.top();
				setkbdfocus(hc);
				buttons = p.buttons;
				if(p.buttons & 4)
					dragwin(wmctxt.ptr, hc, w, p.xy.sub(w.r.min), 0);
				else
					sizewin(wmctxt.ptr, hc, w, Point(0, 0), p.xy, 0);
				buttons = 0;
				break;
			}
			c := wmsrv->find(p.xy);
			if(c != nil){
				if(c != kbdfocus && p.buttons == 1){
					# rio: button 1 in a window that is not the
					# current one only makes it current; the click
					# goes no further
					c.top();
					setkbdfocus(c);
					held = 1;
					break;
				}
				ptrfocus = c;
				c.ctl <-= "raise";
				setkbdfocus(c);
			}else{
				# the background: as rio, button 3 is the window
				# menu and buttons 1 and 2 do nothing
				ptrfocus = nil;
				held = 1;
				if(p.buttons & 4)
					held = button3menu(wmctxt, clientctxt, p);
				break;
			}
		}
		if(ptrfocus != nil && (ptrfocus.flags & Ptrstarted) != 0){
			# inside currently selected client or it had button down last time (might have come up)
			buttons = p.buttons;
			ptrfocus.ptr <-= p;
			break;
		}
		buttons = 0;
	(c, rc) := <-join =>
		rc <-= nil;
		# new client; inform it of the available screen rectangle.
		# XXX do we need to do this now we've got wmrect?
		c.ctl <-= "rect " + r2s(screen.image.r);
		if(allowcontrol){
			controller = c;
			c.flags |= Controller;
			allowcontrol = 0;
		}else
			controlevent("newclient " + string c.id);
	(c, data, rc) := <-req =>
		# if client leaving
		if(rc == nil){
			c.remove();
			forgethidden(c);
			setclientlabel(c, nil);
			if(c == ptrfocus)
				ptrfocus = nil;
			if(c == kbdfocus)
				kbdfocus = nil;
			if(c == controller)
				controller = nil;
			controlevent("delclient " + string c.id);
			for(z := wmsrv->top(); z != nil; z = z.znext)
				if(z.flags & Kbdstarted)
					break;
			setkbdfocus(z);
			c.stop <-= 1;
			break;
		}
		err := handlerequest(win, wmctxt, c, string data);
		n := len data;
		if(err != nil)
			n = -1;
		alt{
		rc <-= (n, err) =>;
		* =>;
		}
	(nil, nil, nil, wc) := <-wmrectIO.write =>
		if(wc == nil)
			break;
		alt{
		wc <-= (0, "cannot write") =>;
		* =>;
		}
	(off, nil, nil, rc) := <-wmrectIO.read =>
		if(rc == nil)
			break;
		d := array of byte r2s(screen.image.r);
		if(off > len d)
			off = len d;
		alt{
		rc <-= (d[off:], nil) =>;
		* =>;
		}
	}
}

handlerequest(win: ref Wmclient->Window, wmctxt: ref Wmcontext, c: ref Client, req: string): string
{
#sys->print("%d: %s\n", c.id, req);
	args := str->unquoted(req);
	if(args == nil)
		return "no request";
	n := len args;
	if(req[0] == '!' && n < 3)
		return "bad arg count";
	case hd args {
	"key" =>
		# XXX should we think about restricting this capability to certain clients only?
		if(n != 2)
			return "bad arg count";
		if(fakekbdin == nil){
			fakekbdin = chan of string;
			spawn bufferproc(fakekbdin, fakekbd);
		}
		fakekbdin <-= hd tl args;
	"ptr" =>
		# ptr x y
		if(n != 3)
			return "bad arg count";
		if(ptrfocus != c)
			return "cannot move pointer";
		e := wmclient->win.wmctl(req);
		if(e == nil){
			c.ptr <-= nil;		# flush queue
			c.ptr <-= ref Pointer(buttons, (int hd tl args, int hd tl tl args), sys->millisec());
		}
	"start" =>
		if(n != 2)
			return "bad arg count";
		case hd tl args {
		"mouse" or
		"ptr" =>
			c.flags |= Ptrstarted;
		"kbd" =>
			c.flags |= Kbdstarted;
			# XXX this means that any new window grabs the focus from the current
			# application, but usually you want this to happen... how can we distinguish
			# the two cases?
			setkbdfocus(c);
		"control" =>
			if((c.flags & Controller) == 0)
				return "control not available";
			c.flags |= Controlstarted;
		* =>
			return "unknown input source";
		}
	"!reshape" =>
		# reshape tag reqid rect [how]
		# XXX allow "how" to specify that the origin of the window is never
		# changed - a new window will be created instead.
		if(n < 7)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;		# skip reqid
		r: Rect;
		r.min.x = int hd args; args = tl args;
		r.min.y = int hd args; args = tl args;
		r.max.x = int hd args; args = tl args;
		r.max.y = int hd args; args = tl args;
		if(args != nil){
			case hd args{
			"onscreen" =>
				r = fitrect(r, screen.image.r);
			"place" =>
				if(tag == "." && !sweptr.eq(Rect((0, 0), (0, 0)))){
					# rio's New: the window swept out for it
					r = sweptr;
					sweptr = Rect((0, 0), (0, 0));
				}else{
					r = fitrect(r, screen.image.r);
					r = newrect(r, screen.image.r);
				}
			"exact" =>
				;
			"max" =>
				r = screen.image.r;			# XXX don't obscure toolbar?
			* =>
				return "unkown placement method";
			}
		}
		return reshape(c, tag, r);
	"delete" =>
		# delete tag
		if(tl args == nil)
			return "tag required";
		c.setimage(hd tl args, nil);
		if(c.wins == nil && c == kbdfocus)
			setkbdfocus(nil);
	"raise" =>
		c.top();
	"lower" =>
		c.bottom();
	"!move" or
	"!size" =>
		# !move tag reqid startx starty
		# !size tag reqid mindx mindy
		ismove := hd args == "!move";
		if(n < 3)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;			# skip reqid
		w := c.window(tag);
		if(w == nil)
			return "no such tag";
		if(ismove){
			if(n != 5)
				return "bad arg count";
			return dragwin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args).sub(w.r.min), 1);
		}else{
			if(n != 5)
				return "bad arg count";
			return sizewin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args), presspt, 1);
		}
	"fixedorigin" =>
		c.flags |= Fixedorigin;
	"label" =>
		# label text: the window's title, as rio's /dev/label; shown in
		# the menu of hidden windows
		if(n != 2)
			return "bad arg count";
		setclientlabel(c, hd tl args);
	"embedded" =>
		# no: wm/wm places windows and leaves the drawing of their
		# frames to the clients (wmlib->embedded).  A client that asks
		# draws one, so its frame's presses are wm/wm's (framehit).
		# Answered here, before a controller could accept it.
		c.flags |= Framed;
		return "not embedded";
	"rect" =>
		;
	"kbdfocus" =>
		if(n != 2)
			return "bad arg count";
		if(int hd tl args)
			setkbdfocus(c);
		else if(c == kbdfocus)
			setkbdfocus(nil);
	# controller specific messages:
	"request" =>		# can be used to test for control.
		if((c.flags & Controller) == 0)
			return "you are not in control";
	"ctl" =>
		# ctl id msg
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		if(n < 3)
			return "bad arg count";
		id := int hd tl args;
		for(z := wmsrv->top(); z != nil; z = z.znext)
			if(z.id == id)
				break;
		if(z == nil)
			return "no such client";
		z.ctl <-= str->quoted(tl tl args);
	"endcontrol" =>
		if(c != controller)
			return "invalid request";
		controller = nil;
		allowcontrol = 1;
		c.flags &= ~(Controlstarted | Controller);
	* =>
		if(c == controller || controller == nil || (controller.flags & Controlstarted) == 0)
			return "unknown control request";
		controller.ctl <-= "request " + string c.id + " " + req;
	}
	return nil;
}

Fix: con 1000;
# the window manager window has been reshaped;
# allocate a new screen, and move all the 
reshaped(win: ref Wmclient->Window)
{
	oldr := screen.image.r;
	newr := win.image.r;
	mx := Fix;
	if(oldr.dx() > 0)
		mx = newr.dx() * Fix / oldr.dx();
	my := Fix;
	if(oldr.dy() > 0)
		my = newr.dy() * Fix / oldr.dy();
	screen = makescreen(win.image);
	for(z := wmsrv->top(); z != nil; z = z.znext){
		for(wl := z.wins; wl != nil; wl = tl wl){
			w := hd wl;
			w.img = nil;
			nr := w.r.subpt(oldr.min);
			nr.min.x = nr.min.x * mx / Fix;
			nr.min.y = nr.min.y * my / Fix;
			rounding := 1;
			nr.max.x = nr.max.x * mx / Fix + rounding;
			if(nr.max.x > newr.max.x)
				nr.max.x = newr.max.x;
			nr.max.y = nr.max.y * my / Fix + rounding;
			if(nr.max.y > newr.max.y)
				nr.max.y = newr.max.y;
			nr = nr.addpt(newr.min);
			w.img = screen.newwindow(nr, Draw->Refbackup, Draw->Nofill);
			# XXX check for creation failure
			w.r = nr;
			spawn reshapenotify(z.ctl, sys->sprint("!reshape %q -1 %s", w.tag, r2s(nr)), "rect " + r2s(newr));
		}
	}
}

# Send reshape and rect notifications to a client without blocking the
# main event loop.  The childminder goroutine buffers these via its Squeue,
# so the sends will complete once the scheduler runs it.
# A reshape the window manager starts: the client asks for the new
# image itself, as for a change of screen size.
tellreshape(c: ref Client, tag: string, r: Rect)
{
	spawn reshapenotify(c.ctl, sys->sprint("!reshape %q -1 %s", tag, r2s(r)), "rect " + r2s(screen.image.r));
}

reshapenotify(ctl: chan of string, reshape, rect: string)
{
	ctl <-= reshape;
	ctl <-= rect;
}

controlevent(e: string)
{
	if(controller != nil && (controller.flags & Controlstarted))
		controller.ctl <-= e;
}

# tell: the press was the client's (a request of its own), so it gets
# the release; a press on the frame, or from the menu, it never saw
dragwin(ptr: chan of ref Pointer, c: ref Client, w: ref Window, off: Point, tell: int): string
{
	if(buttons == 0)
		return "too late";
	p: ref Pointer;
	do{
		p = <-ptr;
		w.img.origin(w.img.r.min, p.xy.sub(off));
	} while (p.buttons != 0);
	if(tell)
		c.ptr <-= p;
	buttons = 0;
	r: Rect;
	r.min = p.xy.sub(off);
	r.max = r.min.add(w.r.size());
	if(r.eq(w.r))
		return "not moved";
	if(!tell){
		# the client is not waiting for an image: have it ask
		tellreshape(c, w.tag, r);
		return nil;
	}
	reshape(c, w.tag, r);
	return nil;
}

# Reshape window w by sweeping from xy, where the press began, while
# the button is held: one drag, no mode.  If the press is already over,
# nothing happens.
sizewin(ptrc: chan of ref Pointer, c: ref Client, w: ref Window, minsize: Point, xy: Point, tell: int): string
{
	if(buttons == 0)
		return "too late";
	if(minsize.x < Minwidth)
		minsize.x = Minwidth;
	if(minsize.y < Minheight)
		minsize.y = Minheight;
	borders := array[4] of ref Image;
	showborders(borders, w.r, Minx|Maxx|Miny|Maxy);
	screen.image.flush(Draw->Flushnow);
	move, show: int;
	offset := Point(0, 0);
	r := w.r;
	show = Minx|Miny|Maxx|Maxy;
	# rio's way: the nearest edge, or a corner within 20 pixels of one
	# (rio.c, whichcorner); an edge moves one side only.  The edge then
	# moves by as much as the pointer does (offset is from the press
	# itself), so nothing jumps on the press; a press just off the
	# window counts as on its nearest edge.
	cx := xy;
	if(cx.x < r.min.x)
		cx.x = r.min.x;
	if(cx.x >= r.max.x)
		cx.x = r.max.x-1;
	if(cx.y < r.min.y)
		cx.y = r.min.y;
	if(cx.y >= r.max.y)
		cx.y = r.max.y-1;
	px := portion(cx.x, r.min.x, r.max.x);
	py := portion(cx.y, r.min.y, r.max.y);
	if(px == 1 && py == 1){
		# well inside: the nearest corner
		px = py = 2;
		if(cx.x < (r.min.x+r.max.x)/2)
			px = 0;
		if(cx.y < (r.min.y+r.max.y)/2)
			py = 0;
	}
	move = 0;
	case px {
	0 =>
		move |= Minx;
		offset.x = xy.x - r.min.x;
	2 =>
		move |= Maxx;
		offset.x = xy.x - r.max.x;
	}
	case py {
	0 =>
		move |= Miny;
		offset.y = xy.y - r.min.y;
	2 =>
		move |= Maxy;
		offset.y = xy.y - r.max.y;
	}
	nr := sweep(ptrc, r, offset, borders, move, show, minsize);
	if(!tell){
		# from the frame: the client is not waiting for an image
		if(!nr.eq(w.r))
			tellreshape(c, w.tag, nr);
		return nil;
	}
	return reshape(c, w.tag, nr);
}

# which third of lo..hi x falls in, the ends being 20 pixels (rio.c)
portion(x, lo, hi: int): int
{
	# 9front's: the halves first, so the corners of a narrow window
	# do not overlap
	x -= lo;
	hi -= lo;
	if(x < hi/2){
		if(x < 20)
			return 0;
	}else if(x > hi-20)
		return 2;
	return 1;
}

# The window whose border is under p, if a press there is the border's:
# the topmost window at p, and p on its border -- the Wmlib->Border
# pixels inside its edge, rio's winborder -- if it is a framed window.
# Positions are wm/wm's own (w.r), which follow every move; a
# client's view of its image may not.
framehit(p: Point): (ref Client, ref Window)
{
	for(z := wmsrv->top(); z != nil; z = z.znext){
		for(wl := z.wins; wl != nil; wl = tl wl){
			w := hd wl;
			if(w.img == nil || !p.in(w.r))
				continue;
			if(w.tag == "." && (z.flags & Framed) != 0 && !p.in(w.r.inset(Wmlib->Border)))
				return (z, w);
			return (nil, nil);	# inside: the app's
		}
	}
	return (nil, nil);
}

reshape(c: ref Client, tag: string, r: Rect): string
{
	w := c.window(tag);
	# if window hasn't changed size, then just change its origin and use the same image.
	if((c.flags & Fixedorigin) == 0 && w != nil && w.r.size().eq(r.size())){
		c.setorigin(tag, r.min);
	} else {
		img := screen.newwindow(r, Draw->Refbackup, Draw->Nofill);
		if(img == nil)
			return sys->sprint("window creation failed: %r");
		if(c.setimage(tag, img) == -1)
			return "can't do two at once";
	}
	c.top();
	return nil;
}

sweep(ptr: chan of ref Pointer, r: Rect, offset: Point, borders: array of ref Image, move, show: int, min: Point): Rect
{
	while((p := <-ptr).buttons != 0){
		xy := p.xy.sub(offset);
		if(move&Minx)
			r.min.x = xy.x;
		if(move&Miny)
			r.min.y = xy.y;
		if(move&Maxx)
			r.max.x = xy.x;
		if(move&Maxy)
			r.max.y = xy.y;
		showborders(borders, r, show);
	}
	r = r.canon();
	if(r.min.y < screen.image.r.min.y){
		r.min.y = screen.image.r.min.y;
		r = r.canon();
	}
	if(r.dx() < min.x){
		if(move & Maxx)
			r.max.x = r.min.x + min.x;
		else
			r.min.x = r.max.x - min.x;
	}
	if(r.dy() < min.y){
		if(move & Maxy)
			r.max.y = r.min.y + min.y;
		else {
			r.min.y = r.max.y - min.y;
			if(r.min.y < screen.image.r.min.y){
				r.min.y = screen.image.r.min.y;
				r.max.y = r.min.y + min.y;
			}
		}
	}
	return r;
}

showborders(b: array of ref Image, r: Rect, show: int)
{
	r = r.canon();
	b[Sminx] = showborder(b[Sminx], show&Minx,
		(r.min, (r.min.x+Bdwidth, r.max.y)));
	b[Sminy] = showborder(b[Sminy], show&Miny,
		((r.min.x+Bdwidth, r.min.y), (r.max.x-Bdwidth, r.min.y+Bdwidth)));
	b[Smaxx] = showborder(b[Smaxx], show&Maxx,
		((r.max.x-Bdwidth, r.min.y), (r.max.x, r.max.y)));
	b[Smaxy] = showborder(b[Smaxy], show&Maxy,
		((r.min.x+Bdwidth, r.max.y-Bdwidth), (r.max.x-Bdwidth, r.max.y)));
}

showborder(b: ref Image, show: int, r: Rect): ref Image
{
	if(!show)
		return nil;
	if(b != nil && b.r.size().eq(r.size()))
		b.origin(r.min, r.min);
	else
		b = screen.newwindow(r, Draw->Refbackup, Draw->Red);
	return b;
}

r2s(r: Rect): string
{
	return string r.min.x + " " + string r.min.y + " " +
			string r.max.x + " " + string r.max.y;
}

# XXX for consideration:
# do not allow applications to grab the keyboard focus
# unless there is currently no keyboard focus...
# but what about launching a new app from the taskbar:
# surely we should allow that the grab the focus?
setkbdfocus(new: ref Client)
{
	old := kbdfocus;
	if(old == new || (new != nil && (new.flags & Kbdstarted) == 0))
		return;
	if(old != nil)
		spawn sendctl(old.ctl, "haskbdfocus 0");
	if(new != nil){
		spawn sendctl2(new.ctl, "raise", "haskbdfocus 1");
		kbdfocus = new;
	} else
		kbdfocus = nil;
}

sendctl(ctl: chan of string, msg: string)
{
	ctl <-= msg;
}

sendctl2(ctl: chan of string, msg1, msg2: string)
{
	ctl <-= msg1;
	ctl <-= msg2;
}

makescreen(img: ref Image): ref Screen
{
	screen = Screen.allocate(img, img.display.color(Background), 0);
	img.draw(img.r, screen.fill, nil, screen.fill.r.min);
	return screen;
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm: %s\n", s);
	kill(sys->pctl(0, nil), "killgrp");
	raise "fail:error";
}

# fit a window rectangle to the available space.
# try to preserve requested location if possible.
# make sure that the window is no bigger than
# the screen, and that its top and left-hand edges
# will be visible at least.
fitrect(w, r: Rect): Rect
{
	if(w.dx() > r.dx())
		w.max.x = w.min.x + r.dx();
	if(w.dy() > r.dy())
		w.max.y = w.min.y + r.dy();
	size := w.size();
	if (w.max.x > r.max.x)
		(w.min.x, w.max.x) = (r.min.x - size.x, r.max.x - size.x);
	if (w.max.y > r.max.y)
		(w.min.y, w.max.y) = (r.min.y - size.y, r.max.y - size.y);
	if (w.min.x < r.min.x)
		(w.min.x, w.max.x) = (r.min.x, r.min.x + size.x);
	if (w.min.y < r.min.y)
		(w.min.y, w.max.y) = (r.min.y, r.min.y + size.y);
	return w;
}

lastrect: Rect;
# find an suitable area for a window
newrect(w, r: Rect): Rect
{
	rl: list of Rect;
	for(z := wmsrv->top(); z != nil; z = z.znext)
		for(wl := z.wins; wl != nil; wl = tl wl)
			rl = (hd wl).r :: rl;
	lastrect = winplace->place(rl, r, lastrect, w.size());
	return lastrect;
}

bufferproc(in, out: chan of string)
{
	h, t: list of string;
	dummyout := chan of string;
	for(;;){
		outc := dummyout;
		s: string;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		}
	}
}

command(ctxt: ref Draw->Context, args: list of string, sync: chan of string)
{
	fds := list of {0, 1, 2};
	sys->pctl(sys->NEWFD, fds);

	cmd := hd args;
	file := cmd;

	if(len file<4 || file[len file-4:]!=".dis")
		file += ".dis";

	c := load Wm file;
	if(c == nil) {
		err := sys->sprint("%r");
		if(err != "permission denied" && err != "access permission denied" && file[0]!='/' && file[0:2]!="./"){
			c = load Wm "/dis/"+file;
			if(c == nil)
				err = sys->sprint("%r");
		}
		if(c == nil){
			if(sync != nil)
				sync <-= sys->sprint("%s: %s\n", cmd, err);
			else
				sys->fprint(sys->fildes(2), "wm: %s: %s\n", cmd, err);
			exit;
		}
	}
	if(sync != nil)
		sync <-= nil;
	c->init(ctxt, args);
}

startwmsize(): chan of Rect
{
	rchan := chan of Rect;
	fd := sys->open("#w/wmsize", Sys->OREAD);
	if(fd == nil)
		return rchan;
	sync := chan of int;
	spawn wmsizeproc(sync, fd, rchan);
	<-sync;
	return rchan;
}

Wmsize: con 1+4*12;		# 'm' plus 4 12-byte decimal integers

wmsizeproc(sync: chan of int, fd: ref Sys->FD, ptr: chan of Rect)
{
	sync <-= sys->pctl(0, nil);

	b:= array[Wmsize] of byte;
	while(sys->read(fd, b, len b) > 0){
		p := bytes2rect(b);
		if(p != nil)
			ptr <-= *p;
	}
}

bytes2rect(b: array of byte): ref Rect
{
	if(len b < Wmsize || int b[0] != 'm')
		return nil;
	x := int string b[1:13];
	y := int string b[13:25];
#	but := int string b[25:37];
#	msec := int string b[37:49];
	return ref Rect((0,0), (x, y));
}

# Export /chan at /mnt/wm via sys->export so that processes outside this
# namespace group (e.g. Veltro) can access wmctl and wmrect.
exportchan()
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->fprint(sys->fildes(2), "wm: pipe for /mnt/wm export: %r\n");
		return;
	}
	spawn exportproc(fds[0]);
	# Ensure /mnt/wm exists as a mount point.
	sys->create("/mnt/wm", Sys->OREAD, Sys->DMDIR | 8r755);
	if(sys->mount(fds[1], nil, "/mnt/wm", Sys->MREPL, nil) < 0)
		sys->fprint(sys->fildes(2), "wm: mount /mnt/wm: %r\n");
}

exportproc(fd: ref Sys->FD)
{
	sys->pctl(Sys->NEWFD, fd.fd :: nil);
	sys->export(fd, "/chan", Sys->EXPWAIT);
}


# Synthetic input for tests: parse "/chan/uitest" writes and feed the
# same channels real input arrives on.  Reads list the windows (above).
uitestproc(f: ref Sys->FileIO, ptr: chan of ref Draw->Pointer)
{
	for(;;) alt {
	(off, nil, nil, rc) := <-f.read =>
		# the windows, topmost first: "id minx miny maxx maxy" each,
		# so a test can check where moves and reshapes left them
		if(rc == nil)
			break;
		t := "";
		for(z := wmsrv->top(); z != nil; z = z.znext)
			if((w := z.window(".")) != nil)
				t += sys->sprint("%d %d %d %d %d\n", z.id, w.r.min.x, w.r.min.y, w.r.max.x, w.r.max.y);
		b := array of byte t;
		if(off > len b)
			off = len b;
		rc <-= (b[off:], nil);
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			break;
		(n, toks) := sys->tokenize(string data, " \t\n");
		err := "";
		if(n >= 4 && hd toks == "ptr") {
			x := int hd tl toks;
			y := int hd tl tl toks;
			b := int hd tl tl tl toks;
			ptr <-= ref Draw->Pointer(b, (x, y), sys->millisec());
		} else if(n >= 2 && hd toks == "key")
			fakekbd <-= hd tl toks;
		else
			err = "usage: ptr X Y BUTTONS | key RUNE";
		if(err != "")
			wc <-= (0, err);
		else
			wc <-= (len data, nil);
	}
}

# ---- rio's button-3 menu: New, Resize, Move, Delete, Hide, and the
# hidden windows.  As in rio, an operation that needs a window asks for
# one: the cursor becomes a gunsight and button 3 chooses it (any other
# button cancels).  Returns whether the button is still down.

Rnew, Rresize, Rmove, Rdelete, Rhide: con iota;
menu3 := array[] of {"New", "Resize", "Move", "Delete", "Hide"};

button3menu(wmctxt: ref Wmcontext, clientctxt: ref Draw->Context, p: ref Pointer): int
{
	items := array[len menu3 + len hidden] of string;
	items[0:] = menu3;
	i := len menu3;
	for(hl := hidden; hl != nil; hl = tl hl)
		items[i++] = clientlabel(hd hl);
	mc := ref Mousectl(wmctxt.ptr, p.buttons, p.xy, p.msec);
	n := menuhit->menuhit(3, mc, ref Menu(items, nil, 0), nil);
	# a click that never moved chooses nothing: the menu opens under
	# the pointer, and a bare click must not start anything
	if(mc.xy.eq(p.xy))
		n = -1;
	held := mc.buttons != 0;
	if(n < 0)
		return held;
	ptr := wmctxt.ptr;
	case n {
	Rnew =>
		r := sweepout(ptr);
		if(!r.eq(Rect((0, 0), (0, 0)))){
			sweptr = r;
			spawn command(clientctxt, "wm/sh" :: nil, nil);
		}
	Rresize =>
		(c, nil) := pointto(ptr, 1);
		if(c != nil){
			r := sweepout(ptr);
			if(!r.eq(Rect((0, 0), (0, 0))))
				tellreshape(c, ".", r);
		}
	Rmove =>
		(c, at) := pointto(ptr, 0);
		if(c != nil && (w := c.window(".")) != nil){
			c.top();
			setcursor(boxcursor);
			buttons = 4;
			dragwin(ptr, c, w, at.sub(w.r.min), 0);
			buttons = 0;
			setcursor(nil);
		}
	Rdelete =>
		(c, nil) := pointto(ptr, 1);
		if(c != nil)
			spawn tellexit(c);
	Rhide =>
		(c, nil) := pointto(ptr, 1);
		if(c != nil)
			hide(c);
	* =>
		j := n - len menu3;
		for(hl = hidden; hl != nil && j > 0; hl = tl hl)
			j--;
		if(hl != nil)
			unhide(hd hl);
	}
	return 0;
}

# rio's pointto: the gunsight, then button 3 on a window chooses it
# (with release, the release must be on the same window).  Returns the
# window, and where it was pressed.
pointto(ptr: chan of ref Pointer, release: int): (ref Client, Point)
{
	setcursor(sightcursor);
	p := <-ptr;
	while(p.buttons != 0)
		p = <-ptr;
	while(p.buttons == 0)
		p = <-ptr;
	at := p.xy;
	c: ref Client;
	if(p.buttons == 4){
		c = wmsrv->find(at);
		if(c != nil && c.window(".") == nil)
			c = nil;
	}
	if(c == nil || release){
		while(p.buttons != 0)
			p = <-ptr;
		if(c != nil && wmsrv->find(p.xy) != c)
			c = nil;
	}
	setcursor(nil);
	return (c, at);
}

# rio's sweep: the cross, then a button-3 drag sweeps out a rectangle.
# Too small, or any other button, and there is none.
sweepout(ptr: chan of ref Pointer): Rect
{
	none := Rect((0, 0), (0, 0));
	setcursor(crosscursor);
	p := <-ptr;
	while(p.buttons != 0)
		p = <-ptr;
	while(p.buttons == 0)
		p = <-ptr;
	r := Rect(p.xy, p.xy);
	ok := p.buttons == 4;
	borders := array[4] of ref Image;
	while(p.buttons != 0){
		if(p.buttons != 4)
			ok = 0;
		if(ok){
			r.max = p.xy;
			showborders(borders, r.canon(), Minx|Maxx|Miny|Maxy);
		}
		p = <-ptr;
	}
	setcursor(nil);
	r = r.canon();
	if(!ok || r.dx() < Minwidth || r.dy() < Minheight)
		return none;
	return r;
}

tellexit(c: ref Client)
{
	c.ctl <-= "exit";
}

# exitwhenempty: tell the main loop to exit once every window has gone
# (their disconnections are handled there), or after two seconds.
exitwhenempty(exitc: chan of int)
{
	for(t := 0; t < 20 && (wmsrv->top() != nil || hidden != nil); t++)
		sys->sleep(100);
	exitc <-= 1;
}

tellctl(ctl: chan of string, s: string)
{
	ctl <-= s;
}

# rio's Hide: off the screen, out of the stacking order, on the menu.
# The client is not told: its image is the same, only shown nowhere.
Hidden: adt {
	c:	ref Client;
	rs:	list of Rect;
};
hiddenat: list of ref Hidden;

hide(c: ref Client)
{
	off := screen.image.r.max.add((10000, 10000));
	rs: list of Rect;
	for(wl := c.wins; wl != nil; wl = tl wl){
		w := hd wl;
		rs = w.r :: rs;
		if(w.img != nil)
			w.img.origin(w.img.r.min, off);
		w.r = Rect(off, off.add(w.r.size()));
	}
	hiddenat = ref Hidden(c, rs) :: hiddenat;
	c.remove();
	c.znext = nil;		# top() relinks it: remove() leaves it set
	hidden = c :: hidden;
	if(kbdfocus == c)
		setkbdfocus(wmsrv->top());
}

unhide(c: ref Client)
{
	nh: list of ref Client;
	for(hl := hidden; hl != nil; hl = tl hl)
		if(hd hl != c)
			nh = hd hl :: nh;
	hidden = nh;
	nha: list of ref Hidden;
	h: ref Hidden;
	for(ha := hiddenat; ha != nil; ha = tl ha)
		if((hd ha).c == c)
			h = hd ha;
		else
			nha = hd ha :: nha;
	hiddenat = nha;
	if(h == nil)
		return;
	# the rects were saved in reverse
	rs: list of Rect;
	for(l := h.rs; l != nil; l = tl l)
		rs = hd l :: rs;
	for(wl := c.wins; wl != nil && rs != nil; (wl, rs) = (tl wl, tl rs)){
		w := hd wl;
		w.r = hd rs;
		if(w.img != nil)
			w.img.origin(w.img.r.min, w.r.min);
	}
	c.top();
	setkbdfocus(c);
}

# Window labels (rio's /dev/label), from the clients' "label" requests.
labels: list of (ref Client, string);

setclientlabel(c: ref Client, l: string)
{
	nl: list of (ref Client, string);
	for(ll := labels; ll != nil; ll = tl ll)
		if((hd ll).t0 != c)
			nl = hd ll :: nl;
	if(l != nil)
		nl = (c, l) :: nl;
	labels = nl;
}

clientlabel(c: ref Client): string
{
	for(ll := labels; ll != nil; ll = tl ll)
		if((hd ll).t0 == c)
			return (hd ll).t1;
	return "window " + string c.id;
}

# A gone client is no longer hidden.
forgethidden(c: ref Client)
{
	nh: list of ref Client;
	for(hl := hidden; hl != nil; hl = tl hl)
		if(hd hl != c)
			nh = hd hl :: nh;
	hidden = nh;
	nha: list of ref Hidden;
	for(ha := hiddenat; ha != nil; ha = tl ha)
		if((hd ha).c != c)
			nha = hd ha :: nha;
	hiddenat = nha;
}

# rio's cursors (rio/data.c), as wmlib's "cursor" request takes them:
# hot point, 16x32 (the clear plane, then the set plane), in hex.
crosscursor := "cursor -7 -7 16 32 03c003c003c003c003c003c0ffffffffffffffff03c003c003c003c003c003c000000180018001800180018001807ffe7ffe0180018001800180018001800000";
boxcursor := "cursor -7 -7 16 32 fffffffffffffffffffff81ff81ff81ff81ff81ff81fffffffffffffffffffff00007ffe7ffe7ffe700e700e700e700e700e700e700e700e7ffe7ffe7ffe0000";
sightcursor := "cursor -7 -7 16 32 1ff83ffc7ffefbdff3cfe3c7ffffffffffffffffe3c7f3cf7bdf7ffe3ffc1ff800000ff0318c21844182418241827ffe7ffe4182418241822184318c0ff00000";

setcursor(c: string)
{
	if(c == nil)
		c = "cursor";
	if(wmwin != nil)
		wmclient->wmwin.wmctl(c);
}
