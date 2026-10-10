#
# jsrt.b - what the interpreter calls on: generators, async functions,
# promises and the job queue, iteration, for-in, arguments objects,
# templates, spread, eval.  Included by js.b.
#

# ---- generators and async functions ----

Gstart, Gsuspended, Grunning, Gdone: con iota;

Genstate: adt {
	state:	int;
	code:	ref Code;
	fnh:	int;		# the function object
	regs:	array of V;	# the frame's registers while suspended
	pc:	int;
	resumereg:	int;	# where a resumption's value goes
	modereg:	int;	# yield*: where its mode goes, or -1
	out:	V;		# what it yielded or awaited
	awaiting:	int;	# it stopped at an await
	result:	V;		# what it returned
	async:	int;
	promise:	int;	# an async function's promise
	genobj:	int;	# the generator object
	queue:	list of ref Asyncreq;	# an async generator's requests
	raw:	int;		# out is an iterator result already (yield*)
};

Asyncreq: adt {
	mode:	int;		# 0 next, 1 throw, 2 return
	v:	V;
	promise:	int;
};

Rnext, Rthrow, Rreturn: con iota;

markgen(g: ref Genstate)
{
	if(g == nil)
		return;
	marko(g.fnh);
	for(i := 0; i < len g.regs; i++)
		markv(g.regs[i]);
	markv(g.out);
	markv(g.result);
	marko(g.promise);
	marko(g.genobj);
	for(l := g.queue; l != nil; l = tl l) {
		markv((hd l).v);
		marko((hd l).promise);
	}
	markcode(g.code);
}

markcode(c: ref Code)
{
	if(c == nil || c.marked == ncollect)
		return;
	c.marked = ncollect;
	for(i := 0; i < len c.tmplcache; i++)
		if(c.tmplcache[i] >= 0)
			marko(c.tmplcache[i]);
	for(i = 0; i < len c.funcs; i++)
		markcode(c.funcs[i]);
}

# frames, jobs and the rest the collector must see
markroots()
{
	for(i := 0; i < nframe; i++) {
		markcode(frames[i].code);
		markgen(frames[i].gen);
	}
	for(l := jobs; l != nil; l = tl l)
		markjob(hd l);
	for(l = jobstail; l != nil; l = tl l)
		markjob(hd l);
	markv(thrown);
	markv(genretval);
	for(i = 0; i < len globalcodes; i++)
		markcode(globalcodes[i]);
	for(b := 0; glex != nil && b < len glex; b++)
		for(gl := glex[b]; gl != nil; gl = tl gl)
			markv(*(hd gl).t1);
	for(rl := rootstk; rl != nil; rl = tl rl)
		markv(hd rl);
	markmods();
}

rootstk: list of V;		# values Limbo code holds across calls back into script
globalcodes: array of ref Code;

# a generator or async function called: its state, without running (generators) or run to its first await (async)
startgen(h: int, d: ref Data.Func, this: V, a, n: int): V
{
	c := d.code;
	g := ref Genstate(Gstart, c, h, nil, 0, -1, -1, undef, 0, undef, (c.flags & Casync) != 0, -1, -1, nil, 0);
	# the frame's registers, set up as for a call, then saved
	nb := sp;
	if(nb < a + n)
		nb = a + n;
	setupframe(h, d, c, nb, this, a, n, undef);
	g.regs = array[c.nregs] of V;
	g.regs[0:] = vs[nb:nb+c.nregs];
	sp = nb;
	if(c.flags & Cgen) {
		# parameters are bound (and defaults evaluated) before the generator is returned
		proto := getv(objv(h), aprototype);
		dflt := igenproto;
		if(c.flags & Casync)
			dflt = iasyncgenproto;
		p := dflt;
		if(proto.t == Tobj)
			p = proto.x;
		go := newobj(Kgen, p);
		odata[go] = ref Data.Gen(g);
		g.genobj = go;
		# run to the end of the parameter bindings: the body starts at the Ogenstart
		runprologue(g);
		return objv(go);
	}
	# async function: a promise; run now until the first await
	pr := newpromise(ipromisector);
	g.promise = pr;
	sp0 := sp;
	push(objv(pr));
	asyncstep(g, Rnext, undef);
	sp = sp0;
	return objv(pr);
}

# a generator's parameters are bound when it is called (their errors are the call's)
runprologue(g: ref Genstate)
{
	c := g.code;
	# find the Ogenstart: the body begins after it
	start := -1;
	for(i := 0; i < len c.ops; ) {
		if(c.ops[i] == Ogenstart) {
			start = i;
			break;
		}
		i += oplen(c.ops[i]);
	}
	if(start < 0)
		return;
	# run the prologue as a frame of its own
	r := resumegen(g, Rnext, undef, start);
	r = undef;
}

# resume generator g: mode and value; stopat: run only until this pc (the prologue), or -1
resumegen(g: ref Genstate, mode: int, v: V, stopat: int): V
{
	c := g.code;
	nb := sp;
	need := nb + c.nregs + 8;
	if(need > len vs)
		growvs(need);
	vs[nb:] = g.regs[0:c.nregs];
	sp = nb + c.nregs;
	g.state = Grunning;
	pushframe(Frame(c, nb, g.pc, -1, 0, g, 1));
	if(stopat >= 0) {
		# the prologue: run to the Ogenstart, then suspend there
		return runto(g, stopat);
	}
	if(g.resumereg >= 0) {
		if(g.modereg >= 0) {
			vs[nb+g.resumereg] = v;
			vs[nb+g.modereg] = num(real mode);
		} else {
			case mode {
			Rnext =>
				vs[nb+g.resumereg] = v;
			Rthrow =>
				return resumethrow(g, v);
			Rreturn =>
				return resumereturn(g, v);
			}
		}
	}
	return run();
}

# run until the generator's frame reaches pc stop
runto(g: ref Genstate, stop: int): V
{
	# put a temporary suspension at the stop: the loop yields when it meets Ogenstart
	c := g.code;
	saved := c.ops[stop];
	c.ops[stop] = Oyield;
	ins := array[3] of int;
	ins[0:] = c.ops[stop:stop+3];
	c.ops[stop+1] = Rarg0;
	c.ops[stop+2] = Rarg0;
	{
		run();
	} exception e {
	"*" =>
		c.ops[stop:] = ins;
		c.ops[stop] = saved;
		raise e;
	}
	c.ops[stop:] = ins;
	c.ops[stop] = saved;
	g.pc = stop + 1;
	g.resumereg = -1;
	g.state = Gstart;
	return undef;
}

