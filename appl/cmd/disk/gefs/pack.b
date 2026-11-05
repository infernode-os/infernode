#
# gefs: packing and unpacking, as 9front's pack.c. All numbers on disk
# are big-endian and byte-packed. Each pack function takes a buffer and
# an offset in it and returns the offset after what it wrote; each
# unpack, the value and the offset after it.
#

p8(b: array of byte, o: int, v: int): int
{
	b[o] = byte v;
	return o+1;
}

p16(b: array of byte, o: int, v: int): int
{
	b[o] = byte (v>>8);
	b[o+1] = byte v;
	return o+2;
}

p32(b: array of byte, o: int, v: int): int
{
	b[o] = byte (v>>24);
	b[o+1] = byte (v>>16);
	b[o+2] = byte (v>>8);
	b[o+3] = byte v;
	return o+4;
}

p64(b: array of byte, o: int, v: big): int
{
	for(i := 7; i >= 0; i--){
		b[o+i] = byte v;
		v = v >> 8;
	}
	return o+8;
}

g8(b: array of byte, o: int): int
{
	return int b[o];
}

g16(b: array of byte, o: int): int
{
	return (int b[o]<<8) | int b[o+1];
}

g32(b: array of byte, o: int): int
{
	return (int b[o]<<24) | (int b[o+1]<<16) | (int b[o+2]<<8) | int b[o+3];
}

g64(b: array of byte, o: int): big
{
	return (big g32(b, o) << 32) | (big g32(b, o+4) & big 16rFFFFFFFF);
}

#
# Strings: len[2] bytes[len] 0. The terminator is on disk for C's sake,
# and checked here as 9front checks it.
#
unpackstr(b: array of byte, o, e: int): (string, int)
{
	if(e - o < 3)
		broke(Efs+": unpackstr");
	n := g16(b, o);
	if(e - o < n + 3 || int b[o+n+2] != 0)
		broke(Efs+": unpackstr");
	return (string b[o+2:o+2+n], o+3+n);
}

packstr(b: array of byte, o, e: int, s: string): int
{
	a := array of byte s;
	n := len a;
	if(e - o < n+3)
		broke("packstr: no room");
	o = p16(b, o, n);
	b[o:] = a;
	o += n;
	b[o] = byte 0;
	return o+1;
}

# a directory entry: Kent pqid[8] name -> Xdir
dir2kv(up: big, d: ref Xdir): Kvp
{
	buf := array[Kvmax] of byte;
	ek := packdkey(buf, 0, len buf, up, d.name);
	ev := packdval(buf, ek, len buf, d);
	return Kvp(buf[0:ek], buf[ek:ev]);
}

# a directory entry's key. The name is always packed, the empty one
# too: in Limbo "" is nil, where the C tells them apart -- its nil, the
# prefix of a directory's scan, is packdpfx.
packdkey(b: array of byte, o, e: int, up: big, name: string): int
{
	o = p8(b, o, Kent);
	o = p64(b, o, up);
	return packstr(b, o, e, name);
}

packdpfx(b: array of byte, o: int, up: big): int
{
	o = p8(b, o, Kent);
	return p64(b, o, up);
}

unpackdkey(b: array of byte, o, e: int): (big, string)
{
	if(e - o <= 9 || g8(b, o) != Kent)
		broke(Efs+": unpackdkey");
	up := g64(b, o+1);
	(name, nil) := unpackstr(b, o+9, e);
	return (up, name);
}

packsuper(b: array of byte, o: int, up: big): int
{
	o = p8(b, o, Kup);
	return p64(b, o, up);
}

packdval(b: array of byte, o, e: int, d: ref Xdir): int
{
	if(e - o < Xdirsz)
		broke("packdval: no room");
	o = p64(b, o, d.flag);
	o = p64(b, o, d.qpath);
	o = p32(b, o, d.qvers);
	o = p8(b, o, d.qtype);
	o = p32(b, o, d.mode);
	o = p64(b, o, d.atime);
	o = p64(b, o, d.mtime);
	o = p64(b, o, d.length);
	o = p32(b, o, d.uid);
	o = p32(b, o, d.gid);
	o = p32(b, o, d.muid);
	return o;
}

