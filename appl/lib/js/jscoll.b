#
# jscoll.b - keyed collections (§24), Promise (§27.2), Reflect (§28.1),
# the iterator and generator prototypes (§27.1, §27.3-27.6).
# Included by js.b.
#

# ---- Map and Set: entries in insertion order, deleted ones emptied ----

collectionsinit()
{
	c := ctor("Map", 0, mapctor, imapproto);
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	method(c, "groupBy", 2, map_groupby);
	p := imapproto;
	method(p, "clear", 0, map_clear);
	method(p, "delete", 1, map_delete);
	entries := method(p, "entries", 0, map_entries);
	defown(p, asymiterator, Awrite|Aconf, objv(entries));
	method(p, "forEach", 1, map_foreach);
	method(p, "get", 1, map_get);
	method(p, "has", 1, map_has);
	method(p, "keys", 0, map_keys);
	method(p, "set", 2, map_set);
	getter(p, intern("size"), "size", map_size);
	method(p, "values", 0, map_values);
	method(p, "getOrInsert", 2, map_getorinsert);
	method(p, "getOrInsertComputed", 2, map_getorinsertcomputed);
	tag(p, "Map");
	method(imapiterproto, "next", 0, mapiter_next);
	tag(imapiterproto, "Map Iterator");

	c = ctor("Set", 0, setctor, isetproto);
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	p = isetproto;
	method(p, "add", 1, set_add);
	method(p, "clear", 0, map_clear);
	method(p, "delete", 1, map_delete);
	method(p, "entries", 0, set_entries);
	method(p, "forEach", 1, set_foreach);
	method(p, "has", 1, map_has);
	getter(p, intern("size"), "size", map_size);
	values := method(p, "values", 0, set_values);
	defown(p, intern("keys"), Awrite|Aconf, objv(values));
	defown(p, asymiterator, Awrite|Aconf, objv(values));
	method(p, "union", 1, set_union);
	method(p, "intersection", 1, set_intersection);
	method(p, "difference", 1, set_difference);
	method(p, "symmetricDifference", 1, set_symdiff);
	method(p, "isSubsetOf", 1, set_issubsetof);
	method(p, "isSupersetOf", 1, set_issupersetof);
	method(p, "isDisjointFrom", 1, set_isdisjointfrom);
	tag(p, "Set");
	method(isetiterproto, "next", 0, mapiter_next);
	tag(isetiterproto, "Set Iterator");

	ctor("WeakMap", 0, weakmapctor, iweakmapproto);
	p = iweakmapproto;
	method(p, "delete", 1, map_delete);
	method(p, "get", 1, map_get);
	method(p, "has", 1, map_has);
	method(p, "set", 2, map_set);
	method(p, "getOrInsert", 2, map_getorinsert);
	method(p, "getOrInsertComputed", 2, map_getorinsertcomputed);
	tag(p, "WeakMap");
	ctor("WeakSet", 0, weaksetctor, iweaksetproto);
	p = iweaksetproto;
	method(p, "add", 1, set_add);
	method(p, "delete", 1, map_delete);
	method(p, "has", 1, map_has);
	tag(p, "WeakSet");
	wrp := keep(newobj(Kord, iobjproto));
	ctor("WeakRef", 1, weakrefctor, wrp);
	method(wrp, "deref", 0, weakref_deref);
	tag(wrp, "WeakRef");
}

newmap(kind, proto: int): int
{
	h := newobj(kind, proto);
	odata[h] = ref Data.Map(array[8] of V, array[8] of V, 0, 0, nil);
	return h;
}

mapdata(this: V, kind: int, name: string): ref Data.Map
{
	if(this.t == Tobj && okind[this.x] == kind)
		pick d := odata[this.x] {
		Map =>
			return d;
		}
	typeerr(name + " called on incompatible receiver " + show(this));
	return nil;
}

# the receiver's kind, for methods shared by Map and Set (and their weak forms)
anymap(this: V, name: string): ref Data.Map
{
	if(this.t == Tobj) {
		k := okind[this.x];
		if(k == Kmap || k == Kset || k == Kweakmap || k == Kweakset)
			pick d := odata[this.x] {
			Map =>
				return d;
			}
	}
	typeerr(name + " called on incompatible receiver " + show(this));
	return nil;
}

# a key's hash, by SameValueZero
vhash(v: V): int
{
	case v.t {
	Tnum =>
		x := v.n;
		if(x == 0.0)
			return 0;
		if(isnan(x))
			return 1;
		if(x == real int x)
			return int x & 16r7FFFFFFF;
		b := math->realbits64(x);
		return int (b ^ (b >> 32)) & 16r7FFFFFFF;
	Tstr =>
		return strhash(str(v.x));
	Tbig =>
		return strhash(str(v.x));
	}
	return (v.t * 31 + v.x) & 16r7FFFFFFF;
}

mapfind(d: ref Data.Map, k: V): int
{
	if(d.index == nil || len d.index < d.n / 2)
		reindexmap(d);
	for(l := d.index[vhash(k) % len d.index]; l != nil; l = tl l) {
		i := hd l;
		if(d.keys[i].t != Tempty && samevaluezero(d.keys[i], k))
			return i;
	}
	return -1;
}

reindexmap(d: ref Data.Map)
{
	n := 2 * d.n + 16;
	d.index = array[n] of list of int;
	for(i := 0; i < d.n; i++)
		if(d.keys[i].t != Tempty) {
			b := vhash(d.keys[i]) % n;
			d.index[b] = i :: d.index[b];
		}
}

