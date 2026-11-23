implement Post9p;

#
# post9p - a 9P server posted in #s (post9p(2)).  The posted file is a
# file2chan; each client of it (each fid) gets a pipe whose other end
# is handed to the poster to serve, and its reads and writes are
# relayed through the pipe.
#

include "sys.m";
	sys: Sys;

include "post9p.m";

init()
{
	sys = load Sys Sys->PATH;
}

# #s with no spec is a directory of the caller's own, made anew at each
# attach: a file posted there can be reached by nobody
Enospec: con "no spec: nobody could reach it";

post(spec: string, conns: chan of ref Sys->FD): (ref Post, string)
{
	if(spec == nil)
		return (nil, Enospec);
	dir := "#s" + spec;
	name := "fs";
	io: ref Sys->FileIO;
	for(i := 1; i < 32; i++) {
		(ok, nil) := sys->stat(dir + "/" + name);
		if(ok < 0 && (io = sys->file2chan(dir, name)) != nil)
			break;
		name = "fs." + string i;
	}
	if(io == nil)
		return (nil, sys->sprint("file2chan: %r"));
	return (posted(io, dir + "/" + name, conns), nil);
}

postas(spec, name: string, conns: chan of ref Sys->FD): (ref Post, string)
{
	if(spec == nil)
		return (nil, Enospec);
	dir := "#s" + spec;
	(ok, nil) := sys->stat(dir + "/" + name);
	if(ok >= 0)
		return (nil, dir + "/" + name + ": already posted");
	io := sys->file2chan(dir, name);
	if(io == nil)
		return (nil, sys->sprint("file2chan: %r"));
	return (posted(io, dir + "/" + name, conns), nil);
}

posted(io: ref Sys->FileIO, path: string, conns: chan of ref Sys->FD): ref Post
{
	p := ref Post(path, chan[1] of int);
	spawn poster(io, conns, p.quit);
	return p;
}

Post.unpost(p: self ref Post)
{
	if(p.path == nil)
		return;
	sys->remove(p.path);
	p.path = nil;
	alt {
	p.quit <-= 1 =>	;
	* =>	;
	}
}

#
# The poster's loop takes every request for the posted file, for every
# connection, and must never wait for one of them.  It used to hand each
# request to its connection's reader or writer through a small buffered
# channel: a client with more reads outstanding on one descriptor than
# the buffer held (five; the reader was in its first, on a pipe with
# nothing to read) stopped the loop in that send, and with it every
# other connection of the post and every new mount, for good: the
# close that would have cleared it arrives on the same loop.  The same
# for writes once a server stopped reading its pipe.
#
# Now the loop keeps each connection's waiting requests itself and gives
# its reader and writer one at a time, when they say they are idle; a
# connection may have Maxpending waiting each way (export(2) allows a
# connection as many requests) and more are refused.  When a connection
# is closed its reader and writer are killed, wherever they are, so
# that its pipe closes and the server sees the end of it.
#
Maxpending: con 1024;

# A post has so many connections at once and no more: each is a pipe,
# two processes here and whatever its server keeps for it, and there
# was no end to them.  One more is refused in answer to its first
# request, so its client is told why.
Maxconns: con 256;
Etoomany: con "too many connections to this post";

Rd, Wr: con iota;

Readreq: adt {
	count:	int;
	rc:	Sys->Rread;
};

Writereq: adt {
	data:	array of byte;
	wc:	Sys->Rwrite;
};

Conn: adt {
	fid:	int;
	fd:	ref Sys->FD;	# our end of the connection's pipe
	dead:	int;
	rc:	chan of ref Readreq;	# to the reader, when it is idle
	wc:	chan of ref Writereq;	# to the writer, when it is idle
	rbusy:	int;
	wbusy:	int;
	rq:	list of ref Readreq;	# waiting, newest first
	wq:	list of ref Writereq;
	nrq:	int;
	nwq:	int;
	rpid:	int;
	wpid:	int;
};

poster(io: ref Sys->FileIO, conns: chan of ref Sys->FD, quit: chan of int)
{
	cl: list of ref Conn;
	idle := chan of (ref Conn, int);
	for(;;) alt {
	<-quit =>
		return;
	(c, which) := <-idle =>
		if(c.dead)
			continue;
		if(which == Rd){
			if(c.rq == nil)
				c.rbusy = 0;
			else{
				r: ref Readreq;
				(r, c.rq) = last(c.rq);
				c.nrq--;
				c.rc <-= r;
			}
		}else{
			if(c.wq == nil)
				c.wbusy = 0;
			else{
				w: ref Writereq;
				(w, c.wq) = last(c.wq);
				c.nwq--;
				c.wc <-= w;
			}
		}
	(nil, count, fid, rc) := <-io.read =>
		if(rc == nil) {
			cl = hangup(cl, fid);
			continue;
		}
		c: ref Conn;
		why: string;
		(cl, c, why) = conn(cl, fid, conns, idle);
		if(c == nil)
			rc <-= (nil, why);
		else if(!c.rbusy){
			c.rbusy = 1;
			c.rc <-= ref Readreq(count, rc);	# its reader is waiting for it
		}else if(c.nrq >= Maxpending)
			rc <-= (nil, "too many reads outstanding on one connection");
		else{
			c.rq = ref Readreq(count, rc) :: c.rq;
			c.nrq++;
		}
	(nil, data, fid, wc) := <-io.write =>
		if(wc == nil) {
			cl = hangup(cl, fid);
			continue;
		}
		c: ref Conn;
		why: string;
		(cl, c, why) = conn(cl, fid, conns, idle);
		if(c == nil)
			wc <-= (0, why);
		else if(!c.wbusy){
			c.wbusy = 1;
			c.wc <-= ref Writereq(data, wc);
		}else if(c.nwq >= Maxpending)
			wc <-= (0, "too many writes outstanding on one connection");
		else{
			c.wq = ref Writereq(data, wc) :: c.wq;
			c.nwq++;
		}
	}
}

