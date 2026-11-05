#
# gefs: snapshots, labels and deadlists, as 9front's snap.c.
#

dlflush(dl: ref Dlist)
{
	if(dl.ins == nil)
		return;
	dl.head = dl.ins.bp;
	if(dl.tail.addr == dl.head.addr)
		dl.tail = dl.head;
	enqueue(dl.ins);
	# head and tail keep the pointer as it was before enqueue hashed
	# the block: a deadlist block is checked by the hash of its body
	dl.ins = nil;
	# the snap dlist has gen -1: it is not in the tree
	if(dl.gen != big -1){
		kv := dlist2kv(dl);
		btupsert(fs.snap, array[] of {Msg(Oinsert, kv.k, kv.v)});
	}
}

dlhash(gen, bgen: big): int
{
	h := (ihash(gen) ^ ihash(bgen)) % fs.dlcmax;
	if(h < 0)
		h = -h;
	return h;
}

dlcachedel(dl: ref Dlist, hdel: int)
{
	if(hdel){
		h := dlhash(dl.gen, dl.bgen);
		prev: ref Dlist;
		for(d := fs.dlcache[h]; d != nil; d = d.chain){
			if(d.gen == dl.gen && d.bgen == dl.bgen){
				if(prev == nil)
					fs.dlcache[h] = d.chain;
				else
					prev.chain = d.chain;
				break;
			}
			prev = d;
		}
	}
	if(dl == fs.dlhead)
		fs.dlhead = dl.cnext;
	if(dl == fs.dltail)
		fs.dltail = dl.cprev;
	if(dl.cnext != nil)
		dl.cnext.cprev = dl.cprev;
	if(dl.cprev != nil)
		dl.cprev.cnext = dl.cnext;
	dl.cnext = nil;
	dl.cprev = nil;
}

dlcacheget(gen, bgen: big): ref Dlist
{
	for(dl := fs.dlcache[dlhash(gen, bgen)]; dl != nil; dl = dl.chain)
		if(dl.gen == gen && dl.bgen == bgen){
			dlcachedel(dl, 0);
			return dl;
		}
	return nil;
}

dlkey(gen, bgen: big): array of byte
{
	k := array[Dlksz] of byte;
	p8(k, 0, Kdlist);
	p64(k, 1, gen);
	p64(k, 9, bgen);
	return k;
}

getdl(gen, bgen: big): ref Dlist
{
	dl := dlcacheget(gen, bgen);
	if(dl != nil)
		return dl;
	fs.dlcount++;
	{
		kv := btlookup(fs.snap, dlkey(gen, bgen));
		if(kv != nil)
			dl = kv2dlist(*kv);
		else{
			# a new one
			dl = ref Dlist;
			dl.gen = gen;
			dl.bgen = bgen;
			dl.head = Zb();
			dl.tail = Zb();
			dl.ins = nil;
			n := dlist2kv(dl);
			btupsert(fs.snap, array[] of {Msg(Oinsert, n.k, n.v)});
		}
	} exception e {
	"*" =>
		fs.dlcount--;
		raise e;
	}
	h := dlhash(gen, bgen);
	dl.chain = fs.dlcache[h];
	fs.dlcache[h] = dl;
	return dl;
}

putdl(dl: ref Dlist)
{
	# gen -1 is the snap dlist, which is not in the cache
	if(dl.gen == big -1)
		return;
	dlcachedel(dl, 0);
	while(fs.dlcount >= fs.dlcmax && (dt := fs.dltail) != nil){
		fs.dlcount--;
		dlcachedel(dt, 1);
		dlflush(dt);
	}
	dl.cprev = nil;
	dl.cnext = fs.dlhead;
	if(fs.dltail == nil)
		fs.dltail = dl;
	if(fs.dlhead != nil)
		fs.dlhead.cprev = dl;
	fs.dlhead = dl;
}

# give back a deadlist's blocks, and with dofree the blocks it lists
freedl(dl: ref Dlist, dofree: int)
{
	bp := dl.head;
	done := 0;
	while(bp.addr != big -1 && !done){
		b := getblk(bp, 0);
		if(dofree)
			for(p := 0; p < b.logsz; p += 8){
				addr := g64(b.data, p);
				cachedel(addr);
				blkdealloc_lk(getarena(addr), addr);
			}
		done = (bp.addr == dl.tail.addr);
		bp = b.logp;
		b.flag |= Bfreed;
		blkdealloc_lk(getarena(b.bp.addr), b.bp.addr);
	}
}

splicedl(d, m: ref Dlist)
{
	# a destination that did not exist takes the merged one whole;
	# otherwise chain on to its tail
	if(d == m)
		broke("splicedl: same list");
	if(m.head.addr == big -1)
		return;
	if(d.head.addr == big -1){
		if(d.ins != nil)
			broke("splicedl: empty list with a head block");
		d.head = m.head;
		d.tail = m.tail;
		d.ins = m.ins;
		m.ins = nil;
	}else{
		if(m.ins != nil){
			enqueue(m.ins);
			m.ins = nil;
		}
		b := getblk(d.tail, 0);
		b.logp = m.head;
		d.tail = m.tail;
		if(d.head.addr == m.head.addr)
			broke("splicedl: lists share a head");
		# dlflush writes the tail, so this should not
		if(b != d.ins){
			cachedel(b.bp.addr);
			finalize(b);
			syncblk(b);
			cacheins(b);
		}
	}
}

