implement Styxservers;

#
# Copyright © 1999 Vita Nuova Limited.  All rights reserved.
# Revisions copyright © 2000-2003 Vita Nuova Holdings Limited.  All rights reserved.
#
#	Derived from Roger Peppe's Styxlib by Martin C. Atkins, 2001/2002 by
#	adding new helper functions, and then removing Dirgenmod and its helpers
#
#	Further modified by Roger Peppe to simplify the interface by
#	adding the Navigator/Navop channel interface and making other changes,
#	including using the Styx module
#
# converted to revised Styx at Vita Nuova
# further revised August/September 2002
#
# TO DO:
#	- directory reading interface revision?
#

include "sys.m";
	sys: Sys;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";

CHANHASHSIZE: con 256;	# a power of two; a connection may hold MAXFIDS fids
DIRREADSIZE: con Styx->STATFIXLEN+4*20;	# ``reasonable'' chunk for reading directories

debug := 0;

init(styxmod: Styx)
{
	sys = load Sys Sys->PATH;
	styx = styxmod;
}

traceset(d: int)
{
	debug = d;
}

Styxserver.new(fd: ref Sys->FD, t: ref Navigator, rootpath: big): (chan of ref Tmsg, ref Styxserver)
{
	tchan := chan of ref Tmsg;
	srv := ref Styxserver(fd, array[CHANHASHSIZE] of list of ref Fid, chan[1] of int, t, rootpath, 0, nil, 0);

	sync := chan of int;
	spawn tmsgreader(fd, srv, tchan, sync);
	<-sync;
	return (tchan, srv);
}

tmsgreader(fd: ref Sys->FD, srv: ref Styxserver, tchan: chan of ref Tmsg, sync: chan of int)
{
	if(debug)
		sys->pctl(Sys->NEWFD|Sys->NEWNS, fd.fd :: 2 :: nil);
	else
		sys->pctl(Sys->NEWFD|Sys->NEWNS, fd.fd :: nil);
	sync <-= 1;
	fd = sys->fildes(fd.fd);
	m: ref Tmsg;
	do {
		m = Tmsg.read(fd, srv.msize);
		if(debug && m != nil)
			sys->fprint(sys->fildes(2), "<- %s\n", m.text());
		tchan <-= m;
	} while(m != nil && tagof(m) != tagof(Tmsg.Readerror));
}

Fid.clone(oc: self ref Fid, c: ref Fid): ref Fid
{
	# c.fid not touched, other values copied from c
	c.path = oc.path;
	c.qtype = oc.qtype;
	c.isopen = oc.isopen;
	c.mode = oc.mode;
	c.doffset = oc.doffset;
	c.uname  = oc.uname;
	c.param = oc.param;
	c.data = oc.data;
	return c;
}

Fid.walk(c: self ref Fid, qid: Sys->Qid)
{
	c.path = qid.path;
	c.qtype = qid.qtype;
}

Fid.open(c: self ref Fid, mode: int, qid: Sys->Qid)
{
	c.isopen = 1;
	c.mode = mode;
	c.doffset = (0, 0);
	c.path = qid.path;
	c.qtype = qid.qtype;
}

Styxserver.error(srv: self ref Styxserver, m: ref Tmsg, msg: string)
{
	srv.reply(ref Rmsg.Error(m.tag, msg));
}

Styxserver.reply(srv: self ref Styxserver, m: ref Rmsg): int
{
	if(debug)
		sys->fprint(sys->fildes(2), "-> %s\n", m.text());
	if(srv.replychan != nil){
		srv.replychan <-= m;
		return 0;
	}
	return srv.replydirect(m);
}

Styxserver.replydirect(srv: self ref Styxserver, m: ref Rmsg): int
{
	# before a version is agreed nothing is answered but the Tversion
	# itself and what was refused
	if(srv.msize == 0 && tagof m != tagof Rmsg.Version && tagof m != tagof Rmsg.Error)
		m = ref Rmsg.Error(m.tag, "Tversion not seen");
	d := m.pack();
	if(srv.msize != 0 && len d > srv.msize){
		m = ref Rmsg.Error(m.tag, "Styx reply didn't fit");
		d = m.pack();
	}
	return sys->write(srv.fd, d, len d);
}