# throw v at the generator's current yield
resumethrow(nil: ref Genstate, v: V): V
{
	thrown = v;
	return runfrom(1);
}

# return v from the generator's current yield, through its finally blocks
resumereturn(g: ref Genstate, v: V): V
{
	genretval = v;
	r := runfrom(2);
	if(g.state != Gsuspended) {
		g.state = Gdone;
		g.result = r;
	}
	return r;
}

# generator.prototype.next/throw/return for a sync generator: the iterator result
genresume(gv: V, mode: int, v: V, name: string): V
{
	if(gv.t != Tobj || okind[gv.x] != Kgen)
		typeerr("Generator.prototype." + name + " called on incompatible receiver");
	g: ref Genstate;
	pick d := odata[gv.x] {
	Gen =>
		g = d.g;
	}
	if(g.async)
		typeerr("Generator.prototype." + name + " called on incompatible receiver");
	case g.state {
	Grunning =>
		typeerr("generator is already running");
	Gdone =>
		case mode {
		Rthrow => throwv(v);
		Rreturn => return iterresult(v, 1);
		}
		return iterresult(undef, 1);
	Gstart =>
		case mode {
		Rthrow =>
			g.state = Gdone;
			throwv(v);
		Rreturn =>
			g.state = Gdone;
			return iterresult(v, 1);
		}
	}
	sp0 := sp;
	push(gv);
	push(v);
	r: V;
	{
		r = resumegen(g, mode, v, -1);
	} exception e {
	"js:throw" =>
		g.state = Gdone;
		sp = sp0;
		raise e;
	}
	sp = sp0;
	if(g.state == Gdone)
		return iterresult(g.result, 1);
	if(g.raw)
		return g.out;
	return iterresult(g.out, 0);
}

iterresult(v: V, done: int): V
{
	h := newplain();
	addprop(h, avalue, Adefault, v);
	addprop(h, adone, Adefault, bool(done));
	return objv(h);
}

# run an async function until it awaits or finishes
asyncstep(g: ref Genstate, mode: int, v: V)
{
	r: V;
	{
		if(g.state == Gstart && mode == Rnext)
			r = resumegen(g, Rnext, undef, -1);
		else
			r = resumegen(g, mode, v, -1);
	} exception e {
	"js:throw" =>
		g.state = Gdone;
		rejectpromise(g.promise, thrown);
		return;
	}
	if(g.state == Gdone) {
		resolvepromise(g.promise, r);
		return;
	}
	# awaiting r: resume when it settles
	awaitvalue(g, r);
}

# Await: resume g with the value's settlement
awaitvalue(g: ref Genstate, v: V)
{
	p := promiseresolve(ipromisector, v);
	onfulfil := nativefn("", 1, asyncfulfilled);
	onreject := nativefn("", 1, asyncrejected);
	setcap(onfulfil, array[] of {objv(g.fnh)});
	setcap(onreject, array[] of {objv(g.fnh)});
	gens = (g.fnh, g) :: gens;
	performthen(p, objv(onfulfil), objv(onreject), -1);
}

# suspended async functions, by function object (the job holds the function)
gens: list of (int, ref Genstate);

asyncfulfilled(nil: V, a, n: int, nil: V, f: int): V
{
	g := takegen(f);
	if(g != nil) {
		if(g.genobj >= 0 && g.async && g.code.flags & Cgen)
			asyncgenstep(g, Rnext, arg(a, n, 0));
		else
			asyncstep(g, Rnext, arg(a, n, 0));
	}
	return undef;
}

asyncrejected(nil: V, a, n: int, nil: V, f: int): V
{
	g := takegen(f);
	if(g != nil) {
		if(g.genobj >= 0 && g.async && g.code.flags & Cgen)
			asyncgenstep(g, Rthrow, arg(a, n, 0));
		else
			asyncstep(g, Rthrow, arg(a, n, 0));
	}
	return undef;
}

takegen(f: int): ref Genstate
{
	fv := capof(f, 0);
	g: ref Genstate;
	r: list of (int, ref Genstate);
	for(l := gens; l != nil; l = tl l) {
		(h, x) := hd l;
		if(g == nil && h == fv.x && x.state == Gsuspended)
			g = x;
		else
			r = hd l :: r;
	}
	gens = r;
	return g;
}

# ---- async generators (§27.6) ----

asyncgenenqueue(gv: V, mode: int, v: V): V
{
	pr := newpromise(ipromisector);
	g: ref Genstate;
	if(gv.t == Tobj && okind[gv.x] == Kgen)
		pick d := odata[gv.x] {
		Gen =>
			g = d.g;
		}
	if(g == nil || !g.async) {
		rejectpromise(pr, objv(newerror(TypeError, "not an async generator")));
		return objv(pr);
	}
	req := ref Asyncreq(mode, v, pr);
	g.queue = appendreq(g.queue, req);
	if(g.state != Grunning && !(g.state == Gsuspended && g.awaiting))
		asyncgendrain(g);
	return objv(pr);
}

appendreq(l: list of ref Asyncreq, r: ref Asyncreq): list of ref Asyncreq
{
	if(l == nil)
		return r :: nil;
	return hd l :: appendreq(tl l, r);
}

# serve the queue's head
asyncgendrain(g: ref Genstate)
{
	while(g.queue != nil) {
		req := hd g.queue;
		case g.state {
		Gdone =>
			case req.mode {
			Rnext =>
				g.queue = tl g.queue;
				resolvepromise(req.promise, iterresult(undef, 1));
				continue;
			Rthrow =>
				g.queue = tl g.queue;
				rejectpromise(req.promise, req.v);
				continue;
			Rreturn =>
				# await the value, then resolve done
				g.state = Grunning;
				p := promiseresolve(ipromisector, req.v);
				onf := nativefn("", 1, asyncgenretfulfilled);
				onr := nativefn("", 1, asyncgenretrejected);
				setcap(onf, array[] of {objv(g.genobj)});
				setcap(onr, array[] of {objv(g.genobj)});
				performthen(p, objv(onf), objv(onr), -1);
				return;
			}
		Gstart =>
			if(req.mode != Rnext) {
				g.state = Gdone;
				continue;
			}
			asyncgenstep(g, Rnext, req.v);
			return;
		Gsuspended =>
			asyncgenstep(g, req.mode, req.v);
			return;
		* =>
			return;
		}
	}
}

