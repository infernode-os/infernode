#
# jsdispose.b - explicit resource management: using's resources,
# SuppressedError, DisposableStack and AsyncDisposableStack,
# Symbol.dispose and Symbol.asyncDispose.  Included by js.b.
#

asymdispose, asymasyncdispose, isupperrproto, idispstackproto, iasyncdispstackproto: int;

disposeinit()
{
	asymdispose = wellknown("dispose");
	asymasyncdispose = wellknown("asyncDispose");
	sym := get(iglobal, intern("Symbol"), objv(iglobal));
	defown(sym.x, intern("dispose"), 0, V(Tsym, asymdispose, 0.0));
	defown(sym.x, intern("asyncDispose"), 0, V(Tsym, asymasyncdispose, 0.0));

	isupperrproto = keep(newobj(Kord, ierrorproto));
	c := ctor("SuppressedError", 3, suppressedctor, isupperrproto);
	oproto[c] = ierrorctors[Error];
	value(isupperrproto, "name", strv("SuppressedError"));
	value(isupperrproto, "message", strv(""));

	idispstackproto = keep(newobj(Kord, iobjproto));
	ctor("DisposableStack", 0, dispstackctor, idispstackproto);
	p := idispstackproto;
	getter(p, intern("disposed"), "disposed", ds_disposed);
	dispose := method(p, "dispose", 0, ds_dispose);
	defown(p, asymdispose, Awrite|Aconf, objv(dispose));
	method(p, "use", 1, ds_use);
	method(p, "adopt", 2, ds_adopt);
	method(p, "defer", 1, ds_defer);
	method(p, "move", 0, ds_move);
	tag(p, "DisposableStack");

	iasyncdispstackproto = keep(newobj(Kord, iobjproto));
	ctor("AsyncDisposableStack", 0, adispstackctor, iasyncdispstackproto);
	p = iasyncdispstackproto;
	getter(p, intern("disposed"), "disposed", ads_disposed);
	da := method(p, "disposeAsync", 0, ads_disposeasync);
	defown(p, asymasyncdispose, Awrite|Aconf, objv(da));
	method(p, "use", 1, ads_use);
	method(p, "adopt", 2, ads_adopt);
	method(p, "defer", 1, ads_defer);
	method(p, "move", 0, ads_move);
	tag(p, "AsyncDisposableStack");

	symmethod(iiterproto, asymdispose, "[Symbol.dispose]", 0, iterproto_dispose);
	symmethod(iasynciterproto, asymasyncdispose, "[Symbol.asyncDispose]", 0, asynciterproto_dispose);
}

suppressed(err, supp: V): int
{
	h := newobj(Kerror, isupperrproto);
	odata[h] = ref Data.Error(errtrace());
	defown(h, intern("error"), Awrite|Aconf, err);
	defown(h, intern("suppressed"), Awrite|Aconf, supp);
	return h;
}

suppressedctor(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		nt = objv(f);
	h := newobj(Kerror, protofromctor(nt, isupperrproto));
	odata[h] = ref Data.Error(errtrace());
	sp0 := sp;
	push(objv(h));
	msg := arg(a, n, 2);
	if(msg.t != Tundef)
		defown(h, amessage, Awrite|Aconf, tostrv(msg));
	defown(h, intern("error"), Awrite|Aconf, arg(a, n, 0));
	defown(h, intern("suppressed"), Awrite|Aconf, arg(a, n, 1));
	sp = sp0;
	return objv(h);
}

# a resource record: [value, method, awaited]
resource(v: V, async: int): V
{
	if(v.t == Tundef || v.t == Tnull) {
		if(!async)
			return undef;
		return objv(arrayof(array[] of {undef, undef, vtrue}));
	}
	if(v.t != Tobj)
		typeerr(show(v) + " is not an object, so it cannot be disposed of");
	m := undef;
	awaited := 1;
	if(async) {
		m = getmethod(v, asymasyncdispose);
		if(m.t == Tundef) {
			m = getmethod(v, asymdispose);
			awaited = 0;
		}
	} else {
		m = getmethod(v, asymdispose);
		awaited = 0;
	}
	if(m.t == Tundef) {
		mn := "dispose";
		if(async)
			mn = "asyncDispose";
		typeerr(show(v) + " has no Symbol." + mn + " method");
	}
	return objv(arrayof(array[] of {v, m, bool(awaited)}));
}

addresource(stack: int, v: V, async: int)
{
	r := resource(v, async);
	if(r.t != Tundef)
		arrpush(stack, r);
}

