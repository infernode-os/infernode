#
# jsicoll.b - Map, Set, the weak collections, Promise, Reflect, Proxy,
# and the iterator objects.
#
# Weak collections hold their keys strongly: the realm is collected as a
# whole by Dis when it is dropped, and nothing in a script can tell the
# difference except memory.
#

NMap, NMgroupby, NMPclear, NMPdelete, NMPentries, NMPforeach, NMPget, NMPhas, NMPkeys, NMPset,
NMPsize, NMPvalues, NMInext, NSet, NSPadd, NSPclear, NSPdelete, NSPentries, NSPforeach, NSPhas,
NSPsize, NSPvalues, NSetInext, NSPunion, NSPintersection, NSPdifference, NSPsymdiff, NSPissubset,
NSPissuperset, NSPisdisjoint, NWeakMap, NWMPdelete, NWMPget, NWMPhas, NWMPset, NWeakSet, NWSPadd,
NWSPdelete, NWSPhas, NWeakRef, NWRPderef, NFinReg, NFRPregister, NFRPunregister, NMPgetorinsert,
NMPgetorinsertcomputed, NWMPgetorinsert, NWMPgetorinsertcomputed: con Ncollbase + iota;

NPromise, NPall, NPallsettled, NPany, NPrace, NPreject, NPresolve, NPwithresolvers, NPtry,
NPPthen, NPPcatch, NPPfinally, NPallelem, NPfinallyfn, NPthunk, NPspecies: con Npromisebase + iota;

NRapply, NRconstruct, NRdefprop, NRdelprop, NRget, NRgopd, NRgetproto, NRhas, NRisext, NRownkeys,
NRprevent, NRset, NRsetproto, NProxy, NPxrevocable, NPxrevoke: con Nreflectbase + iota;

NIterator, NIfrom, NIPmap, NIPfilter, NIPtake, NIPdrop, NIPflatmap, NIPreduce, NIPtoarray, NIPforeach,
NIPsome, NIPevery, NIPfind, NIPiterator, NIPtagget, NIPtagset, NIPctorget, NIPctorset, NIHnext,
NIHreturn, NIWnext, NIWreturn, NIconcat, NIPdispose, NAIPdispose: con Niterbase + iota;

mapiterproto, setiterproto, iterhelperproto, wrapforvalidproto, setctor: ref Obj;

collinit()
{
	c := defctor("Map", NMap, 0, mapproto);
	defmethod(c, "groupBy", NMgroupby, 2);
	defaccessor(c, a_symspecies, "[Symbol.species]", NAspecies, 0);
	p := mapproto;
	defmethod(p, "clear", NMPclear, 0);
	defmethod(p, "delete", NMPdelete, 1);
	ent := defmethod(p, "entries", NMPentries, 0);
	defmethod(p, "forEach", NMPforeach, 1);
	defmethod(p, "get", NMPget, 1);
	defmethod(p, "has", NMPhas, 1);
	defmethod(p, "keys", NMPkeys, 0);
	defmethod(p, "set", NMPset, 2);
	defmethod(p, "getOrInsert", NMPgetorinsert, 2);
	defmethod(p, "getOrInsertComputed", NMPgetorinsertcomputed, 2);
	defgetter(p, "size", NMPsize);
	defmethod(p, "values", NMPvalues, 0);
	defprop(p, a_symiterator, objv(ent), Awrite|Aconf);
	defprop(p, a_symtostringtag, strv("Map"), Aconf);
	mapiterproto = newobj(Cplain, iterproto);
	defmethod(mapiterproto, "next", NMInext, 0);
	defprop(mapiterproto, a_symtostringtag, strv("Map Iterator"), Aconf);

	setctor = defctor("Set", NSet, 0, setprotoobj);
	defaccessor(setctor, a_symspecies, "[Symbol.species]", NAspecies, 0);
	p = setprotoobj;
	defmethod(p, "add", NSPadd, 1);
	defmethod(p, "clear", NSPclear, 0);
	defmethod(p, "delete", NSPdelete, 1);
	defmethod(p, "entries", NSPentries, 0);
	defmethod(p, "forEach", NSPforeach, 1);
	defmethod(p, "has", NSPhas, 1);
	defgetter(p, "size", NSPsize);
	vals := defmethod(p, "values", NSPvalues, 0);
	defprop(p, a_keys, objv(vals), Awrite|Aconf);
	defprop(p, a_symiterator, objv(vals), Awrite|Aconf);
	defmethod(p, "union", NSPunion, 1);
	defmethod(p, "intersection", NSPintersection, 1);
	defmethod(p, "difference", NSPdifference, 1);
	defmethod(p, "symmetricDifference", NSPsymdiff, 1);
	defmethod(p, "isSubsetOf", NSPissubset, 1);
	defmethod(p, "isSupersetOf", NSPissuperset, 1);
	defmethod(p, "isDisjointFrom", NSPisdisjoint, 1);
	defprop(p, a_symtostringtag, strv("Set"), Aconf);
	setiterproto = newobj(Cplain, iterproto);
	defmethod(setiterproto, "next", NSetInext, 0);
	defprop(setiterproto, a_symtostringtag, strv("Set Iterator"), Aconf);

	defctor("WeakMap", NWeakMap, 0, weakmapproto);
	p = weakmapproto;
	defmethod(p, "delete", NWMPdelete, 1);
	defmethod(p, "get", NWMPget, 1);
	defmethod(p, "has", NWMPhas, 1);
	defmethod(p, "set", NWMPset, 2);
	defmethod(p, "getOrInsert", NWMPgetorinsert, 2);
	defmethod(p, "getOrInsertComputed", NWMPgetorinsertcomputed, 2);
	defprop(p, a_symtostringtag, strv("WeakMap"), Aconf);
	defctor("WeakSet", NWeakSet, 0, weaksetproto);
	p = weaksetproto;
	defmethod(p, "add", NWSPadd, 1);
	defmethod(p, "delete", NWSPdelete, 1);
	defmethod(p, "has", NWSPhas, 1);
	defprop(p, a_symtostringtag, strv("WeakSet"), Aconf);
	p = newobj(Cplain, objproto);
	defctor("WeakRef", NWeakRef, 1, p);
	defmethod(p, "deref", NWRPderef, 0);
	defprop(p, a_symtostringtag, strv("WeakRef"), Aconf);
	p = newobj(Cplain, objproto);
	defctor("FinalizationRegistry", NFinReg, 1, p);
	defmethod(p, "register", NFRPregister, 2);
	defmethod(p, "unregister", NFRPunregister, 1);
	defprop(p, a_symtostringtag, strv("FinalizationRegistry"), Aconf);
}

thismap(this: V, cls: int, name: string): ref Hmap
{
	if(this.t == Tobj && this.o.cls == cls) {
		pick d := this.o.data {
		Map =>
			return d.m;
		}
	}
	throwtype("Method " + name + " called on incompatible receiver " + showv(this));
	return nil;
}

# a key a weak collection can hold: an object, or a symbol not made by Symbol.for
canbeweak(v: V): int
{
	if(v.t == Tobj)
		return 1;
	if(v.t == Tsym) {
		pick d := v.o.data {
		Sym =>
			return !d.reg;
		}
	}
	return 0;
}