mapput(d: ref Data.Map, k, v: V)
{
	if(k.t == Tnum && k.n == 0.0)
		k = num(0.0);	# -0 is 0
	i := mapfind(d, k);
	if(i >= 0) {
		d.vals[i] = v;
		return;
	}
	if(d.n == len d.keys) {
		# compact if many are deleted, else grow
		if(d.size < d.n / 2)
			compactmap(d);
		if(d.n == len d.keys) {
			if(2 * d.n > Maxrows)
				throwerr(RangeError, "out of memory: collection too large");
			nk := array[2 * d.n] of V;
			nk[0:] = d.keys;
			d.keys = nk;
			nv := array[2 * d.n] of V;
			nv[0:] = d.vals;
			d.vals = nv;
		}
	}
	d.keys[d.n] = k;
	d.vals[d.n] = v;
	if(d.index != nil) {
		b := vhash(k) % len d.index;
		d.index[b] = d.n :: d.index[b];
	}
	d.n++;
	d.size++;
}

# drop deleted entries (only when no iterator could be past them: iterators hold indices)
compactmap(d: ref Data.Map)
{
	if(mapiterators > 0)
		return;
	j := 0;
	for(i := 0; i < d.n; i++)
		if(d.keys[i].t != Tempty) {
			d.keys[j] = d.keys[i];
			d.vals[j] = d.vals[i];
			j++;
		}
	for(i = j; i < d.n; i++) {
		d.keys[i] = empty;
		d.vals[i] = undef;
	}
	d.n = j;
	d.index = nil;
}

mapiterators := 0;	# live iterators, any map (compaction waits)

mapinit(this: V, kind: int, iterable: V, adder: int)
{
	if(iterable.t == Tundef || iterable.t == Tnull)
		return;
	add := getv(this, adder);
	if(!iscallable(add))
		typeerr("'" + atomstr[adder] + "' is not a function");
	sp0 := sp;
	push(this);
	(it, next) := getiterator(iterable, 0);
	push(it);
	push(next);
	for(;;) {
		(e, done) := iterstep(it, next);
		if(done)
			break;
		{
			if(kind == Kmap || kind == Kweakmap) {
				if(e.t != Tobj)
					typeerr("iterator value " + show(e) + " is not an entry object");
				k := getv(e, idxkey(0));
				v := getv(e, idxkey(1));
				call(add, this, array[] of {k, v});
			} else
				call(add, this, array[] of {e});
		} exception ex {
		"js:throw" =>
			saved := thrown;
			{
				iterclose(it);
			} exception {
			"js:throw" =>
				;
			}
			thrown = saved;
			raise ex;
		}
	}
	sp = sp0;
}

mapctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor Map requires 'new'");
	h := newmap(Kmap, protofromctor(nt, imapproto));
	mapinit(objv(h), Kmap, arg(a, n, 0), aset);
	return objv(h);
}

setctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor Set requires 'new'");
	h := newmap(Kset, protofromctor(nt, isetproto));
	mapinit(objv(h), Kset, arg(a, n, 0), intern("add"));
	return objv(h);
}

weakmapctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor WeakMap requires 'new'");
	h := newmap(Kweakmap, protofromctor(nt, iweakmapproto));
	mapinit(objv(h), Kweakmap, arg(a, n, 0), aset);
	return objv(h);
}

weaksetctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor WeakSet requires 'new'");
	h := newmap(Kweakset, protofromctor(nt, iweaksetproto));
	mapinit(objv(h), Kweakset, arg(a, n, 0), intern("add"));
	return objv(h);
}

# CanBeHeldWeakly
canbeheldweakly(v: V): int
{
	if(v.t == Tobj)
		return 1;
	if(v.t == Tsym) {
		for(l := symregistry; l != nil; l = tl l)
			if((hd l).t1 == v.x)
				return 0;
		return 1;
	}
	return 0;
}

isweak(this: V): int
{
	return okind[this.x] == Kweakmap || okind[this.x] == Kweakset;
}

map_clear(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := anymap(this, "clear");
	if(isweak(this))
		typeerr("clear called on incompatible receiver");
	for(i := 0; i < d.n; i++) {
		d.keys[i] = empty;
		d.vals[i] = undef;
	}
	d.size = 0;
	d.index = nil;
	return undef;
}

map_delete(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "delete");
	k := arg(a, n, 0);
	if(isweak(this) && !canbeheldweakly(k))
		return vfalse;
	i := mapfind(d, k);
	if(i < 0)
		return vfalse;
	d.keys[i] = empty;
	d.vals[i] = undef;
	d.size--;
	return vtrue;
}

map_get(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "get");
	if(okind[this.x] == Kset || okind[this.x] == Kweakset)
		typeerr("get called on incompatible receiver");
	i := mapfind(d, arg(a, n, 0));
	if(i < 0)
		return undef;
	return d.vals[i];
}

map_has(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "has");
	return bool(mapfind(d, arg(a, n, 0)) >= 0);
}

map_set(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "set");
	if(okind[this.x] == Kset || okind[this.x] == Kweakset)
		typeerr("set called on incompatible receiver");
	k := arg(a, n, 0);
	if(isweak(this) && !canbeheldweakly(k))
		typeerr("invalid value used as weak map key");
	mapput(d, k, arg(a, n, 1));
	return this;
}

map_getorinsert(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "getOrInsert");
	if(okind[this.x] == Kset || okind[this.x] == Kweakset)
		typeerr("getOrInsert called on incompatible receiver");
	k := arg(a, n, 0);
	if(isweak(this) && !canbeheldweakly(k))
		typeerr("invalid value used as weak map key");
	i := mapfind(d, k);
	if(i >= 0)
		return d.vals[i];
	mapput(d, k, arg(a, n, 1));
	return arg(a, n, 1);
}

map_getorinsertcomputed(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "getOrInsertComputed");
	if(okind[this.x] == Kset || okind[this.x] == Kweakset)
		typeerr("getOrInsertComputed called on incompatible receiver");
	k := arg(a, n, 0);
	if(isweak(this) && !canbeheldweakly(k))
		typeerr("invalid value used as weak map key");
	f := arg(a, n, 1);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	i := mapfind(d, k);
	if(i >= 0)
		return d.vals[i];
	if(k.t == Tnum && k.n == 0.0)
		k = num(0.0);
	v := call(f, undef, array[] of {k});
	mapput(d, k, v);
	return v;
}

