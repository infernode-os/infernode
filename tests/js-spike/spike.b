implement Spike;

#
# spike - how fast Dis runs JavaScript, before there is a compiler.
#
# Each benchmark of bench.js, hand-compiled twice into the Limbo a
# JavaScript-to-Dis compiler would emit (docs/JS-ENGINE.md §9):
#
#	base	the baseline tier: every value a Val, every operation a
#		call to the runtime (add, lt, getprop with an inline cache,
#		calls through function references with argument arrays)
#	opt	the optimising tier: locals the interpreter has seen hold
#		only numbers kept as real or int behind type guards, inline
#		caches checked in line, small callees inlined
#
# Values are a small struct passed by value, so a number is never a
# heap object; objects have shapes (hidden classes) with polymorphic
# inline caches; strings are ropes.  Run it under the JIT (emu -c1) and
# the interpreter (-c0); compare with qjs bench.js.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Spike: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# ---- values ----

Tundef, Tnull, Tbool, Tnum, Tstr, Tobj: con iota;

Val: adt {
	t:	int;
	n:	real;		# Tnum; Tbool's 0 or 1
	s:	ref Str;	# Tstr
	o:	ref Obj;	# Tobj
};

# a string: flat, or two halves joined (a rope) until something needs it flat
Str: adt {
	flat:	string;
	l, r:	cyclic ref Str;
	nb:	int;		# its length in bytes
};

Shape: adt {
	keys:	array of string;
	next:	cyclic list of (string, ref Shape);	# its transitions, by the key added
};

Code: type ref fn(this: Val, args: array of Val, env: ref Env): Val;

Obj: adt {
	shape:	ref Shape;
	slots:	cyclic array of Val;
	proto:	cyclic ref Obj;
	code:	Code;		# a function's
	env:	cyclic ref Env;	# a closure's
	ishape:	ref Shape;	# as a prototype: the empty shape of the objects that have it
};

Env: adt {
	v:	cyclic array of Val;
	up:	cyclic ref Env;
};

# a polymorphic inline cache: up to four receiver shapes, each with
# where the property is (holder nil: on the receiver itself)
Nic: con 4;
IC: adt {
	n:	int;
	shapes:	array of ref Shape;
	holders:	array of ref Obj;
	slots:	array of int;
};

undef, null: Val;
root: ref Shape;

num(n: real): Val
{
	return Val(Tnum, n, nil, nil);
}

obj(o: ref Obj): Val
{
	return Val(Tobj, 0.0, nil, o);
}

str(s: string): Val
{
	return Val(Tstr, 0.0, ref Str(s, nil, nil, len array of byte s), nil);
}

newic(): ref IC
{
	return ref IC(0, array[Nic] of ref Shape, array[Nic] of ref Obj, array[Nic] of int);
}

newobj(proto: ref Obj): ref Obj
{
	sh := root;
	if(proto != nil) {
		if(proto.ishape == nil)
			proto.ishape = ref Shape(array[0] of string, nil);
		sh = proto.ishape;
	}
	return ref Obj(sh, array[4] of Val, proto, nil, nil, nil);
}

mkfn(c: Code, env: ref Env): Val
{
	o := newobj(nil);
	o.code = c;
	o.env = env;
	return obj(o);
}

slotof(sh: ref Shape, key: string): int
{
	k := sh.keys;
	for(i := 0; i < len k; i++)
		if(k[i] == key)
			return i;
	return -1;
}

transition(sh: ref Shape, key: string): ref Shape
{
	for(l := sh.next; l != nil; l = tl l)
		if((hd l).t0 == key)
			return (hd l).t1;
	nk := array[len sh.keys + 1] of string;
	nk[0:] = sh.keys;
	nk[len sh.keys] = key;
	n := ref Shape(nk, nil);
	sh.next = (key, n) :: sh.next;
	return n;
}

# an object literal's shape, made once per literal in the program
litshape(keys: array of string): ref Shape
{
	sh := root;
	for(i := 0; i < len keys; i++)
		sh = transition(sh, keys[i]);
	return sh;
}