natcoll(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NMap or NSet or NWeakMap or NWeakSet =>
		if(nt == nil)
			throwtype("Constructor requires 'new'");
		cls := Cmap;
		proto := mapproto;
		adder := a_set;
		case id {
		NSet =>
			cls = Cset;
			proto = setprotoobj;
			adder = a_add;
		NWeakMap =>
			cls = Cweakmap;
			proto = weakmapproto;
		NWeakSet =>
			cls = Cweakset;
			proto = weaksetproto;
			adder = a_add;
		}
		o := fromctor(nt, proto, cls);
		o.data = ref Data.Map(newhmap());
		it := arg(args, 0);
		if(it.t == Tundef || it.t == Tnull)
			return objv(o);
		add := getv(o, adder);
		if(!iscallable(add))
			throwtype("'" + atomstr[adder] + "' is not a function");
		ov := objv(o);
		iter := getiterator(it, 0);
		next := getvalue(iter, a_next);
		for(;;) {
			r := call1(next, iter, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done)))
				break;
			v := getv(r.o, a_value);
			{
				if(id == NMap || id == NWeakMap) {
					if(v.t != Tobj)
						throwtype("Iterator value " + showv(v) + " is not an entry object");
					k := getidx(v.o, 0, v);
					x := getidx(v.o, 1, v);
					call(add.o, ov, array[] of {k, x});
				} else
					call(add.o, ov, array[] of {v});
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(iter, 1);
				throwv(ex);
			}
		}
		return ov;
	NMgroupby =>
		return groupby(args, 1);
	NMPclear or NSPclear =>
		cls := Cmap;
		if(id == NSPclear)
			cls = Cset;
		hclear(thismap(this, cls, "clear"));
		return undef;
	NMPdelete or NSPdelete =>
		cls := Cmap;
		if(id == NSPdelete)
			cls = Cset;
		return boolv(hdelete(thismap(this, cls, "delete"), arg(args, 0)));
	NMPget =>
		m := thismap(this, Cmap, "Map.prototype.get");
		i := hfind(m, arg(args, 0));
		if(i < 0)
			return undef;
		return m.vals[i];
	NMPhas or NSPhas =>
		cls := Cmap;
		if(id == NSPhas)
			cls = Cset;
		return boolv(hfind(thismap(this, cls, "has"), arg(args, 0)) >= 0);
	NMPset =>
		m := thismap(this, Cmap, "Map.prototype.set");
		hset(m, arg(args, 0), arg(args, 1));
		return this;
	NMPgetorinsert or NMPgetorinsertcomputed =>
		m := thismap(this, Cmap, "Map.prototype.getOrInsert");
		k := arg(args, 0);
		if(id == NMPgetorinsertcomputed && !iscallable(arg(args, 1)))
			throwtype("callback is not a function");
		i := hfind(m, k);
		if(i >= 0)
			return m.vals[i];
		v := arg(args, 1);
		if(id == NMPgetorinsertcomputed) {
			if(k.t == Tnum && k.n == 0.0)
				k = intv(0);
			v = call(v.o, undef, array[] of {k});
		}
		hset(m, k, v);
		return v;
	NSPadd =>
		m := thismap(this, Cset, "Set.prototype.add");
		k := arg(args, 0);
		if(hfind(m, k) < 0)
			hset(m, k, k);
		return this;
	NMPsize or NSPsize =>
		cls := Cmap;
		if(id == NSPsize)
			cls = Cset;
		return intv(thismap(this, cls, "size").live);
	NMPentries or NMPkeys or NMPvalues or NSPentries or NSPvalues =>
		cls := Cmap;
		proto := mapiterproto;
		kind := Ientries;
		case id {
		NMPkeys => kind = Ikeys;
		NMPvalues => kind = Ivalues;
		NSPentries =>
			cls = Cset;
			proto = setiterproto;
		NSPvalues =>
			cls = Cset;
			proto = setiterproto;
			kind = Ivalues;
		}
		thismap(this, cls, "iterator");
		it := newobj(Citer, proto);
		it.data = ref Data.Iter(kind, this.o, undef, 0, 0, nil);
		return objv(it);
	NMInext or NSetInext =>
		proto := mapiterproto;
		if(id == NSetInext)
			proto = setiterproto;
		if(this.t != Tobj || this.o.cls != Citer || this.o.sh.proto == nil)
			throwtype("next method called on incompatible receiver " + showv(this));
		pick d := this.o.data {
		Iter =>
			if(d.done || d.o == nil || d.o.cls != Cmap && d.o.cls != Cset)
				return iterresult(undef, 1);
			m: ref Hmap;
			pick md := d.o.data {
			Map =>
				m = md.m;
			}
			while(d.i < m.n && m.keys[d.i].t == Thole)
				d.i++;
			if(d.i >= m.n) {
				d.done = 1;
				d.o = nil;
				return iterresult(undef, 1);
			}
			i := d.i++;
			case d.kind {
			Ikeys =>
				return iterresult(m.keys[i], 0);
			Ivalues =>
				return iterresult(m.vals[i], 0);
			* =>
				return iterresult(objv(mkarray(array[] of {m.keys[i], m.vals[i]})), 0);
			}
		}
		return undef;
	NMPforeach or NSPforeach =>
		cls := Cmap;
		if(id == NSPforeach)
			cls = Cset;
		m := thismap(this, cls, "forEach");
		cb := callback(args);
		t := arg(args, 1);
		for(i := 0; i < m.n; i++) {
			if(m.keys[i].t == Thole)
				continue;
			call(cb, t, array[] of {m.vals[i], m.keys[i], this});
		}
		return undef;
	NSPunion or NSPintersection or NSPdifference or NSPsymdiff or NSPissubset or NSPissuperset or NSPisdisjoint =>
		return setmethod(id, this, arg(args, 0));
	NWMPdelete or NWSPdelete =>
		cls := Cweakmap;
		if(id == NWSPdelete)
			cls = Cweakset;
		m := thismap(this, cls, "delete");
		k := arg(args, 0);
		if(!canbeweak(k))
			return falsev;
		return boolv(hdelete(m, k));
	NWMPget =>
		m := thismap(this, Cweakmap, "WeakMap.prototype.get");
		i := hfind(m, arg(args, 0));
		if(i < 0)
			return undef;
		return m.vals[i];
	NWMPhas or NWSPhas =>
		cls := Cweakmap;
		if(id == NWSPhas)
			cls = Cweakset;
		m := thismap(this, cls, "has");
		return boolv(canbeweak(arg(args, 0)) && hfind(m, arg(args, 0)) >= 0);
	NWMPset =>
		m := thismap(this, Cweakmap, "WeakMap.prototype.set");
		k := arg(args, 0);
		if(!canbeweak(k))
			throwtype("Invalid value used as weak map key");
		hset(m, k, arg(args, 1));
		return this;
	NWMPgetorinsert or NWMPgetorinsertcomputed =>
		m := thismap(this, Cweakmap, "WeakMap.prototype.getOrInsert");
		k := arg(args, 0);
		if(!canbeweak(k))
			throwtype("Invalid value used as weak map key");
		if(id == NWMPgetorinsertcomputed && !iscallable(arg(args, 1)))
			throwtype("callback is not a function");
		i := hfind(m, k);
		if(i >= 0)
			return m.vals[i];
		v := arg(args, 1);
		if(id == NWMPgetorinsertcomputed)
			v = call(v.o, undef, array[] of {k});
		hset(m, k, v);
		return v;
	NWSPadd =>
		m := thismap(this, Cweakset, "WeakSet.prototype.add");
		k := arg(args, 0);
		if(!canbeweak(k))
			throwtype("Invalid value used in weak set");
		hset(m, k, k);
		return this;
	NWeakRef =>
		if(nt == nil)
			throwtype("Constructor WeakRef requires 'new'");
		t := arg(args, 0);
		if(!canbeweak(t))
			throwtype("WeakRef: invalid target");
		o := fromctor(nt, getv(f, a_prototype).o, Cweakref);
		o.data = ref Data.Weak(t);
		return objv(o);
	NWRPderef =>
		if(this.t == Tobj && this.o.cls == Cweakref) {
			pick d := this.o.data {
			Weak =>
				return d.target;
			}
		}
		throwtype("WeakRef.prototype.deref called on incompatible receiver");
	NFinReg =>
		if(nt == nil)
			throwtype("Constructor FinalizationRegistry requires 'new'");
		cb := arg(args, 0);
		if(!iscallable(cb))
			throwtype("FinalizationRegistry: cleanup must be callable");
		o := fromctor(nt, getv(f, a_prototype).o, Cfinreg);
		o.data = ref Data.Finreg(cb.o, nil);
		return objv(o);
	NFRPregister =>
		if(this.t != Tobj || this.o.cls != Cfinreg)
			throwtype("FinalizationRegistry.prototype.register called on incompatible receiver");
		t := arg(args, 0);
		if(!canbeweak(t))
			throwtype("FinalizationRegistry.prototype.register: invalid target");
		if(samevalue(t, arg(args, 1)))
			throwtype("FinalizationRegistry.prototype.register: target and holdings must not be same");
		tok := arg(args, 2);
		if(tok.t != Tundef && !canbeweak(tok))
			throwtype("FinalizationRegistry.prototype.register: invalid unregister token");
		pick d := this.o.data {
		Finreg =>
			d.cells = (t, arg(args, 1), tok) :: d.cells;
		}
		return undef;
	NFRPunregister =>
		if(this.t != Tobj || this.o.cls != Cfinreg)
			throwtype("FinalizationRegistry.prototype.unregister called on incompatible receiver");
		tok := arg(args, 0);
		if(!canbeweak(tok))
			throwtype("Invalid unregisterToken");
		found := 0;
		pick d := this.o.data {
		Finreg =>
			r: list of (V, V, V);
			for(l := d.cells; l != nil; l = tl l) {
				(nil, nil, t) := hd l;
				if(t.t != Tundef && samevalue(t, tok))
					found = 1;
				else
					r = hd l :: r;
			}
			d.cells = r;
		}
		return boolv(found);
	}
	throwerr(EError, "unknown collection built-in");
	return undef;
}