map_size(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t == Tobj && (okind[this.x] == Kmap || okind[this.x] == Kset))
		pick d := odata[this.x] {
		Map =>
			return num(real d.size);
		}
	typeerr("get size called on incompatible receiver " + show(this));
	return undef;
}

set_add(this: V, a, n: int, nil: V, nil: int): V
{
	d := anymap(this, "add");
	if(okind[this.x] == Kmap || okind[this.x] == Kweakmap)
		typeerr("add called on incompatible receiver");
	v := arg(a, n, 0);
	if(isweak(this) && !canbeheldweakly(v))
		typeerr("invalid value used in weak set");
	if(mapfind(d, v) < 0)
		mapput(d, v, v);
	return this;
}

mapforeach(this: V, a, n: int, kind: int, name: string): V
{
	d := mapdata(this, kind, name);
	f := arg(a, n, 0);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	t := arg(a, n, 1);
	mapiterators++;
	{
		for(i := 0; i < d.n; i++) {
			if(d.keys[i].t == Tempty)
				continue;
			if(kind == Kmap)
				call(f, t, array[] of {d.vals[i], d.keys[i], this});
			else
				call(f, t, array[] of {d.keys[i], d.keys[i], this});
		}
	} exception e {
	"js:throw" =>
		mapiterators--;
		raise e;
	}
	mapiterators--;
	return undef;
}

map_foreach(this: V, a, n: int, nil: V, nil: int): V { return mapforeach(this, a, n, Kmap, "Map.prototype.forEach"); }
set_foreach(this: V, a, n: int, nil: V, nil: int): V { return mapforeach(this, a, n, Kset, "Set.prototype.forEach"); }

# map iterators: kind 20+Ikeys..Ientries; target is the map
mapiter(this: V, kind, want: int, name: string): V
{
	mapdata(this, kind, name);
	proto := imapiterproto;
	if(kind == Kset)
		proto = isetiterproto;
	h := newobj(Kiter, proto);
	odata[h] = ref Data.Iter(20 + want, this, 0, 0);
	mapiterators++;
	return objv(h);
}

map_entries(this: V, nil, nil: int, nil: V, nil: int): V { return mapiter(this, Kmap, Ientries, "Map.prototype.entries"); }
map_keys(this: V, nil, nil: int, nil: V, nil: int): V { return mapiter(this, Kmap, Ikeys, "Map.prototype.keys"); }
map_values(this: V, nil, nil: int, nil: V, nil: int): V { return mapiter(this, Kmap, Ivalues, "Map.prototype.values"); }
set_entries(this: V, nil, nil: int, nil: V, nil: int): V { return mapiter(this, Kset, Ientries, "Set.prototype.entries"); }
set_values(this: V, nil, nil: int, nil: V, nil: int): V { return mapiter(this, Kset, Ivalues, "Set.prototype.values"); }

mapiter_next(this: V, nil, nil: int, nil: V, f: int): V
{
	if(this.t != Tobj || okind[this.x] != Kiter)
		typeerr("next method called on incompatible receiver " + show(this));
	pick it := odata[this.x] {
	Iter =>
		if(it.kind < 20 || it.kind > 22)
			typeerr("next method called on incompatible receiver");
		want := oproto[this.x] == isetiterproto;
		(nil, myproto) := ownerproto(f);
		if(myproto >= 0 && myproto != oproto[this.x] && (myproto == isetiterproto) != want)
			typeerr("next method called on incompatible receiver");
		if(it.done)
			return iterresult(undef, 1);
		pick d := odata[it.target.x] {
		Map =>
			while(it.i < d.n && d.keys[it.i].t == Tempty)
				it.i++;
			if(it.i >= d.n) {
				it.done = 1;
				it.target = undef;
				mapiterators--;
				return iterresult(undef, 1);
			}
			i := it.i++;
			case it.kind - 20 {
			Ikeys => return iterresult(d.keys[i], 0);
			Ivalues => return iterresult(d.vals[i], 0);
			* => return iterresult(objv(arrayof(array[] of {d.keys[i], d.vals[i]})), 0);
			}
		}
	}
	return undef;
}

# which prototype a native method was installed on (Map's or Set's iterator), from its name
ownerproto(f: int): (int, int)
{
	if(f < 0)
		return (0, -1);
	(ok, nil, nil) := getownprop(isetiterproto, anext);
	if(ok) {
		(nil, v, nil) := getownprop(isetiterproto, anext);
		if(v.t == Tobj && v.x == f)
			return (1, isetiterproto);
	}
	return (1, imapiterproto);
}

map_groupby(nil: V, a, n: int, nil: V, nil: int): V
{
	items := arg(a, n, 0);
	cb := arg(a, n, 1);
	if(items.t == Tundef || items.t == Tnull)
		typeerr("Map.groupBy called on null or undefined");
	if(!iscallable(cb))
		typeerr(show(cb) + " is not a function");
	m := newmap(Kmap, imapproto);
	sp0 := sp;
	push(objv(m));
	(it, next) := getiterator(items, 0);
	push(it);
	push(next);
	k := 0;
	d := mapdata(objv(m), Kmap, "");
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		key: V;
		{
			key = call(cb, undef, array[] of {v, num(real k)});
		} exception ex {
		"js:throw" =>
			saved := thrown;
			{
				iterclose(it);
			} exception {
			"js:throw" =>
				;
			}
			thrown = saved;
			raise ex;
		}
		if(key.t == Tnum && key.n == 0.0)
			key = num(0.0);
		i := mapfind(d, key);
		g: V;
		if(i < 0) {
			g = objv(newarray(0));
			mapput(d, key, g);
		} else
			g = d.vals[i];
		arrpush(g.x, v);
		k++;
	}
	sp = sp0;
	return objv(m);
}

