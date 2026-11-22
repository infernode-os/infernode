#
# gefs: loading a file system, and making one: 9front's load.c and
# ream.c.
#

newarena(): ref Arena
{
	a := ref Arena;
	a.logbuf = array[2] of ref Blk;
	a.logbuf[0] = newblkbuf();
	a.logbuf[1] = newblkbuf();
	a.logbuf[0].flag = Bstatic;
	a.logbuf[1].flag = Bstatic;
	a.dsz = -1;
	a.dlogp = Zb();
	return a;
}

loadarena(a: ref Arena, head: Bptr)
{
	# the header or the footer: one is enough
	bp := head;
	h0 := getblk(bp, GBtry);
	bp.addr += big Blksz;
	h1 := getblk(bp, GBtry);
	b := h0;
	if(b == nil)
		b = h1;
	if(b == nil)
		error(Efs+": loadarena");
	if(h0 == nil || h1 == nil)
		sys->fprint(sys->fildes(2), "gefs: using fallback arena header %bux\n", b.bp.addr);
	# we could have crashed mid-pass: take the blocks as they are
	bp = head;
	if(h0 == nil)
		h0 = getblk(bp, GBnochk);
	bp.addr += big Blksz;
	if(h1 == nil)
		h1 = getblk(bp, GBnochk);
	logbuf := a.logbuf;
	unpackarena(a, b.data, 0);
	a.logbuf = logbuf;
	a.free = nil;
	a.h0 = h0;
	a.h1 = h1;
	a.used = a.size;
}

devsize(fd: ref Sys->FD): big
{
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		error(sys->sprint("stat: %r"));
	return d.length;
}

loadfs(dev: string)
{
	dump := ref Mount;
	dump.name = "dump";
	dump.refs = 1;
	dump.gen = big -1;
	dump.root = fs.snap;
	fs.snapmnt = dump;
	fs.narena = 1;
	fs.dropdl.head = Zb();
	fs.dropdl.tail = Zb();
	fs.fd = sys->open(dev, Sys->ORDWR);
	if(fs.fd == nil)
		error(sys->sprint("open %s: %r", dev));
	eb := devsize(fs.fd);
	eb = eb - (eb % big Blksz) - big Blksz;
	fs.sb0 = getblk(Bptr(big 0, big -1, big -1), GBnochk);
	fs.sb1 = getblk(Bptr(eb, big -1, big -1), GBnochk);
	{
		unpacksb(fs.sb0.buf);
	} exception e {
	"gefs:*" =>
		sys->fprint(sys->fildes(2), "gefs: unable to load primary superblock: %s\n", errmsg(e));
		unpacksb(fs.sb1.buf);
	}
	fs.arenas = array[fs.narena] of ref Arena;
	for(i := 0; i < fs.narena; i++){
		a := newarena();
		fs.arenas[i] = a;
		loadarena(a, fs.arenabp[i]);
		a.reserve = a.size / big 1024;
		if(a.reserve < big 512*KiB)
			a.reserve = big 512*KiB;
		if(a.reserve > big 8*MiB)
			a.reserve = big 8*MiB;
	}
	for(i = 0; i < fs.narena; i++){
		a := fs.arenas[i];
		loadlog(a, a.loghd);
	}
	(t, nil) := opensnap("adm");
	if(t == nil)
		error("load users: no adm label");
	loadusers(t);
	if(debug){
		sys->fprint(sys->fildes(2), "gefs: load %s:\n", dev);
		sys->fprint(sys->fildes(2), "\tsnaptree:\t%bux\n", fs.snap.bp.addr);
		sys->fprint(sys->fildes(2), "\tnarenas:\t%d\n", fs.narena);
		sys->fprint(sys->fildes(2), "\tnextqid:\t%bd\n", fs.nextqid);
		sys->fprint(sys->fildes(2), "\tlastqgen:\t%bd\n", fs.qgen);
		sys->fprint(sys->fildes(2), "\tnextgen:\t%bd\n", fs.nextgen);
		sys->fprint(sys->fildes(2), "\tcachesz:\t%d MiB\n", fs.cmax*Blksz/(1024*1024));
	}
}

# ---- ream ----

kv(k, v: array of byte): Kvp
{
	return Kvp(k, v);
}

