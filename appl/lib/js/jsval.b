#
# jsval.b - values, the heap, strings, property keys, shapes, objects'
# properties, conversions and the collector.  Included by js.b.
#
# A value (V) is a tag, an integer and a number, with no Limbo pointers
# in it, so copying one is a plain move (tests/js-spike/README.md).
# Objects and strings are rows of the engine's own tables, named by
# handle; the engine's mark-and-sweep frees them.  It runs only at the
# interpreter's safe points (calls and backward jumps), never inside an
# operation, so Limbo code holding a handle between safe points needs
# nothing more; across a call back into JavaScript, a handle must be
# held where the collector looks (the value stack, or an object).
#

Tundef, Tnull, Tbool, Tnum, Tstr, Tsym, Tobj, Tbig, Tempty, Tacc, Timport: con iota;

# V, a value, is in jsjit.m, shared with compiled code

undef, null, vtrue, vfalse, empty: V;
nan, inf: real;

num(n: real): V
{
	return V(Tnum, 0, n);
}

bool(b: int): V
{
	if(b)
		return vtrue;
	return vfalse;
}

objv(h: int): V
{
	return V(Tobj, h, 0.0);
}

isobj(v: V): int
{
	return v.t == Tobj;
}

# (not x != x: the Limbo compiler folds that to 0, and turns ordered
# comparisons into their inverse for branches, which is wrong for a NaN;
# so a NaN is tested for before any ordered comparison that may meet one)
isnan(x: real): int
{
	return math->isnan(x);
}

valinit()
{
	undef = V(Tundef, 0, 0.0);
	null = V(Tnull, 0, 0.0);
	vtrue = V(Tbool, 1, 0.0);
	vfalse = V(Tbool, 0, 0.0);
	empty = V(Tempty, 0, 0.0);
	inf = Math->Infinity;
	nan = Math->NaN;
}

# ---- strings ----
#
# A string is a row: flat (a Limbo string, whose characters are UTF-16
# code units, as JavaScript's are) or a rope of two others, flattened
# when its characters are needed.

sflat: array of string;
sleft, sright, slen, satom: array of int;	# satom: the string's key if known, else -1
smark: array of byte;
nstr := 0;
sfree: array of int;
nsfree := 0;
strsince := 0;		# strings made since the last collection

Ropemin: con 64;	# shorter concatenations are copied

strinit()
{
	n := 1024;
	sflat = array[n] of string;
	sleft = array[n] of int;
	sright = array[n] of int;
	slen = array[n] of int;
	satom = array[n] of int;
	smark = array[n] of byte;
	sfree = array[n] of int;
}

newstrrow(): int
{
	if(nsfree > 0)
		return sfree[--nsfree];
	if(nstr == len sflat) {
		n := 2 * nstr;
		if(n > Maxrows)
			throwerr(RangeError, "out of memory: too many strings");
		a := array[n] of string; a[0:] = sflat; sflat = a;
		b := array[n] of int; b[0:] = sleft; sleft = b;
		b = array[n] of int; b[0:] = sright; sright = b;
		b = array[n] of int; b[0:] = slen; slen = b;
		b = array[n] of int; b[0:] = satom; satom = b;
		m := array[n] of byte; m[0:] = smark; smark = m;
		b = array[n] of int; b[0:] = sfree[0:nsfree]; sfree = b;
	}
	return nstr++;
}

newstr(s: string): int
{
	h := newstrrow();
	sflat[h] = s;
	sleft[h] = -1;
	slen[h] = len s;
	satom[h] = -1;
	strsince++;
	if(strsince > gcstrlimit)
		gcwanted = 1;
	return h;
}

strv(s: string): V
{
	return V(Tstr, newstr(s), 0.0);
}

# the characters of string h
str(h: int): string
{
	s := sflat[h];
	if(s != nil || sleft[h] < 0)
		return s;
	# a rope: walk it without recursion's depth
	r := "";
	stk := h :: nil;
	while(stk != nil) {
		x := hd stk;
		stk = tl stk;
		if(sleft[x] >= 0 && sflat[x] == nil) {
			stk = sleft[x] :: sright[x] :: stk;
			continue;
		}
		r += sflat[x];
	}
	sflat[h] = r;
	sleft[h] = -1;
	return r;
}

# the code point at s[i], and how many code units it takes
cpat(s: string, i: int): (int, int)
{
	c := s[i];
	if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
		return (16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00), 2);
	return (c, 1);
}

vstr(v: V): string
{
	return str(v.x);
}

