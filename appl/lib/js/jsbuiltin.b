#
# jsbuiltin.b - the realm's intrinsics and its built-in objects.
# Included by js.b.
#

# intrinsics
iobjproto, ifuncproto, iarrproto, istrproto, inumproto, iboolproto, isymproto, ibigproto,
ierrorproto, iglobal, ievalfn, ithrowtypeerror, iiterproto, iarrayiterproto, iarrvalues, iarriternext,
igenproto, igenfuncproto, iasyncfuncproto, iasyncgenproto, iasyncgenfuncproto, iasynciterproto,
iasyncfromsyncproto, ipromiseproto, ipromisector, iregexpproto, iobjctor, ifuncctor, iarrctor,
istriterproto, imapproto, isetproto, imapiterproto, isetiterproto, iweakmapproto, iweaksetproto,
idateproto, iregexpstriterproto: int;
ierrorprotos := array[8] of int;
ierrorctors := array[8] of int;

intr: array of int;		# every intrinsic, for the collector
nintr := 0;

# atoms of common keys
alength, aname, aprototype, aconstructor, amessage, atostring, avalueof, aundefined, anull,
atrue, afalse, athen, avalue, adone, anext, areturn, athrow, acallee, alastindex, aget, aset,
awritable, aenumerable, aconfigurable, acause, aerrors, araw, aindex, ainput, agroups, aflags,
asource, aglobal, akey: int;
# well-known symbols
asymiterator, asymasynciter, asymhasinst, asymtoprim, asymtostrtag, asymspecies,
asymunscopables, asymisconcat, asymmatch, asymmatchall, asymreplace, asymsearch, asymsplit: int;

keep(h: int): int
{
	if(intr == nil)
		intr = array[256] of int;
	if(nintr == len intr) {
		a := array[2 * nintr] of int;
		a[0:] = intr;
		intr = a;
	}
	intr[nintr++] = h;
	return h;
}

wellknown(name: string): int
{
	a := newsymbol("Symbol." + name, 1);
	return a;
}

realminit()
{
	alength = intern("length");
	aname = intern("name");
	aprototype = intern("prototype");
	aconstructor = intern("constructor");
	amessage = intern("message");
	atostring = intern("toString");
	avalueof = intern("valueOf");
	aundefined = intern("undefined");
	anull = intern("null");
	atrue = intern("true");
	afalse = intern("false");
	athen = intern("then");
	avalue = intern("value");
	adone = intern("done");
	anext = intern("next");
	areturn = intern("return");
	athrow = intern("throw");
	acallee = intern("callee");
	alastindex = intern("lastIndex");
	aget = intern("get");
	aset = intern("set");
	awritable = intern("writable");
	aenumerable = intern("enumerable");
	aconfigurable = intern("configurable");
	acause = intern("cause");
	aerrors = intern("errors");
	araw = intern("raw");
	aindex = intern("index");
	ainput = intern("input");
	agroups = intern("groups");
	aflags = intern("flags");
	asource = intern("source");
	aglobal = intern("global");
	akey = intern("key");
	asymiterator = wellknown("iterator");
	asymasynciter = wellknown("asyncIterator");
	asymhasinst = wellknown("hasInstance");
	asymtoprim = wellknown("toPrimitive");
	asymtostrtag = wellknown("toStringTag");
	asymspecies = wellknown("species");
	asymunscopables = wellknown("unscopables");
	asymisconcat = wellknown("isConcatSpreadable");
	asymmatch = wellknown("match");
	asymmatchall = wellknown("matchAll");
	asymreplace = wellknown("replace");
	asymsearch = wellknown("search");
	asymsplit = wellknown("split");

	# the prototypes first: everything else is made from them
	iobjproto = keep(newobj(Kord, -1));
	ifuncproto = keep(newobj(Knative, iobjproto));
	oflags[ifuncproto] |= Ocallable;
	odata[ifuncproto] = ref Data.Native(nothing, "", nil);
	addprop(ifuncproto, alength, Aconf, num(0.0));
	addprop(ifuncproto, aname, Aconf, strv(""));
	iarrproto = keep(newobj(Karray, iobjproto));
	ierrorproto = keep(newobj(Kord, iobjproto));
	iglobal = keep(newobj(Kord, iobjproto));
	iiterproto = keep(newobj(Kord, iobjproto));
	iasynciterproto = keep(newobj(Kord, iobjproto));
	iarrayiterproto = keep(newobj(Kord, iiterproto));
	istriterproto = keep(newobj(Kord, iiterproto));
	igenproto = keep(newobj(Kord, iiterproto));
	iasyncgenproto = keep(newobj(Kord, iasynciterproto));
	iasyncfromsyncproto = keep(newobj(Kord, iasynciterproto));
	ipromiseproto = keep(newobj(Kord, iobjproto));
	iregexpproto = keep(newobj(Kord, iobjproto));
	imapproto = keep(newobj(Kord, iobjproto));
	isetproto = keep(newobj(Kord, iobjproto));
	imapiterproto = keep(newobj(Kord, iiterproto));
	isetiterproto = keep(newobj(Kord, iiterproto));
	iweakmapproto = keep(newobj(Kord, iobjproto));
	iweaksetproto = keep(newobj(Kord, iobjproto));
	idateproto = keep(newobj(Kord, iobjproto));
	iregexpstriterproto = keep(newobj(Kord, iiterproto));

	g := iglobal;
	defown(g, intern("globalThis"), Awrite|Aconf, objv(g));
	defown(g, intern("NaN"), 0, num(nan));
	defown(g, intern("Infinity"), 0, num(inf));
	defown(g, aundefined, 0, undef);

	ithrowtypeerror = keep(nativefn("", 0, throwtypeerror));
	preventext(ithrowtypeerror);
	freeze(ithrowtypeerror);

	objectinit();
	functioninit();
	errorinit();
	symbolinit();
	primsinit();
	arrayinit();
	iterinit();
	globalfnsinit();
	stringinit();
	numberinit();
	mathinit();
	jsoninit();
	collectionsinit();
	promiseinit();
	regexpinit();
	reflectinit();
	generatorinit();
}

