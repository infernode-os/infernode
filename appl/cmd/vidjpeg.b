implement Vidjpeg;

#
# vidjpeg - a feed served as JPEG (videnc(1)) back as I420 frames.
#
#	mount {vidjpeg /n/pi5/video/0} /mnt/video
#
# Serves 0/{ctl,fmt,frame,status,layer/} as vid9p(4) does, so whatever
# reads a feed (wm/camera, vidplay9p, vision(4)) reads this one: frame N
# is the framesize bytes at N*framesize.  A read of frame N takes N's
# record from the feed's jpeg/index (waiting there at the live edge as
# frame waits), its bytes from jpeg/data (several reads at once), and
# decodes them to planes with readjpg (no RGB between); the last few
# decoded are kept, so the several reads one frame is read with decode
# it once.  status and fmt are the feed's, read through; ctl is passed
# to the feed's; layer/ is empty, as vid9p serves it, for layers bound
# here.  Errors (frame expired) are the feed's.
#
# Across a network (the feed mounted from another machine, over sdg(2)
# or TCP) a frame read one request after another falls behind a live
# feed, so while frames are being read, the AHEAD frames after the
# latest one asked for are fetched and decoded too, each once it is due
# by the live edge (livefeed(2)) less LEAD ms, so that few reads wait at
# the feed's server for frames not yet made.  A frame's bytes are read
# in WAYS pieces at once, and a read answered "reply gone" is sent
# again.  The edge is taken from the feed's status at the start and
# again when a frame has expired, never on other errors.  A second
# without a frame asked for and nothing more is fetched.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
include "jpeg.m";
	jp: Jpegplanes;
include "livefeed.m";
	livefeed: Livefeed;
	Edge: import livefeed;

Vidjpeg: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Qroot, Qstream, Qctl, Qfmt, Qframe, Qstatus, Qlayer: con iota;
RECLEN: con 32;
NKEEP: con 16;	# frames kept decoded
NWORK: con 8;	# frames fetched and decoding at once
WAYS: con 8;	# reads in flight for one frame's bytes
AHEAD: con 4;	# frames fetched after the latest one asked for
LEAD: con 50;	# ms before its frame is due that a fetch may start
TICK: con 15;	# ms between looks at what is due
IDLE: con 1000;	# ms without a frame asked for: stop fetching ahead

Frm: adt {
	n:	int;
	b:	array of byte;	# I420, framesize bytes
};

stderr: ref Sys->FD;
src: string;
index, data: ref Sys->FD;
w, h, fps, framesize: int;
kept: list of ref Frm;	# newest first
busy: list of int;
waiting: list of ref Tmsg.Read;
srv: ref Styxserver;
done: chan of (int, array of byte, string);
edge: ref Edge;		# nil until status has been read
want := -1;		# the latest frame asked for
asked := 0;		# when (sys->millisec())
ticking := 0;
tick: chan of int;
tickgo: chan of int;
anchoring := 0;
anchorc: chan of (int, int);

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	jp = load Jpegplanes Jpegplanes->PATH;
	livefeed = load Livefeed Livefeed->PATH;
	if(styx == nil || styxservers == nil || nametree == nil || jp == nil || livefeed == nil)
		fatal(sys->sprint("can't load a module: %r"));
	styx->init();
	styxservers->init(styx);
	nametree->init();
	args = tl args;
	if(len args != 1){
		sys->fprint(stderr, "usage: vidjpeg feeddir\n");
		raise "fail:usage";
	}
	src = hd args;
	e: string;
	(w, h, fps, e) = readfmt(src + "/jpeg/fmt");
	if(e != nil)
		fatal(e);
	framesize = w*h + 2 * ((w+1)/2) * ((h+1)/2);
	index = sys->open(src + "/jpeg/index", Sys->OREAD);
	data = sys->open(src + "/jpeg/data", Sys->OREAD);
	if(index == nil || data == nil)
		fatal(sys->sprint("can't open %s/jpeg: %r", src));
	sys->pctl(Sys->NEWPGRP, nil);
	livefeed->init();
	done = chan of (int, array of byte, string);
	tick = chan of int;
	tickgo = chan of int;
	anchorc = chan of (int, int);
	edge = Edge.new(src, fps);

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("0", Sys->DMDIR|8r555, Qstream));
	tree.create(big Qstream, dir("ctl", 8r666, Qctl));
	tree.create(big Qstream, dir("fmt", 8r444, Qfmt));
	tree.create(big Qstream, dir("frame", 8r444, Qframe));
	tree.create(big Qstream, dir("status", 8r444, Qstatus));
	tree.create(big Qstream, dir("layer", Sys->DMDIR|8r555, Qlayer));
	tc: chan of ref Tmsg;
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	serve(tc, tree);
}

