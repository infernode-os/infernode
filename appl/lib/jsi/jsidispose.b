#
# jsidispose.b - explicit resource management: using and await using,
# SuppressedError, DisposableStack and AsyncDisposableStack; and
# Array.fromAsync.  The rules follow appl/lib/js/jsdispose.b's.
#
# Async built-ins (disposeAsync, Array.fromAsync) are Limbo code run as
# an async function's coroutine (asyncnative), so they await as a
# script's async function does.
#

NSuppressedError, NDisposableStack, NDSPdisposed, NDSPdispose, NDSPuse, NDSPadopt, NDSPdefer,
NDSPmove, NAsyncDisposableStack, NADSPdisposed, NADSPdisposeasync, NADSPuse, NADSPadopt,
NADSPdefer, NADSPmove, NIPdisposed, NAIPdisposed, NAdoptcall: con Ndisposebase + iota;

# the async natives' ids (Gen.nat)
Xdisposeasync, Xfromasync: con 1 + iota;

suppproto, dsproto, adsproto: ref Obj;

disposeinit()
{
	suppproto = newobj(Cplain, errproto);
	c := defctor("SuppressedError", NSuppressedError, 3, suppproto);
	ec := getv(global, intern("Error"));
	setproto(c, ec.o);
	defval(suppproto, "name", strv("SuppressedError"), Awrite|Aconf);
	defval(suppproto, "message", strv(""), Awrite|Aconf);
	dsproto = newobj(Cplain, objproto);
	defctor("DisposableStack", NDisposableStack, 0, dsproto);
	p := dsproto;
	defgetter(p, "disposed", NDSPdisposed);
	d := defmethod(p, "dispose", NDSPdispose, 0);
	defprop(p, a_symdispose, objv(d), Awrite|Aconf);
	defmethod(p, "use", NDSPuse, 1);
	defmethod(p, "adopt", NDSPadopt, 2);
	defmethod(p, "defer", NDSPdefer, 1);
	defmethod(p, "move", NDSPmove, 0);
	defprop(p, a_symtostringtag, strv("DisposableStack"), Aconf);
	adsproto = newobj(Cplain, objproto);
	defctor("AsyncDisposableStack", NAsyncDisposableStack, 0, adsproto);
	p = adsproto;
	defgetter(p, "disposed", NADSPdisposed);
	d = defmethod(p, "disposeAsync", NADSPdisposeasync, 0);
	defprop(p, a_symasyncdispose, objv(d), Awrite|Aconf);
	defmethod(p, "use", NADSPuse, 1);
	defmethod(p, "adopt", NADSPadopt, 2);
	defmethod(p, "defer", NADSPdefer, 1);
	defmethod(p, "move", NADSPmove, 0);
	defprop(p, a_symtostringtag, strv("AsyncDisposableStack"), Aconf);
	defsymmethod(iterproto, a_symdispose, "[Symbol.dispose]", NIPdisposed, 0);
	defsymmethod(asynciterproto, a_symasyncdispose, "[Symbol.asyncDispose]", NAIPdisposed, 0);
}

# a resource: the value, its dispose method (nil: none, for await using null), whether awaited
Res: adt {
	v:	V;
	m:	ref Obj;
	awaited:	int;
};

resource(v: V, async: int): ref Res
{
	if(v.t == Tundef || v.t == Tnull) {
		if(!async)
			return nil;
		return ref Res(undef, nil, 1);
	}
	if(v.t != Tobj)
		throwtype(showv(v) + " is not an object, so it cannot be disposed of");
	m: ref Obj;
	awaited := 0;
	if(async) {
		m = getmethod(v, a_symasyncdispose);
		awaited = 1;
		if(m == nil) {
			m = getmethod(v, a_symdispose);
			if(m != nil) {
				# a sync method under await using: its result is not awaited, but undefined is
				m = syncwrap(m);
			}
		}
	} else
		m = getmethod(v, a_symdispose);
	if(m == nil) {
		mn := "dispose";
		if(async)
			mn = "asyncDispose";
		throwtype(showv(v) + " has no Symbol." + mn + " method");
	}
	return ref Res(v, m, awaited);
}

