implement Wmsrv;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Screen, Pointer, Context, Wmcontext, Chans: import draw;
include "wmsrv.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop: import styxservers;

zorder: ref Client;		# top of z-order list, linked by znext.
allclients: array of ref Client;	# wm()'s clients array, for wsys()
stopc: chan of int;		# stop() -> wm()

ZR: con Rect((0, 0), (0, 0));
Iqueue: adt {
	h, t: list of int;
	n: int;
	put:			fn(q: self ref Iqueue, s: int);
	get:			fn(q: self ref Iqueue): int;
	peek:		fn(q: self ref Iqueue): int;
	nonempty:	fn(q: self ref Iqueue): int;
};
Squeue: adt {
	h, t: list of string;
	n: int;
	put:			fn(q: self ref Squeue, s: string);
	get:			fn(q: self ref Squeue): string;
	peek:		fn(q: self ref Squeue): string;
	nonempty:	fn(q: self ref Squeue): int;
};
# Ptrqueue is the same as the other queues except it merges events
# that have the same button state.
Ptrqueue: adt {
	last: ref Pointer;
	h, t: list of ref Pointer;
	put:			fn(q: self ref Ptrqueue, s: ref Pointer);
	get:			fn(q: self ref Ptrqueue): ref Pointer;
	peek:		fn(q: self ref Ptrqueue): ref Pointer;
	nonempty:	fn(q: self ref Ptrqueue): int;
	flush:		fn(q: self ref Ptrqueue);
};

init(name: string): 	(chan of (string, chan of (string, ref Wmcontext)),
		chan of (ref Client, chan of string),
		chan of (ref Client, array of byte, Sys->Rwrite))
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	if(name == nil || name == "")
		name = "wmctl";
	r := sys->bind("#s", "/chan", Sys->MBEFORE);
	ctlio := sys->file2chan("/chan", name);
	if(ctlio == nil){
		sys->werrstr(sys->sprint("can't create /chan/%s: %r", name));
		return (nil, nil, nil);
	}

	wmreq := chan of (string, chan of (string, ref Wmcontext));
	join := chan of (ref Client, chan of string);
	req := chan of (ref Client, array of byte, Sys->Rwrite);
	stopc = chan of int;
	spawn wm(ctlio, wmreq, join, req);
	return (wmreq, join, req);
}

wm(ctlio: ref Sys->FileIO,
			wmreq: chan of (string, chan of (string, ref Wmcontext)),
			join: chan of (ref Client, chan of string),
			req: chan of (ref Client, array of byte, Sys->Rwrite))
{
	clients: array of ref Client;

	for(;;){
		alt{
	(cmd, rc) := <-wmreq =>
		token := int cmd;
		for(i := 0; i < len clients; i++)
			if(clients[i] != nil && clients[i].token == token)
				break;

		if(i == len clients){
			spawn senderror(rc, "not found");
			break;
		}
		c := clients[i];
		if(c.stop != nil){
			spawn senderror(rc, "already started");
			break;
		}
		ok := chan of string;
		join <-= (c, ok);
		if((e := <-ok) != nil){
			spawn senderror(rc, e);
			break;
		}
		c.stop = chan of int;
		spawn childminder(c, rc);

	(nil, nbytes, fid, rc) := <-ctlio.read =>
		if(rc == nil)
			break;
		c := findfid(clients, fid);
		if(c == nil){
			c = ref Client(
				chan[32] of int,	# kbd: buffered so the compositor's
							# non-blocking send doesn't drop keys
							# while a -c0 app is mid-redraw (text
							# input to workspace apps, e.g. settings)
				chan of ref Draw->Pointer,
				chan of string,
				nil,
				0,
				nil,
				nil,
				nil,

				chan of (ref Point, ref Image, chan of int),
				-1,
				fid,
				fid,			# token; XXX could be random integer + fid
				newwmcontext()
			);
			clients = addclient(clients, c);
			allclients = clients;
		}
		alt{
		rc <-= (sys->aprint("%d", c.token), nil) => ;
		* => ;
		}
	(nil, data, fid, wc) := <-ctlio.write =>
		c := findfid(clients, fid);
		if(wc != nil){
			if(c == nil){
				alt{
				wc <-= (0, "must read first") => ;
				* => ;
				}
				break;
			}
			req <-= (c, data, wc);
		}else if(c != nil){
			req <-= (c, nil, nil);
			delclient(clients, c);
		}
	<-stopc =>
		for(i := 0; i < len clients; i++) {
			c := clients[i];
			if(c == nil)
				continue;
			alt{
			c.ctl <-= "exit" => ;
			* => ;
			}
			if(c.stop != nil)
				c.stop <-= 1;
		}
		allclients = nil;
		return;
		}  # end alt
	}  # end for
}