asyncgenretfulfilled(nil: V, a, n: int, nil: V, f: int): V
{
	gv := capof(f, 0);
	pick d := odata[gv.x] {
	Gen =>
		g := d.g;
		g.state = Gdone;
		req := hd g.queue;
		g.queue = tl g.queue;
		resolvepromise(req.promise, iterresult(arg(a, n, 0), 1));
		asyncgendrain(g);
	}
	return undef;
}

asyncgenretrejected(nil: V, a, n: int, nil: V, f: int): V
{
	gv := capof(f, 0);
	pick d := odata[gv.x] {
	Gen =>
		g := d.g;
		g.state = Gdone;
		req := hd g.queue;
		g.queue = tl g.queue;
		rejectpromise(req.promise, arg(a, n, 0));
		asyncgendrain(g);
	}
	return undef;
}

asyncgenstep(g: ref Genstate, mode: int, v: V)
{
	r: V;
	{
		r = resumegen(g, mode, v, -1);
	} exception e {
	"js:throw" =>
		g.state = Gdone;
		req := hd g.queue;
		g.queue = tl g.queue;
		rejectpromise(req.promise, thrown);
		asyncgendrain(g);
		return;
	}
	if(g.state == Gdone) {
		req := hd g.queue;
		g.queue = tl g.queue;
		resolvepromise(req.promise, iterresult(r, 1));
		asyncgendrain(g);
		return;
	}
	if(g.awaiting) {
		awaitvalue(g, r);
		return;
	}
	# a yield: resolve the head request
	req := hd g.queue;
	g.queue = tl g.queue;
	resolvepromise(req.promise, iterresult(r, 0));
	if(g.queue != nil)
		asyncgendrain(g);
}

# ---- promises (§27.2) ----

Ppending, Pfulfilled, Prejected: con iota;

Reaction: adt {
	promise:	int;	# the derived promise, or -1
	resolve, reject:	V;	# its capability's functions
	onfulfil, onreject:	V;
};

markreaction(r: ref Reaction)
{
	marko(r.promise);
	markv(r.resolve);
	markv(r.reject);
	markv(r.onfulfil);
	markv(r.onreject);
}

Job: adt {
	pick {
	React =>
		r:	ref Reaction;
		fulfilled:	int;
		v:	V;
	Thenable =>
		promise:	int;
		thenable:	V;
		then:	V;
	Call =>
		f:	V;
		args:	array of V;
	}
};

jobs: list of ref Job;
jobstail: list of ref Job;	# reversed: added at the head, moved to jobs when it runs dry

markjob(j: ref Job)
{
	pick x := j {
	React =>
		markreaction(x.r);
		markv(x.v);
	Thenable =>
		marko(x.promise);
		markv(x.thenable);
		markv(x.then);
	Call =>
		markv(x.f);
		for(i := 0; i < len x.args; i++)
			markv(x.args[i]);
	}
}

njobs := 0;
Maxjobs: con 1000000;

enqueue(j: ref Job)
{
	if(++njobs > Maxjobs) {
		njobs = 0;
		jobs = nil;
		jobstail = nil;
		throwerr(RangeError, "out of memory: too many pending jobs");
	}
	jobstail = j :: jobstail;
}

# run the job queue until it is empty
runjobs()
{
	for(;;) {
		if(jobs == nil) {
			if(jobstail == nil)
				return;
			for(; jobstail != nil; jobstail = tl jobstail)
				jobs = hd jobstail :: jobs;
		}
		j := hd jobs;
		jobs = tl jobs;
		njobs--;
		sp0 := sp;
		{
			runjob(j);
		} exception e {
		"js:throw" =>
			reportuncaught(thrown);
		}
		sp = sp0;
		if(gcwanted && nframe == 0)
			collect();
	}
}

runjob(j: ref Job)
{
	pick x := j {
	React =>
		r := x.r;
		handler := r.onreject;
		if(x.fulfilled)
			handler = r.onfulfil;
		res: V;
		threw := 0;
		if(handler.t == Tundef) {
			res = x.v;
			threw = !x.fulfilled;
		} else {
			{
				res = call(handler, undef, array[] of {x.v});
			} exception e {
			"js:throw" =>
				res = thrown;
				threw = 1;
			}
		}
		if(r.promise < 0 && r.resolve.t == Tundef)
			return;
		if(threw)
			call(r.reject, undef, array[] of {res});
		else
			call(r.resolve, undef, array[] of {res});
	Thenable =>
		(res, rej) := resolvingfns(x.promise);
		{
			call(x.then, x.thenable, array[] of {objv(res), objv(rej)});
		} exception e {
		"js:throw" =>
			call(objv(rej), undef, array[] of {thrown});
		}
	Call =>
		call(x.f, undef, x.args);
	}
}

newpromise(nil: int): int
{
	h := newobj(Kpromise, ipromiseproto);
	odata[h] = ref Data.Promise(Ppending, undef, nil, 0);
	return h;
}

promisedata(h: int): ref Data.Promise
{
	pick d := odata[h] {
	Promise =>
		return d;
	}
	return nil;
}

# CreateResolvingFunctions
resolvingfns(p: int): (int, int)
{
	flag := newobj(Kord, -1);	# shared alreadyResolved: its first slot
	res := nativefn("", 1, resolvefn);
	rej := nativefn("", 1, rejectfn);
	setcap(res, array[] of {objv(p), objv(flag)});
	setcap(rej, array[] of {objv(p), objv(flag)});
	return (res, rej);
}

alreadyresolved(f: int): int
{
	flag := capof(f, 1).x;
	if(oflags[flag] & Ohtmldda)
		return 1;
	oflags[flag] |= Ohtmldda;	# (used as a mark on this private object)
	return 0;
}

resolvefn(nil: V, a, n: int, nil: V, f: int): V
{
	if(alreadyresolved(f))
		return undef;
	p := capof(f, 0).x;
	resolvepromise(p, arg(a, n, 0));
	return undef;
}