fatal(s: string)
{
	sys->fprint(stderr, "vidjpeg: %s\n", s);
	raise "fail:" + s;
}

dir(name: string, perm, qid: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "vidjpeg";
	d.qid.path = big qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	return d;
}

# "jpeg <w> <h> 420 <fps>"
readfmt(f: string): (int, int, int, string)
{
	s := readfile(f);
	if(s == nil)
		return (0, 0, 0, sys->sprint("can't read %s: %r", f));
	(nf, fl) := sys->tokenize(s, " \t\n");
	if(nf < 5 || hd fl != "jpeg" || hd tl tl tl fl != "420")
		return (0, 0, 0, f + ": not a 4:2:0 JPEG feed: " + s);
	return (int hd tl fl, int hd tl tl fl, int hd tl tl tl tl fl, nil);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[8192] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		s += string b[0:n];
	return s;
}

serve(tc: chan of ref Tmsg, tree: ref Tree)
{
	for(;;) alt {
	tmsg := <-tc =>
		if(tmsg == nil){
			shutdown(tree);
			return;
		}
		pick tm := tmsg {
		Readerror =>
			shutdown(tree);
			return;
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			case int c.path {
			Qroot or Qstream or Qlayer =>
				srv.read(tm);
			Qfmt =>
				srv.reply(styxservers->readstr(tm, sys->sprint("%d %d i420 %d\n", w, h, fps)));
			Qstatus or Qctl =>
				# the feed's own, read through
				f := "/status";
				if(int c.path == Qctl)
					f = "/ctl";
				s := readfile(src + f);
				if(s == nil)
					srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("%r")));
				else
					srv.reply(styxservers->readstr(tm, s));
			Qframe =>
				readframe(tm);
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "vidjpeg: bad path"));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			else if(int c.path != Qctl)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			else {
				# to the feed's ctl, from a process of its own: it may wait
				spawn ctlwrite(tm);
			}
		Flush =>
			still: list of ref Tmsg.Read;
			for(l := waiting; l != nil; l = tl l)
				if((hd l).tag != tm.oldtag)
					still = hd l :: still;
			waiting = still;
			srv.default(tmsg);
		* =>
			srv.default(tmsg);
		}
	(n, b, e) := <-done =>
		if(e != "later")
			busy = remove(busy, n);
		if(b != nil)
			keep(n, b);
		still, again: list of ref Tmsg.Read;
		for(l := waiting; l != nil; l = tl l){
			tm := hd l;
			if(int (tm.offset / big framesize) != n)
				still = tm :: still;
			else if(b != nil)
				replyframe(tm, b);
			else if(e == "later")
				again = tm :: again;
			else
				srv.reply(ref Rmsg.Error(tm.tag, e));
		}
		waiting = still;
		for(; again != nil; again = tl again)
			start(n, hd again);
		if(e != nil && contains(e, "frame expired") && !anchoring){
			# the readers are behind: where the feed is, again
			anchoring = 1;
			spawn anchor();
		}
	<-tick =>
		if(sys->millisec() - asked > IDLE){
			ticking = 0;
			tickgo <-= 0;
			break;
		}
		tickgo <-= 1;
		ahead();
	(lf, lt) := <-anchorc =>
		anchoring = 0;
		if(lf >= 0){
			if(edge == nil)
				edge = ref Edge(src, fps, lf, lt);
			else
				edge.set(lf, lt);
		}
	}
}

