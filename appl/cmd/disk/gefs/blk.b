#
# gefs: blocks, arenas and their allocation logs, and the block cache,
# as 9front's blk.c and cache.c.
#
# What is different, and why. 9front writes dirty blocks from syncer
# procs, through a queue per arena that orders a generation's writes
# before its frees and marks syncs with fences; and it frees nothing a
# reader may still be looking at until an epoch has passed. Here there
# is one thread: enqueue() writes the block at once, so a fence is a
# flush of the device (devflush); and a free waits on fs.pending until
# the request that made it is finished (quiesce()), which is the point
# at which 9front's epoch would advance. The order the disk sees --
# a generation's writes, then its frees, then the superblock -- is the
# same.
#
# The cache is 9front's in purpose and not in shape: blocks are garbage
# collected, so it is a bounded table of clean blocks, and forgetting
# one frees nothing that is still in use. A dirty block -- a deadlist's
# head being appended to, the arena logs -- is never evicted: getblk of
# its address must find that very block.
#

# a free range in an arena, in an AVL tree by offset
Arange: adt {
	off:	big;
	ln:	big;
	h:	int;
	l:	cyclic ref Arange;
	r:	cyclic ref Arange;
};

Arena: adt {
	free:	ref Arange;	# the AVL tree of free ranges
	logbuf:	array of ref Blk;	# 2 preallocated log pages
	h0:	ref Blk;	# header
	h1:	ref Blk;	# footer
	size:	big;
	used:	big;
	reserve: big;
	lastlogsz: big;
	nlog:	big;
	loghd:	Bptr;
	logtl:	ref Blk;	# end of the log, open for writing
	# the tail as it is on disk, for rewriting it safely (tailstage)
	dsz:	int;		# its logsz there, or -1 if it has no copy there
	dlogp:	Bptr;		# and its chain
	staged:	int;		# the new contents are there, under the old header
};

Pend: adt {
	bp:	Bptr;
	b:	ref Blk;
	dl:	ref Dlist;
	next:	cyclic ref Pend;
};

#
# Free range tree. lookup(off) is the range holding off; prev/next are
# by offset. Ranges never overlap.
#
rht(r: ref Arange): int
{
	if(r == nil)
		return 0;
	return r.h;
}

rfix(r: ref Arange): ref Arange
{
	hl := rht(r.l);
	hr := rht(r.r);
	if(hl > hr)
		r.h = hl+1;
	else
		r.h = hr+1;
	return r;
}

rrotr(r: ref Arange): ref Arange
{
	l := r.l;
	r.l = l.r;
	l.r = rfix(r);
	return rfix(l);
}

rrotl(r: ref Arange): ref Arange
{
	n := r.r;
	r.r = n.l;
	n.l = rfix(r);
	return rfix(n);
}

rbal(r: ref Arange): ref Arange
{
	rfix(r);
	d := rht(r.l) - rht(r.r);
	if(d > 1){
		if(rht(r.l.l) < rht(r.l.r))
			r.l = rrotl(r.l);
		return rrotr(r);
	}
	if(d < -1){
		if(rht(r.r.r) < rht(r.r.l))
			r.r = rrotr(r.r);
		return rrotl(r);
	}
	return r;
}

rinsert(t: ref Arange, n: ref Arange): ref Arange
{
	if(t == nil){
		n.l = nil;
		n.r = nil;
		n.h = 1;
		return n;
	}
	if(n.off < t.off)
		t.l = rinsert(t.l, n);
	else if(n.off > t.off)
		t.r = rinsert(t.r, n);
	else
		broke("rinsert: duplicate range");
	return rbal(t);
}

rdelmin(t: ref Arange): (ref Arange, ref Arange)
{
	if(t.l == nil)
		return (t.r, t);
	m: ref Arange;
	(t.l, m) = rdelmin(t.l);
	return (rbal(t), m);
}

rdelete(t: ref Arange, off: big): ref Arange
{
	if(t == nil)
		broke("rdelete: no such range");
	if(off < t.off)
		t.l = rdelete(t.l, off);
	else if(off > t.off)
		t.r = rdelete(t.r, off);
	else{
		if(t.l == nil)
			return t.r;
		if(t.r == nil)
			return t.l;
		(r, m) := rdelmin(t.r);
		m.l = t.l;
		m.r = r;
		return rbal(m);
	}
	return rbal(t);
}