rejectfn(nil: V, a, n: int, nil: V, f: int): V
{
	if(alreadyresolved(f))
		return undef;
	p := capof(f, 0).x;
	rejectpromise(p, arg(a, n, 0));
	return undef;
}

# resolve p with v (a value or thenable)
resolvepromise(p: int, v: V)
{
	d := promisedata(p);
	if(d == nil || d.state != Ppending)
		return;
	if(v.t == Tobj && v.x == p) {
		rejectpromise(p, objv(newerror(TypeError, "chaining cycle detected for promise")));
		return;
	}
	if(v.t != Tobj) {
		fulfilpromise(p, v);
		return;
	}
	then: V;
	{
		then = getv(v, athen);
	} exception e {
	"js:throw" =>
		rejectpromise(p, thrown);
		return;
	}
	if(!iscallable(then)) {
		fulfilpromise(p, v);
		return;
	}
	enqueue(ref Job.Thenable(p, v, then));
}

fulfilpromise(p: int, v: V)
{
	d := promisedata(p);
	if(d.state != Ppending)
		return;
	rs := d.reactions;
	d.state = Pfulfilled;
	d.result = v;
	d.reactions = nil;
	for(l := revreact(rs); l != nil; l = tl l)
		enqueue(ref Job.React(hd l, 1, v));
}

rejectpromise(p: int, v: V)
{
	d := promisedata(p);
	if(d == nil || d.state != Ppending)
		return;
	rs := d.reactions;
	d.state = Prejected;
	d.result = v;
	d.reactions = nil;
	for(l := revreact(rs); l != nil; l = tl l)
		enqueue(ref Job.React(hd l, 0, v));
}

revreact(l: list of ref Reaction): list of ref Reaction
{
	r: list of ref Reaction;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# PerformPromiseThen; derived: the result promise (with its resolving functions taken from cap), or -1
performthen(p: int, onf, onr: V, derived: int)
{
	performthencap(p, onf, onr, derived, undef, undef);
}

performthencap(p: int, onf, onr: V, derived: int, res, rej: V)
{
	if(!iscallable(onf))
		onf = undef;
	if(!iscallable(onr))
		onr = undef;
	r := ref Reaction(derived, res, rej, onf, onr);
	d := promisedata(p);
	case d.state {
	Ppending =>
		d.reactions = r :: d.reactions;
	Pfulfilled =>
		enqueue(ref Job.React(r, 1, d.result));
	Prejected =>
		enqueue(ref Job.React(r, 0, d.result));
	}
	d.handled = 1;
}

# PromiseResolve(C, x)
promiseresolve(c: int, x: V): int
{
	if(x.t == Tobj && okind[x.x] == Kpromise) {
		xc := getv(x, aconstructor);
		if(xc.t == Tobj && xc.x == c)
			return x.x;
	}
	p := newpromise(c);
	resolvepromise(p, x);
	return p;
}

# ---- native function helpers ----

nativefn(name: string, length: int, f: Native): int
{
	h := newobj(Knative, ifuncproto);
	oflags[h] |= Ocallable;
	odata[h] = ref Data.Native(f, name, nil);
	addprop(h, alength, Aconf, num(real length));
	addprop(h, aname, Aconf, V(Tstr, atomsh[intern(name)], 0.0));
	return h;
}

setcap(h: int, cap: array of V)
{
	pick d := odata[h] {
	Native =>
		d.cap = cap;
	}
}

capof(h: int, i: int): V
{
	pick d := odata[h] {
	Native =>
		if(i < len d.cap)
			return d.cap[i];
	}
	return undef;
}

# ---- iteration (§7.4) ----

# GetIterator: (the iterator, its next method)
getiterator(v: V, async: int): (V, V)
{
	m: V;
	if(async) {
		m = getmethod(v, asymasynciter);
		if(m.t == Tundef) {
			sm := getmethod(v, asymiterator);
			if(sm.t == Tundef)
				typeerr(show(v) + " is not async iterable");
			it := call(sm, v, nil);
			if(it.t != Tobj)
				typeerr("result of the Symbol.iterator method is not an object");
			next := getv(it, anext);
			return (objv(asyncfromsync(it, next)), getv(objv(asyncfromsync(it, next)), anext));
		}
	} else
		m = getmethod(v, asymiterator);
	if(m.t == Tundef)
		typeerr(show(v) + " is not iterable");
	it := call(m, v, nil);
	if(it.t != Tobj)
		typeerr("result of the Symbol.iterator method is not an object");
	return (it, getv(it, anext));
}

# IteratorStep: (value, done)
iterstep(it, next: V): (V, int)
{
	if(next.t == Tundef)
		return (undef, 1);
	r := call(next, it, nil);
	if(r.t != Tobj)
		typeerr("iterator result " + show(r) + " is not an object");
	if(truthy(getv(r, adone)))
		return (undef, 1);
	return (getv(r, avalue), 0);
}

iterclose(it: V)
{
	ret := getmethod(it, areturn);
	if(ret.t == Tundef)
		return;
	r := call(ret, it, nil);
	if(r.t != Tobj)
		typeerr("iterator result is not an object");
}

# yield*'s step: the inner iterator's next, throw or return (by mode) with v;
# done and res: the result's done, and (done) its value or (not) the result itself
ystep(resr, doner, itr: int, mode, v: V, async: int)
{
	it := vs[base+itr];
	m := int mode.n;
	r: V;
	case m {
	Rnext =>
		r = call(vs[base+itr+1], it, array[] of {v});
	Rthrow =>
		th := getmethod(it, athrow);
		if(th.t == Tundef) {
			# no throw: close it, then it is a protocol error
			if(async) {
				ret := getmethod(it, areturn);
				if(ret.t != Tundef)
					call(ret, it, nil);
			} else
				iterclose(it);
			typeerr("the iterator does not have a 'throw' method");
		}
		r = call(th, it, array[] of {v});
	* =>
		ret := getmethod(it, areturn);
		if(ret.t == Tundef) {
			vs[base+resr] = v;
			vs[base+doner] = vtrue;
			return;
		}
		r = call(ret, it, array[] of {v});
	}
	if(async) {
		# the result is awaited by the code that follows
		vs[base+resr] = r;
		vs[base+doner] = vfalse;
		return;
	}
	if(r.t != Tobj)
		typeerr("iterator result " + show(r) + " is not an object");
	d := truthy(getv(r, adone));
	vs[base+doner] = bool(d);
	if(d)
		vs[base+resr] = getv(r, avalue);
	else
		vs[base+resr] = r;
}

# CreateAsyncFromSyncIterator: a simple wrapper object
asyncfromsync(it, next: V): int
{
	h := newobj(Kiter, iasyncfromsyncproto);
	odata[h] = ref Data.Iter(1, it, 0, 0);
	defown(h, intern("%next"), 0, next);
	return h;
}

# ---- for-in (§14.7.5.9) ----

forinstart(v: V): int
{
	h := newobj(Kforin, -1);
	if(v.t == Tundef || v.t == Tnull) {
		odata[h] = ref Data.Forin(array[0] of int, 0, -1, nil);
		return h;
	}
	o := toobject(v);
	odata[h] = ref Data.Forin(forinkeys(o), 0, o, nil);
	return h;
}

# the enumerable string keys of o, then of its prototypes, not repeating
forinkeys(o: int): array of int
{
	seen: list of int;
	keys: list of int;
	for(p := o; p >= 0; p = getproto(p)) {
		ks := ownkeys(p);
		for(i := 0; i < len ks; i++) {
			k := ks[i];
			if(issymkey(k) || isprivkey(k))
				continue;
			if(hasint(seen, k))
				continue;
			seen = k :: seen;
			(found, d) := getown(p, k);
			if(found && (d.attrs & Aenum))
				keys = k :: keys;
		}
	}
	a := array[len keys] of int;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd keys;
		keys = tl keys;
	}
	return a;
}