# ---- the Set methods ----

# GetSetRecord: (size, has, keys)
setrecord(v: V): (real, ref Obj, ref Obj)
{
	if(v.t != Tobj)
		throwtype("The argument is not an object");
	rs := getv(v.o, a_size);
	n := tonum(rs);
	if(isnan(n))
		throwtype("The size property is not a number");
	sz := tointeger(V(Tnum, 0, n, nil, nil));
	if(sz < 0.0)
		throwerr(ERange, "The size is negative");
	has := getv(v.o, a_has);
	if(!iscallable(has))
		throwtype("has is not a function");
	keys := getv(v.o, a_keys);
	if(!iscallable(keys))
		throwtype("keys is not a function");
	return (sz, has.o, keys.o);
}

newset(entries: list of V): V
{
	o := newobj(Cset, setprotoobj);
	m := newhmap();
	o.data = ref Data.Map(m);
	r: list of V;
	for(; entries != nil; entries = tl entries)
		r = hd entries :: r;
	for(; r != nil; r = tl r)
		if(hfind(m, hd r) < 0)
			hset(m, hd r, hd r);
	return objv(o);
}

liveentries(m: ref Hmap): list of V
{
	l: list of V;
	for(i := 0; i < m.n; i++)
		if(m.keys[i].t != Thole)
			l = m.keys[i] :: l;
	r: list of V;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

setmethod(id: int, this: V, other: V): V
{
	m := thismap(this, Cset, "Set method");
	(sz, has, keysfn) := setrecord(other);
	ov := other;
	case id {
	NSPunion =>
		l := revv(liveentries(m));
		it := call(keysfn, ov, nil);
		next := getvalue(it, a_next);
		for(;;) {
			r := call1(next, it, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done)))
				break;
			v := getv(r.o, a_value);
			if(v.t == Tnum && v.n == 0.0)
				v = intv(0);
			l = v :: l;
		}
		return newset(l);
	NSPintersection =>
		l: list of V;
		if(real m.live <= sz) {
			for(i := 0; i < m.n; i++) {
				if(m.keys[i].t == Thole)
					continue;
				e := m.keys[i];
				if(tobool(call(has, ov, array[] of {e})))
					l = e :: l;
			}
		} else {
			it := call(keysfn, ov, nil);
			next := getvalue(it, a_next);
			for(;;) {
				r := call1(next, it, nil);
				if(r.t != Tobj)
					throwtype("Iterator result is not an object");
				if(tobool(getv(r.o, a_done)))
					break;
				v := getv(r.o, a_value);
				if(v.t == Tnum && v.n == 0.0)
					v = intv(0);
				if(hfind(m, v) >= 0)
					l = v :: l;
			}
		}
		return newset(l);
	NSPdifference =>
		res := newset(revv(liveentries(m)));
		rm: ref Hmap;
		pick d := res.o.data {
		Map =>
			rm = d.m;
		}
		if(real m.live <= sz) {
			for(i := 0; i < m.n; i++) {
				if(m.keys[i].t == Thole)
					continue;
				e := m.keys[i];
				if(tobool(call(has, ov, array[] of {e})))
					hdelete(rm, e);
			}
		} else {
			it := call(keysfn, ov, nil);
			next := getvalue(it, a_next);
			for(;;) {
				r := call1(next, it, nil);
				if(r.t != Tobj)
					throwtype("Iterator result is not an object");
				if(tobool(getv(r.o, a_done)))
					break;
				hdelete(rm, getv(r.o, a_value));
			}
		}
		return res;
	NSPsymdiff =>
		res := newset(revv(liveentries(m)));
		rm: ref Hmap;
		pick d := res.o.data {
		Map =>
			rm = d.m;
		}
		it := call(keysfn, ov, nil);
		next := getvalue(it, a_next);
		for(;;) {
			r := call1(next, it, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done)))
				break;
			v := getv(r.o, a_value);
			if(v.t == Tnum && v.n == 0.0)
				v = intv(0);
			if(hfind(m, v) >= 0)
				hdelete(rm, v);
			else if(hfind(rm, v) < 0)
				hset(rm, v, v);
		}
		return res;
	NSPissubset =>
		if(real m.live > sz)
			return falsev;
		for(i := 0; i < m.n; i++) {
			if(m.keys[i].t == Thole)
				continue;
			if(!tobool(call(has, ov, array[] of {m.keys[i]})))
				return falsev;
		}
		return truev;
	NSPissuperset =>
		if(real m.live < sz)
			return falsev;
		it := call(keysfn, ov, nil);
		next := getvalue(it, a_next);
		for(;;) {
			r := call1(next, it, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done)))
				return truev;
			if(hfind(m, getv(r.o, a_value)) < 0) {
				iterclose(it, 0);
				return falsev;
			}
		}
	NSPisdisjoint =>
		if(real m.live <= sz) {
			for(i := 0; i < m.n; i++) {
				if(m.keys[i].t == Thole)
					continue;
				if(tobool(call(has, ov, array[] of {m.keys[i]})))
					return falsev;
			}
			return truev;
		}
		it := call(keysfn, ov, nil);
		next := getvalue(it, a_next);
		for(;;) {
			r := call1(next, it, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done)))
				return truev;
			if(hfind(m, getv(r.o, a_value)) >= 0) {
				iterclose(it, 0);
				return falsev;
			}
		}
	}
	return undef;
}

