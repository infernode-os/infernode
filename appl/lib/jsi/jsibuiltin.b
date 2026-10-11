#
# jsibuiltin.b - the realm: its intrinsics, built-in functions' plumbing,
# and Object, Function, Symbol, Boolean, the errors and the global
# functions.
#
# A built-in function is an object whose Fn has a native id; calling it
# comes to callnative, which hands it to the file that implements its
# range of ids.
#

# property keys the engine uses itself
a_length, a_name, a_prototype, a_constructor, a_message, a_valueOf, a_toString, a_next,
a_done, a_value, a_return, a_throw, a_then, a_callee, a_raw, a_get, a_set, a_writable,
a_enumerable, a_configurable, a_cause, a_errors, a_index, a_input, a_groups, a_lastIndex,
a_join, a_caller, a_arguments, a_values, a_indices, a_source, a_flags, a_proto,
a_toJSON, a_exec, a_global, a_unicode, a_sticky, a_multiline, a_ignoreCase, a_dotAll,
a_hasIndices, a_unicodeSets, a_size, a_has, a_add, a_delete, a_keys, a_entries,
a_toISOString, a_stack, a_resolve, a_reject, a_status, a_reason, a_default, a_description,
a_symiterator, a_symasynciterator, a_symtoprim, a_syminstanceof, a_symspecies,
a_symunscopables, a_symtostringtag, a_symisconcatspreadable, a_symmatch, a_symmatchall,
a_symreplace, a_symsearch, a_symsplit, a_symdispose, a_symasyncdispose, a_clear,
a_forEach, a_dispose, a_error, a_suppressed: int;

wellknown: list of (string, ref Obj);	# Symbol.iterator and the rest

atomsinit()
{
	a_length = intern("length");
	a_name = intern("name");
	a_prototype = intern("prototype");
	a_constructor = intern("constructor");
	a_message = intern("message");
	a_valueOf = intern("valueOf");
	a_toString = intern("toString");
	a_next = intern("next");
	a_done = intern("done");
	a_value = intern("value");
	a_return = intern("return");
	a_throw = intern("throw");
	a_then = intern("then");
	a_callee = intern("callee");
	a_raw = intern("raw");
	a_get = intern("get");
	a_set = intern("set");
	a_writable = intern("writable");
	a_enumerable = intern("enumerable");
	a_configurable = intern("configurable");
	a_cause = intern("cause");
	a_errors = intern("errors");
	a_index = intern("index");
	a_input = intern("input");
	a_groups = intern("groups");
	a_lastIndex = intern("lastIndex");
	a_join = intern("join");
	a_caller = intern("caller");
	a_arguments = intern("arguments");
	a_values = intern("values");
	a_indices = intern("indices");
	a_source = intern("source");
	a_flags = intern("flags");
	a_proto = intern("__proto__");
	a_toJSON = intern("toJSON");
	a_exec = intern("exec");
	a_global = intern("global");
	a_unicode = intern("unicode");
	a_sticky = intern("sticky");
	a_multiline = intern("multiline");
	a_ignoreCase = intern("ignoreCase");
	a_dotAll = intern("dotAll");
	a_hasIndices = intern("hasIndices");
	a_unicodeSets = intern("unicodeSets");
	a_size = intern("size");
	a_has = intern("has");
	a_add = intern("add");
	a_delete = intern("delete");
	a_keys = intern("keys");
	a_entries = intern("entries");
	a_toISOString = intern("toISOString");
	a_stack = intern("stack");
	a_resolve = intern("resolve");
	a_reject = intern("reject");
	a_status = intern("status");
	a_reason = intern("reason");
	a_default = intern("default");
	a_description = intern("description");
	a_clear = intern("clear");
	a_forEach = intern("forEach");
	a_dispose = intern("dispose");
	a_error = intern("error");
	a_suppressed = intern("suppressed");
	wellknown = nil;
	a_symiterator = wksym("iterator");
	a_symasynciterator = wksym("asyncIterator");
	a_symtoprim = wksym("toPrimitive");
	a_syminstanceof = wksym("hasInstance");
	a_symspecies = wksym("species");
	a_symunscopables = wksym("unscopables");
	a_symtostringtag = wksym("toStringTag");
	a_symisconcatspreadable = wksym("isConcatSpreadable");
	a_symmatch = wksym("match");
	a_symmatchall = wksym("matchAll");
	a_symreplace = wksym("replace");
	a_symsearch = wksym("search");
	a_symsplit = wksym("split");
	a_symdispose = wksym("dispose");
	a_symasyncdispose = wksym("asyncDispose");
}

wksym(name: string): int
{
	o := newsym("Symbol." + name, 1);
	wellknown = (name, o) :: wellknown;
	return symatom(o);
}

# ---- the intrinsics ----

objproto, funcproto, arrproto, strproto, numproto, boolproto, symproto, bigproto: ref Obj;
errproto: ref Obj;
errprotos: array of ref Obj;
genfuncproto, asyncfuncproto, asyncgenfuncproto, genproto, asyncgenproto: ref Obj;
iterproto, asynciterproto, arrayiterproto, asyncfromsyncproto: ref Obj;
promiseproto, regexpproto, dateproto, mapproto, setprotoobj, weakmapproto, weaksetproto: ref Obj;
throwerfn, evalfn: ref Obj;
objectctor, functionctor, arrayctor: ref Obj;
symregistry: ref Hmap;

# a built-in function
mknative(id: int, name: string, nargs: int): ref Obj
{
	o := ref Obj;
	o.cls = Cfunc;
	o.sh = emptyshape(funcproto);
	o.flags = Fext;
	o.fun = ref Fn(nil, id, nargs);
	o.slots = array[2] of V;
	o.sh = addkey(addkey(o.sh, a_length, Aconf), a_name, Aconf);
	o.slots[0] = intv(nargs);
	o.slots[1] = strv(name);
	return o;
}

# a method of o
defmethod(o: ref Obj, name: string, id, nargs: int): ref Obj
{
	f := mknative(id, name, nargs);
	defprop(o, intern(name), objv(f), Awrite|Aconf);
	return f;
}

defsymmethod(o: ref Obj, k: int, name: string, id, nargs: int): ref Obj
{
	f := mknative(id, name, nargs);
	defprop(o, k, objv(f), Awrite|Aconf);
	return f;
}

defval(o: ref Obj, name: string, v: V, attrs: int)
{
	defprop(o, intern(name), v, attrs);
}

# an accessor property of built-in getter (and setter) functions
defaccessor(o: ref Obj, k: int, name: string, getid, setid: int)
{
	g, s: ref Obj;
	if(getid > 0)
		g = mknative(getid, "get " + name, 0);
	if(setid > 0)
		s = mknative(setid, "set " + name, 1);
	defineown(o, k, ref Desc(Dget|Dset|Denum|Dconf, undef, Aconf, g, s));
}

defgetter(o: ref Obj, name: string, id: int)
{
	defaccessor(o, intern(name), name, id, 0);
}

# a constructor and its prototype object, put in the global object
defctor(name: string, id, nargs: int, proto: ref Obj): ref Obj
{
	c := mknative(id, name, nargs);
	c.flags |= Fctor;
	if(proto != nil) {
		defprop(c, a_prototype, objv(proto), 0);
		defprop(proto, a_constructor, objv(c), Awrite|Aconf);
	}
	defprop(global, intern(name), objv(c), Awrite|Aconf);
	return c;
}