hasint(l: list of int, k: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == k)
			return 1;
	return 0;
}

forinnext(h: int): (V, int)
{
	pick d := odata[h] {
	Forin =>
		while(d.i < len d.keys) {
			k := d.keys[d.i++];
			# a key deleted since is skipped
			if(d.obj >= 0 && !hasprop(d.obj, k))
				continue;
			return (keyval(k), 1);
		}
	}
	return (undef, 0);
}

# ---- arguments objects (§10.4.4) ----

argsobject(mapped: int): int
{
	all := vs[base+code.allreg].x;
	n := onelem[all];
	h := newobj(Kargs, iobjproto);
	e := array[n + 4] of V;
	e[0:] = oelems[all][0:n];
	oelems[h] = e;
	onelem[h] = n;
	addprop(h, alength, Awrite|Aconf, num(real n));
	addprop(h, asymiterator, Awrite|Aconf, objv(iarrvalues));
	if(mapped) {
		# each formal parameter's slot in the function's environment
		m := array[n] of {* => -1};
		fs := code.scopes;
		fenv := envreg();
		if(fenv >= 0 && len fs > 0) {
			pick ed := odata[fenv] {
			Env =>
				sc := ed.scope;
				for(i := 0; i < n && i < code.nparams; i++) {
					pname := paramname(code, i);
					if(pname < 0)
						continue;
					for(j := 0; sc != nil && j < len sc.names; j++)
						if(sc.names[j] == pname && sc.kinds[j] == Bparam)
							m[i] = j;
				}
			}
		}
		# a later parameter of the same name maps; earlier ones do not
		odata[h] = ref Data.Args(fenv, m);
	} else {
		odata[h] = ref Data.Args(-1, nil);
		thrower := objv(ithrowtypeerror);
		addprop(h, acallee, Aacc, V(Tacc, thrower.x, real thrower.x));
	}
	if(mapped)
		addprop(h, acallee, Awrite|Aconf, vs[base+Rfn]);
	return h;
}

# the name of parameter i (from the source of the code, kept by the compiler), or -1
paramname(c: ref Code, i: int): int
{
	if(c.paramnames == nil || i >= len c.paramnames)
		return -1;
	return c.paramnames[i];
}

argsmap(h, k: int): (int, int)
{
	pick d := odata[h] {
	Args =>
		if(d.map != nil && isidx(k)) {
			i := keyidx(k);
			if(i < len d.map && d.map[i] >= 0)
				return (d.env, d.map[i]);
		}
	}
	return (-1, -1);
}

argsgetown(h, k: int): (int, ref Desc)
{
	(ok, v, a) := getownprop(h, k);
	if(!ok)
		return (0, nil);
	(env, slot) := argsmap(h, k);
	if(env >= 0)
		v = oslots[env][slot];
	if(a & Aacc) {
		g := undef;
		s := undef;
		if(v.x >= 0)
			g = objv(v.x);
		if(v.n >= 0.0)
			s = objv(int v.n);
		return (1, ref Desc(Hget|Hset|Henum|Hconf, undef, g, s, a & (Aenum|Aconf)));
	}
	return (1, ref Desc(Hvalue|Hwrite|Henum|Hconf, v, undef, undef, a & (Awrite|Aenum|Aconf)));
}

argsdefine(h, k: int, d: ref Desc): int
{
	(env, slot) := argsmap(h, k);
	nd := d;
	if(env >= 0 && isdatadesc(d) && (d.has & Hvalue) == 0 && (d.has & Hwrite) && (d.attrs & Awrite) == 0) {
		nd = ref *d;
		nd.has |= Hvalue;
		nd.value = oslots[env][slot];
	}
	if(!ordinarydefine(h, k, nd))
		return 0;
	if(env >= 0) {
		if(isaccdesc(d))
			unmap(h, k);
		else {
			if(d.has & Hvalue)
				oslots[env][slot] = d.value;
			if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
				unmap(h, k);
		}
	}
	return 1;
}

argsdelete(h, k: int): int
{
	(found, d) := getown(h, k);
	if(!found)
		return 1;
	if((d.attrs & Aconf) == 0)
		return 0;
	removeown(h, k);
	unmap(h, k);
	return 1;
}

unmap(h, k: int)
{
	pick d := odata[h] {
	Args =>
		if(d.map != nil && isidx(k) && keyidx(k) < len d.map)
			d.map[keyidx(k)] = -1;
	}
}

# ---- templates, spread, object rest ----