mergedl(merge, gen, bgen: big)
{
	d := getdl(merge, bgen);
	m := getdl(gen, bgen);
	splicedl(d, m);
	k0 := dlist2kv(m);
	k1 := dlist2kv(d);
	{
		btupsert(fs.snap, array[] of {Msg(Odelete, k0.k, k0.v), Msg(Oinsert, k1.k, k1.v)});
	} exception e {
	"*" =>
		putdl(m);
		putdl(d);
		raise e;
	}
	putdl(m);
	putdl(d);
}

# reclaims a deadlist after the next superblock commit
dropdl(gen, bgen, succ: big)
{
	d := getdl(gen, bgen);
	kv := dlist2kv(d);
	btupsert(fs.snap, array[] of {Msg(Odelete, kv.k, kv.v)});
	if(d.ins != nil)
		broke("dropdl: open head");
	dlcachedel(d, 1);
	fs.dlcount--;
	# with no successor, sweeping the tree frees what it lists; we
	# give back the deadlist's own blocks
	if(succ == big -1)
		splicedl(fs.dropdl, d);
	else
		splicedl(fs.snapdl, d);
}

dlpfx(gen: big): array of byte
{
	pfx := array[9] of byte;
	p8(pfx, 0, Kdlist);
	p64(pfx, 1, gen);
	return pfx;
}

reclaimblocks(gen, succ, prev: big)
{
	s := btnewscan(dlpfx(gen));
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		dl := kv2dlist(*kv);
		if(succ != big -1 && dl.bgen <= prev)
			mergedl(succ, dl.gen, dl.bgen);
		else
			dropdl(dl.gen, dl.bgen, succ);
		# the tree changed under the scan: resume after this key
		btexit(s);
		btenter(fs.snap, s);
	}
	btexit(s);
	if(succ != big -1){
		s = btnewscan(dlpfx(succ));
		btenter(fs.snap, s);
		for(;;){
			kv := btnext(s);
			if(kv == nil)
				break;
			dl := kv2dlist(*kv);
			if(dl.bgen <= prev)
				continue;
			dropdl(dl.gen, dl.bgen, succ);
			btexit(s);
			btenter(fs.snap, s);
		}
		btexit(s);
	}
}

delsnapname(name: string)
{
	if(name == "dump" || name == "empty" || name == "adm")
		error(Esnapr);
}

#
# Removes a label from a snapshot, letting it be reclaimed if it is not
# the direct predecessor of more than one other. One with a single
# successor and no label is merged into that successor. 1 if the tree
# must be swept.
#
delsnap(t: ref Tree, succ: big, name: string): int
{
	m: list of Msg;
	del := 0;
	if(name != nil){
		delsnapname(name);
		m = Msg(Odelete, packlbl(name), array[0] of byte) :: m;
		t.nlbl--;
	}
	if(t.nlbl == 0 && t.nref == 0){
		del = 1;
		if(t.pred != big -1){
			kv := retag2kv(t.pred, succ, 0, 0);
			m = Msg(Orelink, kv.k, kv.v) :: m;
		}
		if(t.succ != big -1){
			kv := retag2kv(t.succ, t.pred, 0, 0);
			m = Msg(Oreprev, kv.k, kv.v) :: m;
		}
		if(t.pred == big -1 && succ == big -1){
			kv := retag2kv(t.base, big -1, 0, -1);
			m = Msg(Oincref, kv.k, kv.v) :: m;
		}
		m = Msg(Odelete, snapkey(t.gen), array[0] of byte) :: m;
	}else{
		if(name == nil)
			broke("delsnap: no name");
		kv := retag2kv(t.gen, t.succ, -1, 0);
		m = Msg(Orelink, kv.k, kv.v) :: m;
	}
	dlsync();
	btupsert(fs.snap, l2a(m));
	if(del){
		reclaimblocks(t.gen, succ, t.pred);
		for(ml := fs.mounts; ml != nil; ml = tl ml){
			r := (hd ml).root;
			if(r.gen == t.succ)
				r.pred = t.pred;
			if(r.gen == t.pred)
				r.succ = succ;
		}
	}
	return del && succ == big -1;
}

l2a(l: list of Msg): array of Msg
{
	n := len l;
	a := array[n] of Msg;
	for(; l != nil; l = tl l)
		a[--n] = hd l;
	return a;
}

