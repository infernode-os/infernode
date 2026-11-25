implement Rcpu;

#
# rcpu(1): a command run on a 9front cpu server, as 9front's rcpu runs
# it: rcpu's connection (rconnect(2)), the same server function, which
# mounts what this end serves over the connection at /mnt/term and runs
# the command with /mnt/term/fd/10, 11 and 12 as its input, output and
# error.  9front's rcpu serves its whole name space there; this serves a
# tree of its own and nothing else of this machine:
#
#	fd/10 fd/11 fd/12	this command's input, output, error
#	dev/cons		input and output; a window's keys once a
#				program there has it raw
#	mnt/cpunote/data	notes for the far end (none are sent)
#	env/rstatus		where the far end leaves its exit status
#
# and, where this machine has a display, what a 9front graphical program
# draws with, as rcpu run in a rio window gives it (#1270):
#
#	dev/draw/		the draw device, in a scope of this session's
#				own (draw(3)): its programs reach their own
#				images and their window, not the screen or
#				another program's
#	dev/winname		the window: made when a program first asks
#				for it, gone when no program has its mouse
#	dev/mouse dev/cursor	its pointer (9front's form) and cursor
#	dev/consctl dev/kbd	rawon for cons; 9front's raw keyboard
#	dev/label dev/snarf	its label; this machine's snarf buffer
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Image, Pointer, Rect: import draw;

include "keyboard.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "arg.m";

include "factotum.m";

include "rconnect.m";
	rcon: Rconnect;

Rcpu: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

# 9front's rcpu's server function, as rc's whatis gives it
SERVER: con "fn server {\n" +
	"	mount -nc /fd/0 /mnt/term || exit\n" +
	"	bind -q /mnt/term/dev/cons /dev/cons\n" +
	"	</mnt/term/fd/10 >/mnt/term/fd/11 >[2]/mnt/term/fd/12 {\n" +
	"		~ $#dir 0 || cd $\"dir || echo 'can''t change directory: '^$\"dir >[1=2]\n" +
	"		switch($#cmd){\n" +
	"		case 0;	cmd=(rc -li)\n" +
	"		case 1; cmd=(rc -lc $cmd)\n" +
	"		case *; cmd=(rc -lc '$*' $cmd)\n" +
	"		}\n" +
	"		rm -f /env/^(cmd dir 'fn#server')\n" +
	"		service=cpu exec $cmd\n" +
	"	} &\n" +
	"	if(test -d /mnt/term/mnt/cpunote) {\n" +
	"		rfork e\n" +
	"		mainproc=$apid\n" +
	"		rm -f /mnt/term/env/rfailed\n" +
	"		{cat; echo -n hangup} </mnt/term/mnt/cpunote/data >/proc/$mainproc/notepg &\n" +
	"		noteproc=$apid\n" +
	"		wait $mainproc\n" +
	"		echo -n $status >/mnt/term/env/rstatus >[2]/dev/null\n" +
	"		echo -n hangup >/proc/$noteproc/notepg\n" +
	"	}\n" +
	"}\n";

stderr: ref Sys->FD;
rstatus := "";
drawctxt: ref Draw->Context;	# where windows go; made if none was given
scope := "";			# this session's draw scope (draw(3))
title := "rcpu";
gfxpids: list of int;		# the display's processes, stopped with the session
gfxquit: chan of int;		# to the display: the session is over
gfxdone: chan of int;		# from it: the window is closed