templateobj(c: ref Code, i: int): int
{
	if(c.tmplcache[i] >= 0)
		return c.tmplcache[i];
	(cooked, raw) := c.tmpls[i];
	a := newarray(0);
	r := newarray(0);
	for(j := 0; j < len cooked; j++) {
		if(cooked[j] == nil && raw[j] != nil && 0)
			;
		cv := undef;
		if(cooked[j] != nil || raw[j] == "")
			cv = V(Tstr, atomsh[intern(cooked[j])], 0.0);
		if(cooked[j] == nil && raw[j] != "")
			cv = undef;
		arrpush(a, cv);
		arrpush(r, V(Tstr, atomsh[intern(raw[j])], 0.0));
	}
	freeze(r);
	defown(a, intern("raw"), 0, objv(r));
	freeze(a);
	c.tmplcache[i] = a;
	return a;
}

# SetIntegrityLevel frozen, for ordinary objects and arrays built here
freeze(h: int)
{
	e := oelems[h];
	n := onelem[h];
	if(n > 0) {
		spill(h);
		e = nil;
	}
	sh := ownshape(h);
	for(i := 0; i < sh.n; i++)
		if(sh.attrs[i] & Aacc)
			sh.attrs[i] &= ~Aconf;
		else
			sh.attrs[i] &= ~(Aconf|Awrite);
	if(okind[h] == Karray)
		oflags[h] |= Oarrlenro;
	oflags[h] &= ~Oext;
}

# [ ...v ]: v's values onto array h
spreadinto(h: int, v: V)
{
	# a plain array with the default iterator: its elements
	if(v.t == Tobj && okind[v.x] == Karray && arrayiterintact(v.x)) {
		s := v.x;
		n := int oalen[s];
		for(i := 0; i < n; i++) {
			e := undef;
			if(i < onelem[s] && oelems[s][i].t != Tempty)
				e = oelems[s][i];
			else
				e = get(s, idxkey(i), v);
			arrpush(h, e);
		}
		return;
	}
	(it, next) := getiterator(v, 0);
	sp0 := sp;
	push(it);
	push(next);
	for(;;) {
		(x, done) := iterstep(it, next);
		if(done)
			break;
		arrpush(h, x);
	}
	sp = sp0;
}

# whether array h iterates as arrays do by default
arrayiterintact(h: int): int
{
	if(oproto[h] != iarrproto || oshape[h].n != 0)
		return 0;
	(ok, f, a) := getownprop(iarrproto, asymiterator);
	if(!ok || (a & Aacc) || f.t != Tobj || f.x != iarrvalues)
		return 0;
	(ok2, nx, a2) := getownprop(iarrayiterproto, anext);
	return ok2 && (a2 & Aacc) == 0 && nx.t == Tobj && nx.x == iarriternext;
}

# CopyDataProperties(target, source, excluded)
copyprops(target: int, src: V, excl: V)
{
	if(src.t == Tundef || src.t == Tnull)
		return;
	s := toobject(src);
	sp0 := sp;
	push(objv(s));
	ks := ownkeys(s);
	for(i := 0; i < len ks; i++) {
		k := ks[i];
		if(isprivkey(k))
			continue;
		if(excl.t == Tobj && excluded(excl.x, k))
			continue;
		(found, d) := getown(s, k);
		if(found && (d.attrs & Aenum)) {
			v := get(s, k, objv(s));
			createdataorthrow(target, k, v);
		}
	}
	sp = sp0;
}

excluded(arr, k: int): int
{
	for(i := 0; i < onelem[arr]; i++) {
		kv := oelems[arr][i];
		if(tokey(kv) == k)
			return 1;
	}
	return 0;
}

# ---- eval ----

# PerformEval for a direct call: the argument, in the caller's scope
directeval(a, n: int, flags: int): V
{
	x := arg(a, n, 0);
	if(x.t != Tstr)
		return x;
	strictcaller := flags & 1;
	ctx := (flags >> 1) & 16r7F;
	privs: list of string;
	if(flags >> 8) {
		(nil, privs) = sys->tokenize(str(code.consts[(flags >> 8) - 1].x), " ");
	}
	if(code.flags & Ceval) {
		ctx |= code.evalctx;
		for(pl := code.evalprivs; pl != nil; pl = tl pl)
			privs = hd pl :: privs;
	}
	src := str(x.x);
	(prog, err) := jsparse->parseeval(src, strictcaller, ctx, privs);
	if(err != nil)
		throwerr(SyntaxError, err);
	pick p := prog {
	Program =>
		# in parameters, a sloppy eval may not declare var arguments
		if((ctx & 32) && !strictcaller && !p.strict)
			for(nl := varlist1(p.body, nil); nl != nil; nl = tl nl)
				if(hd nl == "arguments")
					throwerr(SyntaxError, "eval in parameters cannot declare 'arguments'");
		evalctxin = ctx & 31;
		evalprivsin = privs;
		c := compilescript(p, src, 1, strictcaller);
		evalctxin = 0;
		evalprivsin = nil;
		setfile(c, code.file);
		setmodid(c, code.modid);
		c.flags |= Ceval;
		if(strictcaller || p.strict)
			c.flags |= Cstrict;
		# eval code runs as a frame of the caller's: this, function, new.target, environment
		nb := sp;
		need := nb + c.nregs + 8;
		if(need > len vs)
			growvs(need);
		for(i := 0; i < c.nregs; i++)
			vs[nb+i] = undef;
		vs[nb+Rthis] = vs[base+Rthis];
		vs[nb+Rfn] = vs[base+Rfn];
		vs[nb+Rnewtarget] = vs[base+Rnewtarget];
		vs[nb+Renv] = vs[base+Renv];
		sp = nb + c.nregs;
		pushframe(Frame(c, nb, 0, -1, 0, nil, 1));
		return run();
	}
	return undef;
}

# indirect eval: global code
indirecteval(x: V): V
{
	if(x.t != Tstr)
		return x;
	src := str(x.x);
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		throwerr(SyntaxError, err);
	pick p := prog {
	Program =>
		c := compilescript(p, src, 0, 0);
		c.flags |= Ceval | Cindirect;
		return runcode(c);
	}
	return undef;
}

# a script's code, as a frame of its own
runcode(c: ref Code): V
{
	nb := sp;
	need := nb + c.nregs + 8;
	if(need > len vs)
		growvs(need);
	for(i := 0; i < c.nregs; i++)
		vs[nb+i] = undef;
	vs[nb+Rthis] = objv(iglobal);
	sp = nb + c.nregs;
	pushframe(Frame(c, nb, 0, -1, 0, nil, 1));
	return run();
}

