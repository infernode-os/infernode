implement Videnc;

#
# videnc - a video feed's frames as JPEG, beside its raw ones.
#
#	mount -a {videnc /mnt/video/0} /mnt/video/0
#
# Reads the feed's fmt and frame (vid9p(4), camsrv(4): I420, frame N the
# framesize bytes at N*framesize) and serves
#
#	jpeg/ctl	"quality N" (1-100, default 75); read back
#	jpeg/fmt	"jpeg <w> <h> 420 <fps>"
#	jpeg/index	frame N's record at offset N*32: "<off> <len>" padded to
#			31 bytes and a newline, <off> and <len> the frame's
#			place in data
#	jpeg/data	the encoded frames end to end, offsets only growing
#
# A frame is encoded when its record is first read, once however many
# read it: a feed nobody reads encoded costs nothing.  Reading a record
# for a frame the feed has not made yet waits for it, as the feed's frame
# does; one the feed no longer keeps, or that has left this cache (the
# last 64 frames encoded), is "frame expired".  A changed quality starts
# the cache again.  Union-mounted after the feed, with export(4) in front,
# a remote viewer reads jpeg/ where a local one reads frame; vidjpeg(1)
# turns it back into frames there.
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
	enc: Jpegenc;

Videnc: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Qroot, Qjpeg, Qctl, Qfmt, Qindex, Qdata: con iota;
RECLEN: con 32;
NCACHE: con 64;
NWORK: con 4;	# frames encoding at once

Ent: adt {
	n:	int;
	off:	big;
	data:	array of byte;
};

Job: adt {
	n:	int;
	gen:	int;	# the quality generation it was started in
};

stderr: ref Sys->FD;
src: string;
srcframe: ref Sys->FD;
w, h, fps, framesize: int;
quality := 75;
gen := 0;		# bumped when the quality changes: older work is dropped
cache: list of ref Ent;	# newest first
ncache := 0;
nextoff := big 0;
busy: list of int;	# frames being encoded
waiting: list of ref Tmsg.Read;	# index reads for frames being encoded
srv: ref Styxserver;
done: chan of (int, int, array of byte, string);	# n, gen, jpeg, error

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	enc = load Jpegenc Jpegenc->PATH;
	if(styx == nil || styxservers == nil || nametree == nil || enc == nil)
		fatal(sys->sprint("can't load a module: %r"));
	styx->init();
	styxservers->init(styx);
	nametree->init();
	args = tl args;
	if(len args != 1){
		sys->fprint(stderr, "usage: videnc feeddir\n");
		raise "fail:usage";
	}
	src = hd args;
	e: string;
	(w, h, fps, e) = readfmt(src + "/fmt");
	if(e != nil)
		fatal(e);
	framesize = w*h + 2 * ((w+1)/2) * ((h+1)/2);
	srcframe = sys->open(src + "/frame", Sys->OREAD);
	if(srcframe == nil)
		fatal(sys->sprint("can't open %s/frame: %r", src));
	sys->pctl(Sys->NEWPGRP, nil);
	done = chan of (int, int, array of byte, string);

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("jpeg", Sys->DMDIR|8r555, Qjpeg));
	tree.create(big Qjpeg, dir("ctl", 8r666, Qctl));
	tree.create(big Qjpeg, dir("fmt", 8r444, Qfmt));
	tree.create(big Qjpeg, dir("index", 8r444, Qindex));
	tree.create(big Qjpeg, dir("data", 8r444, Qdata));
	tc: chan of ref Tmsg;
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	serve(tc, tree);
}

fatal(s: string)
{
	sys->fprint(stderr, "videnc: %s\n", s);
	raise "fail:" + s;
}

dir(name: string, perm, qid: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "videnc";
	d.qid.path = big qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	return d;
}

# "<w> <h> i420 <fps>"
readfmt(f: string): (int, int, int, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (0, 0, 0, sys->sprint("can't open %s: %r", f));
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return (0, 0, 0, sys->sprint("can't read %s: %r", f));
	(nf, fl) := sys->tokenize(string b[0:n], " \t\n");
	if(nf < 4 || hd tl tl fl != "i420")
		return (0, 0, 0, f + ": not an I420 feed: " + string b[0:n]);
	fw := int hd fl;
	fh := int hd tl fl;
	if(fw <= 0 || fh <= 0)
		return (0, 0, 0, f + ": no geometry yet");
	return (fw, fh, int hd tl tl tl fl, nil);
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
			Qroot or Qjpeg =>
				srv.read(tm);
			Qfmt =>
				srv.reply(styxservers->readstr(tm, sys->sprint("jpeg %d %d 420 %d\n", w, h, fps)));
			Qctl =>
				srv.reply(styxservers->readstr(tm, sys->sprint("quality %d\n", quality)));
			Qindex =>
				readindex(tm);
			Qdata =>
				readdata(tm);
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "videnc: bad path"));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			else if(int c.path != Qctl)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			else if((e := ctl(string tm.data)) != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Flush =>
			# a read given up on is not answered later
			still: list of ref Tmsg.Read;
			for(l := waiting; l != nil; l = tl l)
				if((hd l).tag != tm.oldtag)
					still = hd l :: still;
			waiting = still;
			srv.default(tmsg);
		* =>
			srv.default(tmsg);
		}
	(n, g, j, e) := <-done =>
		if(g >= 0)	# a worker's result, not later()'s reminder
			busy = remove(busy, n);
		if(g == gen && j != nil)
			add(n, j);
		still, again: list of ref Tmsg.Read;
		for(l := waiting; l != nil; l = tl l){
			tm := hd l;
			if(int (tm.offset / big RECLEN) != n)
				still = tm :: still;
			else if(g != gen)
				again = tm :: again;	# the quality changed while it encoded, or no worker was free
			else if(e != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				replyrec(tm, find(n));
		}
		waiting = still;
		for(; again != nil; again = tl again)
			start(n, hd again, 1);
	}
}

