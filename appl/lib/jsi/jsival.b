#
# jsival.b - values, atoms, shapes, objects' own properties, strings.
#
# A value is five fields, read according to its tag: t, then i for
# booleans and 32-bit integers, n for other numbers, s for strings,
# o for everything that lives on the heap.  The evaluator keeps the
# value it is working on in five registers (rt ri rn rs ro, in
# jsieval.b) and stores values field by field, so that a value is
# never copied as a whole struct: Dis's JIT on amd64 punts a copy of a
# struct holding pointers (IMOVMP) to the interpreter.
#
# Objects are Limbo objects, freed by Dis: by reference count at once,
# by the collector when they are cyclic.
#

Tundef, Tnull, Tbool, Tint, Tnum, Tstr, Trope, Tsym, Tobj, Tbig, Thole: con iota;

V: adt {
	t:	int;
	i:	int;
	n:	real;
	s:	string;
	o:	ref Obj;
};

# object classes
Cplain, Carray, Cfunc, Cerror, Cbool, Cnum, Cstr, Csym, Cbigint, Cdate, Cregexp,
Cmap, Cset, Cweakmap, Cweakset, Cpromise, Cargs, Cproxy, Cgenobj, Crope, Cacc,
Cbuf, Ctyped, Cview, Citer, Cweakref, Cfinreg, Cns, Cdisposable: con iota;

# object flags
Fext, Fproto, Fslow, Fctor, Fbiglen, Fmapped, Fclassctor, Fderived, Fnew, Ffrozenlen, Flazyproto, Fpriv, Fdead: con 1 << iota;

# property attributes
Awrite, Aenum, Aconf, Aacc: con 1 << iota;
Adefault: con Awrite | Aenum | Aconf;

Obj: adt {
	sh:	ref Shape;
	slots:	array of V;
	cls:	int;
	flags:	int;
	elems:	array of V;	# an array's (or arguments') elements, Thole where absent
	alen:	int;		# an array's length (Fbiglen: blen is)
	fun:	ref Fn;		# callable
	env:	ref Env;	# a closure's scope
	data:	ref Data;
};
# (nine words: an Obj is one 128-byte block of the heap pool on 64-bit
# hosts, where a Limbo int is a word; a tenth would make it two)

Shape: adt {
	keys:	array of int;	# atoms, by slot (-1: a deleted key, in a dictionary)
	attrs:	array of int;
	n:	int;
	proto:	ref Obj;
	dict:	int;		# owned by one object and changed in place
	index:	array of int;	# atom -> slot+1, open addressed, when n > 8
	tk:	array of int;	# transitions: atom<<4 | attrs
	ts:	array of ref Shape;
	nt:	int;
	kid:	ref Shape;	# a prototype's (whose shape is its own): the empty shape of objects it is the prototype of
};

# a property descriptor, as defineProperty takes it
Dvalue, Dwrite, Denum, Dconf, Dget, Dset: con 1 << iota;
Desc: adt {
	has:	int;
	v:	V;
	attrs:	int;
	get, set:	ref Obj;
};

