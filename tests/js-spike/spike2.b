implement Spike2;

#
# spike2 - the spike again, with JavaScript's own heap.
#
# spike.b's values held Limbo pointers, so every copy adjusted reference
# counts (a call out of compiled code on amd64), and JavaScript's
# cyclic garbage was left to Dis's collector, which is paced for Limbo
# programs and does not keep up.  Here, as V8 and QuickJS manage their
# own heaps, the engine does:
#
#	a value	a tag, an integer (an object's or string's handle) and a
#		number: no pointers, so a copy is a plain move
#	objects	rows of the engine's own arrays (shape, prototype, code,
#		environment, and NSLOT slots of tag, handle and number)
#	locals	JavaScript's locals on the engine's value stack, where its
#		collector finds them; the optimising tier keeps numbers and,
#		between allocations, handles in Limbo locals
#	collection	mark and sweep over the object rows when they run
#		out, from the stack, the globals and the inline caches;
#		the rows double only when too few come free
#
# Nothing in Dis or its JIT is changed: this is Limbo code.  Same
# benchmarks as spike.b (and bench.js), plus the garbage test.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Spike2: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Tundef, Tnull, Tbool, Tnum, Tstr, Tobj: con iota;

V: adt {
	t:	int;
	x:	int;		# Tobj, Tstr: the handle
	n:	real;		# Tnum; Tbool's 0 or 1
};

undef, null: V;

num(n: real): V
{
	return V(Tnum, 0, n);
}

objv(h: int): V
{
	return V(Tobj, h, 0.0);
}

# ---- the object heap ----

NSLOT: con 4;	# slots a row holds (the benchmarks' objects stay small; growth would chain a second row)

oshape: array of int;	# -1: the row is free
oproto: array of int;	# a handle, or -1
ocode: array of int;	# a function's code (codes[]), or -1
oenv: array of int;	# a closure's environment, or -1
omark: array of byte;
st: array of int;	# slots: row h's are [h*NSLOT, h*NSLOT+NSLOT)
sx: array of int;
sn: array of real;
nrow := 0;		# rows ever used
freerows: array of int;
nfree := 0;
ncollect := 0;
worstgc := 0;

heapinit(n: int)
{
	oshape = array[n] of int;
	oproto = array[n] of int;
	ocode = array[n] of int;
	oenv = array[n] of int;
	omark = array[n] of byte;
	st = array[n * NSLOT] of int;
	sx = array[n * NSLOT] of int;
	sn = array[n * NSLOT] of real;
	freerows = array[n] of int;
	nrow = 0;
	nfree = 0;
}

grow()
{
	n := 2 * len oshape;
	a := array[n] of int; a[0:] = oshape; oshape = a;
	a = array[n] of int; a[0:] = oproto; oproto = a;
	a = array[n] of int; a[0:] = ocode; ocode = a;
	a = array[n] of int; a[0:] = oenv; oenv = a;
	m := array[n] of byte; m[0:] = omark; omark = m;
	a = array[n * NSLOT] of int; a[0:] = st; st = a;
	a = array[n * NSLOT] of int; a[0:] = sx; sx = a;
	r := array[n * NSLOT] of real; r[0:] = sn; sn = r;
	a = array[n] of int; a[0:] = freerows[0:nfree]; freerows = a;
}

alloc(shape, proto: int): int
{
	if(nfree == 0 && nrow == len oshape) {
		collect();
		if(nfree < len oshape / 4)
			grow();
	}
	h: int;
	if(nfree > 0) {
		nfree--;
		h = freerows[nfree];
	} else
		h = nrow++;
	oshape[h] = shape;
	oproto[h] = proto;
	ocode[h] = -1;
	oenv[h] = -1;
	b := h * NSLOT;
	for(k := 0; k < NSLOT; k++)
		st[b+k] = Tundef;
	return h;
}

# ---- the value stack and globals: the collector's roots ----

vs: array of V;
sp := 0;
ics: list of ref IC;	# their holders are roots too

markstk: array of int;

mark(h: int, nm: int): int
{
	if(omark[h] != byte 0)
		return nm;
	omark[h] = byte 1;
	if(nm == len markstk) {
		a := array[2 * nm] of int;
		a[0:] = markstk;
		markstk = a;
	}
	markstk[nm++] = h;
	return nm;
}

