implement Charonfs;

#
# charonfs.b - a browsing session as files (see charonfs.m).
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;
include "web/dom.m";
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
include "web/page.m";
include "web/browser.m";
	browser: Browser;
	Session: import browser;
include "web/charonfs.m";

Qroot, Qctl, Qurl, Qtitle, Qstatus, Qtext, Qlinks, Qforms, Qfind, Qimage, Qevent,
Qdom, Qnode, Qtag, Qattrs, Qntext, Qstyle, Qbox, Qchildren: con iota;

rootfiles := array[] of {Qctl, Qurl, Qtitle, Qstatus, Qtext, Qlinks, Qforms, Qfind, Qimage, Qevent, Qdom};
nodefiles := array[] of {Qtag, Qattrs, Qntext, Qstyle, Qbox, Qchildren};

names := array[] of {
	"/", "ctl", "url", "title", "status", "text", "links", "forms", "find", "image", "event",
	"dom", "", "tag", "attrs", "text", "style", "box", "children",
};

# an open event file
Evq: adt {
	srv:	ref Styxserver;	# the connection it is open on
	fid:	int;
	lines:	list of string;	# reversed
	reads:	list of ref Tmsg.Read;	# waiting, reversed
};

sess: ref Session;
display: ref Display;
user: string;
query: string;	# the last thing written to find
evqs: list of ref Evq;

init(): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	if(styx == nil || styxservers == nil)
		return sys->sprint("cannot load modules: %r");
	styx->init();
	styxservers->init(styx);
	return nil;
}

serve(b: Browser, s: ref Session, d: ref Display, mountpt: string): string
{
	browser = b;
	sess = s;
	display = d;
	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";
	if(mountpt == nil)
		return nil;
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return sys->sprint("pipe: %r");
	serveconn(fds[0]);
	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL, nil) < 0)
		return sys->sprint("mount %s: %r", mountpt);
	return nil;
}

# Serve one 9P connection on fd.
serveconn(fd: ref Sys->FD)
{
	navops := chan of ref Navop;
	spawn navigator(navops);
	(tchan, srv) := Styxserver.new(fd, Navigator.new(navops), big Qroot);
	evc := sess.listen();
	pidc := chan of int;
	spawn serveloop(tchan, srv, evc, navops, pidc);
	<-pidc;
}

# ---- posting: /srv, Inferno style ----
#
# #s<spec> is one directory per spec (and user) across every name
# space, so a file posted in #scharon is where any process of this
# user can find the session, whatever its name space was built from:
#	mount -A '#scharon/fs' /mnt/charon
# Each open of the posted file is its own 9P connection.

post(spec: string): (string, string)
{
	if(sess == nil)
		return (nil, "not serving");
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
	posted(io, dir + "/" + name);
	return (name, nil);
}

postas(spec, name: string): string
{
	if(sess == nil)
		return "not serving";
	dir := "#s" + spec;
	(ok, nil) := sys->stat(dir + "/" + name);
	if(ok >= 0)
		return dir + "/" + name + ": already posted";
	io := sys->file2chan(dir, name);
	if(io == nil)
		return sys->sprint("file2chan: %r");
	posted(io, dir + "/" + name);
	return nil;
}

postpath: string;
unposted: chan of int;

posted(io: ref Sys->FileIO, path: string)
{
	postpath = path;
	unposted = chan[1] of int;
	spawn poster(io, unposted);
}

unpost()
{
	if(postpath == nil)
		return;
	sys->remove(postpath);
	postpath = nil;
	alt {
	unposted <-= 1 =>	;
	* =>	;
	}
}

Conn: adt {
	fid:	int;
	fd:	ref Sys->FD;	# our end of the connection's pipe
	rq:	chan of (int, Sys->Rread);
	wq:	chan of (array of byte, Sys->Rwrite);
};