Styxserver.attach(srv: self ref Styxserver, m: ref Tmsg.Attach): ref Fid
{
	(d, err) := srv.t.stat(srv.rootpath);
	if(d == nil) {
		srv.reply(ref Rmsg.Error(m.tag, err));
		return nil;
	}
	if((d.qid.qtype & Sys->QTDIR) == 0) {
		srv.reply(ref Rmsg.Error(m.tag, Enotdir));
		return nil;
	}
	c := srv.newfid(m.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, srv.nofid()));
		return nil;
	}
	c.uname = m.uname;
	c.param = m.aname;
	c.path = d.qid.path;
	c.qtype = d.qid.qtype;
	srv.reply(ref Rmsg.Attach(m.tag, d.qid));
	return c;
}

# not one element of a path: empty, or with a slash or a NUL in it
badname(s: string): int
{
	if(s == nil)
		return 1;
	for(i := 0; i < len s; i++)
		if(s[i] == '/' || s[i] == 0)
			return 1;
	return 0;
}

# why newfid gave nil
Styxserver.nofid(srv: self ref Styxserver): string
{
	if(srv.msize == 0)
		return "Tversion not seen";
	if(srv.nfids >= MAXFIDS)
		return Enofids;
	return Einuse;
}

walk1(n: ref Navigator, c: ref Fid, name: string): (ref Sys->Dir, string)
{
	(d, err) := n.stat(c.path);
	if(d == nil)
		return (nil, err);
	if((d.qid.qtype & Sys->QTDIR) == 0)
		return (nil, Enotdir);
	if(!openok(c.uname, Styx->OEXEC, d.mode, d.uid, d.gid))
		return (nil, Eperm);
	(d, err) = n.walk(d.qid.path, name);
	if(d == nil)
		return (nil, err);
	return (d, nil);
}

Styxserver.walk(srv: self ref Styxserver, m: ref Tmsg.Walk): ref Fid
{
	c := srv.getfid(m.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, Ebadfid));
		return nil;
	}
	if(c.isopen) {
		srv.reply(ref Rmsg.Error(m.tag, Eopen));
		return nil;
	}
	if(m.newfid != m.fid){
		nc := srv.newfid(m.newfid);
		if(nc == nil){
			srv.reply(ref Rmsg.Error(m.tag, srv.nofid()));
			return nil;
		}
		c = c.clone(nc);
	}
	# a name is one element: with a slash in it, a navigator that makes
	# a path of its names was walked wherever the client said
	for(j := 0; j < len m.names; j++)
		if(badname(m.names[j])){
			if(m.newfid != m.fid)
				srv.delfid(c);
			srv.reply(ref Rmsg.Error(m.tag, Ename));
			return nil;
		}
	qids := array[len m.names] of Sys->Qid;
	oldpath := c.path;
	oldqtype := c.qtype;
	for(i := 0; i < len m.names; i++){
		(d, err) := walk1(srv.t, c, m.names[i]);
		if(d == nil){
			c.path = oldpath;	# restore c
			c.qtype = oldqtype;
			if(m.newfid != m.fid)
				srv.delfid(c);
			if(i == 0)
				srv.reply(ref Rmsg.Error(m.tag, err));
			else
				srv.reply(ref Rmsg.Walk(m.tag, qids[0:i]));
			return nil;
		}
		c.walk(d.qid);
		qids[i] = d.qid;
	}
	srv.reply(ref Rmsg.Walk(m.tag, qids));
	return c;
}

Styxserver.canopen(srv: self ref Styxserver, m: ref Tmsg.Open): (ref Fid, int, ref Sys->Dir, string)
{
	c := srv.getfid(m.fid);
	if(c == nil)
		return (nil, 0, nil, Ebadfid);
	if(c.isopen)
		return (nil, 0, nil, Eopen);
	(f, err) := srv.t.stat(c.path);
	if(f == nil)
		return (nil, 0, nil, err);
	mode := openmode(m.mode);
	if(mode == -1)
		return (nil, 0, nil, Ebadarg);
	if(mode != Sys->OREAD && f.qid.qtype & Sys->QTDIR)
		return (nil, 0, nil, Eperm);
	if(!openok(c.uname, m.mode, f.mode, f.uid, f.gid))
		return (nil, 0, nil, Eperm);
	if(m.mode & Sys->ORCLOSE) {
		(dir, nil) := srv.t.walk(c.path, "..");
		if(dir == nil || dir.qid.path == f.qid.path && dir.qid.qtype == f.qid.qtype ||	# can't remove root directory
		   !openok(c.uname, Sys->OWRITE, dir.mode, dir.uid, dir.gid))
			return (nil, 0, nil, Eperm);
		mode |= Sys->ORCLOSE;
	}
	return (c, mode, f, err);
}

