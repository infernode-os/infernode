#
# jsarray.b - Array and the array iterator (ECMAScript 2025 §23.1).
# Included by js.b.
#
# The methods are generic: they work on any object through Get, Set,
# HasProperty and DeletePropertyOrThrow, as the specification has them.
#

arrayinit()
{
	iarrctor = ctor("Array", 1, arrayctor, iarrproto);
	c := iarrctor;
	method(c, "isArray", 1, array_isarray);
	method(c, "of", 0, array_of);
	method(c, "from", 1, array_from);
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	p := iarrproto;
	defown(p, alength, Awrite, num(0.0));
	oalen[p] = 0.0;
	method(p, "at", 1, arr_at);
	method(p, "concat", 1, arr_concat);
	method(p, "copyWithin", 2, arr_copywithin);
	method(p, "entries", 0, arr_entries);
	method(p, "every", 1, arr_every);
	method(p, "fill", 1, arr_fill);
	method(p, "filter", 1, arr_filter);
	method(p, "find", 1, arr_find);
	method(p, "findIndex", 1, arr_findindex);
	method(p, "findLast", 1, arr_findlast);
	method(p, "findLastIndex", 1, arr_findlastindex);
	method(p, "flat", 0, arr_flat);
	method(p, "flatMap", 1, arr_flatmap);
	method(p, "forEach", 1, arr_foreach);
	method(p, "includes", 1, arr_includes);
	method(p, "indexOf", 1, arr_indexof);
	method(p, "join", 1, arr_join);
	method(p, "keys", 0, arr_keys);
	method(p, "lastIndexOf", 1, arr_lastindexof);
	method(p, "map", 1, arr_map);
	method(p, "pop", 0, arr_pop);
	method(p, "push", 1, arr_push);
	method(p, "reduce", 1, arr_reduce);
	method(p, "reduceRight", 1, arr_reduceright);
	method(p, "reverse", 0, arr_reverse);
	method(p, "shift", 0, arr_shift);
	method(p, "slice", 2, arr_slice);
	method(p, "some", 1, arr_some);
	method(p, "sort", 1, arr_sort);
	method(p, "splice", 2, arr_splice);
	method(p, "toLocaleString", 0, arr_tolocalestring);
	method(p, "toReversed", 0, arr_toreversed);
	method(p, "toSorted", 1, arr_tosorted);
	method(p, "toSpliced", 2, arr_tospliced);
	method(p, "toString", 0, arr_tostring);
	method(p, "unshift", 1, arr_unshift);
	iarrvalues = keep(method(p, "values", 0, arr_values));
	defown(p, asymiterator, Awrite|Aconf, objv(iarrvalues));
	method(p, "with", 2, arr_with);
	u := newobj(Kord, -1);
	names := array[] of {"at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast",
		"findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values"};
	for(i := 0; i < len names; i++)
		addprop(u, intern(names[i]), Adefault, vtrue);
	defown(p, asymunscopables, Aconf, objv(u));
	# the array iterator
	iarriternext = keep(method(iarrayiterproto, "next", 0, arriter_next));
	tag(iarrayiterproto, "Array Iterator");
}

returnthis(this: V, nil, nil: int, nil: V, nil: int): V
{
	return this;
}

# ---- helpers ----

idxk(i: real): int
{
	if(i >= 0.0 && i <= real Idxmax)
		return idxkey(int i);
	return strkey(numstr(i));
}

getidx(o: V, i: real): V
{
	if(o.t == Tobj) {
		h := o.x;
		if(i >= 0.0 && i < real onelem[h] && okind[h] != Kargs && okind[h] != Kproxy) {
			v := oelems[h][int i];
			if(v.t != Tempty)
				return v;
		}
		return get(h, idxk(i), o);
	}
	return getv(o, idxk(i));
}

setidx(o: V, i: real, v: V)
{
	setv(o, idxk(i), v, 1);
}

hasidx(o: V, i: real): int
{
	h := o.x;
	if(i >= 0.0 && i < real onelem[h] && oelems[h][int i].t != Tempty && okind[h] != Kproxy)
		return 1;
	return hasprop(h, idxk(i));
}