nothing(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return undef;
}

throwtypeerror(nil: V, nil, nil: int, nil: V, nil: int): V
{
	typeerr("'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
	return undef;
}

# ---- definition helpers ----

method(o: int, name: string, length: int, f: Native): int
{
	h := nativefn(name, length, f);
	defown(o, intern(name), Awrite|Aconf, objv(h));
	return h;
}

symmethod(o: int, sym: int, name: string, length: int, f: Native): int
{
	h := nativefn(name, length, f);
	defown(o, sym, Awrite|Aconf, objv(h));
	return h;
}

getter(o: int, k: int, name: string, f: Native): int
{
	h := nativefn("get " + name, 0, f);
	defown(o, k, Aacc|Aconf, V(Tacc, h, -1.0));
	return h;
}

accessor(o: int, k: int, name: string, gf, sf: Native): int
{
	g := nativefn("get " + name, 0, gf);
	s := nativefn("set " + name, 1, sf);
	defown(o, k, Aacc|Aconf, V(Tacc, g, real s));
	return g;
}

# a constructor: the function, its prototype's constructor, a global
ctor(name: string, length: int, f: Native, proto: int): int
{
	h := nativefn(name, length, f);
	oflags[h] |= Octor;
	if(proto >= 0) {
		defown(h, aprototype, 0, objv(proto));
		defown(proto, aconstructor, Awrite|Aconf, objv(h));
	}
	defown(iglobal, intern(name), Awrite|Aconf, objv(h));
	return keep(h);
}

value(o: int, name: string, v: V)
{
	defown(o, intern(name), Awrite|Aconf, v);
}

tag(o: int, s: string)
{
	defown(o, asymtostrtag, Aconf, strv(s));
}

thisobj(this: V, name: string): int
{
	if(this.t != Tobj)
		typeerr(name + " called on non-object");
	return this.x;
}

# ---- Object ----

objectinit()
{
	iobjctor = ctor("Object", 1, objectctor, iobjproto);
	c := iobjctor;
	method(c, "getPrototypeOf", 1, object_getprototypeof);
	method(c, "setPrototypeOf", 2, object_setprototypeof);
	method(c, "create", 2, object_create);
	method(c, "defineProperty", 3, object_defineproperty);
	method(c, "defineProperties", 2, object_defineproperties);
	method(c, "getOwnPropertyDescriptor", 2, object_getownpropertydescriptor);
	method(c, "getOwnPropertyDescriptors", 1, object_getownpropertydescriptors);
	method(c, "getOwnPropertyNames", 1, object_getownpropertynames);
	method(c, "getOwnPropertySymbols", 1, object_getownpropertysymbols);
	method(c, "keys", 1, object_keys);
	method(c, "values", 1, object_values);
	method(c, "entries", 1, object_entries);
	method(c, "assign", 2, object_assign);
	method(c, "freeze", 1, object_freeze);
	method(c, "isFrozen", 1, object_isfrozen);
	method(c, "seal", 1, object_seal);
	method(c, "isSealed", 1, object_issealed);
	method(c, "preventExtensions", 1, object_preventextensions);
	method(c, "isExtensible", 1, object_isextensible);
	method(c, "is", 2, object_is);
	method(c, "hasOwn", 2, object_hasown);
	method(c, "fromEntries", 1, object_fromentries);
	method(c, "groupBy", 2, object_groupby);
	p := iobjproto;
	method(p, "hasOwnProperty", 1, objproto_hasownproperty);
	method(p, "isPrototypeOf", 1, objproto_isprototypeof);
	method(p, "propertyIsEnumerable", 1, objproto_propertyisenumerable);
	method(p, "toString", 0, objproto_tostring);
	method(p, "toLocaleString", 0, objproto_tolocalestring);
	method(p, "valueOf", 0, objproto_valueof);
	method(p, "__defineGetter__", 2, objproto_definegetter);
	method(p, "__defineSetter__", 2, objproto_definesetter);
	method(p, "__lookupGetter__", 1, objproto_lookupgetter);
	method(p, "__lookupSetter__", 1, objproto_lookupsetter);
	accessor(p, intern("__proto__"), "__proto__", objproto_getproto, objproto_setproto);
}

objectctor(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t != Tundef && nt.x != f)
		return objv(newobj(Kord, protofromctor(nt, iobjproto)));
	v := arg(a, n, 0);
	if(v.t == Tundef || v.t == Tnull)
		return objv(newplain());
	return objv(toobject(v));
}

object_getprototypeof(nil: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(arg(a, n, 0));
	p := getproto(h);
	if(p < 0)
		return null;
	return objv(p);
}

object_setprototypeof(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	p := arg(a, n, 1);
	if(o.t == Tundef || o.t == Tnull)
		typeerr("Object.setPrototypeOf called on null or undefined");
	if(p.t != Tobj && p.t != Tnull)
		typeerr("object prototype may only be an Object or null");
	if(o.t != Tobj)
		return o;
	pp := -1;
	if(p.t == Tobj)
		pp = p.x;
	if(!setproto(o.x, pp))
		typeerr("cannot set prototype");
	return o;
}

object_create(nil: V, a, n: int, nil: V, nil: int): V
{
	p := arg(a, n, 0);
	if(p.t != Tobj && p.t != Tnull)
		typeerr("object prototype may only be an Object or null");
	pp := -1;
	if(p.t == Tobj)
		pp = p.x;
	h := newobj(Kord, pp);
	props := arg(a, n, 1);
	if(props.t != Tundef)
		defineproperties(h, props);
	return objv(h);
}

