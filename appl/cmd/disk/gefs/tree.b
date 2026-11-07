#
# gefs: the Bε tree, as 9front's tree.c, function for function.
#
# A block's values and messages are read as slices of its buffer, as
# the C reads them through pointers; cpkvp() is the copy. The C's
# holdblk/dropblk counts are not here: the garbage collector keeps a
# block alive while anything refers to it. freeblk/freebp keep their
# disk meaning -- the space goes back, or onto a deadlist.
#

POmod, POrot, POsplit, POmerge: con iota;

Path: adt {
	# flowing down for flush
	ins:	array of Msg;	# inserted values, bounded by lo..hi
	b:	ref Blk;	# to shadow
	s:	ref Blk;	# sibling of shadow, for merge/rotate
	idx:	int;	# insert at
	lo:	int;
	hi:	int;
	sz:	int;	# size of range
	# flowing up from flush
	op:	int;
	nl:	ref Blk;	# new left
	nr:	ref Blk;	# new right, if we split or rotated
	midx:	int;	# modification index
	npull:	int;	# messages pulled
	pullsz:	int;	# their size
};

newpath(): ref Path
{
	return ref Path(nil, nil, nil, 0, 0, 0, 0, 0, nil, nil, 0, 0, 0);
}

keycmp(a, b: array of byte): int
{
	n := len a;
	if(len b < n)
		n = len b;
	for(i := 0; i < n; i++)
		if(a[i] != b[i]){
			if(int a[i] < int b[i])
				return -1;
			return 1;
		}
	if(len a < len b)
		return -1;
	if(len a > len b)
		return 1;
	return 0;
}

hasprefix(k, pfx: array of byte): int
{
	if(len k < len pfx)
		return 0;
	for(i := 0; i < len pfx; i++)
		if(k[i] != pfx[i])
			return 0;
	return 1;
}

dup(a: array of byte): array of byte
{
	b := array[len a] of byte;
	b[0:] = a;
	return b;
}

# a private copy of a key and value, as cpkvp
cpkvp(k, v: array of byte): ref Kvp
{
	return ref Kvp(dup(k), dup(v));
}

stablesort(m: array of Msg)
{
	for(i := 1; i < len m; i++)
		for(j := i; j > 0; j--){
			if(keycmp(m[j-1].k, m[j].k) <= 0)
				break;
			t := m[j-1];
			m[j-1] = m[j];
			m[j] = t;
		}
}

msgsz(m: Msg): int
{
	# disp + op + klen + key + vlen + v
	return 2+1+2+len m.k +2+ len m.v;
}

valsz(k, v: array of byte): int
{
	return 2 + 2+len k + 2+len v;
}

getval(b: ref Blk, i: int): Kvp
{
	bassert(b, i >= 0 && i < b.nval, "getval index");
	o := g16(b.data, 2*i);
	nk := g16(b.data, o);
	k := b.data[o+2:o+2+nk];
	o += 2+nk;
	nv := g16(b.data, o);
	return Kvp(k, b.data[o+2:o+2+nv]);
}

getptr(kv: Kvp): (Bptr, int)
{
	if(len kv.v != Ptrsz+2)
		broke(Efs+": getptr");
	return (unpackbp(kv.v, 0), g16(kv.v, Ptrsz));
}

setval(b: ref Blk, k, v: array of byte)
{
	spc := Pivspc;
	if(b.ty == Tleaf)
		spc = Leafspc;
	b.valsz += 2 + len k + 2 + len v;
	off := spc - b.valsz;
	if(len k > 0 && int k[0] == Kent && len v == 0)
		broke("setval: empty entry");
	bassert(b, 2*(b.nval+1) + b.valsz <= spc, "setval room");
	bassert(b, 2*(b.nval+1) <= off, "setval offset");
	p16(b.data, 2*b.nval, off);
	o := p16(b.data, off, len k);
	b.data[o:] = k;
	o += len k;
	o = p16(b.data, o, len v);
	b.data[o:] = v;
	b.nval++;
}

setptr(b: ref Blk, k: array of byte, bp: Bptr, fill: int)
{
	v := array[Ptrsz+2] of byte;
	o := packbp(v, 0, bp);
	p16(v, o, fill);
	setval(b, k, v);
}

setmsg(b: ref Blk, m: Msg)
{
	bassert(b, b.ty == Tpivot, "setmsg type");
	b.bufsz += msgsz(m)-2;
	bassert(b, 2*(b.nbuf+1) + b.bufsz <= Bufspc, "setmsg room");
	o := Bufspc - b.bufsz;
	p16(b.data, Pivspc + 2*b.nbuf, o);
	p := Pivspc + o;
	b.data[p++] = byte m.op;
	p = p16(b.data, p, len m.k);
	b.data[p:] = m.k;
	p += len m.k;
	p = p16(b.data, p, len m.v);
	b.data[p:] = m.v;
	b.nbuf++;
}