realminit()
{
	objproto = ref Obj;
	objproto.cls = Cplain;
	objproto.sh = rootshape;
	objproto.flags = Fext;
	emptyshape(objproto);
	funcproto = ref Obj;
	funcproto.cls = Cfunc;
	funcproto.sh = emptyshape(objproto);
	funcproto.flags = Fext;
	funcproto.fun = ref Fn(nil, Nnoop, 0);
	addprop(funcproto, a_length, Aconf, intv(0));
	addprop(funcproto, a_name, Aconf, strv(""));
	global = newobj(Cplain, objproto);
	globalthis = objv(global);
	dictify(global);

	arrproto = newobj(Carray, objproto);
	arrproto.alen = 0;
	strproto = wrap(Cstr, objproto, strv(""));
	numproto = wrap(Cnum, objproto, intv(0));
	boolproto = wrap(Cbool, objproto, falsev);
	symproto = newobj(Cplain, objproto);
	bigproto = newobj(Cplain, objproto);
	errproto = newobj(Cplain, objproto);
	iterproto = newobj(Cplain, objproto);
	asynciterproto = newobj(Cplain, objproto);
	genproto = newobj(Cplain, iterproto);
	asyncgenproto = newobj(Cplain, asynciterproto);
	genfuncproto = newobj(Cplain, funcproto);
	asyncfuncproto = newobj(Cplain, funcproto);
	asyncgenfuncproto = newobj(Cplain, funcproto);
	arrayiterproto = newobj(Cplain, iterproto);
	asyncfromsyncproto = newobj(Cplain, asynciterproto);
	promiseproto = newobj(Cplain, objproto);
	regexpproto = newobj(Cplain, objproto);
	dateproto = newobj(Cplain, objproto);
	mapproto = newobj(Cplain, objproto);
	setprotoobj = newobj(Cplain, objproto);
	weakmapproto = newobj(Cplain, objproto);
	weaksetproto = newobj(Cplain, objproto);
	symregistry = newhmap();

	throwerfn = mknative(Nthrower, "", 0);
	preventext(throwerfn);
	s := slotof(throwerfn.sh, a_length);
	setattrs(throwerfn, s, 0);
	s = slotof(throwerfn.sh, a_name);
	setattrs(throwerfn, s, 0);
	throwerfn.flags &= ~Fext;

	coreinit();
	arrayinit();
	stringinit();
	numberinit();
	mathinit();
	jsoninit();
	collinit();
	promiseinit();
	reflectinit();
	iterinit();
	regexpinit();
	dateinit();
	typedinit();
	biginit();
	disposeinit();
	globalfnsinit();
}

coreinit()
{
	# Object
	objectctor = defctor("Object", NObject, 1, objproto);
	o := objectctor;
	defmethod(o, "assign", NOassign, 2);
	defmethod(o, "create", NOcreate, 2);
	defmethod(o, "defineProperties", NOdefprops, 2);
	defmethod(o, "defineProperty", NOdefprop, 3);
	defmethod(o, "entries", NOentries, 1);
	defmethod(o, "freeze", NOfreeze, 1);
	defmethod(o, "fromEntries", NOfromentries, 1);
	defmethod(o, "getOwnPropertyDescriptor", NOgopd, 2);
	defmethod(o, "getOwnPropertyDescriptors", NOgopds, 1);
	defmethod(o, "getOwnPropertyNames", NOgopn, 1);
	defmethod(o, "getOwnPropertySymbols", NOgops, 1);
	defmethod(o, "getPrototypeOf", NOgetproto, 1);
	defmethod(o, "groupBy", NOgroupby, 2);
	defmethod(o, "hasOwn", NOhasown, 2);
	defmethod(o, "is", NOis, 2);
	defmethod(o, "isExtensible", NOisext, 1);
	defmethod(o, "isFrozen", NOisfrozen, 1);
	defmethod(o, "isSealed", NOissealed, 1);
	defmethod(o, "keys", NOkeys, 1);
	defmethod(o, "preventExtensions", NOprevent, 1);
	defmethod(o, "seal", NOseal, 1);
	defmethod(o, "setPrototypeOf", NOsetproto, 2);
	defmethod(o, "values", NOvalues, 1);
	p := objproto;
	defmethod(p, "hasOwnProperty", NOPhasown, 1);
	defmethod(p, "isPrototypeOf", NOPisproto, 1);
	defmethod(p, "propertyIsEnumerable", NOPpropenum, 1);
	defmethod(p, "toLocaleString", NOPtolocale, 0);
	defmethod(p, "toString", NOPtostring, 0);
	defmethod(p, "valueOf", NOPvalueof, 0);
	defmethod(p, "__defineGetter__", NOPdefget, 2);
	defmethod(p, "__defineSetter__", NOPdefset, 2);
	defmethod(p, "__lookupGetter__", NOPlookget, 1);
	defmethod(p, "__lookupSetter__", NOPlookset, 1);
	defaccessor(p, a_proto, "__proto__", NOPgetproto, NOPsetproto);

	# Function
	functionctor = defctor("Function", NFunction, 1, funcproto);
	defmethod(funcproto, "apply", NFapply, 2);
	defmethod(funcproto, "bind", NFbind, 1);
	defmethod(funcproto, "call", NFcall, 1);
	defmethod(funcproto, "toString", NFtostring, 0);
	hi := defsymmethod(funcproto, a_syminstanceof, "[Symbol.hasInstance]", NFhasinstance, 1);
	setattrs(funcproto, slotof(funcproto.sh, a_syminstanceof), 0);
	hi = hi;
	defaccessor(funcproto, a_caller, "caller", Nthrower, Nthrower);
	defaccessor(funcproto, a_arguments, "arguments", Nthrower, Nthrower);
	# the throwers are one function
	for(k := 0; k < 2; k++) {
		kk := a_caller;
		if(k)
			kk = a_arguments;
		s := slotof(funcproto.sh, kk);
		funcproto.slots[s] = objv(newacc(throwerfn, throwerfn));
	}

	# generator and async function constructors
	gf := mknative(NGeneratorFunction, "GeneratorFunction", 1);
	gf.flags |= Fctor;
	setproto(gf, functionctor);
	defprop(gf, a_prototype, objv(genfuncproto), 0);
	defprop(genfuncproto, a_constructor, objv(gf), Aconf);
	defprop(genfuncproto, a_prototype, objv(genproto), Aconf);
	defprop(genfuncproto, a_symtostringtag, strv("GeneratorFunction"), Aconf);
	defprop(genproto, a_constructor, objv(genfuncproto), Aconf);
	defmethod(genproto, "next", NGnext, 1);
	defmethod(genproto, "return", NGreturn, 1);
	defmethod(genproto, "throw", NGthrow, 1);
	defprop(genproto, a_symtostringtag, strv("Generator"), Aconf);

	af := mknative(NAsyncFunction, "AsyncFunction", 1);
	af.flags |= Fctor;
	setproto(af, functionctor);
	defprop(af, a_prototype, objv(asyncfuncproto), 0);
	defprop(asyncfuncproto, a_constructor, objv(af), Aconf);
	defprop(asyncfuncproto, a_symtostringtag, strv("AsyncFunction"), Aconf);

	agf := mknative(NAsyncGeneratorFunction, "AsyncGeneratorFunction", 1);
	agf.flags |= Fctor;
	setproto(agf, functionctor);
	defprop(agf, a_prototype, objv(asyncgenfuncproto), 0);
	defprop(asyncgenfuncproto, a_constructor, objv(agf), Aconf);
	defprop(asyncgenfuncproto, a_prototype, objv(asyncgenproto), Aconf);
	defprop(asyncgenfuncproto, a_symtostringtag, strv("AsyncGeneratorFunction"), Aconf);
	defprop(asyncgenproto, a_constructor, objv(asyncgenfuncproto), Aconf);
	defmethod(asyncgenproto, "next", NAGnext, 1);
	defmethod(asyncgenproto, "return", NAGreturn, 1);
	defmethod(asyncgenproto, "throw", NAGthrow, 1);
	defprop(asyncgenproto, a_symtostringtag, strv("AsyncGenerator"), Aconf);
	defsymmethod(asynciterproto, a_symasynciterator, "[Symbol.asyncIterator]", NIterself, 0);
	defmethod(asyncfromsyncproto, "next", NAFSnext, 1);
	defmethod(asyncfromsyncproto, "return", NAFSreturn, 1);
	defmethod(asyncfromsyncproto, "throw", NAFSthrow, 1);

	# Symbol
	sc := defctor("Symbol", NSymbol, 0, symproto);
	defmethod(sc, "for", NSfor, 1);
	defmethod(sc, "keyFor", NSkeyfor, 1);
	for(l := wellknown; l != nil; l = tl l) {
		(name, so) := hd l;
		defval(sc, name, V(Tsym, 0, 0.0, nil, so), 0);
	}
	defmethod(symproto, "toString", NSyPtostring, 0);
	defmethod(symproto, "valueOf", NSyPvalueof, 0);
	defgetter(symproto, "description", NSyPdescription);
	defprop(symproto, a_symtostringtag, strv("Symbol"), Aconf);
	tp := defsymmethod(symproto, a_symtoprim, "[Symbol.toPrimitive]", NSyPvalueof, 1);
	setattrs(symproto, slotof(symproto.sh, a_symtoprim), Aconf);
	tp = tp;

	# Boolean
	defctor("Boolean", NBoolean, 1, boolproto);
	defmethod(boolproto, "toString", NBPtostring, 0);
	defmethod(boolproto, "valueOf", NBPvalueof, 0);

	# the errors
	errprotos = array[len errnames] of ref Obj;
	errprotos[EError] = errproto;
	ec := defctor("Error", NError, 1, errproto);
	defval(errproto, "name", strv("Error"), Awrite|Aconf);
	defval(errproto, "message", strv(""), Awrite|Aconf);
	defmethod(errproto, "toString", NErrtostring, 0);
	defmethod(ec, "captureStackTrace", NErrcapture, 1);
	defmethod(ec, "isError", NErriserror, 1);
	for(i := 1; i < len errnames; i++) {
		p = newobj(Cplain, errproto);
		errprotos[i] = p;
		nargs := 1;
		if(i == EAggregate)
			nargs = 2;
		c := defctor(errnames[i], NError + i, nargs, p);
		setproto(c, ec);
		defval(p, "name", strv(errnames[i]), Awrite|Aconf);
		defval(p, "message", strv(""), Awrite|Aconf);
	}
}