# eval's var and function declarations: in the caller's var scope (sloppy)
evalvarinit(g: ref Gdecl, c: ref Code)
{
	if(c.flags & Cindirect) {
		# global code, but its declarations are configurable
		gh := iglobal;
		for(i := 0; i < len g.lets; i++)
			;
		for(i = 0; i < len g.funcs; i++) {
			(a, nil) := g.funcs[i];
			if(glexfind(a) != nil)
				throwerr(SyntaxError, "identifier '" + atomstr[a] + "' has already been declared");
			(found, d) := getown(gh, a);
			if(!found || (d.attrs & Aconf))
				defineown(gh, a, datadesc(undef, Adefault));
			else if(isaccdesc(d) || (d.attrs & (Awrite|Aenum)) != (Awrite|Aenum))
				typeerr("cannot declare global function " + atomstr[a]);
		}
		for(i = 0; i < len g.vars; i++) {
			a := g.vars[i];
			if(glexfind(a) != nil)
				throwerr(SyntaxError, "identifier '" + atomstr[a] + "' has already been declared");
			if(!hasown(gh, a))
				defineown(gh, a, datadesc(undef, Adefault));
		}
		for(i = 0; i < len g.annexb; i++) {
			a := g.annexb[i];
			if(glexfind(a) == nil && !hasown(gh, a))
				defineown(gh, a, datadesc(undef, Adefault));
		}
		return;
	}
	# the nearest function (or script) scope's eval-var object, or the global object
	target := -1;
	for(e := envreg(); e >= 0; e = oproto[e]) {
		pick d := odata[e] {
		Env =>
			if(d.withobj <= -2) {
				target = -2 - d.withobj;
				break;
			}
			if(d.scope != nil && d.scope.isfunc)
				break;
		}
	}
	# a var may not shadow a lexical declaration between here and there
	names := catint(g.vars, g.annexb);
	for(i := 0; i < len g.funcs; i++)
		names = catint(names, array[] of {g.funcs[i].t0});
	for(e = envreg(); e >= 0; e = oproto[e]) {
		stop := 0;
		pick d := odata[e] {
		Env =>
			if(d.scope != nil && d.scope.names != nil)
				for(j := 0; j < len d.scope.names; j++)
					if(d.scope.kinds[j] == Blet || d.scope.kinds[j] == Bconst || d.scope.kinds[j] == Bclass)
						if(inlist(names, d.scope.names[j]) && !inlist(g.annexb, d.scope.names[j]))
							throwerr(SyntaxError, "identifier '" + atomstr[d.scope.names[j]] + "' has already been declared");
			if(d.withobj <= -2 || d.scope != nil && d.scope.isfunc)
				stop = 1;
		}
		if(stop)
			break;
	}
	if(target < 0) {
		# the caller is global code: the global object (and its lexical names must not clash)
		gh := iglobal;
		for(i = 0; i < len names; i++)
			if(glexfind(names[i]) != nil)
				throwerr(SyntaxError, "identifier '" + atomstr[names[i]] + "' has already been declared");
		for(i = 0; i < len g.funcs; i++) {
			(a, nil) := g.funcs[i];
			(found, d) := getown(gh, a);
			if(!found || (d.attrs & Aconf))
				defineown(gh, a, datadesc(undef, Adefault));
		}
		for(i = 0; i < len g.vars; i++)
			if(!hasown(gh, g.vars[i]))
				defineown(gh, g.vars[i], datadesc(undef, Adefault));
		for(i = 0; i < len g.annexb; i++)
			if(!hasown(gh, g.annexb[i]))
				defineown(gh, g.annexb[i], datadesc(undef, Adefault));
		return;
	}
	for(i = 0; i < len names; i++) {
		a := names[i];
		# a binding of the function's that already has the name keeps it
		(found, nil, slot, nil) := dynfind(a);
		if(found && slot >= 0)
			continue;
		if(!hasown(target, a))
			addprop(target, a, Adefault, undef);
	}
}


# ---- instruction lengths (for scans of code) ----

oplen(op: int): int
{
	case op {
	Opopenv or Ocopyenv or Ogenstart or Odebugger or Onop or Oinitfields =>
		return 1;
	Oundef or Onull or Otrue or Ofalse or Oempty or Ochkthis or Opushenv or Oglobalinit or
	Ojmp or Oret or Othrow or Onewobj or Onewarr or Oarrhole or Oiterclose or Oreqobj or
	Opushwith or Oimportmeta or Oiterdone or Olineno or Ohome or Ofinish or Oasynciter or Ochkobj =>
		return 2;
	Oint or Oconst or Omove or Ochktdz or Otypeofglobal or Osetglobal or Oinitglobal or
	Odelglobal or Ogetname or Otypeofname or Osetname or Oinitname or Odelname or
	Ojt or Ojf or Ojnullish or Ojnnullish or Ojundef or Ojnundef or Othrowerr or Oclosure or
	Oarrpush or Oarrspread or Osetproto or Osethome or Otemplate or Oregexp or Oforin or
	Oargs or Orest or Otokey or Otostr or Oyield or Oawait or Ospreadobj or Onewprivate or
	Oneg or Opos or Otonumeric or Onot or Obnot or Otypeof or Oinc or Odec or
	Oitercall or Oitreturn or Ojempty =>
		return 3;
	Ogetenv or Osetenv or Ogetglobal or Ocallname or Ogetelem or Osetelem or Odelprop or
	Odelelem or Oin or Odefdata or Odefdataa or Ocopyprops or Osetfnname or Ogetiter or
	Oiternext or Oforinnext or Oconcat or Oyieldraw or Ogetpriv or Osetpriv or Odefpriv or
	Ohaspriv or Oimport or Onewspread or
	Oadd or Osub or Omul or Odiv or Omod or Oexp or Oshl or Oshr or Oushr or Oband or Obor or Obxor or
	Oeq or One or Oseq or Osne or Olt or Ole or Ogt or Oge or Oinstof =>
		return 4;
	Ogetenvc or Osetenvc or Ogetprop or Osetprop or Ocallspread or Onew or Odefacc or
	Oclass or Odefmethod or Oprivmethod or Ogetsuper or Osetsuper or Osupercallspread or Oiterres =>
		return 5;
	Ocall or Oeval or Osupercall or Oystep =>
		return 6;
	Onewdisp or Othisdyn or Ogenret =>
		return 2;
	Omodinit =>
		return 1;
	Odiscall or Oaccum =>
		return 3;
	Oaddres or Odisnext =>
		return 4;
	}
	return 1;
}