Data: adt {
	pick {
	Prim =>
		v:	V;
	Sym =>
		desc:	string;
		hasdesc:	int;
		atom:	int;
		reg:	int;	# made by Symbol.for
	Acc =>
		get, set:	ref Obj;
	Bound =>
		target:	ref Obj;
		this:	V;
		args:	array of V;
	Func =>
		home:	ref Obj;	# a method's object, for super
		fields:	array of ref Field;	# a class constructor's
		privbrand:	ref Obj;
	Date =>
		t:	real;
	Regexp =>
		pat:	ref Jsre->Pattern;
		source:	string;
		flags:	string;
	Map =>
		m:	ref Hmap;
	Promise =>
		state:	int;
		v:	V;
		reacts:	list of ref React;
		handled:	int;
	Args =>
		fr:	array of V;	# the frame the parameters are in
		env:	ref Env;
		map:	array of int;	# by index: frame slot (>=0), -(env slot)-2, or -1 unmapped
	Proxy =>
		target, handler:	ref Obj;
	Rope =>
		pieces:	array of string;
		cum:	array of int;	# length up to and including each piece
		np:	int;
		flat:	string;	# pieces[0:nflat] made one
		nflat:	int;
	Gen =>
		g:	ref Gen;
	Buf =>
		b:	array of byte;
		detached:	int;
		maxlen:	int;	# resizable: the most it can grow to (-1: fixed)
	Typed =>
		buf:	ref Obj;
		kind:	int;
		off:	int;
		length:	int;	# elements (-1: tracks the buffer)

	Iter =>
		kind:	int;
		o:	ref Obj;
		v:	V;
		i:	int;
		done:	int;
		aux:	ref Obj;
	Weak =>
		target:	V;
	Ns =>
		m:	ref Module;
	Big =>
		b:	ref Keyring->IPint;
	Finreg =>
		cleanup:	ref Obj;
		cells:	list of (V, V, V);
	Disp =>
		stack:	list of (V, ref Obj, int);
		disposed:	int;
	Shape =>
		sh:	ref Shape;
	Resolver =>
		p:	ref Obj;
		done:	ref Flag;
		reject:	int;
	Capexec =>
		cap:	ref Cap;
	Arr =>
		id:	int;		# an array's identity, for Map's hash
		blen:	real;		# its length when past 2^31-1
	Pall =>
		st:	ref Pall;
		i:	int;
		kind:	int;
		done:	ref Flag;
	Native =>
		v:	V;		# what a built-in's closure needs
		w:	V;
		i:	int;
		done:	ref Flag;
	}
};

Flag: adt {
	v:	int;
};

# the shared state of Promise.all and its kin
Pall: adt {
	values:	ref Obj;
	remaining:	int;
	cap:	ref Cap;
	kind:	int;	# 0 all, 1 allSettled fulfilled, 2 allSettled rejected, 3 any
};


Field: adt {
	key:	int;		# atom, or -1 for a computed key already in kv
	kv:	V;
	priv:	int;		# a private name's atom
	init:	int;		# node of the initialiser, or -1
	env:	ref Env;
	isblock:	int;
	ismethod:	int;		# a private method or accessor: installed whole
	meth:	ref Obj;
	getter, setter:	ref Obj;
};

React: adt {
	kind:	int;	# 0 fulfilled, 1 rejected
	handler:	ref Obj;
	cap:	ref Cap;
	native:	int;	# an engine continuation (await): its id
	g:	ref Gen;
};

Cap: adt {
	promise:	ref Obj;
	resolve, reject:	ref Obj;
};

Hmap: adt {
	keys:	array of V;
	vals:	array of V;
	n:	int;		# entries used (deleted ones too)
	live:	int;
	hash:	array of int;	# entry+1, open addressed
	nhash:	int;
};

undef: V;
nullv: V;
truev: V;
falsev: V;
holev: V;

nan, inf: real;

isnan(x: real): int
{
	return math->isnan(x);
}

valinit()
{
	undef = V(Tundef, 0, 0.0, nil, nil);
	nullv = V(Tnull, 0, 0.0, nil, nil);
	truev = V(Tbool, 1, 0.0, nil, nil);
	falsev = V(Tbool, 0, 0.0, nil, nil);
	holev = V(Thole, 0, 0.0, nil, nil);
	nan = math->NaN;
	inf = math->Infinity;
}

intv(i: int): V
{
	return V(Tint, i, 0.0, nil, nil);
}

numv(x: real): V
{
	if(x >= -1073741824.0 && x <= 1073741823.0 && !isnan(x)) {
		i := int x;
		if(real i == x && (i != 0 || !negzero(x)))
			return V(Tint, i, 0.0, nil, nil);
	}
	return V(Tnum, 0, x, nil, nil);
}

negzero(x: real): int
{
	return x == 0.0 && math->copysign(1.0, x) < 0.0;
}

boolv(b: int): V
{
	if(b)
		return truev;
	return falsev;
}

strv(s: string): V
{
	return V(Tstr, 0, 0.0, s, nil);
}

objv(o: ref Obj): V
{
	if(o == nil)
		return nullv;
	return V(Tobj, 0, 0.0, nil, o);
}

isobj(v: V): int
{
	return v.t == Tobj;
}