# the range with the greatest off <= x, or nil
rfloor(t: ref Arange, x: big): ref Arange
{
	best: ref Arange;
	while(t != nil){
		if(t.off <= x){
			best = t;
			t = t.r;
		}else
			t = t.l;
	}
	return best;
}

# the range with the least off > x, or nil
rafter(t: ref Arange, x: big): ref Arange
{
	best: ref Arange;
	while(t != nil){
		if(t.off > x){
			best = t;
			t = t.l;
		}else
			t = t.r;
	}
	return best;
}

# the range with the greatest off < x, or nil
rbefore(t: ref Arange, x: big): ref Arange
{
	best: ref Arange;
	while(t != nil){
		if(t.off < x){
			best = t;
			t = t.r;
		}else
			t = t.l;
	}
	return best;
}

rmin(t: ref Arange): ref Arange
{
	if(t == nil)
		return nil;
	while(t.l != nil)
		t = t.l;
	return t;
}

rmax(t: ref Arange): ref Arange
{
	if(t == nil)
		return nil;
	while(t.r != nil)
		t = t.r;
	return t;
}

freerange(a: ref Arena, off, ln: big)
{
	if(ln % big Blksz != big 0)
		broke("freerange: not whole blocks");
	r := ref Arange(off, ln, 1, nil, nil);
	if(rfloor(a.free, off) != nil && rfloor(a.free, off).off == off)
		broke("freerange: double free");
	# coalesce with the range before and the range after
	s := rbefore(a.free, off);
	if(s != nil){
		if(s.off+s.ln == r.off){
			a.free = rdelete(a.free, s.off);
			r.off = s.off;
			r.ln += s.ln;
		}else if(s.off+s.ln > r.off)
			broke("freerange: overlaps the range before");
	}
	s = rafter(a.free, r.off);
	if(s != nil){
		if(r.off+r.ln == s.off){
			a.free = rdelete(a.free, s.off);
			r.ln += s.ln;
		}else if(r.off+r.ln > s.off)
			broke("freerange: overlaps the range after");
	}
	a.free = rinsert(a.free, r);
}

grabrange(a: ref Arena, off, ln: big)
{
	if(ln % big Blksz != big 0)
		broke("grabrange: not whole blocks");
	r := rfloor(a.free, off);
	if(r == nil || off + ln > r.off + r.ln)
		broke("grabrange: not free");
	if(off == r.off){
		a.free = rdelete(a.free, r.off);
		r.off += ln;
		r.ln -= ln;
		if(r.ln != big 0)
			a.free = rinsert(a.free, r);
	}else if(off + ln == r.off + r.ln){
		r.ln -= ln;
	}else if(off > r.off && off+ln < r.off + r.ln){
		l := r.ln;
		s := ref Arange(off + ln, big 0, 1, nil, nil);
		r.ln = off - r.off;
		s.ln = l - r.ln - ln;
		a.free = rinsert(a.free, s);
	}else
		broke("grabrange: bad range");
}

# ---- blocks ----

newblkbuf(): ref Blk
{
	b := ref Blk;
	b.buf = array[Blksz] of byte;
	b.data = b.buf;
	b.bp = Zb();
	return b;
}

syncblk(b: ref Blk)
{
	bassert(b, (b.flag & Bfinal) != 0, "syncblk: not finalized");
	bassert(b, b.bp.addr >= big 0, "syncblk: no address");
	if(sys->pwrite(fs.fd, b.buf, Blksz, b.bp.addr) != Blksz)
		broke(sys->sprint("%bux %s: %r", b.bp.addr, Eio));
	if(wjfd != nil){
		r := array[9+Blksz] of byte;
		r[0] = byte 'W';
		p64(r, 1, b.bp.addr);
		r[9:] = b.buf;
		sys->write(wjfd, r, len r);
	}
	b.flag &= ~Bdirty;
	fs.nwritten++;
}

