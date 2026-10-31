implement Scenefs;

#
# scenefs — serve a live 2-D scene: its objects, a shared camera, and
# the stream of its changes.  docs/scene-design.md §3; man/4/scenefs.
#
#	mount {scenefs} /mnt/scene
#
# The tree (all text; stanza files are one attr=value per line):
#
#	ctl		(w)  one command per write line:
#			     center A B | zoom Z | fit | follow ID | unfollow
#			     select ID | deselect | clear
#	view		(r)  "frame F center A B zoom Z sel ID follow ID fit N"
#			     (N is a pending fit request, 0 when none)
#	status		(r)  "t T gen G entities N features N layers N"
#	event		(r)  blocking; one event per read, each open its own
#			     cursor: "gen G", "select ID", "view ..."
#	changes		(r)  blocking; every change as records (§3.2), each
#			     stamped with the clock when it moved; each open is
#			     its own cursor and begins with the scene as it
#			     stands, so what it reads is a recording:
#				cat /mnt/scene/changes > run.scene
#	log		(w)  records, one per line; a write is seen whole,
#			     and a bad record stops it (the lines before stand)
#	meta		(rw) the scene's stanza (frame=, units=, title=, ...)
#	time		(rw) the scene clock
#	entities/	(rw) one stanza file per entity: create, write, remove
#	features/	(rw) likewise
#	layers/		(rw) likewise
#
# A stanza write lands at its offset and takes effect at once.  The
# server keeps no history: recording is reading changes, and replay is
# scenereplay(1) writing a recording back into log.
#
# scenefs holds no authority beyond the files it serves: it opens none.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
include "string.m";
	str: String;
include "scene.m";
	scene: Scene;
	Model, Cam, Obj: import scene;

Scenefs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qview, Qstatus, Qevent, Qchanges, Qlog, Qmeta, Qtime,
Qentdir, Qfeatdir, Qlayerdir: con iota;
Qobj: con 16;		# + kind; the object's slot is path >> 8

EVMAX: con 64;
CHMAX: con 4*1024*1024;	# bytes a changes reader may fall behind

stderr: ref Sys->FD;
user: string;
srv: ref Styxserver;
lk: chan of int;

live: ref Model;	# the scene
cam: ref Cam;
fitseq := 1;
fitpending := 1;	# a fit asked for and not yet answered (only a viewer
			# knows its size); a fresh scene asks for one
sgen := 0;		# bumped whenever the scene changes
lastrect := 0.0;	# the clock value last stamped into changes
hasrect := 0;

# object slots: qid path <-> (kind, id), append-only
slotids: array of array of string;
nslots: array of int;
slotlook: array of array of list of (string, int);

# event cursors
Evq: adt {
	fid:	int;
	q:	list of string;	# oldest first
	n:	int;
	pending: ref Tmsg.Read;
};
evqs: list of ref Evq;

# changes cursors: the bytes a reader has yet to read, one array each
Chq: adt {
	fid:	int;
	buf:	array of byte;
	n:	int;
	lost:	int;	# fell more than CHMAX behind: changes were dropped
	pending: ref Tmsg.Read;
};
chqs: list of ref Chq;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	scene = load Scene Scene->PATH;
	str = load String String->PATH;
	if(str == nil || styx == nil || styxservers == nil || scene == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("scenefs [-D]");
	while((c := arg->opt()) != 0)
		case c {
		'D' =>	styxservers->traceset(1);
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";

	live = Model.new();
	cam = Cam.new(((0, 0), (0, 0)));
	slotids = array[3] of array of string;
	nslots = array[3] of {* => 0};
	slotlook = array[3] of array of list of (string, int);
	for(k := 0; k < 3; k++) {
		slotids[k] = array[64] of string;
		slotlook[k] = array[257] of list of (string, int);
	}
	lk = chan[1] of int;

	navops := chan of ref Navop;
	spawn navigator(navops);
	tc: chan of ref Tmsg;
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navops), big Qroot);
	serve(tc);
}

lock()
{
	lk <-= 1;
}

unlock()
{
	<-lk;
}