collect()
{
	t := sys->millisec();
	ncollect++;
	for(h := 0; h < nrow; h++)
		omark[h] = byte 0;
	if(markstk == nil)
		markstk = array[1024] of int;
	nm := 0;
	for(i := 0; i < sp; i++)
		if(vs[i].t == Tobj)
			nm = mark(vs[i].x, nm);
	for(l := ics; l != nil; l = tl l) {
		ic := hd l;
		for(k := 0; k < ic.n; k++)
			if(ic.holders[k] >= 0)
				nm = mark(ic.holders[k], nm);
	}
	while(nm > 0) {
		h = markstk[--nm];
		b := h * NSLOT;
		for(k := 0; k < NSLOT; k++)
			if(st[b+k] == Tobj)
				nm = mark(sx[b+k], nm);
		if(oproto[h] >= 0)
			nm = mark(oproto[h], nm);
		if(oenv[h] >= 0)
			nm = mark(oenv[h], nm);
	}
	nfree = 0;
	for(h = 0; h < nrow; h++)
		if(omark[h] == byte 0) {
			oshape[h] = -1;
			freerows[nfree++] = h;
		}
	t = sys->millisec() - t;
	if(t > worstgc)
		worstgc = t;
}

# ---- shapes and inline caches (integers only) ----

Shape: adt {
	keys:	array of string;
	next:	list of (string, int);
};

shapes: array of ref Shape;
nshape := 0;
rootshape := 0;

newshape(keys: array of string): int
{
	if(nshape == len shapes) {
		a := array[2 * nshape] of ref Shape;
		a[0:] = shapes;
		shapes = a;
	}
	shapes[nshape] = ref Shape(keys, nil);
	return nshape++;
}

slotof(sh: int, key: string): int
{
	k := shapes[sh].keys;
	for(i := 0; i < len k; i++)
		if(k[i] == key)
			return i;
	return -1;
}

transition(sh: int, key: string): int
{
	s := shapes[sh];
	for(l := s.next; l != nil; l = tl l)
		if((hd l).t0 == key)
			return (hd l).t1;
	nk := array[len s.keys + 1] of string;
	nk[0:] = s.keys;
	nk[len s.keys] = key;
	n := newshape(nk);
	s.next = (key, n) :: s.next;
	return n;
}

litshape(keys: array of string): int
{
	sh := rootshape;
	for(i := 0; i < len keys; i++)
		sh = transition(sh, keys[i]);
	return sh;
}

Nic: con 4;
IC: adt {
	n:	int;
	shapes:	array of int;
	holders:	array of int;	# -1: the receiver itself
	slots:	array of int;
};

newic(): ref IC
{
	ic := ref IC(0, array[Nic] of int, array[Nic] of int, array[Nic] of int);
	ics = ic :: ics;
	return ic;
}

# objects whose prototype is p get their own empty shape, so a shape says the prototype too
protoshape: array of int;

newobj(proto: int): int
{
	sh := rootshape;
	if(proto >= 0) {
		if(proto >= len protoshape) {
			a := array[2 * len oshape] of {* => -1};
			a[0:] = protoshape;
			protoshape = a;
		}
		if(protoshape[proto] < 0)
			protoshape[proto] = newshape(array[0] of string);
		sh = protoshape[proto];
	}
	return alloc(sh, proto);
}

getprop(v: V, key: string, ic: ref IC): V
{
	if(v.t != Tobj)
		return undef;
	h := v.x;
	sh := oshape[h];
	for(i := 0; i < ic.n; i++)
		if(ic.shapes[i] == sh) {
			hh := ic.holders[i];
			if(hh < 0)
				hh = h;
			b := hh * NSLOT + ic.slots[i];
			return V(st[b], sx[b], sn[b]);
		}
	for(p := h; p >= 0; p = oproto[p]) {
		k := slotof(oshape[p], key);
		if(k >= 0) {
			if(ic.n < Nic) {
				ic.shapes[ic.n] = sh;
				ic.holders[ic.n] = -1;
				if(p != h)
					ic.holders[ic.n] = p;
				ic.slots[ic.n] = k;
				ic.n++;
			}
			b := p * NSLOT + k;
			return V(st[b], sx[b], sn[b]);
		}
	}
	return undef;
}

setprop(v: V, key: string, x: V, ic: ref IC)
{
	h := v.x;
	sh := oshape[h];
	k: int;
	if(ic.n > 0 && ic.shapes[0] == sh)
		k = ic.slots[0];
	else {
		k = slotof(sh, key);
		if(k < 0) {
			k = len shapes[sh].keys;
			if(k >= NSLOT)
				raise "spike: object too big";
			oshape[h] = transition(sh, key);
		} else if(ic.n == 0) {
			ic.shapes[0] = sh;
			ic.holders[0] = -1;
			ic.slots[0] = k;
			ic.n = 1;
		}
	}
	b := h * NSLOT + k;
	st[b] = x.t;
	sx[b] = x.x;
	sn[b] = x.n;
}