delidx(o: V, i: real)
{
	if(!delete(o.x, idxk(i)))
		typeerr("cannot delete property '" + numstr(i) + "'");
}

setlength(o: V, n: real)
{
	setv(o, alength, num(n), 1);
}

callback(f: V, name: string)
{
	if(!iscallable(f))
		typeerr(show(f) + " is not a function (in Array.prototype." + name + ")");
}

# a relative index (negative from the end), clamped to [0, len]
relidx(v: V, length: real, dflt: real): real
{
	if(v.t == Tundef)
		return dflt;
	x := tointorinf(v);
	if(x < 0.0) {
		x += length;
		if(x < 0.0)
			x = 0.0;
	} else if(x > length)
		x = length;
	return x;
}

# ArraySpeciesCreate
speciescreate(o: V, n: real): V
{
	if(!isarray(o))
		return objv(arraycreate(n, iarrproto));
	c := getv(o, aconstructor);
	if(isctor(c)) {
		# another realm's Array: there is no other realm
		;
	}
	if(c.t == Tobj) {
		c = getv(c, asymspecies);
		if(c.t == Tnull)
			c = undef;
	}
	if(c.t == Tundef)
		return objv(arraycreate(n, iarrproto));
	if(!isctor(c))
		typeerr("species is not a constructor");
	return construct(c, array[] of {num(n)}, c);
}

# ArrayCreate
arraycreate(n: real, proto: int): int
{
	if(n > 4294967295.0)
		throwerr(RangeError, "invalid array length");
	h := newobj(Karray, proto);
	oalen[h] = n;
	return h;
}

# ---- the constructor ----

arrayctor(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		nt = objv(f);
	proto := protofromctor(nt, iarrproto);
	if(n == 0)
		return objv(arraycreate(0.0, proto));
	if(n == 1) {
		l := vs[a];
		if(l.t != Tnum) {
			h := arraycreate(0.0, proto);
			arrpush(h, l);
			return objv(h);
		}
		il := touint32(l);
		if(il != l.n)
			throwerr(RangeError, "invalid array length");
		return objv(arraycreate(il, proto));
	}
	h := arraycreate(0.0, proto);
	for(i := 0; i < n; i++)
		arrpush(h, vs[a+i]);
	return objv(h);
}

array_isarray(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(isarray(arg(a, n, 0)));
}

array_of(this: V, a, n: int, nil: V, nil: int): V
{
	r: V;
	if(isctor(this))
		r = construct(this, array[] of {num(real n)}, this);
	else
		r = objv(arraycreate(real n, iarrproto));
	sp0 := sp;
	push(r);
	for(i := 0; i < n; i++)
		createdataorthrow(r.x, idxkey(i), vs[a+i]);
	setlength(r, real n);
	sp = sp0;
	return r;
}

array_from(this: V, a, n: int, nil: V, nil: int): V
{
	items := arg(a, n, 0);
	mapfn := arg(a, n, 1);
	thisarg := arg(a, n, 2);
	mapping := mapfn.t != Tundef;
	if(mapping && !iscallable(mapfn))
		typeerr(show(mapfn) + " is not a function");
	sp0 := sp;
	usingit := getmethod(items, asymiterator);
	if(usingit.t != Tundef) {
		r: V;
		if(isctor(this))
			r = construct(this, nil, this);
		else
			r = objv(arraycreate(0.0, iarrproto));
		push(r);
		it := call(usingit, items, nil);
		if(it.t != Tobj)
			typeerr("result of the Symbol.iterator method is not an object");
		next := getv(it, anext);
		push(it);
		push(next);
		k := 0.0;
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done) {
				setlength(r, k);
				sp = sp0;
				return r;
			}
			{
				if(mapping)
					v = call(mapfn, thisarg, array[] of {v, num(k)});
				createdataorthrow(r.x, idxk(k), v);
			} exception e {
			"js:throw" =>
				saved := thrown;
				{
					iterclose(it);
				} exception {
				"js:throw" =>
					;
				}
				thrown = saved;
				raise e;
			}
			k += 1.0;
		}
	}
	al := objv(toobject(items));
	push(al);
	l := lengthof(al);
	r: V;
	if(isctor(this))
		r = construct(this, array[] of {num(l)}, this);
	else
		r = objv(arraycreate(l, iarrproto));
	push(r);
	for(k := 0.0; k < l; k += 1.0) {
		v := getidx(al, k);
		if(mapping)
			v = call(mapfn, thisarg, array[] of {v, num(k)});
		createdataorthrow(r.x, idxk(k), v);
	}
	setlength(r, l);
	sp = sp0;
	return r;
}