# the oldest of a list kept newest first, and the rest
last[T](l: list of T): (T, list of T)
{
	r: list of T;
	for(; tl l != nil; l = tl l)
		r = hd l :: r;
	x := hd l;
	l = nil;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return (x, l);
}

conn(l: list of ref Conn, fid: int, conns: chan of ref Sys->FD, idle: chan of (ref Conn, int)): (list of ref Conn, ref Conn, string)
{
	n := 0;
	for(t := l; t != nil; t = tl t){
		if((hd t).fid == fid)
			return (l, hd t, nil);
		n++;
	}
	if(n >= Maxconns)
		return (l, nil, Etoomany);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (l, nil, sys->sprint("cannot connect: %r"));
	c := ref Conn;
	c.fid = fid;
	c.fd = fds[1];
	c.rc = chan[1] of ref Readreq;
	c.wc = chan[1] of ref Writereq;
	conns <-= fds[0];
	pidc := chan of int;
	spawn connreader(c, c.fd, idle, pidc);
	c.rpid = <-pidc;
	spawn connwriter(c, c.fd, idle, pidc);
	c.wpid = <-pidc;
	return (c :: l, c, nil);
}

hangup(l: list of ref Conn, fid: int): list of ref Conn
{
	r: list of ref Conn;
	for(; l != nil; l = tl l) {
		c := hd l;
		if(c.fid != fid) {
			r = c :: r;
			continue;
		}
		# its reader may be in a read with nothing to come, its
		# writer in a write nobody will take: neither can be
		# asked to stop, and while either lives the pipe is open
		c.dead = 1;
		kill(c.rpid);
		kill(c.wpid);
		c.fd = nil;	# the server sees end of file
		# whoever still waits (nobody, when the close was the
		# client's own) is not left waiting
		for(; c.rq != nil; c.rq = tl c.rq)
			(hd c.rq).rc <-= (nil, "connection closed");
		for(; c.wq != nil; c.wq = tl c.wq)
			(hd c.wq).wc <-= (0, "connection closed");
	}
	return r;
}

kill(pid: int)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

connreader(c: ref Conn, fd: ref Sys->FD, idle: chan of (ref Conn, int), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	# What the pipe gave for a read whose client had gone by then (it
	# was killed, or its request flushed) is the next read's: it is a
	# piece of the connection's 9P replies, and sent to the request
	# that had been given up it reached nobody, so the reader after it
	# waited for a reply that had been spent.  The kernel leaves word
	# on a given-up request's channel (sys-file2chan(2)).
	kept: array of byte;
	for(;;) {
		r := <-c.rc;
		alt {
		<-r.rc =>
			idle <-= (c, Rd);	# given up while it waited its turn
			continue;
		* =>
			;
		}
		buf: array of byte;
		err: string;
		if(kept != nil){
			n := len kept;
			if(n > r.count)
				n = r.count;
			buf = kept[0:n];
			if(n < len kept)
				kept = kept[n:];
			else
				kept = nil;
		}else{
			buf = array[r.count] of byte;
			n := sys->read(fd, buf, len buf);
			if(n < 0){
				err = sys->sprint("%r");
				buf = nil;
			}else
				buf = buf[0:n];
		}
		alt {
		<-r.rc =>
			if(err == nil && len buf > 0){
				if(kept != nil){	# what was cut from it comes after it
					b := array[len buf + len kept] of byte;
					b[0:] = buf;
					b[len buf:] = kept;
					buf = b;
				}
				kept = buf;
			}
		* =>
			r.rc <-= (buf, err);
		}
		idle <-= (c, Rd);
	}
}

connwriter(c: ref Conn, fd: ref Sys->FD, idle: chan of (ref Conn, int), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		w := <-c.wc;
		# a write given up while it waited its turn was refused to
		# its client: it is not then sent to the server
		alt {
		<-w.wc =>
			idle <-= (c, Wr);
			continue;
		* =>
			;
		}
		# a write on a pipe whose server has closed its end is an
		# exception: the writer went with it, the client's write
		# was never answered, nor any after it
		n := -1;
		err: string;
		{
			n = sys->write(fd, w.data, len w.data);
			if(n < 0)
				err = sys->sprint("%r");
		}exception e{
		"*" =>
			n = -1;
			err = e;
		}
		if(n < 0)
			w.wc <-= (0, err);
		else
			w.wc <-= (n, nil);
		idle <-= (c, Wr);
	}
}
