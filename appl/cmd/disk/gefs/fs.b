#
# gefs: the 9P server, as 9front's fs.c and ctl.c.
#
# 9front hands a connection's messages to reader procs, a mutator, an
# admin proc and a sweeper; here one loop serves them in turn
# (serve(), in gefs.b), and the work 9front queues for its admin and
# sweeper procs -- a sync, a snapshot, clearing a file's blocks after a
# truncate or a remove -- is done straight after the request that asked
# for it, before the next is read.
#

Cron: adt {
	i:	int;
	cnt:	int;
	div:	big;
	last:	big;
	tag:	string;
	lbl:	array of string;
};

Mount: adt {
	name:	string;
	refs:	int;
	gen:	big;
	root:	ref Tree;
	flag:	int;
	dtab:	array of list of ref Dent;
	cron:	array of ref Cron;
};

Ndtab: con 1024;

# an open directory entry: the fid's view of a file, shared by fids
Dent: adt {
	d:	ref Xdir;
	k:	array of byte;	# its key: Kent pqid name
	up:	big;
	refs:	int;
	trunc:	int;
	gone:	int;
};

Fid: adt {
	fid:	int;
	mnt:	ref Mount;
	scan:	ref Scan;
	dent:	ref Dent;
	dir:	ref Dent;
	rclose:	int;
	qpath:	big;
	pqpath:	big;
	mode:	int;
	iounit:	int;
	uid:	int;
	duid:	int;
	dgid:	int;
	dmode:	int;
	permit:	int;
	fromdump: int;
	status:	array of byte;	# readstatus's text
};

# the work a request leaves for after it
AOnone, AOsnap, AOsync, AOhalt, AOclear, AOrclose, AOsetcfg, AOclrcfg: con iota;

Amsg: adt {
	op:	int;
	old, new: string;
	flag:	int;
	delete:	int;
	snap, key, val: string;
	mnt:	ref Mount;
	dent:	ref Dent;
	qpath:	big;
	off:	big;
	end:	big;
};

Nfidtab: con 1024;
fidtab := array[Nfidtab] of list of ref Fid;
iounit := Max9p;
versioned := 0;
authok := 0;
halting := 0;

# ---- trees ----

walk1(t: ref Tree, up: big, name: string): (int, Sys->Qid, big)
{
	k := array[Keymax] of byte;
	n := packdkey(k, 0, len k, up, name);
	kv := btlookup(t, k[0:n]);
	if(kv == nil)
		return (0, Sys->Qid(big 0, 0, 0), big 0);
	d := kv2dir(*kv);
	return (1, Sys->Qid(d.qpath, d.qvers, d.qtype), d.length);
}

touch(de: ref Dent): Msg
{
	de.d.qvers++;
	return Msg(Owstat, de.k, array[] of {byte 0});
}

upsert(mnt: ref Mount, m: array of Msg)
{
	if(!(mnt.flag & Lmut) || fs.rdonly)
		error(Erdonly);
	r := mnt.root;
	if(r.nlbl != 1 || r.nref != 0){
		r = updatesnap(r, mnt.name, mnt.flag);
		mnt.root = r;
	}
	btupsert(r, m);
}

# ---- sync: 9front's four passes, with a device flush at each barrier ----

sync(): int
{
	# pass 0: update the open snapshots, and pack what is to be synced
	for(ml := fs.mounts; ml != nil; ml = tl ml){
		mnt := hd ml;
		if(mnt.flag & Lmut)
			mnt.root = updatesnap(mnt.root, mnt.name, mnt.flag);
	}
	# the snap tree does not change from here
	dlsync();
	sdl := ref *fs.snapdl;
	ddl := ref *fs.dropdl;
	ok := sdl.head.addr == big -1 && ddl.head.addr == big -1;
	fs.snapdl.head = Zb();
	fs.snapdl.tail = Zb();
	fs.snapdl.ins = nil;
	fs.dropdl.head = Zb();
	fs.dropdl.tail = Zb();
	fs.dropdl.ins = nil;
	fs.qgen++;
	for(i := 0; i < fs.narena; i++){
		a := fs.arenas[i];
		# the log is in preallocated blocks: it is written out now
		logbarrier(a, fs.qgen);
		flushlog(a);
		packarena(a.h0.data, 0, a);
		packarena(a.h1.data, 0, a);
		finalize(a.h0);
		finalize(a.h1);
		fs.arenabp[i] = a.h0.bp;
	}
	packsb(fs.sb0.buf);
	packsb(fs.sb1.buf);
	finalize(fs.sb0);
	finalize(fs.sb1);
	fs.snap.dirty = 0;
	devflush();
	# pass 1: arena headers; a crash here leaves the footers good
	for(i = 0; i < fs.narena; i++)
		syncblk(fs.arenas[i].h0);
	fs.qgen++;
	devflush();
	# pass 2: the superblocks; with good headers, a crash is safe
	syncblk(fs.sb0);
	syncblk(fs.sb1);
	fs.qgen++;
	devflush();
	# pass 3: arena footers; a crash here leaves the headers good
	for(i = 0; i < fs.narena; i++)
		syncblk(fs.arenas[i].h1);
	devflush();
	# pass 4: the old snap tree's deadlist, now the commit is on disk
	freedl(ddl, 0);
	limbodl(sdl);
	quiesce();
	return ok;
}

# a sync that does the work 9front's admin proc does around it
syncfs()
{
	if(!fs.snap.dirty || fs.rdonly)
		return;
	oldhd := array[fs.narena] of Bptr;
	for(i := 0; i < fs.narena; i++){
		a := fs.arenas[i];
		oldhd[i] = Zb();
		# compress when the log has doubled
		if(a.nlog >= big 2*a.lastlogsz){
			oldhd[i] = a.loghd;
			compresslog(a);
		}
	}
	sync();
	for(i = 0; i < fs.narena; i++){
		nb: Bptr;
		for(bp := oldhd[i]; bp.addr != big -1; bp = nb){
			b := getblk(bp, 0);
			nb = b.logp;
			freeblk(nil, b);
		}
	}
	quiesce();
}

# all of it: syncing until no deadlists are left over
drainsync()
{
	for(n := 0; n < 4; n++){
		quiesce();
		if(sync())
			break;
	}
}

# ---- snapshots ----

snapfs(a: ref Amsg): ref Tree
{
	t: ref Tree;
	mnt: ref Mount;
	for(ml := fs.mounts; ml != nil; ml = tl ml){
		if((hd ml).name != a.old)
			continue;
		mnt = hd ml;
		t = mnt.root;
		if(mnt.flag & Lmut){
			t = updatesnap(t, mnt.name, mnt.flag);
			mnt.root = t;
		}
		break;
	}
	if(t == nil)
		(t, nil) = opensnap(a.old);
	if(t == nil)
		error(Eexist);
	if(a.delete){
		if(mnt != nil)
			error(Esnapu);
		if(delsnap(t, t.succ, a.old))
			return t;
		return nil;
	}
	(s, nil) := opensnap(a.new);
	if(s != nil)
		error(Esnapx);
	tagsnap(t, a.new, a.flag);
	return nil;
}