# ---- the prototype's methods ----

arr_at(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0)
		k += l;
	if(k < 0.0 || k >= l)
		return undef;
	return getidx(o, k);
}

isconcatspreadable(v: V): int
{
	if(v.t != Tobj)
		return 0;
	s := getv(v, asymisconcat);
	if(s.t != Tundef)
		return truthy(s);
	return isarray(v);
}

arr_concat(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	r := speciescreate(o, 0.0);
	push(r);
	k := 0.0;
	for(i := -1; i < n; i++) {
		e := o;
		if(i >= 0)
			e = vs[a+i];
		if(isconcatspreadable(e)) {
			l := lengthof(e);
			if(k + l > 9007199254740991.0)
				typeerr("array too long");
			for(j := 0.0; j < l; j += 1.0) {
				if(hasidx(e, j))
					createdataorthrow(r.x, idxk(k), getidx(e, j));
				k += 1.0;
			}
		} else {
			if(k >= 9007199254740991.0)
				typeerr("array too long");
			createdataorthrow(r.x, idxk(k), e);
			k += 1.0;
		}
	}
	setlength(r, k);
	sp = sp0;
	return r;
}

arr_copywithin(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	dst := relidx(arg(a, n, 0), l, 0.0);
	from := relidx(arg(a, n, 1), l, 0.0);
	final := relidx(arg(a, n, 2), l, l);
	count := final - from;
	if(l - dst < count)
		count = l - dst;
	dir := 1.0;
	if(from < dst && dst < from + count) {
		dir = -1.0;
		from += count - 1.0;
		dst += count - 1.0;
	}
	while(count > 0.0) {
		if(hasidx(o, from))
			setidx(o, dst, getidx(o, from));
		else
			delidx(o, dst);
		from += dir;
		dst += dir;
		count -= 1.0;
	}
	return o;
}

# iteration kinds
Ikeys, Ivalues, Ientries: con iota;

arrayiter(o: V, kind: int): V
{
	h := newobj(Kiter, iarrayiterproto);
	odata[h] = ref Data.Iter(kind, o, 0, 0);
	return objv(h);
}

arr_entries(this: V, nil, nil: int, nil: V, nil: int): V
{
	return arrayiter(objv(toobject(this)), Ientries);
}

arr_keys(this: V, nil, nil: int, nil: V, nil: int): V
{
	return arrayiter(objv(toobject(this)), Ikeys);
}

arr_values(this: V, nil, nil: int, nil: V, nil: int): V
{
	return arrayiter(objv(toobject(this)), Ivalues);
}

arriter_next(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj || okind[this.x] != Kiter || oproto[this.x] < 0)
		typeerr("next method called on incompatible receiver " + show(this));
	pick d := odata[this.x] {
	Iter =>
		if(d.kind > Ientries)
			typeerr("next method called on incompatible receiver");
		if(d.done)
			return iterresult(undef, 1);
		o := d.target;
		l: real;
		if(o.t == Tobj && okind[o.x] == Ktyped)
			l = real typedlen(o.x);
		else
			l = lengthof(o);
		i := d.i;
		if(real i >= l) {
			d.done = 1;
			d.target = undef;
			return iterresult(undef, 1);
		}
		d.i = i + 1;
		case d.kind {
		Ikeys =>
			return iterresult(num(real i), 0);
		Ivalues =>
			return iterresult(getidx(o, real i), 0);
		* =>
			v := getidx(o, real i);
			return iterresult(objv(arrayof(array[] of {num(real i), v})), 0);
		}
	}
	return undef;
}