# ---- functions: code by number, arguments on the value stack ----

Code: type ref fn(this: V, env, fp, nargs: int): V;
codes: array of Code;
ncode := 0;

defcode(c: Code): int
{
	if(ncode == len codes) {
		a := array[2 * ncode] of Code;
		a[0:] = codes;
		codes = a;
	}
	codes[ncode] = c;
	return ncode++;
}

mkfn(code, env: int): V
{
	h := alloc(rootshape, -1);
	ocode[h] = code;
	oenv[h] = env;
	return objv(h);
}

# call f with the nargs arguments the caller has pushed at fp
call(f: V, this: V, fp, nargs: int): V
{
	h := f.x;
	r := codes[ocode[h]](this, oenv[h], fp, nargs);
	sp = fp;
	return r;
}

arg(fp, nargs, i: int): V
{
	if(i < nargs)
		return vs[fp+i];
	return undef;
}

push(v: V)
{
	vs[sp++] = v;
}

# ---- strings: their own table, ropes by handle ----

sflat: array of string;
sl, sr, snb: array of int;
nstr := 0;

newstr(flat: string, l, r, nb: int): int
{
	if(nstr == len sflat) {
		n := 2 * nstr;
		a := array[n] of string; a[0:] = sflat; sflat = a;
		b := array[n] of int; b[0:] = sl; sl = b;
		b = array[n] of int; b[0:] = sr; sr = b;
		b = array[n] of int; b[0:] = snb; snb = b;
	}
	sflat[nstr] = flat;
	sl[nstr] = l;
	sr[nstr] = r;
	snb[nstr] = nb;
	return nstr++;
}

strv(s: string): V
{
	return V(Tstr, newstr(s, -1, -1, len array of byte s), 0.0);
}

tostr(v: V): int
{
	case v.t {
	Tstr =>
		return v.x;
	Tnum =>
		if(v.n == real int v.n)
			return strv(string int v.n).x;
		return strv(string v.n).x;
	}
	return strv("[object]").x;
}

flatten(h: int): string
{
	if(sl[h] < 0)
		return sflat[h];
	buf := array[snb[h]] of byte;
	end := snb[h];
	stk := array[64] of int;
	n := 0;
	stk[n++] = h;
	while(n > 0) {
		t := stk[--n];
		if(sl[t] < 0) {
			b := array of byte sflat[t];
			end -= len b;
			buf[end:] = b;
			continue;
		}
		if(n + 2 > len stk) {
			a := array[2 * len stk] of int;
			a[0:] = stk;
			stk = a;
		}
		stk[n++] = sl[t];
		stk[n++] = sr[t];	# the right half next: we fill from the end
	}
	sflat[h] = string buf;
	sl[h] = sr[h] = -1;
	return sflat[h];
}

# ---- operations (the baseline's runtime) ----

truthy(v: V): int
{
	case v.t {
	Tundef or Tnull =>
		return 0;
	Tbool or Tnum =>
		return v.n != 0.0;
	Tstr =>
		return snb[v.x] != 0;
	}
	return 1;
}

tonum(v: V): real
{
	if(v.t == Tnum || v.t == Tbool)
		return v.n;
	return 0.0;
}

toint32(n: real): int
{
	b := big n & big 16rFFFFFFFF;	# (whole numbers here: conversion's rounding is truncation)
	if(b >= big 16r80000000)
		b -= big 16r100000000;
	return int b;
}

add(a, b: V): V
{
	if(a.t == Tnum && b.t == Tnum)
		return V(Tnum, 0, a.n + b.n);
	if(a.t == Tstr || b.t == Tstr) {
		x := tostr(a);
		y := tostr(b);
		return V(Tstr, newstr(nil, x, y, snb[x] + snb[y]), 0.0);
	}
	return num(tonum(a) + tonum(b));
}

mul(a, b: V): V
{
	return V(Tnum, 0, tonum(a) * tonum(b));
}

lt(a, b: V): int
{
	return tonum(a) < tonum(b);
}

bor0(a: V): V
{
	return V(Tnum, 0, real toint32(tonum(a)));
}

band(a, b: V): V
{
	return V(Tnum, 0, real (toint32(tonum(a)) & toint32(tonum(b))));
}