# ---- the Set methods of ES2025 (GetSetRecord) ----

Setrec: adt {
	obj:	V;
	size:	real;
	has, keys:	V;
};

getsetrecord(v: V): ref Setrec
{
	if(v.t != Tobj)
		typeerr("set-like argument must be an object");
	rs := getv(v, intern("size"));
	ns := tonumber(rs);
	if(isnan(ns))
		typeerr("set-like object's size is not a number");
	sz := tointorinf(num(ns));
	if(sz < 0.0)
		throwerr(RangeError, "set-like object's size is negative");
	has := getv(v, intern("has"));
	if(!iscallable(has))
		typeerr("set-like object's has is not a function");
	keys := getv(v, intern("keys"));
	if(!iscallable(keys))
		typeerr("set-like object's keys is not a function");
	return ref Setrec(v, sz, has, keys);
}

setkeysiter(r: ref Setrec): (V, V)
{
	it := call(r.keys, r.obj, nil);
	if(it.t != Tobj)
		typeerr("keys() result is not an object");
	return (it, getv(it, anext));
}

copyset(d: ref Data.Map): (int, ref Data.Map)
{
	h := newmap(Kset, isetproto);
	nd := mapdata(objv(h), Kset, "");
	for(i := 0; i < d.n; i++)
		if(d.keys[i].t != Tempty)
			mapput(nd, d.keys[i], d.keys[i]);
	return (h, nd);
}

set_union(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.union");
	r := getsetrecord(arg(a, n, 0));
	(h, nd) := copyset(d);
	sp0 := sp;
	push(objv(h));
	(it, next) := setkeysiter(r);
	push(it);
	push(next);
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		if(v.t == Tnum && v.n == 0.0)
			v = num(0.0);
		if(mapfind(nd, v) < 0)
			mapput(nd, v, v);
	}
	sp = sp0;
	return objv(h);
}

set_intersection(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.intersection");
	r := getsetrecord(arg(a, n, 0));
	h := newmap(Kset, isetproto);
	nd := mapdata(objv(h), Kset, "");
	sp0 := sp;
	push(objv(h));
	if(real d.size <= r.size) {
		for(i := 0; i < d.n; i++) {
			e := d.keys[i];
			if(e.t == Tempty)
				continue;
			if(truthy(call(r.has, r.obj, array[] of {e})) && mapfind(nd, e) < 0)
				mapput(nd, e, e);
		}
	} else {
		(it, next) := setkeysiter(r);
		push(it);
		push(next);
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				break;
			if(v.t == Tnum && v.n == 0.0)
				v = num(0.0);
			if(mapfind(d, v) >= 0 && mapfind(nd, v) < 0)
				mapput(nd, v, v);
		}
	}
	sp = sp0;
	return objv(h);
}

set_difference(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.difference");
	r := getsetrecord(arg(a, n, 0));
	(h, nd) := copyset(d);
	sp0 := sp;
	push(objv(h));
	if(real d.size <= r.size) {
		for(i := 0; i < d.n; i++) {
			e := d.keys[i];
			if(e.t == Tempty)
				continue;
			if(truthy(call(r.has, r.obj, array[] of {e}))) {
				j := mapfind(nd, e);
				if(j >= 0) {
					nd.keys[j] = empty;
					nd.size--;
				}
			}
		}
	} else {
		(it, next) := setkeysiter(r);
		push(it);
		push(next);
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				break;
			j := mapfind(nd, v);
			if(j >= 0) {
				nd.keys[j] = empty;
				nd.size--;
			}
		}
	}
	sp = sp0;
	return objv(h);
}

set_symdiff(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.symmetricDifference");
	r := getsetrecord(arg(a, n, 0));
	(h, nd) := copyset(d);
	sp0 := sp;
	push(objv(h));
	(it, next) := setkeysiter(r);
	push(it);
	push(next);
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		if(v.t == Tnum && v.n == 0.0)
			v = num(0.0);
		if(mapfind(d, v) >= 0) {
			j := mapfind(nd, v);
			if(j >= 0) {
				nd.keys[j] = empty;
				nd.size--;
			}
		} else if(mapfind(nd, v) < 0)
			mapput(nd, v, v);
	}
	sp = sp0;
	return objv(h);
}

set_issubsetof(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.isSubsetOf");
	r := getsetrecord(arg(a, n, 0));
	if(real d.size > r.size)
		return vfalse;
	for(i := 0; i < d.n; i++) {
		e := d.keys[i];
		if(e.t != Tempty && !truthy(call(r.has, r.obj, array[] of {e})))
			return vfalse;
	}
	return vtrue;
}

set_issupersetof(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.isSupersetOf");
	r := getsetrecord(arg(a, n, 0));
	if(real d.size < r.size)
		return vfalse;
	(it, next) := setkeysiter(r);
	sp0 := sp;
	push(it);
	push(next);
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		if(mapfind(d, v) < 0) {
			iterclose(it);
			sp = sp0;
			return vfalse;
		}
	}
	sp = sp0;
	return vtrue;
}

set_isdisjointfrom(this: V, a, n: int, nil: V, nil: int): V
{
	d := mapdata(this, Kset, "Set.prototype.isDisjointFrom");
	r := getsetrecord(arg(a, n, 0));
	if(real d.size <= r.size) {
		for(i := 0; i < d.n; i++) {
			e := d.keys[i];
			if(e.t != Tempty && truthy(call(r.has, r.obj, array[] of {e})))
				return vfalse;
		}
		return vtrue;
	}
	(it, next) := setkeysiter(r);
	sp0 := sp;
	push(it);
	push(next);
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		if(mapfind(d, v) >= 0) {
			iterclose(it);
			sp = sp0;
			return vfalse;
		}
	}
	sp = sp0;
	return vtrue;
}