# buffer all events between a window manager and
# a client, so that one recalcitrant child can't
# clog the whole system.
childminder(c: ref Client, rc: chan of (string, ref Wmcontext))
{
	wmctxt := c.wmctxt;

	dummykbd := chan of int;
	dummyptr := chan of ref Pointer;
	dummyimg := chan of ref Image;
	dummyctl := chan of string;

	kbdq := ref Iqueue;
	ptrq := ref Ptrqueue;
	ctlq := ref Squeue;

	Imgnone, Imgsend, Imgsendnil1, Imgsendnil2, Imgorigin: con iota;
	img, sendimg: ref Image;
	imgorigin: Point;
	imgstate := Imgnone;

	# send reply to client, but make sure we don't block.
Reply:
	for(;;) alt{
	rc <-= (nil, ref *wmctxt) =>
		break Reply;
	<-c.stop =>
		exit;
	key := <-c.kbd =>
		kbdq.put(key);
	ptr := <-c.ptr =>
		ptrq.put(ptr);
	ctl := <-c.ctl =>
		ctlq.put(ctl);
	}

	for(;;){
		outkbd := dummykbd;
		key := -1;
		if(kbdq.nonempty()){
			key = kbdq.peek();
			outkbd = wmctxt.kbd;
		}

		outptr := dummyptr;
		ptr: ref Pointer;
		if(ptrq.nonempty()){
			ptr = ptrq.peek();
			outptr = wmctxt.ptr;
		}

		outctl := dummyctl;
		ctl: string;
		if(ctlq.nonempty()){
			ctl = ctlq.peek();
			outctl = wmctxt.ctl;
		}

		outimg := dummyimg;
		case imgstate{
		Imgsend =>
			outimg = wmctxt.images;
			sendimg = img;
		Imgsendnil1 or
		Imgsendnil2 or
		Imgorigin =>
			outimg = wmctxt.images;
			sendimg = nil;
		}

		alt{
		outkbd <-= key =>
			kbdq.get();
		outptr <-= ptr =>
			ptrq.get();
		outctl <-= ctl =>
			ctlq.get();
		outimg <-= sendimg =>
			case imgstate{
			Imgsend =>
				imgstate = Imgnone;
				img = sendimg = nil;
			Imgsendnil1 =>
				imgstate = Imgsendnil2;
			Imgsendnil2 =>
				imgstate = Imgnone;
			Imgorigin =>
				if(img.origin(imgorigin, imgorigin) == -1){
					# XXX what can we do about this? there's no way at the moment
					# of getting the information about the origin failure back to the wm,
					# so we end up with an inconsistent window position.
					# if the window manager blocks while we got the sync from
					# the client, then a client could block the whole window manager
					# which is what we're trying to avoid.
					# but there's no other time we could set the origin of the window,
					# and not risk mucking up the window contents.
					# the short answer is that running out of image space is Bad News.
				}
				imgstate = Imgsend;
			}

		# XXX could mark the application as unresponding if any of these queues
		# start growing too much.
		ch := <-c.kbd =>
			kbdq.put(ch);
		p := <-c.ptr =>
			if(p == nil)
				ptrq.flush();
			else
				ptrq.put(p);
		e := <-c.ctl =>
			ctlq.put(e);
		(o, i, reply) := <-c.images =>
			# can't queue multiple image requests.
			if(imgstate != Imgnone)
				reply <-= -1;
			else {
				# if the origin is being set, then we first send a nil image
				# to indicate that this is happening, and then the
				# image itself (reorigined).
				# if a nil image is being set, then we
				# send nil twice.
				if(o != nil){
					imgorigin = *o;
					imgstate = Imgorigin;
					img = i;
				}else if(i != nil){
					img = i;
					imgstate = Imgsend;
				}else
					imgstate = Imgsendnil1;
				reply <-= 0;
			}
		<-c.stop =>
			# XXX do we need to unblock channels, kill, etc.?
			# we should perhaps drain the ctl output channel here
			# if possible, exiting if it times out.
			exit;
		}
	}
}