revv(l: list of V): list of V
{
	r: list of V;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# ---- Promise ----

promiseinit()
{
	promisector = defctor("Promise", NPromise, 1, promiseproto);
	c := promisector;
	defmethod(c, "all", NPall, 1);
	defmethod(c, "allSettled", NPallsettled, 1);
	defmethod(c, "any", NPany, 1);
	defmethod(c, "race", NPrace, 1);
	defmethod(c, "reject", NPreject, 1);
	defmethod(c, "resolve", NPresolve, 1);
	defmethod(c, "withResolvers", NPwithresolvers, 0);
	defmethod(c, "try", NPtry, 1);
	defaccessor(c, a_symspecies, "[Symbol.species]", NPspecies, 0);
	p := promiseproto;
	defmethod(p, "then", NPPthen, 2);
	defmethod(p, "catch", NPPcatch, 1);
	defmethod(p, "finally", NPPfinally, 1);
	defprop(p, a_symtostringtag, strv("Promise"), Aconf);
}

thispromise(v: V): ref Obj
{
	if(v.t == Tobj && v.o.cls == Cpromise)
		return v.o;
	throwtype("Method Promise.prototype.then called on incompatible receiver " + showv(v));
	return nil;
}

natpromise(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NPromise =>
		if(nt == nil)
			throwtype("Promise constructor cannot be invoked without 'new'");
		ex := arg(args, 0);
		if(!iscallable(ex))
			throwtype("Promise resolver " + showv(ex) + " is not a function");
		p := newpromise(protofromctor(nt, promiseproto));
		(res, rej) := resolvingfns(p);
		{
			call(ex.o, undef, array[] of {objv(res), objv(rej)});
		} exception {
		"JS" =>
			call(rej, undef, array[] of {thrown});
		}
		return objv(p);
	NPspecies =>
		return this;
	NPresolve =>
		if(this.t != Tobj)
			throwtype("PromiseResolve called on non-object");
		return objv(promiseresolve(this.o, arg(args, 0)));
	NPreject =>
		cap := newcapof(this);
		call(cap.reject, undef, array[] of {arg(args, 0)});
		return objv(cap.promise);
	NPwithresolvers =>
		cap := newcapof(this);
		o := plainobj();
		addprop(o, intern("promise"), Adefault, objv(cap.promise));
		addprop(o, a_resolve, Adefault, objv(cap.resolve));
		addprop(o, a_reject, Adefault, objv(cap.reject));
		return objv(o);
	NPtry =>
		if(this.t != Tobj)
			throwtype("Promise.try called on non-object");
		# a callback's promise of this constructor is returned as it is (PromiseResolve)
		fnv := arg(args, 0);
		rest: array of V;
		if(len args > 1)
			rest = args[1:];
		r: V;
		{
			r = call1(fnv, undef, rest);
		} exception {
		"JS" =>
			ex := thrown;
			cap := newcapof(this);
			call(cap.reject, undef, array[] of {ex});
			return objv(cap.promise);
		}
		return objv(promiseresolve(this.o, r));
	NPPthen =>
		p := thispromise(this);
		c := speciesctor(p, promisector);
		cap := newcapof(objv(c));
		ok := arg(args, 0);
		bad := arg(args, 1);
		okf, badf: ref Obj;
		if(iscallable(ok))
			okf = ok.o;
		if(iscallable(bad))
			badf = bad.o;
		performthen(p, ref React(0, okf, cap, 0, nil), ref React(1, badf, cap, 0, nil));
		return objv(cap.promise);
	NPPcatch =>
		return invoke(this, a_then, array[] of {undef, arg(args, 0)});
	NPPfinally =>
		if(this.t != Tobj)
			throwtype("Promise.prototype.finally called on a non-object");
		c := speciesctor(this.o, promisector);
		onf := arg(args, 0);
		if(!iscallable(onf))
			return invoke(this, a_then, array[] of {onf, onf});
		tf := mknative(NPfinallyfn, "", 1);
		tf.data = ref Data.Native(onf, objv(c), 0, nil);
		cf := mknative(NPfinallyfn, "", 1);
		cf.data = ref Data.Native(onf, objv(c), 1, nil);
		return invoke(this, a_then, array[] of {objv(tf), objv(cf)});
	NPfinallyfn =>
		pick d := f.data {
		Native =>
			r := call(d.v.o, undef, nil);
			p := promiseresolve(d.w.o, r);
			th := mknative(NPthunk, "", 0);
			th.data = ref Data.Native(arg(args, 0), undef, d.i, nil);
			return invoke(objv(p), a_then, array[] of {objv(th)});
		}
	NPthunk =>
		pick d := f.data {
		Native =>
			if(d.i)
				throwv(d.v);
			return d.v;
		}
	NPall or NPallsettled or NPany or NPrace =>
		return promisecombine(id, this, arg(args, 0));
	NPallelem =>
		pick d := f.data {
		Pall =>
			if(d.done.v)
				return undef;
			d.done.v = 1;
			st := d.st;
			v := arg(args, 0);
			case d.kind {
			1 =>
				o := plainobj();
				addprop(o, a_status, Adefault, strv("fulfilled"));
				addprop(o, a_value, Adefault, v);
				v = objv(o);
			2 =>
				o := plainobj();
				addprop(o, a_status, Adefault, strv("rejected"));
				addprop(o, a_reason, Adefault, v);
				v = objv(o);
			}
			createdata(st.values, idxatom(d.i), v);
			if(--st.remaining == 0) {
				if(st.kind == 3) {
					e := mkerror(EAggregate, "All promises were rejected");
					defprop(e, a_errors, objv(st.values), Awrite|Aconf);
					call(st.cap.reject, undef, array[] of {objv(e)});
				} else
					call(st.cap.resolve, undef, array[] of {objv(st.values)});
			}
		}
		return undef;
	}
	throwerr(EError, "unknown Promise built-in");
	return undef;
}

promisecombine(id: int, c: V, iterable: V): V
{
	cap := newcapof(c);
	it: V;
	{
		resolve := getv(c.o, a_resolve);
		if(!iscallable(resolve))
			throwtype("Promise resolve is not a function");
		it = getiterator(iterable, 0);
		next := getvalue(it, a_next);
		st := ref Pall(newarray(0), 1, cap, 0);
		if(id == NPany)
			st.kind = 3;
		i := 0;
		for(;;) {
			r: V;
			done := 0;
			{
				r = call1(next, it, nil);
				if(r.t != Tobj)
					throwtype("Iterator result is not an object");
				done = tobool(getv(r.o, a_done));
				if(!done)
					r = getv(r.o, a_value);
			} exception {
			"JS" =>
				# a broken iterator is not closed
				raise "JSnoclose";
			}
			if(done) {
				if(id != NPrace && --st.remaining == 0) {
					if(id == NPany) {
						e := mkerror(EAggregate, "All promises were rejected");
						defprop(e, a_errors, objv(st.values), Awrite|Aconf);
						call(cap.reject, undef, array[] of {objv(e)});
					} else
						call(cap.resolve, undef, array[] of {objv(st.values)});
				}
				return objv(cap.promise);
			}
			{
				np := call(resolve.o, c, array[] of {r});
				case id {
				NPrace =>
					invoke(np, a_then, array[] of {objv(cap.resolve), objv(cap.reject)});
				* =>
					apush(st.values, undef);
					done1 := ref Flag(0);
					ok := mknative(NPallelem, "", 1);
					bad := mknative(NPallelem, "", 1);
					st.remaining++;
					case id {
					NPall =>
						ok.data = ref Data.Pall(st, i, 0, done1);
						invoke(np, a_then, array[] of {objv(ok), objv(cap.reject)});
					NPallsettled =>
						ok.data = ref Data.Pall(st, i, 1, done1);
						bad.data = ref Data.Pall(st, i, 2, done1);
						invoke(np, a_then, array[] of {objv(ok), objv(bad)});
					NPany =>
						bad.data = ref Data.Pall(st, i, 0, done1);
						invoke(np, a_then, array[] of {objv(cap.resolve), objv(bad)});
					}
				}
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(it, 1);
				throwv(ex);
			}
			i++;
		}
	} exception {
	"JS" =>
		call(cap.reject, undef, array[] of {thrown});
	"JSnoclose" =>
		call(cap.reject, undef, array[] of {thrown});
	}
	return objv(cap.promise);
}

# ---- Reflect ----

reflectinit()
{
	r := plainobj();
	defval(global, "Reflect", objv(r), Awrite|Aconf);
	defprop(r, a_symtostringtag, strv("Reflect"), Aconf);
	defmethod(r, "apply", NRapply, 3);
	defmethod(r, "construct", NRconstruct, 2);
	defmethod(r, "defineProperty", NRdefprop, 3);
	defmethod(r, "deleteProperty", NRdelprop, 2);
	defmethod(r, "get", NRget, 2);
	defmethod(r, "getOwnPropertyDescriptor", NRgopd, 2);
	defmethod(r, "getPrototypeOf", NRgetproto, 1);
	defmethod(r, "has", NRhas, 2);
	defmethod(r, "isExtensible", NRisext, 1);
	defmethod(r, "ownKeys", NRownkeys, 1);
	defmethod(r, "preventExtensions", NRprevent, 1);
	defmethod(r, "set", NRset, 3);
	defmethod(r, "setPrototypeOf", NRsetproto, 2);
	pc := mknative(NProxy, "Proxy", 2);
	pc.flags |= Fctor;
	defprop(global, intern("Proxy"), objv(pc), Awrite|Aconf);
	defmethod(pc, "revocable", NPxrevocable, 2);
}

robj(v: V, name: string): ref Obj
{
	if(v.t != Tobj)
		throwtype("Reflect." + name + " called on non-object");
	return v.o;
}