readblk(b: ref Blk, bp: Bptr, flg: int)
{
	off := bp.addr;
	rem := Blksz;
	o := 0;
	while(rem != 0){
		n := sys->pread(fs.fd, b.buf[o:], rem, off);
		if(n <= 0)
			error(sys->sprint("%s: %r", Eio));
		rem -= n;
		off += big n;
		o += n;
	}
	fs.nread++;
	b.bp = Bptr(bp.addr, big -1, big -1);
	b.nval = 0;
	b.valsz = 0;
	b.nbuf = 0;
	b.bufsz = 0;
	b.logsz = 0;
	if(flg & GBraw)
		b.ty = Tdat;
	else
		b.ty = g16(b.buf, 0);
	case b.ty {
	Tdat or Tsuper =>
		b.data = b.buf;
	Tarena =>
		b.data = b.buf[2:];
	Tdlist or Tlog =>
		b.logsz = g16(b.buf, 2);
		b.logh = g64(b.buf, 4);
		b.logp = unpackbp(b.buf, 12);
		b.data = b.buf[Loghdsz:];
	Tpivot =>
		b.nval = g16(b.buf, 2);
		b.valsz = g16(b.buf, 4);
		b.nbuf = g16(b.buf, 6);
		b.bufsz = g16(b.buf, 8);
		b.data = b.buf[Pivhdsz:];
	Tleaf =>
		b.nval = g16(b.buf, 2);
		b.valsz = g16(b.buf, 4);
		b.data = b.buf[Leafhdsz:];
	* =>
		error(sys->sprint("invalid block type %d @%bux", b.ty, bp.addr));
	}
	xh, ck: big;
	if(b.ty == Tlog || b.ty == Tdlist){
		xh = b.logh;
		ck = bufhash(b.data, b.logsz);
	}else{
		xh = bp.hash;
		ck = blkhash(b);
	}
	if((flg & GBnochk) == 0 && ck != xh)
		error(sys->sprint("%s: %bux %bux != %bux", Ecorrupt, bp.addr, xh, ck));
}

pickarena(ty, hint, tries: int): ref Arena
{
	r := fs.roundrobin++ / 2048;
	n: int;
	if(ty == Tdat)
		n = hint % (fs.narena - 1) + r + 1;
	else
		n = r;
	return fs.arenas[(n + tries) % fs.narena];
}

getarena(b: big): ref Arena
{
	lo := 0;
	hi := fs.narena;
	if(b == fs.sb0.bp.addr)
		return fs.arenas[0];
	if(b == fs.sb1.bp.addr)
		return fs.arenas[hi-1];
	for(;;){
		if(lo > hi || lo >= fs.narena)
			broke(sys->sprint("getarena: %bux in no arena", b));
		mid := (hi + lo)/2;
		a := fs.arenas[mid];
		alo := a.h0.bp.addr;
		ahi := alo + a.size + big (2*Blksz);
		if(b < alo)
			hi = mid-1;
		else if(b > ahi)
			lo = mid+1;
		else
			return a;
	}
}

mklogblk(a: ref Arena, o: big): ref Blk
{
	lb := a.logbuf[0];
	if(lb == a.logtl)
		lb = a.logbuf[1];
	lb.flag = Bstatic;
	initblk(lb, o, big -1, Tlog);
	return lb;
}

#
# Logs an allocation, a free, or a sync barrier. Duplicates some of the
# work of blkalloc, to keep from recursing.
#
logappend(a: ref Arena, off, ln: big, op: int)
{
	if((off & big 16rff) != big 0)
		broke("logappend: unaligned");
	if(op != LogSync){
		start := a.h0.bp.addr;
		end := start + a.size + big (2*Blksz);
		if(off < start || off >= end)
			broke("logappend: outside the arena");
	}
	lb := a.logtl;
	bassert(lb, lb.ty == Tlog, "logappend: not a log");
	if((lb.flag & Bdirty) == 0)
		lb.flag = (lb.flag | Bdirty) & ~Bfinal;
	#
	# Move to the next block when there is too little room: up to 16
	# bytes for this, then 16 more for the new block's allocation and
	# the chain.
	#
	if(lb.logsz >= Logspc - Logslop){
		o := blkalloc_lk(a, 0);
		if(o == big -1)
			error(Efull);
		p64(lb.data, lb.logsz, o|big LogAlloc1);
		lb.logsz += 8;
		lb.logp = Bptr(o, big -1, big -1);
		lb = mklogblk(a, o);
	}
	if(ln == big Blksz){
		if(op == LogAlloc)
			op = LogAlloc1;
		else if(op == LogFree)
			op = LogFree1;
	}
	p64(lb.data, lb.logsz, off | big op);
	lb.logsz += 8;
	if(op >= Log2wide){
		p64(lb.data, lb.logsz, ln);
		lb.logsz += 8;
	}
	if(lb != a.logtl){
		finalize(lb);
		syncblk(lb);
		if(tailstage(a))
			devflush();
		tailwrite(a);
		a.logtl = lb;
		a.dsz = lb.logsz;
		a.dlogp = lb.logp;
		a.nlog++;
	}
}