# a sync dispose method under await using: called, its result dropped (the await is of undefined)
syncwrap(m: ref Obj): ref Obj
{
	f := mknative(NAdoptcall, "", 0);
	f.data = ref Data.Native(objv(m), undef, 1, nil);
	return f;
}

# the dispose stacks of the blocks being run, innermost first
Dscope: adt {
	res:	list of ref Res;
	async:	int;
};

dscopes: list of ref Dscope;

usingadd(v: V, async: int)
{
	if(dscopes == nil)
		throwerr(ESyntax, "using outside a block");
	r := resource(v, async);
	if(r != nil)
		(hd dscopes).res = r :: (hd dscopes).res;
}

# Nusing: the value in the registers is a resource; it stays there to be bound
usingnode(async: int)
{
	v := regv();
	usingadd(v, async);
	setr(v);
}

# a block with using declarations: its resources disposed of when it ends, however it ends
usingblock(n: int)
{
	ds := ref Dscope(nil, nb[n]);
	dscopes = ds :: dscopes;
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	err := V(Thole, 0, 0.0, nil, nil);
	pexs: string;
	{
		ev(na[n]);
	} exception e {
	"JS" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		err = thrown;
	"JSkill" =>
		raise e;
	"JS*" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		pexs = e;
	}
	dscopes = tl dscopes;
	sctl := ctl;
	sid := ctlid;
	sv := regv();
	ctl = 0;
	err = disposeall(ds.res, err, ds.async);
	ctl = sctl;
	ctlid = sid;
	setr(sv);
	if(err.t != Thole)
		throwv(err);
	if(pexs != nil)
		raise pexs;
}

# dispose of resources, last added first; the error to throw (Thole: none).
# The resources are roots while they are disposed of (an await may collect).
disposing: list of ref Dscope;

disposeall(res: list of ref Res, err: V, async: int): V
{
	disposing = ref Dscope(res, async) :: disposing;
	{
		err = disposeall1(res, err, async);
	} exception {
	"*" =>
		disposing = tl disposing;
		raise;
	}
	disposing = tl disposing;
	return err;
}

disposeall1(res: list of ref Res, err: V, async: int): V
{
	needawait := 0;
	hasawaited := 0;
	for(; res != nil; res = tl res) {
		r := hd res;
		if(!r.awaited && needawait && !hasawaited) {
			await(undef);
			needawait = 0;
		}
		if(r.m == nil) {
			needawait = 1;
			continue;
		}
		{
			x := call(r.m, r.v, nil);
			if(r.awaited) {
				await(x);
				hasawaited = 1;
			}
		} exception {
		"JS" =>
			if(err.t == Thole)
				err = thrown;
			else
				err = objv(suppressed(thrown, err));
		}
	}
	if(async && needawait && !hasawaited)
		await(undef);
	return err;
}

suppressed(err, supp: V): ref Obj
{
	o := newobj(Cerror, suppproto);
	addprop(o, a_error, Awrite|Aconf, err);
	addprop(o, a_suppressed, Awrite|Aconf, supp);
	return o;
}

# ---- DisposableStack and AsyncDisposableStack ----

dsdata(this: V, cls: int, name: string): ref Data.Disp
{
	if(this.t == Tobj && this.o.cls == cls) {
		pick d := this.o.data {
		Disp =>
			return d;
		}
	}
	throwtype(name + " called on incompatible receiver " + showv(this));
	return nil;
}

Cdispstack: con Cdisposable;
Cadispstack: con Cdisposable + 100;

dslive(this: V, cls: int, name: string): ref Data.Disp
{
	d := dsdata(this, cls, name);
	if(d.disposed)
		throwerr(ERef, name + ": the stack is already disposed");
	return d;
}