isstr(v: V): int
{
	return v.t == Tstr || v.t == Trope;
}

isnum(v: V): int
{
	return v.t == Tint || v.t == Tnum;
}

numof(v: V): real
{
	if(v.t == Tint)
		return real v.i;
	return v.n;
}

# a value's object, nil for anything else (null's o may be left over in the registers)
objornil(v: V): ref Obj
{
	if(v.t == Tobj)
		return v.o;
	return nil;
}

iscallable(v: V): int
{
	return v.t == Tobj && v.o.fun != nil;
}

isctor(o: ref Obj): int
{
	return o != nil && o.fun != nil && (o.flags & Fctor);
}

# ---- atoms: interned property keys ----

atomstr: array of string;
atomsym: array of ref Obj;
atomidx: array of int;		# a canonical array index's value, -1 if not one, -2 if past 2^31-1
natom := 0;
atomhash: array of int;
smallidx: array of int;		# the atoms of "0".."1023"

atominit()
{
	atomstr = array[1024] of string;
	atomsym = array[1024] of ref Obj;
	atomidx = array[1024] of int;
	natom = 0;
	atomhash = array[4096] of {* => 0};
	smallidx = array[1024] of {* => -1};
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h * 31 + s[i];
	return h & 16r7FFFFFFF;
}

newatom(s: string, sym: ref Obj): int
{
	if(natom == len atomstr) {
		a := array[2 * natom] of string;
		a[0:] = atomstr;
		atomstr = a;
		b := array[2 * natom] of ref Obj;
		b[0:] = atomsym;
		atomsym = b;
		c := array[2 * natom] of int;
		c[0:] = atomidx;
		atomidx = c;
	}
	k := natom++;
	atomstr[k] = s;
	atomsym[k] = sym;
	if(sym == nil)
		atomidx[k] = canonidx(s);
	else
		atomidx[k] = -1;
	return k;
}

intern(s: string): int
{
	m := len atomhash - 1;
	h := strhash(s) & m;
	for(;;) {
		a := atomhash[h];
		if(a == 0)
			break;
		if(atomsym[a-1] == nil && atomstr[a-1] == s)
			return a - 1;
		h = (h + 1) & m;
	}
	k := newatom(s, nil);
	atomhash[h] = k + 1;
	if(2 * natom > len atomhash)
		rehashatoms();
	return k;
}

rehashatoms()
{
	n := 2 * len atomhash;
	atomhash = array[n] of {* => 0};
	m := n - 1;
	for(k := 0; k < natom; k++) {
		if(atomsym[k] != nil)
			continue;
		h := strhash(atomstr[k]) & m;
		while(atomhash[h] != 0)
			h = (h + 1) & m;
		atomhash[h] = k + 1;
	}
}

# the value of s as an array index (0 to 2^32-2), -1 if it is not one, -2 if it is past 2^31-1
canonidx(s: string): int
{
	n := len s;
	if(n == 0 || n > 10)
		return -1;
	if(s[0] == '0')
		if(n == 1)
			return 0;
		else
			return -1;
	v := big 0;
	for(i := 0; i < n; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return -1;
		v = v * big 10 + big (c - '0');
	}
	if(v > big 16rFFFFFFFE)
		return -1;
	if(v > big 16r7FFFFFFF)
		return -2;
	return int v;
}

idxatom(i: int): int
{
	if(i >= 0 && i < len smallidx) {
		a := smallidx[i];
		if(a < 0)
			a = smallidx[i] = intern(string i);
		return a;
	}
	return intern(string i);
}

issym(k: int): int
{
	return atomsym[k] != nil;
}

# a key as a value (a string or a symbol)
keyv(k: int): V
{
	if(atomsym[k] != nil)
		return V(Tsym, 0, 0.0, nil, atomsym[k]);
	return strv(atomstr[k]);
}

# a key as it is shown in messages
keyname(k: int): string
{
	if(atomsym[k] != nil) {
		pick d := atomsym[k].data {
		Sym =>
			return "Symbol(" + d.desc + ")";
		}
	}
	return atomstr[k];
}

newsym(desc: string, hasdesc: int): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.cls = Csym;
	d := ref Data.Sym(desc, hasdesc, 0, 0);
	o.data = d;
	d.atom = newatom(desc, o);
	return o;
}

