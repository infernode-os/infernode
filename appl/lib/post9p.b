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

post(spec: string, conns: chan of ref Sys->FD): (ref Post, string)
{
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

Conn: adt {
	fid:	int;
	fd:	ref Sys->FD;	# our end of the connection's pipe
	rq:	chan of (int, Sys->Rread);
	wq:	chan of (array of byte, Sys->Rwrite);
};

poster(io: ref Sys->FileIO, conns: chan of ref Sys->FD, quit: chan of int)
{
	cl: list of ref Conn;
	for(;;) alt {
	<-quit =>
		return;
	(nil, count, fid, rc) := <-io.read =>
		if(rc == nil) {
			cl = hangup(cl, fid);
			continue;
		}
		c: ref Conn;
		(cl, c) = conn(cl, fid, conns);
		if(c == nil)
			rc <-= (nil, "cannot connect");
		else
			c.rq <-= (count, rc);
	(nil, data, fid, wc) := <-io.write =>
		if(wc == nil) {
			cl = hangup(cl, fid);
			continue;
		}
		c: ref Conn;
		(cl, c) = conn(cl, fid, conns);
		if(c == nil)
			wc <-= (0, "cannot connect");
		else
			c.wq <-= (data, wc);
	}
}

conn(l: list of ref Conn, fid: int, conns: chan of ref Sys->FD): (list of ref Conn, ref Conn)
{
	for(t := l; t != nil; t = tl t)
		if((hd t).fid == fid)
			return (l, hd t);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (l, nil);
	c := ref Conn(fid, fds[1], chan[4] of (int, Sys->Rread), chan[16] of (array of byte, Sys->Rwrite));
	conns <-= fds[0];
	spawn connreader(c);
	spawn connwriter(c);
	return (c :: l, c);
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
		c.rq <-= (-1, nil);
		c.wq <-= (nil, nil);
	}
	return r;
}

connreader(c: ref Conn)
{
	for(;;) {
		(count, rc) := <-c.rq;
		if(rc == nil)
			return;
		buf := array[count] of byte;
		n := sys->read(c.fd, buf, len buf);
		if(n < 0)
			rc <-= (nil, sys->sprint("%r"));
		else
			rc <-= (buf[0:n], nil);
	}
}

connwriter(c: ref Conn)
{
	for(;;) {
		(data, wc) := <-c.wq;
		if(wc == nil) {
			c.fd = nil;	# the server sees end of file
			return;
		}
		n := sys->write(c.fd, data, len data);
		if(n < 0)
			wc <-= (0, sys->sprint("%r"));
		else
			wc <-= (n, nil);
	}
}