concat(a, b: int): int
{
	if(slen[a] == 0)
		return b;
	if(slen[b] == 0)
		return a;
	n := slen[a] + slen[b];
	if(n > Strmax)
		throwerr(RangeError, "string too long");
	if(n < Ropemin)
		return newstr(str(a) + str(b));
	h := newstrrow();
	sflat[h] = nil;
	sleft[h] = a;
	sright[h] = b;
	slen[h] = n;
	satom[h] = -1;
	strsince++;
	return h;
}

# A string's longest: 64M characters (128 MB).  Browsers allow more (2^29
# or 2^30), but a realm shares emu's heap, and a request for gigabytes
# there takes emu down, not only the script.
Strmax: con (1 << 26) - 1;

# ---- property keys ----
#
# A key is an int: an array index i as -i-1 (for indices below 2^31-1),
# otherwise an atom: an interned string or a symbol.  Atoms are never
# freed.

atomstr: array of string;	# a symbol's: its description
atomsh: array of int;		# the atom's string handle (pinned); for a symbol, its description's, or -1
atomsym: array of byte;	# 1: a symbol
atomidx: array of real;	# an index key too large to be an int key, else -1
natom := 0;
atomhash: array of list of int;

atominit()
{
	atomstr = array[1024] of string;
	atomsh = array[1024] of int;
	atomsym = array[1024] of byte;
	atomidx = array[1024] of real;
	atomhash = array[4096] of list of int;
}

newatom(s: string, sym: int): int
{
	if(natom == len atomstr) {
		n := 2 * natom;
		a := array[n] of string; a[0:] = atomstr; atomstr = a;
		b := array[n] of int; b[0:] = atomsh; atomsh = b;
		c := array[n] of byte; c[0:] = atomsym; atomsym = c;
		d := array[n] of real; d[0:] = atomidx; atomidx = d;
	}
	a := natom++;
	atomstr[a] = s;
	atomsym[a] = byte sym;
	atomidx[a] = -1.0;
	if(sym)
		atomsh[a] = -1;
	else
		atomsh[a] = newstr(s);
	return a;
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h * 31 + s[i];
	return h & 16r7FFFFFFF;
}

intern(s: string): int
{
	b := strhash(s) % len atomhash;
	for(l := atomhash[b]; l != nil; l = tl l)
		if(atomstr[hd l] == s)
			return hd l;
	a := newatom(s, 0);
	satom[atomsh[a]] = a;
	(isidx, ix) := canonidx(s);
	if(isidx)
		atomidx[a] = ix;
	atomhash[b] = a :: atomhash[b];
	if(natom > 2 * len atomhash) {
		nh := array[2 * len atomhash] of list of int;
		for(i := 0; i < natom; i++)
			if(atomsym[i] == byte 0) {
				k := strhash(atomstr[i]) % len nh;
				nh[k] = i :: nh[k];
			}
		atomhash = nh;
	}
	return a;
}

newsymbol(desc: string, hasdesc: int): int
{
	a := newatom(desc, 1);
	if(hasdesc)
		atomsh[a] = newstr(desc);
	return a;
}

# whether s is an array index's canonical form ("0" to "4294967294")
canonidx(s: string): (int, real)
{
	n := len s;
	if(n == 0 || n > 10)
		return (0, 0.0);
	if(s[0] == '0')
		return (n == 1, 0.0);
	v := 0.0;
	for(i := 0; i < n; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return (0, 0.0);
		v = v * 10.0 + real (c - '0');
	}
	if(v > 4294967294.0)
		return (0, 0.0);
	return (1, v);
}

Idxmax: con 16r7FFFFFFE;	# the largest index an int key holds

idxkey(i: int): int
{
	return -i - 1;
}

isidx(k: int): int
{
	return k < 0;
}

keyidx(k: int): int
{
	return -k - 1;
}

# a key from a string
strkey(s: string): int
{
	(isi, ix) := canonidx(s);
	if(isi && ix <= real Idxmax)
		return idxkey(int ix);
	return intern(s);
}

# a key from a string row, remembering it
strhkey(h: int): int
{
	a := satom[h];
	if(a >= 0) {
		# an interned "2" is the index 2, not an atom
		ix := atomidx[a];
		if(ix >= 0.0 && ix <= real Idxmax)
			return idxkey(int ix);
		return a;
	}
	s := str(h);
	(isi, ix) := canonidx(s);
	if(isi && ix <= real Idxmax)
		return idxkey(int ix);
	a = intern(s);
	satom[h] = a;
	return a;
}

# a key from a number
numkey(x: real): int
{
	if(x >= 0.0 && x <= real Idxmax && x == real int x)
		return idxkey(int x);
	return strkey(numstr(x));
}