symatom(o: ref Obj): int
{
	pick d := o.data {
	Sym =>
		return d.atom;
	}
	return -1;
}

# ---- shapes ----

rootshape: ref Shape;	# objects with a null prototype
protoepoch := 0;	# changes when a prototype's shape does

shapeinit()
{
	rootshape = ref Shape(nil, nil, 0, nil, 0, nil, nil, nil, 0, nil);
}

emptyshape(proto: ref Obj): ref Shape
{
	if(proto == nil)
		return rootshape;
	sh := proto.sh;
	if(sh.kid == nil) {
		# a prototype has a shape of its own, which keeps the shape of its objects
		if(!sh.dict)
			dictify(proto);
		sh = proto.sh;
		sh.kid = ref Shape(nil, nil, 0, proto, 0, nil, nil, nil, 0, nil);
		proto.flags |= Fproto;
	}
	return sh.kid;
}

slotof(sh: ref Shape, k: int): int
{
	if(sh.index != nil) {
		m := len sh.index - 1;
		h := (k * 7) & m;
		for(;;) {
			s := sh.index[h];
			if(s == 0)
				return -1;
			if(sh.keys[s-1] == k)
				return s - 1;
			h = (h + 1) & m;
		}
	}
	keys := sh.keys;
	for(i := sh.n - 1; i >= 0; i--)
		if(keys[i] == k)
			return i;
	return -1;
}

reindex(sh: ref Shape)
{
	if(sh.n <= 8) {
		sh.index = nil;
		return;
	}
	n := 16;
	while(n < 2 * sh.n)
		n *= 2;
	sh.index = array[n] of {* => 0};
	m := n - 1;
	for(i := 0; i < sh.n; i++) {
		k := sh.keys[i];
		if(k < 0)
			continue;
		h := (k * 7) & m;
		while(sh.index[h] != 0)
			h = (h + 1) & m;
		sh.index[h] = i + 1;
	}
}

# the shape sh with key k added, shared
addkey(sh: ref Shape, k, attrs: int): ref Shape
{
	tk := k << 4 | attrs;
	for(i := 0; i < sh.nt; i++)
		if(sh.tk[i] == tk)
			return sh.ts[i];
	n := sh.n;
	keys := array[n + 1] of int;
	if(n > 0)
		keys[0:] = sh.keys[0:n];
	keys[n] = k;
	at := array[n + 1] of int;
	if(n > 0)
		at[0:] = sh.attrs[0:n];
	at[n] = attrs;
	ns := ref Shape(keys, at, n + 1, sh.proto, 0, nil, nil, nil, 0, nil);
	if(n + 1 > 8)
		reindex(ns);
	if(sh.nt < 64) {
		if(sh.tk == nil || sh.nt == len sh.tk) {
			m := 2 * sh.nt;
			if(m == 0)
				m = 2;
			a := array[m] of int;
			b := array[m] of ref Shape;
			if(sh.nt > 0) {
				a[0:] = sh.tk[0:sh.nt];
				b[0:] = sh.ts[0:sh.nt];
			}
			sh.tk = a;
			sh.ts = b;
		}
		sh.tk[sh.nt] = tk;
		sh.ts[sh.nt] = ns;
		sh.nt++;
	}
	return ns;
}

# make o's shape its own, to change in place
dictify(o: ref Obj)
{
	sh := o.sh;
	if(sh.dict)
		return;
	n := sh.n;
	cap := n + 4;
	keys := array[cap] of int;
	at := array[cap] of int;
	if(n > 0) {
		keys[0:] = sh.keys[0:n];
		at[0:] = sh.attrs[0:n];
	}
	ns := ref Shape(keys, at, n, sh.proto, 1, nil, nil, nil, 0, sh.kid);
	reindex(ns);
	o.sh = ns;
}

# a dictionary's shape copied, so that caches holding the old one miss
reshape(o: ref Obj)
{
	sh := o.sh;
	ns := ref Shape(sh.keys, sh.attrs, sh.n, sh.proto, 1, sh.index, nil, nil, 0, sh.kid);
	o.sh = ns;
	if(o.flags & Fproto)
		protoepoch++;
}