getmsg(b: ref Blk, i: int): Msg
{
	bassert(b, b.ty == Tpivot, "getmsg type");
	bassert(b, i >= 0 && i < b.nbuf, "getmsg index");
	o := g16(b.data, Pivspc + 2*i);
	p := Pivspc + o;
	op := int b.data[p++];
	nk := g16(b.data, p);
	p += 2;
	k := b.data[p:p+nk];
	p += nk;
	nv := g16(b.data, p);
	p += 2;
	return Msg(op, k, b.data[p:p+nv]);
}

# the first message for k, or the last before it: (index, same)
bufsearch(b: ref Blk, k: array of byte): (int, int)
{
	ri := -1;
	lo := 0;
	hi := b.nbuf-1;
	while(lo <= hi){
		mid := (hi + lo) / 2;
		cmp := getmsg(b, mid);
		case keycmp(k, cmp.k) {
		-1 =>	hi = mid-1;
		0 =>	ri = mid; hi = mid-1;
		1 =>	lo = mid+1;
		}
	}
	if(ri == -1)
		return (lo-1, 0);
	return (ri, 1);
}

blksearch(b: ref Blk, k: array of byte): (int, int)
{
	ri := -1;
	lo := 0;
	hi := b.nval-1;
	while(lo <= hi){
		mid := (hi + lo) / 2;
		cmp := getval(b, mid);
		case keycmp(k, cmp.k) {
		-1 =>	hi = mid-1;
		0 =>	ri = mid; hi = mid-1;
		1 =>	lo = mid+1;
		}
	}
	if(ri == -1)
		return (lo-1, 0);
	return (ri, 1);
}

buffill(b: ref Blk): int
{
	return 2*b.nbuf + b.bufsz;
}

filledbuf(b: ref Blk, nmsg, needed: int): int
{
	return 2*(b.nbuf+nmsg) + b.bufsz + needed > Bufspc;
}

filledleaf(b: ref Blk, needed: int): int
{
	return 2*(b.nval+1) + b.valsz + needed > Leafspc;
}

filledpiv(b: ref Blk, reserve: int): int
{
	# room for one message at all times, so that splits along the
	# whole path have somewhere to go as they propagate up
	return 2*(b.nval+1) + b.valsz + reserve*(8+Keymax+Ptrsz) > Pivspc;
}

# the first key of a child -- its first value's, or its first message's if
# earlier -- and the length of that first value, for the C's valsz()
firstkey(c: ref Blk): (array of byte, int)
{
	kv := getval(c, 0);
	k := kv.k;
	if(c.nbuf > 0){
		m := getmsg(c, 0);
		if(keycmp(k, m.k) > 0)
			k = m.k;
	}
	return (k, len kv.v);
}

copyup(n: ref Blk, pp: ref Path): int
{
	nbytes := 0;
	# the previous node may have been emptied by deletes
	if(pp.nl != nil){
		(k, nv) := firstkey(pp.nl);
		setptr(n, k, pp.nl.bp, blkfill(pp.nl));
		nbytes += 2 + 2+len k + 2+nv;
	}
	if(pp.nr != nil){
		(k, nv) := firstkey(pp.nr);
		setptr(n, k, pp.nr.bp, blkfill(pp.nr));
		nbytes += 2 + 2+len k + 2+nv;
	}
	return nbytes;
}

statupdate(kv: ref Kvp, m: Msg)
{
	if(len m.v < 1)
		broke("statupdate: empty");
	p := 0;
	op := int m.v[p++];
	d := kv2dir(*kv);
	d.qvers++;	# bump the version
	if(op & Owsize){
		d.length = g64(m.v, p);
		p += 8;
	}
	if(op & Owmode){
		d.mode = g32(m.v, p);
		d.qtype = (d.mode>>24) & 16rFF;
		p += 4;
	}
	if(op & Owmtime){
		d.mtime = g64(m.v, p);
		p += 8;
	}
	if(op & Owatime){
		d.atime = g64(m.v, p);
		p += 8;
	}
	if(op & Owuid){
		d.uid = g32(m.v, p);
		p += 4;
	}
	if(op & Owgid){
		d.gid = g32(m.v, p);
		p += 4;
	}
	if(op & Owmuid){
		d.muid = g32(m.v, p);
		p += 4;
	}
	if(op & Owqpath){
		d.qpath = g64(m.v, p);
		p += 8;
	}
	if(p != len m.v)
		broke("malformed stat message");
	if(packdval(kv.v, 0, len kv.v, d) != len kv.v)
		broke("repacking dir failed");
}