globalfnsinit()
{
	g := global;
	defval(g, "globalThis", globalthis, Awrite|Aconf);
	defval(g, "NaN", V(Tnum, 0, nan, nil, nil), 0);
	defval(g, "Infinity", V(Tnum, 0, inf, nil, nil), 0);
	defval(g, "undefined", undef, 0);
	evalfn = defmethod(g, "eval", Nevalfn, 1);
	defmethod(g, "isFinite", NisFinite, 1);
	defmethod(g, "isNaN", NisNaN, 1);
	pf := defmethod(g, "parseFloat", NparseFloat, 1);
	pi := defmethod(g, "parseInt", NparseInt, 2);
	defmethod(g, "decodeURI", NdecodeURI, 1);
	defmethod(g, "decodeURIComponent", NdecodeURIComponent, 1);
	defmethod(g, "encodeURI", NencodeURI, 1);
	defmethod(g, "encodeURIComponent", NencodeURIComponent, 1);
	defmethod(g, "escape", Nescape, 1);
	defmethod(g, "unescape", Nunescape, 1);
	defmethod(g, "print", Nprint, 1);
	# Number.parseFloat and parseInt are the same functions
	nc := getv(g, intern("Number"));
	if(nc.t == Tobj) {
		defprop(nc.o, intern("parseFloat"), objv(pf), Awrite|Aconf);
		defprop(nc.o, intern("parseInt"), objv(pi), Awrite|Aconf);
	}
	console := plainobj();
	defmethod(console, "log", Nconsolelog, 0);
	defmethod(console, "info", Nconsolelog, 0);
	defmethod(console, "warn", Nconsolelog, 0);
	defmethod(console, "error", Nconsolelog, 0);
	defmethod(console, "debug", Nconsolelog, 0);
	defval(g, "console", objv(console), Awrite|Aconf);
}

# ---- native ids ----

Nnoop, Nthrower, NObject, NOassign, NOcreate, NOdefprops, NOdefprop, NOentries, NOfreeze,
NOfromentries, NOgopd, NOgopds, NOgopn, NOgops, NOgetproto, NOgroupby, NOhasown, NOis, NOisext,
NOisfrozen, NOissealed, NOkeys, NOprevent, NOseal, NOsetproto, NOvalues, NOPhasown, NOPisproto,
NOPpropenum, NOPtolocale, NOPtostring, NOPvalueof, NOPdefget, NOPdefset, NOPlookget, NOPlookset,
NOPgetproto, NOPsetproto, NFunction, NFapply, NFbind, NFcall, NFtostring, NFhasinstance,
NGeneratorFunction, NAsyncFunction, NAsyncGeneratorFunction, NGnext, NGreturn, NGthrow,
NAGnext, NAGreturn, NAGthrow, NAFSnext, NAFSreturn, NAFSthrow, NIterself, NSymbol, NSfor, NSkeyfor, NSyPtostring,
NSyPvalueof, NSyPdescription, NBoolean, NBPtostring, NBPvalueof, NErrtostring, NErrcapture, NErriserror,
Nevalfn, NisFinite, NisNaN, NparseFloat, NparseInt, NdecodeURI, NdecodeURIComponent,
NencodeURI, NencodeURIComponent, Nescape, Nunescape, Nprint, Nconsolelog, Nbound,
Npromisecapexec, Npromiseresolvefn, Npxcall, Nhostfn, Nmemstat, Nimportjob, NError, Ncorelast: con 1 + iota;
# NError .. NError+7 are the error constructors
Ncoreend: con NError + 8;

callnative(f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	id := f.fun.native;
	if(id < Ncoreend)
		return natcore(id, f, this, args, nt);
	if(id < Nstrbase)
		return natarray(id, f, this, args, nt);
	if(id < Nnumbase)
		return natstring(id, f, this, args, nt);
	if(id < Nmathbase)
		return natnumber(id, f, this, args, nt);
	if(id < Njsonbase)
		return natmath(id, this, args);
	if(id < Ncollbase)
		return natjson(id, f, this, args, nt);
	if(id < Npromisebase)
		return natcoll(id, f, this, args, nt);
	if(id < Nreflectbase)
		return natpromise(id, f, this, args, nt);
	if(id < Niterbase)
		return natreflect(id, f, this, args, nt);
	if(id < Nregexpbase)
		return natiter(id, f, this, args, nt);
	if(id < Ndatebase)
		return natregexp(id, f, this, args, nt);
	if(id < Ntypedbase)
		return natdate(id, f, this, args, nt);
	if(id < Nbigbase)
		return nattyped(id, f, this, args, nt);
	if(id < Ndisposebase)
		return natbig(id, f, this, args, nt);
	if(id >= N262evalscript)
		return nat262(id, args);
	return natdispose(id, f, this, args, nt);
}

Nstrbase: con 200;
Nnumbase: con 300;
Nmathbase: con 350;
Njsonbase: con 400;
Ncollbase: con 420;
Npromisebase: con 480;
Nreflectbase: con 510;
Niterbase: con 540;
Nregexpbase: con 600;
Ndatebase: con 650;
Ntypedbase: con 750;
Nbigbase: con 850;
Ndisposebase: con 880;