getprop(v: Val, key: string, ic: ref IC): Val
{
	o := v.o;
	if(o == nil)
		return undef;
	sh := o.shape;
	for(i := 0; i < ic.n; i++)
		if(ic.shapes[i] == sh) {
			if((h := ic.holders[i]) == nil)
				return o.slots[ic.slots[i]];
			return h.slots[ic.slots[i]];
		}
	for(p := o; p != nil; p = p.proto) {
		k := slotof(p.shape, key);
		if(k >= 0) {
			if(ic.n < Nic) {
				ic.shapes[ic.n] = sh;
				if(p != o)
					ic.holders[ic.n] = p;
				ic.slots[ic.n] = k;
				ic.n++;
			}
			return p.slots[k];
		}
	}
	return undef;
}

setprop(v: Val, key: string, x: Val, ic: ref IC)
{
	o := v.o;
	sh := o.shape;
	if(ic.n > 0 && ic.shapes[0] == sh) {
		o.slots[ic.slots[0]] = x;
		return;
	}
	k := slotof(sh, key);
	if(k < 0) {
		k = len sh.keys;
		o.shape = transition(sh, key);
		if(k >= len o.slots) {
			ns := array[2 * len o.slots + 1] of Val;
			ns[0:] = o.slots;
			o.slots = ns;
		}
		o.slots[k] = x;
		return;
	}
	if(ic.n == 0) {
		ic.shapes[0] = sh;
		ic.slots[0] = k;
		ic.n = 1;
	}
	o.slots[k] = x;
}

call(f: Val, this: Val, args: array of Val): Val
{
	return f.o.code(this, args, f.o.env);
}

arg(a: array of Val, i: int): Val
{
	if(i < len a)
		return a[i];
	return undef;
}

truthy(v: Val): int
{
	case v.t {
	Tundef or Tnull =>
		return 0;
	Tbool or Tnum =>
		return v.n != 0.0;
	Tstr =>
		return v.s.nb != 0;
	}
	return 1;
}

tonum(v: Val): real
{
	case v.t {
	Tnum or Tbool =>
		return v.n;
	}
	return 0.0;
}

toint32(n: real): int
{
	b := big n & big 16rFFFFFFFF;	# (the spike's numbers are integers: conversion's rounding is truncation)
	if(b >= big 16r80000000)
		b -= big 16r100000000;
	return int b;
}

tostr(v: Val): ref Str
{
	case v.t {
	Tstr =>
		return v.s;
	Tnum =>
		if(v.n == real int v.n)
			return str(string int v.n).s;
		return str(string v.n).s;
	Tundef =>
		return str("undefined").s;
	Tnull =>
		return str("null").s;
	}
	return str("[object Object]").s;
}

add(a, b: Val): Val
{
	if(a.t == Tnum && b.t == Tnum)
		return Val(Tnum, a.n + b.n, nil, nil);
	if(a.t == Tstr || b.t == Tstr) {
		x := tostr(a);
		y := tostr(b);
		return Val(Tstr, 0.0, ref Str(nil, x, y, x.nb + y.nb), nil);
	}
	return num(tonum(a) + tonum(b));
}

mul(a, b: Val): Val
{
	return Val(Tnum, tonum(a) * tonum(b), nil, nil);
}

lt(a, b: Val): int
{
	return tonum(a) < tonum(b);
}

bor0(a: Val): Val
{
	return Val(Tnum, real toint32(tonum(a)), nil, nil);
}

band(a, b: Val): Val
{
	return Val(Tnum, real (toint32(tonum(a)) & toint32(tonum(b))), nil, nil);
}

mod(a, b: Val): Val
{
	x := tonum(a);
	y := tonum(b);
	return Val(Tnum, x - y * real (big x / big y), nil, nil);	# (the spike's operands are whole and positive)
}