# the stack's resources as Res records (Data.Disp keeps (value, method, awaited))
dsres(d: ref Data.Disp): list of ref Res
{
	r: list of ref Res;
	for(l := d.stack; l != nil; l = tl l) {
		(v, m, aw) := hd l;
		r = ref Res(v, m, aw) :: r;
	}
	# d.stack is newest first already: keep that order
	o: list of ref Res;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

dspush(d: ref Data.Disp, r: ref Res)
{
	if(r != nil)
		d.stack = (r.v, r.m, r.awaited) :: d.stack;
}

natdispose(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NSuppressedError =>
		if(nt == nil)
			nt = f;
		o := fromctor(nt, suppproto, Cerror);
		msg := arg(args, 2);
		if(msg.t != Tundef)
			addprop(o, a_message, Awrite|Aconf, strv(tostr(msg)));
		addprop(o, a_error, Awrite|Aconf, arg(args, 0));
		addprop(o, a_suppressed, Awrite|Aconf, arg(args, 1));
		return objv(o);
	NDisposableStack or NAsyncDisposableStack =>
		if(nt == nil)
			throwtype("Constructor requires 'new'");
		cls := Cdispstack;
		proto := dsproto;
		if(id == NAsyncDisposableStack) {
			cls = Cadispstack;
			proto = adsproto;
		}
		o := fromctor(nt, proto, cls);
		o.data = ref Data.Disp(nil, 0);
		return objv(o);
	NDSPdisposed =>
		return boolv(dsdata(this, Cdispstack, "get DisposableStack.prototype.disposed").disposed);
	NADSPdisposed =>
		return boolv(dsdata(this, Cadispstack, "get AsyncDisposableStack.prototype.disposed").disposed);
	NDSPdispose =>
		d := dsdata(this, Cdispstack, "DisposableStack.prototype.dispose");
		if(d.disposed)
			return undef;
		d.disposed = 1;
		res := dsres(d);
		d.stack = nil;
		err := disposeall(res, V(Thole, 0, 0.0, nil, nil), 0);
		if(err.t != Thole)
			throwv(err);
		return undef;
	NDSPuse or NADSPuse =>
		cls := Cdispstack;
		if(id == NADSPuse)
			cls = Cadispstack;
		d := dslive(this, cls, "use");
		v := arg(args, 0);
		dspush(d, resource(v, id == NADSPuse));
		return v;
	NDSPadopt or NADSPadopt =>
		cls := Cdispstack;
		if(id == NADSPadopt)
			cls = Cadispstack;
		d := dslive(this, cls, "adopt");
		v := arg(args, 0);
		fv := arg(args, 1);
		if(!iscallable(fv))
			throwtype(showv(fv) + " is not a function");
		c := mknative(NAdoptcall, "", 0);
		c.data = ref Data.Native(fv, v, 0, nil);
		d.stack = (undef, c, id == NADSPadopt) :: d.stack;
		return v;
	NDSPdefer or NADSPdefer =>
		cls := Cdispstack;
		if(id == NADSPdefer)
			cls = Cadispstack;
		d := dslive(this, cls, "defer");
		fv := arg(args, 0);
		if(!iscallable(fv))
			throwtype(showv(fv) + " is not a function");
		d.stack = (undef, fv.o, id == NADSPdefer) :: d.stack;
		return undef;
	NDSPmove or NADSPmove =>
		cls := Cdispstack;
		proto := dsproto;
		if(id == NADSPmove) {
			cls = Cadispstack;
			proto = adsproto;
		}
		d := dslive(this, cls, "move");
		o := newobj(cls, proto);
		o.data = ref Data.Disp(d.stack, 0);
		d.stack = nil;
		d.disposed = 1;
		return objv(o);
	NADSPdisposeasync =>
		return asyncnative(Xdisposeasync, this, args);
	NAdoptcall =>
		pick d := f.data {
		Native =>
			if(d.i) {
				# a sync dispose method under await using
				call1(d.v, this, nil);
				return undef;
			}
			return call1(d.v, undef, array[] of {d.w});
		}
		return undef;
	NIPdisposed =>
		m := getmethod(this, a_return);
		if(m != nil)
			call(m, this, nil);
		return undef;
	NAIPdisposed =>
		cap := newcap();
		{
			m := getmethod(this, a_return);
			if(m == nil) {
				resolvecap(cap, undef);
				return objv(cap.promise);
			}
			r := call(m, this, nil);
			p := promiseresolve(promisector, r);
			ok := mknative(NPthunk, "", 0);
			ok.data = ref Data.Native(undef, undef, 0, nil);
			performthen(p, ref React(0, ok, cap, 0, nil), ref React(1, nil, cap, 0, nil));
		} exception {
		"JS" =>
			rejectcap(cap, thrown);
		}
		return objv(cap.promise);
	}
	throwerr(EError, "unknown disposal built-in");
	return undef;
}