# the key as a value: a string or a symbol
keyval(k: int): V
{
	if(isidx(k))
		return strv(string keyidx(k));
	if(atomsym[k] != byte 0)
		return V(Tsym, k, 0.0);
	return V(Tstr, atomsh[k], 0.0);
}

keystr(k: int): string
{
	if(isidx(k))
		return string keyidx(k);
	return atomstr[k];
}

issymkey(k: int): int
{
	return k >= 0 && atomsym[k] != byte 0;
}

# an array index the key names (int or large), or -1
keyindex(k: int): real
{
	if(isidx(k))
		return real keyidx(k);
	return atomidx[k];
}

# ---- objects ----

# kinds
Kord, Karray, Kfunc, Knative, Kbound, Kerror, Kprim, Kdate, Kregexp,
Kmap, Kset, Kweakmap, Kweakset, Kpromise, Kproxy, Kargs, Kenv, Kgen,
Kiter, Kforin, Kabuf, Ktyped, Kdview, Kweakref, Kfinreg, Kmodns: con iota;
Kfree: con -1;

# object flags
Oext: con 1 << 0;		# extensible
Oidxprops: con 1 << 1;	# some index keys are in the shape, not the elements
Ocallable: con 1 << 2;
Octor: con 1 << 3;		# a constructor
Oclassctor: con 1 << 4;	# a class constructor: not callable without new
Oarrlenro: con 1 << 5;	# an array whose length is not writable
Ohtmldda: con 1 << 6;

# attributes
Awrite: con 1 << 0;
Aenum: con 1 << 1;
Aconf: con 1 << 2;
Aacc: con 1 << 3;
Adefault: con Awrite | Aenum | Aconf;

okind: array of int;
oflags: array of int;
oshape: array of ref Shape;
oproto: array of int;		# a handle, or -1 for null
oslots: array of array of V;
oelems: array of array of V;	# indexed properties with the default attributes; Tempty: a hole
onelem: array of int;		# elements in use
oalen: array of real;		# an array's length
odata: array of ref Data;
omark: array of byte;
nobj := 0;
ofree: array of int;
nofree := 0;
objsince := 0;
gcwanted := 0;
gcstress := 0;	# collect after this many objects or strings, to find what is not a root

# an object the collector freed is used: under stress, said where
freeduse(what: string)
{
	sys->fprint(sys->fildes(2), "js: freed object used: %s (last native %s, %d frames, %d collections)%s\n", what, lastnative, nframe, ncollect, tracetext(errtrace()));
	raise "js: freed object used";
}
gcobjlimit := 100000;
gcstrlimit := 200000;

objinit()
{
	n := 4096;
	okind = array[n] of int;
	oflags = array[n] of int;
	oshape = array[n] of ref Shape;
	oproto = array[n] of int;
	oslots = array[n] of array of V;
	oelems = array[n] of array of V;
	onelem = array[n] of int;
	oalen = array[n] of real;
	odata = array[n] of ref Data;
	omark = array[n] of byte;
	ofree = array[n] of int;
}

# a realm's budget: the rows it may hold (docs/JS-ENGINE.md §10, per-realm accounting)
Maxrows := 4*1024*1024;

objgrow()
{
	n := 2 * len okind;
	if(n > Maxrows)
		throwerr(RangeError, "out of memory: too many objects");
	a := array[n] of int; a[0:] = okind; okind = a;
	a = array[n] of int; a[0:] = oflags; oflags = a;
	s := array[n] of ref Shape; s[0:] = oshape; oshape = s;
	a = array[n] of int; a[0:] = oproto; oproto = a;
	v := array[n] of array of V; v[0:] = oslots; oslots = v;
	v = array[n] of array of V; v[0:] = oelems; oelems = v;
	a = array[n] of int; a[0:] = onelem; onelem = a;
	r := array[n] of real; r[0:] = oalen; oalen = r;
	d := array[n] of ref Data; d[0:] = odata; odata = d;
	m := array[n] of byte; m[0:] = omark; omark = m;
	a = array[n] of int; a[0:] = ofree[0:nofree]; ofree = a;
}

newobj(kind, proto: int): int
{
	h: int;
	if(nofree > 0)
		h = ofree[--nofree];
	else {
		if(nobj == len okind)
			objgrow();
		h = nobj++;
	}
	okind[h] = kind;
	oflags[h] = Oext;
	oshape[h] = rootshape;
	oproto[h] = proto;
	oslots[h] = nil;
	oelems[h] = nil;
	onelem[h] = 0;
	oalen[h] = 0.0;
	odata[h] = nil;
	if(++objsince > gcobjlimit)
		gcwanted = 1;
	return h;
}