# every/some/forEach/find...: kind
Aevery, Asome, Aforeach, Afind, Afindindex, Afindlast, Afindlastindex: con iota;

iterate(this: V, a, n: int, kind: int, name: string): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	f := arg(a, n, 0);
	callback(f, name);
	t := arg(a, n, 1);
	case kind {
	Afind or Afindindex =>
		for(k := 0.0; k < l; k += 1.0) {
			v := getidx(o, k);
			if(truthy(call(f, t, array[] of {v, num(k), o}))) {
				sp = sp0;
				if(kind == Afind)
					return v;
				return num(k);
			}
		}
		sp = sp0;
		if(kind == Afind)
			return undef;
		return num(-1.0);
	Afindlast or Afindlastindex =>
		for(k := l - 1.0; k >= 0.0; k -= 1.0) {
			v := getidx(o, k);
			if(truthy(call(f, t, array[] of {v, num(k), o}))) {
				sp = sp0;
				if(kind == Afindlast)
					return v;
				return num(k);
			}
		}
		sp = sp0;
		if(kind == Afindlast)
			return undef;
		return num(-1.0);
	}
	for(k := 0.0; k < l; k += 1.0) {
		if(!hasidx(o, k))
			continue;
		v := getidx(o, k);
		r := truthy(call(f, t, array[] of {v, num(k), o}));
		case kind {
		Aevery =>
			if(!r) {
				sp = sp0;
				return vfalse;
			}
		Asome =>
			if(r) {
				sp = sp0;
				return vtrue;
			}
		}
	}
	sp = sp0;
	case kind {
	Aevery => return vtrue;
	Asome => return vfalse;
	}
	return undef;
}

arr_every(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Aevery, "every"); }
arr_some(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Asome, "some"); }
arr_foreach(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Aforeach, "forEach"); }
arr_find(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Afind, "find"); }
arr_findindex(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Afindindex, "findIndex"); }
arr_findlast(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Afindlast, "findLast"); }
arr_findlastindex(this: V, a, n: int, nil: V, nil: int): V { return iterate(this, a, n, Afindlastindex, "findLastIndex"); }

arr_fill(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	v := arg(a, n, 0);
	k := relidx(arg(a, n, 1), l, 0.0);
	final := relidx(arg(a, n, 2), l, l);
	for(; k < final; k += 1.0)
		setidx(o, k, v);
	return o;
}

arr_filter(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	f := arg(a, n, 0);
	callback(f, "filter");
	t := arg(a, n, 1);
	r := speciescreate(o, 0.0);
	push(r);
	dst := 0.0;
	for(k := 0.0; k < l; k += 1.0) {
		if(!hasidx(o, k))
			continue;
		v := getidx(o, k);
		if(truthy(call(f, t, array[] of {v, num(k), o}))) {
			createdataorthrow(r.x, idxk(dst), v);
			dst += 1.0;
		}
	}
	sp = sp0;
	return r;
}

# FlattenIntoArray; returns the next index
flatten(target, src: V, srclen, start, depth: real, mapper, thisarg: V): real
{
	ti := start;
	for(si := 0.0; si < srclen; si += 1.0) {
		if(!hasidx(src, si))
			continue;
		e := getidx(src, si);
		if(mapper.t != Tundef)
			e = call(mapper, thisarg, array[] of {e, num(si), src});
		if(depth > 0.0 && isarray(e)) {
			sp0 := sp;
			push(e);
			ti = flatten(target, e, lengthof(e), ti, depth - 1.0, undef, undef);
			sp = sp0;
		} else {
			if(ti >= 9007199254740991.0)
				typeerr("array too long");
			createdataorthrow(target.x, idxk(ti), e);
			ti += 1.0;
		}
	}
	return ti;
}

arr_flat(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	depth := 1.0;
	if(arg(a, n, 0).t != Tundef) {
		depth = tointorinf(arg(a, n, 0));
		if(depth < 0.0)
			depth = 0.0;
	}
	r := speciescreate(o, 0.0);
	push(r);
	flatten(r, o, l, 0.0, depth, undef, undef);
	sp = sp0;
	return r;
}