natcore(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	Nnoop =>
		return undef;
	Nthrower =>
		# f.caller and f.arguments of a sloppy function: null, as browsers have it
		if(this.t == Tobj && this.o.fun != nil && this.o.fun.code != nil &&
		   (this.o.fun.code.flags & (Cstrict|Carrow|Cmethod|Cgen|Casync|Cclassctor)) == 0)
			return nullv;
		throwtype("'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
	NObject =>
		if(nt != nil && nt != f)
			return objv(fromctor(nt, objproto, Cplain));
		v := arg(args, 0);
		if(v.t == Tundef || v.t == Tnull)
			return objv(plainobj());
		return objv(toobj(v));
	NOassign =>
		dst := toobj(arg(args, 0));
		for(i := 1; i < len args; i++) {
			if(args[i].t == Tundef || args[i].t == Tnull)
				continue;
			src := toobj(args[i]);
			keys := ownkeys(src);
			for(j := 0; j < len keys; j++) {
				k := keys[j];
				d := getowndesc(src, k);
				if(d == nil || (d.attrs & Aenum) == 0)
					continue;
				v := get(src, k, objv(src));
				if(!put(dst, k, v, objv(dst)))
					throwtype("Cannot assign to read only property '" + keyname(k) + "' of object");
			}
		}
		return objv(dst);
	NOcreate =>
		p := arg(args, 0);
		if(p.t != Tobj && p.t != Tnull)
			throwtype("Object prototype may only be an Object or null: " + showv(p));
		o := newobj(Cplain, p.o);
		if(len args > 1 && args[1].t != Tundef)
			defprops(o, args[1]);
		return objv(o);
	NOdefprops =>
		o := arg(args, 0);
		if(o.t != Tobj)
			throwtype("Object.defineProperties called on non-object");
		defprops(o.o, arg(args, 1));
		return o;
	NOdefprop =>
		o := arg(args, 0);
		if(o.t != Tobj)
			throwtype("Object.defineProperty called on non-object");
		k := tokey(arg(args, 1));
		d := todescriptor(arg(args, 2));
		defineorthrow(o.o, k, d);
		return o;
	NOentries or NOkeys or NOvalues =>
		o := toobj(arg(args, 0));
		keys := ownkeys(o);
		r := newarray(0);
		for(i := 0; i < len keys; i++) {
			k := keys[i];
			if(atomsym[k] != nil)
				continue;
			d := getowndesc(o, k);
			if(d == nil || (d.attrs & Aenum) == 0)
				continue;
			case id {
			NOkeys =>
				apush(r, strv(atomstr[k]));
			NOvalues =>
				apush(r, get(o, k, objv(o)));
			* =>
				apush(r, objv(mkarray(array[] of {strv(atomstr[k]), get(o, k, objv(o))})));
			}
		}
		return objv(r);
	NOfreeze or NOseal =>
		o := arg(args, 0);
		if(o.t != Tobj)
			return o;
		if(!setintegrity(o.o, id == NOfreeze))
			throwtype("Cannot freeze");
		return o;
	NOfromentries =>
		it := arg(args, 0);
		if(it.t == Tundef || it.t == Tnull)
			throwtype(showv(it) + " is not iterable");
		o := plainobj();
		iterate(it, NOfromentries, o, nil);
		return objv(o);
	NOgopd =>
		o := toobj(arg(args, 0));
		k := tokey(arg(args, 1));
		d := getowndesc(o, k);
		if(d == nil)
			return undef;
		return objv(fromdesc(d));
	NOgopds =>
		o := toobj(arg(args, 0));
		keys := ownkeys(o);
		r := plainobj();
		for(i := 0; i < len keys; i++) {
			d := getowndesc(o, keys[i]);
			if(d != nil)
				createdata(r, keys[i], objv(fromdesc(d)));
		}
		return objv(r);
	NOgopn or NOgops =>
		o := toobj(arg(args, 0));
		keys := ownkeys(o);
		r := newarray(0);
		for(i := 0; i < len keys; i++) {
			k := keys[i];
			if((atomsym[k] != nil) == (id == NOgops) && !isprivkey(k))
				apush(r, keyv(k));
		}
		return objv(r);
	NOgetproto =>
		o := toobj(arg(args, 0));
		return objv(getprotoof(o));
	NOgroupby =>
		return groupby(args, 0);
	NOhasown =>
		o := toobj(arg(args, 0));
		return boolv(hasownp(o, tokey(arg(args, 1))));
	NOis =>
		return boolv(samevalue(arg(args, 0), arg(args, 1)));
	NOisext =>
		o := arg(args, 0);
		if(o.t != Tobj)
			return falsev;
		return boolv(isextensible(o.o));
	NOisfrozen or NOissealed =>
		o := arg(args, 0);
		if(o.t != Tobj)
			return truev;
		return boolv(testintegrity(o.o, id == NOisfrozen));
	NOprevent =>
		o := arg(args, 0);
		if(o.t != Tobj)
			return o;
		if(!preventext(o.o))
			throwtype("Cannot prevent extensions");
		return o;
	NOsetproto =>
		o := arg(args, 0);
		if(o.t == Tundef || o.t == Tnull)
			throwtype("Object.setPrototypeOf called on null or undefined");
		p := arg(args, 1);
		if(p.t != Tobj && p.t != Tnull)
			throwtype("Object prototype may only be an Object or null: " + showv(p));
		if(o.t != Tobj)
			return o;
		if(!setprotoof(o.o, p.o))
			throwtype("Cyclic __proto__ value, or the object is not extensible");
		return o;
	NOPhasown =>
		k := tokey(arg(args, 0));
		o := toobj(this);
		return boolv(hasownp(o, k));
	NOPisproto =>
		v := arg(args, 0);
		if(v.t != Tobj)
			return falsev;
		o := toobj(this);
		for(p := getprotoof(v.o); p != nil; p = getprotoof(p))
			if(p == o)
				return truev;
		return falsev;
	NOPpropenum =>
		k := tokey(arg(args, 0));
		o := toobj(this);
		d := getowndesc(o, k);
		return boolv(d != nil && (d.attrs & Aenum) != 0);
	NOPtolocale =>
		return invoke(this, a_toString, nil);
	NOPtostring =>
		return strv(objtostring(this));
	NOPvalueof =>
		return objv(toobj(this));
	NOPdefget or NOPdefset =>
		o := toobj(this);
		g := arg(args, 1);
		if(!iscallable(g))
			throwtype("Object.prototype.__defineGetter__: Expecting function");
		k := tokey(arg(args, 0));
		if(id == NOPdefget)
			defineorthrow(o, k, ref Desc(Dget|Denum|Dconf, undef, Aenum|Aconf, g.o, nil));
		else
			defineorthrow(o, k, ref Desc(Dset|Denum|Dconf, undef, Aenum|Aconf, nil, g.o));
		return undef;
	NOPlookget or NOPlookset =>
		o := toobj(this);
		k := tokey(arg(args, 0));
		for(p := o; p != nil; p = getprotoof(p)) {
			d := getowndesc(p, k);
			if(d != nil) {
				if(id == NOPlookget && d.get != nil)
					return objv(d.get);
				if(id == NOPlookset && d.set != nil)
					return objv(d.set);
				return undef;
			}
		}
		return undef;
	NOPgetproto =>
		o := toobj(this);
		return objv(getprotoof(o));
	NOPsetproto =>
		if(this.t == Tundef || this.t == Tnull)
			throwtype("Object.prototype.__proto__ called on null or undefined");
		p := arg(args, 0);
		if(p.t != Tobj && p.t != Tnull || this.t != Tobj)
			return undef;
		if(!setprotoof(this.o, p.o))
			throwtype("Cyclic __proto__ value");
		return undef;
	NFunction or NGeneratorFunction or NAsyncFunction or NAsyncGeneratorFunction =>
		return objv(dynfunction(id, args, nt));
	NFapply =>
		if(!iscallable(this))
			throwtype("Function.prototype.apply was called on " + showv(this) + ", which is not a function");
		a := arg(args, 1);
		if(a.t == Tundef || a.t == Tnull)
			return call(this.o, arg(args, 0), nil);
		return call(this.o, arg(args, 0), listfrom(a));
	NFbind =>
		if(!iscallable(this))
			throwtype("Bind must be called on a function");
		return objv(bindfn(this.o, arg(args, 0), args));
	NFcall =>
		if(!iscallable(this))
			throwtype("Function.prototype.call was called on " + showv(this) + ", which is not a function");
		if(len args <= 1)
			return call(this.o, arg(args, 0), nil);
		return call(this.o, args[0], args[1:]);
	NFtostring =>
		if(this.t == Tobj && this.o.cls == Cproxy && this.o.fun != nil)
			return strv("function () { [native code] }");
		if(!iscallable(this))
			throwtype("Function.prototype.toString requires that 'this' be a Function");
		return strv(fntostring(this.o));
	NFhasinstance =>
		if(this.t != Tobj)
			return falsev;
		return boolv(ordinaryhasinstance(this.o, arg(args, 0)));
	NGnext =>
		return gennext(this, Mnext, arg(args, 0));
	NGreturn =>
		return gennext(this, Mreturn, arg(args, 0));
	NGthrow =>
		return gennext(this, Mthrow, arg(args, 0));
	NAGnext =>
		return agrequest(this, Mnext, arg(args, 0));
	NAGreturn =>
		return agrequest(this, Mreturn, arg(args, 0));
	NAGthrow =>
		return agrequest(this, Mthrow, arg(args, 0));
	NAFSnext or NAFSreturn or NAFSthrow =>
		return asyncfromsyncstep(id, this, args);
	NIterself =>
		return this;
	NSymbol =>
		if(nt != nil)
			throwtype("Symbol is not a constructor");
		d := arg(args, 0);
		if(d.t == Tundef)
			return V(Tsym, 0, 0.0, nil, newsym(nil, 0));
		return V(Tsym, 0, 0.0, nil, newsym(tostr(d), 1));
	NSfor =>
		key := strv(tostr(arg(args, 0)));
		i := hfind(symregistry, key);
		if(i >= 0)
			return symregistry.vals[i];
		s := newsym(key.s, 1);
		pick d := s.data {
		Sym =>
			d.reg = 1;
		}
		v := V(Tsym, 0, 0.0, nil, s);
		hset(symregistry, key, v);
		return v;
	NSkeyfor =>
		s := arg(args, 0);
		if(s.t != Tsym)
			throwtype(showv(s) + " is not a symbol");
		pick d := s.o.data {
		Sym =>
			if(d.reg)
				return strv(d.desc);
		}
		return undef;
	NSyPtostring =>
		s := thissym(this);
		pick d := s.data {
		Sym =>
			return strv("Symbol(" + d.desc + ")");
		}
		return undef;
	NSyPvalueof =>
		return V(Tsym, 0, 0.0, nil, thissym(this));
	NSyPdescription =>
		s := thissym(this);
		pick d := s.data {
		Sym =>
			if(d.hasdesc)
				return strv(d.desc);
		}
		return undef;
	NBoolean =>
		b := boolv(tobool(arg(args, 0)));
		if(nt == nil)
			return b;
		o := fromctor(nt, boolproto, Cbool);
		o.data = ref Data.Prim(b);
		return objv(o);
	NBPtostring or NBPvalueof =>
		b := thisprim(this, Cbool, Tbool, "Boolean");
		if(id == NBPvalueof)
			return b;
		return strv(tostr(b));
	NErrtostring =>
		if(this.t != Tobj)
			throwtype("Error.prototype.toString called on a non-object");
		n := get(this.o, a_name, this);
		name := "Error";
		if(n.t != Tundef)
			name = tostr(n);
		m := get(this.o, a_message, this);
		msg := "";
		if(m.t != Tundef)
			msg = tostr(m);
		if(name == "")
			return strv(msg);
		if(msg == "")
			return strv(name);
		return strv(name + ": " + msg);
	NErrcapture =>
		o := arg(args, 0);
		if(o.t != Tobj)
			throwtype("Invalid argument");
		defprop(o.o, a_stack, strv(""), Awrite|Aconf);
		return undef;
	NErriserror =>
		o := arg(args, 0);
		return boolv(o.t == Tobj && o.o.cls == Cerror);
	Nevalfn =>
		x := arg(args, 0);
		if(!isstr(x))
			return x;
		return evalcode(flat(x), 1);
	NisFinite =>
		x := tonum(arg(args, 0));
		return boolv(!isnan(x) && x != inf && x != -inf);
	NisNaN =>
		return boolv(isnan(tonum(arg(args, 0))));
	NparseFloat =>
		return V(Tnum, 0, parsefloat(tostr(arg(args, 0))), nil, nil);
	NparseInt =>
		return parseint(tostr(arg(args, 0)), arg(args, 1));
	NdecodeURI =>
		return strv(uridecode(tostr(arg(args, 0)), ";/?:@&=+$,#"));
	NdecodeURIComponent =>
		return strv(uridecode(tostr(arg(args, 0)), ""));
	NencodeURI =>
		return strv(uriencode(tostr(arg(args, 0)), ";/?:@&=+$,-_.!~*'()#"));
	NencodeURIComponent =>
		return strv(uriencode(tostr(arg(args, 0)), "-_.!~*'()"));
	Nescape =>
		return strv(escape(tostr(arg(args, 0))));
	Nunescape =>
		return strv(unescape(tostr(arg(args, 0))));
	Nprint or Nconsolelog =>
		s := "";
		for(i := 0; i < len args; i++) {
			if(i > 0)
				s += " ";
			if(args[i].t == Tsym)
				s += showv(args[i]);
			else if(id == Nconsolelog && args[i].t == Tobj && args[i].o.fun == nil)
				s += inspect(args[i], 2);
			else
				s += tostr(args[i]);
		}
		out(s + "\n");
		return undef;
	Nbound =>
		if(f.data != nil)
		pick b := f.data {
		Bound =>
			a := array[len b.args + len args] of V;
			a[0:] = b.args;
			a[len b.args:] = args;
			if(nt != nil) {
				if(nt == f)
					nt = b.target;
				return construct(b.target, a, nt);
			}
			return call(b.target, b.this, a);
		}
	Npromisecapexec =>
		if(f.data != nil)
		pick d := f.data {
		Capexec =>
			if(d.cap.resolve != nil || d.cap.reject != nil)
				throwtype("Promise executor has already been invoked with non-undefined arguments");
			r := arg(args, 0);
			j := arg(args, 1);
			if(r.t == Tobj)
				d.cap.resolve = r.o;
			if(j.t == Tobj)
				d.cap.reject = j.o;
			if(r.t != Tundef && r.t != Tobj || j.t != Tundef && j.t != Tobj) {
				# not functions: kept so the caller can say so
				if(r.t != Tundef && r.t != Tobj)
					d.cap.resolve = throwerfn;
				if(j.t != Tundef && j.t != Tobj)
					d.cap.reject = throwerfn;
			}
		}
		return undef;
	Npromiseresolvefn =>
		if(f.data != nil)
		pick d := f.data {
		Resolver =>
			if(d.done.v)
				return undef;
			d.done.v = 1;
			if(d.reject)
				rejectpromise(d.p, arg(args, 0));
			else
				resolvepromise(d.p, arg(args, 0));
		}
		return undef;
	Npxcall =>
		return pxcall(f, this, args);
	Nhostfn =>
		return hostcall(f, args);
	Nimportjob =>
		return importjob(f);
	Nmemstat =>
		# the heap arena's bytes in use (a debugging aid)
		fd := sys->open("/dev/memory", Sys->OREAD);
		if(fd == nil)
			return intv(-1);
		b := array[1024] of byte;
		k := sys->read(fd, b, len b);
		if(k <= 0)
			return intv(-1);
		(nil, lines) := sys->tokenize(string b[0:k], "\n");
		for(; lines != nil; lines = tl lines) {
			(nil, f) := sys->tokenize(hd lines, " \t");
			if(len f >= 8 && hd tl tl tl tl tl tl tl f == "heap")
				return numv(real hd f);
		}
		return intv(-2);
	}
	if(id >= NError && id < NError + 8)
		return errorctor(id - NError, f, args, nt);
	throwerr(EError, "unknown built-in " + string id);
	return undef;
}

