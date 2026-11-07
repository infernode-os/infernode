implement Appfs;

#
# appfs - a program's own files, served and posted (appfs.m).  Each
# connection made through the posting has its own Styxserver; reads and
# writes go to the program as Reqs; events are kept by one hub for all.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;

include "post9p.m";
	post9p: Post9p;
	Post: import post9p;

include "appfs.m";

names: array of string;		# the program's files, then event
reqc: chan of ref Req;
evops: chan of ref Evop;
user := "app";

init(): string
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	post9p = load Post9p Post9p->PATH;
	if(styx == nil || styxservers == nil || post9p == nil)
		return sys->sprint("appfs: cannot load: %r");
	styx->init();
	styxservers->init(styx);
	post9p->init();
	return nil;
}

serve(spec: string, files: array of string, reqs: chan of ref Req): (string, ref Sys->FD, string)
{
	names = array[len files + 1] of string;
	names[0:] = files;
	names[len files] = "event";
	reqc = reqs;
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (nil, nil, sys->sprint("appfs: pipe: %r"));
	c := chan of (string, string);
	spawn root(spec, fds[0], c);
	fds[0] = nil;
	(path, err) := <-c;
	if(path == nil)
		return (nil, nil, err);
	return (path, fds[1], nil);
}

# appfs's procs, in a group and fd table of their own: the program holds
# the tether's other end, and when it goes (or drops the tether) the read
# here ends, the posted file is taken away and the group killed.
root(spec: string, tether: ref Sys->FD, c: chan of (string, string))
{
	pid := sys->pctl(Sys->NEWPGRP|Sys->NEWFD, tether.fd :: 2 :: nil);
	evops = chan of ref Evop;
	spawn evhub();
	conns := chan of ref Sys->FD;
	(p, err) := post9p->post(spec, conns);
	if(p == nil) {
		c <-= (nil, err);
		return;
	}
	spawn connserver(conns);
	c <-= (p.path, nil);
	buf := array[1] of byte;
	while(sys->read(tether, buf, len buf) > 0)
		;
	p.unpost();
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

event(msg: string)
{
	if(evops != nil)
		evops <-= ref Evop.Post(msg);
}

connserver(conns: chan of ref Sys->FD)
{
	for(;;) {
		fd := <-conns;
		navops := chan of ref Navop;
		spawn navigator(navops);
		(tchan, srv) := Styxserver.new(fd, Navigator.new(navops), big 0);
		spawn serveloop(tchan, srv, navops);
	}
}

# qid 0 is the root, i+1 is names[i]
isevent(p: big): int
{
	return int p == len names;
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, navops: chan of ref Navop)
{
Serve:
	while((gm := <-tchan) != nil) {
		pick m := gm {
		Readerror =>
			break Serve;
		Open =>
			f := srv.open(m);
			if(f != nil) {
				f.data = nil;
				if(isevent(f.path))
					evops <-= ref Evop.Open(srv, m.fid);
			}
		Read =>
			(f, err) := srv.canread(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(f.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}
			if(isevent(f.path)) {
				evops <-= ref Evop.Read(srv, m);
				break;
			}
			if(f.data == nil || m.offset == big 0) {
				reply := chan of string;
				reqc <-= ref Req(names[int f.path - 1], nil, reply);
				f.data = array of byte <-reply;
			}
			srv.reply(styxservers->readbytes(m, f.data));
		Write =>
			(f, err) := srv.canwrite(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(isevent(f.path)) {
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
				break;
			}
			reply := chan of string;
			reqc <-= ref Req(names[int f.path - 1], string m.data, reply);
			if((e := <-reply) != nil)
				srv.reply(ref Rmsg.Error(m.tag, e));
			else
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Flush =>
			done := chan of int;
			evops <-= ref Evop.Flush(srv, m.oldtag, done);
			<-done;
			srv.default(gm);
		Clunk =>
			evops <-= ref Evop.Clunk(srv, m.fid);
			srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(int n.path);
		Walk =>
			if(n.path != big 0) {
				n.reply <-= (nil, "not a directory");
				continue;
			}
			if(n.name == "..") {
				n.reply <-= dirgen(0);
				continue;
			}
			for(i := 0; i < len names; i++)
				if(names[i] == n.name)
					break;
			if(i < len names)
				n.reply <-= dirgen(i + 1);
			else
				n.reply <-= (nil, Styxservers->Enotfound);
		Readdir =>
			if(n.path == big 0)
				for(i := n.offset; i < len names && i < n.offset + n.count; i++)
					n.reply <-= dirgen(i + 1);
			n.reply <-= (nil, nil);
		}
	}
}

dirgen(q: int): (ref Sys->Dir, string)
{
	d := ref sys->zerodir;
	d.qid.path = big q;
	d.uid = d.gid = user;
	if(q == 0) {
		d.name = ".";
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR | 8r555;
		return (d, nil);
	}
	if(q > len names)
		return (nil, Styxservers->Enotfound);
	d.name = names[q - 1];
	if(q == len names)
		d.mode = 8r444;
	else
		d.mode = 8r666;
	return (d, nil);
}

#
# event: one line an event, a read waiting for the next; a queue per
# open, kept by one proc for every connection; a stream at any offset.
#
Evop: adt {
	pick {
	Open =>
		srv:	ref Styxserver;
		fid:	int;
	Read =>
		srv:	ref Styxserver;
		m:	ref Tmsg.Read;
	Flush =>
		srv:	ref Styxserver;
		tag:	int;
		done:	chan of int;
	Clunk =>
		srv:	ref Styxserver;
		fid:	int;
	Post =>
		msg:	string;
	}
};

Evq: adt {
	srv:	ref Styxserver;
	fid:	int;
	q:	list of string;
	rd:	ref Tmsg.Read;
};

evhub()
{
	qs: list of ref Evq;
	for(;;) {
		op := <-evops;
		pick o := op {
		Open =>
			qs = ref Evq(o.srv, o.fid, nil, nil) :: qs;
		Read =>
			for(l := qs; l != nil; l = tl l)
				if((hd l).srv == o.srv && (hd l).fid == o.m.fid) {
					(hd l).rd = o.m;
					evreply(hd l);
				}
		Flush =>
			for(l := qs; l != nil; l = tl l)
				if((hd l).srv == o.srv && (hd l).rd != nil && (hd l).rd.tag == o.tag)
					(hd l).rd = nil;
			o.done <-= 1;
		Clunk =>
			nl: list of ref Evq;
			for(l := qs; l != nil; l = tl l)
				if((hd l).srv != o.srv || (hd l).fid != o.fid)
					nl = hd l :: nl;
			qs = nl;
		Post =>
			# a line already waiting to be read is not queued again:
			# a reader slow to come back gets each kind of change once
			for(l := qs; l != nil; l = tl l) {
				if(!member(o.msg, (hd l).q))
					(hd l).q = appendstr((hd l).q, o.msg);
				evreply(hd l);
			}
		}
	}
}

evreply(e: ref Evq)
{
	if(e.rd == nil || e.q == nil)
		return;
	b := array of byte (hd e.q + "\n");
	e.q = tl e.q;
	if(len b > e.rd.count)
		b = b[0:e.rd.count];
	e.srv.reply(ref Rmsg.Read(e.rd.tag, b));
	e.rd = nil;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

appendstr(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: appendstr(tl l, s);
}