natreflect(id: int, f: ref Obj, nil: V, args: array of V, nt: ref Obj): V
{
	case id {
	NRapply =>
		fnv := arg(args, 0);
		if(!iscallable(fnv))
			throwtype("Function.prototype.apply was called on " + showv(fnv) + ", which is not a function");
		return call(fnv.o, arg(args, 1), listfrom(arg(args, 2)));
	NRconstruct =>
		c := arg(args, 0);
		if(c.t != Tobj || !isctor(c.o))
			throwtype(showv(c) + " is not a constructor");
		nt2 := c.o;
		if(len args > 2) {
			if(args[2].t != Tobj || !isctor(args[2].o))
				throwtype(showv(args[2]) + " is not a constructor");
			nt2 = args[2].o;
		}
		return construct(c.o, listfrom(arg(args, 1)), nt2);
	NRdefprop =>
		o := robj(arg(args, 0), "defineProperty");
		k := tokey(arg(args, 1));
		return boolv(defineown(o, k, todescriptor(arg(args, 2))));
	NRdelprop =>
		o := robj(arg(args, 0), "deleteProperty");
		return boolv(deleteprop(o, tokey(arg(args, 1))));
	NRget =>
		o := robj(arg(args, 0), "get");
		k := tokey(arg(args, 1));
		recv := objv(o);
		if(len args > 2)
			recv = args[2];
		return get(o, k, recv);
	NRgopd =>
		o := robj(arg(args, 0), "getOwnPropertyDescriptor");
		d := getowndesc(o, tokey(arg(args, 1)));
		if(d == nil)
			return undef;
		return objv(fromdesc(d));
	NRgetproto =>
		return objv(getprotoof(robj(arg(args, 0), "getPrototypeOf")));
	NRhas =>
		o := robj(arg(args, 0), "has");
		return boolv(hasprop(o, tokey(arg(args, 1))));
	NRisext =>
		return boolv(isextensible(robj(arg(args, 0), "isExtensible")));
	NRownkeys =>
		o := robj(arg(args, 0), "ownKeys");
		keys := ownkeys(o);
		r := newarray(0);
		for(i := 0; i < len keys; i++)
			if(!isprivkey(keys[i]))
				apush(r, keyv(keys[i]));
		return objv(r);
	NRprevent =>
		return boolv(preventext(robj(arg(args, 0), "preventExtensions")));
	NRset =>
		o := robj(arg(args, 0), "set");
		k := tokey(arg(args, 1));
		recv := objv(o);
		if(len args > 3)
			recv = args[3];
		return boolv(put(o, k, arg(args, 2), recv));
	NRsetproto =>
		o := robj(arg(args, 0), "setPrototypeOf");
		p := arg(args, 1);
		if(p.t != Tobj && p.t != Tnull)
			throwtype("Object prototype may only be an Object or null: " + showv(p));
		return boolv(setprotoof(o, objornil(p)));
	NProxy =>
		if(nt == nil)
			throwtype("Constructor Proxy requires 'new'");
		return objv(mkproxy(arg(args, 0), arg(args, 1)));
	NPxrevocable =>
		p := mkproxy(arg(args, 0), arg(args, 1));
		rv := mknative(NPxrevoke, "", 0);
		rv.data = ref Data.Native(objv(p), undef, 0, nil);
		o := plainobj();
		addprop(o, intern("proxy"), Adefault, objv(p));
		addprop(o, intern("revoke"), Adefault, objv(rv));
		return objv(o);
	NPxrevoke =>
		pick d := f.data {
		Native =>
			if(d.v.t == Tobj) {
				pick pd := d.v.o.data {
				Proxy =>
					pd.target = nil;
					pd.handler = nil;
				}
				d.v = undef;
			}
		}
		return undef;
	}
	throwerr(EError, "unknown Reflect built-in");
	return undef;
}

# ---- Proxy ----

mkproxy(t, h: V): ref Obj
{
	if(t.t != Tobj || h.t != Tobj)
		throwtype("Cannot create proxy with a non-object as target or handler");
	o := ref Obj;
	gcnew(o);
	o.cls = Cproxy;
	o.sh = rootshape;
	o.flags = Fext;
	o.data = ref Data.Proxy(t.o, h.o);
	if(t.o.fun != nil || t.o.cls == Cproxy && callableproxy(t.o)) {
		o.fun = ref Fn(nil, Npxcall, 0);
		if(isctor(t.o))
			o.flags |= Fctor;
	}
	return o;
}

callableproxy(o: ref Obj): int
{
	return o.fun != nil;
}

# the proxy's target and handler, and the trap of that name (nil if none)
pxtrap(p: ref Obj, name: string): (ref Obj, ref Obj, ref Obj)
{
	pick d := p.data {
	Proxy =>
		if(d.handler == nil)
			throwtype("Cannot perform '" + name + "' on a proxy that has been revoked");
		t := d.target;
		h := d.handler;
		trap := getmethod(objv(h), intern(name));
		return (t, h, trap);
	}
	return (nil, nil, nil);
}

pxgetproto(p: ref Obj): ref Obj
{
	(t, h, trap) := pxtrap(p, "getPrototypeOf");
	if(trap == nil)
		return getprotoof(t);
	r := call(trap, objv(h), array[] of {objv(t)});
	if(r.t != Tobj && r.t != Tnull)
		throwtype("'getPrototypeOf' on proxy: trap returned neither object nor null");
	if(isextensible(t))
		return r.o;
	if(r.o != getprotoof(t))
		throwtype("'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype");
	return r.o;
}

pxsetproto(p: ref Obj, v: ref Obj): int
{
	(t, h, trap) := pxtrap(p, "setPrototypeOf");
	if(trap == nil)
		return setprotoof(t, v);
	vv := nullv;
	if(v != nil)
		vv = objv(v);
	r := tobool(call(trap, objv(h), array[] of {objv(t), vv}));
	if(!r)
		return 0;
	if(isextensible(t))
		return 1;
	if(getprotoof(t) != v)
		throwtype("'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target");
	return 1;
}

pxisext(p: ref Obj): int
{
	(t, h, trap) := pxtrap(p, "isExtensible");
	if(trap == nil)
		return isextensible(t);
	r := tobool(call(trap, objv(h), array[] of {objv(t)}));
	if(r != isextensible(t))
		throwtype("'isExtensible' on proxy: trap result does not reflect extensibility of proxy target");
	return r;
}

pxprevent(p: ref Obj): int
{
	(t, h, trap) := pxtrap(p, "preventExtensions");
	if(trap == nil)
		return preventext(t);
	r := tobool(call(trap, objv(h), array[] of {objv(t)}));
	if(r && isextensible(t))
		throwtype("'preventExtensions' on proxy: trap returned truish but the proxy target is extensible");
	return r;
}

pxgetowndesc(p: ref Obj, k: int): ref Desc
{
	(t, h, trap) := pxtrap(p, "getOwnPropertyDescriptor");
	if(trap == nil)
		return getowndesc(t, k);
	r := call(trap, objv(h), array[] of {objv(t), keyv(k)});
	if(r.t != Tobj && r.t != Tundef)
		throwtype("'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined for property '" + keyname(k) + "'");
	td := getowndesc(t, k);
	if(r.t == Tundef) {
		if(td == nil)
			return nil;
		if((td.attrs & Aconf) == 0)
			throwtype("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '" + keyname(k) + "' which is non-configurable in the proxy target");
		if(!isextensible(t))
			throwtype("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '" + keyname(k) + "' which exists in the non-extensible proxy target");
		return nil;
	}
	ext := isextensible(t);
	d := todescriptor(r);
	completedesc(d);
	if(!compatibledesc(ext, d, td))
		throwtype("'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property '" + keyname(k) + "' that is incompatible with the existing property in the proxy target");
	if((d.attrs & Aconf) == 0) {
		if(td == nil || (td.attrs & Aconf))
			throwtype("'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property '" + keyname(k) + "' which is either non-existent or configurable in the proxy target");
		if((d.has & Dwrite) && (d.attrs & Awrite) == 0 && (td.attrs & Awrite))
			throwtype("'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and writable for property '" + keyname(k) + "' which is non-configurable, non-writable in the proxy target");
	}
	return d;
}

completedesc(d: ref Desc)
{
	if((d.has & (Dget|Dset)) == 0)
		d.has |= Dvalue|Dwrite;
	else
		d.has |= Dget|Dset;
	d.has |= Denum|Dconf;
}

# IsCompatiblePropertyDescriptor
compatibledesc(ext: int, d: ref Desc, cur: ref Desc): int
{
	if(cur == nil)
		return ext;
	if((cur.attrs & Aconf) == 0) {
		if((d.has & Dconf) && (d.attrs & Aconf))
			return 0;
		if((d.has & Denum) && (d.attrs & Aenum) != (cur.attrs & Aenum))
			return 0;
		dacc := (d.has & (Dget|Dset)) != 0;
		dgen := (d.has & (Dget|Dset|Dvalue|Dwrite)) == 0;
		cacc := (cur.has & (Dget|Dset)) != 0;
		if(!dgen && dacc != cacc)
			return 0;
		if(cacc) {
			if((d.has & Dget) && d.get != cur.get)
				return 0;
			if((d.has & Dset) && d.set != cur.set)
				return 0;
		} else if((cur.attrs & Awrite) == 0) {
			if((d.has & Dwrite) && (d.attrs & Awrite))
				return 0;
			if((d.has & Dvalue) && !samevalue(d.v, cur.v))
				return 0;
		}
	}
	return 1;
}

pxgetown(p: ref Obj, k: int): (int, V, int)
{
	d := pxgetowndesc(p, k);
	if(d == nil)
		return (0, undef, 0);
	if(d.has & (Dget|Dset))
		return (1, objv(newacc(d.get, d.set)), Aacc | (d.attrs & (Aenum|Aconf)));
	return (1, d.v, d.attrs & Adefault);
}