errorctor(kind: int, f: ref Obj, args: array of V, nt: ref Obj): V
{
	if(nt == nil)
		nt = f;
	o := fromctor(nt, errprotos[kind], Cerror);
	mi := 0;
	if(kind == EAggregate)
		mi = 1;
	m := arg(args, mi);
	if(m.t != Tundef)
		addprop(o, a_message, Awrite|Aconf, strv(tostr(m)));
	opts := arg(args, mi + 1);
	if(opts.t == Tobj && hasprop(opts.o, a_cause))
		addprop(o, a_cause, Awrite|Aconf, get(opts.o, a_cause, opts));
	if(kind == EAggregate) {
		errs := iterlist(arg(args, 0));
		defprop(o, a_errors, objv(mkarray(errs)), Awrite|Aconf);
	}
	return objv(o);
}

thissym(this: V): ref Obj
{
	if(this.t == Tsym)
		return this.o;
	if(this.t == Tobj && this.o.cls == Csym) {
		pick d := this.o.data {
		Prim =>
			return d.v.o;
		}
	}
	throwtype("Symbol.prototype method called on incompatible receiver " + showv(this));
	return nil;
}

# a primitive's value from this, or its wrapper object's
thisprim(this: V, cls, t: int, name: string): V
{
	if(this.t == t || t == Tint && this.t == Tnum || t == Tstr && this.t == Trope)
		return this;
	if(this.t == Tobj && this.o.cls == cls) {
		pick d := this.o.data {
		Prim =>
			return d.v;
		}
	}
	throwtype(name + ".prototype method called on incompatible receiver " + showv(this));
	return undef;
}