#
# The log's tail is the one block written again in place after a commit
# holds it: entries are appended to it, and at the next commit, or when
# it fills and gets a successor, it is written out whole. A drive
# promises only that a sector (512 bytes or 4 KB) is written whole when
# the power goes, not a 16 KB block, so the cut can leave the block part
# old and part new: the header, in the first sector, new, with an
# appended entry further on still old. Its hash then fails, the commit's
# log cannot be read, and the disk cannot be loaded at all. 9front
# writes it the same way; power-cut tests here (gefs_crash_test.sh) lost
# whole disks to it.
#
# So it goes in two steps with a flush between: first the new contents
# under the header that is on disk, which covers only the entries both
# have; then the new header. Every mixture of neighbouring versions is
# then a block whose header and hashed entries agree, the old commit's
# or the new. The disk format is unchanged.
#
tailstage(a: ref Arena): int
{
	b := a.logtl;
	if(a.dsz < 0 || a.staged || (b.logsz == a.dsz && b.logp.addr == a.dlogp.addr))
		return 0;
	if(b.logsz < a.dsz)
		broke("tailstage: the log tail was cut back and not written");
	m := newblkbuf();
	m.buf[0:] = b.buf;
	m.ty = Tlog;
	m.data = m.buf[Loghdsz:];
	m.bp = b.bp;
	m.logsz = a.dsz;
	m.logp = a.dlogp;
	finalize(m);
	syncblk(m);
	a.staged = 1;
	return 1;
}

# the tail's new header, after tailstage
tailwrite(a: ref Arena)
{
	b := a.logtl;
	finalize(b);
	syncblk(b);
	a.dsz = b.logsz;
	a.dlogp = b.logp;
	a.staged = 0;
}

#
# After a load the tail in memory stops at the last commit, and the copy
# on disk may go on past it, with entries that commit did not make. It
# is written once, cut back, before anything is appended: only its
# header changes, which a torn write cannot spoil. Not for a read-only
# file system, which never appends.
#
normlogs()
{
	n := 0;
	for(i := 0; i < fs.narena; i++){
		a := fs.arenas[i];
		if(a.logtl != nil && (a.logtl.logsz != a.dsz || a.logtl.logp.addr != a.dlogp.addr)){
			tailwrite(a);
			n++;
		}
	}
	if(n)
		devflush();
}

loadlog(a: ref Arena, bp: Bptr)
{
	b := a.logbuf[0];
	for(;;){
		readblk(b, bp, 0);
		a.nlog++;
		n := 0;
		for(i := 0; i < b.logsz; i += n){
			ent := g64(b.data, i);
			op := int (ent & big 16rff);
			off := ent & ~big 16rff;
			n = 8;
			if(op >= Log2wide)
				n = 16;
			case op {
			LogSync =>
				gen := ent >> 8;
				if(gen >= fs.qgen){
					if(a.logtl == nil){
						a.dsz = b.logsz;
						a.dlogp = b.logp;
						b.logp = Zb();
						b.logsz = i;
						a.logtl = b;
						cachedel(b.bp.addr);
						b.flag |= Bdirty;
						return;
					}
					return;
				}
			LogAlloc or LogAlloc1 =>
				ln := big Blksz;
				if(op >= Log2wide)
					ln = g64(b.data, i+8);
				grabrange(a, off, ln);
				a.used += ln;
			LogFree or LogFree1 =>
				ln := big Blksz;
				if(op >= Log2wide)
					ln = g64(b.data, i+8);
				freerange(a, off, ln);
				a.used -= ln;
			* =>
				broke(sys->sprint("loadlog: log op %d", op));
			}
		}
		if(b.logp.addr == big -1){
			a.logtl = b;
			a.dsz = b.logsz;
			a.dlogp = b.logp;
			return;
		}
		bp = b.logp;
		# the next block of the chain goes in the other buffer, so
		# that the tail is one of the two
		if(b == a.logbuf[0])
			b = a.logbuf[1];
		else
			b = a.logbuf[0];
	}
}