poster(io: ref Sys->FileIO, quit: chan of int)
{
	conns: list of ref Conn;
	for(;;) alt {
	<-quit =>
		return;
	(nil, count, fid, rc) := <-io.read =>
		if(rc == nil) {
			conns = hangup(conns, fid);
			continue;
		}
		c: ref Conn;
		(conns, c) = conn(conns, fid);
		if(c == nil)
			rc <-= (nil, "cannot connect");
		else
			c.rq <-= (count, rc);
	(nil, data, fid, wc) := <-io.write =>
		if(wc == nil) {
			conns = hangup(conns, fid);
			continue;
		}
		c: ref Conn;
		(conns, c) = conn(conns, fid);
		if(c == nil)
			wc <-= (0, "cannot connect");
		else
			c.wq <-= (data, wc);
	}
}

conn(l: list of ref Conn, fid: int): (list of ref Conn, ref Conn)
{
	for(t := l; t != nil; t = tl t)
		if((hd t).fid == fid)
			return (l, hd t);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (l, nil);
	c := ref Conn(fid, fds[1], chan[4] of (int, Sys->Rread), chan[16] of (array of byte, Sys->Rwrite));
	serveconn(fds[0]);
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

path(n, t: int): big
{
	return big n << 8 | big t;
}

ftype(p: big): int
{
	return int (p & big 16rFF);
}

fnode(p: big): int
{
	return int (p >> 8);
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, evc: chan of string, navops: chan of ref Navop, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWFD, srv.fd.fd :: 2 :: nil);
Serve:
	for(;;) alt {
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		if(tagof gm == tagof Tmsg.Readerror)
			break Serve;
		{
			handle(srv, gm);
		} exception e {
		"*" =>
			srv.reply(ref Rmsg.Error(gm.tag, "internal error: " + e));
		}
	e := <-evc =>
		for(l := evqs; l != nil; l = tl l) {
			q := hd l;
			if(q.srv != srv)
				continue;
			q.lines = e :: q.lines;
			drain(srv, q);
		}
	}
	# the connection is gone: so are its event files
	r: list of ref Evq;
	for(l := evqs; l != nil; l = tl l)
		if((hd l).srv != srv)
			r = hd l :: r;
	evqs = r;
	sess.unlisten(evc);
	navops <-= nil;
}

handle(srv: ref Styxserver, gm: ref Tmsg)
{
	pick m := gm {
	Open =>
		f := srv.open(m);
		if(f == nil)
			break;
		t := ftype(f.path);
		if(t == Qevent)
			evqs = ref Evq(srv, f.fid, nil, nil) :: evqs;
		else if(t != Qctl && t != Qfind && (f.qtype & Sys->QTDIR) == 0)
			f.data = contents(t, fnode(f.path));
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
		case ftype(f.path) {
		Qevent =>
			q := findq(srv, f.fid);
			if(q == nil) {
				srv.reply(ref Rmsg.Error(m.tag, "event file not open"));
				break;
			}
			q.reads = m :: q.reads;
			drain(srv, q);
		Qctl =>
			srv.reply(styxservers->readbytes(m, nil));
		Qfind =>
			if(m.offset == big 0)
				f.data = array of byte sess.find(query);
			srv.reply(styxservers->readbytes(m, f.data));
		* =>
			srv.reply(styxservers->readbytes(m, f.data));
		}
	Write =>
		(f, err) := srv.canwrite(m);
		if(f == nil) {
			srv.reply(ref Rmsg.Error(m.tag, err));
			break;
		}
		s := string m.data;
		while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
			s = s[0:len s - 1];
		case ftype(f.path) {
		Qctl =>
			if((err = ctl(s)) != nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				return;
			}
		Qfind =>
			query = s;
		* =>
			srv.reply(ref Rmsg.Error(m.tag, Eperm));
			return;
		}
		srv.reply(ref Rmsg.Write(m.tag, len m.data));
	Flush =>
		for(l := evqs; l != nil; l = tl l) {
			q := hd l;
			if(q.srv != srv)
				continue;
			r: list of ref Tmsg.Read;
			for(rl := q.reads; rl != nil; rl = tl rl)
				if((hd rl).tag != m.oldtag)
					r = hd rl :: r;
			q.reads = nil;
			for(; r != nil; r = tl r)
				q.reads = hd r :: q.reads;
		}
		srv.default(gm);
	Clunk =>
		dropq(srv, m.fid);
		srv.clunk(m);
	Remove =>
		dropq(srv, m.fid);
		srv.remove(m);
	* =>
		srv.default(gm);
	}
}