flatten(s: ref Str): string
{
	if(s.l == nil)
		return s.flat;
	buf := array[s.nb] of byte;
	# the right halves first, from the end: a string built a piece at
	# a time is a rope as deep as it has pieces
	end := s.nb;
	stack: list of ref Str;
	stack = s :: nil;
	while(stack != nil) {
		t := hd stack;
		stack = tl stack;
		if(t.l == nil) {
			b := array of byte t.flat;
			end -= len b;
			buf[end:] = b;
			continue;
		}
		stack = t.r :: t.l :: stack;	# the right half next: we fill from the end
	}
	s.flat = string buf;
	s.l = s.r = nil;
	return s.flat;
}

# ---- base: the baseline tier ----

baseprop(): Val
{
	icx := newic();
	icy := newic();
	icw := newic();
	o := obj(newobj(nil));
	setprop(o, "x", num(1.0), icw);
	setprop(o, "y", num(2.0), newic());
	s := num(0.0);
	for(i := num(0.0); lt(i, num(5000000.0)); i = add(i, num(1.0))) {
		setprop(o, "x", add(getprop(o, "x", icx), getprop(o, "y", icy)), icw);
		s = add(s, band(getprop(o, "x", icx), num(1.0)));
	}
	return s;
}

jsadd(nil: Val, a: array of Val, nil: ref Env): Val
{
	return add(arg(a, 0), arg(a, 1));
}

basecall(): Val
{
	f := mkfn(jsadd, nil);
	s := num(0.0);
	for(i := num(0.0); lt(i, num(5000000.0)); i = add(i, num(1.0))) {
		args := array[2] of Val;
		args[0] = s;
		args[1] = i;
		s = bor0(call(f, undef, args));
	}
	return s;
}

counter(nil: Val, nil: array of Val, env: ref Env): Val
{
	c := env.v[0];
	env.v[0] = add(c, num(1.0));
	return c;
}

mk(nil: Val, a: array of Val, env: ref Env): Val
{
	e := ref Env(array[1] of Val, env);
	e.v[0] = arg(a, 0);
	return mkfn(counter, e);
}

baseclosure(): Val
{
	mkf := mkfn(mk, nil);
	s := num(0.0);
	for(i := num(0.0); lt(i, num(500000.0)); i = add(i, num(1.0))) {
		args := array[1] of Val;
		args[0] = i;
		f := call(mkf, undef, args);
		s = bor0(add(add(s, call(f, undef, nil)), call(f, undef, nil)));
	}
	return s;
}

vnshape: ref Shape;	# the shape of the literal {v: i, next: head}

basealloc(): Val
{
	if(vnshape == nil)
		vnshape = litshape(array[] of {"v", "next"});
	head := null;
	for(i := num(0.0); lt(i, num(1000000.0)); i = add(i, num(1.0))) {
		o := ref Obj(vnshape, array[2] of Val, nil, nil, nil, nil);
		o.slots[0] = i;
		o.slots[1] = head;
		head = obj(o);
	}
	s := num(0.0);
	icn := newic();
	icv := newic();
	for(p := head; truthy(p); p = getprop(p, "next", icn))
		s = bor0(add(s, getprop(p, "v", icv)));
	return s;
}

ret1(nil: Val, nil: array of Val, nil: ref Env): Val { return num(1.0); }
ret2(nil: Val, nil: array of Val, nil: ref Env): Val { return num(2.0); }
ret3(nil: Val, nil: array of Val, nil: ref Env): Val { return num(3.0); }

mkclass(f: Code): ref Obj
{
	p := newobj(nil);
	setprop(obj(p), "f", mkfn(f, nil), newic());
	return p;
}

basepoly(): Val
{
	pa := mkclass(ret1);
	pb := mkclass(ret2);
	pc := mkclass(ret3);
	a := array[] of {obj(newobj(pa)), obj(newobj(pb)), obj(newobj(pc))};
	icf := newic();
	s := num(0.0);
	for(i := num(0.0); lt(i, num(3000000.0)); i = add(i, num(1.0))) {
		r := a[int mod(i, num(3.0)).n];
		s = add(s, call(getprop(r, "f", icf), r, nil));
	}
	return s;
}