arr_flatmap(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	f := arg(a, n, 0);
	callback(f, "flatMap");
	r := speciescreate(o, 0.0);
	push(r);
	flatten(r, o, l, 0.0, 1.0, f, arg(a, n, 1));
	sp = sp0;
	return r;
}

arr_includes(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(l == 0.0)
		return vfalse;
	k := tointorinf(arg(a, n, 1));
	if(k == inf)
		return vfalse;
	if(k < 0.0) {
		k += l;
		if(k < 0.0)
			k = 0.0;
	}
	x := arg(a, n, 0);
	for(; k < l; k += 1.0)
		if(samevaluezero(getidx(o, k), x))
			return vtrue;
	return vfalse;
}

arr_indexof(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(l == 0.0)
		return num(-1.0);
	k := tointorinf(arg(a, n, 1));
	if(k == inf)
		return num(-1.0);
	if(k < 0.0) {
		k += l;
		if(k < 0.0)
			k = 0.0;
	}
	x := arg(a, n, 0);
	for(; k < l; k += 1.0)
		if(hasidx(o, k) && strictequal(getidx(o, k), x))
			return num(k);
	return num(-1.0);
}

arr_lastindexof(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(l == 0.0)
		return num(-1.0);
	k := l - 1.0;
	if(n > 1) {
		k = tointorinf(vs[a+1]);
		if(k == -inf)
			return num(-1.0);
		if(k >= 0.0) {
			if(k > l - 1.0)
				k = l - 1.0;
		} else
			k += l;
	}
	x := arg(a, n, 0);
	for(; k >= 0.0; k -= 1.0)
		if(hasidx(o, k) && strictequal(getidx(o, k), x))
			return num(k);
	return num(-1.0);
}

arr_join(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	sep := ",";
	if(arg(a, n, 0).t != Tundef)
		sep = tostring(vs[a]);
	if(injoin(o.x))
		return strv("");
	joining = o.x :: joining;
	r := "";
	{
		for(k := 0.0; k < l; k += 1.0) {
			if(k > 0.0)
				r += sep;
			e := getidx(o, k);
			if(e.t != Tundef && e.t != Tnull)
				r += tostring(e);
			if(len r > Strmax)
				throwerr(RangeError, "string too long");
		}
	} exception e {
	"js:throw" =>
		joining = tl joining;
		raise e;
	}
	joining = tl joining;
	return strv(r);
}

# arrays being joined: a cycle joins as empty
joining: list of int;

injoin(h: int): int
{
	for(l := joining; l != nil; l = tl l)
		if(hd l == h)
			return 1;
	return 0;
}

arr_map(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	f := arg(a, n, 0);
	callback(f, "map");
	t := arg(a, n, 1);
	r := speciescreate(o, l);
	push(r);
	for(k := 0.0; k < l; k += 1.0) {
		if(!hasidx(o, k))
			continue;
		v := call(f, t, array[] of {getidx(o, k), num(k), o});
		createdataorthrow(r.x, idxk(k), v);
	}
	sp = sp0;
	return r;
}

arr_pop(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(l == 0.0) {
		setlength(o, 0.0);
		return undef;
	}
	i := l - 1.0;
	h := o.x;
	if(okind[h] == Karray && i < real onelem[h] && i == real (onelem[h] - 1) && (oflags[h] & (Oarrlenro|Oidxprops)) == 0 && oelems[h][int i].t != Tempty) {
		v := oelems[h][int i];
		oelems[h][int i] = empty;
		onelem[h]--;
		oalen[h] = i;
		return v;
	}
	v := getidx(o, i);
	delidx(o, i);
	setlength(o, i);
	return v;
}