findq(srv: ref Styxserver, fid: int): ref Evq
{
	for(l := evqs; l != nil; l = tl l)
		if((hd l).srv == srv && (hd l).fid == fid)
			return hd l;
	return nil;
}

dropq(srv: ref Styxserver, fid: int)
{
	r: list of ref Evq;
	for(l := evqs; l != nil; l = tl l)
		if((hd l).srv != srv || (hd l).fid != fid)
			r = hd l :: r;
	evqs = r;
}

# Answer waiting reads with waiting lines, oldest first.
drain(srv: ref Styxserver, q: ref Evq)
{
	if(q.reads == nil || q.lines == nil)
		return;
	reads: list of ref Tmsg.Read;
	for(r := q.reads; r != nil; r = tl r)
		reads = hd r :: reads;
	lines: list of string;
	for(l := q.lines; l != nil; l = tl l)
		lines = hd l :: lines;
	for(; reads != nil && lines != nil; reads = tl reads) {
		m := hd reads;
		b := array of byte (hd lines + "\n");
		lines = tl lines;
		if(len b > m.count)
			b = b[0:m.count];
		srv.reply(ref Rmsg.Read(m.tag, b));
	}
	q.reads = nil;
	for(; reads != nil; reads = tl reads)
		q.reads = hd reads :: q.reads;
	q.lines = nil;
	for(; lines != nil; lines = tl lines)
		q.lines = hd lines :: q.lines;
}

ctl(s: string): string
{
	(cmd, arg) := split(s);
	case cmd {
	"open" =>
		if(arg == "")
			return "usage: open <url>";
		sess.open(arg);
	"back" =>
		return sess.goback();
	"forward" =>
		return sess.goforward();
	"reload" =>
		sess.reload();
	"stop" =>
		sess.stop();
	"follow" =>
		return sess.follow(num(arg));
	"click" =>
		return sess.click(num(arg));
	"set" =>
		(n, v) := split(arg);
		return sess.set(num(n), v);
	"submit" =>
		(f, b) := split(arg);
		return sess.submit(num(f), num(b));
	"width" =>
		if(num(arg) <= 0)
			return "bad width";
		sess.resize(num(arg), sess.height);
	"size" =>
		(nil, l) := sys->tokenize(arg, "x ");
		if(len l != 2 || num(hd l) <= 0 || num(hd tl l) <= 0)
			return "usage: size <w>x<h>";
		sess.resize(num(hd l), num(hd tl l));
	"scroll" =>
		sess.scroll = num(arg);
	* =>
		return "unknown command " + cmd;
	}
	return nil;
}

contents(t, n: int): array of byte
{
	s := "";
	case t {
	Qurl =>
		s = sess.url + "\n";
	Qtitle =>
		s = sess.title + "\n";
	Qstatus =>
		s = sess.status + "\n";
	Qtext =>
		s = sess.text();
	Qlinks =>
		s = browser->linkstext(sess.links());
	Qforms =>
		s = browser->fieldstext(sess.fields());
	Qimage =>
		return image();
	Qtag or Qattrs or Qntext or Qstyle or Qbox or Qchildren =>
		(r, nil) := sess.dom(n, names[t]);
		s = r;
	}
	return array of byte s;
}