basestring(): Val
{
	s := str("");
	ab := str("ab");
	for(i := num(0.0); lt(i, num(200000.0)); i = add(i, num(1.0)))
		s = add(s, add(ab, i));
	f := flatten(s.s);
	n := 1;
	pieces: list of string;
	st := 0;
	for(k := 0; k < len f; k++)
		if(f[k] == 'a') {
			pieces = f[st:k] :: pieces;
			st = k + 1;
			n++;
		}
	pieces = f[st:] :: pieces;
	return num(real n);
}

basefloat(): Val
{
	x := num(0.5);
	for(i := num(0.0); lt(i, num(5000000.0)); i = add(i, num(1.0)))
		x = add(mul(x, num(1.000001)), num(0.000001));
	return num(real int (x.n * 1000.0));
}

# ---- inl: the baseline tier, its fast paths emitted in line ----
#
# Still every value a Val and no type assumed, but the common case of
# each operation tested where it happens (both numbers? the cached
# shape?), the runtime called only when that fails.

inlprop(): Val
{
	icx := newic();
	icy := newic();
	icw := newic();
	o := obj(newobj(nil));
	setprop(o, "x", num(1.0), icw);
	setprop(o, "y", num(2.0), newic());
	getprop(o, "x", icx);
	getprop(o, "y", icy);
	s := num(0.0);
	i := num(0.0);
	for(;;) {
		lim := num(5000000.0);
		if(i.t == Tnum) {
			if(!(i.n < lim.n))
				break;
		} else if(!lt(i, lim))
			break;
		# o.x
		x, y: Val;
		oo := o.o;
		if(oo != nil && icx.n > 0 && oo.shape == icx.shapes[0] && icx.holders[0] == nil)
			x = oo.slots[icx.slots[0]];
		else
			x = getprop(o, "x", icx);
		if(oo != nil && icy.n > 0 && oo.shape == icy.shapes[0] && icy.holders[0] == nil)
			y = oo.slots[icy.slots[0]];
		else
			y = getprop(o, "y", icy);
		v: Val;
		if(x.t == Tnum && y.t == Tnum)
			v = Val(Tnum, x.n + y.n, nil, nil);
		else
			v = add(x, y);
		if(oo != nil && icw.n > 0 && oo.shape == icw.shapes[0])
			oo.slots[icw.slots[0]] = v;
		else
			setprop(o, "x", v, icw);
		if(oo != nil && icx.n > 0 && oo.shape == icx.shapes[0] && icx.holders[0] == nil)
			x = oo.slots[icx.slots[0]];
		else
			x = getprop(o, "x", icx);
		b: Val;
		if(x.t == Tnum)
			b = Val(Tnum, real (toint32(x.n) & 1), nil, nil);
		else
			b = band(x, num(1.0));
		if(s.t == Tnum && b.t == Tnum)
			s = Val(Tnum, s.n + b.n, nil, nil);
		else
			s = add(s, b);
		if(i.t == Tnum)
			i = Val(Tnum, i.n + 1.0, nil, nil);
		else
			i = add(i, num(1.0));
	}
	return s;
}

inlcall(): Val
{
	f := mkfn(jsadd, nil);
	s := num(0.0);
	i := num(0.0);
	args := array[2] of Val;	# (a frame for the call's arguments, reused: the callee does not keep it)
	for(;;) {
		if(i.t == Tnum) {
			if(!(i.n < 5000000.0))
				break;
		} else if(!lt(i, num(5000000.0)))
			break;
		args[0] = s;
		args[1] = i;
		r := f.o.code(undef, args, f.o.env);
		if(r.t == Tnum)
			s = Val(Tnum, real toint32(r.n), nil, nil);
		else
			s = bor0(r);
		if(i.t == Tnum)
			i = Val(Tnum, i.n + 1.0, nil, nil);
		else
			i = add(i, num(1.0));
	}
	return s;
}