mod(a, b: V): V
{
	x := tonum(a);
	y := tonum(b);
	return V(Tnum, 0, x - y * real (big x / big y));	# (whole and positive here)
}

# ---- base: every local on the value stack, every operation the runtime's ----

baseprop(): V
{
	icx := newic();
	icy := newic();
	icw := newic();
	fp := sp;
	sp += 3;	# o, s, i
	vs[fp] = objv(newobj(-1));
	setprop(vs[fp], "x", num(1.0), icw);
	setprop(vs[fp], "y", num(2.0), newic());
	vs[fp+1] = num(0.0);
	for(vs[fp+2] = num(0.0); lt(vs[fp+2], num(5000000.0)); vs[fp+2] = add(vs[fp+2], num(1.0))) {
		setprop(vs[fp], "x", add(getprop(vs[fp], "x", icx), getprop(vs[fp], "y", icy)), icw);
		vs[fp+1] = add(vs[fp+1], band(getprop(vs[fp], "x", icx), num(1.0)));
	}
	r := vs[fp+1];
	sp = fp;
	return r;
}

jsadd(nil: V, nil, fp, nargs: int): V
{
	return add(arg(fp, nargs, 0), arg(fp, nargs, 1));
}

basecall(): V
{
	fp := sp;
	sp += 3;	# f, s, i
	vs[fp] = mkfn(defcode(jsadd), -1);
	vs[fp+1] = num(0.0);
	for(vs[fp+2] = num(0.0); lt(vs[fp+2], num(5000000.0)); vs[fp+2] = add(vs[fp+2], num(1.0))) {
		a := sp;
		push(vs[fp+1]);
		push(vs[fp+2]);
		vs[fp+1] = bor0(call(vs[fp], undef, a, 2));
	}
	r := vs[fp+1];
	sp = fp;
	return r;
}

ccounter := -1;

counter(nil: V, env, nil, nil: int): V
{
	b := env * NSLOT;
	c := V(st[b], sx[b], sn[b]);
	n := add(c, num(1.0));
	st[b] = n.t;
	sx[b] = n.x;
	sn[b] = n.n;
	return c;
}

mk(nil: V, env, fp, nargs: int): V
{
	e := alloc(rootshape, -1);
	oenv[e] = env;
	a := arg(fp, nargs, 0);
	b := e * NSLOT;
	st[b] = a.t;
	sx[b] = a.x;
	sn[b] = a.n;
	vs[sp++] = objv(e);	# held while the function object is made: making it may collect
	f := mkfn(ccounter, e);
	sp--;
	return f;
}

baseclosure(): V
{
	if(ccounter < 0)
		ccounter = defcode(counter);
	fp := sp;
	sp += 4;	# mk, s, i, f
	vs[fp] = mkfn(defcode(mk), -1);
	vs[fp+1] = num(0.0);
	for(vs[fp+2] = num(0.0); lt(vs[fp+2], num(500000.0)); vs[fp+2] = add(vs[fp+2], num(1.0))) {
		a := sp;
		push(vs[fp+2]);
		vs[fp+3] = call(vs[fp], undef, a, 1);
		c1 := call(vs[fp+3], undef, sp, 0);
		c2 := call(vs[fp+3], undef, sp, 0);
		vs[fp+1] = bor0(add(add(vs[fp+1], c1), c2));
	}
	r := vs[fp+1];
	sp = fp;
	return r;
}

vnshape := -1;

basealloc(): V
{
	if(vnshape < 0)
		vnshape = litshape(array[] of {"v", "next"});
	fp := sp;
	sp += 4;	# head, i, s, p
	vs[fp] = null;
	for(vs[fp+1] = num(0.0); lt(vs[fp+1], num(1000000.0)); vs[fp+1] = add(vs[fp+1], num(1.0))) {
		h := alloc(vnshape, -1);
		b := h * NSLOT;
		v := vs[fp+1];
		st[b] = v.t; sx[b] = v.x; sn[b] = v.n;
		v = vs[fp];
		st[b+1] = v.t; sx[b+1] = v.x; sn[b+1] = v.n;
		vs[fp] = objv(h);
	}
	vs[fp+2] = num(0.0);
	icn := newic();
	icv := newic();
	for(vs[fp+3] = vs[fp]; truthy(vs[fp+3]); vs[fp+3] = getprop(vs[fp+3], "next", icn))
		vs[fp+2] = bor0(add(vs[fp+2], getprop(vs[fp+3], "v", icv)));
	r := vs[fp+2];
	sp = fp;
	return r;
}

