#
# gefs: the consistency check, as 9front's check.c: the free lists, the
# deadlists, the snap tree, and every snapshot's tree and data. It
# reports on fd 2, and says "ok" or "not ok".
#

ckfd: ref Sys->FD;

ckprint(s: string)
{
	if(ckfd == nil)
		ckfd = sys->fildes(2);
	sys->fprint(ckfd, "%s", s);
}

keystr(k: array of byte): string
{
	s := "";
	for(i := 0; i < len k && i < 24; i++)
		s += sys->sprint("%.2ux", int k[i]);
	return s;
}

isfree(bp: big): int
{
	a := getarena(bp);
	r := rfloor(a.free, bp);
	if(r == nil)
		return 0;
	return bp < r.off + r.ln;
}

checktree(b: ref Blk, h: int, pred: big, lo, hi: array of byte): int
{
	fail := 0;
	if(h < 0){
		ckprint("node too deep (loop?)\n");
		return 1;
	}
	if(b.ty == Tleaf){
		if(h != 0){
			ckprint("unbalanced leaf\n");
			fail++;
		}
		if(h != 0 && b.nval < 2 && debug){
			ckprint(sys->sprint("warning: underfilled leaf %bux\n", b.bp.addr));
			fail++;
		}
	}
	if(b.ty == Tpivot && b.nval < 2 && debug)
		ckprint(sys->sprint("warning: underfilled pivot %bux\n", b.bp.addr));
	x := getval(b, 0);
	if(lo != nil && keycmp(lo, x.k) > 0){
		ckprint(sys->sprint("out of range keys %s != %s\n", keystr(lo), keystr(x.k)));
		fail++;
	}
	for(i := 1; i < b.nval; i++){
		y := getval(b, i);
		if(hi != nil && keycmp(y.k, hi) >= 0){
			ckprint(sys->sprint("out of range keys %s >= %s\n", keystr(y.k), keystr(hi)));
			fail++;
		}
		if(b.ty == Tpivot){
			(bp, fill) := getptr(x);
			if(bp.gen > pred){
				if(isfree(bp.addr)){
					ckprint(sys->sprint("freed block in use: %bux\n", bp.addr));
					fail++;
				}
				c := getblk(bp, GBtry);
				if(c == nil){
					ckprint(sys->sprint("corrupt block: %bux\n", bp.addr));
					fail++;
					continue;
				}
				if(blkfill(c) != fill){
					ckprint("mismatched block fill\n");
					fail++;
				}
				if(checktree(c, h - 1, pred, x.k, y.k))
					fail++;
			}
		}
		case keycmp(x.k, y.k) {
		0 =>
			ckprint(sys->sprint("duplicate keys %s, %s\n", keystr(x.k), keystr(y.k)));
			fail++;
		1 =>
			ckprint(sys->sprint("misordered keys %s, %s\n", keystr(x.k), keystr(y.k)));
			fail++;
		}
		x = y;
	}
	if(b.ty == Tpivot){
		y := getval(b, b.nval-1);
		(bp, nil) := getptr(x);
		if(bp.gen > pred){
			c := getblk(bp, GBtry);
			if(c == nil){
				ckprint(sys->sprint("corrupt block: %bux\n", bp.addr));
				fail++;
			}
			if(c != nil && checktree(c, h - 1, pred, y.k, nil))
				fail++;
		}
		mx: Msg;
		if(b.nbuf > 0){
			mx = getmsg(b, 0);
			if(hi != nil && keycmp(mx.k, hi) >= 0){
				ckprint(sys->sprint("out of range messages %s != %s\n", keystr(hi), keystr(mx.k)));
				fail++;
			}
		}
		for(i = 1; i < b.nbuf; i++){
			my := getmsg(b, i);
			if(my.op == Owstat){
				if((int my.v[0] & ~(Owsize|Owmode|Owmtime|Owatime|Owuid|Owgid|Owmuid)) != 0){
					ckprint(sys->sprint("invalid stat op %x\n", int my.v[0]));
					fail++;
				}
			}else if(my.op <= 0 || my.op >= Nmsgtype){
				ckprint(sys->sprint("invalid message op %d\n", my.op));
				fail++;
			}
			if(hi != nil && keycmp(y.k, hi) > 0){
				ckprint(sys->sprint("out of range keys %s >= %s\n", keystr(y.k), keystr(hi)));
				fail++;
			}
			if(keycmp(mx.k, my.k) == 1){
				ckprint(sys->sprint("misordered keys %s, %s\n", keystr(x.k), keystr(y.k)));
				fail++;
				break;
			}
			mx = my;
		}
	}
	return fail;
}