newobj(cls: int, proto: ref Obj): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.sh = emptyshape(proto);
	o.cls = cls;
	o.flags = Fext;
	return o;
}

plainobj(): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.sh = emptyshape(objproto);
	o.flags = Fext;
	return o;
}

# add a new own property (it must not be there)
addprop(o: ref Obj, k, attrs: int, v: V)
{
	sh := o.sh;
	n := sh.n;
	if(sh.dict) {
		if(n == len sh.keys) {
			a := array[2 * n + 4] of int;
			a[0:] = sh.keys[0:n];
			sh.keys = a;
			b := array[2 * n + 4] of int;
			b[0:] = sh.attrs[0:n];
			sh.attrs = b;
		}
		sh.keys[n] = k;
		sh.attrs[n] = attrs;
		sh.n = n + 1;
		if(sh.index != nil && 2 * sh.n <= len sh.index) {
			m := len sh.index - 1;
			h := (k * 7) & m;
			while(sh.index[h] != 0)
				h = (h + 1) & m;
			sh.index[h] = n + 1;
		} else
			reindex(sh);
	} else if(n >= 64) {
		dictify(o);
		addprop(o, k, attrs, v);
		return;
	} else
		o.sh = addkey(sh, k, attrs);
	if(o.slots == nil || n >= len o.slots) {
		m := 2 * n;
		if(m < 2)
			m = 2;
		a := array[m] of V;
		if(o.slots != nil)
			a[0:] = o.slots[0:n];
		o.slots = a;
	}
	o.slots[n] = v;
	if(o.flags & Fproto)
		protoepoch++;
}

# remove an own property found at slot s
removeslot(o: ref Obj, s: int)
{
	if(!o.sh.dict) {
		if(s == o.sh.n - 1 && o.sh.n > 0) {
			# the last one added: go back to the shape without it, if it is the parent
			dictify(o);
		} else
			dictify(o);
	} else
		reshape(o);
	sh := o.sh;
	# compact: keys after s move down
	n := sh.n;
	for(i := s; i < n - 1; i++) {
		sh.keys[i] = sh.keys[i+1];
		sh.attrs[i] = sh.attrs[i+1];
		o.slots[i] = o.slots[i+1];
	}
	sh.n = n - 1;
	o.slots[n-1] = undef;
	reindex(sh);
	if(o.flags & Fproto)
		protoepoch++;
}

setattrs(o: ref Obj, s, attrs: int)
{
	if(o.sh.attrs[s] == attrs)
		return;
	if(!o.sh.dict)
		dictify(o);
	else
		reshape(o);
	o.sh.attrs[s] = attrs;
	if(o.flags & Fproto)
		protoepoch++;
}

setproto(o: ref Obj, p: ref Obj)
{
	if(o.sh.proto == p)
		return;
	sh := o.sh;
	if(sh.n == 0 && !sh.dict) {
		o.sh = emptyshape(p);
	} else {
		n := sh.n;
		keys := array[n + 4] of int;
		at := array[n + 4] of int;
		if(n > 0) {
			keys[0:] = sh.keys[0:n];
			at[0:] = sh.attrs[0:n];
		}
		ns := ref Shape(keys, at, n, p, 1, nil, nil, nil, 0, sh.kid);
		reindex(ns);
		o.sh = ns;
	}
	if(p != nil && p.sh.kid == nil)
		emptyshape(p);
	if(o.flags & Fproto)
		protoepoch++;
}

# ---- strings ----

# the rope: an append-only buffer of pieces; a rope value (Trope) is
# the first i pieces of its buffer, so appending to the newest value of
# a buffer adds a piece without copying
Ropemin: con 256;