arr_push(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	h := o.x;
	if(okind[h] == Karray && oalen[h] == real onelem[h] && (oflags[h] & (Oarrlenro|Oidxprops)) == 0 && (oflags[h] & Oext) && oalen[h] + real n < real Idxmax) {
		for(i := 0; i < n; i++)
			arrpush(h, vs[a+i]);
		return num(oalen[h]);
	}
	l := lengthof(o);
	if(l + real n > 9007199254740991.0)
		typeerr("array too long");
	for(i := 0; i < n; i++) {
		setidx(o, l, vs[a+i]);
		l += 1.0;
	}
	setlength(o, l);
	return num(l);
}

reduce(this: V, a, n: int, right: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	f := arg(a, n, 0);
	callback(f, "reduce");
	k := 0.0;
	step := 1.0;
	if(right) {
		k = l - 1.0;
		step = -1.0;
	}
	acc: V;
	if(n > 1)
		acc = vs[a+1];
	else {
		found := 0;
		for(; k >= 0.0 && k < l; k += step)
			if(hasidx(o, k)) {
				acc = getidx(o, k);
				found = 1;
				k += step;
				break;
			}
		if(!found)
			typeerr("reduce of empty array with no initial value");
	}
	for(; k >= 0.0 && k < l; k += step) {
		if(!hasidx(o, k))
			continue;
		acc = call(f, undef, array[] of {acc, getidx(o, k), num(k), o});
		vs[sp0] = o;
	}
	sp = sp0;
	return acc;
}

arr_reduce(this: V, a, n: int, nil: V, nil: int): V { return reduce(this, a, n, 0); }
arr_reduceright(this: V, a, n: int, nil: V, nil: int): V { return reduce(this, a, n, 1); }

arr_reverse(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	mid := math->floor(l / 2.0);
	for(lo := 0.0; lo < mid; lo += 1.0) {
		hi := l - lo - 1.0;
		le := hasidx(o, lo);
		lv := undef;
		if(le)
			lv = getidx(o, lo);
		he := hasidx(o, hi);
		hv := undef;
		if(he)
			hv = getidx(o, hi);
		if(le && he) {
			setidx(o, lo, hv);
			setidx(o, hi, lv);
		} else if(he) {
			setidx(o, lo, hv);
			delidx(o, hi);
		} else if(le) {
			delidx(o, lo);
			setidx(o, hi, lv);
		}
	}
	return o;
}

arr_shift(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(l == 0.0) {
		setlength(o, 0.0);
		return undef;
	}
	h := o.x;
	if(okind[h] == Karray && oalen[h] == real onelem[h] && (oflags[h] & (Oarrlenro|Oidxprops)) == 0 && oproto[h] == iarrproto && !protohasidx()) {
		e := oelems[h];
		n := onelem[h];
		v := e[0];
		if(v.t != Tempty) {
			for(i := 1; i < n; i++) {
				if(e[i].t == Tempty)
					break;
				e[i-1] = e[i];
			}
			if(i == n) {
				e[n-1] = empty;
				onelem[h] = n - 1;
				oalen[h] = real (n - 1);
				return v;
			}
			# a hole: undo, and go the general way
			for(j := i - 1; j >= 1; j--)
				e[j] = e[j-1];
			e[0] = v;
		}
	}
	first := getidx(o, 0.0);
	for(k := 1.0; k < l; k += 1.0) {
		if(hasidx(o, k))
			setidx(o, k - 1.0, getidx(o, k));
		else
			delidx(o, k - 1.0);
	}
	delidx(o, l - 1.0);
	setlength(o, l - 1.0);
	return first;
}

# whether Array.prototype or Object.prototype has index properties (holes would see them)
protohasidx(): int
{
	return onelem[iarrproto] > 0 || (oflags[iarrproto] & Oidxprops) || onelem[iobjproto] > 0 || (oflags[iobjproto] & Oidxprops);
}

arr_slice(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	k := relidx(arg(a, n, 0), l, 0.0);
	final := relidx(arg(a, n, 1), l, l);
	count := final - k;
	if(count < 0.0)
		count = 0.0;
	r := speciescreate(o, count);
	push(r);
	i := 0.0;
	for(; k < final; k += 1.0) {
		if(hasidx(o, k))
			createdataorthrow(r.x, idxk(i), getidx(o, k));
		i += 1.0;
	}
	setlength(r, i);
	sp = sp0;
	return r;
}