#
# Attaches a label to a tree, adding to its count: the snapshot shows
# in the dump.
#
tagsnap(t: ref Tree, name: string, flg: int)
{
	if(name == "dump" || name == "empty" || name == "adm")
		error(Ename);
	m: list of Msg;
	if(flg & Lmut){
		kv := btlookup(fs.snap, snapkey(t.gen));
		if(kv == nil)
			broke(Efs+": tagsnap");
		c := unpacktree(kv.v, 0);
		n := ref Tree;
		n.dirty = 0;
		n.nlbl = 1;
		n.nref = 0;
		n.ht = c.ht;
		n.bp = c.bp;
		n.succ = big -1;
		n.pred = big -1;
		n.base = t.gen;
		n.gen = fs.nextgen++;
		n.memgen = fs.nextgen++;

		t.nref++;
		r := retag2kv(t.gen, big -1, 0, 1);
		m = Msg(Oincref, r.k, r.v) :: m;
		l := lbl2kv(name, n.gen, flg);
		m = Msg(Oinsert, l.k, l.v) :: m;
		tk := tree2kv(n);
		m = Msg(Oinsert, tk.k, tk.v) :: m;
	}else{
		t.nlbl++;
		r := retag2kv(t.gen, t.succ, 1, 0);
		m = Msg(Orelink, r.k, r.v) :: m;
		l := lbl2kv(name, t.gen, flg);
		m = Msg(Oinsert, l.k, l.v) :: m;
	}
	btupsert(fs.snap, l2a(m));
}

#
# Updates a snapshot: the same generation where it can be, else a new
# one. A snapshot keeps its generation only while it is the tip of its
# list; once a derived one can see it, it is immutable.
#
updatesnap(o: ref Tree, lbl: string, flg: int): ref Tree
{
	if(!(flg & Lmut))
		broke("updatesnap: immutable");
	if(!o.dirty)
		return o;
	t := ref Tree;
	t.dirty = 0;
	t.nlbl = 1;
	t.nref = 0;
	t.ht = o.ht;
	t.bp = o.bp;
	t.succ = big -1;
	t.base = o.base;
	t.gen = o.memgen;
	t.memgen = fs.nextgen++;
	m: list of Msg;
	o.nlbl--;
	if(o.nlbl == 0 && o.nref == 0){
		t.pred = o.pred;
		if(t.pred != big -1){
			r := retag2kv(t.pred, t.gen, 0, 0);
			m = Msg(Orelink, r.k, r.v) :: m;
		}
	}else{
		t.pred = o.gen;
		r := retag2kv(t.pred, t.gen, -1, 0);
		m = Msg(Orelink, r.k, r.v) :: m;
	}
	tk := tree2kv(t);
	m = Msg(Oinsert, tk.k, tk.v) :: m;
	l := lbl2kv(lbl, t.gen, flg);
	m = Msg(Oinsert, l.k, l.v) :: m;
	btupsert(fs.snap, l2a(m));
	# dirty is cleared only after the sync
	o.dirty = 0;
	# the last ref to the snap
	if(o.nlbl == 0 && o.nref == 0)
		delsnap(o, t.gen, nil);
	return t;
}

opentree(gen: big): ref Tree
{
	for(ml := fs.mounts; ml != nil; ml = tl ml)
		if((hd ml).root.gen == gen)
			return (hd ml).root;
	kv := btlookup(fs.snap, snapkey(gen));
	if(kv == nil)
		broke(Efs+": opentree");
	t := unpacktree(kv.v, 0);
	t.memgen = fs.nextgen++;
	return t;
}

# a snapshot by its label: (tree, flags), or nil
opensnap(label: string): (ref Tree, int)
{
	kv := btlookup(fs.snap, packlbl(label));
	if(kv == nil)
		return (nil, 0);
	if(len kv.v != 1+8+4)
		broke(Efs+": opensnap");
	gen := g64(kv.v, 1);
	flg := g32(kv.v, 1+8);
	return (opentree(gen), flg);
}

dlsync()
{
	dlflush(fs.snapdl);
	for(dl := fs.dlhead; dl != nil; dl = dl.cnext)
		dlflush(dl);
}

#
# Marks a block killed by the tree t: free once t is reclaimed. t is an
# active snapshot with no successors.
#
killblk(t: ref Tree, bp: Bptr)
{
	dl: ref Dlist;
	# blocks made before a fork belong to the other chain: leak them
	# here, and let the last reference over there clean up
	if(t == fs.snap)
		dl = fs.snapdl;
	else if(bp.gen > t.base)
		dl = getdl(t.memgen, bp.gen);
	else
		return;
	{
		if(dl.ins == nil || Logspc - dl.ins.logsz < Logslop){
			b := newblk(fs.snap, Tdlist);
			if(dl.ins != nil)
				enqueue(dl.ins);
			if(dl.tail.addr == big -1)
				dl.tail = b.bp;
			b.logp = dl.head;
			dl.head = b.bp;
			dl.ins = b;
			cacheins(b);
		}
		p64(dl.ins.data, dl.ins.logsz, bp.addr);
		dl.ins.logsz += 8;
		dl.ins.flag |= Bdirty;
	} exception e {
	"*" =>
		putdl(dl);
		raise e;
	}
	putdl(dl);
}