concat(a, b: V): V
{
	if(a.t == Tstr && b.t == Tstr) {
		if(len a.s + len b.s < Ropemin)
			return strv(a.s + b.s);
		if(a.s == nil)
			return b;
		if(b.s == nil)
			return a;
	}
	la := strlenv(a);
	lb := strlenv(b);
	if(la + lb < Ropemin || la == 0 || lb == 0)
		return strv(flat(a) + flat(b));
	if(la + lb < 0 || la + lb > Maxstr)
		throwerr(ERange, "Invalid string length");
	if(a.t == Trope) {
		pick d := a.o.data {
		Rope =>
			if(a.i == d.np) {
				ropeadd(d, b);
				return V(Trope, d.np, 0.0, nil, a.o);
			}
		}
	}
	o := ref Obj;
	gcnew(o);
	o.cls = Crope;
	d := ref Data.Rope(array[8] of string, array[8] of int, 0, nil, 0);
	o.data = d;
	ropeadd(d, a);
	ropeadd(d, b);
	return V(Trope, d.np, 0.0, nil, o);
}

Maxstr: con (1 << 30) - 1;

ropeadd(d: ref Data.Rope, v: V)
{
	s: string;
	if(v.t == Trope)
		s = flat(v);
	else
		s = v.s;
	if(d.np == len d.pieces) {
		a := array[2 * d.np] of string;
		a[0:] = d.pieces;
		d.pieces = a;
		c := array[2 * d.np] of int;
		c[0:] = d.cum;
		d.cum = c;
	}
	prev := 0;
	if(d.np > 0)
		prev = d.cum[d.np-1];
	d.pieces[d.np] = s;
	d.cum[d.np] = prev + len s;
	d.np++;
}

strlenv(v: V): int
{
	if(v.t == Tstr)
		return len v.s;
	if(v.t == Trope) {
		pick d := v.o.data {
		Rope =>
			return d.cum[v.i-1];
		}
	}
	return len tostr(v);
}

# a string value as one Limbo string
flat(v: V): string
{
	if(v.t == Tstr)
		return v.s;
	if(v.t != Trope)
		return tostr(v);
	pick d := v.o.data {
	Rope =>
		if(d.nflat < v.i) {
			# join the pieces not yet joined, onto what was
			n := v.i - d.nflat;
			parts := array[n + 1] of string;
			parts[0] = d.flat;
			parts[1:] = d.pieces[d.nflat:v.i];
			d.flat = joinall(parts);
			d.nflat = v.i;
			# the joined pieces are no longer needed
			for(j := 0; j < v.i; j++)
				d.pieces[j] = nil;
		}
		if(d.nflat == v.i)
			return d.flat;
		return d.flat[0:d.cum[v.i-1]];
	}
	return nil;
}

# strings joined, pairwise, so each character is copied about log n times
joinall(a: array of string): string
{
	n := len a;
	if(n == 0)
		return nil;
	while(n > 1) {
		j := 0;
		for(i := 0; i < n; i += 2) {
			if(i + 1 < n)
				a[j++] = a[i] + a[i+1];
			else
				a[j++] = a[i];
		}
		for(k := j; k < n; k++)
			a[k] = nil;
		n = j;
	}
	return a[0];
}

# ---- numbers and strings (numstr, decimal and strnum follow
# appl/lib/js/jsval.b's, which work around the emulator's strtod) ----

numstr(x: real): string
{
	if(isnan(x))
		return "NaN";
	if(x == 0.0)
		return "0";
	if(x < 0.0)
		return "-" + numstr(-x);
	if(x == inf)
		return "Infinity";
	if(x < 1e21 && x < 9007199254740992.0 && x == real big x)
		return string big x;
	digits := "";
	e := 0;
	for(p := 1; p <= 17; p++) {
		s := sys->sprint("%.*e", p - 1, x);
		(d, ex) := splitexp(s);
		if(decimal(s) == x || p == 17) {
			digits = d;
			e = ex;
			break;
		}
	}
	while(len digits > 1 && digits[len digits - 1] == '0')
		digits = digits[0:len digits - 1];
	k := len digits;
	n := e + 1;
	if(k <= n && n <= 21) {
		s := digits;
		for(i := 0; i < n - k; i++)
			s[len s] = '0';
		return s;
	}
	if(0 < n && n <= 21)
		return digits[0:n] + "." + digits[n:];
	if(-6 < n && n <= 0) {
		s := "0.";
		for(i := 0; i < -n; i++)
			s[len s] = '0';
		return s + digits;
	}
	s := digits[0:1];
	if(k > 1)
		s += "." + digits[1:];
	if(n - 1 >= 0)
		return s + "e+" + string (n - 1);
	return s + "e-" + string (1 - n);
}