# the frames after the latest asked for, once each is due less LEAD
ahead()
{
	if(edge == nil){
		if(!anchoring){
			anchoring = 1;
			spawn anchor();
		}
		return;
	}
	for(m := want + 1; m <= want + AHEAD; m++){
		if(member(busy, m) || iskept(m))
			continue;
		if(len busy >= NWORK)
			return;
		if(m > edge.newest() && edge.due(m) > LEAD)
			return;
		busy = m :: busy;
		spawn decode(m);
	}
}

iskept(n: int): int
{
	for(l := kept; l != nil; l = tl l)
		if((hd l).n == n)
			return 1;
	return 0;
}

anchor()
{
	anchorc <-= livefeed->status(src);
}

ticker()
{
	do{
		sys->sleep(TICK);
		tick <-= 1;
	}while(<-tickgo);
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

shutdown(tree: ref Tree)
{
	tree.quit();
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

ctlwrite(tm: ref Tmsg.Write)
{
	fd := sys->open(src + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->write(fd, tm.data, len tm.data) != len tm.data)
		srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("%r")));
	else
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
}

readframe(tm: ref Tmsg.Read)
{
	n := int (tm.offset / big framesize);
	want = n;
	asked = sys->millisec();
	if(!ticking){
		ticking = 1;
		spawn ticker();
	}
	for(l := kept; l != nil; l = tl l)
		if((hd l).n == n){
			replyframe(tm, (hd l).b);
			return;
		}
	start(n, tm);
}

start(n: int, tm: ref Tmsg.Read)
{
	if(tm != nil)
		waiting = tm :: waiting;
	if(member(busy, n))
		return;
	if(len busy >= NWORK){
		spawn later(n);
		return;
	}
	busy = n :: busy;
	spawn decode(n);
}

later(n: int)
{
	sys->sleep(5);
	done <-= (n, nil, "later");
}

replyframe(tm: ref Tmsg.Read, b: array of byte)
{
	o := int (tm.offset % big framesize);
	k := len b - o;
	if(k > tm.count)
		k = tm.count;
	srv.reply(ref Rmsg.Read(tm.tag, b[o:o+k]));
}

keep(n: int, b: array of byte)
{
	kept = ref Frm(n, b) :: kept;
	k: list of ref Frm;
	i := 0;
	for(l := kept; l != nil && i < NKEEP; l = tl l){
		k = hd l :: k;
		i++;
	}
	kept = nil;
	for(; k != nil; k = tl k)
		kept = hd k :: kept;
}

# frame n: its record, its bytes, its planes
decode(n: int)
{
	rec := array[RECLEN] of byte;
	k := livefeed->pread(index, rec, len rec, big n * big RECLEN);
	if(k <= 0){
		e := sys->sprint("%r");
		if(k == 0)
			e = "vidjpeg: no such frame";
		done <-= (n, nil, e);
		return;
	}
	(nf, fl) := sys->tokenize(string rec[0:k], " \n");
	if(nf != 2){
		done <-= (n, nil, "vidjpeg: bad index record: " + string rec[0:k]);
		return;
	}
	off := big hd fl;
	sz := int hd tl fl;
	if(sz <= 0 || sz > 16*1024*1024){
		done <-= (n, nil, "vidjpeg: bad index record: " + string rec[0:k]);
		return;
	}
	j := array[sz] of byte;
	(got, err) := livefeed->read(data, j, off, WAYS);
	if(got != sz){
		if(err == nil)
			err = "vidjpeg: short frame";
		done <-= (n, nil, err);
		return;
	}
	(dw, dh, y, u, v, derr) := jp->planes(j);
	if(derr != nil){
		done <-= (n, nil, derr);
		return;
	}
	if(dw != w || dh != h){
		done <-= (n, nil, sys->sprint("vidjpeg: frame %d is %dx%d, not %dx%d", n, dw, dh, w, h));
		return;
	}
	b := array[framesize] of byte;
	b[0:] = y;
	b[len y:] = u;
	b[len y + len u:] = v;
	done <-= (n, b, nil);
}

member(l: list of int, n: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == n)
			return 1;
	return 0;
}

remove(l: list of int, n: int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		if(hd l != n)
			r = hd l :: r;
	return r;
}