isprivkey(k: int): int
{
	s := atomsym[k];
	return s != nil && (s.flags & Fpriv);
}

hasownp(o: ref Obj, k: int): int
{
	if(o.cls == Cproxy)
		return pxgetowndesc(o, k) != nil;
	if(o.cls == Cfunc && k == a_prototype && (o.flags & Flazyproto))
		mkproto(o);
	return hasown(o, k);
}

# ToPropertyDescriptor
todescriptor(v: V): ref Desc
{
	if(v.t != Tobj)
		throwtype("Property description must be an object: " + showv(v));
	o := v.o;
	d := ref Desc(0, undef, 0, nil, nil);
	if(hasprop(o, a_enumerable)) {
		d.has |= Denum;
		if(tobool(getv(o, a_enumerable)))
			d.attrs |= Aenum;
	}
	if(hasprop(o, a_configurable)) {
		d.has |= Dconf;
		if(tobool(getv(o, a_configurable)))
			d.attrs |= Aconf;
	}
	if(hasprop(o, a_value)) {
		d.has |= Dvalue;
		d.v = getv(o, a_value);
	}
	if(hasprop(o, a_writable)) {
		d.has |= Dwrite;
		if(tobool(getv(o, a_writable)))
			d.attrs |= Awrite;
	}
	if(hasprop(o, a_get)) {
		g := getv(o, a_get);
		if(g.t != Tundef && !iscallable(g))
			throwtype("Getter must be a function: " + showv(g));
		d.has |= Dget;
		if(g.t == Tobj)
			d.get = g.o;
	}
	if(hasprop(o, a_set)) {
		s := getv(o, a_set);
		if(s.t != Tundef && !iscallable(s))
			throwtype("Setter must be a function: " + showv(s));
		d.has |= Dset;
		if(s.t == Tobj)
			d.set = s.o;
	}
	if((d.has & (Dget|Dset)) && (d.has & (Dvalue|Dwrite)))
		throwtype("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute");
	return d;
}

# FromPropertyDescriptor
fromdesc(d: ref Desc): ref Obj
{
	o := plainobj();
	if(d.has & (Dget|Dset)) {
		addprop(o, a_get, Adefault, objv(d.get));
		if(d.get == nil)
			o.slots[0] = undef;
		addprop(o, a_set, Adefault, objv(d.set));
		if(d.set == nil)
			o.slots[1] = undef;
	} else {
		addprop(o, a_value, Adefault, d.v);
		addprop(o, a_writable, Adefault, boolv(d.attrs & Awrite));
	}
	addprop(o, a_enumerable, Adefault, boolv(d.attrs & Aenum));
	addprop(o, a_configurable, Adefault, boolv(d.attrs & Aconf));
	return o;
}

defprops(o: ref Obj, v: V)
{
	props := toobj(v);
	keys := ownkeys(props);
	descs: list of (int, ref Desc);
	for(i := 0; i < len keys; i++) {
		d := getowndesc(props, keys[i]);
		if(d == nil || (d.attrs & Aenum) == 0)
			continue;
		descs = (keys[i], todescriptor(get(props, keys[i], objv(props)))) :: descs;
	}
	r: list of (int, ref Desc);
	for(; descs != nil; descs = tl descs)
		r = hd descs :: r;
	for(; r != nil; r = tl r) {
		(k, d) := hd r;
		defineorthrow(o, k, d);
	}
}

# SetIntegrityLevel
setintegrity(o: ref Obj, frozen: int): int
{
	if(!preventext(o))
		return 0;
	keys := ownkeys(o);
	if(o.cls != Cproxy && o.cls != Ctyped && o.cls != Cns && o.cls != Cargs) {
		if(o.cls == Carray)
			slowarray(o);
		for(i := 0; i < len keys; i++) {
			k := keys[i];
			if(o.cls == Carray && k == a_length) {
				if(frozen)
					o.flags |= Ffrozenlen;
				continue;
			}
			s := slotof(o.sh, k);
			if(s < 0)
				continue;
			at := o.sh.attrs[s] & ~Aconf;
			if(frozen && (at & Aacc) == 0)
				at &= ~Awrite;
			setattrs(o, s, at);
		}
		return 1;
	}
	for(i := 0; i < len keys; i++) {
		k := keys[i];
		if(frozen) {
			d := getowndesc(o, k);
			if(d == nil)
				continue;
			if(d.has & (Dget|Dset))
				defineorthrow(o, k, ref Desc(Dconf, undef, 0, nil, nil));
			else
				defineorthrow(o, k, ref Desc(Dconf|Dwrite, undef, 0, nil, nil));
		} else
			defineorthrow(o, k, ref Desc(Dconf, undef, 0, nil, nil));
	}
	return 1;
}

testintegrity(o: ref Obj, frozen: int): int
{
	if(isextensible(o))
		return 0;
	keys := ownkeys(o);
	for(i := 0; i < len keys; i++) {
		d := getowndesc(o, keys[i]);
		if(d == nil)
			continue;
		if(d.attrs & Aconf)
			return 0;
		if(frozen && (d.has & Dvalue) && (d.attrs & Awrite))
			return 0;
	}
	return 1;
}

# Object.prototype.toString
objtostring(v: V): string
{
	case v.t {
	Tundef =>
		return "[object Undefined]";
	Tnull =>
		return "[object Null]";
	}
	o := toobj(v);
	tag := "Object";
	if(isarray(objv(o)))
		tag = "Array";
	else
		case o.cls {
		Cargs =>
			tag = "Arguments";
		Cfunc =>
			tag = "Function";
		Cerror =>
			tag = "Error";
		Cbool =>
			tag = "Boolean";
		Cnum =>
			tag = "Number";
		Cstr =>
			tag = "String";
		Cdate =>
			tag = "Date";
		Cregexp =>
			tag = "RegExp";
		Cproxy =>
			if(o.fun != nil)
				tag = "Function";
		}
	t := get(o, a_symtostringtag, objv(o));
	if(isstr(t))
		tag = flat(t);
	return "[object " + tag + "]";
}

# IsArray
isarray(v: V): int
{
	if(v.t != Tobj)
		return 0;
	if(v.o.cls == Carray)
		return 1;
	if(v.o.cls == Cproxy) {
		pick d := v.o.data {
		Proxy =>
			if(d.handler == nil)
				throwtype("Cannot perform 'IsArray' on a proxy that has been revoked");
			return isarray(objv(d.target));
		}
	}
	return 0;
}