freetree(rb: Bptr, pred: big)
{
	b := getblk(rb, 0);
	if(b.ty == Tpivot)
		for(i := 0; i < b.nval; i++){
			kv := getval(b, i);
			freetree(unpackbp(kv.v, 0), pred);
			quiesce();
		}
	if(rb.gen > pred)
		freeblk(nil, b);
}

# the tree t's blocks back, as its last reference goes; its predecessor
# if that is left unreferenced too
sweeptree(t: ref Tree): ref Tree
{
	gen := t.base;
	if(t.pred != big -1)
		gen = t.pred;
	s := btnewscan(array[] of {byte Kdat});
	btenter(t, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		bp := unpackbp(kv.v, 0);
		if(bp.gen > gen)
			freebp(nil, bp);
	}
	btexit(s);
	quiesce();
	freetree(t.bp, gen);
	quiesce();
	if(gen != big -1){
		n := opentree(gen);
		if(n != nil && n.nlbl == 0 && n.nref == 0)
			return n;
	}
	return nil;
}

dosnap(a: ref Amsg)
{
	if(fs.rdonly){
		sys->fprint(sys->fildes(2), "gefs: snap on read only fs\n");
		return;
	}
	t := snapfs(a);
	quiesce();
	while(t != nil){
		sync();
		n := sweeptree(t);
		if(n == nil)
			break;
		t = n;
		ok := 0;
		if(n.nref == 0 && n.nlbl == 0)
			ok = delsnap(n, n.succ, nil);
		quiesce();
		if(!ok)
			break;
	}
}

# a file's blocks from off to end, gone: after a truncate or a remove
clearfile(am: ref Amsg)
{
	if(fs.rdonly){
		sys->fprint(sys->fildes(2), "gefs: clear on read only fs\n");
		return;
	}
	fs.snap.dirty = 1;
	nmax := Kvmax/Offksz;
	m: list of Msg;
	nm := 0;
	for(off := am.off; off < am.end; off += big Blksz){
		k := array[Offksz] of byte;
		p8(k, 0, Kdat);
		p64(k, 1, am.qpath);
		p64(k, 9, off);
		m = Msg(Oclearb, k, array[0] of byte) :: m;
		nm++;
		if(nm >= nmax || off + big Blksz >= am.end){
			upsert(am.mnt, l2a(m));
			quiesce();
			m = nil;
			nm = 0;
		}
	}
	if(am.dent != nil)
		am.dent.trunc--;
}

rclosefile(am: ref Amsg)
{
	if(fs.rdonly){
		sys->fprint(sys->fildes(2), "gefs: rclose on read only fs\n");
		return;
	}
	m := Msg(Odelete, am.dent.k, array[0] of byte) :: nil;
	if(am.dent.d.qtype & Sys->QTDIR){
		k := array[Upksz] of byte;
		packsuper(k, 0, am.qpath);
		m = Msg(Oclobber, k, array[0] of byte) :: m;
	}
	upsert(am.mnt, l2a(m));
	quiesce();
	clearfile(am);
}

setconf(op: int, snap, key, val: string)
{
	t := fs.snap;
	if(snap != nil){
		mnt := getmount(snap);
		t = mnt.root;
		if((mnt.flag & Lmut) == 0)
			error(Eperm);
	}
	ka := array of byte key;
	k := array[1+len ka] of byte;
	k[0] = byte Kconf;
	k[1:] = ka;
	m := Msg(op, k, array of byte val);
	if(op == Oinsert || btlookup(t, k) != nil)
		btupsert(t, array[] of {m});
	else
		sys->fprint(sys->fildes(2), "gefs: no key %s\n", key);
	fs.snap.dirty = 1;
	syncfs();
}

runamsg(a: ref Amsg)
{
	if(a == nil)
		return;
	case a.op {
	AOsync =>	syncfs();
	AOsnap =>	dosnap(a);
	AOclear =>	clearfile(a);
	AOrclose =>	rclosefile(a);
	AOsetcfg =>	setconf(Oinsert, a.snap, a.key, a.val);
	AOclrcfg =>	setconf(Odelete, a.snap, a.key, "");
	AOhalt =>	halting = 1;
	}
	quiesce();
}

# ---- mounts and entries ----

mountlookup(name: string): ref Mount
{
	for(ml := fs.mounts; ml != nil; ml = tl ml)
		if((hd ml).name == name){
			(hd ml).refs++;
			return hd ml;
		}
	return nil;
}

getmount(name: string): ref Mount
{
	if(name == "dump"){
		fs.snapmnt.refs++;
		return fs.snapmnt;
	}
	mnt := mountlookup(name);
	if(mnt != nil)
		return mnt;
	(t, flg) := opensnap(name);
	if(t == nil)
		error(Enosnap);
	mnt = ref Mount;
	mnt.refs = 1;
	mnt.name = name;
	mnt.flag = flg;
	mnt.root = t;
	mnt.gen = big 0;
	mnt.dtab = array[Ndtab] of list of ref Dent;
	loadautos(mnt);
	fs.mounts = mnt :: fs.mounts;
	return mnt;
}

clunkmount(mnt: ref Mount)
{
	if(mnt == nil || mnt == fs.snapmnt)
		return;
	if(--mnt.refs != 0)
		return;
	l: list of ref Mount;
	for(ml := fs.mounts; ml != nil; ml = tl ml)
		if(hd ml != mnt)
			l = hd ml :: l;
	fs.mounts = l;
}

dslot(qpath: big): int
{
	h := ihash(qpath) % Ndtab;
	if(h < 0)
		h = -h;
	return h;
}

getdent(mnt: ref Mount, pqid: big, d: ref Xdir): ref Dent
{
	if(mnt.dtab == nil)
		mnt.dtab = array[Ndtab] of list of ref Dent;
	h := dslot(d.qpath);
	for(l := mnt.dtab[h]; l != nil; l = tl l)
		if((hd l).d.qpath == d.qpath){
			(hd l).refs++;
			return hd l;
		}
	k := array[Maxent] of byte;
	n := packdkey(k, 0, len k, pqid, d.name);
	de := ref Dent(ref *d, k[0:n], pqid, 1, 0, 0);
	mnt.dtab[h] = de :: mnt.dtab[h];
	return de;
}

clunkdent(mnt: ref Mount, de: ref Dent)
{
	if(de == nil)
		return;
	if(de.d.qtype & Sys->QTAUTH)
		return;
	if(--de.refs != 0)
		return;
	if(mnt == nil || mnt.dtab == nil)
		return;
	h := dslot(de.d.qpath);
	l: list of ref Dent;
	for(dl := mnt.dtab[h]; dl != nil; dl = tl dl)
		if(hd dl != de)
			l = hd dl :: l;
	mnt.dtab[h] = l;
}

fslot(fid: int): int
{
	h := ihash(big fid) % Nfidtab;
	if(h < 0)
		h = -h;
	return h;
}