splitexp(s: string): (string, int)
{
	d := "";
	i := 0;
	for(; i < len s && s[i] != 'e'; i++)
		if(s[i] != '.')
			d[len d] = s[i];
	e := 0;
	if(i < len s)
		e = int s[i+1:];
	return (d, e);
}

decimal(text: string): real
{
	(m, e) := sci(text);
	if(m == nil)
		return 0.0;
	neg := len text > 0 && text[0] == '-';
	v: real;
	if(e > 310)
		v = inf;
	else if(e < -330)
		v = 0.0;
	else if(e < -300)
		v = real (m + "e" + string (e + 300 - len m + 1)) * 1e-300;
	else
		return real text;
	if(neg)
		return -v;
	return v;
}

sci(text: string): (string, int)
{
	m := "";
	e := 0;
	seen := 0;
	point := 0;
	i := 0;
	if(i < len text && (text[i] == '-' || text[i] == '+'))
		i++;
	for(; i < len text; i++) {
		c := text[i];
		if(c == '.') {
			point = 1;
			continue;
		}
		if(c < '0' || c > '9')
			break;
		if(!seen && c == '0') {
			if(point)
				e--;
			continue;
		}
		if(!seen) {
			seen = 1;
			if(point)
				e--;
		} else if(!point)
			e++;
		m[len m] = c;
	}
	if(i < len text && (text[i] == 'e' || text[i] == 'E'))
		e += int text[i+1:];
	return (m, e);
}

isjsws(c: int): int
{
	case c {
	'\t' or 16r0B or 16r0C or ' ' or 16rA0 or 16rFEFF or 16r1680 or 16r202F or 16r205F or 16r3000 or
	'\n' or '\r' or 16r2028 or 16r2029 =>
		return 1;
	}
	return c >= 16r2000 && c <= 16r200A;
}

trimws(s: string, left, right: int): string
{
	i := 0;
	j := len s;
	if(left)
		while(i < j && isjsws(s[i]))
			i++;
	if(right)
		while(j > i && isjsws(s[j-1]))
			j--;
	return s[i:j];
}

strnum(s: string): real
{
	s = trimws(s, 1, 1);
	if(s == nil)
		return 0.0;
	if(len s > 2 && s[0] == '0') {
		base := 0;
		case s[1] {
		'x' or 'X' => base = 16;
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		if(base) {
			v := 0.0;
			for(i := 2; i < len s; i++) {
				d := digitval(s[i]);
				if(d < 0 || d >= base)
					return nan;
				v = v * real base + real d;
			}
			return v;
		}
	}
	i := 0;
	if(s[0] == '+' || s[0] == '-')
		i = 1;
	if(s[i:] == "Infinity") {
		if(s[0] == '-')
			return -inf;
		return inf;
	}
	nd := 0;
	while(i < len s && s[i] >= '0' && s[i] <= '9') {
		i++;
		nd++;
	}
	if(i < len s && s[i] == '.') {
		i++;
		while(i < len s && s[i] >= '0' && s[i] <= '9') {
			i++;
			nd++;
		}
	}
	if(nd == 0)
		return nan;
	if(i < len s && (s[i] == 'e' || s[i] == 'E')) {
		i++;
		if(i < len s && (s[i] == '+' || s[i] == '-'))
			i++;
		ne := 0;
		while(i < len s && s[i] >= '0' && s[i] <= '9') {
			i++;
			ne++;
		}
		if(ne == 0)
			return nan;
	}
	if(i != len s)
		return nan;
	v := decimal(s);
	if(v == 0.0 && s[0] == '-')
		return -0.0;
	return v;
}

digitval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'z')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'Z')
		return c - 'A' + 10;
	return -1;
}

# ---- maps keyed by SameValueZero (Map, Set, and the engine's own) ----

newhmap(): ref Hmap
{
	return ref Hmap(array[8] of V, array[8] of V, 0, 0, array[16] of {* => 0}, 16);
}