bindfn(target: ref Obj, this: V, args: array of V): ref Obj
{
	ba: array of V;
	if(len args > 1)
		ba = args[1:];
	else
		ba = array[0] of V;
	o := ref Obj;
	o.cls = Cfunc;
	o.sh = emptyshape(getprotoof(target));
	o.flags = Fext;
	if(isctor(target))
		o.flags |= Fctor;
	o.fun = ref Fn(nil, Nbound, 0);
	o.data = ref Data.Bound(target, this, ba);
	l := 0.0;
	if(hasownp(target, a_length)) {
		tlv := get(target, a_length, objv(target));
		if(isnum(tlv)) {
			x := numof(tlv);
			if(x == inf)
				l = inf;
			else if(x != -inf && !isnan(x)) {
				x = trunc(x) - real len ba;
				if(x > 0.0)
					l = x;
			}
		}
	}
	addprop(o, a_length, Aconf, numv(l));
	n := get(target, a_name, objv(target));
	name := "";
	if(isstr(n))
		name = flat(n);
	addprop(o, a_name, Aconf, strv("bound " + name));
	return o;
}

fntostring(f: ref Obj): string
{
	if(f.fun.code != nil && f.fun.code.src != nil) {
		c := f.fun.code;
		if(c.send <= len c.src.s && (c.flags & (Cscript|Ceval)) == 0)
			return c.src.s[c.spos:c.send];
	}
	name := "";
	n := fnname(f);
	if(n != nil)
		name = n;
	return "function " + name + "() { [native code] }";
}

# the Function constructor and its kin: the source made into a function
dynfunction(id: int, args: array of V, nil: ref Obj): ref Obj
{
	params := "";
	for(i := 0; i < len args - 1; i++) {
		if(i > 0)
			params += ",";
		params += tostr(args[i]);
	}
	body := "";
	if(len args > 0)
		body = tostr(args[len args - 1]);
	kw := "function";
	case id {
	NGeneratorFunction =>
		kw = "function*";
	NAsyncFunction =>
		kw = "async function";
	NAsyncGeneratorFunction =>
		kw = "async function*";
	}
	src := "(" + kw + " anonymous(" + params + "\n) {\n" + body + "\n})";
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		throwerr(ESyntax, err);
	# the parts must each be what they say: one function, its body the body
	pick p := prog {
	Program =>
		ok := 0;
		if(len p.body == 1) {
			pick e := p.body[0] {
			Expr =>
				x := e.e;
				pick pe := x {
				Paren =>
					x = pe.e;
				}
				pick fx := x {
				Func =>
					ok = fx.end == len src - 1;
					# the parameters must not close the list early
					(nil, perr) := jsparse->parse("(" + kw + " anonymous(" + params + "\n) {})", 0, 0);
					if(perr != nil)
						ok = 0;
					(nil, berr) := jsparse->parse("(" + kw + " anonymous() {\n" + body + "\n})", 0, 0);
					if(berr != nil)
						ok = 0;
				}
			}
		}
		if(!ok)
			throwerr(ESyntax, "Unexpected token in the Function constructor's arguments");
		(pos, msg) := jscheck->check(prog);
		if(msg != nil)
			throwerr(ESyntax, msg + " at " + string pos);
		(c, cerr) := compilescript(p, src, 1, nil, 0);
		if(cerr != nil)
			throwerr(ESyntax, cerr);
		# its value is the function; it runs in the global scope
		pick e := p.body[0] {
		Expr =>
			;
		}
		v := rununitexpr(c);
		if(v.t != Tobj)
			throwerr(EError, "Function constructor made no function");
		return v.o;
	}
	return nil;
}

# a script made of one expression: its value
rununitexpr(c: ref Code): V
{
	return rununit(c, globalthis, nil);
}

# ---- globals' helpers ----

parsefloat(s: string): real
{
	s = trimws(s, 1, 0);
	i := 0;
	if(i < len s && (s[i] == '+' || s[i] == '-'))
		i++;
	if(len s >= i + 8 && s[i:i+8] == "Infinity") {
		if(s[0] == '-')
			return -inf;
		return inf;
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
		return nan;
	if(i < len s && (s[i] == 'e' || s[i] == 'E')) {
		j := i + 1;
		if(j < len s && (s[j] == '+' || s[j] == '-'))
			j++;
		ne := 0;
		while(j < len s && s[j] >= '0' && s[j] <= '9') {
			j++;
			ne++;
		}
		if(ne > 0)
			i = j;
	}
	st = 0;
	t := s[st:i];
	if(len t > 0 && t[len t - 1] == '.')
		t = t[0:len t - 1];
	v := decimal(t);
	if(v == 0.0 && s[0] == '-')
		return -0.0;
	return v;
}

parseint(s: string, radix: V): V
{
	s = trimws(s, 1, 0);
	neg := 0;
	i := 0;
	if(i < len s && (s[i] == '+' || s[i] == '-')) {
		neg = s[i] == '-';
		i++;
	}
	r := toint32(radix);
	strip := 1;
	if(r != 0) {
		if(r < 2 || r > 36)
			return V(Tnum, 0, nan, nil, nil);
		if(r != 16)
			strip = 0;
	} else
		r = 10;
	if(strip && i + 1 < len s && s[i] == '0' && (s[i+1] == 'x' || s[i+1] == 'X')) {
		i += 2;
		r = 16;
	}
	st := i;
	while(i < len s) {
		d := digitval(s[i]);
		if(d < 0 || d >= r)
			break;
		i++;
	}
	if(i == st)
		return V(Tnum, 0, nan, nil, nil);
	x: real;
	if(r == 10)
		x = decimal(s[st:i]);
	else {
		x = 0.0;
		for(j := st; j < i; j++)
			x = x * real r + real digitval(s[j]);
		if(x >= 9007199254740992.0 && (r & (r - 1)) == 0)
			x = pow2digits(s[st:i], r);
	}
	if(neg)
		x = -x;
	return numv(x);
}

# a power-of-two radix's digits, rounded correctly
pow2digits(s: string, r: int): real
{
	bits := 0;
	for(b := r; b > 1; b >>= 1)
		bits++;
	# the bits, most significant first
	nb := len s * bits;
	a := array[nb] of int;
	for(i := 0; i < len s; i++) {
		d := digitval(s[i]);
		for(j := 0; j < bits; j++)
			a[i * bits + j] = (d >> (bits - 1 - j)) & 1;
	}
	st := 0;
	while(st < nb && a[st] == 0)
		st++;
	if(st == nb)
		return 0.0;
	n := nb - st;
	if(n <= 53) {
		x := 0.0;
		for(i = st; i < nb; i++)
			x = x * 2.0 + real a[i];
		return x;
	}
	m := 0.0;
	for(i = st; i < st + 53; i++)
		m = m * 2.0 + real a[i];
	# round half to even on the rest
	half := a[st + 53];
	rest := 0;
	for(i = st + 54; i < nb; i++)
		if(a[i])
			rest = 1;
	if(half && (rest || a[st + 52]))
		m += 1.0;
	return math->scalbn(m, n - 53);
}

hexd := "0123456789ABCDEF";

uriencode(s: string, keep: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < 128 && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || instr(keep, c))) {
			r[len r] = c;
			continue;
		}
		cp := c;
		if(c >= 16rDC00 && c <= 16rDFFF)
			throwerr(EURI, "URI malformed");
		if(c >= 16rD800 && c <= 16rDBFF) {
			if(i + 1 >= len s || s[i+1] < 16rDC00 || s[i+1] > 16rDFFF)
				throwerr(EURI, "URI malformed");
			cp = 16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00);
			i++;
		}
		b := utf8(cp);
		for(j := 0; j < len b; j++) {
			r[len r] = '%';
			r[len r] = hexd[int b[j] >> 4];
			r[len r] = hexd[int b[j] & 15];
		}
	}
	return r;
}