findfid(clients: array of ref Client, fid: int): ref Client
{
	for(i := 0; i < len clients; i++)
		if(clients[i] != nil && clients[i].fid == fid)
			return clients[i];
	return nil;
}

addclient(clients: array of ref Client, c: ref Client): array of ref Client
{
	for(i := 0; i < len clients; i++)
		if(clients[i] == nil){
			clients[i] = c;
			c.id = i;
			return clients;
		}
	nc := array[len clients + 4] of ref Client;
	nc[0:] = clients;
	nc[len clients] = c;
	c.id = len clients;
	return nc;
}

delclient(clients: array of ref Client, c: ref Client)
{
	clients[c.id] = nil;
}

stop()
{
	if(stopc == nil)
		return;
	stopc <-= 1;
	stopc = nil;
}

senderror(rc: chan of (string, ref Wmcontext), e: string)
{
	rc <-= (e, nil);
}

Client.window(c: self ref Client, tag: string): ref Window
{
	for (w := c.wins; w != nil; w = tl w)
		if((hd w).tag == tag)
			return hd w;
	return nil;
}

Client.image(c: self ref Client, tag: string): ref Draw->Image
{
	w := c.window(tag);
	if(w != nil)
		return w.img;
	return nil;
}

Client.setimage(c: self ref Client, tag: string, img: ref Draw->Image): int
{
	# if img is nil, remove window from list.
	if(img == nil){
		# usual case:
		if(c.wins != nil && (hd c.wins).tag == tag){
			c.wins = tl c.wins;
			return -1;
		}
		nw: list of ref Window;
		for (w := c.wins; w != nil; w = tl w)
			if((hd w).tag != tag)
				nw = hd w :: nw;
		c.wins = nil;
		for(; nw != nil; nw = tl nw)
			c.wins = hd nw :: c.wins;
		return -1;
	}
	for(w := c.wins; w != nil; w = tl w)
		if((hd w).tag == tag)
			break;
	win: ref Window;
	if(w != nil)
		win = hd w;
	else{
		win = ref Window(tag, ZR, nil);
		c.wins = win :: c.wins;
	}
	win.img = img;
	win.r = img.r;			# save so clients can set logical origin
	rc := chan of int;
	c.images <-= (nil, img, rc);
	return <-rc;
}

# tell a client about a window that's moved to screen coord o.
Client.setorigin(c: self ref Client, tag: string, o: Draw->Point): int
{
	w := c.window(tag);
	if(w == nil)
		return -1;
	img := w.img;
	if(img == nil)
		return -1;
	rc := chan of int;
	c.images <-= (ref o, w.img, rc);
	if(<-rc != -1){
		w.r = (o, o.add(img.r.size()));
		return 0;
	}
	return -1;
}

clientimages(c: ref Client): array of ref Image
{
	a := array[len c.wins] of ref Draw->Image;
	i := 0;
	for(w := c.wins; w != nil; w = tl w)
		if((hd w).img != nil)
			a[i++] = (hd w).img;
	return a[0:i];
}

Client.top(c: self ref Client)
{
	imgs := clientimages(c);
	if(len imgs > 0)
		imgs[0].screen.top(imgs);

	if(zorder == c)
		return;

	prev: ref Client;
	for(z := zorder; z != nil; (prev, z) = (z, z.znext))
		if(z == c)
			break;
	if(prev != nil)
		prev.znext = c.znext;
	c.znext = zorder;
	zorder = c;
}

Client.bottom(c: self ref Client)
{
	# Always move the screen image to z-back, regardless of z-list state.
	# The original early return (c.znext == nil) skipped screen.bottom() for
	# single-element lists or clients not yet in the list — causing ghost windows
	# to remain visible when the app was the only entry in the z-list.
	imgs := clientimages(c);
	if(len imgs > 0)
		imgs[0].screen.bottom(imgs);
	if(c.znext == nil)
		return;		# already at tail of z-list; no list reordering needed
	prev: ref Client;
	for(z := zorder; z != nil; (prev, z) = (z, z.znext))
		if(z == c)
			break;
	if(prev != nil)
		prev.znext = c.znext;
	else
		zorder = c.znext;
	z = c.znext;
	c.znext = nil;
	for(; z != nil; (prev, z) = (z, z.znext))
		;
	if(prev != nil)
		prev.znext = c;
	else
		zorder = c;
}

Client.hide(nil: self ref Client)
{
}

Client.unhide(nil: self ref Client)
{
}