Styxserver.open(srv: self ref Styxserver, m: ref Tmsg.Open): ref Fid
{
	(c, mode, f, err) := srv.canopen(m);
	if(c == nil){
		srv.reply(ref Rmsg.Error(m.tag, err));
		return nil;
	}
	c.open(mode, f.qid);
	srv.reply(ref Rmsg.Open(m.tag, f.qid, srv.iounit()));
	return c;
}

Styxserver.cancreate(srv: self ref Styxserver, m: ref Tmsg.Create): (ref Fid, int, ref Sys->Dir, string)
{
	c := srv.getfid(m.fid);
	if(c == nil)
		return (nil, 0, nil, Ebadfid);
	if(c.isopen)
		return (nil, 0, nil, Eopen);
	(d, err) := srv.t.stat(c.path);
	if(d == nil)
		return (nil, 0, nil, err);
	if((d.mode & Sys->DMDIR) == 0)
		return (nil, 0, nil, Enotdir);
	if(badname(m.name))
		return (nil, 0, nil, Ename);
	if(m.name == "." || m.name == "..")
		return (nil, 0, nil, Edot);
	if(!openok(c.uname, Sys->OWRITE, d.mode, d.uid, d.gid))
		return (nil, 0, nil, Eperm);
	if(srv.t.walk(d.qid.path, m.name).t0 != nil)
		return (nil, 0, nil, Eexists);
	if((mode := openmode(m.mode)) == -1)
		return (nil, 0, nil, Ebadarg);
	mode |= m.mode & Sys->ORCLOSE;		# can create, so directory known to be writable
	f := ref Sys->zerodir;
	if(m.perm & Sys->DMDIR){
		f.mode = m.perm & (~8r777 | (d.mode & 8r777));
		f.qid.qtype = Sys->QTDIR;
	}else{
		f.mode = m.perm & (~8r666 | (d.mode & 8r666));
		f.qid.qtype = Sys->QTFILE;
	}
	f.name = m.name;
	f.uid = c.uname;
	f.muid = c.uname;
	f.gid = d.gid;
	f.dtype = d.dtype;
	f.dev = d.dev;
	# caller must supply atime, mtime, qid.path
	return (c, mode, f, nil);
}

Styxserver.canread(srv: self ref Styxserver, m: ref Tmsg.Read): (ref Fid, string)
{
	c := srv.getfid(m.fid);
	if(c == nil)
		return (nil, Ebadfid);
	if(!c.isopen)
		return (nil, Enotopen);
	mode := c.mode & 3;
	if(mode != Sys->OREAD && mode != Sys->ORDWR)	# readable modes
		return (nil, Eaccess);
	if(m.count < 0 || m.count > srv.msize-Styx->IOHDRSZ)
		return (nil, Ecount);
	if(m.offset < big 0)
		return (nil, Eoffset);
	return (c, nil);
}

Styxserver.read(srv: self ref Styxserver, m: ref Tmsg.Read): ref Fid
{
	(c, err) := srv.canread(m);
	if(c == nil){
		srv.reply(ref Rmsg.Error(m.tag, err));
		return nil;
	}
	if((c.qtype & Sys->QTDIR) == 0) {
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
		return nil;
	}
	if(m.count <= 0){
		srv.reply(ref Rmsg.Read(m.tag, nil));
		return c;
	}
	# a directory's offsets are ints here: one past 2^31 was cut to an
	# int and compared, and the read answered with the directory's
	# first entries (or, cut to a positive, with a walk of all of it)
	if(m.offset > big 16r7fffffff){
		srv.reply(ref Rmsg.Read(m.tag, nil));
		return c;
	}
	want := int m.offset;
	count := m.count;
	a := array[count] of byte;
	(offset, index) := c.doffset;
	if(want != offset){	# rescan from the beginning
		offset = 0;
		index = 0;
	}
	p := 0;
Dread:
	while((d := srv.t.readdir(c.path, index, (count+DIRREADSIZE-1)/DIRREADSIZE)) != nil && (nd := len d) > 0){
		for(i := 0; i < nd; i++) {
			size := styx->packdirsize(*d[i]);
			offset += size;
			index++;
			if(offset < want)
				continue;
			if((count -= size) < 0){	# won't fit, save state for next time
				offset -= size;
				index--;
				break Dread;
			}
			de := styx->packdir(*d[i]);
			a[p:] = de;
			p += size;
		}
	}
	c.doffset = (offset, index);
	srv.reply(ref Rmsg.Read(m.tag, a[0:p]));
	return c;
}