ret1(nil: V, nil, nil, nil: int): V { return num(1.0); }
ret2(nil: V, nil, nil, nil: int): V { return num(2.0); }
ret3(nil: V, nil, nil, nil: int): V { return num(3.0); }

# a class: a prototype object with a method f; the caller holds it on the stack
mkclass(c: Code): V
{
	p := objv(newobj(-1));
	push(p);
	f := mkfn(defcode(c), -1);
	setprop(p, "f", f, newic());
	sp--;
	return p;
}

basepoly(): V
{
	fp := sp;
	sp += 8;	# 3 classes, 3 instances, s, i
	vs[fp] = mkclass(ret1);
	vs[fp+1] = mkclass(ret2);
	vs[fp+2] = mkclass(ret3);
	for(k := 0; k < 3; k++)
		vs[fp+3+k] = objv(newobj(vs[fp+k].x));
	icf := newic();
	vs[fp+6] = num(0.0);
	for(vs[fp+7] = num(0.0); lt(vs[fp+7], num(3000000.0)); vs[fp+7] = add(vs[fp+7], num(1.0))) {
		r := vs[fp + 3 + int mod(vs[fp+7], num(3.0)).n];
		m := getprop(r, "f", icf);
		vs[fp+6] = add(vs[fp+6], call(m, r, sp, 0));
	}
	r := vs[fp+6];
	sp = fp;
	return r;
}

basestring(): V
{
	fp := sp;
	sp += 3;	# s, ab, i
	vs[fp] = strv("");
	vs[fp+1] = strv("ab");
	for(vs[fp+2] = num(0.0); lt(vs[fp+2], num(200000.0)); vs[fp+2] = add(vs[fp+2], num(1.0)))
		vs[fp] = add(vs[fp], add(vs[fp+1], vs[fp+2]));
	f := flatten(vs[fp].x);
	n := 1;
	st0 := 0;
	for(k := 0; k < len f; k++)
		if(f[k] == 'a') {
			strv(f[st0:k]);	# the pieces, as split makes them
			st0 = k + 1;
			n++;
		}
	strv(f[st0:]);
	sp = fp;
	return num(real n);
}

basefloat(): V
{
	fp := sp;
	sp += 2;	# x, i
	vs[fp] = num(0.5);
	for(vs[fp+1] = num(0.0); lt(vs[fp+1], num(5000000.0)); vs[fp+1] = add(vs[fp+1], num(1.0)))
		vs[fp] = add(mul(vs[fp], num(1.000001)), num(0.000001));
	r := num(real int (vs[fp].n * 1000.0));
	sp = fp;
	return r;
}

# ---- opt: numbers in Limbo locals; handles there too between allocations ----

optprop(): V
{
	icw := newic();
	o := newobj(-1);
	setprop(objv(o), "x", num(1.0), icw);
	setprop(objv(o), "y", num(2.0), newic());
	sh := oshape[o];
	bx := o * NSLOT + slotof(sh, "x");
	by := o * NSLOT + slotof(sh, "y");
	s := 0;
	for(i := 0; i < 5000000; i++) {
		if(oshape[o] != sh || st[bx] != Tnum || st[by] != Tnum)
			raise "deopt";
		x := sn[bx] + sn[by];
		sn[bx] = x;
		s += toint32(x) & 1;
	}
	return num(real s);
}

optcall(): V
{
	s := 0;
	for(i := 0; i < 5000000; i++)
		s = toint32(real s + real i);
	return num(real s);
}

optclosure(): V
{
	if(ccounter < 0)
		ccounter = defcode(counter);
	s := 0;
	for(i := 0; i < 500000; i++) {
		e := alloc(rootshape, -1);
		b := e * NSLOT;
		st[b] = Tnum;
		sn[b] = real i;
		vs[sp++] = objv(e);
		f := mkfn(ccounter, e);
		sp--;
		c1 := sn[b];
		sn[b] = c1 + 1.0;
		c2 := sn[b];
		sn[b] = c2 + 1.0;
		s = toint32(real s + c1 + c2);
		f = undef;
	}
	return num(real s);
}