# apply m to kv, a private copy; 1 if a value remains
apply(kv: ref Kvp, m: Msg): int
{
	case m.op {
	Odelete =>
		if(keycmp(kv.k, m.k) != 0)
			broke("apply: delete of another key");
		return 0;
	Oclearb or Oclobber =>
		return 0;
	Oinsert =>
		kv.k = dup(m.k);
		kv.v = dup(m.v);
		return 1;
	Owstat =>
		if(keycmp(kv.k, m.k) != 0)
			broke("apply: wstat of another key");
		statupdate(kv, m);
		return 1;
	Orelink or Oreprev or Oincref =>
		t := unpacktree(kv.v, 0);
		p := 0;
		if(m.op == Orelink)
			t.succ = g64(m.v, p);
		else if(m.op == Oreprev)
			t.pred = g64(m.v, p);
		p += 8;
		t.nlbl += sbyte(m.v[p++]);
		t.nref += sbyte(m.v[p++]);
		if(t.nlbl < 0 || t.nref < 0 || p != len m.v)
			broke("apply: bad tree message");
		packtree(kv.v, 0, t);
		return 1;
	}
	broke(sys->sprint("invalid op %d", m.op));
	return 0;
}

# a byte as the signed char the C adds
sbyte(b: byte): int
{
	v := int b;
	if(v >= 128)
		v -= 256;
	return v;
}

setb(dst: ref Blk, t: ref Tree, b: ref Blk): ref Blk
{
	if(dst != nil)
		freeblk(t, dst);
	if(b.nval == 0){
		freeblk(t, b);
		return nil;
	}
	enqueue(b);
	return b;
}

# the j'th message pulled down: (cmp, full, msg)
pullmsg(p: ref Path, i: int, v: array of byte, full, spc: int): (int, int, Msg)
{
	m: Msg;
	if(i < 0 || i >= p.hi || full)
		return (-1, full, m);
	if(p.ins != nil)
		m = p.ins[i];
	else
		m = getmsg(p.b, i);
	if(msgsz(m) <= spc){
		if(v == nil)
			return (0, full, m);
		return (keycmp(v, m.k), full, m);
	}
	return (-1, 1, m);
}

isfreeing(v: ref Kvp, m: Msg): int
{
	return len v.k > 0 && int v.k[0] == Kdat
		&& (m.op == Oclearb || m.op == Oinsert || m.op == Odelete);
}

#
# The merge of a leaf's values with the messages coming down to it,
# into d: updateleaf and splitleaf share it. Returns (i, j, spc, full).
#
leafmerge(t: ref Tree, up, p: ref Path, i, j: int, d: ref Blk, spc, full: int, copied: array of int): (int, int, int, int)
{
	b := p.b;
	v := getval(b, i);
	(c, nfull, m) := pullmsg(up, j, v.k, full, spc);
	full = nfull;
	case c {
	-1 =>
		# value before message: copy the value
		setval(d, v.k, v.v);
		if(copied != nil)
			copied[0] += valsz(v.k, v.v);
		return (i+1, j, spc, full);
	0 =>
		# value merges with the message sequence
		w := cpkvp(v.k, v.v);
		if(copied != nil)
			copied[0] += valsz(w.k, w.v);
		if(isfreeing(w, m))
			freebp(t, unpackbp(w.v, 0));
		ok := apply(w, m);
		(j, spc, full) = copyloop(t, up, p, w, ok, j+1, spc, full, d);
		return (i+1, j, spc, full);
	* =>
		broke("leafmerge: impossible");
	}
	return (i, j, spc, full);
}

# message before any value: insert the message sequence
leafinsert(up, p: ref Path, j: int, spc, full: int, m: Msg, d: ref Blk, t: ref Tree, copied: array of int): (int, int, int)
{
	w := cpkvp(m.k, m.v);
	if(copied != nil)
		copied[0] += valsz(w.k, w.v);
	ok := 0;
	if(m.op != Oclearb && m.op != Oclobber){
		# new keys start with Oinsert
		if(m.op != Oinsert)
			broke(Efs+": broken entry");
		spc -= valsz(m.k, m.v);
		p.pullsz += msgsz(m);
		ok = 1;
	}
	return copyloop(t, up, p, w, ok, j+1, spc, full, d);
}

copyloop(t: ref Tree, up, p: ref Path, w: ref Kvp, ok, j, spc, full: int, d: ref Blk): (int, int, int)
{
	while(j < up.hi){
		(c, nfull, m) := pullmsg(up, j, w.k, full, spc);
		full = nfull;
		if(c != 0)
			break;
		if(ok && isfreeing(w, m))
			freebp(t, unpackbp(w.v, 0));
		p.pullsz += msgsz(m);
		ok = apply(w, m);
		j++;
	}
	if(ok)
		setval(d, w.k, w.v);
	return (j, spc, full);
}