Styxserver.canwrite(srv: self ref Styxserver, m: ref Tmsg.Write): (ref Fid, string)
{
	c := srv.getfid(m.fid);
	if(c == nil)
		return (nil, Ebadfid);
	if(!c.isopen)
		return (nil, Enotopen);
	if(c.qtype & Sys->QTDIR)
		return (nil, Eperm);
	mode := c.mode & 3;
	if(mode != Sys->OWRITE && mode != Sys->ORDWR)	# writable modes
		return (nil, Eaccess);
	if(m.offset < big 0)
		return (nil, Eoffset);
	# could check len m.data > iounit, but since we've got it now, it doesn't matter
	return (c, nil);
}

Styxserver.stat(srv: self ref Styxserver, m: ref Tmsg.Stat)
{
	c := srv.getfid(m.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, Ebadfid));
		return;
	}
	(d, err) := srv.t.stat(c.path);
	if(d == nil) {
		srv.reply(ref Rmsg.Error(m.tag, err));
		return;
	}
	srv.reply(ref Rmsg.Stat(m.tag, *d));
}

Styxserver.canremove(srv: self ref Styxserver, m: ref Tmsg.Remove): (ref Fid, big, string)
{
	c := srv.getfid(m.fid);
	if(c == nil)
		return (nil, big 0, Ebadfid);
	(dir, nil) := srv.t.walk(c.path, "..");	# this relies on .. working for non-directories
	if(dir == nil)
		return (nil, big 0, "can't find parent directory");
	if(dir.qid.path == c.path && dir.qid.qtype == c.qtype ||	# can't remove root directory
	   !openok(c.uname, Sys->OWRITE, dir.mode, dir.uid, dir.gid))
		return (nil, big 0, Eperm);
	return (c, dir.qid.path, nil);
}

Styxserver.remove(srv: self ref Styxserver, m: ref Tmsg.Remove): ref Fid
{
	c := srv.getfid(m.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, Ebadfid));
		return nil;
	}
	srv.delfid(c);			# Remove always clunks the fid
	srv.reply(ref Rmsg.Error(m.tag, Eperm));
	return c;	
}

Styxserver.clunk(srv: self ref Styxserver, m: ref Tmsg.Clunk): ref Fid
{
	c := srv.getfid(m.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(m.tag, Ebadfid));
		return nil;
	}
	srv.delfid(c);
	srv.reply(ref Rmsg.Clunk(m.tag));
	return c;
}

Styxserver.default(srv: self ref Styxserver, gm: ref Tmsg)
{
	if(gm == nil) {
		srv.t.c <-= nil;
		exit;
	}
	pick m := gm {
	Readerror =>
		srv.t.c <-= nil;
		exit;
	Version =>
		# srv.msize is set only by a Tversion that is taken: it was set
		# to the default first, so one refused for its size, or of a
		# version not known, left the connection as though agreed
		max := srv.msize;
		if(max <= 0)
			max = Styx->MAXRPC;
		(msize, version) := styx->compatible(m, max, Styx->VERSION);
		if(m.msize < 256 || msize < 256){
			srv.reply(ref Rmsg.Error(m.tag, "message size too small"));
			break;
		}
		if(version == "unknown"){
			srv.reply(ref Rmsg.Version(m.tag, msize, version));
			break;
		}
		srv.msize = msize;
		srv.reply(ref Rmsg.Version(m.tag, msize, version));
	Auth =>
		srv.reply(ref Rmsg.Error(m.tag, "authentication not required"));
	Flush =>
		srv.reply(ref Rmsg.Flush(m.tag));
	Walk =>
		srv.walk(m);
	Open =>
		srv.open(m);
	Create =>
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
	Read =>
		srv.read(m);
	Write =>
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
	Clunk =>
		srv.clunk(m);
		# to delete on ORCLOSE:
		# c := srv.clunk(m);
		# if(c != nil && c.mode & Sys->ORCLOSE)
		# 	srv.doremove(c);
	Stat =>
		srv.stat(m);
	Remove =>
		srv.remove(m);
	Wstat =>
		srv.reply(ref Rmsg.Error(m.tag, Eperm));
	Attach =>
		srv.attach(m);
	* =>
		sys->fprint(sys->fildes(2), "styxservers: unhandled Tmsg tag %d - should not happen\n", tagof gm);
		raise "fail: unhandled case";
	}
}

Styxserver.iounit(srv: self ref Styxserver): int
{
	n := srv.msize - Styx->IOHDRSZ;
	if(n <= 0)
		return 0;	# unknown
	return n;
}