fail(s: string)
{
	sys->fprint(stderr, "rcpu: %s\n", s);
	raise "fail:"+s;
}

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	drawctxt = ctxt;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("rcpu [-k keypattern] [-u user] [-h host] [-c cmd arg ...]");
	keyspec := "";
	host := readenv("cpu");
	cmd: list of string;
	dir := "";
	cflag := 0;
	while(!cflag && (o := arg->opt()) != 0)
		case o {
		'k' =>	keyspec += " "+arg->earg();
		'u' =>	keyspec += " user="+arg->earg();
		'h' =>	host = arg->earg();
		'd' =>	dir = arg->earg();
		'c' =>
			cmd = arg->argv();
			if(cmd == nil)
				arg->usage();
			cflag = 1;
		* =>	arg->usage();
		}
	if(!cflag && arg->argv() != nil)
		arg->usage();
	if(host == nil)
		fail("no host: -h host, or $cpu");
	title = "rcpu "+host;

	rcon = load Rconnect Rconnect->PATH;
	if(rcon == nil)
		fail(sys->sprint("cannot load %s: %r", Rconnect->PATH));
	if((e := rcon->init()) != nil)
		fail(e);

	script := "dir=()\n";
	if(dir != nil)
		script = "dir="+rcon->rcquote(dir)+"\n";
	if(cmd == nil)
		script += "cmd=()\n";
	else{
		script += "cmd=(";
		for(l := cmd; l != nil; l = tl l){
			script += rcon->rcquote(hd l);
			if(tl l != nil)
				script += " ";
		}
		script += ")\n";
	}
	script += SERVER + "server\n";

	(fd, nil, err) := rcon->connect(host, keyspec, script);
	if(fd == nil)
		fail(err);
	# the tree once there is a connection to serve it on: the server's
	# mount waits for its answers until then
	sys->pctl(Sys->FORKNS, nil);
	root := mktree();
	xerr := "";
	if(sys->export(fd, root, Sys->EXPWAIT) < 0)
		xerr = sys->sprint("export: %r");
	# the session is over: its window goes with it (the window's own
	# processes hold its connection, so it is closed, not left to them)
	if(gfxquit != nil){
		gfxquit <-= 1;
		t := chan[1] of int;	# buffered: the timer never waits
		spawn timer(t, 2000);
		alt{
		<-gfxdone =>
			;
		<-t =>
			;	# the display is stuck: it is stopped below all the same
		}
	}
	for(; gfxpids != nil; gfxpids = tl gfxpids)
		kill(hd gfxpids);
	rmtree(root);
	if(xerr != "")
		fail(xerr);
	if(rstatus != nil && rstatus != "")
		raise "fail:"+rstatus;
}