# ToPropertyDescriptor
todesc(v: V): ref Desc
{
	if(v.t != Tobj)
		typeerr("property description must be an object: " + show(v));
	d := ref Desc(0, undef, undef, undef, 0);
	o := v.x;
	if(hasprop(o, aenumerable)) {
		d.has |= Henum;
		if(truthy(get(o, aenumerable, v)))
			d.attrs |= Aenum;
	}
	if(hasprop(o, aconfigurable)) {
		d.has |= Hconf;
		if(truthy(get(o, aconfigurable, v)))
			d.attrs |= Aconf;
	}
	if(hasprop(o, avalue)) {
		d.has |= Hvalue;
		d.value = get(o, avalue, v);
	}
	if(hasprop(o, awritable)) {
		d.has |= Hwrite;
		if(truthy(get(o, awritable, v)))
			d.attrs |= Awrite;
	}
	if(hasprop(o, aget)) {
		g := get(o, aget, v);
		if(g.t != Tundef && !iscallable(g))
			typeerr("getter must be a function: " + show(g));
		d.has |= Hget;
		d.get = g;
	}
	if(hasprop(o, aset)) {
		s := get(o, aset, v);
		if(s.t != Tundef && !iscallable(s))
			typeerr("setter must be a function: " + show(s));
		d.has |= Hset;
		d.set = s;
	}
	if(isaccdesc(d) && isdatadesc(d))
		typeerr("invalid property descriptor: cannot both specify accessors and a value or writable attribute");
	return d;
}

# FromPropertyDescriptor
fromdesc(d: ref Desc): V
{
	if(d == nil)
		return undef;
	h := newplain();
	if(d.has & Hvalue)
		addprop(h, avalue, Adefault, d.value);
	if(d.has & Hwrite)
		addprop(h, awritable, Adefault, bool(d.attrs & Awrite));
	if(d.has & Hget)
		addprop(h, aget, Adefault, d.get);
	if(d.has & Hset)
		addprop(h, aset, Adefault, d.set);
	if(d.has & Henum)
		addprop(h, aenumerable, Adefault, bool(d.attrs & Aenum));
	if(d.has & Hconf)
		addprop(h, aconfigurable, Adefault, bool(d.attrs & Aconf));
	return objv(h);
}

object_defineproperty(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		typeerr("Object.defineProperty called on non-object");
	k := tokey(arg(a, n, 1));
	d := todesc(arg(a, n, 2));
	if(!defineown(o.x, k, d))
		typeerr("cannot redefine property: " + keystr(k));
	return o;
}

defineproperties(h: int, props: V)
{
	p := toobject(props);
	ks := ownkeys(p);
	descs: list of (int, ref Desc);
	for(i := 0; i < len ks; i++) {
		(found, pd) := getown(p, ks[i]);
		if(found && (pd.attrs & Aenum))
			descs = (ks[i], todesc(get(p, ks[i], objv(p)))) :: descs;
	}
	for(l := revdescs(descs); l != nil; l = tl l) {
		(k, d) := hd l;
		if(!defineown(h, k, d))
			typeerr("cannot redefine property: " + keystr(k));
	}
}