optalloc(): V
{
	if(vnshape < 0)
		vnshape = litshape(array[] of {"v", "next"});
	fp := sp;
	sp++;	# head, for the collector
	vs[fp] = null;
	for(i := 0; i < 1000000; i++) {
		h := alloc(vnshape, -1);
		b := h * NSLOT;
		st[b] = Tnum; sn[b] = real i;
		st[b+1] = vs[fp].t; sx[b+1] = vs[fp].x;
		vs[fp] = objv(h);
	}
	s := 0;
	for(p := vs[fp]; p.t == Tobj; ) {
		if(oshape[p.x] != vnshape)
			raise "deopt";
		b := p.x * NSLOT;
		s = toint32(real s + sn[b]);
		p = V(st[b+1], sx[b+1], 0.0);
	}
	sp = fp;
	return num(real s);
}

optpoly(): V
{
	fp := sp;
	sp += 6;
	vs[fp] = mkclass(ret1);
	vs[fp+1] = mkclass(ret2);
	vs[fp+2] = mkclass(ret3);
	for(k := 0; k < 3; k++)
		vs[fp+3+k] = objv(newobj(vs[fp+k].x));
	icf := newic();
	s := 0.0;
	for(i := 0; i < 3000000; i++) {
		r := vs[fp + 3 + i % 3];
		sh := oshape[r.x];
		j := 0;
		while(j < icf.n && icf.shapes[j] != sh)
			j++;
		m: V;
		if(j < icf.n) {
			b := icf.holders[j] * NSLOT + icf.slots[j];
			m = V(st[b], sx[b], sn[b]);
		} else
			m = getprop(r, "f", icf);
		s += codes[ocode[m.x]](r, oenv[m.x], sp, 0).n;
	}
	sp = fp;
	return num(s);
}

optfloat(): V
{
	x := 0.5;
	for(i := 0; i < 5000000; i++)
		x = x * 1.000001 + 0.000001;
	return num(real int (x * 1000.0));
}

# ---- the garbage test: rounds of cyclic objects, each dropped ----

gccycles(): V
{
	n := 500000;
	pairshape := litshape(array[] of {"next", "prev"});
	fp := sp;
	sp++;	# the round's head
	t0 := sys->millisec();
	worst := 0;
	last := t0;
	maxrows := 0;
	for(round := 0; round < 6; round++) {
		vs[fp] = null;
		for(i := 0; i < n; i++) {
			h := alloc(pairshape, -1);
			b := h * NSLOT;
			st[b] = vs[fp].t; sx[b] = vs[fp].x;	# next
			if(vs[fp].t == Tobj) {
				pb := vs[fp].x * NSLOT + 1;	# the old head's prev: a cycle
				st[pb] = Tobj; sx[pb] = h;
			}
			vs[fp] = objv(h);
			if((i & 1023) == 0) {
				now := sys->millisec();
				if(now - last > worst)
					worst = now - last;
				last = now;
			}
		}
		if(len oshape > maxrows)
			maxrows = len oshape;
	}
	sp = fp;
	sys->print("gc\t6 rounds of %d cyclic objects: %d ms; worst pause %d ms; rows at most %d (%d MB of tables); %d collections, worst %d ms\n",
		n, sys->millisec() - t0, worst, maxrows, maxrows * (4*8 + 1 + NSLOT*(8+8+8)) / 1000000, ncollect, worstgc);
	return num(0.0);
}

# ---- timing ----

bench(name: string, f: ref fn(): V)
{
	t := sys->millisec();
	r := f();
	t = sys->millisec() - t;
	rs := "";
	if(r.t == Tnum)
		rs = string big r.n;
	sys->print("%s\t%d ms\t%s\n", name, t, rs);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	undef = V(Tundef, 0, 0.0);
	null = V(Tnull, 0, 0.0);
	heapinit(1024);
	vs = array[1 << 16] of V;
	shapes = array[16] of ref Shape;
	rootshape = newshape(array[0] of string);
	codes = array[16] of Code;
	sflat = array[1024] of string;
	sl = array[1024] of int;
	sr = array[1024] of int;
	snb = array[1024] of int;
	protoshape = array[1024] of {* => -1};
	which := "all";
	if(argv != nil && tl argv != nil)
		which = hd tl argv;
	if(which == "all" || which == "base") {
		bench("base prop", baseprop);
		bench("base call", basecall);
		bench("base closure", baseclosure);
		bench("base alloc", basealloc);
		bench("base poly", basepoly);
		bench("base string", basestring);
		bench("base float", basefloat);
	}
	if(which == "all" || which == "opt") {
		bench("opt prop", optprop);
		bench("opt call", optcall);
		bench("opt closure", optclosure);
		bench("opt alloc", optalloc);
		bench("opt poly", optpoly);
		bench("opt string", basestring);
		bench("opt float", optfloat);
	}
	if(which == "all" || which == "gc")
		gccycles();
}