flushlog(a: ref Arena)
{
	if((a.logtl.flag & Bdirty) == 0)
		return;
	if(tailstage(a))
		devflush();
	tailwrite(a);
}

compresslog(a: ref Arena)
{
	flushlog(a);
	# room for the ranges, and for the blocks that hold them
	sz := 0;
	nr := 0;
	for(r := rmin(a.free); r != nil; r = rafter(a.free, r.off)){
		sz += 16;
		nr++;
	}
	nblks := (sz+Logspc)/(Logspc - Logslop) + 16*nr/(Logspc-Logslop) + 1;
	blks := array[nblks] of big;
	for(i := 0; i < nblks; i++){
		blks[i] = blkalloc_lk(a, 1);
		if(blks[i] == big -1)
			error(Efull);
	}
	# the log, from the ranges in the tree
	nlog := 0;
	i = 0;
	b := mklogblk(a, blks[i++]);
	for(r = rmin(a.free); r != nil; r = rafter(a.free, r.off)){
		if(b.logsz >= Logspc - Logslop){
			b.logp = Bptr(blks[i], big -1, big -1);
			finalize(b);
			syncblk(b);
			nlog++;
			b = mklogblk(a, blks[i++]);
		}
		p64(b.data, b.logsz, r.off | big LogFree);
		p64(b.data, b.logsz+8, r.ln);
		b.logsz += 16;
	}
	finalize(b);
	syncblk(b);
	# a valid freelist now: give back the blocks not used
	a.loghd = Bptr(blks[0], big -1, big -1);
	a.logtl = b;	# written back by sync() later
	a.dsz = b.logsz;
	a.dlogp = b.logp;
	a.staged = 0;
	a.nlog = big nlog;
	a.lastlogsz = big nlog;
	for(; i < nblks; i++)
		blkdealloc_lk(a, blks[i]);
}

logbarrier(a: ref Arena, gen: big)
{
	logappend(a, gen<<8, big 0, LogSync);
}

blkalloc_lk(a: ref Arena, seq: int): big
{
	r: ref Arange;
	if(seq)
		r = rmin(a.free);
	else
		r = rmax(a.free);
	if(!usereserve && a.size - a.used <= a.reserve)
		return big -1;
	if(r == nil)
		broke(Estuffed);
	b: big;
	if(seq){
		b = r.off;
		a.free = rdelete(a.free, r.off);
		r.ln -= big Blksz;
		r.off += big Blksz;
		if(r.ln != big 0)
			a.free = rinsert(a.free, r);
	}else{
		r.ln -= big Blksz;
		b = r.off + r.ln;
		if(r.ln == big 0)
			a.free = rdelete(a.free, r.off);
	}
	a.used += big Blksz;
	return b;
}

blkdealloc_lk(a: ref Arena, b: big)
{
	cachedel(b);
	logappend(a, b, big Blksz, LogFree);
	freerange(a, b, big Blksz);
	a.used -= big Blksz;
}

blkalloc(ty, hint, seq: int): big
{
	for(tries := 0; ; tries++){
		if(tries == 2*fs.narena)
			error(Efull);
		a := pickarena(ty, hint, tries);
		b := blkalloc_lk(a, seq);
		if(b == big -1)
			continue;
		logappend(a, b, big Blksz, LogAlloc);
		return b;
	}
}

initblk(b: ref Blk, bp, gen: big, ty: int): ref Blk
{
	b.ty = ty;
	b.bp = Bptr(bp, big -1, gen);
	if(cachepeek(bp) != nil)
		broke(sys->sprint("double alloc: %bux", bp));
	case ty {
	Tdat =>
		b.data = b.buf;
	Tarena =>
		b.data = b.buf[2:];
	Tdlist or Tlog =>
		b.logsz = 0;
		b.logp = Zb();
		b.data = b.buf[Loghdsz:];
	Tpivot =>
		b.data = b.buf[Pivhdsz:];
	Tleaf =>
		b.data = b.buf[Leafhdsz:];
	}
	b.flag |= Bdirty;
	b.nval = 0;
	b.valsz = 0;
	b.nbuf = 0;
	b.bufsz = 0;
	b.logsz = 0;
	return b;
}

newdblk(t: ref Tree, hint: big, seq: int): ref Blk
{
	bp := blkalloc(Tdat, int (hint & big 16r7FFFFFFF), seq);
	return initblk(newblkbuf(), bp, t.memgen, Tdat);
}