shutdown(tree: ref Tree)
{
	tree.quit();
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

ctl(s: string): string
{
	(nf, fl) := sys->tokenize(s, " \t\n");
	if(nf == 2 && hd fl == "quality"){
		q := int hd tl fl;
		if(q < 1 || q > 100)
			return "videnc: quality is 1-100";
		if(q != quality){
			quality = q;
			gen++;
			cache = nil;	# the old frames' bytes are not this quality's
			ncache = 0;
		}
		return nil;
	}
	return "videnc: unknown control: " + s;
}

readindex(tm: ref Tmsg.Read)
{
	if(tm.offset % big RECLEN != big 0){
		srv.reply(ref Rmsg.Error(tm.tag, "videnc: read a record at a multiple of 32"));
		return;
	}
	n := int (tm.offset / big RECLEN);
	if((e := find(n)) != nil){
		replyrec(tm, e);
		return;
	}
	start(n, tm, 0);
}

# n is wanted: encode it unless it is already being encoded; tm waits for it
start(n: int, tm: ref Tmsg.Read, nil: int)
{
	waiting = tm :: waiting;
	if(member(busy, n))
		return;		# its worker's result will answer it
	if(len busy >= NWORK){
		spawn later(n);	# every worker busy: asked for again shortly
		return;
	}
	busy = n :: busy;
	spawn encode(n, gen, quality);
}

# a frame wanted while every worker was busy: asked for again shortly
later(n: int)
{
	sys->sleep(5);
	done <-= (n, -1, nil, nil);
}

replyrec(tm: ref Tmsg.Read, e: ref Ent)
{
	rec := sys->sprint("%bd %d", e.off, len e.data);
	b := array[RECLEN] of {* => byte ' '};
	b[0:] = array of byte rec;
	b[RECLEN-1] = byte '\n';
	n := tm.count;
	if(n > RECLEN)
		n = RECLEN;
	srv.reply(ref Rmsg.Read(tm.tag, b[0:n]));
}

readdata(tm: ref Tmsg.Read)
{
	for(l := cache; l != nil; l = tl l){
		e := hd l;
		if(tm.offset >= e.off && tm.offset < e.off + big len e.data){
			o := int (tm.offset - e.off);
			n := len e.data - o;
			if(n > tm.count)
				n = tm.count;
			srv.reply(ref Rmsg.Read(tm.tag, e.data[o:o+n]));
			return;
		}
	}
	if(tm.offset >= nextoff)
		srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
	else
		srv.reply(ref Rmsg.Error(tm.tag, "frame expired"));
}

find(n: int): ref Ent
{
	for(l := cache; l != nil; l = tl l)
		if((hd l).n == n)
			return hd l;
	return nil;
}

add(n: int, j: array of byte)
{
	if(find(n) != nil)
		return;
	cache = ref Ent(n, nextoff, j) :: cache;
	nextoff += big len j;
	if(++ncache > NCACHE){
		k: list of ref Ent;
		i := 0;
		for(l := cache; l != nil && i < NCACHE; l = tl l){
			k = hd l :: k;
			i++;
		}
		cache = nil;
		for(; k != nil; k = tl k)
			cache = hd k :: cache;
		ncache = NCACHE;
	}
}

# read frame n of the feed (waiting for it at the live edge) and encode it
encode(n, g, q: int)
{
	b := array[framesize] of byte;
	got := 0;
	while(got < framesize){
		k := sys->pread(srcframe, b[got:], framesize - got, big n * big framesize + big got);
		if(k < 0){
			done <-= (n, g, nil, sys->sprint("%r"));
			return;
		}
		if(k == 0){
			done <-= (n, g, nil, "videnc: no such frame");
			return;
		}
		got += k;
	}
	cw := (w+1)/2;
	ch := (h+1)/2;
	(j, e) := enc->encode(w, h, b[0:w*h], b[w*h:w*h+cw*ch], b[w*h+cw*ch:], q);
	done <-= (n, g, j, e);
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