revdescs(l: list of (int, ref Desc)): list of (int, ref Desc)
{
	r: list of (int, ref Desc);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

object_defineproperties(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		typeerr("Object.defineProperties called on non-object");
	defineproperties(o.x, arg(a, n, 1));
	return o;
}

object_getownpropertydescriptor(nil: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(arg(a, n, 0));
	k := tokey(arg(a, n, 1));
	(found, d) := getown(h, k);
	if(!found)
		return undef;
	return fromdesc(d);
}

object_getownpropertydescriptors(nil: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(arg(a, n, 0));
	r := newplain();
	ks := ownkeys(h);
	for(i := 0; i < len ks; i++) {
		if(isprivkey(ks[i]))
			continue;
		(found, d) := getown(h, ks[i]);
		if(found)
			createdata(r, ks[i], fromdesc(d));
	}
	return objv(r);
}

# the own keys of o that are strings (strs) or symbols, as an array
keysarray(h: int, strs: int): int
{
	ks := ownkeys(h);
	r := newarray(0);
	for(i := 0; i < len ks; i++) {
		k := ks[i];
		if(isprivkey(k))
			continue;
		if(issymkey(k) == !strs)
			arrpush(r, keyval(k));
	}
	return r;
}

object_getownpropertynames(nil: V, a, n: int, nil: V, nil: int): V
{
	return objv(keysarray(toobject(arg(a, n, 0)), 1));
}

object_getownpropertysymbols(nil: V, a, n: int, nil: V, nil: int): V
{
	return objv(keysarray(toobject(arg(a, n, 0)), 0));
}

# EnumerableOwnProperties: 0 keys, 1 values, 2 entries
enumown(h: int, kind: int): int
{
	sp0 := sp;
	push(objv(h));
	r := newarray(0);
	push(objv(r));
	ks := ownkeys(h);
	for(i := 0; i < len ks; i++) {
		k := ks[i];
		if(issymkey(k) || isprivkey(k))
			continue;
		(found, d) := getown(h, k);
		if(!found || (d.attrs & Aenum) == 0)
			continue;
		case kind {
		0 =>
			arrpush(r, keyval(k));
		1 =>
			arrpush(r, get(h, k, objv(h)));
		2 =>
			v := get(h, k, objv(h));
			arrpush(r, objv(arrayof(array[] of {keyval(k), v})));
		}
	}
	sp = sp0;
	return r;
}

object_keys(nil: V, a, n: int, nil: V, nil: int): V
{
	return objv(enumown(toobject(arg(a, n, 0)), 0));
}

object_values(nil: V, a, n: int, nil: V, nil: int): V
{
	return objv(enumown(toobject(arg(a, n, 0)), 1));
}

object_entries(nil: V, a, n: int, nil: V, nil: int): V
{
	return objv(enumown(toobject(arg(a, n, 0)), 2));
}

object_assign(nil: V, a, n: int, nil: V, nil: int): V
{
	tobj := toobject(arg(a, n, 0));
	tv := objv(tobj);
	for(i := 1; i < n; i++) {
		src := vs[a+i];
		if(src.t == Tundef || src.t == Tnull)
			continue;
		s := toobject(src);
		ks := ownkeys(s);
		for(j := 0; j < len ks; j++) {
			if(isprivkey(ks[j]))
				continue;
			(found, d) := getown(s, ks[j]);
			if(found && (d.attrs & Aenum))
				setv(tv, ks[j], get(s, ks[j], objv(s)), 1);
		}
	}
	return tv;
}

# SetIntegrityLevel; frozen: else sealed
integrity(h: int, frozen: int): int
{
	if(!preventext(h))
		return 0;
	ks := ownkeys(h);
	for(i := 0; i < len ks; i++) {
		k := ks[i];
		d := ref Desc(Hconf, undef, undef, undef, 0);
		if(frozen) {
			(found, cur) := getown(h, k);
			if(!found)
				continue;
			if(isdatadesc(cur))
				d.has |= Hwrite;
		}
		if(!defineown(h, k, d))
			typeerr("cannot redefine property: " + keystr(k));
	}
	return 1;
}

testintegrity(h: int, frozen: int): int
{
	if(isext(h))
		return 0;
	ks := ownkeys(h);
	for(i := 0; i < len ks; i++) {
		(found, d) := getown(h, ks[i]);
		if(!found)
			continue;
		if(d.attrs & Aconf)
			return 0;
		if(frozen && isdatadesc(d) && (d.attrs & Awrite))
			return 0;
	}
	return 1;
}

object_freeze(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return o;
	if(!integrity(o.x, 1))
		typeerr("cannot freeze");
	return o;
}

object_isfrozen(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return vtrue;
	return bool(testintegrity(o.x, 1));
}

object_seal(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return o;
	if(!integrity(o.x, 0))
		typeerr("cannot seal");
	return o;
}

object_issealed(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return vtrue;
	return bool(testintegrity(o.x, 0));
}

object_preventextensions(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return o;
	if(!preventext(o.x))
		typeerr("cannot prevent extensions");
	return o;
}

object_isextensible(nil: V, a, n: int, nil: V, nil: int): V
{
	o := arg(a, n, 0);
	if(o.t != Tobj)
		return vfalse;
	return bool(isext(o.x));
}

object_is(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(samevalue(arg(a, n, 0), arg(a, n, 1)));
}

object_hasown(nil: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(arg(a, n, 0));
	return bool(hasown(h, tokey(arg(a, n, 1))));
}

object_fromentries(nil: V, a, n: int, nil: V, nil: int): V
{
	it := arg(a, n, 0);
	if(it.t == Tundef || it.t == Tnull)
		typeerr("Object.fromEntries requires an iterable");
	r := newplain();
	sp0 := sp;
	push(objv(r));
	(iter, next) := getiterator(it, 0);
	push(iter);
	push(next);
	for(;;) {
		(e, done) := iterstep(iter, next);
		if(done)
			break;
		{
			if(e.t != Tobj)
				typeerr("iterator value " + show(e) + " is not an entry object");
			k := getv(e, idxkey(0));
			v := getv(e, idxkey(1));
			createdataorthrow(r, tokey(k), v);
		} exception ex {
		"js:throw" =>
			saved := thrown;
			{
				iterclose(iter);
			} exception {
			"js:throw" =>
				;
			}
			thrown = saved;
			raise ex;
		}
	}
	sp = sp0;
	return objv(r);
}

object_groupby(nil: V, a, n: int, nil: V, nil: int): V
{
	items := arg(a, n, 0);
	cb := arg(a, n, 1);
	if(items.t == Tundef || items.t == Tnull)
		typeerr("Object.groupBy called on null or undefined");
	if(!iscallable(cb))
		typeerr(show(cb) + " is not a function");
	r := newobj(Kord, -1);
	sp0 := sp;
	push(objv(r));
	(iter, next) := getiterator(items, 0);
	push(iter);
	push(next);
	k := 0;
	for(;;) {
		(v, done) := iterstep(iter, next);
		if(done)
			break;
		key: int;
		{
			kv := call(cb, undef, array[] of {v, num(real k)});
			key = tokey(kv);
		} exception ex {
		"js:throw" =>
			saved := thrown;
			{
				iterclose(iter);
			} exception {
			"js:throw" =>
				;
			}
			thrown = saved;
			raise ex;
		}
		(ok, g, nil) := getownprop(r, key);
		if(!ok) {
			g = objv(newarray(0));
			addprop(r, key, Adefault, g);
		}
		arrpush(g.x, v);
		k++;
	}
	sp = sp0;
	return objv(r);
}

objproto_hasownproperty(this: V, a, n: int, nil: V, nil: int): V
{
	k := tokey(arg(a, n, 0));
	h := toobject(this);
	return bool(hasown(h, k));
}

objproto_isprototypeof(this: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	if(v.t != Tobj)
		return vfalse;
	h := toobject(this);
	for(p := getproto(v.x); p >= 0; p = getproto(p))
		if(p == h)
			return vtrue;
	return vfalse;
}

objproto_propertyisenumerable(this: V, a, n: int, nil: V, nil: int): V
{
	k := tokey(arg(a, n, 0));
	h := toobject(this);
	(found, d) := getown(h, k);
	return bool(found && (d.attrs & Aenum));
}

objproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	case this.t {
	Tundef => return strv("[object Undefined]");
	Tnull => return strv("[object Null]");
	}
	h := toobject(this);
	builtin := "Object";
	if(isarray(objv(h)))
		builtin = "Array";
	else case okind[h] {
	Kargs => builtin = "Arguments";
	Kfunc or Knative or Kbound => builtin = "Function";
	Kerror => builtin = "Error";
	Kprim =>
		pick d := odata[h] {
		Prim =>
			case d.v.t {
			Tbool => builtin = "Boolean";
			Tnum => builtin = "Number";
			Tstr => builtin = "String";
			}
		}
	Kdate => builtin = "Date";
	Kregexp => builtin = "RegExp";
	}
	if(okind[h] == Kproxy && iscallable(objv(h)))
		builtin = "Function";
	t := get(h, asymtostrtag, objv(h));
	if(t.t == Tstr)
		builtin = str(t.x);
	return strv("[object " + builtin + "]");
}