Styxserver.getfid(srv: self ref Styxserver, fid: int): ref Fid
{
	# the list is safe to use without locking
	for(l := srv.fids[fid & (CHANHASHSIZE-1)]; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

Styxserver.delfid(srv: self ref Styxserver, c: ref Fid)
{
	slot := c.fid & (CHANHASHSIZE-1);
	nl: list of ref Fid;
	srv.fidlock <-= 1;
	for(l := srv.fids[slot]; l != nil; l = tl l)
		if((hd l).fid != c.fid)
			nl = (hd l) :: nl;
		else
			srv.nfids--;
	srv.fids[slot] = nl;
	<-srv.fidlock;
}

Styxserver.allfids(srv: self ref Styxserver): list of ref Fid
{
	cl: list of ref Fid;
	srv.fidlock <-= 1;
	for(i := 0; i < len srv.fids; i++)
		for(l := srv.fids[i]; l != nil; l = tl l)
			cl = hd l :: cl;
	<-srv.fidlock;
	return cl;
}

Styxserver.newfid(srv: self ref Styxserver, fid: int): ref Fid
{
	srv.fidlock <-= 1;
	if((c := srv.getfid(fid)) != nil){
		<-srv.fidlock;
		return nil;		# illegal: fid in use
	}
	# No fid before a version is agreed: the request that asked for one
	# was answered "Tversion not seen" with its fid made all the same,
	# and "in use" ever after.  And no more than MAXFIDS: nothing
	# counted them, and a walk of no names makes one for 17 bytes.
	if(srv.msize == 0 || srv.nfids >= MAXFIDS){
		<-srv.fidlock;
		return nil;
	}
	srv.nfids++;
	c = ref Fid;
	c.path = big -1;
	c.qtype = 0;
	c.isopen = 0;
	c.mode = 0;
	c.fid = fid;
	c.doffset = (0, 0);
	slot := fid & (CHANHASHSIZE-1);
	srv.fids[slot] = c :: srv.fids[slot];
	<-srv.fidlock;
	return c;
}

readstr(m: ref Tmsg.Read, d: string): ref Rmsg.Read
{
	return readbytes(m, array of byte d);
}

readbytes(m: ref Tmsg.Read, d: array of byte): ref Rmsg.Read
{
	r := ref Rmsg.Read(m.tag, nil);
	# the count is the client's: negative (ff ff ff ff), or so large that
	# offset+count wrapped, d[offset:e] was an exception in the server,
	# which not every server calls canread to prevent
	if(m.count <= 0 || m.offset >= big len d || m.offset < big 0)
		return r;
	offset := int m.offset;
	n := len d - offset;
	if(m.count < n)
		n = m.count;
	r.data = d[offset:offset+n];
	return r;
}

Navigator.new(c: chan of ref Navop): ref Navigator
{
	return ref Navigator(c, chan of (ref Sys->Dir, string));
}

Navigator.stat(t: self ref Navigator, q: big): (ref Sys->Dir, string)
{
	t.c <-= ref Navop.Stat(t.reply, q);
	return <-t.reply;
}

Navigator.walk(t: self ref Navigator, q: big, name: string): (ref Sys->Dir, string)
{
	t.c <-= ref Navop.Walk(t.reply, q, name);
	return <-t.reply;
}

Navigator.readdir(t: self ref Navigator, q: big, offset, count: int): array of ref Sys->Dir
{
	a := array[count] of ref Sys->Dir;
	t.c <-= ref Navop.Readdir(t.reply, q, offset, count);
	i := 0;
	while((d := (<-t.reply).t0) != nil)
		if(i < count)
			a[i++] = d;
	if(i == 0)
		return nil;
	return a[0:i];
}

openmode(o: int): int
{
	OTRUNC, ORCLOSE, OREAD, ORDWR: import Sys;
	o &= ~(OTRUNC|ORCLOSE);
	if(o > ORDWR)
		return -1;
	return o;
}

access := array[] of {8r400, 8r200, 8r600, 8r100};
openok(uname: string, omode: int, perm: int, fuid: string, fgid: string): int
{
	t := access[omode & 3];
	if(omode & Sys->OTRUNC){
		if(perm & Sys->DMDIR)
			return 0;
		t |= 8r200;
	}
	if(uname == fuid && (t&perm) == t)
		return 1;
	if(uname == fgid && (t&(perm<<3)) == t)
		return 1;
	return (t&(perm<<6)) == t;
}	