serve(tc: chan of ref Tmsg)
{
	for(;;) {
		tmsg := <-tc;
		if(tmsg == nil)
			exit;
		pick tm := tmsg {
		Readerror =>
			exit;
		Flush =>
			cancelpending(tm.oldtag);
			cancelchq(tm.oldtag);
			srv.reply(ref Rmsg.Flush(tm.tag));
		Open =>
			c := srv.open(tm);
			if(c == nil)
				break;
			if(int c.path == Qevent)
				evqs = ref Evq(c.fid, nil, 0, nil) :: evqs;
			if(int c.path == Qchanges) {
				# begin with the scene as it stands: a self-contained recording
				lock();
				d := array of byte live.dump();
				unlock();
				chqs = ref Chq(c.fid, d, len d, 0, nil) :: chqs;
			}
			# a truncating open starts the file afresh; otherwise
			# writes land in the current contents at their offset
			if(tm.mode & Sys->OTRUNC && writable(c.path))
				wbufs = ref Wbuf(c.fid, array[0] of byte) :: wbufs;
		Create =>
			docreate(tm);
		Read =>
			doread(tm);
		Write =>
			dowrite(tm);
		Clunk =>
			c := srv.getfid(tm.fid);
			if(c != nil) {
				if(TYPE(c.path) == Qlog && (lb := getwbuf(c.fid)) != nil) {
					lock();
					change(trim(string lb.buf));
					unlock();
					changed();
				}
				dropwbuf(c.fid);
				if(int c.path == Qevent)
					dropevq(c.fid);
				if(int c.path == Qchanges)
					dropchq(c.fid);
			}
			srv.clunk(tm);
		Remove =>
			doremove(tm);
		* =>
			srv.default(tmsg);
		}
	}
}

# ── reads ──────────────────────────────────────────────────

doread(tm: ref Tmsg.Read)
{
	c := srv.getfid(tm.fid);
	if(c == nil || !c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	p := c.path;
	case TYPE(p) {
	Qroot or Qentdir or Qfeatdir or Qlayerdir =>
		srv.read(tm);
	Qctl or Qlog =>
		srv.reply(styxservers->readstr(tm, ""));
	Qview =>
		srv.reply(styxservers->readstr(tm, viewtext() + "\n"));
	Qstatus =>
		srv.reply(styxservers->readstr(tm, statustext() + "\n"));
	Qmeta =>
		lock();
		s := live.metatext();
		unlock();
		srv.reply(styxservers->readstr(tm, s));
	Qtime =>
		s := "";
		if(live.hast)
			s = fmt(live.t) + "\n";
		srv.reply(styxservers->readstr(tm, s));
	Qchanges =>
		q := getchq(c.fid);
		if(q == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "lost changes cursor"));
			return;
		}
		if(q.pending != nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
			return;
		}
		if(q.lost) {
			srv.reply(ref Rmsg.Error(tm.tag, "changes lost: the reader fell behind"));
			return;
		}
		if(q.n == 0) {
			q.pending = tm;
			return;
		}
		srv.reply(chreply(tm, q));
	Qevent =>
		q := getevq(c.fid);
		if(q == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "lost event cursor"));
			return;
		}
		if(q.pending != nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
			return;
		}
		if(q.q == nil) {
			q.pending = tm;
			return;
		}
		srv.reply(evreply(tm, q));
	* =>
		if(TYPE(p) >= Qobj && TYPE(p) < Qobj + 3) {
			lock();
			o := live.find(TYPE(p) - Qobj, slotid(p));
			s := "";
			if(o != nil)
				s = o.text();
			unlock();
			if(o == nil)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Enotfound));
			else
				srv.reply(styxservers->readstr(tm, s));
			return;
		}
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
	}
}

viewtext(): string
{
	lock();
	s := cam.text(live) + " fit " + string fitpending;
	unlock();
	return s;
}

statustext(): string
{
	lock();
	t := 0.0;
	if(live.hast)
		t = live.t;
	s := sys->sprint("t %s gen %d entities %d features %d layers %d",
		fmt(t), sgen,
		live.count(Scene->ENT), live.count(Scene->FEAT), live.count(Scene->LAYER));
	unlock();
	return s;
}

# ── writes ─────────────────────────────────────────────────

writable(p: big): int
{
	t := TYPE(p);
	return t == Qmeta || t == Qtime || t >= Qobj && t < Qobj + 3;
}