objproto_tolocalestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return invoke(this, atostring, nil);
}

objproto_valueof(this: V, nil, nil: int, nil: V, nil: int): V
{
	return objv(toobject(this));
}

objproto_definegetter(this: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(this);
	g := arg(a, n, 1);
	if(!iscallable(g))
		typeerr("getter must be a function");
	k := tokey(arg(a, n, 0));
	if(!defineown(h, k, ref Desc(Hget|Henum|Hconf, undef, g, undef, Aenum|Aconf)))
		typeerr("cannot redefine property: " + keystr(k));
	return undef;
}

objproto_definesetter(this: V, a, n: int, nil: V, nil: int): V
{
	h := toobject(this);
	s := arg(a, n, 1);
	if(!iscallable(s))
		typeerr("setter must be a function");
	k := tokey(arg(a, n, 0));
	if(!defineown(h, k, ref Desc(Hset|Henum|Hconf, undef, undef, s, Aenum|Aconf)))
		typeerr("cannot redefine property: " + keystr(k));
	return undef;
}

lookupacc(this: V, kv: V, setter: int): V
{
	h := toobject(this);
	k := tokey(kv);
	for(p := h; p >= 0; p = getproto(p)) {
		(found, d) := getown(p, k);
		if(found) {
			if(isaccdesc(d)) {
				if(setter)
					return d.set;
				return d.get;
			}
			return undef;
		}
	}
	return undef;
}

objproto_lookupgetter(this: V, a, n: int, nil: V, nil: int): V
{
	return lookupacc(this, arg(a, n, 0), 0);
}

objproto_lookupsetter(this: V, a, n: int, nil: V, nil: int): V
{
	return lookupacc(this, arg(a, n, 0), 1);
}

objproto_getproto(this: V, nil, nil: int, nil: V, nil: int): V
{
	h := toobject(this);
	p := getproto(h);
	if(p < 0)
		return null;
	return objv(p);
}

objproto_setproto(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t == Tundef || this.t == Tnull)
		typeerr("Object.prototype.__proto__ called on null or undefined");
	p := arg(a, n, 0);
	if(p.t != Tobj && p.t != Tnull || this.t != Tobj)
		return undef;
	pp := -1;
	if(p.t == Tobj)
		pp = p.x;
	if(!setproto(this.x, pp))
		typeerr("cannot set prototype");
	return undef;
}

# ---- Function ----

functioninit()
{
	ifuncctor = ctor("Function", 1, functionctor, ifuncproto);
	p := ifuncproto;
	method(p, "call", 1, funcproto_call);
	method(p, "apply", 2, funcproto_apply);
	method(p, "bind", 1, funcproto_bind);
	method(p, "toString", 0, funcproto_tostring);
	h := nativefn("[Symbol.hasInstance]", 1, funcproto_hasinstance);
	defown(p, asymhasinst, 0, objv(h));
	thrower := V(Tacc, ithrowtypeerror, real ithrowtypeerror);
	defown(p, intern("caller"), Aacc|Aconf, thrower);
	defown(p, intern("arguments"), Aacc|Aconf, thrower);
}

# new Function(p1, ..., body): kind 0 normal, 1 generator, 2 async, 3 async generator
dynamicfunction(a, n: int, nt: V, kind: int): V
{
	params := "";
	for(i := 0; i < n - 1; i++) {
		if(i > 0)
			params += ",";
		params += tostring(vs[a+i]);
	}
	body := "";
	if(n > 0)
		body = tostring(vs[a+n-1]);
	prefix := "function";
	case kind {
	1 => prefix = "function*";
	2 => prefix = "async function";
	3 => prefix = "async function*";
	}
	src := prefix + " anonymous(" + params + "\n) {\n" + body + "\n}";
	# the parts must each parse on their own
	(nil, perr) := jsparse->parse("(" + prefix + " (" + params + "\n) {})", 0, 0);
	if(perr != nil)
		throwerr(SyntaxError, perr);
	(nil, berr) := jsparse->parse("(" + prefix + " () {\n" + body + "\n})", 0, 0);
	if(berr != nil)
		throwerr(SyntaxError, berr);
	(prog, err) := jsparse->parse("(" + src + ")", 0, 0);
	if(err != nil)
		throwerr(SyntaxError, err);
	pick p := prog {
	Program =>
		c := compilescript(p, "(" + src + ")", 0, 0);
		# the script's one expression is the function: take its template
		if(len c.funcs != 1)
			throwerr(SyntaxError, "invalid function body");
		fc := c.funcs[0];
		fc.src = src;
		fc.name = "anonymous";
		h := closure(fc, -1);
		defown(h, aname, Aconf, strv("anonymous"));
		if(nt.t != Tundef) {
			dflt := ifuncproto;
			case kind {
			1 => dflt = igenfuncproto;
			2 => dflt = iasyncfuncproto;
			3 => dflt = iasyncgenfuncproto;
			}
			oproto[h] = protofromctor(nt, dflt);
		}
		return objv(h);
	}
	return undef;
}

functionctor(nil: V, a, n: int, nt: V, nil: int): V
{
	return dynamicfunction(a, n, nt, 0);
}

funcproto_call(this: V, a, n: int, nil: V, nil: int): V
{
	if(!iscallable(this))
		typeerr("Function.prototype.call called on " + show(this));
	t := arg(a, n, 0);
	if(n > 0)
		return callv(this, t, a + 1, n - 1, undef);
	return callv(this, t, a, 0, undef);
}

funcproto_apply(this: V, a, n: int, nil: V, nil: int): V
{
	if(!iscallable(this))
		typeerr("Function.prototype.apply called on " + show(this));
	t := arg(a, n, 0);
	al := arg(a, n, 1);
	if(al.t == Tundef || al.t == Tnull)
		return callv(this, t, sp, 0, undef);
	args := listfromarraylike(al);
	return call(this, t, args);
}