newblk(t: ref Tree, ty: int): ref Blk
{
	bp := blkalloc(ty, 0, 0);
	return initblk(newblkbuf(), bp, t.memgen, ty);
}

dupblk(t: ref Tree, b: ref Blk): ref Blk
{
	r := newblk(t, b.ty);
	r.bp.hash = big -1;
	r.nval = b.nval;
	r.valsz = b.valsz;
	r.nbuf = b.nbuf;
	r.bufsz = b.bufsz;
	r.logsz = b.logsz;
	r.buf[0:] = b.buf;
	return r;
}

finalize(b: ref Blk)
{
	if(b.ty != Tdat)
		p16(b.buf, 0, b.ty);
	case b.ty {
	Tpivot =>
		p16(b.buf, 2, b.nval);
		p16(b.buf, 4, b.valsz);
		p16(b.buf, 6, b.nbuf);
		p16(b.buf, 8, b.bufsz);
	Tleaf =>
		p16(b.buf, 2, b.nval);
		p16(b.buf, 4, b.valsz);
	Tdlist or Tlog =>
		b.logh = bufhash(b.data, b.logsz);
		p16(b.buf, 2, b.logsz);
		p64(b.buf, 4, b.logh);
		packbp(b.buf, 12, b.logp);
	Tdat or Tarena or Tsuper =>
		;
	* =>
		broke(sys->sprint("finalize: block type %d", b.ty));
	}
	b.bp.hash = blkhash(b);
	b.flag |= Bdirty|Bfinal;
}

getblk(bp: Bptr, flg: int): ref Blk
{
	{
		b := cacheget(bp.addr);
		if(b != nil){
			bassert(b, (b.flag & Bfreed) == 0, "getblk: freed");
			bassert(b, b.bp.gen == bp.gen, "getblk: wrong generation");
			return b;
		}
		#
		# An arena's log tail is not in the cache but in one of its
		# two static buffers, and what is on disk there may be older:
		# after a crash, loadlog cut the tail back to the last commit,
		# and the copy on disk still chains on to blocks the lost
		# commit allocated, which are free again. Reading that copy
		# would put a free block in the cache (check, walking the
		# chain, did, and the next allocation of it broke the fs as a
		# double alloc), so the tail is the one in memory. A scan:
		# there are few arenas, and a miss reads the disk anyway.
		#
		for(i := 0; i < len fs.arenas; i++){
			a := fs.arenas[i];
			if(a != nil && a.logtl != nil && a.logtl.bp.addr == bp.addr)
				return a.logtl;
		}
		b = newblkbuf();
		readblk(b, bp, flg);
		b.bp.gen = bp.gen;
		cacheins(b);
		return b;
	} exception e {
	"gefs:*" =>
		if(flg & GBtry)
			return nil;
		fs.rdonly = 1;
		raise e;
	}
}

blkfill(b: ref Blk): int
{
	case b.ty {
	Tpivot =>
		return 2*b.nbuf + b.bufsz + 2*b.nval + b.valsz;
	Tleaf =>
		return 2*b.nval + b.valsz;
	}
	broke(sys->sprint("invalid block @%bud", b.bp.addr));
	return 0;
}

#
# Frees: a block born in an older generation than the tree's is still
# in a snapshot, and goes on that tree's deadlist (killblk); one born
# in it is free when the request is done.
#
freeblk(t: ref Tree, b: ref Blk)
{
	if(t == fs.snap || (t != nil && b.bp.gen < t.memgen)){
		killblk(t, b.bp);
		return;
	}
	b.flag |= Blimbo;
	fs.pending = ref Pend(b.bp, b, nil, fs.pending);
}

freebp(t: ref Tree, bp: Bptr)
{
	if(t == fs.snap || (t != nil && bp.gen < t.memgen)){
		killblk(t, bp);
		return;
	}
	fs.pending = ref Pend(bp, nil, nil, fs.pending);
}

# a deadlist to free once this request is done
limbodl(dl: ref Dlist)
{
	fs.pending = ref Pend(Zb(), nil, dl, fs.pending);
}