dirkv(up: big, d: ref Xdir): Kvp
{
	return dir2kv(up, d);
}

initadm(r, u: ref Blk, nu: int)
{
	# values go in in key order
	k := array[Offksz] of byte;
	p8(k, 0, Kdat);
	p64(k, 1, big Qadmuser);
	p64(k, 9, big 0);
	v := array[Ptrsz] of byte;
	packbp(v, 0, u.bp);
	setval(r, k, v);
	# a quirk: sorted by length, then alphabet
	x := dir2kv(big Qadmroot, fillxdir(Qctl, "ctl", Sys->QTFILE, 8r664, big 0));
	setval(r, x.k, x.v);
	x = dir2kv(big Qadmroot, fillxdir(big Qadmuser, "users", Sys->QTFILE, 8r664, big nu));
	setval(r, x.k, x.v);
	x = dir2kv(big Qadmroot, fillxdir(Qstatus, "status", Sys->QTFILE, 8r664, big 0));
	setval(r, x.k, x.v);
	x = dir2kv(big -1, fillxdir(big Qadmroot, "", Sys->QTDIR, Sys->DMDIR|8r775, big 0));
	setval(r, x.k, x.v);
	sk := array[Upksz] of byte;
	packsuper(sk, 0, big Qadmroot);
	sv := array[Keymax] of byte;
	n := packdkey(sv, 0, len sv, big -1, "");
	setval(r, sk, sv[0:n]);
}

initroot(r: ref Blk)
{
	x := dir2kv(big -1, fillxdir(big Qmainroot, "", Sys->QTDIR, Sys->DMDIR|8r775, big 0));
	setval(r, x.k, x.v);
	sk := array[Upksz] of byte;
	packsuper(sk, 0, big Qmainroot);
	sv := array[Keymax] of byte;
	n := packdkey(sv, 0, len sv, big -1, "");
	setval(r, sk, sv[0:n]);
}

snapval(t: ref Tree): array of byte
{
	v := array[Treesz] of byte;
	packtree(v, 0, t);
	return v;
}

initsnap(s, r, a: ref Blk)
{
	x := lbl2kv("adm", big 1, Lmut);
	setval(s, x.k, x.v);
	x = lbl2kv("empty", big 0, 0);
	setval(s, x.k, x.v);
	x = lbl2kv("main", big 2, Lmut);
	setval(s, x.k, x.v);

	# empty
	t := ref Tree;
	t.flag = 0;
	t.nref = 2;
	t.nlbl = 1;
	t.ht = 1;
	t.gen = fs.nextgen++;
	t.base = big -1;
	t.pred = big -1;
	t.succ = big -1;
	t.bp = r.bp;
	setval(s, snapkey(big 0), snapval(t));
	# adm
	t = ref Tree;
	t.nref = 0;
	t.nlbl = 1;
	t.ht = 1;
	t.gen = fs.nextgen++;
	t.base = big 0;
	t.pred = big -1;
	t.succ = big -1;
	t.bp = a.bp;
	setval(s, snapkey(big 1), snapval(t));
	# main
	t = ref Tree;
	t.nref = 0;
	t.nlbl = 1;
	t.ht = 1;
	t.gen = fs.nextgen++;
	t.base = big 0;
	t.pred = big -1;
	t.succ = big -1;
	t.bp = r.bp;
	setval(s, snapkey(big 2), snapval(t));
}

initarena(a: ref Arena, hdaddr, asz: big)
{
	b := newblkbuf();
	addr := hdaddr + big (2*Blksz);	# room for the arena header and footer
	a.loghd = Zb();
	b.ty = Tlog;
	b.bp = Bptr(addr, big -1, big -1);
	b.logsz = 0;
	b.logp = Zb();
	b.data = b.buf[Loghdsz:];
	b.flag |= Bdirty;
	o := 0;
	o = p64(b.data, o, addr | big LogFree);
	o = p64(b.data, o, asz - big (2*Blksz));
	o = p64(b.data, o, b.bp.addr | big LogAlloc);
	o = p64(b.data, o, big Blksz);
	o = p64(b.data, o, big LogSync);	# barrier
	b.logsz = o;
	finalize(b);
	syncblk(b);
	a.loghd = b.bp;
	a.loghd.gen = big -1;
	a.size = asz;
	a.used = big Blksz;

	h0 := newblkbuf();
	h0.ty = Tarena;
	h0.bp = Bptr(hdaddr, big -1, big -1);
	h0.data = h0.buf[2:];
	packarena(h0.data, 0, a);
	finalize(h0);
	syncblk(h0);
	a.h0 = h0;

	h1 := newblkbuf();
	h1.ty = Tarena;
	h1.bp = Bptr(hdaddr + big Blksz, big -1, big -1);
	h1.data = h1.buf[2:];
	packarena(h1.data, 0, a);
	finalize(h1);
	syncblk(h1);
	a.h1 = h1;
}