dowrite(tm: ref Tmsg.Write)
{
	c := srv.getfid(tm.fid);
	if(c == nil || !c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	case TYPE(c.path) {
	Qctl =>
		err: string;
		(nil, lines) := sys->tokenize(string tm.data, "\n");
		for(; lines != nil && err == nil; lines = tl lines)
			err = ctl(trim(hd lines));
		if(err != nil)
			srv.reply(ref Rmsg.Error(tm.tag, err));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	Qlog =>
		# a long write reaches us split at the iounit: hold a partial
		# last line until the rest arrives
		# (in bytes: the split may fall inside a UTF-8 sequence)
		lerr: string;
		data := tm.data;
		if((lb := getwbuf(c.fid)) != nil) {
			nd := array[len lb.buf + len data] of byte;
			nd[0:] = lb.buf;
			nd[len lb.buf:] = data;
			data = nd;
			dropwbuf(c.fid);
		}
		for(e := len data; e > 0 && data[e-1] != byte '\n'; e--)
			;
		if(e < len data)
			wbufs = ref Wbuf(c.fid, data[e:]) :: wbufs;
		text := string data[0:e];
		lock();
		(nil, llines) := sys->tokenize(text, "\n");
		for(; llines != nil && lerr == nil; llines = tl llines)
			lerr = change(trim(hd llines));
		unlock();
		changed();
		if(lerr != nil)
			srv.reply(ref Rmsg.Error(tm.tag, lerr));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	* =>
		if(!writable(c.path)) {
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			return;
		}
		# Stanza files behave as files: the write lands at its offset
		# in the current contents and the result applies at once, so
		# echo >, echo >> and a multi-write editor all do what they say.
		wb := getwbuf(c.fid);
		if(wb == nil) {
			wb = ref Wbuf(c.fid, array of byte filetext(c.path));
			wbufs = wb :: wbufs;
		}
		off := int tm.offset;
		if(off > len wb.buf)
			off = len wb.buf;
		end := off + len tm.data;
		if(end > len wb.buf) {
			nb := array[end] of byte;
			nb[0:] = wb.buf;
			wb.buf = nb;
		}
		wb.buf[off:] = tm.data;
		err := applyfile(c.path, string wb.buf);
		if(err != nil)
			srv.reply(ref Rmsg.Error(tm.tag, err));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	}
}

Wbuf: adt {
	fid:	int;
	buf:	array of byte;
};
wbufs: list of ref Wbuf;

getwbuf(fid: int): ref Wbuf
{
	for(l := wbufs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropwbuf(fid: int)
{
	nl: list of ref Wbuf;
	for(l := wbufs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	wbufs = nl;
}

# The live contents of a writable file (what a non-truncating write edits).
filetext(p: big): string
{
	lock();
	s := "";
	case TYPE(p) {
	Qmeta =>
		s = live.metatext();
	Qtime =>
		if(live.hast)
			s = fmt(live.t) + "\n";
	* =>
		if((o := live.find(TYPE(p) - Qobj, slotid(p))) != nil)
			s = o.text();
	}
	unlock();
	return s;
}

# A stanza file's new contents, applied as one record.
applyfile(p: big, text: string): string
{
	rec: string;
	t := TYPE(p);
	lock();
	case t {
	Qmeta =>
		rec = recline("meta" :: nil, scene->stanza(text));
	Qtime =>
		v := trim(text);
		if(v == "") {
			unlock();
			return nil;
		}
		rec = "time " + v;
	* =>
		k := t - Qobj;
		rec = recline(scene->kindname(k) :: slotid(p) :: nil, scene->stanza(text));
	}
	err := change(rec);
	unlock();
	changed();
	return err;
}

recline(head: list of string, kv: list of (string, string)): string
{
	l := rev(head);
	for(; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		l = (k + "=" + v) :: l;
	}
	return quotedl(rev(l));
}

docreate(tm: ref Tmsg.Create)
{
	c := srv.getfid(tm.fid);
	if(c == nil || c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	k := -1;
	case TYPE(c.path) {
	Qentdir =>	k = Scene->ENT;
	Qfeatdir =>	k = Scene->FEAT;
	Qlayerdir =>	k = Scene->LAYER;
	}
	if(k < 0 || tm.perm & Sys->DMDIR) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		return;
	}
	if(!goodname(tm.name)) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ename));
		return;
	}
	lock();
	if(live.find(k, tm.name) == nil)
		change(scene->kindname(k) + " " + quotedl(tm.name :: nil));
	q := Qid(objpath(k, tm.name), 0, Sys->QTFILE);
	unlock();
	changed();
	c.open(tm.mode, q);
	wbufs = ref Wbuf(c.fid, array[0] of byte) :: wbufs;
	srv.reply(ref Rmsg.Create(tm.tag, q, srv.iounit()));
}

doremove(tm: ref Tmsg.Remove)
{
	c := srv.getfid(tm.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	t := TYPE(c.path);
	if(t < Qobj || t >= Qobj + 3) {
		dropwbuf(c.fid);
		if(t == Qevent)
			dropevq(c.fid);
		srv.delfid(c);
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		return;
	}
	lock();
	err := change("del " + scene->kindname(t - Qobj) + " " + quotedl(slotid(c.path) :: nil));
	unlock();
	changed();
	dropwbuf(c.fid);
	srv.delfid(c);
	if(err != nil)
		srv.reply(ref Rmsg.Error(tm.tag, err));
	else
		srv.reply(ref Rmsg.Remove(tm.tag));
}

# ── the scene and its changes ──────────────────────────────

# Apply one record to the scene and pass it to the changes readers.
# Called locked.
change(rec: string): string
{
	if(rec == "" || rec[0] == '#')
		return nil;
	ot := live.t;
	oh := live.hast;
	if((err := live.apply(rec)) != nil)
		return err;
	if(len rec >= 5 && rec[0:5] == "time ") {
		if(oh && live.t == ot)
			return nil;	# no news
	}
	record(rec);
	sgen++;
	return nil;
}

# Emit a change, stamped with the clock when that moved.
record(rec: string)
{
	s := "";
	if(len rec >= 5 && rec[0:5] == "time ")
		rec = "time " + fmt(live.t);
	else if(live.hast && (!hasrect || live.t != lastrect))
		s = "time " + fmt(live.t) + "\n";
	if(live.hast) {
		lastrect = live.t;
		hasrect = 1;
	}
	emit(array of byte (s + rec + "\n"));
}

emit(b: array of byte)
{
	for(l := chqs; l != nil; l = tl l) {
		q := hd l;
		if(q.lost)
			continue;
		if(q.n + len b > CHMAX) {
			q.lost = 1;
			q.buf = nil;
			q.n = 0;
			if(q.pending != nil) {
				srv.reply(ref Rmsg.Error(q.pending.tag, "changes lost: the reader fell behind"));
				q.pending = nil;
			}
			continue;
		}
		if(q.n + len b > len q.buf) {
			nb := array[2 * (q.n + len b)] of byte;
			nb[0:] = q.buf[0:q.n];
			q.buf = nb;
		}
		q.buf[q.n:] = b;
		q.n += len b;
		if(q.pending != nil) {
			srv.reply(chreply(q.pending, q));
			q.pending = nil;
		}
	}
}

# Up to count bytes of what the reader has yet to read.  A stream, not a
# file: the offset is ignored.
chreply(tm: ref Tmsg.Read, q: ref Chq): ref Rmsg
{
	n := q.n;
	if(n > tm.count)
		n = tm.count;
	d := array[n] of byte;
	d[0:] = q.buf[0:n];
	q.buf[0:] = q.buf[n:q.n];
	q.n -= n;
	return ref Rmsg.Read(tm.tag, d);
}

getchq(fid: int): ref Chq
{
	for(l := chqs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropchq(fid: int)
{
	nl: list of ref Chq;
	for(l := chqs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	chqs = nl;
}

cancelchq(tag: int)
{
	for(l := chqs; l != nil; l = tl l)
		if((q := hd l).pending != nil && q.pending.tag == tag)
			q.pending = nil;
}

# After a (batch of) change(s): tell the watchers.
changed()
{
	post("gen " + string sgen);
}

# ── ctl ────────────────────────────────────────────────────

ctl(line: string): string
{
	if(line == "")
		return nil;
	(n, toks) := sys->tokenize(line, " \t");
	verb := hd toks;
	args := tl toks;
	arg1 := "";
	if(args != nil)
		arg1 = hd args;
	camchange := 0;
	case verb {
	"center" =>
		if(n != 3)
			return "usage: center A B";
		lock();
		cam.ca = real arg1;
		cam.cb = real hd tl args;
		fitpending = 0;
		unlock();
		camchange = 1;
	"zoom" =>
		if(n != 2)
			return "usage: zoom Z";
		lock();
		cam.zoom = real arg1;
		fitpending = 0;
		unlock();
		camchange = 1;
	"fit" =>
		fitseq++;
		fitpending = fitseq;
		camchange = 1;
	"follow" =>
		if(n != 2)
			return "usage: follow ID";
		cam.follow = arg1;
		camchange = 1;
	"unfollow" =>
		cam.follow = nil;
		camchange = 1;
	"select" =>
		if(n != 2)
			return "usage: select ID";
		cam.sel = arg1;
		post("select " + arg1);
		camchange = 1;
	"deselect" =>
		cam.sel = nil;
		post("select -");
		camchange = 1;
	"clear" =>
		lock();
		change("clear");
		unlock();
	* =>
		return "unknown command: " + verb;
	}
	if(camchange)
		post("view " + viewtext());
	else
		post("gen " + string sgen);
	return nil;
}

# ── events ─────────────────────────────────────────────────

post(ev: string)
{
	for(l := evqs; l != nil; l = tl l) {
		q := hd l;
		if(q.pending != nil && q.q == nil) {
			q.pending.offset = big 0;	# events are a stream, not a file
			srv.reply(styxservers->readstr(q.pending, ev + "\n"));
			q.pending = nil;
			continue;
		}
		# coalesce: a newer gen/view replaces a queued one of its kind
		(nil, w) := sys->tokenize(ev, " ");
		kind := hd w;
		if(kind == "gen" || kind == "view") {
			nq: list of string;
			for(ql := q.q; ql != nil; ql = tl ql) {
				(nil, qw) := sys->tokenize(hd ql, " ");
				if(hd qw != kind)
					nq = hd ql :: nq;
				else
					q.n--;
			}
			q.q = revs(nq);
		}
		q.q = appends(q.q, ev);
		q.n++;
		while(q.n > EVMAX) {
			q.q = tl q.q;
			q.n--;
		}
	}
}

evreply(tm: ref Tmsg.Read, q: ref Evq): ref Rmsg
{
	ev := hd q.q;
	q.q = tl q.q;
	q.n--;
	tm.offset = big 0;
	return styxservers->readstr(tm, ev + "\n");
}

getevq(fid: int): ref Evq
{
	for(l := evqs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropevq(fid: int)
{
	nl: list of ref Evq;
	for(l := evqs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	evqs = nl;
}

cancelpending(tag: int)
{
	for(l := evqs; l != nil; l = tl l)
		if((q := hd l).pending != nil && q.pending.tag == tag)
			q.pending = nil;
}

# ── the namespace ──────────────────────────────────────────

TYPE(p: big): int
{
	return int (p & big 16rFF);
}

slotid(p: big): string
{
	k := TYPE(p) - Qobj;
	s := int (p >> 8);
	if(k < 0 || k >= 3 || s >= nslots[k])
		return nil;
	return slotids[k][s];
}

objpath(k: int, id: string): big
{
	h := strhash(id) % len slotlook[k];
	for(l := slotlook[k][h]; l != nil; l = tl l) {
		(sid, s) := hd l;
		if(sid == id)
			return (big s << 8) | big (Qobj + k);
	}
	if(nslots[k] == len slotids[k]) {
		na := array[2 * len slotids[k]] of string;
		na[0:] = slotids[k];
		slotids[k] = na;
	}
	s := nslots[k]++;
	slotids[k][s] = id;
	slotlook[k][h] = (id, s) :: slotlook[k][h];
	return (big s << 8) | big (Qobj + k);
}

dir(p: big, name: string, perm: int, length: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = name;
	d.uid = d.gid = user;
	d.qid = Qid(p, 0, Sys->QTFILE);
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	d.length = big length;
	return d;
}

# Called locked.
dirgen(p: big): ref Sys->Dir
{
	case TYPE(p) {
	Qroot =>	return dir(p, ".", Sys->DMDIR|8r775, 0);
	Qctl =>	return dir(p, "ctl", 8r222, 0);
	Qview =>	return dir(p, "view", 8r444, 0);
	Qstatus =>	return dir(p, "status", 8r444, 0);
	Qevent =>	return dir(p, "event", 8r444, 0);
	Qchanges =>	return dir(p, "changes", 8r444, 0);
	Qlog =>	return dir(p, "log", 8r222, 0);
	Qmeta =>	return dir(p, "meta", 8r664, len array of byte live.metatext());
	Qtime =>	return dir(p, "time", 8r664, 0);
	Qentdir =>	return dir(p, "entities", Sys->DMDIR|8r775, 0);
	Qfeatdir =>	return dir(p, "features", Sys->DMDIR|8r775, 0);
	Qlayerdir =>	return dir(p, "layers", Sys->DMDIR|8r775, 0);
	}
	t := TYPE(p);
	if(t >= Qobj && t < Qobj + 3) {
		id := slotid(p);
		o := live.find(t - Qobj, id);
		if(o == nil)
			return nil;
		return dir(p, id, 8r664, len array of byte o.text());
	}
	return nil;
}

rootents := array[] of {Qctl, Qview, Qstatus, Qevent, Qchanges, Qlog, Qmeta, Qtime,
	Qentdir, Qfeatdir, Qlayerdir};

# The entries of a directory.  Called locked.
entries(p: big): array of big
{
	case TYPE(p) {
	Qroot =>
		a := array[len rootents] of big;
		for(i := 0; i < len rootents; i++)
			a[i] = big rootents[i];
		return a;
	Qentdir or Qfeatdir or Qlayerdir =>
		k := TYPE(p) - Qentdir;
		objs := live.objs(k);
		a := array[len objs] of big;
		for(i := 0; i < len objs; i++)
			a[i] = objpath(k, objs[i].id);
		return a;
	}
	return nil;
}

navigator(c: chan of ref Navop)
{
	while((m := <-c) != nil) {
		lock();
		pick n := m {
		Stat =>
			d := dirgen(n.path);
			if(d == nil)
				n.reply <-= (nil, Styxservers->Enotfound);
			else
				n.reply <-= (d, nil);
		Walk =>
			n.reply <-= walk(n.path, n.name);
		Readdir =>
			a := entries(n.path);
			j := 0;
			for(i := 0; i < len a && j < n.offset + n.count; i++) {
				d := dirgen(a[i]);
				if(d == nil)
					continue;
				if(j++ >= n.offset)
					n.reply <-= (d, nil);
			}
			n.reply <-= (nil, nil);
		}
		unlock();
	}
}

walk(p: big, name: string): (ref Sys->Dir, string)
{
	t := TYPE(p);
	if(name == "..") {
		if(t >= Qobj && t < Qobj + 3)
			return (dirgen(big (Qentdir + t - Qobj)), nil);
		return (dirgen(big Qroot), nil);
	}
	case t {
	Qroot =>
		for(i := 0; i < len rootents; i++) {
			d := dirgen(big rootents[i]);
			if(d.name == name)
				return (d, nil);
		}
	Qentdir or Qfeatdir or Qlayerdir =>
		k := t - Qentdir;
		if(live.find(k, name) != nil)
			return (dirgen(objpath(k, name)), nil);
	* =>
		return (nil, Styxservers->Enotdir);
	}
	return (nil, Styxservers->Enotfound);
}

# ── helpers ────────────────────────────────────────────────

goodname(s: string): int
{
	if(s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '/' || s[i] < 16r20)
			return 0;
	return 1;
}

quotedl(l: list of string): string
{
	return str->quoted(l);
}

fmt(v: real): string
{
	if(v == real int v)
		return string int v;
	s := sys->sprint("%.9f", v);
	while(len s > 1 && s[len s - 1] == '0')
		s = s[0:len s - 1];
	if(s[len s - 1] == '.')
		s = s[0:len s - 1];
	return s;
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h * 31 + s[i]) & 16r7FFFFFF;
	return h;
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revs(l: list of string): list of string
{
	return rev(l);
}

appends(l: list of string, s: string): list of string
{
	return rev(s :: rev(l));
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

fatal(s: string)
{
	sys->fprint(stderr, "scenefs: %s\n", s);
	raise "fail:error";
}