# an ordinary object whose prototype is %Object.prototype%
newplain(): int
{
	return newobj(Kord, iobjproto);
}

# ---- internal slots ----

Native: type ref fn(this: V, a, n: int, nt: V, f: int): V;

Data: adt {
	pick {
	Func =>
		code:	ref Code;
		env:	int;		# the closure's environment, or -1
		home:	int;		# the home object, for super, or -1
		fieldfns:	int;	# a class constructor's field initialisers (an array), or -1
		privmeths:	list of (int, V, int);	# its instances' private methods: (name, function, kind)
		fieldkey:	V;	# a field initialiser's key
		isfield:	int;	# 1: a field initialiser; 2: one waiting for its computed key
	Native =>
		f:	Native;
		name:	string;
		cap:	array of V;	# what the function closes over (resolving functions, and the like)
	Bound =>
		target:	int;
		this:	V;
		args:	array of V;
	Prim =>
		v:	V;		# Boolean, Number, String, Symbol, BigInt wrappers; Date's time value
	Error =>
		trace:	list of (ref Code, int);	# where it was made: (code, pc), innermost first
	Env =>
		scope:	ref Scope;	# the names, for eval and with; nil for a function's plain closure env
		withobj:	int;	# a with statement's object, or -1
	Map =>
		keys:	array of V;	# Tempty: deleted
		vals:	array of V;
		n:	int;		# entries used (deleted included)
		size:	int;
		index:	array of list of int;
	Promise =>
		state:	int;
		result:	V;
		reactions:	list of ref Reaction;
		handled:	int;
	Proxy =>
		target, handler:	int;	# -1 when revoked
	Regexp =>
		pat:	ref Jsre->Pattern;
		source:	string;
		flags:	string;
		prog:	ref Reprog;
	Gen =>
		g:	ref Genstate;
	Iter =>
		kind:	int;		# what it iterates
		target:	V;
		i:	int;
		done:	int;
	Forin =>
		keys:	array of int;
		i:	int;
		obj:	int;
		visited:	list of int;
	Args =>
		env:	int;		# a mapped arguments object's environment
		map:	array of int;	# per argument: the env slot it aliases, or -1
	Abuf =>
		b:	array of byte;
		detached:	int;
		maxlen:	int;
	Typed =>
		ty:	int;
		buf:	int;
		off, n:	int;
		tracking:	int;
	Weakref =>
		target:	V;
	}
};

# ---- shapes ----
#
# A shape maps keys to slots, in the order they were added.  Shapes are
# shared by objects built the same way, and immutable but for the
# transitions out of them; an object that deletes or reconfigures a
# property, or grows large, gets a shape of its own that it changes in
# place (a dictionary).

# Shape is in jsjit.m, shared with compiled code

rootshape: ref Shape;

Linear: con 8;		# shapes this small are searched, larger ones hashed
Dictmin: con 64;		# shapes that grow this large become dictionaries

shapeinit()
{
	rootshape = ref Shape(array[0] of int, array[0] of int, 0, nil, nil, 0, 0);
}

keyhash(k: int, n: int): int
{
	return (k * 1640531527 & 16r7FFFFFFF) % n;
}

slotof(sh: ref Shape, k: int): int
{
	if(sh.index != nil) {
		for(l := sh.index[keyhash(k, len sh.index)]; l != nil; l = tl l)
			if((hd l).t0 == k)
				return (hd l).t1;
		return -1;
	}
	keys := sh.keys;
	for(i := 0; i < sh.n; i++)
		if(keys[i] == k)
			return i;
	return -1;
}

reindex(sh: ref Shape)
{
	if(sh.n <= Linear) {
		sh.index = nil;
		return;
	}
	ix := array[2 * sh.n + 7] of list of (int, int);
	for(i := 0; i < sh.n; i++) {
		b := keyhash(sh.keys[i], len ix);
		ix[b] = (sh.keys[i], i) :: ix[b];
	}
	sh.index = ix;
}