# ---- stubs for what comes later: proxies, typed arrays, BigInt, modules, regexps ----

Reprog: adt {
	x:	int;
};

# BigInt: a decimal string row (sign and digits)
strbig(s: string): (int, V)
{
	s = trimws(s, 1, 1);
	if(s == nil)
		return (1, V(Tbig, newstr("0"), 0.0));
	neg := 0;
	if(s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-';
		s = s[1:];
	}
	if(s == nil)
		return (0, undef);
	if(len s > 2 && s[0] == '0' && !neg) {
		base := 0;
		case s[1] {
		'x' or 'X' => base = 16;
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		if(base) {
			for(i := 2; i < len s; i++)
				if(digitval(s[i]) < 0 || digitval(s[i]) >= base)
					return (0, undef);
			return (1, V(Tbig, newstr(bigfromradix(s[2:], base)), 0.0));
		}
	}
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return (0, undef);
	i = 0;
	while(i < len s - 1 && s[i] == '0')
		i++;
	d := s[i:];
	if(neg && d != "0")
		d = "-" + d;
	return (1, V(Tbig, newstr(d), 0.0));
}

bigfromradix(d: string, base: int): string
{
	# repeated multiply-add in decimal
	r := "0";
	for(i := 0; i < len d; i++) {
		if(d[i] == '_')
			continue;
		r = decmuladd(r, base, digitval(d[i]));
	}
	return r;
}

# a non-negative decimal string times m plus a
decmuladd(s: string, m, a: int): string
{
	r := "";
	carry := a;
	for(i := len s - 1; i >= 0; i--) {
		x := (s[i] - '0') * m + carry;
		r[len r] = '0' + x % 10;
		carry = x / 10;
	}
	while(carry > 0) {
		r[len r] = '0' + carry % 10;
		carry /= 10;
	}
	# reverse and strip leading zeros
	o := "";
	for(i = len r - 1; i >= 0; i--)
		o[len o] = r[i];
	j := 0;
	while(j < len o - 1 && o[j] == '0')
		j++;
	return o[j:];
}

bigeqnum(b: V, x: real): int
{
	if(isnan(x) || x == inf || x == -inf || x != trunc(x))
		return 0;
	return str(b.x) == string big x || bigcmpnum(b, x) == 0;
}

bigcmp(a, b: V): int
{
	return deccmp(str(a.x), str(b.x));
}

# compare signed decimal strings
deccmp(a, b: string): int
{
	na := len a > 0 && a[0] == '-';
	nb := len b > 0 && b[0] == '-';
	if(na != nb) {
		if(na)
			return -1;
		return 1;
	}
	if(na) {
		a = a[1:];
		b = b[1:];
	}
	c := 0;
	if(len a != len b) {
		if(len a < len b)
			c = -1;
		else
			c = 1;
	} else if(a < b)
		c = -1;
	else if(a > b)
		c = 1;
	if(na)
		return -c;
	return c;
}

bigcmpnum(b: V, x: real): int
{
	if(x == inf)
		return -1;
	if(x == -inf)
		return 1;
	s := str(b.x);
	bv := real s;
	if(bv < x)
		return -1;
	if(bv > x)
		return 1;
	# close: compare exactly against x's integer part
	t := trunc(x);
	ts := string big t;
	if(t > 9.2e18 || t < -9.2e18)
		ts = numstr(t);
	c := deccmp(s, ts);
	if(c != 0)
		return c;
	if(x > t)
		return -1;
	if(x < t)
		return 1;
	return 0;
}

bigneg(a: V): V
{
	s := str(a.x);
	if(s == "0")
		return a;
	if(s[0] == '-')
		return V(Tbig, newstr(s[1:]), 0.0);
	return V(Tbig, newstr("-" + s), 0.0);
}

bignot(a: V): V
{
	return bigadd(bigneg(a), bigfromint(-1));
}

bigfromint(i: int): V
{
	return V(Tbig, newstr(string i), 0.0);
}

bigadd(a, b: V): V
{
	if(a.t != Tbig || b.t != Tbig)
		typeerr("cannot mix BigInt and other types, use explicit conversions");
	h := newstr(decadd(str(a.x), str(b.x)));
	return V(Tbig, h, 0.0);
}

decadd(a, b: string): string
{
	na := len a > 0 && a[0] == '-';
	nb := len b > 0 && b[0] == '-';
	if(na)
		a = a[1:];
	if(nb)
		b = b[1:];
	if(na == nb) {
		r := uadd(a, b);
		if(na && r != "0")
			return "-" + r;
		return r;
	}
	# different signs: subtract the smaller magnitude
	c := deccmp(a, b);
	if(c == 0)
		return "0";
	if(c > 0) {
		r := usub(a, b);
		if(na)
			return "-" + r;
		return r;
	}
	r := usub(b, a);
	if(nb)
		return "-" + r;
	return r;
}

uadd(a, b: string): string
{
	r := "";
	i := len a - 1;
	j := len b - 1;
	carry := 0;
	while(i >= 0 || j >= 0 || carry) {
		x := carry;
		if(i >= 0)
			x += a[i--] - '0';
		if(j >= 0)
			x += b[j--] - '0';
		r[len r] = '0' + x % 10;
		carry = x / 10;
	}
	o := "";
	for(k := len r - 1; k >= 0; k--)
		o[len o] = r[k];
	return o;
}

# a - b, a >= b, magnitudes
usub(a, b: string): string
{
	r := "";
	i := len a - 1;
	j := len b - 1;
	borrow := 0;
	while(i >= 0) {
		x := a[i--] - '0' - borrow;
		if(j >= 0)
			x -= b[j--] - '0';
		if(x < 0) {
			x += 10;
			borrow = 1;
		} else
			borrow = 0;
		r[len r] = '0' + x;
	}
	o := "";
	for(k := len r - 1; k >= 0; k--)
		o[len o] = r[k];
	k = 0;
	while(k < len o - 1 && o[k] == '0')
		k++;
	return o[k:];
}