instr(s: string, c: int): int
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

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
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
		if(i + 2 >= len s)
			throwerr(EURI, "URI malformed");
		h := hexval(s[i+1]);
		l := hexval(s[i+2]);
		if(h < 0 || l < 0)
			throwerr(EURI, "URI malformed");
		b := h << 4 | l;
		i += 2;
		if(b < 16r80) {
			if(instr(reserved, b))
				r += s[st:i+1];
			else
				r[len r] = b;
			continue;
		}
		n := 0;
		if((b & 16rE0) == 16rC0)
			n = 1;
		else if((b & 16rF0) == 16rE0)
			n = 2;
		else if((b & 16rF8) == 16rF0)
			n = 3;
		else
			throwerr(EURI, "URI malformed");
		cp := b & (16r3F >> n);
		for(j := 0; j < n; j++) {
			if(i + 3 > len s || s[i+1] != '%')
				throwerr(EURI, "URI malformed");
			h = hexval(s[i+2]);
			if(i + 3 >= len s)
				throwerr(EURI, "URI malformed");
			l = hexval(s[i+3]);
			if(h < 0 || l < 0)
				throwerr(EURI, "URI malformed");
			bb := h << 4 | l;
			if((bb & 16rC0) != 16r80)
				throwerr(EURI, "URI malformed");
			cp = cp << 6 | (bb & 16r3F);
			i += 3;
		}
		# overlong forms and surrogates are errors
		if(n == 1 && cp < 16r80 || n == 2 && cp < 16r800 || n == 3 && cp < 16r10000 || cp > 16r10FFFF || cp >= 16rD800 && cp <= 16rDFFF)
			throwerr(EURI, "URI malformed");
		if(cp >= 16r10000) {
			cp -= 16r10000;
			r[len r] = 16rD800 + (cp >> 10);
			r[len r] = 16rDC00 + (cp & 16r3FF);
		} else
			r[len r] = cp;
	}
	return r;
}

escape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || instr("@*_+-./", c))
			r[len r] = c;
		else if(c < 256) {
			r[len r] = '%';
			r[len r] = hexd[c >> 4];
			r[len r] = hexd[c & 15];
		} else {
			r += "%u";
			r[len r] = hexd[(c >> 12) & 15];
			r[len r] = hexd[(c >> 8) & 15];
			r[len r] = hexd[(c >> 4) & 15];
			r[len r] = hexd[c & 15];
		}
	}
	return r;
}

unescape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '%') {
			if(i + 5 < len s + 0 && s[i+1] == 'u') {
				a := hexval(s[i+2]);
				b := hexval(s[i+3]);
				d := hexval(s[i+4]);
				e := hexval(s[i+5]);
				if(a >= 0 && b >= 0 && d >= 0 && e >= 0) {
					r[len r] = a << 12 | b << 8 | d << 4 | e;
					i += 5;
					continue;
				}
			}
			if(i + 2 < len s) {
				a := hexval(s[i+1]);
				b := hexval(s[i+2]);
				if(a >= 0 && b >= 0) {
					r[len r] = a << 4 | b;
					i += 2;
					continue;
				}
			}
		}
		r[len r] = c;
	}
	return r;
}

# what console.log shows for an object
inspect(v: V, depthleft: int): string
{
	case v.t {
	Tstr or Trope =>
		return "'" + flat(v) + "'";
	Tobj =>
		o := v.o;
		if(o.fun != nil) {
			n := fnname(o);
			if(n == nil || n == "")
				return "[Function (anonymous)]";
			return "[Function: " + n + "]";
		}
		if(o.cls == Cerror) {
			s := "";
			{
				s = tostr(invoke(v, a_toString, nil));
			} exception {
			"JS" =>
				s = "Error";
			}
			return s;
		}
		if(depthleft < 0)
			return "[Object]";
		if(o.cls == Carray) {
			s := "[ ";
			n := o.alen;
			if(n == 0)
				return "[]";
			for(i := 0; i < n && i < 100; i++) {
				if(i > 0)
					s += ", ";
				s += inspect(getidx(o, i, v), depthleft - 1);
			}
			if(n > 100)
				s += ", ...";
			return s + " ]";
		}
		keys := enumkeys(o);
		if(len keys == 0)
			return "{}";
		s := "{ ";
		for(i := 0; i < len keys && i < 100; i++) {
			if(i > 0)
				s += ", ";
			s += atomstr[keys[i]] + ": " + inspect(get(o, keys[i], v), depthleft - 1);
		}
		return s + " }";
	}
	return tostr(v);
}

# the iteration a built-in does over an iterable: each value to what it builds
iterate(it: V, what: int, o: ref Obj, nil: ref Obj)
{
	iter := getiterator(it, 0);
	next := getvalue(iter, a_next);
	for(;;) {
		r := call1(next, iter, nil);
		if(r.t != Tobj)
			throwtype("Iterator result is not an object");
		if(tobool(getv(r.o, a_done)))
			return;
		v := getv(r.o, a_value);
		{
			case what {
			NOfromentries =>
				if(v.t != Tobj)
					throwtype("Iterator value " + showv(v) + " is not an entry object");
				k := getidx(v.o, 0, v);
				x := getidx(v.o, 1, v);
				createdatathrow(o, tokey(k), x);
			}
		} exception {
		"JS" =>
			ex := thrown;
			iterclose(iter, 1);
			throwv(ex);
		}
	}
}

# Object.groupBy (map 0) and Map.groupBy (map 1)
groupby(args: array of V, ismap: int): V
{
	items := arg(args, 0);
	f := arg(args, 1);
	if(items.t == Tundef || items.t == Tnull)
		throwtype("groupBy called on null or undefined");
	if(!iscallable(f))
		throwtype(showv(f) + " is not a function");
	groups := newhmap();
	order: list of V;
	iter := getiterator(items, 0);
	next := getvalue(iter, a_next);
	k := 0;
	for(;;) {
		r := call1(next, iter, nil);
		if(r.t != Tobj)
			throwtype("Iterator result is not an object");
		if(tobool(getv(r.o, a_done)))
			break;
		v := getv(r.o, a_value);
		key: V;
		{
			key = call(f.o, undef, array[] of {v, intv(k)});
			if(!ismap)
				key = keyv(tokey(key));
			else if(key.t == Tnum && key.n == 0.0)
				key = intv(0);
		} exception {
		"JS" =>
			ex := thrown;
			iterclose(iter, 1);
			throwv(ex);
		}
		i := hfind(groups, key);
		if(i < 0) {
			hset(groups, key, objv(newarray(0)));
			order = key :: order;
			i = hfind(groups, key);
		}
		apush(groups.vals[i].o, v);
		k++;
	}
	rev: list of V;
	for(; order != nil; order = tl order)
		rev = hd order :: rev;
	if(ismap) {
		m := newobj(Cmap, mapproto);
		hm := newhmap();
		m.data = ref Data.Map(hm);
		for(; rev != nil; rev = tl rev)
			hset(hm, hd rev, groups.vals[hfind(groups, hd rev)]);
		return objv(m);
	}
	o := newobj(Cplain, nil);
	for(; rev != nil; rev = tl rev)
		createdata(o, tokey(hd rev), groups.vals[hfind(groups, hd rev)]);
	return objv(o);
}

# how an uncaught exception is shown: "Name: message", as appl/lib/js does
showexc(v: V): string
{
	if(v.t == Tobj) {
		{
			n := getv(v.o, a_name);
			m := getv(v.o, a_message);
			ns := "Error";
			if(isstr(n))
				ns = flat(n);
			if(isstr(m) && strlenv(m) > 0)
				return ns + ": " + flat(m);
			if(isstr(n))
				return ns;
		} exception {
		"JS" =>
			;
		}
	}
	{
		if(v.t == Tsym)
			return "uncaught " + showv(v);
		return "uncaught " + tostr(v);
	} exception {
	"JS" =>
		;
	}
	return "uncaught exception";
}

# a value as the shell shows it
display(v: V): string
{
	{
		if(v.t == Tsym)
			return showv(v);
		return tostr(v);
	} exception {
	"JS" =>
		;
	}
	if(v.t == Tobj)
		return "[object]";
	return showv(v);
}

out(s: string)
{
	if(output != nil)
		output(s);
	else
		sys->print("%s", s);
}