readenv(name: string): string
{
	fd := sys->open("/env/"+name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

# the tree served to the far end: directories made in a scratch place of
# this name space's own, each a #s of its own with its files in it
mktree(): string
{
	root := "/tmp/rcpu."+string sys->pctl(0, nil);
	{
		mktree1(root);
	} exception {
	"fail:*" =>
		rmtree(root);
		raise;
	}
	return root;
}

mktree1(root: string)
{
	for(d := list of {"", "/fd", "/dev", "/mnt", "/mnt/cpunote", "/env"}; d != nil; d = tl d)
		if(sys->create(root + hd d, Sys->OREAD, Sys->DMDIR|8r700) == nil && sys->stat(root + hd d).t0 < 0)
			fail(sys->sprint("cannot make %s: %r", root + hd d));
	for(d = list of {"/fd", "/dev", "/mnt/cpunote", "/env"}; d != nil; d = tl d)
		if(sys->bind("#s", root + hd d, Sys->MREPL) < 0)
			fail(sys->sprint("bind #s %s: %r", root + hd d));
	in := sys->fildes(0);
	out := sys->fildes(1);
	err := sys->fildes(2);
	file(root+"/fd", "10", in, nil);
	file(root+"/fd", "11", nil, out);
	file(root+"/fd", "12", nil, err);
	if(!gfxfiles(root+"/dev", in, out))
		file(root+"/dev", "cons", in, out);
	note := sys->file2chan(root+"/mnt/cpunote", "data");
	if(note == nil)
		fail(sys->sprint("file2chan: %r"));
	spawn noteserve(note);
	st := sys->file2chan(root+"/env", "rstatus");
	if(st == nil)
		fail(sys->sprint("file2chan: %r"));
	spawn statusserve(st);
	# the far end makes nothing on this machine's disk: the two
	# directories that are the scratch place's own are made read-only
	ro := sys->nulldir;
	ro.mode = Sys->DMDIR|8r500;
	sys->wstat(root+"/mnt", ro);
	sys->wstat(root, ro);
}

rmtree(root: string)
{
	for(l := list of {"/fd", "/dev", "/mnt/cpunote", "/env"}; l != nil; l = tl l)
		sys->unmount(nil, root + hd l);
	d := sys->nulldir;
	d.mode = Sys->DMDIR|8r700;
	sys->wstat(root, d);
	sys->wstat(root+"/mnt", d);
	for(l = list of {"/fd", "/dev", "/mnt/cpunote", "/mnt", "/env", ""}; l != nil; l = tl l)
		sys->remove(root + hd l);
}

file(dir, name: string, in, out: ref Sys->FD)
{
	f := sys->file2chan(dir, name);
	if(f == nil)
		fail(sys->sprint("file2chan %s/%s: %r", dir, name));
	spawn serve(f, in, out);
}

serve(f: ref Sys->FileIO, in, out: ref Sys->FD)
{
	for(;;) alt {
	(nil, n, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		if(in == nil){
			rc <-= (nil, "not open for reading");
			continue;
		}
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		b := array[n] of byte;
		m := sys->read(in, b, n);
		if(m < 0)
			rc <-= (nil, sys->sprint("%r"));
		else
			rc <-= (b[0:m], nil);
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		if(out == nil){
			wc <-= (0, "not open for writing");
			continue;
		}
		if(sys->write(out, data, len data) != len data)
			wc <-= (0, sys->sprint("%r"));
		else
			wc <-= (len data, nil);
	}
}

# reads of the notes file wait: no note is sent from here
noteserve(f: ref Sys->FileIO)
{
	held: list of Sys->Rread;
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			held = rc :: held;
	(nil, nil, nil, wc) := <-f.write =>
		if(wc != nil)
			wc <-= (0, "permission denied");
	}
}

statusserve(f: ref Sys->FileIO)
{
	for(;;) alt {
	(off, n, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		b := array of byte rstatus;
		if(off >= len b)
			rc <-= (nil, nil);
		else{
			if(off + n > len b)
				n = len b - off;
			rc <-= (b[off:off+n], nil);
		}
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		rstatus = string data;
		wc <-= (len data, nil);
	}
}

#
# The far end's display (#1270).  One process serves every file below and
# the window's events, so nothing in it needs a lock; reads that cannot be
# answered yet wait in lists.  Nothing polls: the window is made at the
# first read of winname and dropped when the last open of mouse closes.
#

Winsize: con 800;	# the window's first size, square-ish, resizable
Mouseq: con 16;	# mouse events kept for a reader that has fallen behind

# the files a graphical program uses, bound beside cons
Gfiles: adt {
	winname, mouse, cursor, cons, consctl, kbd, label, snarf: ref Sys->FileIO;
};

gfxfiles(dir: string, in, out: ref Sys->FD): int
{
	if(drawctxt == nil && sys->stat("#i/draw/new").t0 < 0)
		return 0;	# no display here: text only, as before
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	if(draw == nil || wmclient == nil)
		return 0;
	wmclient->init();
	scope = sys->sprint("rcpu.%d.%d", sys->pctl(0, nil), sys->millisec());
	if(sys->bind("#i"+scope, dir, Sys->MAFTER) < 0)
		return 0;
	f := ref Gfiles;
	f.winname = mkfile(dir, "winname");
	f.mouse = mkfile(dir, "mouse");
	f.cursor = mkfile(dir, "cursor");
	f.cons = mkfile(dir, "cons");
	f.consctl = mkfile(dir, "consctl");
	f.kbd = mkfile(dir, "kbd");
	f.label = mkfile(dir, "label");
	f.snarf = mkfile(dir, "snarf");
	inq := chan of (int, Sys->Rread);
	pidc := chan of int;
	spawn stdinproc(in, inq, pidc);
	gfxpids = <-pidc :: gfxpids;
	gfxquit = chan[1] of int;
	gfxdone = chan[1] of int;
	spawn gfx(f, inq, out, pidc);
	gfxpids = <-pidc :: gfxpids;
	return 1;
}

mkfile(dir, name: string): ref Sys->FileIO
{
	f := sys->file2chan(dir, name);
	if(f == nil)
		fail(sys->sprint("file2chan %s/%s: %r", dir, name));
	return f;
}

# reads of this command's input for cons, one at a time
stdinproc(in: ref Sys->FD, q: chan of (int, Sys->Rread), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		(n, rc) := <-q;
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		b := array[n] of byte;
		m := sys->read(in, b, n);
		if(m < 0)
			rc <-= (nil, sys->sprint("%r"));
		else
			rc <-= (b[0:m], nil);
	}
}

# a read waiting, with the open it came by
Wait: adt {
	fid:	int;
	n:	int;
	rc:	Sys->Rread;
};

gfx(f: ref Gfiles, inq: chan of (int, Sys->Rread), out: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	win: ref Window;
	name := "";
	seq := 0;
	label := "";
	mice: list of int;		# opens of mouse that have read it
	mwait: list of ref Wait;
	mq: list of array of byte;	# mouse events not yet read, oldest first
	cursorbuf: array of byte;
	raw: list of int;		# opens of consctl that set rawon
	kbds: list of int;		# opens of kbd that have read it
	keys := "";			# keys for cons while raw
	kq: array of byte;		# kbd messages not yet read
	cwait, kwait: list of ref Wait;
	snarfs: list of (int, string);	# snarf being written, by open
	last := ref Pointer(0, (0, 0), 0);

	# channels of a window not yet made: never ready
	noctl := chan of string;
	noptr := chan of ref Pointer;
	nokbd := chan of int;
	wctl := noctl;
	wwctl := noctl;
	wptr := noptr;
	wkbd := nokbd;

	for(;;){
		alt{
		# winname: the window, made at the first read
		(off, nil, nil, rc) := <-f.winname.read =>
			if(rc == nil)
				break;
			if(win == nil){
				e: string;
				(win, e) = mkwin();
				if(win == nil){
					rc <-= (nil, e);
					break;
				}
				(name, seq) = namewin(win, seq);
				if(label != nil)
					win.settitle(label);
				wctl = win.ctxt.ctl;
				wwctl = win.ctl;
				wptr = win.ctxt.ptr;
				wkbd = win.ctxt.kbd;
			}
			rc <-= (slice(array of byte name, off), nil);
		(nil, nil, nil, wc) := <-f.winname.write =>
			if(wc != nil)
				wc <-= (0, "permission denied");

		# mouse: events, 9front's form; a write moves the pointer
		(nil, n, fid, rc) := <-f.mouse.read =>
			if(rc == nil)
				break;
			if(win == nil){
				rc <-= (nil, "no window");
				break;
			}
			if(!member(fid, mice))
				mice = fid :: mice;
			if(mq != nil){
				rc <-= (hd mq, nil);
				mq = tl mq;
			}else
				mwait = append(mwait, ref Wait(fid, n, rc));
		(nil, d, fid, wc) := <-f.mouse.write =>
			if(wc == nil){
				# an open of mouse closed: the program may have gone
				mice = remove(fid, mice);
				mwait = dropfid(mwait, fid);
				if(mice == nil && win != nil){
					dropwin(win, name);
					win = nil;
					(wctl, wwctl, wptr, wkbd) = (noctl, noctl, noptr, nokbd);
					mq = nil;
					keys = nil;
					kq = nil;
				}
				break;
			}
			if(win == nil){
				wc <-= (0, "no window");
				break;
			}
			e := moveptr(win, string d);
			if(e != nil)
				wc <-= (0, e);
			else
				wc <-= (len d, nil);

		# cursor: 9front's 72 bytes, or nothing for the arrow
		(off, nil, nil, rc) := <-f.cursor.read =>
			if(rc != nil)
				rc <-= (slice(cursorbuf, off), nil);
		(nil, d, nil, wc) := <-f.cursor.write =>
			if(wc == nil)
				break;
			if(win == nil){
				wc <-= (0, "no window");
				break;
			}
			e := setcursor(win, d);
			if(e != nil)
				wc <-= (0, e);
			else{
				cursorbuf = d;
				wc <-= (len d, nil);
			}

		# cons: this command's input and output, or the window's keys
		# while a program there has it raw and no one reads kbd
		(nil, n, fid, rc) := <-f.cons.read =>
			if(rc == nil)
				break;
			if(win != nil && raw != nil && kbds == nil){
				if(keys != nil){
					(b, rest) := take(keys, n);
					keys = rest;
					rc <-= (b, nil);
				}else
					cwait = append(cwait, ref Wait(fid, n, rc));
			}else
				spawn readin(inq, n, rc);
		(nil, d, nil, wc) := <-f.cons.write =>
			if(wc == nil)
				break;
			if(sys->write(out, d, len d) != len d)
				wc <-= (0, sys->sprint("%r"));
			else
				wc <-= (len d, nil);

		(nil, nil, nil, rc) := <-f.consctl.read =>
			if(rc != nil)
				rc <-= (nil, "permission denied");
		(nil, d, fid, wc) := <-f.consctl.write =>
			if(wc == nil){
				raw = remove(fid, raw);
				break;
			}
			(nil, words) := sys->tokenize(string d, " \t\n");
			if(words != nil)
			case hd words {
			"rawon" =>
				if(!member(fid, raw))
					raw = fid :: raw;
			"rawoff" =>
				raw = remove(fid, raw);
			}
			wc <-= (len d, nil);

		# kbd: k, c and K messages; reading it takes the keys from cons
		(nil, n, fid, rc) := <-f.kbd.read =>
			if(rc == nil)
				break;
			if(win == nil){
				rc <-= (nil, "no window");
				break;
			}
			if(!member(fid, kbds))
				kbds = fid :: kbds;
			if(kq != nil){
				(b, rest) := takeb(kq, n);
				kq = rest;
				rc <-= (b, nil);
			}else
				kwait = append(kwait, ref Wait(fid, n, rc));
		(nil, nil, fid, wc) := <-f.kbd.write =>
			if(wc == nil){
				kbds = remove(fid, kbds);
				kwait = dropfid(kwait, fid);
				break;
			}
			wc <-= (0, "permission denied");

		(off, nil, nil, rc) := <-f.label.read =>
			if(rc != nil)
				rc <-= (slice(array of byte label, off), nil);
		(nil, d, nil, wc) := <-f.label.write =>
			if(wc == nil)
				break;
			label = string d;
			if(win != nil)
				win.settitle(label);
			wc <-= (len d, nil);

		(off, nil, nil, rc) := <-f.snarf.read =>
			if(rc != nil)
				rc <-= (slice(array of byte wmclient->snarfget(), off), nil);
		(nil, d, fid, wc) := <-f.snarf.write =>
			if(wc == nil){
				# the snarf written by this open, put when it closes
				for(l := snarfs; l != nil; l = tl l)
					if((hd l).t0 == fid)
						wmclient->snarfput((hd l).t1);
				snarfs = dropsnarf(snarfs, fid);
				break;
			}
			snarfs = addsnarf(snarfs, fid, string d);
			wc <-= (len d, nil);

		<-gfxquit =>
			dropwin(win, name);
			gfxdone <-= 1;
			exit;

		# the window's own events
		c := <-wctl or
		c = <-wwctl =>
			if(c == "exit"){
				# its close button: the window goes, not this session
				dropwin(win, name);
				win = nil;
				(wctl, wwctl, wptr, wkbd) = (noctl, noctl, noptr, nokbd);
				for(; mwait != nil; mwait = tl mwait)
					(hd mwait).rc <-= (nil, "window closed");
				mq = nil;
				mice = nil;
				break;
			}
			old := win.image;
			e := win.wmctl(c);
			if(e == nil && c != nil && c[0] == '!'){
				# a new image: a new name, and r for the program
				if(old != nil && name != nil)
					old.name(name, 0);
				(name, seq) = namewin(win, seq);
				(mq, mwait) = mouseevent(mq, mwait, 'r', last);
			}
		p := <-wptr =>
			if(win.pointer(*p) == 0){
				last = p;
				(mq, mwait) = mouseevent(mq, mwait, 'm', p);
			}
		k := <-wkbd =>
			r := p9key(k);
			if(kbds != nil){
				ks := sys->sprint("%c", r);
				kq = cat(kq, array of byte ("k"+ks+"\0c"+ks+"\0K\0"));
				while(kwait != nil && kq != nil){
					w := hd kwait;
					kwait = tl kwait;
					(b, rest) := takeb(kq, w.n);
					if(give(w.rc, b))
						kq = rest;
				}
			}else{
				keys[len keys] = r;
				while(cwait != nil && keys != nil){
					w := hd cwait;
					cwait = tl cwait;
					(b, rest) := take(keys, w.n);
					if(give(w.rc, b))
						keys = rest;
				}
			}
		}
	}
}

# data to a reader if it is still waiting (sys-file2chan(2)): what one
# that has gone was to have is kept for the next
give(rc: Sys->Rread, b: array of byte): int
{
	alt{
	<-rc =>
		return 0;
	* =>
		rc <-= (b, nil);
		return 1;
	}
}

readin(q: chan of (int, Sys->Rread), n: int, rc: Sys->Rread)
{
	q <-= (n, rc);
}

mkwin(): (ref Window, string)
{
	if(drawctxt == nil){
		drawctxt = wmclient->makedrawcontext();
		if(drawctxt == nil)
			return (nil, "no display");
	}
	w := wmclient->window(drawctxt, title, Wmclient->Appl);
	if(w == nil)
		return (nil, "cannot make a window");
	r := drawctxt.display.image.r;
	dx := Winsize;
	dy := Winsize*3/4;
	if(dx > r.dx()-40)
		dx = r.dx()-40;
	if(dy > r.dy()-60)
		dy = r.dy()-60;
	w.reshape(((0, 0), (dx, dy)));
	w.onscreen(nil);
	if(w.image == nil)
		return (nil, "cannot get an image to draw on");
	w.startinput("kbd" :: "ptr" :: nil);
	w.image.draw(w.image.r, drawctxt.display.white, nil, (0, 0));
	w.image.flush(Draw->Flushnow);
	return (w, nil);
}

# the window's image named for this session's scope (draw(3)): the
# name its programs find, and no other scope can
namewin(w: ref Window, seq: int): (string, int)
{
	for(;;){
		name := sys->sprint("%s.win.%d", scope, seq++);
		if(w.image.name(name, 1) > 0)
			return (name, seq);
		if(seq > 10000)
			return (nil, seq);
	}
}

dropwin(w: ref Window, name: string)
{
	if(w == nil)
		return;
	if(name != nil && w.image != nil)
		w.image.name(name, 0);
	w.image = nil;
	if(w.ctxt != nil)
		w.ctxt.connfd = nil;	# the window manager drops the window
}

mouseevent(q: list of array of byte, waiting: list of ref Wait, ch: int, p: ref Pointer): (list of array of byte, list of ref Wait)
{
	b := sys->aprint("%c%11d %11d %11d %11d ", ch, p.xy.x, p.xy.y, p.buttons, p.msec);
	for(; waiting != nil; waiting = tl waiting)
		if(give((hd waiting).rc, b))
			return (q, tl waiting);
	q = append1(q, b);
	if(len q > Mouseq)
		q = tl q;
	return (q, nil);
}

moveptr(w: ref Window, m: string): string
{
	if(m == nil || m[0] != 'm')
		return "invalid mouse message";
	(n, f) := sys->tokenize(m[1:], " ");
	if(n < 2)
		return "invalid mouse message";
	return w.wmctl(sys->sprint("ptr %d %d", int hd f, int hd tl f));
}

setcursor(w: ref Window, d: array of byte): string
{
	Hex: con "0123456789abcdef";
	if(len d != 2*4+64)
		return w.wmctl("cursor");
	s := sys->sprint("cursor %d %d 16 32 ", glong(d, 0), glong(d, 4));
	for(i := 2*4; i < len d; i++){
		c := int d[i];
		s[len s] = Hex[c >> 4];
		s[len s] = Hex[c & 16rf];
	}
	return w.wmctl(s);
}

glong(d: array of byte, i: int): int
{
	v := int d[i] | (int d[i+1]<<8) | (int d[i+2]<<16) | (int d[i+3]<<24);
	return v;
}

# this machine's keys as 9front's keyboard.h has them
p9key(c: int): int
{
	KF: con 16rF000;
	Spec: con 16rF800;
	case c {
	Keyboard->LShift =>	return KF|16r16;
	Keyboard->LCtrl =>	return KF|16r17;
	Keyboard->LAlt =>	return KF|16r15;
	Keyboard->Home =>	return KF|16r0D;
	Keyboard->End =>	return KF|16r18;
	Keyboard->Up =>	return KF|16r0E;
	Keyboard->Down =>	return Spec|16r00;
	Keyboard->Left =>	return KF|16r11;
	Keyboard->Right =>	return KF|16r12;
	Keyboard->Pgup =>	return KF|16r0F;
	Keyboard->Pgdown =>	return KF|16r13;
	Keyboard->Ins =>	return KF|16r14;
	}
	if(c > Keyboard->KF && c <= Keyboard->KF+12)
		return KF|(c - Keyboard->KF);
	return c;
}

slice(b: array of byte, off: int): array of byte
{
	if(b == nil || off < 0 || off >= len b)
		return nil;
	return b[off:];
}

take(s: string, n: int): (array of byte, string)
{
	b := array of byte s;
	if(len b <= n)
		return (b, nil);
	# whole runes only
	i := 0;
	m := 0;
	for(; i < len s; i++){
		l := len array of byte s[i:i+1];
		if(m + l > n)
			break;
		m += l;
	}
	if(i == 0)
		i = 1;
	return (array of byte s[0:i], s[i:]);
}

takeb(b: array of byte, n: int): (array of byte, array of byte)
{
	if(len b <= n)
		return (b, nil);
	return (b[0:n], b[n:]);
}

cat(a, b: array of byte): array of byte
{
	if(a == nil)
		return b;
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

member(x: int, l: list of int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}

remove(x: int, l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		if(hd l != x)
			r = hd l :: r;
	return r;
}

append(l: list of ref Wait, w: ref Wait): list of ref Wait
{
	if(l == nil)
		return w :: nil;
	return hd l :: append(tl l, w);
}

append1(l: list of array of byte, b: array of byte): list of array of byte
{
	if(l == nil)
		return b :: nil;
	return hd l :: append1(tl l, b);
}

dropfid(l: list of ref Wait, fid: int): list of ref Wait
{
	r: list of ref Wait;
	for(; l != nil; l = tl l)
		if((hd l).fid != fid)
			r = hd l :: r;
		else
			(hd l).rc <-= (nil, "closed");
	return rev(r);
}

rev(l: list of ref Wait): list of ref Wait
{
	r: list of ref Wait;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

addsnarf(l: list of (int, string), fid: int, s: string): list of (int, string)
{
	r: list of (int, string);
	found := 0;
	for(; l != nil; l = tl l)
		if((hd l).t0 == fid){
			r = (fid, (hd l).t1 + s) :: r;
			found = 1;
		}else
			r = hd l :: r;
	if(!found)
		r = (fid, s) :: r;
	return r;
}

dropsnarf(l: list of (int, string), fid: int): list of (int, string)
{
	r: list of (int, string);
	for(; l != nil; l = tl l)
		if((hd l).t0 != fid)
			r = hd l :: r;
	return r;
}

kill(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}