# dispose of a stack's resources (sync), last first; the error to throw, or empty
disposeall(stack: int, err: V): V
{
	sp0 := sp;
	push(objv(stack));
	while(onelem[stack] > 0) {
		n := onelem[stack];
		rec := oelems[stack][n-1];
		oelems[stack][n-1] = empty;
		onelem[stack] = n - 1;
		oalen[stack] = real (n - 1);
		v := oelems[rec.x][0];
		m := oelems[rec.x][1];
		if(m.t == Tundef)
			continue;
		{
			call(m, v, nil);
		} exception e {
		"js:throw" =>
			if(err.t == Tempty)
				err = thrown;
			else
				err = objv(suppressed(thrown, err));
			push(err);
		}
	}
	sp = sp0;
	return err;
}

# ---- DisposableStack ----

# the stack's state: its resource array in odata's Prim, disposed when the array is nil
dsdata(this: V, kind: int, name: string): ref Data.Prim
{
	if(this.t == Tobj && okind[this.x] == kind)
		pick d := odata[this.x] {
		Prim =>
			return d;
		}
	typeerr(name + " called on incompatible receiver " + show(this));
	return nil;
}

Kdispstack: con Kmodns + 1;
Kadispstack: con Kmodns + 2;

dispstackctor(nil: V, nil, nil: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor DisposableStack requires 'new'");
	h := newobj(Kdispstack, protofromctor(nt, idispstackproto));
	odata[h] = ref Data.Prim(objv(newarray(0)));
	f = 0;
	return objv(h);
}

ds_disposed(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := dsdata(this, Kdispstack, "get DisposableStack.prototype.disposed");
	return bool(d.v.t != Tobj);
}

ds_dispose(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := dsdata(this, Kdispstack, "DisposableStack.prototype.dispose");
	if(d.v.t != Tobj)
		return undef;
	stack := d.v.x;
	d.v = undef;
	err := disposeall(stack, empty);
	if(err.t != Tempty)
		throwv(err);
	return undef;
}

dslive(this: V, kind: int, name: string): int
{
	d := dsdata(this, kind, name);
	if(d.v.t != Tobj)
		throwerr(ReferenceError, name + ": the stack is already disposed");
	return d.v.x;
}

ds_use(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kdispstack, "DisposableStack.prototype.use");
	v := arg(a, n, 0);
	addresource(stack, v, 0);
	return v;
}

ds_adopt(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kdispstack, "DisposableStack.prototype.adopt");
	v := arg(a, n, 0);
	f := arg(a, n, 1);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	c := nativefn("", 0, adoptcall);
	setcap(c, array[] of {v, f});
	arrpush(stack, objv(arrayof(array[] of {undef, objv(c), vfalse})));
	return v;
}

adoptcall(nil: V, nil, nil: int, nil: V, f: int): V
{
	return call(capof(f, 1), undef, array[] of {capof(f, 0)});
}

ds_defer(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kdispstack, "DisposableStack.prototype.defer");
	f := arg(a, n, 0);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	arrpush(stack, objv(arrayof(array[] of {undef, f, vfalse})));
	return undef;
}

ds_move(this: V, nil, nil: int, nil: V, nil: int): V
{
	stack := dslive(this, Kdispstack, "DisposableStack.prototype.move");
	d := dsdata(this, Kdispstack, "");
	h := newobj(Kdispstack, idispstackproto);
	odata[h] = ref Data.Prim(objv(stack));
	d.v = undef;
	return objv(h);
}

# ---- AsyncDisposableStack ----

adispstackctor(nil: V, nil, nil: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor AsyncDisposableStack requires 'new'");
	h := newobj(Kadispstack, protofromctor(nt, iasyncdispstackproto));
	odata[h] = ref Data.Prim(objv(newarray(0)));
	f = 0;
	return objv(h);
}

ads_disposed(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := dsdata(this, Kadispstack, "get AsyncDisposableStack.prototype.disposed");
	return bool(d.v.t != Tobj);
}

ads_use(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kadispstack, "AsyncDisposableStack.prototype.use");
	v := arg(a, n, 0);
	addresource(stack, v, 1);
	return v;
}

ads_adopt(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kadispstack, "AsyncDisposableStack.prototype.adopt");
	v := arg(a, n, 0);
	f := arg(a, n, 1);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	c := nativefn("", 0, adoptcall);
	setcap(c, array[] of {v, f});
	arrpush(stack, objv(arrayof(array[] of {undef, objv(c), vtrue})));
	return v;
}