# the viewport as an image(6)
image(): array of byte
{
	if(sess.pg == nil || display == nil)
		return nil;
	img := display.newimage(Rect((0, 0), (sess.width, sess.height)), Draw->RGB24, 0, Draw->White);
	if(img == nil)
		return nil;
	sess.paint(img, Point(0, sess.scroll));
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return nil;
	c := chan of array of byte;
	spawn slurp(fds[1], c);
	display.writeimage(fds[0], img);
	fds[0] = nil;
	return <-c;
}

slurp(fd: ref Sys->FD, c: chan of array of byte)
{
	r := array[0] of byte;
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0) {
		nr := array[len r + n] of byte;
		nr[0:] = r;
		nr[len r:] = buf[0:n];
		r = nr;
	}
	c <-= r;
}

# ---- the tree ----

dir(p: big, name: string, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid.path = p;
	t := ftype(p);
	if(t == Qroot || t == Qdom || t == Qnode) {
		d.qid.qtype = Sys->QTDIR;
		perm |= Sys->DMDIR;
	}
	d.mode = perm;
	d.name = name;
	d.uid = d.gid = user;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	t := ftype(p);
	n := fnode(p);
	case t {
	Qroot or Qdom =>
		return (dir(p, names[t], 8r555), nil);
	Qnode =>
		if(!isnode(n))
			return (nil, Enotfound);
		return (dir(p, string n, 8r555), nil);
	Qctl =>
		return (dir(p, names[t], 8r222), nil);
	Qfind =>
		return (dir(p, names[t], 8r666), nil);
	}
	if(t < len names)
		return (dir(p, names[t], 8r444), nil);
	return (nil, Enotfound);
}

isnode(n: int): int
{
	pg := sess.pg;
	return pg != nil && n > 0 && n < pg.doc.n;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick o := m {
		Stat =>
			o.reply <-= dirgen(o.path);
		Walk =>
			t := ftype(o.path);
			if(o.name == "..") {
				case t {
				Qnode =>
					o.reply <-= dirgen(path(0, Qdom));
				* =>
					o.reply <-= dirgen(path(0, Qroot));
				}
				continue;
			}
			case t {
			Qroot =>
				for(i := 0; i < len rootfiles; i++)
					if(names[rootfiles[i]] == o.name)
						break;
				if(i < len rootfiles)
					o.reply <-= dirgen(path(0, rootfiles[i]));
				else
					o.reply <-= (nil, Enotfound);
			Qdom =>
				n := num(o.name);
				if(string n != o.name || !isnode(n))
					o.reply <-= (nil, Enotfound);
				else
					o.reply <-= dirgen(path(n, Qnode));
			Qnode =>
				for(i := 0; i < len nodefiles; i++)
					if(names[nodefiles[i]] == o.name)
						break;
				if(i < len nodefiles)
					o.reply <-= dirgen(path(fnode(o.path), nodefiles[i]));
				else
					o.reply <-= (nil, Enotfound);
			* =>
				o.reply <-= (nil, "not a directory");
			}
		Readdir =>
			t := ftype(o.path);
			case t {
			Qroot =>
				for(i := o.offset; i < len rootfiles && o.count > 0; i++) {
					o.reply <-= dirgen(path(0, rootfiles[i]));
					o.count--;
				}
			Qdom =>
				nn := 0;
				if(sess.pg != nil)
					nn = sess.pg.doc.n;
				for(i := o.offset + 1; i < nn && o.count > 0; i++) {
					o.reply <-= dirgen(path(i, Qnode));
					o.count--;
				}
			Qnode =>
				for(i := o.offset; i < len nodefiles && o.count > 0; i++) {
					o.reply <-= dirgen(path(fnode(o.path), nodefiles[i]));
					o.count--;
				}
			}
			o.reply <-= (nil, nil);
		}
	}
}

# ---- small things ----

split(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t') {
			j := i;
			while(j < len s && (s[j] == ' ' || s[j] == '\t'))
				j++;
			return (s[0:i], s[j:]);
		}
	return (s, "");
}

num(s: string): int
{
	n := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		n = n*10 + s[i] - '0';
	if(i == 0)
		return -1;
	return n;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}