getfid(fid: int): ref Fid
{
	for(l := fidtab[fslot(fid)]; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dupfid(new: int, f: ref Fid): ref Fid
{
	if(getfid(new) != nil)
		return nil;
	n := ref *f;
	n.fid = new;
	n.mode = -1;
	n.scan = nil;
	n.status = nil;
	n.rclose = 0;
	fidtab[fslot(new)] = n :: fidtab[fslot(new)];
	if(n.mnt != nil)
		n.mnt.refs++;
	n.dent.refs++;
	n.dir.refs++;
	return n;
}

# out of the table; what an ORCLOSE leaves to be done, if anything
clunkfid(f: ref Fid): ref Amsg
{
	h := fslot(f.fid);
	l: list of ref Fid;
	for(fl := fidtab[h]; fl != nil; fl = tl fl)
		if(hd fl != f)
			l = hd fl :: l;
	fidtab[h] = l;
	f.scan = nil;
	a: ref Amsg;
	if(f.rclose && !f.dent.gone){
		f.dent.gone = 1;
		f.rclose = 0;
		f.dent.refs++;
		f.mnt.refs++;
		a = ref Amsg;
		a.op = AOrclose;
		a.mnt = f.mnt;
		a.qpath = f.qpath;
		a.off = big 0;
		a.end = f.dent.d.length;
		a.dent = f.dent;
	}
	clunkdent(f.mnt, f.dent);
	clunkdent(f.mnt, f.dir);
	clunkmount(f.mnt);
	return a;
}

# ---- permissions ----

ingroup(uid, gid: int): int
{
	u := uid2user(uid);
	g := uid2user(gid);
	if(u == nil || g == nil)
		return 0;
	if(u.id == g.id)
		return 1;
	for(i := 0; i < len g.memb; i++)
		if(u.id == g.memb[i])
			return 1;
	return 0;
}

groupleader(uid, gid: int): int
{
	g := uid2user(gid);
	if(g == nil)
		return 0;
	if(g.lead == 0){
		for(i := 0; i < len g.memb; i++)
			if(g.memb[i] == uid)
				return 1;
		return 0;
	}
	return uid == g.lead;
}

DMMOUNT: con 1<<28;
DMREAD:	con 4;
DMWRITE: con 2;
DMEXEC:	con 1;

mode2bits(req: int): int
{
	m := 0;
	case req & 16rf {
	Sys->OREAD =>	m = DMREAD;
	Sys->OWRITE =>	m = DMWRITE;
	Sys->ORDWR =>	m = DMREAD|DMWRITE;
	Styx->OEXEC =>	m = DMREAD|DMEXEC;
	}
	if(req & Sys->OTRUNC)
		m |= DMWRITE;
	return m;
}

fsaccess(f: ref Fid, fmode, fuid, fgid, m: int): int
{
	# uid none gets only other permissions
	if(f.permit)
		return 0;
	if(f.uid != noneid){
		if(f.uid == fuid)
			if((m & (fmode>>6)) == m)
				return 0;
		if(ingroup(f.uid, fgid))
			if((m & (fmode>>3)) == m)
				return 0;
	}
	if((m & fmode) == m){
		if((fmode & Sys->DMDIR) && m == DMEXEC)
			return 0;
		if(!ingroup(f.uid, nogroupid))
			return 0;
	}
	return -1;
}

okname(name: string): string
{
	if(name == nil || name == "." || name == "..")
		return Ename;
	if(len array of byte name > Maxname)
		return Elength;
	for(i := 0; i < len name; i++)
		if(name[i] < 16r20 || name[i] == '/')
			return Ename;
	return nil;
}

# ---- stat ----

xdir2dir(d: ref Xdir): Sys->Dir
{
	u := uid2user(d.uid);
	if(u == nil)
		u = uid2user(noneid);
	g := uid2user(d.gid);
	if(g == nil)
		g = uid2user(nogroupid);
	m := uid2user(d.muid);
	if(m == nil)
		m = uid2user(noneid);
	if(u == nil || g == nil || m == nil)
		error(Eperm);
	dir: Sys->Dir;
	dir.name = d.name;
	dir.uid = u.name;
	dir.gid = g.name;
	dir.muid = m.name;
	dir.qid = Sys->Qid(d.qpath, d.qvers, d.qtype);
	dir.mode = d.mode;
	dir.atime = int ((d.atime + Nsec/big 2) / Nsec);
	dir.mtime = int ((d.mtime + Nsec/big 2) / Nsec);
	dir.length = d.length;
	dir.dtype = 16rFFFF;
	dir.dev = ~0;
	return dir;
}

filldumpdir(): ref Xdir
{
	d := ref Xdir;
	d.name = "/";
	d.qpath = Qdump;
	d.qvers = int fs.nextgen;
	d.qtype = Sys->QTDIR;
	d.mode = Sys->DMDIR|8r555;
	d.uid = -1;
	d.gid = -1;
	d.muid = -1;
	return d;
}

# ---- the messages ----

reply(r: ref Rmsg)
{
	b := r.pack();
	if(sys->write(srvfd, b, len b) != len b)
		halting = 1;
}

nsec(): big
{
	return big daytime->now() * Nsec;
}

fsversion(m: ref Tmsg.Version)
{
	msize := Max9p + Styx->IOHDRSZ;
	v := m.version;
	for(i := 0; i < len v; i++)
		if(v[i] == '.'){
			v = v[0:i];
			break;
		}
	if(v == "9P2000"){
		if(m.msize < msize)
			msize = m.msize;
		versioned = 1;
		iounit = msize;
		reply(ref Rmsg.Version(m.tag, msize, "9P2000"));
	}else{
		versioned = 0;
		reply(ref Rmsg.Version(m.tag, msize, "unknown"));
	}
}

fsattach(m: ref Tmsg.Attach)
{
	aname := m.aname;
	if(aname != nil && aname[0] == '%')
		aname = aname[1:];
	if(aname == nil)
		aname = "main";
	mnt := getmount(aname);
	{
		n := m.uname;
		# to let people add themselves to the user file
		if(permissive && aname == "adm")
			n = "adm";
		u := name2user(n);
		if(u == nil)
			error(Enouser);
		uid := u.id;
		d: ref Xdir;
		if(m.aname == "dump"){
			if(uid == noneid)
				error(Eperm);
			d = filldumpdir();
		}else{
			k := array[Keymax] of byte;
			nk := packdkey(k, 0, len k, big -1, "");
			kv := btlookup(mnt.root, k[0:nk]);
			if(kv == nil)
				error(Enosnap);
			d = kv2dir(*kv);
		}
		de := getdent(mnt, big -1, d);
		f := ref Fid;
		f.fid = Styx->NOFID;
		f.mnt = mnt;
		f.qpath = d.qpath;
		f.pqpath = d.qpath;
		f.mode = -1;
		f.iounit = iounit;
		f.dent = de;
		f.dir = de;
		f.uid = uid;
		f.duid = d.uid;
		f.dgid = d.gid;
		f.dmode = d.mode;
		if(m.aname != nil && m.aname[0] == '%'){
			if(!permissive && !ingroup(uid, admid))
				error(Eperm);
			f.permit = 1;
		}
		if(aname == "dump")
			f.fromdump = 1;
		if(dupfid(m.fid, f) == nil)
			error(Efid);
		clunkdent(mnt, de);
		clunkmount(mnt);
		reply(ref Rmsg.Attach(m.tag, Sys->Qid(d.qpath, d.qvers, d.qtype)));
	} exception e {
	"gefs:*" =>
		clunkmount(mnt);
		raise e;
	}
}

findparent(t: ref Tree, up: big): (big, string)
{
	k := array[Upksz] of byte;
	packsuper(k, 0, up);
	kv := btlookup(t, k);
	if(kv == nil)
		error(Esrch);
	return unpackdkey(kv.v, 0, len kv.v);
}

dkey(up: big, name: string): array of byte
{
	k := array[Maxent] of byte;
	n := packdkey(k, 0, len k, up, name);
	return k[0:n];
}

fswalk(m: ref Tmsg.Walk)
{
	o := getfid(m.fid);
	if(o == nil)
		error(Enofid);
	if(o.mode != -1)
		error(Einuse);
	t := o.mnt.root;
	mnt := o.mnt;
	wmnt: ref Mount;
	up := o.pqpath;
	prev := o.qpath;
	d := ref *o.dent.d;
	duid := d.uid;
	dgid := d.gid;
	dmode := d.mode;
	qids := array[len m.names] of Sys->Qid;
	i: int;
	for(i = 0; i < len m.names; i++){
		name := m.names[i];
		if(len array of byte name > Maxname)
			error(Elength);
		if(fsaccess(o, d.mode, d.uid, d.gid, DMEXEC) != 0)
			break;
		if(name == ".."){
			if(up == big -1 && o.fromdump){
				mnt = fs.snapmnt;
				d = filldumpdir();
				prev = big -1;
				up = big -1;
				qids[i] = Sys->Qid(d.qpath, d.qvers, d.qtype);
				continue;
			}
			(prev, name) = findparent(t, up);
		}else if(d.qpath == Qdump){
			mnt = getmount(name);
			clunkmount(wmnt);
			name = "";
			prev = big -1;
			wmnt = mnt;
			t = mnt.root;
		}
		up = prev;
		duid = d.uid;
		dgid = d.gid;
		dmode = d.mode;
		kv := btlookup(t, dkey(prev, name));
		if(kv == nil)
			break;
		d = kv2dir(*kv);
		prev = d.qpath;
		qids[i] = Sys->Qid(d.qpath, d.qvers, d.qtype);
	}
	if(i == 0 && len m.names != 0){
		clunkmount(wmnt);
		error(Esrch);
	}
	f := o;
	if(m.fid != m.newfid && i == len m.names){
		f = dupfid(m.newfid, o);
		if(f == nil){
			clunkmount(wmnt);
			error(Efid);
		}
	}
	if(i > 0 && i == len m.names){
		dent := getdent(mnt, up, d);
		dir: ref Dent;
		if(up == big -1)
			dir = getdent(mnt, up, d);	# the root contains itself
		else{
			(upup, name) := findparent(t, up);
			kv := btlookup(t, dkey(upup, name));
			if(kv == nil)
				broke("missing parent");
			pd := kv2dir(*kv);
			dir = getdent(mnt, upup, pd);
		}
		clunkdent(f.mnt, f.dent);
		clunkdent(f.mnt, f.dir);
		if(mnt != f.mnt){
			clunkmount(f.mnt);
			mnt.refs++;
			f.mnt = mnt;
		}
		f.qpath = qids[i-1].path;
		f.pqpath = up;
		f.dent = dent;
		f.dir = dir;
		f.duid = duid;
		f.dgid = dgid;
		f.dmode = dmode;
	}
	clunkmount(wmnt);
	reply(ref Rmsg.Walk(m.tag, qids[0:i]));
}

fsstat(m: ref Tmsg.Stat)
{
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	if(f.dent.gone)
		error(Ephase);
	reply(ref Rmsg.Stat(m.tag, xdir2dir(f.dent.d)));
}

fswstat(m: ref Tmsg.Wstat): ref Amsg
{
	ao: ref Amsg;
	rename := 0;
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	de := f.dent;
	if(de.gone)
		error(Ephase);
	if((de.d.qtype & Sys->QTAUTH) || (de.d.qpath & Qmagic) != big 0)
		error(Emode);
	d := m.stat;
	t := f.mnt.root;
	n := ref *de.d;
	n.qvers++;
	opb := array[Kvmax] of byte;
	p := 1;
	nulldir := 1;
	op := 0;
	if(d.qid.path != ~big 0 || d.qid.vers != ~0 || (d.qid.qtype & 16rFF) != 16rFF || (d.dtype & 16rFFFF) != 16rFFFF || d.dev != ~0)
		error(Ewstatq);
	if(d.name != nil){
		nulldir = 0;
		if(len array of byte d.name > Maxname)
			error(Elength);
		if(d.name != de.d.name){
			rename = 1;
			if((e := okname(d.name)) != nil)
				error(e);
			(found, nil, nil) := walk1(t, de.up, d.name);
			if(found)
				error(Eexist);
			n.name = d.name;
		}
	}
	if(d.length != ~big 0){
		nulldir = 0;
		if(d.length < big 0 || (de.d.mode & Sys->DMDIR) != 0)
			error(Ewstatl);
		if(d.length != de.d.length){
			if(d.length < de.d.length){
				ao = ref Amsg;
				de.trunc++;
				de.refs++;
				f.mnt.refs++;
				ao.op = AOclear;
				ao.mnt = f.mnt;
				ao.qpath = f.qpath;
				ao.off = d.length;
				ao.end = de.d.length;
				ao.dent = de;
			}
			de.d.length = d.length;
			n.length = d.length;
			op |= Owsize;
			p = p64(opb, p, n.length);
		}
	}
	if(d.mode != ~0){
		nulldir = 0;
		if((d.mode ^ de.d.mode) & Sys->DMDIR)
			error(Ewstatd);
		if(d.mode & ~(Sys->DMDIR|Sys->DMAPPEND|Sys->DMEXCL|Sys->DMTMP|8r777))
			error(Ewstatb);
		if(d.mode != de.d.mode){
			n.mode = d.mode;
			n.qtype = (d.mode>>24) & 16rFF;
			op |= Owmode;
			p = p32(opb, p, n.mode);
		}
	}
	if(d.mtime != ~0){
		nulldir = 0;
		n.mtime = (big d.mtime & big 16rFFFFFFFF) * Nsec;
		if(n.mtime != de.d.mtime){
			op |= Owmtime;
			p = p64(opb, p, n.mtime);
		}
	}
	if(d.uid != nil){
		nulldir = 0;
		if(len d.uid > Maxuname)
			error(Elength);
		u := name2user(d.uid);
		if(u == nil)
			error(Enouser);
		n.uid = u.id;
		if(n.uid != de.d.uid){
			op |= Owuid;
			p = p32(opb, p, n.uid);
		}
	}
	if(d.gid != nil){
		nulldir = 0;
		if(len d.gid > Maxuname)
			error(Elength);
		u := name2user(d.gid);
		if(u == nil)
			error(Enogrp);
		n.gid = u.id;
		if(n.gid != de.d.gid){
			op |= Owgid;
			p = p32(opb, p, n.gid);
		}
	}
	if(d.muid != nil)
		error(Eperm);
	if(nulldir && !rename){
		# a wstat that changes nothing is a sync
		syncfs();
		reply(ref Rmsg.Wstat(m.tag));
		return nil;
	}
	op |= Owmuid;
	n.muid = f.uid;
	p = p32(opb, p, n.muid);

	if(rename)
		if(fsaccess(f, f.dmode, f.duid, f.dgid, DMWRITE) == -1)
			error(Eperm);
	if(op & Owsize)
		if(fsaccess(f, de.d.mode, de.d.uid, de.d.gid, DMWRITE) == -1)
			error(Eperm);
	if(op & (Owmode|Owmtime))
		if(!f.permit && f.uid != de.d.uid && !groupleader(f.uid, de.d.gid))
			error(Ewstato);
	if(op & Owuid)
		if(!f.permit)
			error(Ewstatu);
	if(op & Owgid)
		if(!f.permit
		&& !(f.uid == de.d.uid && ingroup(f.uid, n.gid))
		&& !(groupleader(f.uid, de.d.gid) && groupleader(f.uid, n.gid)))
			error(Ewstatg);

	mb: list of Msg;
	nk: array of byte;
	if(rename && !de.gone){
		mb = Msg(Oclobber, de.k, array[0] of byte) :: mb;
		x := dir2kv(f.pqpath, n);
		mb = Msg(Oinsert, x.k, x.v) :: mb;
		nk = x.k;
		if(de.d.qtype & Sys->QTDIR){
			uk := array[Upksz] of byte;
			packsuper(uk, 0, f.qpath);
			mb = Msg(Oinsert, uk, x.k) :: mb;
		}
		mb = touch(f.dir) :: mb;
	}else{
		opb[0] = byte op;
		mb = Msg(Owstat, de.k, opb[0:p]) :: mb;
	}
	upsert(f.mnt, l2a(mb));
	de.d = n;
	if(rename)
		de.k = dup(nk);
	reply(ref Rmsg.Wstat(m.tag));
	return ao;
}

fsclunk(m: ref Tmsg.Clunk): ref Amsg
{
	f := getfid(m.fid);
	if(f == nil){
		reply(ref Rmsg.Error(m.tag, Enofid));
		return nil;
	}
	a := clunkfid(f);
	reply(ref Rmsg.Clunk(m.tag));
	return a;
}

fscreate(m: ref Tmsg.Create)
{
	if((e := okname(m.name)) != nil)
		error(e);
	if(m.perm & (Sys->DMAUTH|DMMOUNT))
		error(Ebotch);
	if(m.perm & ~(Sys->DMDIR|Sys->DMAPPEND|Sys->DMEXCL|Sys->DMTMP|8r777))
		error(Ewstatb);
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	if(f.mode != -1)
		error(Einuse);
	de := f.dent;
	(found, nil, nil) := walk1(f.mnt.root, f.qpath, m.name);
	if(found)
		error(Eexist);
	if(fs.nextqid < big 0)	# reached Qdump, 1<<63: unsigned in the C
		error(Enoqid);
	if(de.gone)
		error(Ephase);
	if((de.d.mode & Sys->DMDIR) == 0)
		error(Ecdir);
	if(fsaccess(f, de.d.mode, de.d.uid, de.d.gid, DMWRITE) == -1)
		error(Eperm);
	duid := de.d.uid;
	dgid := de.d.gid;
	dmode := de.d.mode;

	d := ref Xdir;
	d.flag = big 0;
	d.qtype = 0;
	if(m.perm & Sys->DMDIR)
		d.qtype |= Sys->QTDIR;
	if(m.perm & Sys->DMAPPEND)
		d.qtype |= Sys->QTAPPEND;
	if(m.perm & Sys->DMEXCL)
		d.qtype |= Sys->QTEXCL;
	if(m.perm & Sys->DMTMP)
		d.qtype |= Sys->QTTMP;
	d.qpath = fs.nextqid++;
	d.qvers = 0;
	d.mode = m.perm;
	if(m.perm & Sys->DMDIR)
		d.mode &= ~8r777 | (de.d.mode & 8r777);
	else
		d.mode &= ~8r666 | (de.d.mode & 8r666);
	d.name = m.name;
	d.atime = nsec();
	d.mtime = d.atime;
	d.length = big 0;
	d.uid = f.uid;
	d.gid = dgid;
	d.muid = f.uid;

	mb: list of Msg;
	x := dir2kv(f.qpath, d);
	mb = Msg(Oinsert, x.k, x.v) :: mb;
	if(m.perm & Sys->DMDIR){
		uk := array[Upksz] of byte;
		packsuper(uk, 0, d.qpath);
		uv := array[Keymax] of byte;
		nv := packdkey(uv, 0, len uv, f.qpath, d.name);
		mb = Msg(Oinsert, uk, uv[0:nv]) :: mb;
	}
	mb = touch(f.dent) :: mb;
	upsert(f.mnt, l2a(mb));
	if(m.mode & Sys->ORCLOSE)
		f.rclose = 1;
	nde := getdent(f.mnt, f.qpath, d);
	clunkdent(f.mnt, f.dent);
	f.pqpath = f.qpath;
	f.qpath = d.qpath;
	f.dent = nde;
	f.duid = duid;
	f.dgid = dgid;
	f.dmode = dmode;
	f.mode = mode2bits(m.mode);
	reply(ref Rmsg.Create(m.tag, Sys->Qid(d.qpath, d.qvers, d.qtype), f.iounit));
}

candelete(f: ref Fid): string
{
	if(!(f.dent.d.qtype & Sys->QTDIR))
		return nil;
	pfx := array[Dpfxsz] of byte;
	packdpfx(pfx, 0, f.qpath);
	s := btnewscan(pfx);
	btenter(f.mnt.root, s);
	e: string;
	if(btnext(s) != nil)
		e = Enempty;
	btexit(s);
	return e;
}

fsremove(m: ref Tmsg.Remove): ref Amsg
{
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	t := f.mnt.root;
	# the fid goes whatever happens
	f.dent.refs++;
	f.mnt.refs++;
	ao := clunkfid(f);
	{
		if(fs.rdonly)
			error(Erdonly);
		if(!f.permit && (f.dent.d.qpath & Qmagic) != big 0)
			error(Eperm);
		if(f.dent.gone)
			error(Ephase);
		if(btlookup(t, f.dent.k) == nil)
			error(Ephase);
		if((e := candelete(f)) != nil)
			error(e);
		if(fsaccess(f, f.dmode, f.duid, f.dgid, DMWRITE) == -1)
			error(Eperm);
	} exception e {
	"gefs:*" =>
		clunkdent(f.mnt, f.dent);
		clunkmount(f.mnt);
		raise e;
	}
	ao = nil;
	mb := Msg(Odelete, f.dent.k, array[0] of byte) :: nil;
	if(f.dent.d.qtype & Sys->QTDIR){
		k := array[Upksz] of byte;
		packsuper(k, 0, f.qpath);
		mb = Msg(Oclobber, k, array[0] of byte) :: mb;
	}else{
		ao = ref Amsg;
		f.mnt.refs++;
		ao.op = AOclear;
		ao.mnt = f.mnt;
		ao.qpath = f.qpath;
		ao.off = big 0;
		ao.end = f.dent.d.length;
		ao.dent = nil;
	}
	mb = touch(f.dir) :: mb;
	upsert(f.mnt, l2a(mb));
	f.dent.gone = 1;
	clunkdent(f.mnt, f.dent);
	clunkmount(f.mnt);
	reply(ref Rmsg.Remove(m.tag));
	return ao;
}

fsopen(m: ref Tmsg.Open): ref Amsg
{
	ao: ref Amsg;
	mbits := mode2bits(m.mode);
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	if(f.dent.gone)
		error(Ephase);
	if((f.dent.d.qtype & Sys->QTEXCL) && f.dent.refs != 1)
		error(Elocked);
	if((f.dent.d.qtype & Sys->QTDIR) && (mbits & DMWRITE) != 0)
		error(Eperm);
	if(m.mode & Sys->ORCLOSE){
		if(fsaccess(f, f.dmode, f.duid, f.dgid, DMWRITE) == -1)
			error(Eperm);
		if((e := candelete(f)) != nil)
			error(e);
	}
	if(fsaccess(f, f.dent.d.mode, f.dent.d.uid, f.dent.d.gid, mbits) == -1)
		error(Eperm);
	qid := Sys->Qid(f.dent.d.qpath, f.dent.d.qvers, f.dent.d.qtype);
	if(f.mode != -1)
		error(Einuse);
	if((m.mode & Sys->OTRUNC) && !(f.dent.d.mode & Sys->DMAPPEND)){
		ao = ref Amsg;
		f.dent.trunc++;
		f.dent.refs++;
		f.mnt.refs++;
		ao.op = AOclear;
		ao.mnt = f.mnt;
		ao.qpath = f.qpath;
		ao.off = big 0;
		ao.end = f.dent.d.length;
		ao.dent = f.dent;
		f.dent.d.muid = f.uid;
		f.dent.d.qvers++;
		f.dent.d.length = big 0;
		b := array[1+8+4] of byte;
		b[0] = byte (Owsize|Owmuid);
		p64(b, 1, big 0);
		p32(b, 9, f.uid);
		upsert(f.mnt, array[] of {Msg(Owstat, f.dent.k, b)});
	}
	if(m.mode & Sys->ORCLOSE)
		f.rclose = 1;
	f.mode = mbits;
	reply(ref Rmsg.Open(m.tag, qid, f.iounit));
	return ao;
}

readsnap(m: ref Tmsg.Read, f: ref Fid): array of byte
{
	s := f.scan;
	if(s != nil && s.offset != big 0 && s.offset != m.offset)
		error(Edscan);
	if(s == nil || m.offset == big 0){
		s = btnewscan(array[] of {byte Klabel});
		f.scan = s;
	}
	if(s.donescan)
		return array[0] of byte;
	out: list of array of byte;
	n := m.count;
	d := filldumpdir();
	if(s.overflow){
		d.name = string s.kv.k[1:];
		d.qpath = g64(s.kv.v, 1);
		b := styx->packdir(xdir2dir(d));
		if(len b > n)
			return array[0] of byte;
		out = b :: out;
		n -= len b;
		s.overflow = 0;
	}
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		d.name = string kv.k[1:];
		d.qpath = g64(kv.v, 1);
		b := styx->packdir(xdir2dir(d));
		if(len b > n){
			s.overflow = 1;
			break;
		}
		out = b :: out;
		n -= len b;
	}
	btexit(s);
	return cat(out);
}

cat(l: list of array of byte): array of byte
{
	n := 0;
	for(x := l; x != nil; x = tl x)
		n += len hd x;
	r := array[n] of byte;
	for(; l != nil; l = tl l){
		n -= len hd l;
		r[n:] = hd l;
	}
	return r;
}

readdir(m: ref Tmsg.Read, f: ref Fid): array of byte
{
	s := f.scan;
	t := f.mnt.root;
	if(s != nil && s.offset != big 0 && s.offset != m.offset)
		error(Edscan);
	if(s == nil || m.offset == big 0){
		pfx := array[Dpfxsz] of byte;
		packdpfx(pfx, 0, f.qpath);
		s = btnewscan(pfx);
		f.scan = s;
	}
	if(s.donescan)
		return array[0] of byte;
	out: list of array of byte;
	n := m.count;
	if(s.overflow){
		# an iounit too small for a dir
		b := styx->packdir(xdir2dir(kv2dir(*s.kv)));
		if(len b > n)
			error(Ebotch);
		out = b :: out;
		n -= len b;
		s.overflow = 0;
	}
	btenter(t, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		b := styx->packdir(xdir2dir(kv2dir(*kv)));
		if(len b > n){
			s.overflow = 1;
			break;
		}
		out = b :: out;
		n -= len b;
	}
	btexit(s);
	return cat(out);
}

readb(t: ref Tree, f: ref Fid, d: array of byte, o, n, sz: big): int
{
	if(o >= sz)
		return 0;
	fb := o & ~big (Blksz-1);
	fo := int (o & big (Blksz-1));
	if(big fo + n > big Blksz)
		n = big (Blksz-fo);
	k := array[Offksz] of byte;
	p8(k, 0, Kdat);
	p64(k, 1, f.qpath);
	p64(k, 9, fb);
	kv := btlookup(t, k);
	if(kv == nil){
		for(i := 0; i < int n; i++)
			d[i] = byte 0;
		return int n;
	}
	b := getblk(unpackbp(kv.v, 0), GBraw);
	d[0:] = b.buf[fo:fo+int n];
	return int n;
}

readfile(m: ref Tmsg.Read, f: ref Fid): array of byte
{
	e := f.dent;
	if(m.offset > e.d.length)
		return array[0] of byte;
	c := big m.count;
	if(m.offset + c > e.d.length)
		c = e.d.length - m.offset;
	r := array[int c] of byte;
	o := m.offset;
	p := 0;
	t := f.mnt.root;
	while(c != big 0){
		n := readb(t, f, r[p:], o, c, e.d.length);
		if(n <= 0)
			break;
		p += n;
		o += big n;
		c -= big n;
	}
	return r[0:p];
}

fsread(m: ref Tmsg.Read)
{
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	if(f.dent.gone)
		error(Ephase);
	if(f.mode == -1)
		error(Eopen);
	if(m.offset < big 0)
		error(Eoffset);
	if(m.count > Max9p)
		error(Ebotch);
	data: array of byte;
	if(f.dent.d.qpath == Qdump)
		data = readsnap(m, f);
	else if(f.dent.d.qtype & Sys->QTDIR)
		data = readdir(m, f);
	else if(f.dent.d.qpath == Qstatus)
		data = readstatus(m, f);
	else
		data = readfile(m, f);
	reply(ref Rmsg.Read(m.tag, data));
}

writeb(f: ref Fid, s: array of byte, o, n, sz: big): (int, Msg, Bptr)
{
	fb := o & ~big (Blksz-1);
	fo := int (o & big (Blksz-1));
	k := array[Offksz] of byte;
	p8(k, 0, Kdat);
	p64(k, 1, f.qpath);
	p64(k, 9, fb);
	seq := 0;
	if(big fo + n >= big Blksz)
		seq = 1;
	r := f.mnt.root;
	b := newdblk(r, f.qpath, seq);
	t: ref Blk;
	{
		kv := btlookup(r, k);
		if(kv != nil){
			bp := unpackbp(kv.v, 0);
			if(fb < sz && (fo != 0 || n != big Blksz)){
				t = getblk(bp, GBraw);
				b.buf[0:] = t.buf;
			}
		}
		if(big fo + n > big Blksz)
			n = big (Blksz-fo);
		b.buf[fo:] = s[0:int n];
		if(t == nil){
			for(i := 0; i < fo; i++)
				b.buf[i] = byte 0;
			for(i = fo + int n; i < Blksz; i++)
				b.buf[i] = byte 0;
		}
		enqueue(b);
	} exception e {
	"gefs:*" =>
		freeblk(r, b);
		raise e;
	}
	v := array[Ptrsz] of byte;
	packbp(v, 0, b.bp);
	return (int n, Msg(Oinsert, k, v), b.bp);
}

fswrite(m: ref Tmsg.Write)
{
	f := getfid(m.fid);
	if(f == nil)
		error(Enofid);
	if(f.mode == -1)
		error(Eopen);
	if(m.offset < big 0)
		error(Eoffset);
	if((f.dent.d.qpath & Qmagic) != big 0){
		if(f.dent.d.qpath == Qctl)
			writectl(m, f);
		else
			error(Eperm);
		return;
	}
	if(fs.rdonly)
		error(Erdonly);
	if(!(f.mode & DMWRITE))
		error(Einuse);
	if(f.dent.gone)
		error(Ephase);
	w := 0;
	p := 0;
	o := m.offset;
	c := big len m.data;
	if(o < big 0 || o + c < big 0)	# o >= (1ULL<<63) - c, unsigned in the C
		error(Ewstatl);
	if(f.dent.d.mode & Sys->DMAPPEND)
		o = f.dent.d.length;
	t := f.mnt.root;
	kv: list of Msg;
	bps: list of Bptr;
	{
		while(c != big 0){
			(n, msg, bp) := writeb(f, m.data[p:], o, c, f.dent.d.length);
			kv = msg :: kv;
			bps = bp :: bps;
			w += n;
			p += n;
			o += big n;
			c -= big n;
		}
	} exception e {
	"gefs:*" =>
		if(!fs.rdonly)
			for(; bps != nil; bps = tl bps)
				freebp(t, hd bps);
		raise e;
	}
	sb := array[Wstatmax] of byte;
	op := 0;
	q := 1;
	if(o > f.dent.d.length){
		op |= Owsize;
		q = p64(sb, q, o);
		f.dent.d.length = o;
	}
	op |= Owmtime;
	f.dent.d.mtime = nsec();
	q = p64(sb, q, f.dent.d.mtime);
	op |= Owmuid;
	q = p32(sb, q, f.uid);
	sb[0] = byte op;
	kv = Msg(Owstat, f.dent.k, sb[0:q]) :: kv;
	upsert(f.mnt, l2a(kv));
	reply(ref Rmsg.Write(m.tag, w));
}

# ---- adm/ctl and adm/status ----

readstatus(m: ref Tmsg.Read, f: ref Fid): array of byte
{
	if(f.status == nil || m.offset == big 0){
		s := "gefs p9\n";
		s += df();
		s += showconf(fs.snap, "");
		for(l := labels(); l != nil; l = tl l){
			(name, flg) := hd l;
			if(flg & Lmut){
				{
					mnt := getmount(name);
					s += showconf(mnt.root, name);
					clunkmount(mnt);
				} exception {
				"gefs:*" =>
					;
				}
			}
		}
		for(l = labels(); l != nil; l = tl l){
			(name, flg) := hd l;
			if(flg & Lmut)
				s += sys->sprint("fork %q\n", name);
			else
				s += sys->sprint("snap %q\n", name);
		}
		f.status = array of byte s;
	}
	n := len f.status;
	o := int m.offset;
	if(o >= n)
		return array[0] of byte;
	e := o + m.count;
	if(e > n)
		e = n;
	return f.status[o:e];
}

df(): string
{
	units := array[] of {"B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"};
	size := big 0;
	used := big 0;
	for(i := 0; i < fs.narena; i++){
		size += fs.arenas[i].size;
		used += fs.arenas[i].used;
	}
	hsize := real size;
	hused := real used;
	us := 0;
	for(; us < len units-1 && hsize >= 500.0; us++)
		hsize /= 1024.0;
	uu := 0;
	for(; uu < len units-1 && hused >= 500.0; uu++)
		hused /= 1024.0;
	return sys->sprint("usage \t%.2f%%\t%.2f%s\t%.2f%s\n",
		100.0*real used/real size, hused, units[uu], hsize, units[us]);
}

showconf(t: ref Tree, name: string): string
{
	s := "";
	shown := 0;
	sc := btnewscan(array[] of {byte Kconf});
	btenter(t, sc);
	for(;;){
		kv := btnext(sc);
		if(kv == nil)
			break;
		s += sys->sprint("conf %q %q %q\n", name, string kv.k[1:], string kv.v);
		shown = 1;
	}
	btexit(sc);
	if(name == nil && !shown)
		s += "conf retain '' '60@m 24@h @d'\n";
	return s;
}

labels(): list of (string, int)
{
	l: list of (string, int);
	s := btnewscan(array[] of {byte Klabel});
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		l = (string kv.k[1:], g32(kv.v, 1+8)) :: l;
	}
	btexit(s);
	r: list of (string, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

writectl(m: ref Tmsg.Write, nil: ref Fid)
{
	if(m.offset != big 0)
		error(Ebotch);
	if(len m.data >= 256)
		error(Elength);
	(nsp, sp) := sys->tokenize(string m.data, " \t\r\n");
	if(nsp == 0)
		error(Ebadctl);
	a := ref Amsg;
	case nsp {
	1 =>
		case hd sp {
		"sync" =>
			a.op = AOsync;
		"halt" =>
			a.op = AOhalt;
		"check" =>
			if(!checkfs()){
				reply(ref Rmsg.Error(m.tag, Echeck));
				return;
			}
			a = nil;
		"users" =>
			mnt := getmount("adm");
			loadusers(mnt.root);
			clunkmount(mnt);
			a = nil;
		* =>
			error(Ebadctl);
		}
	2 =>
		case hd sp {
		"delsnap" =>
			a.op = AOsnap;
			a.delete = 1;
			a.old = hd tl sp;
		"usereserve" =>
			usereserve = int hd tl sp;
			a = nil;
		"debug" =>
			debug = int hd tl sp;
			a = nil;
		* =>
			error(Ebadctl);
		}
	* =>
		case hd sp {
		"retain" =>
			setretain(a, hd tl sp, tl tl sp);
		"snap" =>
			if(nsp != 3)
				error(Ebadctl);
			a.op = AOsnap;
			a.old = hd tl sp;
			a.new = hd tl tl sp;
		"fork" =>
			if(nsp != 3)
				error(Ebadctl);
			a.op = AOsnap;
			a.old = hd tl sp;
			a.new = hd tl tl sp;
			a.flag = Lmut;
		* =>
			error(Ebadctl);
		}
	}
	# the work, then the reply: the ctl write returns when it is done
	runamsg(a);
	reply(ref Rmsg.Write(m.tag, len m.data));
}

setretain(a: ref Amsg, snap: string, spec: list of string)
{
	a.key = "retain";
	if(snap != "-")
		a.snap = snap;
	if(len spec == 1 && hd spec == "default"){
		a.op = AOclrcfg;
		a.val = "";
		return;
	}
	a.op = AOsetcfg;
	a.val = "";
	if(len spec != 1 || hd spec != "none")
		for(; spec != nil; spec = tl spec)
			a.val += hd spec + " ";
}

# ---- automatic snapshots ----

loadautos(mnt: ref Mount)
{
	k := array of byte "_retain";
	k[0] = byte Kconf;
	s := "60@m 24@h @d";
	kv := btlookup(mnt.root, k);
	if(kv == nil)
		kv = btlookup(fs.snap, k);
	if(kv != nil)
		s = string kv.v;
	mnt.cron = array[3] of {
		ref Cron(0, 0, big 60, big 0, "minute", nil),
		ref Cron(0, 0, big 3600, big 0, "hour", nil),
		ref Cron(0, 0, big (24*3600), big 0, "day", nil),
	};
	p := 0;
	while(p < len s){
		cnt := -1;
		div := 1;
		op := -1;
		if(s[p] >= '0' && s[p] <= '9'){
			cnt = 0;
			while(p < len s && s[p] >= '0' && s[p] <= '9')
				cnt = cnt*10 + s[p++] - '0';
		}
		if(p >= len s || s[p++] != '@'){
			badsched(mnt, s);
			return;
		}
		if(p < len s && s[p] >= '0' && s[p] <= '9'){
			div = 0;
			while(p < len s && s[p] >= '0' && s[p] <= '9')
				div = div*10 + s[p++] - '0';
		}
		if(p < len s && (s[p] == 'm' || s[p] == 'h' || s[p] == 'd'))
			op = s[p++];
		while(p < len s && (s[p] == ' ' || s[p] == '\t'))
			p++;
		if(div <= 0){
			badsched(mnt, s);
			return;
		}
		i: int;
		for(i = 0; i < 3; i++)
			if(mnt.cron[i].tag[0] == op)
				break;
		if(i == 3){
			badsched(mnt, s);
			return;
		}
		c := cnt;
		if(c <= 0)
			c = 1;
		mnt.cron[i].cnt = cnt;
		mnt.cron[i].div = big div * mnt.cron[i].div;
		mnt.cron[i].lbl = array[c] of string;
	}
	for(i := 0; i < 3; i++)
		loadhist(mnt, mnt.cron[i]);
}

badsched(mnt: ref Mount, s: string)
{
	mnt.cron = array[3] of {
		ref Cron(0, 0, big 0, big 0, "minute", nil),
		ref Cron(0, 0, big 0, big 0, "hour", nil),
		ref Cron(0, 0, big 0, big 0, "day", nil),
	};
	sys->fprint(sys->fildes(2), "gefs: ignoring invalid snap schedule %q\n", s);
}

# snapshots already taken, trimmed to the count now configured
loadhist(mnt: ref Mount, c: ref Cron)
{
	pfx := array of byte ("_" + mnt.name + "@" + c.tag + ".");
	pfx[0] = byte Klabel;
	ns := len pfx - 1;
	i := 0;
	last: string;
	s := btnewscan(pfx);
	btenter(fs.snap, s);
	gone: list of string;
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		name := string kv.k[1:];
		last = name;
		if(c.cnt == 0){
			gone = name :: gone;
			continue;
		}
		if(c.lbl == nil)
			continue;
		if(c.lbl[i] != nil && c.cnt > 0)
			gone = c.lbl[i] :: gone;
		c.lbl[i] = name;
		if(c.cnt > 0)
			i = (i+1) % c.cnt;
		else
			i = 0;
	}
	btexit(s);
	for(; gone != nil; gone = tl gone)
		snapmsg(hd gone, nil);
	if(last != nil)
		c.last = parsetm(last[ns:]);
	c.i = i;
}

snapmsg(old, new: string)
{
	a := ref Amsg;
	a.op = AOsnap;
	a.old = old;
	if(new == nil)
		a.delete = 1;
	else
		a.new = new;
	pendamsg = a :: pendamsg;
}

pendamsg: list of ref Amsg;

# YYYY.MM.DD_hh:mm:ss, UTC, as seconds; 0 if not that
parsetm(s: string): big
{
	if(len s < 19)
		return big 0;
	(n, f) := sys->tokenize(s[0:19], "._:");
	if(n != 6)
		return big 0;
	tm := ref Daytime->Tm;
	tm.year = int hd f - 1900; f = tl f;
	tm.mon = int hd f - 1; f = tl f;
	tm.mday = int hd f; f = tl f;
	tm.hour = int hd f; f = tl f;
	tm.min = int hd f; f = tl f;
	tm.sec = int hd f;
	tm.zone = "GMT";
	tm.tzoff = 0;
	return big daytime->tm2epoch(tm);
}

fmttm(t: int): string
{
	tm := daytime->gmt(t);
	return sys->sprint("%.4d.%.2d.%.2d_%.2d:%.2d:%.2d",
		tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
}

cronsync(name: string, c: ref Cron, now: big)
{
	if(c.div == big 0 || c.cnt == 0)
		return;
	if(now/c.div == c.last/c.div)
		return;
	if(c.cnt > 0 && c.lbl[c.i] != nil)
		snapmsg(c.lbl[c.i], nil);
	lbl := sys->sprint("%s@%s.%s", name, c.tag, fmttm(int now));
	c.lbl[c.i] = lbl;
	if(c.cnt > 0)
		c.i = (c.i+1) % c.cnt;
	else
		c.i = 0;
	snapmsg(name, lbl);
	c.last = now;
}

# every five seconds: a sync, and the snapshots that are due
tick()
{
	if(fs.rdonly)
		return;
	a := ref Amsg;
	a.op = AOsync;
	runamsg(a);
	now := big daytime->now();
	for(ml := fs.mounts; ml != nil; ml = tl ml){
		mnt := hd ml;
		if(!(mnt.flag & Lmut) || mnt.cron == nil)
			continue;
		for(i := 0; i < len mnt.cron; i++)
			cronsync(mnt.name, mnt.cron[i], now);
	}
	runpending();
}

runpending()
{
	while(pendamsg != nil){
		l := pendamsg;
		pendamsg = nil;
		r: list of ref Amsg;
		for(; l != nil; l = tl l)
			r = hd l :: r;
		for(; r != nil; r = tl r){
			{
				runamsg(hd r);
			} exception e {
			"gefs:*" =>
				sys->fprint(sys->fildes(2), "gefs: %s\n", errmsg(e));
			}
		}
	}
}

# ---- one request ----

request(t: ref Tmsg)
{
	a: ref Amsg;
	{
		pick m := t {
		Version =>	fsversion(m);
		Auth =>	reply(ref Rmsg.Error(m.tag, Eauth));
		Flush =>	reply(ref Rmsg.Flush(m.tag));
		Clunk =>	a = fsclunk(m);
		Attach =>	fsattach(m);
		Walk =>	fswalk(m);
		Stat =>	fsstat(m);
		Wstat =>
			fs.snap.dirty = 1;
			a = fswstat(m);
		Create =>
			fs.snap.dirty = 1;
			fscreate(m);
		Write =>
			fs.snap.dirty = 1;
			fswrite(m);
		Remove =>
			fs.snap.dirty = 1;
			a = fsremove(m);
		Open =>
			if(m.mode & (Sys->OTRUNC|Sys->ORCLOSE))
				fs.snap.dirty = 1;
			a = fsopen(m);
		Read =>	fsread(m);
		* =>
			reply(ref Rmsg.Error(t.tag, "unknown message"));
		}
	} exception e {
	"gefs:*" =>
		reply(ref Rmsg.Error(t.tag, errmsg(e)));
	}
	quiesce();
	{
		runamsg(a);
		runpending();
	} exception e {
	"gefs:*" =>
		sys->fprint(sys->fildes(2), "gefs: %s\n", errmsg(e));
	}
}