ads_defer(this: V, a, n: int, nil: V, nil: int): V
{
	stack := dslive(this, Kadispstack, "AsyncDisposableStack.prototype.defer");
	f := arg(a, n, 0);
	if(!iscallable(f))
		typeerr(show(f) + " is not a function");
	arrpush(stack, objv(arrayof(array[] of {undef, f, vtrue})));
	return undef;
}

ads_move(this: V, nil, nil: int, nil: V, nil: int): V
{
	stack := dslive(this, Kadispstack, "AsyncDisposableStack.prototype.move");
	d := dsdata(this, Kadispstack, "");
	h := newobj(Kadispstack, iasyncdispstackproto);
	odata[h] = ref Data.Prim(objv(stack));
	d.v = undef;
	return objv(h);
}

# disposeAsync: a promise; each resource's result is awaited before the next
ads_disposeasync(this: V, nil, nil: int, nil: V, nil: int): V
{
	pr := newpromise(ipromisector);
	sp0 := sp;
	push(objv(pr));
	d: ref Data.Prim;
	if(this.t == Tobj && okind[this.x] == Kadispstack)
		pick x := odata[this.x] {
		Prim =>
			d = x;
		}
	if(d == nil) {
		rejectpromise(pr, objv(newerror(TypeError, "AsyncDisposableStack.prototype.disposeAsync called on incompatible receiver")));
		sp = sp0;
		return objv(pr);
	}
	if(d.v.t != Tobj) {
		resolvepromise(pr, undef);
		sp = sp0;
		return objv(pr);
	}
	stack := d.v.x;
	d.v = undef;
	# a state object: the stack, the promise, the error so far
	st := newobj(Kord, -1);
	oelems[st] = array[] of {objv(stack), objv(pr), empty};
	onelem[st] = 3;
	adsstep(st);
	sp = sp0;
	return objv(pr);
}

adsstep(st: int)
{
	stack := oelems[st][0].x;
	pr := oelems[st][1].x;
	for(;;) {
		if(onelem[stack] == 0) {
			err := oelems[st][2];
			if(err.t != Tempty)
				rejectpromise(pr, err);
			else
				resolvepromise(pr, undef);
			return;
		}
		n := onelem[stack];
		rec := oelems[stack][n-1];
		oelems[stack][n-1] = empty;
		onelem[stack] = n - 1;
		oalen[stack] = real (n - 1);
		v := oelems[rec.x][0];
		m := oelems[rec.x][1];
		awaited := truthy(oelems[rec.x][2]);
		r := undef;
		{
			if(m.t != Tundef)
				r = call(m, v, nil);
		} exception e {
		"js:throw" =>
			adsaccum(st, thrown);
			continue;
		}
		if(!awaited && m.t != Tundef)
			r = undef;
		# await r, then continue
		p := promiseresolve(ipromisector, r);
		onf := nativefn("", 1, adsfulfilled);
		onr := nativefn("", 1, adsrejected);
		setcap(onf, array[] of {objv(st)});
		setcap(onr, array[] of {objv(st)});
		performthen(p, objv(onf), objv(onr), -1);
		return;
	}
}

adsaccum(st: int, x: V)
{
	e := oelems[st][2];
	if(e.t == Tempty)
		oelems[st][2] = x;
	else
		oelems[st][2] = objv(suppressed(x, e));
}

adsfulfilled(nil: V, nil, nil: int, nil: V, f: int): V
{
	adsstep(capof(f, 0).x);
	return undef;
}

adsrejected(nil: V, a, n: int, nil: V, f: int): V
{
	st := capof(f, 0).x;
	adsaccum(st, arg(a, n, 0));
	adsstep(st);
	return undef;
}

# %IteratorPrototype%[Symbol.dispose] and %AsyncIteratorPrototype%[Symbol.asyncDispose]
iterproto_dispose(this: V, nil, nil: int, nil: V, nil: int): V
{
	ret := getmethod(this, areturn);
	if(ret.t != Tundef)
		call(ret, this, nil);
	return undef;
}

asynciterproto_dispose(this: V, nil, nil: int, nil: V, nil: int): V
{
	pr := newpromise(ipromisector);
	{
		ret := getmethod(this, areturn);
		if(ret.t == Tundef)
			resolvepromise(pr, undef);
		else {
			r := call(ret, this, array[] of {undef});
			p := promiseresolve(ipromisector, r);
			u := nativefn("", 0, returnundefined);
			(res, rej) := resolvingfns(pr);
			performthencap(p, objv(u), undef, pr, objv(res), objv(rej));
		}
	} exception e {
	"js:throw" =>
		rejectpromise(pr, thrown);
	}
	return objv(pr);
}

returnundefined(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return undef;
}