# SortCompare with comparator f (undefined: by string)
sortcompare(x, y: V, f: V): int
{
	if(x.t == Tundef && y.t == Tundef)
		return 0;
	if(x.t == Tundef)
		return 1;
	if(y.t == Tundef)
		return -1;
	if(f.t != Tundef) {
		v := tonumber(call(f, undef, array[] of {x, y}));
		if(isnan(v))
			return 0;
		if(v < 0.0)
			return -1;
		if(v > 0.0)
			return 1;
		return 0;
	}
	xs := tostring(x);
	ys := tostring(y);
	if(xs < ys)
		return -1;
	if(xs > ys)
		return 1;
	return 0;
}

# a stable merge sort of the values
mergesort(a: array of V, f: V)
{
	n := len a;
	if(n < 2)
		return;
	tmp := array[n] of V;
	for(w := 1; w < n; w *= 2) {
		for(lo := 0; lo < n; lo += 2 * w) {
			mid := lo + w;
			if(mid > n)
				mid = n;
			hi := lo + 2 * w;
			if(hi > n)
				hi = n;
			i := lo;
			j := mid;
			k := lo;
			while(i < mid && j < hi) {
				if(sortcompare(a[j], a[i], f) < 0)
					tmp[k++] = a[j++];
				else
					tmp[k++] = a[i++];
			}
			while(i < mid)
				tmp[k++] = a[i++];
			while(j < hi)
				tmp[k++] = a[j++];
		}
		a[0:] = tmp;
	}
}

# the values of o's indices below l that it has, for sorting
sortvalues(o: V, l: real, skipholes: int): array of V
{
	vals: list of V;
	n := 0;
	for(k := 0.0; k < l; k += 1.0) {
		if(skipholes && !hasidx(o, k))
			continue;
		vals = getidx(o, k) :: vals;
		n++;
	}
	a := array[n] of V;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd vals;
		vals = tl vals;
	}
	return a;
}

arr_sort(this: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(f.t != Tundef && !iscallable(f))
		typeerr("the comparison function must be either a function or undefined");
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	vals := sortvalues(o, l, 1);
	keepall(vals);
	mergesort(vals, f);
	i := 0;
	for(; i < len vals; i++)
		setidx(o, real i, vals[i]);
	for(k := real i; k < l; k += 1.0)
		if(hasidx(o, k))
			delidx(o, k);
	unkeepall(len vals);
	sp = sp0;
	return o;
}

# hold values where the collector sees them (the stack), while callbacks run
keepall(a: array of V)
{
	for(i := 0; i < len a; i++)
		push(a[i]);
}

unkeepall(nil: int)
{
}

arr_splice(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	start := relidx(arg(a, n, 0), l, 0.0);
	ins := 0;
	dc := 0.0;
	if(n == 0)
		dc = 0.0;
	else if(n == 1)
		dc = l - start;
	else {
		ins = n - 2;
		dc = tointorinf(vs[a+1]);
		if(dc < 0.0)
			dc = 0.0;
		if(dc > l - start)
			dc = l - start;
	}
	if(l + real ins - dc > 9007199254740991.0)
		typeerr("array too long");
	r := speciescreate(o, dc);
	push(r);
	for(k := 0.0; k < dc; k += 1.0)
		if(hasidx(o, start + k))
			createdataorthrow(r.x, idxk(k), getidx(o, start + k));
	setlength(r, dc);
	ic := real ins;
	if(ic < dc) {
		for(k = start; k < l - dc; k += 1.0) {
			from := k + dc;
			dst := k + ic;
			if(hasidx(o, from))
				setidx(o, dst, getidx(o, from));
			else
				delidx(o, dst);
		}
		for(k = l; k > l - dc + ic; k -= 1.0)
			delidx(o, k - 1.0);
	} else if(ic > dc) {
		for(k = l - dc; k > start; k -= 1.0) {
			from := k + dc - 1.0;
			dst := k + ic - 1.0;
			if(hasidx(o, from))
				setidx(o, dst, getidx(o, from));
			else
				delidx(o, dst);
		}
	}
	for(i := 0; i < ins; i++)
		setidx(o, start + real i, vs[a+2+i]);
	setlength(o, l - dc + ic);
	sp = sp0;
	return r;
}