#
# A new block with the old one's contents, repacked, and the changes
# pending from above applied.
#
updateleaf(t: ref Tree, up, p: ref Path)
{
	i := 0;
	j := up.lo;
	b := p.b;
	# the room there is to copy down from the parent; conservative,
	# because deletes take none, but their kinds are not known yet
	full := 0;
	spc := Leafspc - blkfill(b);
	n := newblk(t, b.ty);
	while(i < b.nval || j < up.hi){
		c: int;
		m: Msg;
		if(i >= b.nval){
			# only messages left: the one at j, which the C has
			# from the lookahead of the iteration before
			c = 1;
			if(up.ins != nil)
				m = up.ins[j];
			else
				m = getmsg(up.b, j);
		}else{
			c = -1;
			v := getval(b, i);
			if(j < up.hi){
				if(up.ins != nil)
					m = up.ins[j];
				else
					m = getmsg(up.b, j);
				if(msgsz(m) <= spc)
					c = keycmp(v.k, m.k);
				else
					full = 1;
			}
		}
		case c {
		-1 or 0 =>
			(i, j, spc, full) = leafmerge(t, up, p, i, j, n, spc, full, nil);
		1 =>
			(j, spc, full) = leafinsert(up, p, j, spc, full, m, n, t, nil);
		}
	}
	p.npull = j - up.lo;
	p.op = POmod;
	p.nl = setb(p.nl, t, n);
}

updatepiv(t: ref Tree, up, p, pp: ref Path)
{
	b := p.b;
	n := newblk(t, b.ty);
	for(i := 0; i < b.nval; i++){
		if(pp != nil && i == p.midx){
			copyup(n, pp);
			if(pp.op == POrot || pp.op == POmerge)
				i++;
		}else{
			m := getval(b, i);
			setval(n, m.k, m.v);
		}
	}
	i = 0;
	j := up.lo;
	sz := 0;
	full := 0;
	# the room for messages from the parent: what we have, plus what
	# our child pulled down from us
	spc := Bufspc - buffill(b);
	if(pp != nil)
		spc += pp.pullsz;
	while(i < b.nbuf){
		if(i == p.lo)
			i += pp.npull;
		if(i == b.nbuf)
			break;
		m := getmsg(b, i);
		# full here means out of room for new messages, not done
		(r, nfull, u) := pullmsg(up, j, m.k, full, spc - sz);
		full = nfull;
		case r {
		-1 or 0 =>
			setmsg(n, m);
			i++;
		1 =>
			mk := dup(u.k);
			for(;;){
				(r2, nf2, u2) := pullmsg(up, j, mk, full, spc);
				full = nf2;
				if(r2 != 0)
					break;
				setmsg(n, u2);
				sz = msgsz(u2);
				p.pullsz += sz;
				spc -= sz;
				j++;
			}
		}
	}
	while(j < up.hi){
		(nil, nfull, u) := pullmsg(up, j, nil, full, spc);
		full = nfull;
		if(full)
			break;
		setmsg(n, u);
		sz = msgsz(u);
		p.pullsz += sz;
		spc -= sz;
		j++;
	}
	p.npull = j - up.lo;
	p.op = POmod;
	p.nl = setb(p.nl, t, n);
}

#
# Splits a leaf. A split never grows the tree by more than one.
#
splitleaf(t: ref Tree, up, p: ref Path)
{
	b := p.b;
	l := newblk(t, b.ty);
	r := newblk(t, b.ty);
	{
		d := l;
		i := 0;
		j := up.lo;
		full := 0;
		copied := array[1] of {0};
		halfsz := (2*b.nval + b.valsz + up.sz) / 2;
		if(halfsz > Leafspc/2)
			halfsz = Leafspc/2;
		spc := Leafspc - (halfsz + Msgmax);
		bassert(b, b.nval >= 4, "splitleaf nval");
		while(i < b.nval){
			# balance by size, but at least 2 values in each half
			if(d == l)
			if(i == b.nval-2 || (i >= 2 && copied[0] >= halfsz)){
				d = r;
				spc = Leafspc - (halfsz + Msgmax);
			}
			v := getval(b, i);
			(c, nil, m) := pullmsg(up, j, v.k, full, spc);
			case c {
			-1 or 0 =>
				(i, j, spc, full) = leafmerge(t, up, p, i, j, d, spc, full, copied);
			1 =>
				(j, spc, full) = leafinsert(up, p, j, spc, full, m, d, t, copied);
			}
		}
		p.npull = j - up.lo;
		p.op = POsplit;
		p.nl = setb(p.nl, t, l);
		p.nr = setb(p.nr, t, r);
	} exception e {
	"*" =>
		freeblk(t, l);
		freeblk(t, r);
		raise e;
	}
}