weakrefctor(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor WeakRef requires 'new'");
	t := arg(a, n, 0);
	if(!canbeheldweakly(t))
		typeerr("WeakRef: invalid target");
	h := newobj(Kweakref, protofromctor(nt, oproto[f] * 0 + getv(objv(f), aprototype).x));
	odata[h] = ref Data.Weakref(t);
	return objv(h);
}

weakref_deref(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t == Tobj && okind[this.x] == Kweakref)
		pick d := odata[this.x] {
		Weakref =>
			return d.target;
		}
	typeerr("WeakRef.prototype.deref called on incompatible receiver");
	return undef;
}

# ---- Promise ----

promiseinit()
{
	ipromisector = ctor("Promise", 1, promisector, ipromiseproto);
	c := ipromisector;
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	method(c, "all", 1, promise_all);
	method(c, "allSettled", 1, promise_allsettled);
	method(c, "any", 1, promise_any);
	method(c, "race", 1, promise_race);
	method(c, "reject", 1, promise_reject);
	method(c, "resolve", 1, promise_resolve);
	method(c, "withResolvers", 0, promise_withresolvers);
	method(c, "try", 1, promise_try);
	p := ipromiseproto;
	method(p, "catch", 1, promproto_catch);
	method(p, "finally", 1, promproto_finally);
	method(p, "then", 2, promproto_then);
	tag(p, "Promise");
}

promisector(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("Promise constructor cannot be invoked without 'new'");
	ex := arg(a, n, 0);
	if(!iscallable(ex))
		typeerr("Promise resolver " + show(ex) + " is not a function");
	h := newobj(Kpromise, protofromctor(nt, ipromiseproto));
	odata[h] = ref Data.Promise(Ppending, undef, nil, 0);
	sp0 := sp;
	push(objv(h));
	(res, rej) := resolvingfns(h);
	push(objv(res));
	push(objv(rej));
	{
		call(ex, undef, array[] of {objv(res), objv(rej)});
	} exception e {
	"js:throw" =>
		call(objv(rej), undef, array[] of {thrown});
	}
	sp = sp0;
	return objv(h);
}

# NewPromiseCapability(C): (promise, resolve, reject)
newcapability(c: V): (V, V, V)
{
	if(!isctor(c))
		typeerr(show(c) + " is not a constructor");
	if(c.t == Tobj && c.x == ipromisector) {
		p := newpromise(ipromisector);
		(res, rej) := resolvingfns(p);
		return (objv(p), objv(res), objv(rej));
	}
	cell := newobj(Kord, -1);
	ex := nativefn("", 2, capexecutor);
	setcap(ex, array[] of {objv(cell)});
	sp0 := sp;
	push(objv(cell));
	pr := construct(c, array[] of {objv(ex)}, c);
	push(pr);
	(ok1, res, nil) := getownprop(cell, aget);
	(ok2, rej, nil) := getownprop(cell, aset);
	if(!ok1 || !iscallable(res))
		typeerr("promise resolve function is not callable");
	if(!ok2 || !iscallable(rej))
		typeerr("promise reject function is not callable");
	sp = sp0;
	return (pr, res, rej);
}

capexecutor(nil: V, a, n: int, nil: V, f: int): V
{
	cell := capof(f, 0).x;
	(ok1, r1, nil) := getownprop(cell, aget);
	(ok2, r2, nil) := getownprop(cell, aset);
	if(ok1 && r1.t != Tundef || ok2 && r2.t != Tundef)
		typeerr("promise capability executor already called");
	defown(cell, aget, Adefault, arg(a, n, 0));
	defown(cell, aset, Adefault, arg(a, n, 1));
	return undef;
}

promise_resolve(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Promise.resolve called on non-object");
	x := arg(a, n, 0);
	if(x.t == Tobj && okind[x.x] == Kpromise) {
		xc := getv(x, aconstructor);
		if(samevalue(xc, this))
			return x;
	}
	(p, res, nil) := newcapability(this);
	call(res, undef, array[] of {x});
	return p;
}

promise_reject(this: V, a, n: int, nil: V, nil: int): V
{
	(p, nil, rej) := newcapability(this);
	call(rej, undef, array[] of {arg(a, n, 0)});
	return p;
}

promise_withresolvers(this: V, nil, nil: int, nil: V, nil: int): V
{
	(p, res, rej) := newcapability(this);
	h := newplain();
	addprop(h, intern("promise"), Adefault, p);
	addprop(h, intern("resolve"), Adefault, res);
	addprop(h, intern("reject"), Adefault, rej);
	return objv(h);
}

promise_try(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Promise.try called on non-object");
	(p, res, rej) := newcapability(this);
	f := arg(a, n, 0);
	{
		r: V;
		if(n > 1) {
			args := array[n-1] of V;
			args[0:] = vs[a+1:a+n];
			r = call(f, undef, args);
		} else
			r = call(f, undef, nil);
		call(res, undef, array[] of {r});
	} exception e {
	"js:throw" =>
		call(rej, undef, array[] of {thrown});
	}
	return p;
}

ispromise(v: V): int
{
	return v.t == Tobj && okind[v.x] == Kpromise;
}

promproto_then(this: V, a, n: int, nil: V, nil: int): V
{
	if(!ispromise(this))
		typeerr("Promise.prototype.then called on incompatible receiver " + show(this));
	c := speciesctor(this, ipromisector);
	(p, res, rej) := newcapability(c);
	performthencap(this.x, arg(a, n, 0), arg(a, n, 1), p.x, res, rej);
	return p;
}

promproto_catch(this: V, a, n: int, nil: V, nil: int): V
{
	return invoke(this, athen, array[] of {undef, arg(a, n, 0)});
}