kv2dir(kv: Kvp): ref Xdir
{
	if(len kv.k < 9 || len kv.v != Xdirsz)
		broke(Efs+": kv2dir");
	(name, nil) := unpackstr(kv.k, 9, len kv.k);
	v := kv.v;
	d := ref Xdir;
	d.flag = g64(v, 0);
	d.qpath = g64(v, 8);
	d.qvers = g32(v, 16);
	d.qtype = g8(v, 20);
	d.mode = g32(v, 21);
	d.atime = g64(v, 25);
	d.mtime = g64(v, 33);
	d.length = g64(v, 41);
	d.uid = g32(v, 49);
	d.gid = g32(v, 53);
	d.muid = g32(v, 57);
	d.name = name;
	return d;
}

fillxdir(qid: big, name: string, qtype, mode: int, length: big): ref Xdir
{
	return ref Xdir(big 0, qid, 0, qtype, mode, big 0, big 0, length, -1, -1, 0, name);
}

kv2dlist(kv: Kvp): ref Dlist
{
	if(len kv.k < Dlksz || len kv.v < Dlvsz)
		broke(Efs+": kv2dlist");
	dl := ref Dlist;
	dl.gen = g64(kv.k, 1);
	dl.bgen = g64(kv.k, 9);
	dl.head = unpackbp(kv.v, 0);
	dl.tail = unpackbp(kv.v, Ptrsz);
	return dl;
}

dlist2kv(dl: ref Dlist): Kvp
{
	b := array[Dlkvpsz] of byte;
	o := p8(b, 0, Kdlist);
	o = p64(b, o, dl.gen);
	o = p64(b, o, dl.bgen);
	ek := o;
	o = packbp(b, o, dl.head);
	o = packbp(b, o, dl.tail);
	return Kvp(b[0:ek], b[ek:o]);
}

tree2kv(t: ref Tree): Kvp
{
	b := array[Snapsz+Treesz] of byte;
	ek := packsnap(b, 0, t.gen);
	o := packtree(b, ek, t);
	return Kvp(b[0:ek], b[ek:o]);
}

retag2kv(gen, link: big, dlbl, dref: int): Kvp
{
	if(gen == big -1)
		broke("retag2kv: no gen");
	b := array[Snapsz+8+1+1] of byte;
	ek := packsnap(b, 0, gen);
	o := p64(b, ek, link);
	o = p8(b, o, dlbl);
	o = p8(b, o, dref);
	return Kvp(b[0:ek], b[ek:o]);
}

lbl2kv(lbl: string, gen: big, flg: int): Kvp
{
	a := array of byte lbl;
	b := array[1+len a + 1+8+4] of byte;
	o := p8(b, 0, Klabel);
	b[o:] = a;
	o += len a;
	ek := o;
	o = p8(b, o, Ksnap);
	o = p64(b, o, gen);
	o = p32(b, o, flg);
	return Kvp(b[0:ek], b[ek:o]);
}

packlbl(name: string): array of byte
{
	a := array of byte name;
	b := array[1+len a] of byte;
	b[0] = byte Klabel;
	b[1:] = a;
	return b;
}

packsnap(b: array of byte, o: int, id: big): int
{
	o = p8(b, o, Ksnap);
	return p64(b, o, id);
}

snapkey(id: big): array of byte
{
	b := array[Snapsz] of byte;
	packsnap(b, 0, id);
	return b;
}

packbp(b: array of byte, o: int, bp: Bptr): int
{
	o = p64(b, o, bp.addr);
	o = p64(b, o, bp.hash);
	return p64(b, o, bp.gen);
}

unpackbp(b: array of byte, o: int): Bptr
{
	return Bptr(g64(b, o), g64(b, o+8), g64(b, o+16));
}