splitpiv(t: ref Tree, nil: ref Path, p, pp: ref Path)
{
	b := p.b;
	l := newblk(t, b.ty);
	r := newblk(t, b.ty);
	{
		d := l;
		copied := 0;
		halfsz := (2*b.nval + b.valsz)/2;
		bassert(b, b.nval >= 4, "splitpiv nval");
		for(i := 0; i < b.nval; i++){
			# balance by size, but at least 2 nodes in each half
			if(d == l && (i == b.nval-2 || (i >= 2 && copied >= halfsz)))
				d = r;
			if(i == p.idx){
				copied += copyup(d, pp);
				continue;
			}
			tk := getval(b, i);
			setval(d, tk.k, tk.v);
			copied += valsz(tk.k, tk.v);
		}
		d = l;
		mid := getval(r, 0);
		for(i = 0; i < b.nbuf; i++){
			if(i == p.lo)
				i += pp.npull;
			if(i == b.nbuf)
				break;
			m := getmsg(b, i);
			if(d == l && keycmp(m.k, mid.k) >= 0)
				d = r;
			setmsg(d, m);
		}
		p.op = POsplit;
		p.nl = setb(p.nl, t, l);
		p.nr = setb(p.nr, t, r);
	} exception e {
	"*" =>
		freeblk(t, l);
		freeblk(t, r);
		raise e;
	}
}

merge(t: ref Tree, p, pp: ref Path, idx: int, a, b: ref Blk)
{
	d := newblk(t, a.ty);
	for(i := 0; i < a.nval; i++){
		m := getval(a, i);
		setval(d, m.k, m.v);
	}
	for(i = 0; i < b.nval; i++){
		m := getval(b, i);
		setval(d, m.k, m.v);
	}
	if(a.ty == Tpivot){
		for(i = 0; i < a.nbuf; i++)
			setmsg(d, getmsg(a, i));
		for(i = 0; i < b.nbuf; i++)
			setmsg(d, getmsg(b, i));
	}
	p.midx = idx;
	pp.op = POmerge;
	pp.nl = setb(pp.nl, t, d);
}

# the first message in l's and r's buffers with key >= k
splitidx(l, r: ref Blk, k: array of byte, idx: int): int
{
	if(l.ty == Tleaf)
		return idx;
	i: int;
	for(i = idx; i < l.nbuf + r.nbuf; i++){
		n: Msg;
		if(i < l.nbuf)
			n = getmsg(l, i);
		else
			n = getmsg(r, i - l.nbuf);
		if(keycmp(k, n.k) <= 0)
			break;
	}
	return i;
}

rotate(t: ref Tree, p, pp: ref Path, midx: int, a, b: ref Blk, halfpiv: int)
{
	l := newblk(t, a.ty);
	r := newblk(t, a.ty);
	{
		d := l;
		sz := 0;
		sp := 0;
		for(i := 0; i < a.nval; i++){
			m := getval(a, i);
			if(d == l){
				sp = splitidx(a, b, m.k, sp);
				if(sz >= halfpiv)
					d = r;
			}
			setval(d, m.k, m.v);
			sz += valsz(m.k, m.v);
		}
		for(i = 0; i < b.nval; i++){
			m := getval(b, i);
			if(d == l){
				sp = splitidx(a, b, m.k, sp);
				if(sz >= halfpiv)
					d = r;
			}
			setval(d, m.k, m.v);
			sz += valsz(m.k, m.v);
		}
		if(a.ty == Tpivot){
			d = l;
			o := 0;
			for(i = 0; i < a.nbuf; i++){
				if(o == sp){
					d = r;
					o = 0;
				}
				setmsg(d, getmsg(a, i));
				o++;
			}
			for(i = 0; i < b.nbuf; i++){
				if(o == sp){
					d = r;
					o = 0;
				}
				setmsg(d, getmsg(b, i));
				o++;
			}
		}
		p.midx = midx;
		pp.op = POrot;
		pp.nl = setb(pp.nl, t, l);
		pp.nr = setb(pp.nr, t, r);
	} exception e {
	"*" =>
		freeblk(t, l);
		freeblk(t, r);
		raise e;
	}
}

rotmerge(t: ref Tree, p, pp: ref Path, idx: int, a, b: ref Blk): int
{
	bassert(a, a.ty == b.ty, "rotmerge types");
	na := 2*a.nval + a.valsz;
	nb := 2*b.nval + b.valsz;
	ma := 0;
	mb := 0;
	if(a.ty != Tleaf){
		ma = 2*a.nbuf + a.bufsz;
		mb = 2*b.nbuf + b.bufsz;
	}
	imbalance := na - nb;
	if(imbalance < 0)
		imbalance = -imbalance;
	# works for a leaf, because 0 is always < Bufspc
	if(na + nb < (Pivspc - 4*Msgmax) && ma + mb < Bufspc){
		merge(t, p, pp, idx, a, b);
		return 1;
	}else if(imbalance > 4*Msgmax){
		rotate(t, p, pp, idx, a, b, (na + nb)/2);
		return 1;
	}
	return 0;
}