promproto_finally(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Promise.prototype.finally called on non-object");
	c := speciesctor(this, ipromisector);
	f := arg(a, n, 0);
	if(!iscallable(f))
		return invoke(this, athen, array[] of {f, f});
	tf := nativefn("", 1, finallythen);
	setcap(tf, array[] of {f, c});
	cf := nativefn("", 1, finallycatch);
	setcap(cf, array[] of {f, c});
	return invoke(this, athen, array[] of {objv(tf), objv(cf)});
}

finallythen(nil: V, a, n: int, nil: V, fh: int): V
{
	f := capof(fh, 0);
	c := capof(fh, 1);
	r := call(f, undef, nil);
	p := promiseresolvec(c, r);
	vf := nativefn("", 0, returnvalue);
	setcap(vf, array[] of {arg(a, n, 0)});
	return invoke(p, athen, array[] of {objv(vf)});
}

finallycatch(nil: V, a, n: int, nil: V, fh: int): V
{
	f := capof(fh, 0);
	c := capof(fh, 1);
	r := call(f, undef, nil);
	p := promiseresolvec(c, r);
	tf := nativefn("", 0, throwvalue);
	setcap(tf, array[] of {arg(a, n, 0)});
	return invoke(p, athen, array[] of {objv(tf)});
}

returnvalue(nil: V, nil, nil: int, nil: V, f: int): V
{
	return capof(f, 0);
}

throwvalue(nil: V, nil, nil: int, nil: V, f: int): V
{
	throwv(capof(f, 0));
	return undef;
}

# PromiseResolve(C, x), for any constructor C
promiseresolvec(c, x: V): V
{
	if(ispromise(x)) {
		xc := getv(x, aconstructor);
		if(samevalue(xc, c))
			return x;
	}
	(p, res, nil) := newcapability(c);
	call(res, undef, array[] of {x});
	return p;
}

# Promise.all and its kin: kind 0 all, 1 allSettled, 2 any, 3 race
combinator(this: V, a, n: int, kind: int): V
{
	c := this;
	(p, res, rej) := newcapability(c);
	sp0 := sp;
	push(p);
	push(res);
	push(rej);
	{
		resolve := getv(c, intern("resolve"));
		if(!iscallable(resolve))
			typeerr("Promise resolve is not a function");
		(it, next) := getiterator(arg(a, n, 0), 0);
		push(it);
		push(next);
		values := newarray(0);
		push(objv(values));
		# remaining: a counter object (its alen), so the element functions share it
		remaining := newobj(Kord, -1);
		oalen[remaining] = 1.0;
		push(objv(remaining));
		idx := 0;
		for(;;) {
			x: V;
			done: int;
			{
				(x, done) = iterstep(it, next);
			} exception e {
			"js:throw" =>
				raise e;
			}
			if(done) {
				oalen[remaining] -= 1.0;
				if(oalen[remaining] == 0.0) {
					case kind {
					0 or 1 =>
						call(res, undef, array[] of {objv(values)});
					2 =>
						err := newerror(AggregateError, "All promises were rejected");
						defown(err, aerrors, Awrite|Aconf, objv(values));
						call(rej, undef, array[] of {objv(err)});
					}
				}
				sp = sp0;
				return p;
			}
			{
				if(kind != 3)
					arrpush(values, undef);
				np := call(resolve, c, array[] of {x});
				case kind {
				0 =>
					ef := elementfn(values, idx, remaining, res, 0);
					oalen[remaining] += 1.0;
					invoke(np, athen, array[] of {objv(ef), rej});
				1 =>
					ef := elementfn(values, idx, remaining, res, 1);
					rf := elementfn(values, idx, remaining, res, 2);
					shareflag(ef, rf);
					oalen[remaining] += 1.0;
					invoke(np, athen, array[] of {objv(ef), objv(rf)});
				2 =>
					rf := elementfn(values, idx, remaining, rej, 3);
					oalen[remaining] += 1.0;
					invoke(np, athen, array[] of {res, objv(rf)});
				3 =>
					invoke(np, athen, array[] of {res, rej});
				}
				idx++;
			} exception e2 {
			"js:throw" =>
				saved := thrown;
				{
					iterclose(it);
				} exception {
				"js:throw" =>
					;
				}
				thrown = saved;
				raise e2;
			}
		}
	} exception ex {
	"js:throw" =>
		call(rej, undef, array[] of {thrown});
	}
	sp = sp0;
	return p;
}

# a resolve element function: kind 0 value, 1 fulfilled record, 2 rejected record, 3 any's rejection
elementfn(values, idx, remaining: int, cap: V, kind: int): int
{
	h := nativefn("", 1, resolveelement);
	flag := newobj(Kord, -1);
	setcap(h, array[] of {objv(values), num(real idx), objv(remaining), cap, num(real kind), objv(flag)});
	return h;
}

# allSettled's two functions share one alreadyCalled
shareflag(a, b: int)
{
	pick d := odata[a] {
	Native =>
		pick e := odata[b] {
		Native =>
			e.cap[5] = d.cap[5];
		}
	}
}

resolveelement(nil: V, a, n: int, nil: V, f: int): V
{
	flag := capof(f, 5).x;
	if(oflags[flag] & Ohtmldda)
		return undef;
	oflags[flag] |= Ohtmldda;
	values := capof(f, 0).x;
	idx := int capof(f, 1).n;
	remaining := capof(f, 2).x;
	cap := capof(f, 3);
	kind := int capof(f, 4).n;
	x := arg(a, n, 0);
	case kind {
	0 or 3 =>
		createdata(values, idxkey(idx), x);
	1 or 2 =>
		r := newplain();
		if(kind == 1) {
			addprop(r, intern("status"), Adefault, strv("fulfilled"));
			addprop(r, avalue, Adefault, x);
		} else {
			addprop(r, intern("status"), Adefault, strv("rejected"));
			addprop(r, intern("reason"), Adefault, x);
		}
		createdata(values, idxkey(idx), objv(r));
	}
	oalen[remaining] -= 1.0;
	if(oalen[remaining] == 0.0) {
		if(kind == 3) {
			err := newerror(AggregateError, "All promises were rejected");
			defown(err, aerrors, Awrite|Aconf, objv(values));
			return call(cap, undef, array[] of {objv(err)});
		}
		return call(cap, undef, array[] of {objv(values)});
	}
	return undef;
}