checklog(head, tail: Bptr): int
{
	pb := Zb();
	nb: Bptr;
	for(bp := head; bp.addr != big -1; bp = nb){
		{
			pb = bp;
			b := getblk(bp, 0);
			nb = b.logp;
		} exception {
		"gefs:*" =>
			ckprint(sys->sprint("error loading %bux\n", bp.addr));
			return 0;
		}
		if(bp.addr == tail.addr)
			break;
	}
	if(tail.addr != big -1 && pb.addr != tail.addr){
		ckprint(sys->sprint("truncated chain %bux\n", head.addr));
		return 0;
	}
	return 1;
}

checkfree(): int
{
	ok := 1;
	for(i := 0; i < fs.narena; i++){
		a := fs.arenas[i];
		r := rmin(a.free);
		if(r != nil)
		for(n := rafter(a.free, r.off); n != nil; n = rafter(a.free, n.off)){
			if(r.off >= n.off){
				ckprint(sys->sprint("misordered length %bux >= %bux\n", r.off, n.off));
				ok = 0;
			}
			if(r.off+r.ln >= n.off){
				ckprint(sys->sprint("overlaping range %bux+%bux >= %bux\n", r.off, r.ln, n.off));
				ok = 0;
			}
			r = n;
		}
		if(!checklog(a.loghd, Zb())){
			ckprint(sys->sprint("arena %d: broken freelist\n", i));
			ok = 0;
		}
	}
	return ok;
}

checkdlist(): int
{
	ok := 1;
	if(!checklog(fs.snapdl.head, fs.snapdl.tail)){
		ckprint("bad snap dlist\n");
		ok = 0;
	}
	s := btnewscan(array[] of {byte Kdlist});
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		dl := kv2dlist(*kv);
		if(!checklog(dl.head, dl.tail)){
			ckprint(sys->sprint("bad dlist %s\n", keystr(kv.k)));
			ok = 0;
		}
	}
	btexit(s);
	return ok;
}

checkdata(t: ref Tree, pred: big): int
{
	s := btnewscan(array[] of {byte Kdat});
	btenter(t, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		bp := unpackbp(kv.v, 0);
		if(bp.gen > pred){
			if(isfree(bp.addr)){
				ckprint(sys->sprint("free block in use: %bux\n", bp.addr));
				btexit(s);
				error("free block in use");
			}
			getblk(bp, GBraw);
		}
	}
	btexit(s);
	return 0;
}

countlbl(id: big): int
{
	nref := 0;
	s := btnewscan(array[] of {byte Klabel});
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		if(len kv.v >= 9 && g64(kv.v, 1) == id){
			ckprint(sys->sprint("\tlabel %s => %bd\n", string kv.k[1:], g64(kv.v, 1)));
			nref++;
		}
	}
	btexit(s);
	return nref;
}

countref(id: big): int
{
	nref := 0;
	s := btnewscan(array[] of {byte Ksnap});
	btenter(fs.snap, s);
	for(;;){
		kv := btnext(s);
		if(kv == nil)
			break;
		t := unpacktree(kv.v, 0);
		if(t.pred == big -1 && t.base == id)
			nref++;
	}
	btexit(s);
	return nref;
}

checkfs(): int
{
	ok := 1;
	{
		ckprint("checking freelist\n");
		if(!checkfree())
			ok = 0;
		ckprint("checking deadlist\n");
		if(!checkdlist())
			ok = 0;
		ckprint(sys->sprint("checking snap tree: %bux\n", fs.snap.bp.addr));
		(b, height) := getroot(fs.snap);
		if(b != nil && checktree(b, height-1, big -1, nil, nil))
			ok = 0;
		s := btnewscan(array[] of {byte Ksnap});
		btenter(fs.snap, s);
		for(;;){
			kv := btnext(s);
			if(kv == nil)
				break;
			gen := g64(kv.k, 1);
			{
				t := opentree(gen);
				ckprint(sys->sprint("checking snap %bd: %bux\n", gen, t.bp.addr));
				nref := countref(gen);
				nlbl := countlbl(gen);
				ckprint(sys->sprint("\tnref %d nlbl %d\n", nref, nlbl));
				if(t.nref < nref || t.nlbl < nlbl){
					ckprint(sys->sprint("mismatched refs: (%d, %d) != (%d, %d)\n", t.nref, nref, t.nlbl, nlbl));
					ok = 0;
				}
				(r, h) := getroot(t);
				if(checktree(r, h-1, t.pred, nil, nil))
					ok = 0;
				if(checkdata(t, t.pred))
					ok = 0;
			} exception e {
			"gefs:*" =>
				ckprint(sys->sprint("moving on: %s\n", errmsg(e)));
				ok = 0;
			}
		}
		btexit(s);
	} exception e {
	"gefs:*" =>
		ckprint(sys->sprint("error checking %s\n", errmsg(e)));
		return 0;
	}
	if(ok)
		ckprint("ok\n");
	else
		ckprint("not ok\n");
	return ok;
}