# ---- async built-ins as coroutines ----

asyncnative(nat: int, this: V, args: array of V): V
{
	g := ref Gen;
	g.kind = Kasync;
	g.nat = nat;
	g.nthis = this;
	g.natargs = args;
	g.cap = newcap();
	g.depth = depth;
	g.state = Gstart;
	r := resume(g, Mnext, undef);
	asyncstep(g, r);
	return objv(g.cap.promise);
}

# run on the coroutine
natasync(g: ref Gen): V
{
	this := g.nthis;
	args := g.natargs;
	case g.nat {
	Xdisposeasync =>
		d := dsdata(this, Cadispstack, "AsyncDisposableStack.prototype.disposeAsync");
		if(d.disposed)
			return undef;
		d.disposed = 1;
		res := dsres(d);
		d.stack = nil;
		err := disposeall(res, V(Thole, 0, 0.0, nil, nil), 1);
		if(err.t != Thole)
			throwv(err);
		return undef;
	Xfromasync =>
		return fromasync(this, args);
	}
	return undef;
}

# Array.fromAsync
fromasync(this: V, args: array of V): V
{
	items := arg(args, 0);
	mapfn := arg(args, 1);
	t := arg(args, 2);
	if(mapfn.t != Tundef && !iscallable(mapfn))
		throwtype(showv(mapfn) + " is not a function");
	usector := this.t == Tobj && isctor(this.o);
	am := getmethod(items, a_symasynciterator);
	sm: ref Obj;
	if(am == nil)
		sm = getmethod(items, a_symiterator);
	if(am != nil || sm != nil) {
		a: ref Obj;
		if(usector)
			a = construct(this.o, nil, this.o).o;
		else
			a = newarray(0);
		it: V;
		if(am != nil) {
			it = call(am, items, nil);
			if(it.t != Tobj)
				throwtype("Result of the Symbol.asyncIterator method is not an object");
		} else {
			sit := call(sm, items, nil);
			if(sit.t != Tobj)
				throwtype("Result of the Symbol.iterator method is not an object");
			it = objv(asyncfromsync(sit));
		}
		next := getvalue(it, a_next);
		k := 0.0;
		for(;;) {
			r := await(call1(next, it, nil));
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done))) {
				setlength(a, k);
				return objv(a);
			}
			v := getv(r.o, a_value);
			{
				if(mapfn.t != Tundef)
					v = await(call(mapfn.o, t, array[] of {v, numv(k)}));
				createdatathrow(a, realkey(k), v);
			} exception {
			"JS" =>
				ex := thrown;
				{
					asynciterclose(it);
				} exception {
				"JS" =>
					;
				}
				throwv(ex);
			}
			k += 1.0;
		}
	}
	src := toobj(items);
	n := lengthof(src);
	a: ref Obj;
	if(usector)
		a = construct(this.o, array[] of {numv(n)}, this.o).o;
	else
		a = arraycreate(n);
	for(k := 0.0; k < n; k += 1.0) {
		v := await(gidx(src, k, objv(src)));
		if(mapfn.t != Tundef)
			v = await(call(mapfn.o, t, array[] of {v, numv(k)}));
		createdatathrow(a, realkey(k), v);
	}
	setlength(a, n);
	return objv(a);
}