promise_all(this: V, a, n: int, nil: V, nil: int): V { return combinator(this, a, n, 0); }
promise_allsettled(this: V, a, n: int, nil: V, nil: int): V { return combinator(this, a, n, 1); }
promise_any(this: V, a, n: int, nil: V, nil: int): V { return combinator(this, a, n, 2); }
promise_race(this: V, a, n: int, nil: V, nil: int): V { return combinator(this, a, n, 3); }

# ---- Reflect ----

reflectinit()
{
	r := newplain();
	keep(r);
	defown(iglobal, intern("Reflect"), Awrite|Aconf, objv(r));
	tag(r, "Reflect");
	method(r, "apply", 3, reflect_apply);
	method(r, "construct", 2, reflect_construct);
	method(r, "defineProperty", 3, reflect_defineproperty);
	method(r, "deleteProperty", 2, reflect_deleteproperty);
	method(r, "get", 2, reflect_get);
	method(r, "getOwnPropertyDescriptor", 2, reflect_getownpropertydescriptor);
	method(r, "getPrototypeOf", 1, reflect_getprototypeof);
	method(r, "has", 2, reflect_has);
	method(r, "isExtensible", 1, reflect_isextensible);
	method(r, "ownKeys", 1, reflect_ownkeys);
	method(r, "preventExtensions", 1, reflect_preventextensions);
	method(r, "set", 3, reflect_set);
	method(r, "setPrototypeOf", 2, reflect_setprototypeof);
}

reflobj(v: V, name: string): int
{
	if(v.t != Tobj)
		typeerr("Reflect." + name + " called on non-object");
	return v.x;
}

reflect_apply(nil: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	args := listfromarraylike(arg(a, n, 2));
	return call(f, arg(a, n, 1), args);
}

reflect_construct(nil: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(!isctor(f))
		typeerr(show(f) + " is not a constructor");
	nt := f;
	if(n > 2) {
		nt = vs[a+2];
		if(!isctor(nt))
			typeerr(show(nt) + " is not a constructor");
	}
	args := listfromarraylike(arg(a, n, 1));
	return construct(f, args, nt);
}

reflect_defineproperty(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "defineProperty");
	k := tokey(arg(a, n, 1));
	return bool(defineown(h, k, todesc(arg(a, n, 2))));
}

reflect_deleteproperty(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "deleteProperty");
	return bool(delete(h, tokey(arg(a, n, 1))));
}

reflect_get(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	h := reflobj(o, "get");
	k := tokey(arg(a, n, 1));
	recv := o;
	if(n > 2)
		recv = vs[a+2];
	return get(h, k, recv);
}

reflect_getownpropertydescriptor(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "getOwnPropertyDescriptor");
	(found, d) := getown(h, tokey(arg(a, n, 1)));
	if(!found)
		return undef;
	return fromdesc(d);
}

reflect_getprototypeof(nil: V, a, n: int, nil: V, nil: int): V
{
	p := getproto(reflobj(arg(a, n, 0), "getPrototypeOf"));
	if(p < 0)
		return null;
	return objv(p);
}

reflect_has(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "has");
	return bool(hasprop(h, tokey(arg(a, n, 1))));
}

reflect_isextensible(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(isext(reflobj(arg(a, n, 0), "isExtensible")));
}

reflect_ownkeys(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "ownKeys");
	ks := ownkeys(h);
	r := newarray(0);
	for(i := 0; i < len ks; i++)
		arrpush(r, keyval(ks[i]));
	return objv(r);
}

reflect_preventextensions(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(preventext(reflobj(arg(a, n, 0), "preventExtensions")));
}

reflect_set(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	h := reflobj(o, "set");
	k := tokey(arg(a, n, 1));
	recv := o;
	if(n > 3)
		recv = vs[a+3];
	return bool(set(h, k, arg(a, n, 2), recv));
}

reflect_setprototypeof(nil: V, a, n: int, nil: V, nil: int): V
{
	h := reflobj(arg(a, n, 0), "setPrototypeOf");
	p := arg(a, n, 1);
	if(p.t != Tobj && p.t != Tnull)
		typeerr("object prototype may only be an Object or null");
	pp := -1;
	if(p.t == Tobj)
		pp = p.x;
	return bool(setproto(h, pp));
}

# ---- iterators and generators ----

iterinit()
{
	symmethod(iiterproto, asymiterator, "[Symbol.iterator]", 0, returnthis);
	symmethod(iasynciterproto, asymasynciter, "[Symbol.asyncIterator]", 0, returnthis);
}