#
# The end of a request: what it freed goes back to its arena, as
# 9front's epochclean then syncer do. Dead deadlists give back their
# blocks the same way.
#
quiesce()
{
	while((p := fs.pending) != nil){
		fs.pending = p.next;
		if(p.dl != nil){
			freedl(p.dl, 1);
			continue;
		}
		b := p.b;
		if(b == nil)
			b = cachepeek(p.bp.addr);
		if(b != nil)
			b.flag = (b.flag | Bfreed) & ~(Bdirty|Blimbo);
		blkdealloc_lk(getarena(p.bp.addr), p.bp.addr);
	}
}

#
# A block done with: written now (see the head of this file), and
# cached, as finished.
#
enqueue(b: ref Blk)
{
	bassert(b, (b.flag & (Bdirty|Bstatic)) == Bdirty, "enqueue: not dirty, or static");
	bassert(b, b.bp.addr >= big 0, "enqueue: no address");
	finalize(b);
	syncblk(b);
	if((b.flag & Bcached) == 0)
		cacheins(b);
}

#
# A tree's root after an update that fits in its buffer (fastupsert),
# which is most of them: the next update replaces it, and nothing points
# at it but the Tree in memory. So it is not hashed or written yet, only
# cached (a dirty block is never evicted), and one replaced in the
# meantime is freed having cost neither, where every write request used
# to hash and write a root as well as its data. It is still a fresh
# copy each time, never changed in place: a scan between requests holds
# blocks and needs them as they were.
#
# settle() hashes and writes it when something is to point at it: a
# snapshot or the superblock, packed by tree2kv and packsb, both before
# a commit's first flush.
#
deferblk(b: ref Blk)
{
	bassert(b, (b.flag & (Bdirty|Bstatic|Bfinal)) == Bdirty, "deferblk: not new");
	b.flag |= Bdefer;
	if((b.flag & Bcached) == 0)
		cacheins(b);
}

settle(t: ref Tree)
{
	b := cachepeek(t.bp.addr);
	if(b == nil || b.bp.gen != t.bp.gen)
		return;
	if(b.flag & Bdefer){
		b.flag &= ~Bdefer;
		enqueue(b);
	}
	if(b.flag & Bfinal)
		t.bp.hash = b.bp.hash;
}

# ---- the block cache ----

cacheslot(addr: big): int
{
	h := ihash(addr) % fs.cmax;
	if(h < 0)
		h = -h;
	return h;
}

lrudel(b: ref Blk)
{
	if(b == fs.chead)
		fs.chead = b.cnext;
	if(b == fs.ctail)
		fs.ctail = b.cprev;
	if(b.cnext != nil)
		b.cnext.cprev = b.cprev;
	if(b.cprev != nil)
		b.cprev.cnext = b.cnext;
	b.cnext = nil;
	b.cprev = nil;
}

lrutop(b: ref Blk)
{
	lrudel(b);
	if(fs.chead != nil)
		fs.chead.cprev = b;
	if(fs.ctail == nil)
		fs.ctail = b;
	b.cnext = fs.chead;
	fs.chead = b;
}

cacheins(b: ref Blk)
{
	if(b.flag & Bcached)
		return;
	h := cacheslot(b.bp.addr);
	b.flag |= Bcached;
	b.hnext = fs.bcache[h];
	fs.bcache[h] = b;
	fs.ccount++;
	lrutop(b);
	# forget the least recently used clean blocks over the limit
	for(c := fs.ctail; fs.ccount > fs.cmax && c != nil; ){
		p := c.cprev;
		if((c.flag & (Bdirty|Bstatic)) == 0)
			cachedel(c.bp.addr);
		c = p;
	}
}

cachedel(addr: big)
{
	if(addr == big -1)
		return;
	h := cacheslot(addr);
	prev: ref Blk;
	for(b := fs.bcache[h]; b != nil; b = b.hnext){
		if(b.bp.addr == addr){
			if(prev == nil)
				fs.bcache[h] = b.hnext;
			else
				prev.hnext = b.hnext;
			b.hnext = nil;
			b.flag &= ~Bcached;
			lrudel(b);
			fs.ccount--;
			return;
		}
		prev = b;
	}
}

# the cached block at addr, without touching the lru
cachepeek(addr: big): ref Blk
{
	for(b := fs.bcache[cacheslot(addr)]; b != nil; b = b.hnext)
		if(b.bp.addr == addr)
			return b;
	return nil;
}

cacheget(addr: big): ref Blk
{
	b := cachepeek(addr);
	if(b != nil)
		lrutop(b);
	return b;
}