Client.remove(c: self ref Client)
{
	prev: ref Client;
	for(z := zorder; z != nil; (prev, z) = (z, z.znext))
		if(z == c)
			break;
	if(z == nil)
		return;
	if(prev != nil)
		prev.znext = z.znext;
	else if(z != nil)
		zorder = zorder.znext;
}

find(p: Draw->Point): ref Client
{
	for(z := zorder; z != nil; z = z.znext)
		if(z.contains(p))
			return z;
	return nil;
}

top(): ref Client
{
	return zorder;
}

Client.contains(c: self ref Client, p: Point): int
{
	for(w := c.wins; w != nil; w = tl w)
		if((hd w).r.contains(p))
			return 1;
	return 0;
}

r2s(r: Rect): string
{
	return string r.min.x + " " + string r.min.y + " " +
			string r.max.x + " " + string r.max.y;
}

newwmcontext(): ref Wmcontext
{
	return ref Wmcontext(
		chan of int,
		chan of ref Pointer,
		chan of string,
		nil,
		chan of ref Image,
		nil,
		nil
	);
}

Iqueue.put(q: self ref Iqueue, s: int)
{
	q.t = s :: q.t;
}
Iqueue.get(q: self ref Iqueue): int
{
	s := -1;
	if(q.h == nil){
		for(t := q.t; t != nil; t = tl t)
			q.h = hd t :: q.h;
		q.t = nil;
	}
	if(q.h != nil){
		s = hd q.h;
		q.h = tl q.h;
	}
	return s;
}
Iqueue.peek(q: self ref Iqueue): int
{
	s := -1;
	if (q.h == nil && q.t == nil)
		return s;
	s = q.get();
	q.h = s :: q.h;
	return s;
}
Iqueue.nonempty(q: self ref Iqueue): int
{
	return q.h != nil || q.t != nil;
}


Squeue.put(q: self ref Squeue, s: string)
{
	q.t = s :: q.t;
}
Squeue.get(q: self ref Squeue): string
{
	s: string;
	if(q.h == nil){
		for(t := q.t; t != nil; t = tl t)
			q.h = hd t :: q.h;
		q.t = nil;
	}
	if(q.h != nil){
		s = hd q.h;
		q.h = tl q.h;
	}
	return s;
}
Squeue.peek(q: self ref Squeue): string
{
	s: string;
	if (q.h == nil && q.t == nil)
		return s;
	s = q.get();
	q.h = s :: q.h;
	return s;
}
Squeue.nonempty(q: self ref Squeue): int
{
	return q.h != nil || q.t != nil;
}

Ptrqueue.put(q: self ref Ptrqueue, s: ref Pointer)
{
	if(q.last != nil && s.buttons == q.last.buttons)
		*q.last = *s;
	else{
		q.t = s :: q.t;
		q.last = s;
	}
}
Ptrqueue.get(q: self ref Ptrqueue): ref Pointer
{
	s: ref Pointer;
	h := q.h;
	if(h == nil){
		for(t := q.t; t != nil; t = tl t)
			h = hd t :: h;
		q.t = nil;
	}
	if(h != nil){
		s = hd h;
		h = tl h;
		if(h == nil)
			q.last = nil;
	}
	q.h = h;
	return s;
}
Ptrqueue.peek(q: self ref Ptrqueue): ref Pointer
{
	s: ref Pointer;
	if (q.h == nil && q.t == nil)
		return s;
	t := q.last;
	s = q.get();
	q.h = s :: q.h;
	q.last = t;
	return s;
}
Ptrqueue.nonempty(q: self ref Ptrqueue): int
{
	return q.h != nil || q.t != nil;
}
Ptrqueue.flush(q: self ref Ptrqueue)
{
	q.h = q.t = nil;
}

# ── wsys: the windows as a read-only file tree ──────────────────────
#
#	<id>/window	client <id>'s main window: the /dev/screen format,
#			an uncompressed image, a snapshot taken at open
#
# A client's main window is its oldest: windows are kept most recent
# first, and the later ones are the ephemeral kind (pop-up menus).  The
# tag is the window manager's business, "." under wm, "app" under
# lucifer and matrix, so it is not used to find it.
#
# Rio serves the same as /dev/wsys/<id>/window.  Windows are allocated
# Refbackup, so a covered window reads as it is, not as what covers it.
# Nothing is mounted here; the caller puts the tree in the namespaces
# that should have it.

Qwroot, Qwdir, Qwwin: con iota;