trybalance(t: ref Tree, p, pp: ref Path, idx: int)
{
	if(p.idx == -1 || pp == nil || pp.nl == nil)
		return;
	if(pp.op != POmod && pp.op != POmerge)
		return;
	m := pp.nl;
	spc := Pivspc;
	if(m.ty == Tleaf)
		spc = Leafspc;
	if(idx-1 >= 0){
		kl := getval(p.b, idx-1);
		(bp, fill) := getptr(kl);
		if(fill + blkfill(m) < spc){
			l := getblk(bp, 0);
			if(rotmerge(t, p, pp, idx-1, l, m))
				p.s = l;
			return;
		}
	}
	if(idx+1 < p.b.nval){
		kr := getval(p.b, idx+1);
		(bp, fill) := getptr(kr);
		if(fill + blkfill(m) < spc){
			r := getblk(bp, 0);
			if(rotmerge(t, p, pp, idx, m, r))
				p.s = r;
			return;
		}
	}
}

flush(t: ref Tree, path: array of ref Path, npath: int): ref Path
{
	# at least two: the node inserted into, and an empty element at
	# the top for a new root, if the root splits
	fsassert(npath >= 2, "flush: short path");
	rp: ref Path;
	pp: ref Path;
	pi := npath-1;
	p := path[pi];
	up := path[pi-1];
	if(p.b.ty == Tleaf){
		if(!filledleaf(p.b, up.sz)){
			updateleaf(t, path[pi-1], p);
			rp = p;
		}else
			splitleaf(t, up, p);
		p.midx = -1;
		pp = p;
		pi--;
		p = path[pi];
		up = nil;
		if(pi > 0)
			up = path[pi-1];
	}
	while(pi > 0){
		# we add at most one key, but children can grow: split early
		if(!filledpiv(p.b, 2)){
			trybalance(t, p, pp, p.idx);
			#
			# A merged root with an empty buffer is done; if its
			# buffer still has data, pull it down and leave a
			# degenerate root for btupsert to retry. A cleared
			# degenerate root drops out of the tree.
			#
			if(pi == 1 && pp != nil && pp.nl != nil && pp.nr == nil && pp.npull == p.b.nbuf)
			if((pp.op == POmerge && p.b.nval == 2) || (pp.op == POmod && p.b.nval == 1)){
				pp.npull = p.npull;
				return pp;
			}
			updatepiv(t, up, p, pp);
			rp = p;
		}else
			splitpiv(t, up, p, pp);
		pp = p;
		pi--;
		p = path[pi];
		up = nil;
		if(pi > 0)
			up = path[pi-1];
	}
	if(pp.nl != nil && pp.nr != nil){
		rp = path[0];
		rp.nl = newblk(t, Tpivot);
		rp.npull = pp.npull;
		rp.pullsz = pp.pullsz;
		copyup(rp.nl, pp);
		enqueue(rp.nl);
	}
	return rp;
}

freepath(t: ref Tree, path: array of ref Path, npath, ok: int)
{
	if(!ok)
		return;
	for(i := 0; i < npath; i++){
		p := path[i];
		if(p.b != nil)
			freeblk(t, p.b);
		if(p.s != nil)
			freeblk(t, p.s);
	}
}

# the child with the most messages waiting for it in b's buffer
victim(b: ref Blk, p: ref Path)
{
	j := 0;
	maxsz := 0;
	p.b = b;
	# from the second pivot: all values <= it go to the first node;
	# to after the last entry: all >= it go into that one
	for(i := 1; i <= b.nval; i++){
		kv: Kvp;
		if(i < b.nval)
			kv = getval(b, i);
		cursz := 0;
		lo := j;
		for(; j < b.nbuf; j++){
			m := getmsg(b, j);
			if(i < b.nval && keycmp(m.k, kv.k) >= 0)
				break;
			cursz += msgsz(m);
		}
		if(cursz > maxsz){
			maxsz = cursz;
			p.op = POmod;
			p.lo = lo;
			p.hi = j;
			p.sz = maxsz;
			p.idx = i - 1;
			p.midx = i - 1;
			p.npull = 0;
			p.pullsz = 0;
		}
	}
}