funcproto_bind(this: V, a, n: int, nil: V, nil: int): V
{
	if(!iscallable(this))
		typeerr("Bind must be called on a function");
	t := arg(a, n, 0);
	args: array of V;
	if(n > 1) {
		args = array[n-1] of V;
		args[0:] = vs[a+1:a+n];
	}
	target := this.x;
	h := newobj(Kbound, getproto(target));
	oflags[h] |= Ocallable | (oflags[target] & Octor);
	odata[h] = ref Data.Bound(target, t, args);
	sp0 := sp;
	push(objv(h));
	l := 0.0;
	if(hasown(target, alength)) {
		tl0 := get(target, alength, this);
		if(tl0.t == Tnum) {
			if(tl0.n == inf)
				l = inf;
			else if(tl0.n != -inf) {
				x := tointorinf(tl0);
				l = x - real len args;
				if(l < 0.0)
					l = 0.0;
			}
		}
	}
	defown(h, alength, Aconf, num(l));
	nm := get(target, aname, this);
	ns := "";
	if(nm.t == Tstr)
		ns = str(nm.x);
	defown(h, aname, Aconf, strv("bound " + ns));
	sp = sp0;
	return objv(h);
}

funcproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t == Tobj) {
		h := this.x;
		case okind[h] {
		Kfunc =>
			pick d := odata[h] {
			Func =>
				if(d.code.src != nil)
					return strv(d.code.src);
			}
			return strv("function () { [native code] }");
		Knative =>
			pick d := odata[h] {
			Native =>
				return strv("function " + d.name + "() { [native code] }");
			}
		Kbound =>
			return strv("function () { [native code] }");
		Kproxy =>
			if(iscallable(this))
				return strv("function () { [native code] }");
		}
	}
	typeerr("Function.prototype.toString requires that 'this' be a Function");
	return undef;
}

funcproto_hasinstance(this: V, a, n: int, nil: V, nil: int): V
{
	return bool(ordinaryhasinstance(this, arg(a, n, 0)));
}

# ---- errors ----

errornames := array[] of {"Error", "EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError", "AggregateError"};

errorinit()
{
	ierrorprotos[Error] = ierrorproto;
	ierrorctors[Error] = ctor("Error", 1, errorctor, ierrorproto);
	value(ierrorproto, "name", strv("Error"));
	value(ierrorproto, "message", strv(""));
	method(ierrorproto, "toString", 0, errproto_tostring);
	for(k := EvalError; k <= AggregateError; k++) {
		p := keep(newobj(Kord, ierrorproto));
		ierrorprotos[k] = p;
		length := 1;
		if(k == AggregateError)
			length = 2;
		c := ctor(errornames[k], length, errorctor, p);
		oproto[c] = ierrorctors[Error];
		ierrorctors[k] = c;
		value(p, "name", strv(errornames[k]));
		value(p, "message", strv(""));
	}
}

errorkind(f: int): int
{
	for(k := 0; k < len ierrorctors; k++)
		if(ierrorctors[k] == f)
			return k;
	return Error;
}

errorctor(nil: V, a, n: int, nt: V, f: int): V
{
	kind := errorkind(f);
	if(nt.t == Tundef)
		nt = objv(f);
	h := newobj(Kerror, protofromctor(nt, ierrorprotos[kind]));
	odata[h] = ref Data.Error(nil);
	sp0 := sp;
	push(objv(h));
	mi := 0;
	if(kind == AggregateError)
		mi = 1;
	msg := arg(a, n, mi);
	if(msg.t != Tundef)
		defown(h, amessage, Awrite|Aconf, tostrv(msg));
	opts := arg(a, n, mi + 1);
	if(opts.t == Tobj && hasprop(opts.x, acause))
		defown(h, acause, Awrite|Aconf, get(opts.x, acause, opts));
	if(kind == AggregateError) {
		errs := newarray(0);
		push(objv(errs));
		(it, next) := getiterator(arg(a, n, 0), 0);
		push(it);
		push(next);
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				break;
			arrpush(errs, v);
		}
		defown(h, aerrors, Awrite|Aconf, objv(errs));
	}
	sp = sp0;
	return objv(h);
}

errproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Error.prototype.toString called on non-object");
	nm := getv(this, aname);
	ns := "Error";
	if(nm.t != Tundef)
		ns = tostring(nm);
	m := getv(this, amessage);
	ms := "";
	if(m.t != Tundef)
		ms = tostring(m);
	if(ns == "")
		return strv(ms);
	if(ms == "")
		return strv(ns);
	return strv(ns + ": " + ms);
}

# ---- Symbol ----

symregistry: list of (string, int);

symbolinit()
{
	isymproto = keep(newobj(Kord, iobjproto));
	c := ctor("Symbol", 0, symbolctor, isymproto);
	oflags[c] &= ~Octor;
	oflags[c] |= Octor;	# (new Symbol throws, but it is a constructor for subclassing)
	wk := array[] of {
		("iterator", asymiterator), ("asyncIterator", asymasynciter), ("hasInstance", asymhasinst),
		("toPrimitive", asymtoprim), ("toStringTag", asymtostrtag), ("species", asymspecies),
		("unscopables", asymunscopables), ("isConcatSpreadable", asymisconcat), ("match", asymmatch),
		("matchAll", asymmatchall), ("replace", asymreplace), ("search", asymsearch), ("split", asymsplit),
	};
	for(i := 0; i < len wk; i++) {
		(nm, a) := wk[i];
		defown(c, intern(nm), 0, V(Tsym, a, 0.0));
	}
	method(c, "for", 1, symbol_for);
	method(c, "keyFor", 1, symbol_keyfor);
	p := isymproto;
	method(p, "toString", 0, symproto_tostring);
	method(p, "valueOf", 0, symproto_valueof);
	getter(p, intern("description"), "description", symproto_description);
	h := nativefn("[Symbol.toPrimitive]", 1, symproto_valueof);
	defown(p, asymtoprim, Aconf, objv(h));
	tag(p, "Symbol");
}

symbolctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t != Tundef)
		typeerr("Symbol is not a constructor");
	d := arg(a, n, 0);
	if(d.t == Tundef)
		return V(Tsym, newsymbol("", 0), 0.0);
	return V(Tsym, newsymbol(tostring(d), 1), 0.0);
}

symbol_for(nil: V, a, n: int, nil: V, nil: int): V
{
	s := tostring(arg(a, n, 0));
	for(l := symregistry; l != nil; l = tl l)
		if((hd l).t0 == s)
			return V(Tsym, (hd l).t1, 0.0);
	sym := newsymbol(s, 1);
	symregistry = (s, sym) :: symregistry;
	return V(Tsym, sym, 0.0);
}

symbol_keyfor(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	if(v.t != Tsym)
		typeerr(show(v) + " is not a symbol");
	for(l := symregistry; l != nil; l = tl l)
		if((hd l).t1 == v.x)
			return strv((hd l).t0);
	return undef;
}

thissym(this: V): V
{
	if(this.t == Tsym)
		return this;
	if(this.t == Tobj && okind[this.x] == Kprim)
		pick d := odata[this.x] {
		Prim =>
			if(d.v.t == Tsym)
				return d.v;
		}
	typeerr("Symbol.prototype method called on incompatible receiver " + show(this));
	return undef;
}

symproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	s := thissym(this);
	return strv("Symbol(" + atomstr[s.x] + ")");
}

symproto_valueof(this: V, nil, nil: int, nil: V, nil: int): V
{
	return thissym(this);
}

symproto_description(this: V, nil, nil: int, nil: V, nil: int): V
{
	s := thissym(this);
	if(atomsh[s.x] < 0)
		return undef;
	return V(Tstr, atomsh[s.x], 0.0);
}

# ---- Boolean ----

primsinit()
{
	iboolproto = keep(newobj(Kprim, iobjproto));
	odata[iboolproto] = ref Data.Prim(vfalse);
	ctor("Boolean", 1, booleanctor, iboolproto);
	method(iboolproto, "toString", 0, boolproto_tostring);
	method(iboolproto, "valueOf", 0, boolproto_valueof);
}

booleanctor(nil: V, a, n: int, nt: V, nil: int): V
{
	b := bool(truthy(arg(a, n, 0)));
	if(nt.t == Tundef)
		return b;
	h := newobj(Kprim, protofromctor(nt, iboolproto));
	odata[h] = ref Data.Prim(b);
	return objv(h);
}

thisprim(this: V, t: int, name: string): V
{
	if(this.t == t)
		return this;
	if(this.t == Tobj && okind[this.x] == Kprim)
		pick d := odata[this.x] {
		Prim =>
			if(d.v.t == t)
				return d.v;
		}
	typeerr(name + " called on incompatible receiver " + show(this));
	return undef;
}

boolproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	b := thisprim(this, Tbool, "Boolean.prototype.toString");
	if(b.x)
		return strv("true");
	return strv("false");
}

boolproto_valueof(this: V, nil, nil: int, nil: V, nil: int): V
{
	return thisprim(this, Tbool, "Boolean.prototype.valueOf");
}

# ---- global functions ----

globalfnsinit()
{
	g := iglobal;
	ievalfn = keep(method(g, "eval", 1, global_eval));
	method(g, "isNaN", 1, global_isnan);
	method(g, "isFinite", 1, global_isfinite);
	method(g, "parseFloat", 1, global_parsefloat);
	method(g, "parseInt", 2, global_parseint);
	method(g, "print", 1, global_print);
	method(g, "encodeURIComponent", 1, global_encodeuricomponent);
	method(g, "encodeURI", 1, global_encodeuri);
	method(g, "decodeURIComponent", 1, global_decodeuricomponent);
	method(g, "decodeURI", 1, global_decodeuri);
	method(g, "escape", 1, global_escape);
	method(g, "unescape", 1, global_unescape);
}

global_eval(nil: V, a, n: int, nil: V, nil: int): V
{
	return indirecteval(arg(a, n, 0));
}

global_isnan(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(isnan(tonumber(arg(a, n, 0))));
}

global_isfinite(nil: V, a, n: int, nil: V, nil: int): V
{
	x := tonumber(arg(a, n, 0));
	return bool(!isnan(x) && x != inf && x != -inf);
}

global_parsefloat(nil: V, a, n: int, nil: V, nil: int): V
{
	s := trimws(tostring(arg(a, n, 0)), 1, 0);
	i := 0;
	if(i < len s && (s[i] == '+' || s[i] == '-'))
		i++;
	if(len s - i >= 8 && s[i:i+8] == "Infinity") {
		if(s[0] == '-')
			return num(-inf);
		return num(inf);
	}
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
		return num(nan);
	if(i < len s && (s[i] == 'e' || s[i] == 'E')) {
		j := i + 1;
		if(j < len s && (s[j] == '+' || s[j] == '-'))
			j++;
		if(j < len s && s[j] >= '0' && s[j] <= '9') {
			while(j < len s && s[j] >= '0' && s[j] <= '9')
				j++;
			i = j;
		}
	}
	st = 0;
	return num(decimal(s[0:i]));
}

global_parseint(nil: V, a, n: int, nil: V, nil: int): V
{
	s := trimws(tostring(arg(a, n, 0)), 1, 0);
	r := toint32(arg(a, n, 1));
	neg := 0;
	i := 0;
	if(i < len s && (s[i] == '+' || s[i] == '-')) {
		neg = s[i] == '-';
		i++;
	}
	strip := 1;
	if(r != 0) {
		if(r < 2 || r > 36)
			return num(nan);
		if(r != 16)
			strip = 0;
	} else
		r = 10;
	if(strip && i + 1 < len s && s[i] == '0' && (s[i+1] == 'x' || s[i+1] == 'X')) {
		i += 2;
		r = 16;
	}
	st := i;
	v := 0.0;
	while(i < len s) {
		d := digitval(s[i]);
		if(d < 0 || d >= r)
			break;
		i++;
	}
	if(i == st)
		return num(nan);
	digits := s[st:i];
	if(r == 10 && len digits > 15)
		v = decimal(digits);
	else
		for(j := 0; j < len digits; j++)
			v = v * real r + real digitval(digits[j]);
	if(neg)
		v = -v;
	return num(v);
}