unpacktree(b: array of byte, o: int): ref Tree
{
	if(len b - o < Treesz)
		broke(Efs+": unpacktree");
	t := ref Tree;
	t.nref = g32(b, o);
	t.nlbl = g32(b, o+4);
	t.ht = g32(b, o+8);
	t.flag = g32(b, o+12);
	t.gen = g64(b, o+16);
	t.pred = g64(b, o+24);
	t.succ = g64(b, o+32);
	t.base = g64(b, o+40);
	t.bp = Bptr(g64(b, o+48), g64(b, o+56), g64(b, o+64));
	return t;
}

packtree(b: array of byte, o: int, t: ref Tree): int
{
	o = p32(b, o, t.nref);
	o = p32(b, o, t.nlbl);
	o = p32(b, o, t.ht);
	o = p32(b, o, t.flag);
	o = p64(b, o, t.gen);
	o = p64(b, o, t.pred);
	o = p64(b, o, t.succ);
	o = p64(b, o, t.base);
	o = p64(b, o, t.bp.addr);
	o = p64(b, o, t.bp.hash);
	return p64(b, o, t.bp.gen);
}

packarena(b: array of byte, o: int, a: ref Arena): int
{
	o = p64(b, o, a.loghd.addr);	# the freelist
	o = p64(b, o, a.loghd.hash);
	o = p64(b, o, a.size);
	return p64(b, o, a.used);
}

unpackarena(a: ref Arena, b: array of byte, o: int): int
{
	a.loghd = Bptr(g64(b, o), g64(b, o+8), big -1);
	a.size = g64(b, o+16);
	a.used = g64(b, o+24);
	a.logtl = nil;
	return o+Arenasz;
}

# the superblock, and its hash after it
packsb(b: array of byte): int
{
	o := 0;
	b[o:] = array of byte Superver;
	o += 8;
	o = p32(b, o, Blksz);
	o = p32(b, o, Bufspc);
	o = p32(b, o, fs.narena);
	o = p32(b, o, fs.snap.ht);
	o = p64(b, o, fs.snap.bp.addr);
	o = p64(b, o, fs.snap.bp.hash);
	o = p64(b, o, fs.snapdl.head.addr);
	o = p64(b, o, fs.snapdl.head.hash);
	o = p64(b, o, fs.snapdl.tail.addr);
	o = p64(b, o, fs.snapdl.tail.hash);
	o = p64(b, o, fs.flag);
	o = p64(b, o, fs.nextqid);
	o = p64(b, o, fs.nextgen);
	o = p64(b, o, fs.qgen);
	for(i := 0; i < fs.narena; i++){
		o = p64(b, o, fs.arenabp[i].addr);
		o = p64(b, o, fs.arenabp[i].hash);
	}
	h := bufhash(b, o);
	return p64(b, o, h);
}

unpacksb(b: array of byte): int
{
	if(string b[0:8] != Superver)
		error(sys->sprint("%s %s", Efsvers, string b[0:8]));
	o := 8;
	fs.blksz = g32(b, o); o += 4;
	fs.bufspc = g32(b, o); o += 4;
	fs.narena = g32(b, o); o += 4;
	fs.snap.ht = g32(b, o); o += 4;
	fs.snap.bp = Bptr(g64(b, o), g64(b, o+8), big -1); o += 16;
	fs.snapdl.head = Bptr(g64(b, o), g64(b, o+8), big -1); o += 16;
	fs.snapdl.tail = Bptr(g64(b, o), g64(b, o+8), big -1); o += 16;
	fs.snapdl.gen = big -1;
	fs.flag = g64(b, o); o += 8;
	fs.nextqid = g64(b, o); o += 8;
	fs.nextgen = g64(b, o); o += 8;
	fs.qgen = g64(b, o); o += 8;
	if(fs.narena <= 0 || fs.narena >= 256)
		error(sys->sprint("corrupt superblock: %d arenas", fs.narena));
	fs.arenabp = array[fs.narena] of Bptr;
	for(i := 0; i < fs.narena; i++){
		fs.arenabp[i] = Bptr(g64(b, o), g64(b, o+8), big -1);
		o += 16;
	}
	xh := bufhash(b, o);
	dh := g64(b, o);
	if(dh != xh)
		error(sys->sprint("corrupt superblock: %bux != %bux", dh, xh));
	return o+8;
}