pxdefine(p: ref Obj, k: int, d: ref Desc): int
{
	(t, h, trap) := pxtrap(p, "defineProperty");
	if(trap == nil)
		return defineown(t, k, d);
	r := tobool(call(trap, objv(h), array[] of {objv(t), keyv(k), objv(fromdescpartial(d))}));
	if(!r)
		return 0;
	td := getowndesc(t, k);
	ext := isextensible(t);
	settingnc := (d.has & Dconf) && (d.attrs & Aconf) == 0;
	if(td == nil) {
		if(!ext)
			throwtype("'defineProperty' on proxy: trap returned truish for adding property '" + keyname(k) + "'  to the non-extensible proxy target");
		if(settingnc)
			throwtype("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keyname(k) + "' which is either non-existent or configurable in the proxy target");
	} else {
		if(!compatibledesc(ext, d, td))
			throwtype("'defineProperty' on proxy: trap returned truish for adding property '" + keyname(k) + "'  that is incompatible with the existing property in the proxy target");
		if(settingnc && (td.attrs & Aconf))
			throwtype("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keyname(k) + "' which is either non-existent or configurable in the proxy target");
		if((td.has & Dvalue) && (td.attrs & Aconf) == 0 && (td.attrs & Awrite) && (d.has & Dwrite) && (d.attrs & Awrite) == 0)
			throwtype("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keyname(k) + "' which cannot be non-writable, unless there exists a corresponding non-configurable, non-writable own property of the target object.");
	}
	return 1;
}

# a descriptor as an object, with only the fields it has
fromdescpartial(d: ref Desc): ref Obj
{
	o := plainobj();
	if(d.has & Dvalue)
		createdata(o, a_value, d.v);
	if(d.has & Dwrite)
		createdata(o, a_writable, boolv(d.attrs & Awrite));
	if(d.has & Dget)
		createdata(o, a_get, objvu(d.get));
	if(d.has & Dset)
		createdata(o, a_set, objvu(d.set));
	if(d.has & Denum)
		createdata(o, a_enumerable, boolv(d.attrs & Aenum));
	if(d.has & Dconf)
		createdata(o, a_configurable, boolv(d.attrs & Aconf));
	return o;
}

objvu(o: ref Obj): V
{
	if(o == nil)
		return undef;
	return objv(o);
}

pxhas(p: ref Obj, k: int): int
{
	(t, h, trap) := pxtrap(p, "has");
	if(trap == nil)
		return hasprop(t, k);
	r := tobool(call(trap, objv(h), array[] of {objv(t), keyv(k)}));
	if(!r) {
		td := getowndesc(t, k);
		if(td != nil) {
			if((td.attrs & Aconf) == 0)
				throwtype("'has' on proxy: trap returned falsish for property '" + keyname(k) + "' which exists in the proxy target as non-configurable");
			if(!isextensible(t))
				throwtype("'has' on proxy: trap returned falsish for property '" + keyname(k) + "' but the proxy target is not extensible");
		}
	}
	return r;
}

pxget(p: ref Obj, k: int, recv: V): V
{
	(t, h, trap) := pxtrap(p, "get");
	if(trap == nil)
		return get(t, k, recv);
	r := call(trap, objv(h), array[] of {objv(t), keyv(k), recv});
	td := getowndesc(t, k);
	if(td != nil && (td.attrs & Aconf) == 0) {
		if((td.has & Dvalue) && (td.attrs & Awrite) == 0 && !samevalue(r, td.v))
			throwtype("'get' on proxy: property '" + keyname(k) + "' is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value");
		if((td.has & (Dget|Dset)) && td.get == nil && r.t != Tundef)
			throwtype("'get' on proxy: property '" + keyname(k) + "' is a non-configurable accessor property on the proxy target and does not have a getter function, but the trap did not return 'undefined'");
	}
	return r;
}

pxset(p: ref Obj, k: int, v: V, recv: V): int
{
	(t, h, trap) := pxtrap(p, "set");
	if(trap == nil)
		return put(t, k, v, recv);
	r := tobool(call(trap, objv(h), array[] of {objv(t), keyv(k), v, recv}));
	if(!r)
		return 0;
	td := getowndesc(t, k);
	if(td != nil && (td.attrs & Aconf) == 0) {
		if((td.has & Dvalue) && (td.attrs & Awrite) == 0 && !samevalue(v, td.v))
			throwtype("'set' on proxy: trap returned truish for property '" + keyname(k) + "' which exists in the proxy target as a non-configurable and non-writable data property with a different value");
		if((td.has & (Dget|Dset)) && td.set == nil)
			throwtype("'set' on proxy: trap returned truish for property '" + keyname(k) + "' which exists in the proxy target as a non-configurable and non-writable accessor property without a setter");
	}
	return 1;
}

pxdelete(p: ref Obj, k: int): int
{
	(t, h, trap) := pxtrap(p, "deleteProperty");
	if(trap == nil)
		return deleteprop(t, k);
	r := tobool(call(trap, objv(h), array[] of {objv(t), keyv(k)}));
	if(!r)
		return 0;
	td := getowndesc(t, k);
	if(td != nil) {
		if((td.attrs & Aconf) == 0)
			throwtype("'deleteProperty' on proxy: trap returned truish for property '" + keyname(k) + "' which is non-configurable in the proxy target");
		if(!isextensible(t))
			throwtype("'deleteProperty' on proxy: trap returned truish for property '" + keyname(k) + "' but the proxy target is non-extensible");
	}
	return 1;
}

pxownkeys(p: ref Obj): array of int
{
	(t, h, trap) := pxtrap(p, "ownKeys");
	if(trap == nil)
		return ownkeys(t);
	r := call(trap, objv(h), array[] of {objv(t)});
	if(r.t != Tobj)
		throwtype("CreateListFromArrayLike called on non-object");
	n := lengthof(r.o);
	keys := array[int n] of int;
	seen := newhmap();
	for(i := 0; i < len keys; i++) {
		e := getidx(r.o, i, r);
		if(!isstr(e) && e.t != Tsym)
			throwtype(showv(e) + " is not a valid property name");
		if(hfind(seen, e) >= 0)
			throwtype("'ownKeys' on proxy: trap returned duplicate entries");
		hset(seen, e, truev);
		keys[i] = tokey(e);
	}
	ext := isextensible(t);
	tkeys := ownkeys(t);
	for(i = 0; i < len tkeys; i++) {
		k := tkeys[i];
		if(isprivkey(k))
			continue;
		d := getowndesc(t, k);
		found := 0;
		for(j := 0; j < len keys; j++)
			if(keys[j] == k)
				found = 1;
		if(!found && (d != nil && (d.attrs & Aconf) == 0 || !ext))
			throwtype("'ownKeys' on proxy: trap result did not include '" + keyname(k) + "'");
	}
	if(!ext) {
		for(j := 0; j < len keys; j++) {
			found := 0;
			for(i = 0; i < len tkeys; i++)
				if(tkeys[i] == keys[j])
					found = 1;
			if(!found)
				throwtype("'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible");
		}
	}
	return keys;
}

pxcall(p: ref Obj, this: V, args: array of V): V
{
	(t, h, trap) := pxtrap(p, "apply");
	if(trap == nil)
		return call(t, this, args);
	return call(trap, objv(h), array[] of {objv(t), this, objv(mkarray(args))});
}

pxconstruct(p: ref Obj, args: array of V, nt: ref Obj): V
{
	(t, h, trap) := pxtrap(p, "construct");
	if(trap == nil)
		return construct(t, args, nt);
	r := call(trap, objv(h), array[] of {objv(t), objv(mkarray(args)), objv(nt)});
	if(r.t != Tobj)
		throwtype("proxy [[Construct]] must return an object");
	return r;
}

# ---- iterators ----

itertagset := 0;

iterinit()
{
	ic := mknative(NIterator, "Iterator", 0);
	ic.flags |= Fctor;
	defprop(ic, a_prototype, objv(iterproto), 0);
	defprop(global, intern("Iterator"), objv(ic), Awrite|Aconf);
	defmethod(ic, "from", NIfrom, 1);
	defmethod(ic, "concat", NIconcat, 0);
	p := iterproto;
	defsymmethod(p, a_symiterator, "[Symbol.iterator]", NIPiterator, 0);
	defmethod(p, "map", NIPmap, 1);
	defmethod(p, "filter", NIPfilter, 1);
	defmethod(p, "take", NIPtake, 1);
	defmethod(p, "drop", NIPdrop, 1);
	defmethod(p, "flatMap", NIPflatmap, 1);
	defmethod(p, "reduce", NIPreduce, 1);
	defmethod(p, "toArray", NIPtoarray, 0);
	defmethod(p, "forEach", NIPforeach, 1);
	defmethod(p, "some", NIPsome, 1);
	defmethod(p, "every", NIPevery, 1);
	defmethod(p, "find", NIPfind, 1);
	defaccessor(p, a_symtostringtag, "[Symbol.toStringTag]", NIPtagget, NIPtagset);
	defaccessor(p, a_constructor, "constructor", NIPctorget, NIPctorset);
	iterhelperproto = newobj(Cplain, iterproto);
	defmethod(iterhelperproto, "next", NIHnext, 0);
	defmethod(iterhelperproto, "return", NIHreturn, 0);
	defprop(iterhelperproto, a_symtostringtag, strv("Iterator Helper"), Aconf);
	wrapforvalidproto = newobj(Cplain, iterproto);
	defmethod(wrapforvalidproto, "next", NIWnext, 0);
	defmethod(wrapforvalidproto, "return", NIWreturn, 0);
}

# helper kinds (Data.Iter.kind)
HKmap, HKfilter, HKtake, HKdrop, HKflatmap, HKconcat: con 20 + iota;

# GetIteratorDirect: the iterator's object and its next method
iterdirect(v: V): (V, V)
{
	if(v.t != Tobj)
		throwtype(showv(v) + " is not an object");
	return (v, getv(v.o, a_next));
}

iterstep(it, next: V): (V, int)
{
	r := call1(next, it, nil);
	if(r.t != Tobj)
		throwtype("Iterator result " + showv(r) + " is not an object");
	if(tobool(getv(r.o, a_done)))
		return (undef, 1);
	return (getv(r.o, a_value), 0);
}

Helper: adt {
	it, next:	V;
	fun:	V;
	count:	real;
	limit:	real;
	inner:	V;
	innernext:	V;
	running:	int;
	items:	array of (V, V);	# concat's iterables and their methods
	idx:	int;
	started:	int;
};

helpers: list of (ref Obj, ref Helper);

helperof(o: ref Obj): ref Helper
{
	pick d := o.data {
	Iter =>
		if(d.aux != nil) {
			for(l := helpers; l != nil; l = tl l) {
				(k, h) := hd l;
				if(k == d.aux)
					return h;
			}
		}
	}
	return nil;
}

mkhelper(kind: int, h: ref Helper): V
{
	o := newobj(Citer, iterhelperproto);
	key := ref Obj;
	gcnew(key);
	o.data = ref Data.Iter(kind, nil, undef, 0, 0, key);
	helpers = (key, h) :: helpers;
	return objv(o);
}

natiter(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NIterator =>
		if(nt == nil || nt.fun != nil && nt.fun.native == NIterator)
			throwtype("Abstract class Iterator not directly constructable");
		return objv(fromctor(nt, iterproto, Cplain));
	NIfrom =>
		o := arg(args, 0);
		if(isstr(o)) {
			o = strv(flat(o));
		} else if(o.t != Tobj)
			throwtype("Iterator.from called on non-object");
		m := getmethod(o, a_symiterator);
		it, next: V;
		if(m == nil) {
			(it, next) = iterdirect(o);
		} else {
			it = call(m, o, nil);
			if(it.t != Tobj)
				throwtype("Result of the Symbol.iterator method is not an object");
			next = getvalue(it, a_next);
		}
		if(ordinaryhasinstance(iterctor(), it))
			return it;
		w := newobj(Citer, wrapforvalidproto);
		key := ref Obj;
		gcnew(key);
		w.data = ref Data.Iter(0, nil, undef, 0, 0, key);
		helpers = (key, ref Helper(it, next, undef, 0.0, 0.0, undef, undef, 0, nil, 0, 0)) :: helpers;
		return objv(w);
	NIconcat =>
		items := array[len args] of (V, V);
		for(i := 0; i < len args; i++) {
			if(args[i].t != Tobj)
				throwtype("Iterator.concat: argument is not an object");
			m := getv(args[i].o, a_symiterator);
			if(!iscallable(m))
				throwtype("Iterator.concat: argument is not iterable");
			items[i] = (args[i], m);
		}
		return mkhelper(HKconcat, ref Helper(undef, undef, undef, 0.0, 0.0, undef, undef, 0, items, 0, 0));
	NIWnext =>
		h := thishelper(this);
		return call1(h.next, h.it, nil);
	NIWreturn =>
		h := thishelper(this);
		m := getmethod(h.it, a_return);
		if(m == nil)
			return iterresult(undef, 1);
		return call(m, h.it, nil);
	NIPiterator =>
		return this;
	NIPtagget =>
		return strv("Iterator");
	NIPctorget =>
		return objv(iterctor());
	NIPtagset or NIPctorset =>
		if(this.t != Tobj)
			throwtype("setter called on non-object");
		if(this.o == iterproto)
			throwtype("Cannot assign to read only property of Iterator.prototype");
		k := a_symtostringtag;
		if(id == NIPctorset)
			k = a_constructor;
		if(getowndesc(this.o, k) == nil)
			createdatathrow(this.o, k, arg(args, 0));
		else
			put(this.o, k, arg(args, 0), this);
		return undef;
	NIHnext =>
		return helpernext(this);
	NAFSunwrap =>
		pick d := f.data {
		Native =>
			return iterresult(arg(args, 0), d.v.i);
		}
	NAFSclose =>
		pick d := f.data {
		Native =>
			iterclose(d.v, 1);
		}
		throwv(arg(args, 0));
	NIHreturn =>
		if(this.t != Tobj || this.o.cls != Citer)
			throwtype("Iterator helper return called on incompatible receiver");
		h := helperof(this.o);
		if(h == nil)
			throwtype("Iterator helper return called on incompatible receiver");
		if(h.running)
			throwtype("Generator is already running");
		pick d := this.o.data {
		Iter =>
			if(d.done)
				return iterresult(undef, 1);
			d.done = 1;
			if(d.kind == HKconcat) {
				# the helper is running while its iterator closes: return again is refused
				if(h.inner.t == Tobj) {
					h.running = 1;
					{
						iterclose(h.inner, 0);
					} exception {
					"JS" =>
						h.running = 0;
						raise;
					}
					h.running = 0;
				}
				return iterresult(undef, 1);
			}
			if(d.kind == HKflatmap && h.inner.t == Tobj) {
				{
					iterclose(h.inner, 0);
				} exception {
				"JS" =>
					ex := thrown;
					iterclose(h.it, 1);
					throwv(ex);
				}
			}
			iterclose(h.it, 0);
		}
		return iterresult(undef, 1);
	}
	# the prototype methods: this is an iterator
	if(this.t != Tobj)
		throwtype("Iterator.prototype method called on non-object");
	fnv := arg(args, 0);
	case id {
	NIPmap or NIPfilter or NIPflatmap or NIPreduce or NIPforeach or NIPsome or NIPevery or NIPfind =>
		if(!iscallable(fnv)) {
			iterclose(this, 1);
			throwtype(showv(fnv) + " is not a function");
		}
	NIPtake or NIPdrop =>
		x := 0.0;
		{
			x = tonum(fnv);
		} exception {
		"JS" =>
			ex := thrown;
			iterclose(this, 1);
			throwv(ex);
		}
		if(isnan(x)) {
			iterclose(this, 1);
			throwerr(ERange, showv(fnv) + " must be positive");
		}
		x = tointeger(V(Tnum, 0, x, nil, nil));
		# a limit is a safe integer, or infinity
		if(x < 0.0 || x > 9007199254740991.0 && x != inf) {
			iterclose(this, 1);
			throwerr(ERange, showv(fnv) + " must be positive");
		}
		(it, next) := iterdirect(this);
		kind := HKtake;
		if(id == NIPdrop)
			kind = HKdrop;
		return mkhelper(kind, ref Helper(it, next, undef, 0.0, x, undef, undef, 0, nil, 0, 0));
	}
	(it, next) := iterdirect(this);
	case id {
	NIPmap or NIPfilter or NIPflatmap =>
		kind := HKmap;
		if(id == NIPfilter)
			kind = HKfilter;
		else if(id == NIPflatmap)
			kind = HKflatmap;
		return mkhelper(kind, ref Helper(it, next, fnv, 0.0, 0.0, undef, undef, 0, nil, 0, 0));
	NIPreduce =>
		acc: V;
		k := 0.0;
		if(len args > 1)
			acc = args[1];
		else {
			(v, done) := iterstep(it, next);
			if(done)
				throwtype("Reduce of empty iterator with no initial value");
			acc = v;
			k = 1.0;
		}
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				return acc;
			{
				acc = call(fnv.o, undef, array[] of {acc, v, numv(k)});
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(it, 1);
				throwv(ex);
			}
			k += 1.0;
		}
	NIPtoarray =>
		a := newarray(0);
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				return objv(a);
			apush(a, v);
		}
	NIPforeach or NIPsome or NIPevery or NIPfind =>
		k := 0.0;
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				break;
			r: V;
			{
				r = call(fnv.o, undef, array[] of {v, numv(k)});
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(it, 1);
				throwv(ex);
			}
			case id {
			NIPsome =>
				if(tobool(r)) {
					iterclose(it, 0);
					return truev;
				}
			NIPevery =>
				if(!tobool(r)) {
					iterclose(it, 0);
					return falsev;
				}
			NIPfind =>
				if(tobool(r)) {
					iterclose(it, 0);
					return v;
				}
			}
			k += 1.0;
		}
		case id {
		NIPsome =>
			return falsev;
		NIPevery =>
			return truev;
		}
		return undef;
	}
	throwerr(EError, "unknown Iterator built-in");
	return undef;
}