reamfs(dev: string)
{
	fs.fd = sys->open(dev, Sys->ORDWR);
	if(fs.fd == nil)
		error(sys->sprint("open %s: %r", dev));
	sz := devsize(fs.fd);
	sys->fprint(sys->fildes(2), "gefs: reaming %s\n", dev);
	if(sz < big 128*MiB + big Blksz)
		error("ream: disk too small");
	mntroot := ref Tree;
	admroot := ref Tree;

	sz = sz - sz % big Blksz - big (2*Blksz);
	fs.narena = int ((sz + big 4096*GiB - big 1) / (big 4096*GiB));
	if(fs.narena < 8)
		fs.narena = 8;
	if(fs.narena >= 32)
		fs.narena = 32;
	fs.arenas = array[fs.narena] of ref Arena;

	off := big Blksz;
	asz := sz / big fs.narena;
	asz = asz - (asz % big Blksz) - big (2*Blksz);

	sb0 := newblkbuf();
	sb1 := newblkbuf();
	sb0.bp = Bptr(big 0, big -1, big -1);
	sb1.bp = Bptr(sz + big Blksz, big -1, big -1);
	fs.sb0 = sb0;
	fs.sb1 = sb1;

	fs.arenabp = array[fs.narena] of Bptr;
	for(i := 0; i < fs.narena; i++){
		a := newarena();
		fs.arenas[i] = a;
		if(debug)
			sys->fprint(sys->fildes(2), "\tarena %d: %bd blocks at %bux\n", i, asz/big Blksz, off);
		initarena(a, off, asz);
		fs.arenabp[i] = a.h0.bp;
		off += asz + big (2*Blksz);
	}
	for(i = 0; i < fs.narena; i++){
		a := fs.arenas[i];
		loadarena(a, a.h0.bp);
		loadlog(a, a.loghd);
	}

	mb := newblk(mntroot, Tleaf);
	initroot(mb);
	finalize(mb);
	syncblk(mb);
	mntroot.ht = 1;
	mntroot.bp = mb.bp;

	ab := newblk(admroot, Tleaf);
	ub := newdblk(admroot, big 0, 1);
	utab := array of byte sys->sprint("-1:adm::%s\n0:none::\n1:%s:%s:\n", reamuser, reamuser, reamuser);
	ub.data[0:] = utab;
	finalize(ub);
	syncblk(ub);
	initadm(ab, ub, len utab);
	finalize(ab);
	syncblk(ab);
	admroot.ht = 1;
	admroot.bp = ab.bp;

	# an empty file system: one snap block for the tree to insert
	# into, and a snapshot of the start
	tb := newblk(mntroot, Tleaf);
	initsnap(tb, mb, ab);
	finalize(tb);
	syncblk(tb);

	fs.snap.bp = tb.bp;
	fs.snap.ht = 1;
	fs.snapdl.head = Zb();
	fs.snapdl.tail = Zb();
	fs.nextqid = big Nreamqid;

	# the arenas, with their updated free lists
	for(i = 0; i < fs.narena; i++){
		a := fs.arenas[i];
		finalize(a.logtl);
		syncblk(a.logtl);
		packarena(a.h0.data, 0, a);
		finalize(a.h0);
		syncblk(a.h0);
		packarena(a.h1.data, 0, a);
		finalize(a.h1);
		syncblk(a.h1);
		fs.arenabp[i] = a.h0.bp;
	}

	# and the superblock and its backup
	packsb(sb0.buf);
	packsb(sb1.buf);
	sb0.ty = Tsuper;
	sb1.ty = Tsuper;
	finalize(sb0);
	finalize(sb1);
	syncblk(sb0);
	syncblk(sb1);
	devflush();
}