global_print(nil: V, a, n: int, nil: V, nil: int): V
{
	s := "";
	for(i := 0; i < n; i++) {
		if(i > 0)
			s += " ";
		s += tostring(vs[a+i]);
	}
	emitout(s);
	return undef;
}

# URI coding (§19.2.6)
uriunreserved := "-_.!~*'()";
urireserved := ";/?:@&=+$,";

uriencode(s: string, keep: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < 128 && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strchr(uriunreserved, c) || strchr(keep, c))) {
			r[len r] = c;
			continue;
		}
		cp := c;
		if(c >= 16rDC00 && c <= 16rDFFF)
			throwerr(URIError, "URI malformed");
		if(c >= 16rD800 && c <= 16rDBFF) {
			if(i + 1 >= len s || s[i+1] < 16rDC00 || s[i+1] > 16rDFFF)
				throwerr(URIError, "URI malformed");
			cp = 16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00);
			i++;
		}
		b := utf8(cp);
		for(j := 0; j < len b; j++)
			r += sys->sprint("%%%.2X", int b[j]);
	}
	return r;
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

utf8(cp: int): array of byte
{
	if(cp < 16r80)
		return array[] of {byte cp};
	if(cp < 16r800)
		return array[] of {byte (16rC0 | cp >> 6), byte (16r80 | cp & 16r3F)};
	if(cp < 16r10000)
		return array[] of {byte (16rE0 | cp >> 12), byte (16r80 | (cp >> 6) & 16r3F), byte (16r80 | cp & 16r3F)};
	return array[] of {byte (16rF0 | cp >> 18), byte (16r80 | (cp >> 12) & 16r3F), byte (16r80 | (cp >> 6) & 16r3F), byte (16r80 | cp & 16r3F)};
}

uridecode(s: string, reserved: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c != '%') {
			r[len r] = c;
			continue;
		}
		st := i;
		if(i + 2 >= len s || hexv(s[i+1]) < 0 || hexv(s[i+2]) < 0)
			throwerr(URIError, "URI malformed");
		b := hexv(s[i+1]) * 16 + hexv(s[i+2]);
		i += 2;
		if(b < 16r80) {
			if(strchr(reserved, b))
				r += s[st:i+1];
			else
				r[len r] = b;
			continue;
		}
		need := 0;
		cp := 0;
		min := 0;
		if((b & 16rE0) == 16rC0) {
			need = 1;
			cp = b & 16r1F;
			min = 16r80;
		} else if((b & 16rF0) == 16rE0) {
			need = 2;
			cp = b & 16r0F;
			min = 16r800;
		} else if((b & 16rF8) == 16rF0) {
			need = 3;
			cp = b & 16r07;
			min = 16r10000;
		} else
			throwerr(URIError, "URI malformed");
		for(k := 0; k < need; k++) {
			if(i + 3 > len s - 0 || s[i+1] != '%' || i + 3 >= len s + 1)
				throwerr(URIError, "URI malformed");
			if(i + 3 > len s - 1 + 1 || hexv(s[i+2]) < 0 || hexv(s[i+3]) < 0)
				throwerr(URIError, "URI malformed");
			x := hexv(s[i+2]) * 16 + hexv(s[i+3]);
			if((x & 16rC0) != 16r80)
				throwerr(URIError, "URI malformed");
			cp = (cp << 6) | (x & 16r3F);
			i += 3;
		}
		if(cp < min || cp > 16r10FFFF || cp >= 16rD800 && cp <= 16rDFFF)
			throwerr(URIError, "URI malformed");
		r = jslexputcp(r, cp);
	}
	return r;
}

jslexputcp(s: string, c: int): string
{
	if(c > 16rFFFF) {
		c -= 16r10000;
		s[len s] = 16rD800 + (c >> 10);
		s[len s] = 16rDC00 + (c & 16r3FF);
	} else
		s[len s] = c;
	return s;
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

global_encodeuricomponent(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(uriencode(tostring(arg(a, n, 0)), ""));
}

global_encodeuri(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(uriencode(tostring(arg(a, n, 0)), urireserved + "#"));
}

global_decodeuricomponent(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(uridecode(tostring(arg(a, n, 0)), ""));
}

global_decodeuri(nil: V, a, n: int, nil: V, nil: int): V
{
	return strv(uridecode(tostring(arg(a, n, 0)), urireserved + "#"));
}

global_escape(nil: V, a, n: int, nil: V, nil: int): V
{
	s := tostring(arg(a, n, 0));
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < 128 && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strchr("@*_+-./", c)))
			r[len r] = c;
		else if(c < 256)
			r += sys->sprint("%%%.2X", c);
		else
			r += sys->sprint("%%u%.4X", c);
	}
	return strv(r);
}

global_unescape(nil: V, a, n: int, nil: V, nil: int): V
{
	s := tostring(arg(a, n, 0));
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '%') {
			if(i + 5 < len s && s[i+1] == 'u' && hexv(s[i+2]) >= 0 && hexv(s[i+3]) >= 0 && hexv(s[i+4]) >= 0 && hexv(s[i+5]) >= 0) {
				r[len r] = hexv(s[i+2]) << 12 | hexv(s[i+3]) << 8 | hexv(s[i+4]) << 4 | hexv(s[i+5]);
				i += 5;
				continue;
			}
			if(i + 2 < len s && hexv(s[i+1]) >= 0 && hexv(s[i+2]) >= 0) {
				r[len r] = hexv(s[i+1]) << 4 | hexv(s[i+2]);
				i += 2;
				continue;
			}
		}
		r[len r] = c;
	}
	return strv(r);
}