iterctor(): ref Obj
{
	v := getv(global, intern("Iterator"));
	if(v.t == Tobj)
		return v.o;
	return nil;
}

thishelper(this: V): ref Helper
{
	if(this.t == Tobj && this.o.cls == Citer) {
		h := helperof(this.o);
		if(h != nil)
			return h;
	}
	throwtype("method called on incompatible receiver " + showv(this));
	return nil;
}

helpernext(this: V): V
{
	if(this.t != Tobj || this.o.cls != Citer)
		throwtype("Iterator helper next called on incompatible receiver");
	h := helperof(this.o);
	if(h == nil)
		throwtype("Iterator helper next called on incompatible receiver");
	if(h.running)
		throwtype("Generator is already running");
	kind := 0;
	pick d := this.o.data {
	Iter =>
		if(d.done)
			return iterresult(undef, 1);
		kind = d.kind;
	}
	h.running = 1;
	r: V;
	done := 0;
	{
		(r, done) = helperstep(h, kind);
	} exception {
	"JS*" =>
		h.running = 0;
		markdone(this.o);
		raise;
	}
	h.running = 0;
	if(done) {
		markdone(this.o);
		return iterresult(undef, 1);
	}
	return iterresult(r, 0);
}

markdone(o: ref Obj)
{
	pick d := o.data {
	Iter =>
		d.done = 1;
	}
}