addkey(sh: ref Shape, k, attrs: int): ref Shape
{
	if(sh.owned) {
		if(sh.n == len sh.keys) {
			nk := array[2 * sh.n + 4] of int;
			nk[0:] = sh.keys[0:sh.n];
			sh.keys = nk;
			na := array[2 * sh.n + 4] of int;
			na[0:] = sh.attrs[0:sh.n];
			sh.attrs = na;
		}
		sh.keys[sh.n] = k;
		sh.attrs[sh.n] = attrs;
		sh.n++;
		sh.gen++;
		if(sh.index != nil) {
			b := keyhash(k, len sh.index);
			sh.index[b] = (k, sh.n - 1) :: sh.index[b];
			if(sh.n > len sh.index)
				reindex(sh);
		} else if(sh.n > Linear)
			reindex(sh);
		return sh;
	}
	for(l := sh.trans; l != nil; l = tl l) {
		(tk, ta, ts) := hd l;
		if(tk == k && ta == attrs)
			return ts;
	}
	n := sh.n + 1;
	nk := array[n] of int;
	nk[0:] = sh.keys[0:sh.n];
	nk[sh.n] = k;
	na := array[n] of int;
	na[0:] = sh.attrs[0:sh.n];
	na[sh.n] = attrs;
	ns := ref Shape(nk, na, n, nil, nil, n >= Dictmin, 0);
	reindex(ns);
	if(!ns.owned)
		sh.trans = (k, attrs, ns) :: sh.trans;
	return ns;
}

# give h a shape of its own
ownshape(h: int): ref Shape
{
	sh := oshape[h];
	if(sh.owned)
		return sh;
	ns := ref Shape(sh.keys[0:sh.n], sh.attrs[0:sh.n], sh.n, nil, nil, 1, 0);
	ns.keys = array[sh.n + 4] of int;
	ns.keys[0:] = sh.keys[0:sh.n];
	ns.attrs = array[sh.n + 4] of int;
	ns.attrs[0:] = sh.attrs[0:sh.n];
	reindex(ns);
	oshape[h] = ns;
	return ns;
}

# ---- own properties ----

# add a property h does not have
addprop(h, k, attrs: int, v: V)
{
	if(isidx(k) || atomidx[k] >= 0.0) {
		if(attrs == Adefault && isidx(k) && addelem(h, keyidx(k), v))
			return;
		oflags[h] |= Oidxprops;
	}
	sh := addkey(oshape[h], k, attrs);
	oshape[h] = sh;
	slot := sh.n - 1;
	s := oslots[h];
	if(s == nil || slot >= len s) {
		ns := array[2 * slot + 4] of V;
		if(s != nil)
			ns[0:] = s;
		oslots[h] = ns;
		s = ns;
	}
	s[slot] = v;
}

# put element i if the elements can hold it densely
addelem(h, i: int, v: V): int
{
	if(oflags[h] & Oidxprops)
		return 0;
	e := oelems[h];
	n := onelem[h];
	if(i < n) {
		e[i] = v;
		return 1;
	}
	if(i > 2 * n + 16)
		return 0;	# sparse: in the shape instead
	if(e == nil || i >= len e) {
		ne := array[2 * i + 8] of V;
		if(e != nil)
			ne[0:] = e[0:n];
		e = ne;
		oelems[h] = e;
	}
	for(j := n; j < i; j++)
		e[j] = empty;
	e[i] = v;
	onelem[h] = i + 1;
	return 1;
}

# the elements, moved into the shape (before an element is given other attributes)
spill(h: int)
{
	e := oelems[h];
	n := onelem[h];
	oelems[h] = nil;
	onelem[h] = 0;
	oflags[h] |= Oidxprops;
	for(i := 0; i < n; i++)
		if(e[i].t != Tempty) {
			sh := addkey(oshape[h], idxkey(i), Adefault);
			oshape[h] = sh;
			slot := sh.n - 1;
			s := oslots[h];
			if(s == nil || slot >= len s) {
				ns := array[2 * slot + 4] of V;
				if(s != nil)
					ns[0:] = s;
				oslots[h] = ns;
				s = ns;
			}
			s[slot] = e[i];
		}
}

# h's own property k: (found, value, attributes); an accessor's value is Tacc
getownprop(h, k: int): (int, V, int)
{
	if(isidx(k)) {
		i := keyidx(k);
		if(i < onelem[h]) {
			v := oelems[h][i];
			if(v.t != Tempty)
				return (1, v, Adefault);
		}
		case okind[h] {
		Kprim =>
			pick d := odata[h] {
			Prim =>
				if(d.v.t == Tstr && i < slen[d.v.x])
					return (1, strv(str(d.v.x)[i:i+1]), Aenum);
			}
		Ktyped =>
			return typedgetown(h, i);
		}
		if((oflags[h] & Oidxprops) == 0)
			return (0, undef, 0);
	} else if(okind[h] == Ktyped && istakey(k))
		return typedgetownk(h, k);
	sh := oshape[h];
	slot := slotof(sh, k);
	if(slot < 0) {
		if(okind[h] == Karray && k == alength)
			return (1, num(oalen[h]), Awrite * ((oflags[h] & Oarrlenro) == 0));
		if(okind[h] == Kprim && k == alength)
			pick d := odata[h] {
			Prim =>
				if(d.v.t == Tstr)
					return (1, num(real slen[d.v.x]), 0);
			}
		return (0, undef, 0);
	}
	return (1, oslots[h][slot], sh.attrs[slot]);
}