fastupsert(t: ref Tree, b: ref Blk, msg: array of Msg)
{
	r := dupblk(t, b);
	nbuf := r.nbuf;
	for(i := 0; i < len msg; i++)
		setmsg(r, msg[i]);
	for(i = 0; i < len msg; i++){
		ri := -1;
		lo := 0;
		hi := nbuf+i-1;
		while(lo <= hi){
			mid := (hi + lo) / 2;
			cmp := getmsg(r, mid);
			case keycmp(msg[i].k, cmp.k) {
			-1 =>	hi = mid-1;
			0 =>	ri = mid+1; lo = mid+1;
			1 =>	lo = mid+1;
			}
		}
		if(ri == -1)
			ri = hi+1;
		o := g16(r.data, Pivspc + 2*(nbuf+i));
		s := Pivspc + 2*ri;
		n := 2*(nbuf+i-ri);
		for(k := n-1; k >= 0; k--)
			r.data[s+2+k] = r.data[s+k];
		p16(r.data, s, o);
	}
	deferblk(r);
	t.bp = r.bp;
	t.dirty = 1;
	freeblk(t, b);
}

btupsert(t: ref Tree, msg: array of Msg)
{
	sz := 0;
	stablesort(msg);
	for(i := 0; i < len msg; i++){
		if(len msg[i].k > Keymax || len msg[i].v > Inlmax)
			broke("btupsert: message too big");
		sz += msgsz(msg[i]);
	}
	npull := 0;
	for(;;){
		(b, height) := getroot(t);
		if(height+1 >= Maxheight)
			error(Eheight);
		if(npull == 0 && b.ty == Tpivot && b.nval > 1 && !filledbuf(b, len msg, sz)){
			fastupsert(t, b, msg);
			return;
		}
		# the tree can grow by one when the root splits
		path := array[height+2] of ref Path;
		for(i = 0; i < len path; i++)
			path[i] = newpath();
		degen := 0;
		npath := 0;
		path[npath].idx = -1;
		path[npath].midx = -1;
		npath++;
		path[0].sz = sz;
		path[0].ins = msg;
		path[0].lo = npull;
		path[0].hi = len msg;
		while(b.ty == Tpivot){
			if(b.nval > 1 && !filledbuf(b, len msg, path[npath-1].sz))
				break;
			victim(b, path[npath]);
			sep := getval(b, path[npath].idx);
			b = getblk(unpackbp(sep.v, 0), 0);
			npath++;
			fsassert(npath < height+2, "btupsert: path too long");
		}
		path[npath].b = b;
		path[npath].idx = -1;
		path[npath].midx = -1;
		path[npath].lo = -1;
		path[npath].hi = -1;
		npath++;

		rp := flush(t, path, npath);
		rb := rp.nl;
		dh: int;
		if(path[0].nl != nil)
			dh = 1;
		else if(path[1].nl != nil)
			dh = 0;
		else if(npath > 2 && path[2].nl != nil)
			dh = -1;
		else
			broke("broken path change");
		# a merged root with data still in its buffer: clear it out
		if(rb.ty == Tpivot && rb.nval == 1)
			degen = 1;
		bassert(rb, rb.bp.addr != big 0, "setroot at 0");
		t.ht += dh;
		t.bp = rb.bp;
		t.dirty = 1;
		npull += rp.npull;
		freepath(t, path, npath, 1);
		if(npull == len msg && !degen)
			return;
	}
}

getroot(t: ref Tree): (ref Blk, int)
{
	fsassert(t.ht < Maxheight, "getroot: height");
	b := getblk(t.bp, 0);
	if((t.ht == 1 && b.ty != Tleaf) || (t.ht > 1 && b.ty != Tpivot))
		broke("getroot: invalid root block type");
	return (b, t.ht);
}

# the value at k, with every message pending for it applied
btlookup(t: ref Tree, k: array of byte): ref Kvp
{
	(b, h) := getroot(t);
	p := array[h] of ref Blk;
	p[0] = b;
	r: Kvp;
	for(i := 1; i < h; i++){
		(ri, nil) := blksearch(p[i-1], k);
		if(ri == -1)
			break;
		r = getval(p[i-1], ri);
		p[i] = getblk(unpackbp(r.v, 0), 0);
	}
	ok := 0;
	kv: ref Kvp;
	if(p[h-1] != nil){
		(ri, same) := blksearch(p[h-1], k);
		ok = same;
		if(ok){
			r = getval(p[h-1], ri);
			kv = cpkvp(r.k, r.v);
		}
	}
	if(kv == nil)
		kv = ref Kvp(nil, nil);
	for(i = h-2; i >= 0; i--){
		if(p[i] == nil)
			continue;
		(j, same) := bufsearch(p[i], k);
		if(j < 0 || !same)
			continue;
		m := getmsg(p[i], j);
		if(ok || m.op == Oinsert)
			ok = apply(kv, m);
		else if(m.op != Oclearb && m.op != Oclobber)
			broke("lookup: message missing insert");
		for(j++; j < p[i].nbuf; j++){
			m = getmsg(p[i], j);
			if(keycmp(k, m.k) != 0)
				break;
			ok = apply(kv, m);
		}
	}
	if(!ok)
		return nil;
	return kv;
}