hkey(v: V): int
{
	case v.t {
	Tint =>
		return v.i * 1000003;
	Tnum =>
		x := v.n;
		if(isnan(x))
			return 7;
		if(x == 0.0)
			return 0;
		if(x >= -2147483648.0 && x <= 2147483647.0) {
			i := int x;
			if(real i == x)
				return i * 1000003;
		}
		b := math->realbits64(x);
		return int (b ^ (b >> 32));
	Tstr or Trope =>
		return strhash(flat(v));
	Tundef =>
		return 1;
	Tnull =>
		return 2;
	Tbool =>
		return 3 + v.i;
	Tbig =>
		return strhash(bigstr(v.o, 10));
	* =>
		return objhash(v.o);
	}
}

# an object's identity as a number, given when first asked for
nobjhash := 0;

# (in alen, which only arrays and arguments use; theirs in their data)
objhash(o: ref Obj): int
{
	if(o.cls != Carray && o.cls != Cargs) {
		if(o.alen == 0)
			o.alen = ++nobjhash;
		return o.alen;
	}
	if(o.data == nil)
		o.data = ref Data.Arr(0, 0.0);
	pick d := o.data {
	Arr =>
		if(d.id == 0)
			d.id = ++nobjhash;
		return d.id;
	Args =>
		return len d.map + 7;
	}
	return 12345;
}

hfind(m: ref Hmap, k: V): int
{
	h := hkey(k);
	mask := len m.hash - 1;
	j := (h * 7) & mask;
	for(;;) {
		e := m.hash[j];
		if(e == 0)
			return -1;
		if(e > 0 && samevaluezero(m.keys[e-1], k))
			return e - 1;
		j = (j + 1) & mask;
	}
}

hset(m: ref Hmap, k, v: V)
{
	i := hfind(m, k);
	if(i >= 0) {
		m.vals[i] = v;
		return;
	}
	if(k.t == Tnum && k.n == 0.0)
		k = intv(0);	# -0 is +0
	if(m.n == len m.keys) {
		if(m.live < m.n / 2)
			hcompact(m);
		else {
			a := array[2 * m.n] of V;
			a[0:] = m.keys[0:m.n];
			m.keys = a;
			b := array[2 * m.n] of V;
			b[0:] = m.vals[0:m.n];
			m.vals = b;
		}
	}
	m.keys[m.n] = k;
	m.vals[m.n] = v;
	m.n++;
	m.live++;
	if(2 * m.n >= len m.hash)
		hrehash(m, 2 * len m.hash);
	else
		hput(m, m.n - 1);
}

hput(m: ref Hmap, i: int)
{
	mask := len m.hash - 1;
	j := (hkey(m.keys[i]) * 7) & mask;
	while(m.hash[j] > 0)
		j = (j + 1) & mask;
	m.hash[j] = i + 1;
}

hrehash(m: ref Hmap, n: int)
{
	m.hash = array[n] of {* => 0};
	for(i := 0; i < m.n; i++)
		if(m.keys[i].t != Thole)
			hput(m, i);
}

hdelete(m: ref Hmap, k: V): int
{
	i := hfind(m, k);
	if(i < 0)
		return 0;
	mask := len m.hash - 1;
	j := (hkey(k) * 7) & mask;
	while(m.hash[j] != i + 1)
		j = (j + 1) & mask;
	m.hash[j] = -1;
	m.keys[i] = holev;
	m.vals[i] = undef;
	m.live--;
	return 1;
}

# drop deleted entries; iterators index entries, so this is done only
# when the table grows, and live iterators are told how far to move
hcompact(m: ref Hmap)
{
	j := 0;
	for(i := 0; i < m.n; i++) {
		if(m.keys[i].t == Thole)
			continue;
		m.keys[j] = m.keys[i];
		m.vals[j] = m.vals[i];
		j++;
	}
	for(i = j; i < m.n; i++) {
		m.keys[i] = undef;
		m.vals[i] = undef;
	}
	m.n = j;
	hrehash(m, len m.hash);
}

hclear(m: ref Hmap)
{
	for(i := 0; i < m.n; i++) {
		m.keys[i] = holev;
		m.vals[i] = undef;
	}
	m.live = 0;
	m.hash = array[len m.hash] of {* => 0};
}