# set an existing own data property's value, or add one; no checks
putown(h, k: int, v: V)
{
	if(isidx(k)) {
		i := keyidx(k);
		if(i < onelem[h] && oelems[h][i].t != Tempty) {
			oelems[h][i] = v;
			return;
		}
	}
	slot := slotof(oshape[h], k);
	if(slot >= 0) {
		oslots[h][slot] = v;
		return;
	}
	addprop(h, k, Adefault, v);
	if(okind[h] == Karray)
		arraygrew(h, k);
}

# after adding index k to array h, its length
arraygrew(h, k: int)
{
	ix := keyindex(k);
	if(ix >= oalen[h])
		oalen[h] = ix + 1.0;
}

# define an own data property outright (built-ins, literals): replaces any
defown(h, k, attrs: int, v: V)
{
	if(isidx(k) && attrs == Adefault) {
		i := keyidx(k);
		if(i < onelem[h]) {
			oelems[h][i] = v;
			if(okind[h] == Karray)
				arraygrew(h, k);
			return;
		}
	}
	slot := slotof(oshape[h], k);
	if(slot >= 0) {
		sh := oshape[h];
		if(sh.attrs[slot] != attrs) {
			sh = ownshape(h);
			sh.attrs[slot] = attrs;
			sh.gen++;
		}
		oslots[h][slot] = v;
		return;
	}
	if(isidx(k) && attrs != Adefault && keyidx(k) < onelem[h] + 1 && (oflags[h] & Oidxprops) == 0) {
		spill(h);
		slot = slotof(oshape[h], k);
		if(slot >= 0) {
			sh := ownshape(h);
			sh.attrs[slot] = attrs;
			sh.gen++;
			oslots[h][slot] = v;
			return;
		}
	}
	addprop(h, k, attrs, v);
	if(okind[h] == Karray && keyindex(k) >= 0.0)
		arraygrew(h, k);
}

# remove own property k (no checks)
removeown(h, k: int)
{
	if(isidx(k)) {
		i := keyidx(k);
		if(i < onelem[h]) {
			oelems[h][i] = empty;
			if(i == onelem[h] - 1) {
				n := i;
				while(n > 0 && oelems[h][n-1].t == Tempty)
					n--;
				onelem[h] = n;
			}
			return;
		}
	}
	sh := oshape[h];
	slot := slotof(sh, k);
	if(slot < 0)
		return;
	sh = ownshape(h);
	s := oslots[h];
	for(i := slot; i < sh.n - 1; i++) {
		sh.keys[i] = sh.keys[i+1];
		sh.attrs[i] = sh.attrs[i+1];
		s[i] = s[i+1];
	}
	sh.n--;
	sh.gen++;
	s[sh.n] = undef;
	reindex(sh);
}

# h's own keys in the specification's order: indices ascending, then strings, then symbols
ownkeys(h: int): array of int
{
	if(okind[h] == Kproxy)
		return proxyownkeys(h);
	if(okind[h] == Kmodns)
		return modnsownkeys(h);
	extra := 0;	# a String object's characters, a typed array's elements
	if(okind[h] == Kprim)
		pick d := odata[h] {
		Prim =>
			if(d.v.t == Tstr)
				extra = slen[d.v.x];
		}
	if(okind[h] == Ktyped)
		extra = typedlen(h);
	ek: list of int;
	for(i := 0; i < extra; i++)
		ek = idxkey(i) :: ek;
	e := oelems[h];
	for(i = 0; i < onelem[h]; i++)
		if(e[i].t != Tempty && i >= extra)
			ek = idxkey(i) :: ek;
	elemkeys := array[len ek] of int;
	for(i = len elemkeys - 1; i >= 0; i--) {
		elemkeys[i] = hd ek;
		ek = tl ek;
	}
	sh := oshape[h];
	idx: list of (real, int);
	strs: list of int;
	syms: list of int;
	if(okind[h] == Karray || extra > 0 && okind[h] == Kprim)
		strs = alength :: strs;
	for(i = 0; i < sh.n; i++) {
		k := sh.keys[i];
		if(k >= 0 && atomsym[k] == byte 2)
			continue;	# a private name: never a key
		ix := keyindex(k);
		if(ix >= 0.0)
			idx = (ix, k) :: idx;
		else if(issymkey(k))
			syms = k :: syms;
		else
			strs = k :: strs;
	}
	ix := mergeidx(elemkeys, sortidx(idx));
	r := array[len ix + len strs + len syms] of int;
	r[0:] = ix;
	j := len ix;
	for(l := revl(strs); l != nil; l = tl l)
		r[j++] = hd l;
	for(l = revl(syms); l != nil; l = tl l)
		r[j++] = hd l;
	return r;
}