helperstep(h: ref Helper, kind: int): (V, int)
{
	case kind {
	HKmap =>
		(v, done) := iterstep(h.it, h.next);
		if(done)
			return (undef, 1);
		r: V;
		{
			r = call(h.fun.o, undef, array[] of {v, numv(h.count)});
		} exception {
		"JS" =>
			ex := thrown;
			iterclose(h.it, 1);
			throwv(ex);
		}
		h.count += 1.0;
		return (r, 0);
	HKfilter =>
		for(;;) {
			(v, done) := iterstep(h.it, h.next);
			if(done)
				return (undef, 1);
			r: V;
			{
				r = call(h.fun.o, undef, array[] of {v, numv(h.count)});
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(h.it, 1);
				throwv(ex);
			}
			h.count += 1.0;
			if(tobool(r))
				return (v, 0);
		}
	HKtake =>
		if(h.count >= h.limit) {
			iterclose(h.it, 0);
			return (undef, 1);
		}
		h.count += 1.0;
		return iterstep(h.it, h.next);
	HKdrop =>
		while(h.count < h.limit) {
			h.count += 1.0;
			(nil, done) := iterstep(h.it, h.next);
			if(done)
				return (undef, 1);
		}
		return iterstep(h.it, h.next);
	HKflatmap =>
		for(;;) {
			if(h.inner.t == Tobj) {
				r: V;
				done: int;
				{
					(r, done) = iterstep(h.inner, h.innernext);
				} exception {
				"JS" =>
					ex := thrown;
					iterclose(h.it, 1);
					throwv(ex);
				}
				if(!done)
					return (r, 0);
				h.inner = undef;
				continue;
			}
			(v, done) := iterstep(h.it, h.next);
			if(done)
				return (undef, 1);
			{
				m := call(h.fun.o, undef, array[] of {v, numv(h.count)});
				h.count += 1.0;
				# GetIteratorFlattenable: strings are not iterated
				if(m.t != Tobj)
					throwtype("flatMap mapper returned a non-object");
				meth := getmethod(m, a_symiterator);
				if(meth == nil)
					(h.inner, h.innernext) = iterdirect(m);
				else {
					h.inner = call(meth, m, nil);
					if(h.inner.t != Tobj)
						throwtype("Result of the Symbol.iterator method is not an object");
					h.innernext = getvalue(h.inner, a_next);
				}
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(h.it, 1);
				throwv(ex);
			}
		}
	HKconcat =>
		for(;;) {
			if(h.inner.t == Tobj) {
				r := call1(h.innernext, h.inner, nil);
				if(r.t != Tobj)
					throwtype("Iterator result is not an object");
				if(!tobool(getv(r.o, a_done)))
					return (getv(r.o, a_value), 0);
				h.inner = undef;
				continue;
			}
			if(h.idx >= len h.items)
				return (undef, 1);
			(o, m) := h.items[h.idx++];
			it := call1(m, o, nil);
			if(it.t != Tobj)
				throwtype("Result of the Symbol.iterator method is not an object");
			h.inner = it;
			h.innernext = getvalue(it, a_next);
		}
	}
	return (undef, 1);
}

# %AsyncFromSyncIteratorPrototype%'s methods
asyncfromsyncstep(id: int, this: V, args: array of V): V
{
	cap := newcap();
	it: ref Obj;
	next := undef;
	pick d := this.o.data {
	Iter =>
		it = d.o;
		next = d.v;
	}
	{
		r: V;
		case id {
		NAFSnext =>
			if(len args > 0)
				r = call1(next, objv(it), array[] of {args[0]});
			else
				r = call1(next, objv(it), nil);
		NAFSreturn =>
			m := getmethod(objv(it), a_return);
			if(m == nil) {
				resolvecap(cap, iterresult(arg(args, 0), 1));
				return objv(cap.promise);
			}
			if(len args > 0)
				r = call(m, objv(it), array[] of {args[0]});
			else
				r = call(m, objv(it), nil);
		* =>
			m := getmethod(objv(it), a_throw);
			if(m == nil) {
				# close the iterator, then a TypeError
				{
					iterclose(objv(it), 0);
				} exception {
				"JS" =>
					rejectcap(cap, thrown);
					return objv(cap.promise);
				}
				throwtype("The iterator does not provide a 'throw' method");
			}
			r = call(m, objv(it), array[] of {arg(args, 0)});
		}
		if(r.t != Tobj)
			throwtype("Iterator result is not an object");
		done := tobool(getv(r.o, a_done));
		v := getv(r.o, a_value);
		vw: ref Obj;
		{
			vw = promiseresolve(promisector, v);
		} exception {
		"JS" =>
			ex := thrown;
			if(!done && id != NAFSreturn)
				iterclose(objv(it), 1);
			throwv(ex);
		}
		ok := mknative(NPthunk, "", 1);
		ok.data = ref Data.Native(undef, undef, 0, nil);
		# unwrap: {value: v, done} once v settles
		unw := mknative(NAFSunwrap, "", 1);
		unw.data = ref Data.Native(boolv(done), objv(it), id, nil);
		closer: ref Obj;
		if(!done && id != NAFSreturn) {
			closer = mknative(NAFSclose, "", 1);
			closer.data = ref Data.Native(objv(it), undef, 0, nil);
		}
		performthen(vw, ref React(0, unw, cap, 0, nil), ref React(1, closer, cap, 0, nil));
	} exception {
	"JS" =>
		rejectcap(cap, thrown);
	}
	return objv(cap.promise);
}

NAFSunwrap: con Niterbase + 40;
NAFSclose: con Niterbase + 41;