arr_tolocalestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(injoin(o.x))
		return strv("");
	joining = o.x :: joining;
	r := "";
	{
		for(k := 0.0; k < l; k += 1.0) {
			if(k > 0.0)
				r += ",";
			e := getidx(o, k);
			if(e.t != Tundef && e.t != Tnull)
				r += tostring(invoke(e, intern("toLocaleString"), nil));
		}
	} exception e {
	"js:throw" =>
		joining = tl joining;
		raise e;
	}
	joining = tl joining;
	return strv(r);
}

arr_toreversed(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	r := arraycreate(l, iarrproto);
	push(objv(r));
	for(k := 0.0; k < l; k += 1.0)
		createdataorthrow(r, idxk(k), getidx(o, l - k - 1.0));
	sp = sp0;
	return objv(r);
}

arr_tosorted(this: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(f.t != Tundef && !iscallable(f))
		typeerr("the comparison function must be either a function or undefined");
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	r := arraycreate(l, iarrproto);
	push(objv(r));
	vals := sortvalues(o, l, 0);
	keepall(vals);
	mergesort(vals, f);
	for(i := 0; i < len vals; i++)
		createdataorthrow(r, idxkey(i), vals[i]);
	sp = sp0;
	return objv(r);
}

arr_tospliced(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	start := relidx(arg(a, n, 0), l, 0.0);
	ins := 0;
	skip := 0.0;
	if(n == 0)
		skip = 0.0;
	else if(n == 1)
		skip = l - start;
	else {
		ins = n - 2;
		skip = tointorinf(vs[a+1]);
		if(skip < 0.0)
			skip = 0.0;
		if(skip > l - start)
			skip = l - start;
	}
	newlen := l + real ins - skip;
	if(newlen > 9007199254740991.0)
		typeerr("array too long");
	r := arraycreate(newlen, iarrproto);
	push(objv(r));
	i := 0.0;
	for(k := 0.0; k < start; k += 1.0) {
		createdataorthrow(r, idxk(i), getidx(o, k));
		i += 1.0;
	}
	for(j := 0; j < ins; j++) {
		createdataorthrow(r, idxk(i), vs[a+2+j]);
		i += 1.0;
	}
	for(k = start + skip; k < l; k += 1.0) {
		createdataorthrow(r, idxk(i), getidx(o, k));
		i += 1.0;
	}
	sp = sp0;
	return objv(r);
}

arr_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	j := getv(o, intern("join"));
	if(iscallable(j))
		return call(j, o, nil);
	return objproto_tostring(o, 0, 0, undef, -1);
}

arr_unshift(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	l := lengthof(o);
	if(n > 0) {
		if(l + real n > 9007199254740991.0)
			typeerr("array too long");
		for(k := l; k > 0.0; k -= 1.0) {
			from := k - 1.0;
			dst := k + real n - 1.0;
			if(hasidx(o, from))
				setidx(o, dst, getidx(o, from));
			else
				delidx(o, dst);
		}
		for(j := 0; j < n; j++)
			setidx(o, real j, vs[a+j]);
	}
	setlength(o, l + real n);
	return num(l + real n);
}

arr_with(this: V, a, n: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	sp0 := sp;
	push(o);
	l := lengthof(o);
	rel := tointorinf(arg(a, n, 0));
	at := rel;
	if(rel < 0.0)
		at = l + rel;
	if(at >= l || at < 0.0)
		throwerr(RangeError, "invalid index");
	v := arg(a, n, 1);
	r := arraycreate(l, iarrproto);
	push(objv(r));
	for(k := 0.0; k < l; k += 1.0) {
		e := v;
		if(k != at)
			e = getidx(o, k);
		createdataorthrow(r, idxk(k), e);
	}
	sp = sp0;
	return objv(r);
}