revl(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

sortidx(l: list of (real, int)): array of int
{
	n := len l;
	a := array[n] of (real, int);
	for(i := 0; i < n; i++) {
		a[i] = hd l;
		l = tl l;
	}
	# insertion sort: shapes rarely hold many index keys
	for(i = 1; i < n; i++) {
		x := a[i];
		j := i - 1;
		while(j >= 0 && a[j].t0 > x.t0) {
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = x;
	}
	r := array[n] of int;
	for(i = 0; i < n; i++)
		r[i] = a[i].t1;
	return r;
}

# two ascending lists of index keys, merged
mergeidx(a, b: array of int): array of int
{
	r := array[len a + len b] of int;
	i := 0;
	j := 0;
	k := 0;
	while(i < len a && j < len b) {
		if(keyindex(a[i]) <= keyindex(b[j]))
			r[k++] = a[i++];
		else
			r[k++] = b[j++];
	}
	while(i < len a)
		r[k++] = a[i++];
	while(j < len b)
		r[k++] = b[j++];
	return r;
}

# ---- the collector ----

markstk: array of int;
nmark := 0;
ncollect := 0;

markv(v: V)
{
	case v.t {
	Tobj =>
		marko(v.x);
	Tstr =>
		marks(v.x);
	Tsym =>
		;
	Tacc =>
		if(v.x >= 0)
			marko(v.x);
		if(v.n >= 0.0)
			marko(int v.n);
	Tbig =>
		marks(v.x);	# a BigInt is its decimal digits, as a string row
	Timport =>
		marko(v.x);	# a module import: the exporting module's environment
	}
}

marks(h: int)
{
	while(smark[h] == byte 0) {
		smark[h] = byte 1;
		if(sleft[h] < 0 || sflat[h] != nil)
			return;
		marks(sleft[h]);
		h = sright[h];
	}
}

marko(h: int)
{
	# (a register not yet written may hold a stale handle: a freed row is skipped)
	if(h < 0 || h >= nobj || omark[h] != byte 0 || okind[h] == Kfree)
		return;
	omark[h] = byte 1;
	if(nmark == len markstk) {
		a := array[2 * nmark] of int;
		a[0:] = markstk;
		markstk = a;
	}
	markstk[nmark++] = h;
}

collect()
{
	collecting = 1;
	ncollect++;
	for(h := 0; h < nobj; h++)
		omark[h] = byte 0;
	for(h = 0; h < nstr; h++)
		smark[h] = byte 0;
	if(markstk == nil)
		markstk = array[4096] of int;
	nmark = 0;
	# roots
	for(i := 0; i < natom; i++)
		if(atomsh[i] >= 0)
			smark[atomsh[i]] = byte 1;
	for(i = 0; i < sp; i++)
		markv(vs[i]);
	for(i = 0; i < nintr; i++)
		marko(intr[i]);
	markroots();
	# the graph
	weaks: list of int;
	while(nmark > 0) {
		h = markstk[--nmark];
		if(oproto[h] >= 0)
			marko(oproto[h]);
		s := oslots[h];
		n := oshape[h].n;
		if(okind[h] == Kenv && s != nil)
			n = len s;	# an environment's slots are named by its scope, not a shape
		for(i = 0; i < n; i++)
			markv(s[i]);
		e := oelems[h];
		for(i = 0; i < onelem[h]; i++)
			markv(e[i]);
		if(odata[h] != nil) {
			if(okind[h] == Kweakmap || okind[h] == Kweakset || okind[h] == Kweakref)
				weaks = h :: weaks;
			else
				markdata(odata[h]);
		}
		if(nmark == 0 && weaks != nil) {
			# ephemerons: a weak map's value is live while its key is
			weaks = markweak(weaks);
		}
	}
	clearweak(weaks);
	# sweep
	nofree = 0;
	for(h = nobj - 1; h >= 0; h--)
		if(omark[h] == byte 0 && okind[h] != Kfree) {
			okind[h] = Kfree;
			oshape[h] = nil;
			oslots[h] = nil;
			oelems[h] = nil;
			odata[h] = nil;
		}
	# (under stress the rows freed are not used again, so that a use of
	# one finds it free)
	for(h = nobj - 1; h >= 0 && gcstress == 0; h--)
		if(okind[h] == Kfree)
			ofree[nofree++] = h;
	nsfree = 0;
	for(h = nstr - 1; h >= 0; h--)
		if(smark[h] == byte 0) {
			sflat[h] = nil;
			sleft[h] = -1;
			sfree[nsfree++] = h;
		}
	live := nobj - nofree;
	gcobjlimit = live;
	if(gcobjlimit < 100000)
		gcobjlimit = 100000;
	gcstrlimit = nstr - nsfree;
	if(gcstrlimit < 200000)
		gcstrlimit = 200000;
	if(gcstress > 0) {
		gcobjlimit = gcstress;
		gcstrlimit = gcstress;
	}
	objsince = 0;
	strsince = 0;
	gcwanted = 0;
	collecting = 0;
}

markdata(d: ref Data)
{
	pick x := d {
	Func =>
		marko(x.env);
		marko(x.home);
		marko(x.fieldfns);
		for(l := x.privmeths; l != nil; l = tl l)
			markv((hd l).t1);
		markv(x.fieldkey);
		markcode(x.code);
	Native =>
		for(i := 0; i < len x.cap; i++)
			markv(x.cap[i]);
	Bound =>
		marko(x.target);
		markv(x.this);
		for(i := 0; i < len x.args; i++)
			markv(x.args[i]);
	Prim =>
		markv(x.v);
	Env =>
		if(x.withobj < -1)
			marko(-2 - x.withobj);	# eval's vars
		else
			marko(x.withobj);
	Map =>
		for(i := 0; i < x.n; i++) {
			markv(x.keys[i]);
			markv(x.vals[i]);
		}
	Promise =>
		markv(x.result);
		for(l := x.reactions; l != nil; l = tl l)
			markreaction(hd l);
	Proxy =>
		marko(x.target);
		marko(x.handler);
	Gen =>
		markgen(x.g);
	Iter =>
		markv(x.target);
	Forin =>
		marko(x.obj);
	Args =>
		marko(x.env);
	Typed =>
		marko(x.buf);
	}
}

# weak maps whose keys are now marked mark their values; the rest wait
markweak(weaks: list of int): list of int
{
	rest: list of int;
	for(; weaks != nil; weaks = tl weaks) {
		h := hd weaks;
		pick m := odata[h] {
		Map =>
			waiting := 0;
			for(i := 0; i < m.n; i++) {
				k := m.keys[i];
				if(k.t == Tempty)
					continue;
				if(isliveweak(k)) {
					if(okind[h] == Kweakmap)
						markv(m.vals[i]);
				} else
					waiting = 1;
			}
			if(waiting)
				rest = h :: rest;
		Weakref =>
			;
		}
	}
	return rest;
}

isliveweak(k: V): int
{
	if(k.t == Tobj)
		return omark[k.x] != byte 0;
	return 1;	# symbols are atoms, never freed
}

# entries whose keys died go; weak refs to the dead are emptied
clearweak(weaks: list of int)
{
	for(h := 0; h < nobj; h++) {
		if(omark[h] == byte 0)
			continue;
		case okind[h] {
		Kweakmap or Kweakset =>
			pick m := odata[h] {
			Map =>
				for(i := 0; i < m.n; i++)
					if(m.keys[i].t != Tempty && !isliveweak(m.keys[i])) {
						m.keys[i] = empty;
						m.vals[i] = undef;
						m.size--;
						m.index = nil;
					}
			}
		Kweakref =>
			pick w := odata[h] {
			Weakref =>
				if(w.target.t == Tobj && omark[w.target.x] == byte 0)
					w.target = undef;
			}
		}
	}
	weaks = nil;
}

# ---- numbers and strings ----

# Number::toString(10): the shortest digits that read back as x
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
	if(x < 1e21 && x == real big x && x < 9007199254740992.0)
		return string big x;
	# the fewest significant digits that round-trip
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
	# strip trailing zeros
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

# "d.ddde[+-]xx" to its digits and exponent
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

# a decimal's value; the emulator's strtod (libmath/dtoa.c) is wrong or
# does not return for some subnormal values, so those are scaled into
# the normal range first, at the cost of a second rounding
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

# the significant digits of a decimal and the exponent of the first: 0.0012 is ("12", -3)
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

# StringToNumber
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
	# StrUnsignedDecimalLiteral: digits [. digits] [e [+-] digits], or . digits ...
	st := i;
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
	st = 0;
	v := decimal(s);
	if(v == 0.0 && s[0] == '-')
		return -0.0;	# (the conversion loses zero's sign)
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