wsys(): ref Sys->FD
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	if(styx == nil || styxservers == nil)
		return nil;
	styx->init();
	styxservers->init(styx);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return nil;
	navops := chan of ref Navop;
	spawn wsysnav(navops);
	(tc, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qwroot);
	spawn wsysserve(tc, srv, navops);
	return fds[1];
}

wsysserve(tc: chan of ref Tmsg, srv: ref Styxserver, navops: chan of ref Navop)
{
	while((m := <-tc) != nil) {
		pick tm := m {
		Readerror =>
			break;
		Open =>
			c := srv.open(tm);
			if(c != nil && int (c.path & big 16rFF) == Qwwin)
				c.data = winimage(wsysclient(int (c.path >> 8)));
		Read =>
			c := srv.getfid(tm.fid);
			if(c != nil && c.isopen && int (c.path & big 16rFF) == Qwwin) {
				if(c.data == nil)
					srv.reply(ref Rmsg.Error(tm.tag, "window has no image"));
				else
					srv.reply(styxservers->readbytes(tm, c.data));
			} else
				srv.read(tm);
		* =>
			srv.default(m);
		}
	}
	navops <-= nil;
}

# The live client with this id that has a window image, or nil.
wsysclient(id: int): ref Client
{
	a := allclients;
	if(id < 0 || id >= len a || a[id] == nil)
		return nil;
	if(mainimage(a[id]) == nil)
		return nil;
	return a[id];
}

mainimage(c: ref Client): ref Image
{
	img: ref Image;
	for(w := c.wins; w != nil; w = tl w)
		if((hd w).img != nil)
			img = (hd w).img;
	return img;
}

winimage(c: ref Client): array of byte
{
	if(c == nil)
		return nil;
	img := mainimage(c);
	if(img == nil)
		return nil;
	r := img.r;
	hdr := array of byte sys->sprint("%11s %11d %11d %11d %11d ",
		img.chans.text(), r.min.x, r.min.y, r.max.x, r.max.y);
	bpl := (r.dx() * img.depth + 7) / 8;
	px := array[bpl * r.dy()] of byte;
	if(img.readpixels(r, px) != len px)
		return nil;
	b := array[len hdr + len px] of byte;
	b[0:] = hdr;
	b[len hdr:] = px;
	return b;
}

wsysdir(p: big): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid.path = p;
	d.uid = d.gid = "wm";
	id := int (p >> 8);
	case int (p & big 16rFF) {
	Qwroot =>
		d.name = ".";
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR|8r555;
	Qwdir =>
		if(wsysclient(id) == nil)
			return nil;
		d.name = string id;
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR|8r555;
	Qwwin =>
		if(wsysclient(id) == nil)
			return nil;
		d.name = "window";
		d.mode = 8r444;
	* =>
		return nil;
	}
	return d;
}

wsysnav(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			d := wsysdir(n.path);
			if(d == nil)
				n.reply <-= (nil, Styxservers->Enotfound);
			else
				n.reply <-= (d, nil);
		Walk =>
			t := int (n.path & big 16rFF);
			id := int (n.path >> 8);
			d: ref Sys->Dir;
			if(n.name == "..")
				d = wsysdir(big Qwroot);
			else if(t == Qwroot) {
				(ok, nil) := sys->tokenize(n.name, "0123456789");
				if(ok == 0 && n.name != "")
					d = wsysdir((big int n.name << 8) | big Qwdir);
			} else if(t == Qwdir && n.name == "window")
				d = wsysdir((big id << 8) | big Qwwin);
			if(d == nil)
				n.reply <-= (nil, Styxservers->Enotfound);
			else
				n.reply <-= (d, nil);
		Readdir =>
			t := int (n.path & big 16rFF);
			ents: list of ref Sys->Dir;
			if(t == Qwroot) {
				a := allclients;
				for(i := len a - 1; i >= 0; i--)
					if(wsysclient(i) != nil)
						ents = wsysdir((big i << 8) | big Qwdir) :: ents;
			} else if(t == Qwdir)
				ents = wsysdir((n.path & ~big 16rFF) | big Qwwin) :: nil;
			i := 0;
			for(; ents != nil; ents = tl ents) {
				if(hd ents == nil)
					continue;
				if(i >= n.offset && i < n.offset + n.count)
					n.reply <-= (hd ents, nil);
				i++;
			}
			n.reply <-= (nil, nil);
		}
	}
}