Scanp: adt {
	bi:	int;
	vi:	int;
	b:	ref Blk;
};

Scan: adt {
	offset:	big;	# last read offset
	first:	int;
	donescan: int;
	overflow: int;
	present: int;
	ht:	int;
	kv:	ref Kvp;
	pfx:	array of byte;
	path:	array of Scanp;
};

btnewscan(pfx: array of byte): ref Scan
{
	s := ref Scan;
	s.first = 1;
	s.donescan = 0;
	s.offset = big 0;
	s.pfx = dup(pfx);
	s.kv = ref Kvp(dup(pfx), array[0] of byte);
	s.path = array[Maxheight] of Scanp;
	return s;
}

btenter(t: ref Tree, s: ref Scan)
{
	if(s.donescan)
		return;
	b: ref Blk;
	(b, s.ht) = getroot(t);
	p := s.path;
	p[0].b = b;
	for(i := 0; i < s.ht; i++){
		same: int;
		(p[i].vi, same) = blksearch(b, s.kv.k);
		if(b.ty == Tpivot){
			if(p[i].vi == -1)
				++p[i].vi;
			v := getval(b, p[i].vi);
			(bi, bsame) := bufsearch(b, s.kv.k);
			p[i].bi = bi;
			if(bi == -1)
				p[i].bi++;
			else if(!bsame || !s.first){
				# scan past repeated messages
				m := getmsg(b, bi);
				while(p[i].bi < p[i].b.nbuf){
					c := getmsg(p[i].b, p[i].bi);
					if(keycmp(m.k, c.k) != 0)
						break;
					p[i].bi++;
				}
			}
			b = getblk(unpackbp(v.v, 0), 0);
			p[i+1].b = b;
		}else if(p[i].vi == -1 || !same || !s.first)
			p[i].vi++;
	}
	s.first = 0;
}

btnext(s: ref Scan): ref Kvp
{
	for(;;){
		p := s.path;
		h := s.ht;
		start := h;
		bufsrc := -1;
		if(s.ht == 0 || s.donescan)
			return nil;
		# load up the right blocks for the scan
		for(i := h-1; i >= 0; i--){
			if(p[i].b != nil && (p[i].vi < p[i].b.nval || p[i].bi < p[i].b.nbuf))
				break;
			if(i == 0){
				s.donescan = 1;
				return nil;
			}
			p[i].b = nil;
			p[i].vi = 0;
			p[i].bi = 0;
			p[i-1].vi++;
			start = i;
		}
		ok: int;
		m: Msg;
		if(p[start-1].vi < p[start-1].b.nval){
			for(i = start; i < h; i++){
				kv := getval(p[i-1].b, p[i-1].vi);
				p[i].b = getblk(unpackbp(kv.v, 0), 0);
			}
			ok = 1;
			v := getval(p[h-1].b, p[h-1].vi);
			m = Msg(Oinsert, v.k, v.v);
		}else{
			m = getmsg(p[start-1].b, p[start-1].bi);
			if(m.op == Oinsert)
				ok = 1;
			else if(m.op == Oclobber || m.op == Oclearb)
				ok = 0;
			else
				broke(Efs+": broken entry");
			bufsrc = start-1;
		}
		for(i = h-2; i >= 0; i--){
			if(p[i].b == nil || p[i].bi == p[i].b.nbuf)
				continue;
			n := getmsg(p[i].b, p[i].bi);
			if(keycmp(n.k, m.k) < 0){
				if(n.op == Oinsert)
					ok = 1;
				else if(n.op == Oclobber || n.op == Oclearb)
					ok = 0;
				else
					broke(Efs+": broken entry");
				bufsrc = i;
				m = n;
			}
		}
		if(!hasprefix(m.k, s.pfx)){
			s.donescan = 1;
			return nil;
		}
		# every message for this key
		r := cpkvp(m.k, m.v);
		if(bufsrc == -1)
			p[h-1].vi++;
		else
			p[bufsrc].bi++;
		for(i = h-2; i >= 0; i--){
			for(j := p[i].bi; p[i].b != nil && j < p[i].b.nbuf; j++){
				m = getmsg(p[i].b, j);
				if(keycmp(r.k, m.k) != 0)
					break;
				ok = apply(r, m);
				p[i].bi++;
			}
		}
		if(ok){
			s.kv = r;
			return r;
		}
	}
}

btexit(s: ref Scan)
{
	for(i := 0; i < s.ht; i++)
		s.path[i].b = nil;
	s.ht = 0;
}