inlfloat(): Val
{
	x := num(0.5);
	i := num(0.0);
	for(;;) {
		if(i.t == Tnum) {
			if(!(i.n < 5000000.0))
				break;
		} else if(!lt(i, num(5000000.0)))
			break;
		m: Val;
		if(x.t == Tnum)
			m = Val(Tnum, x.n * 1.000001, nil, nil);
		else
			m = mul(x, num(1.000001));
		if(m.t == Tnum)
			x = Val(Tnum, m.n + 0.000001, nil, nil);
		else
			x = add(m, num(0.000001));
		if(i.t == Tnum)
			i = Val(Tnum, i.n + 1.0, nil, nil);
		else
			i = add(i, num(1.0));
	}
	return num(real int (x.n * 1000.0));
}

# ---- opt: the optimising tier ----

optprop(): Val
{
	icw := newic();
	o := newobj(nil);
	setprop(obj(o), "x", num(1.0), icw);
	setprop(obj(o), "y", num(2.0), newic());
	sh := o.shape;
	kx := slotof(sh, "x");
	ky := slotof(sh, "y");
	s := 0;
	for(i := 0; i < 5000000; i++) {
		if(o.shape != sh || o.slots[kx].t != Tnum || o.slots[ky].t != Tnum)
			raise "deopt";	# (back to the baseline code at this point, in a real engine)
		x := o.slots[kx].n + o.slots[ky].n;
		o.slots[kx] = Val(Tnum, x, nil, nil);
		s += toint32(x) & 1;
	}
	return num(real s);
}

optcall(): Val
{
	# add(s, i) inlined, s and i ints
	s := 0;
	for(i := 0; i < 5000000; i++)
		s = toint32(real s + real i);
	return num(real s);
}

optclosure(): Val
{
	# mk inlined; the closures' calls inlined on their environment
	s := 0;
	for(i := 0; i < 500000; i++) {
		e := ref Env(array[1] of Val, nil);
		e.v[0] = Val(Tnum, real i, nil, nil);
		f := mkfn(counter, e);
		c1 := f.o.env.v[0].n;
		f.o.env.v[0] = Val(Tnum, c1 + 1.0, nil, nil);
		c2 := f.o.env.v[0].n;
		f.o.env.v[0] = Val(Tnum, c2 + 1.0, nil, nil);
		s = toint32(real s + c1 + c2);
	}
	return num(real s);
}

optalloc(): Val
{
	if(vnshape == nil)
		vnshape = litshape(array[] of {"v", "next"});
	head: ref Obj;
	for(i := 0; i < 1000000; i++) {
		o := ref Obj(vnshape, array[2] of Val, nil, nil, nil, nil);
		o.slots[0] = Val(Tnum, real i, nil, nil);
		o.slots[1] = obj(head);
		head = o;
	}
	s := 0;
	for(p := head; p != nil; p = p.slots[1].o) {
		if(p.shape != vnshape)
			raise "deopt";
		s = toint32(real s + p.slots[0].n);
	}
	return num(real s);
}

optpoly(): Val
{
	pa := mkclass(ret1);
	pb := mkclass(ret2);
	pc := mkclass(ret3);
	a := array[] of {newobj(pa), newobj(pb), newobj(pc)};
	icf := newic();
	s := 0.0;
	for(i := 0; i < 3000000; i++) {
		r := a[i % 3];
		# the cache checked in line; the method still called through its reference
		m: Val;
		sh := r.shape;
		k := 0;
		while(k < icf.n && icf.shapes[k] != sh)
			k++;
		if(k < icf.n)
			m = icf.holders[k].slots[icf.slots[k]];
		else
			m = getprop(obj(r), "f", icf);
		s += m.o.code(obj(r), nil, m.o.env).n;
	}
	return num(s);
}

optfloat(): Val
{
	x := 0.5;
	for(i := 0; i < 5000000; i++)
		x = x * 1.000001 + 0.000001;
	return num(real int (x * 1000.0));
}

# ---- timing ----

bench(name: string, f: ref fn(): Val)
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
	undef = Val(Tundef, 0.0, nil, nil);
	null = Val(Tnull, 0.0, nil, nil);
	root = ref Shape(array[0] of string, nil);
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
	if(which == "all" || which == "inl") {
		bench("inl prop", inlprop);
		bench("inl call", inlcall);
		bench("inl float", inlfloat);
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
}