generatorinit()
{
	# %GeneratorFunction%, %GeneratorFunction.prototype% (igenfuncproto), %GeneratorPrototype% (igenproto)
	igenfuncproto = keep(newobj(Kord, ifuncproto));
	gf := nativefn("GeneratorFunction", 1, generatorfunctionctor);
	oflags[gf] |= Octor;
	oproto[gf] = ifuncctor;
	keep(gf);
	defown(gf, aprototype, 0, objv(igenfuncproto));
	defown(igenfuncproto, aconstructor, Aconf, objv(gf));
	defown(igenfuncproto, aprototype, Aconf, objv(igenproto));
	tag(igenfuncproto, "GeneratorFunction");
	defown(igenproto, aconstructor, Aconf, objv(igenfuncproto));
	method(igenproto, "next", 1, gen_next);
	method(igenproto, "return", 1, gen_return);
	method(igenproto, "throw", 1, gen_throw);
	tag(igenproto, "Generator");

	iasyncfuncproto = keep(newobj(Kord, ifuncproto));
	af := nativefn("AsyncFunction", 1, asyncfunctionctor);
	oflags[af] |= Octor;
	oproto[af] = ifuncctor;
	keep(af);
	defown(af, aprototype, 0, objv(iasyncfuncproto));
	defown(iasyncfuncproto, aconstructor, Aconf, objv(af));
	tag(iasyncfuncproto, "AsyncFunction");

	iasyncgenfuncproto = keep(newobj(Kord, ifuncproto));
	agf := nativefn("AsyncGeneratorFunction", 1, asyncgeneratorfunctionctor);
	oflags[agf] |= Octor;
	oproto[agf] = ifuncctor;
	keep(agf);
	defown(agf, aprototype, 0, objv(iasyncgenfuncproto));
	defown(iasyncgenfuncproto, aconstructor, Aconf, objv(agf));
	defown(iasyncgenfuncproto, aprototype, Aconf, objv(iasyncgenproto));
	tag(iasyncgenfuncproto, "AsyncGeneratorFunction");
	defown(iasyncgenproto, aconstructor, Aconf, objv(iasyncgenfuncproto));
	method(iasyncgenproto, "next", 1, agen_next);
	method(iasyncgenproto, "return", 1, agen_return);
	method(iasyncgenproto, "throw", 1, agen_throw);
	tag(iasyncgenproto, "AsyncGenerator");

	method(iasyncfromsyncproto, "next", 1, afs_next);
	method(iasyncfromsyncproto, "return", 1, afs_return);
	method(iasyncfromsyncproto, "throw", 1, afs_throw);
}

generatorfunctionctor(nil: V, a, n: int, nt: V, nil: int): V { return dynamicfunction(a, n, nt, 1); }
asyncfunctionctor(nil: V, a, n: int, nt: V, nil: int): V { return dynamicfunction(a, n, nt, 2); }
asyncgeneratorfunctionctor(nil: V, a, n: int, nt: V, nil: int): V { return dynamicfunction(a, n, nt, 3); }

gen_next(this: V, a, n: int, nil: V, nil: int): V { return genresume(this, Rnext, arg(a, n, 0), "next"); }
gen_return(this: V, a, n: int, nil: V, nil: int): V { return genresume(this, Rreturn, arg(a, n, 0), "return"); }
gen_throw(this: V, a, n: int, nil: V, nil: int): V { return genresume(this, Rthrow, arg(a, n, 0), "throw"); }

agen_next(this: V, a, n: int, nil: V, nil: int): V { return asyncgenenqueue(this, Rnext, arg(a, n, 0)); }
agen_return(this: V, a, n: int, nil: V, nil: int): V { return asyncgenenqueue(this, Rreturn, arg(a, n, 0)); }
agen_throw(this: V, a, n: int, nil: V, nil: int): V { return asyncgenenqueue(this, Rthrow, arg(a, n, 0)); }

# %AsyncFromSyncIteratorPrototype%
afs(this: V, a, n: int, which: int): V
{
	pr := newpromise(ipromisector);
	sp0 := sp;
	push(objv(pr));
	pick d := odata[this.x] {
	Iter =>
		it := d.target;
		{
			r: V;
			case which {
			0 =>
				next := get(this.x, intern("%next"), this);
				if(n > 0)
					r = call(next, it, array[] of {vs[a]});
				else
					r = call(next, it, nil);
			1 =>
				ret := getmethod(it, areturn);
				if(ret.t == Tundef) {
					resolvepromise(pr, iterresult(arg(a, n, 0), 1));
					sp = sp0;
					return objv(pr);
				}
				if(n > 0)
					r = call(ret, it, array[] of {vs[a]});
				else
					r = call(ret, it, nil);
			2 =>
				th := getmethod(it, athrow);
				if(th.t == Tundef) {
					saved := thrown;
					{
						iterclose(it);
					} exception {
					"js:throw" =>
						;
					}
					thrown = saved;
					rejectpromise(pr, objv(newerror(TypeError, "the iterator does not have a 'throw' method")));
					sp = sp0;
					return objv(pr);
				}
				r = call(th, it, array[] of {arg(a, n, 0)});
			}
			if(r.t != Tobj)
				typeerr("iterator result is not an object");
			done := truthy(getv(r, adone));
			v := getv(r, avalue);
			vp := promiseresolve(ipromisector, v);
			unwrap := nativefn("", 1, afsunwrap);
			setcap(unwrap, array[] of {bool(done)});
			onrej := undef;
			if(!done && which != 1) {
				cl := nativefn("", 1, afsclose);
				setcap(cl, array[] of {it});
				onrej = objv(cl);
			}
			(res, rej) := resolvingfns(pr);
			performthencap(vp, objv(unwrap), onrej, pr, objv(res), objv(rej));
		} exception e {
		"js:throw" =>
			rejectpromise(pr, thrown);
		}
	}
	sp = sp0;
	return objv(pr);
}

afsunwrap(nil: V, a, n: int, nil: V, f: int): V
{
	return iterresult(arg(a, n, 0), truthy(capof(f, 0)));
}

afsclose(nil: V, a, n: int, nil: V, f: int): V
{
	it := capof(f, 0);
	saved := arg(a, n, 0);
	{
		iterclose(it);
	} exception {
	"js:throw" =>
		;
	}
	throwv(saved);
	return undef;
}

afs_next(this: V, a, n: int, nil: V, nil: int): V { return afs(this, a, n, 0); }
afs_return(this: V, a, n: int, nil: V, nil: int): V { return afs(this, a, n, 1); }
afs_throw(this: V, a, n: int, nil: V, nil: int): V { return afs(this, a, n, 2); }

# regular expressions are next; until then, RegExp construction from a value
regexpcreatefrom(p, f: V): int
{
	ps := "(?:)";
	if(p.t != Tundef)
		ps = tostring(p);
	fs := "";
	if(f.t != Tundef)
		fs = tostring(f);
	return regexpcreate(ps, fs);
}
