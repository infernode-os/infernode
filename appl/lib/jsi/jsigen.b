#
# jsigen.b - generators, async functions, promises and the job queue.
#
# A generator's body runs on a Dis thread of its own, a coroutine: the
# thread that resumes it sends a message and waits for the answer, so
# only one thread runs JavaScript at a time and the interpreter's
# globals are handed over with the messages (each side saves its own
# before it waits and puts them back when it wakes).  An async
# function is a coroutine that its awaits suspend; the promise
# reactions resume it from the job queue.
#

Gstart, Gsuspended, Grunning, Gdone: con iota;
Kgen, Kasync, Kasyncgen: con iota;

# messages to the coroutine, and from it
Mnext, Mthrow, Mreturn, Myield, Myieldraw, Mawait, Mdone, Merror: con iota;

Msg: adt {
	kind:	int;
	v:	V;
};

Gen: adt {
	state:	int;
	kind:	int;
	f:	ref Obj;
	code:	ref Code;
	fr:	array of V;
	env:	ref Env;
	nargs:	int;
	nt:	ref Obj;
	tocoro:	chan of ref Msg;
	fromcoro:	chan of ref Msg;
	started:	int;
	retv:	V;		# a return() being carried out
	cap:	ref Cap;	# an async function's promise
	queue:	list of ref Areq;	# an async generator's requests
	awaiting:	int;
	obj:	ref Obj;
	depth:	int;
	nat:	int;	# an async built-in run as a coroutine (asyncnative)
	nthis:	V;
	natargs:	array of V;
};

# an async generator's request
Areq: adt {
	kind:	int;
	v:	V;
	cap:	ref Cap;
};

curgen: ref Gen;
livegens: list of ref Gen;	# coroutines started and not finished, to be stopped at shutdown

callgen(f: ref Obj, c: ref Code, this: V, args: array of V): V
{
	nfr := mkframe(c, this, args);
	g := ref Gen;
	g.f = f;
	g.code = c;
	g.nargs = len args;
	g.state = Gstart;
	if((c.flags & (Cgen|Casync)) == (Cgen|Casync))
		g.kind = Kasyncgen;
	else if(c.flags & Cgen)
		g.kind = Kgen;
	else
		g.kind = Kasync;
	if(g.kind == Kasync) {
		g.cap = newcap();
		g.fr = nfr;
		g.env = f.env;
		g.depth = depth;
		r := resume(g, Mnext, undef);
		asyncstep(g, r);
		return objv(g.cap.promise);
	}
	# a generator's parameters are bound when it is called
	if(++depth > maxdepth) {
		depth--;
		throwerr(ERange, "Maximum call stack size exceeded");
	}
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	fr = nfr;
	env = f.env;
	curfn = f;
	newt = nil;
	argc = len args;
	if((c.flags & Cstrict) == 0) {
		t := nfr[0].t;
		if(t == Tundef || t == Tnull)
			nfr[0] = globalthis;
		else if(t != Tobj)
			nfr[0] = objv(toobj(nfr[0]));
	}
	{
		if(c.prologue >= 0)
			ev(c.prologue);
	} exception {
	"JS*" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		depth--;
		raise;
	}
	g.fr = fr;
	g.env = env;
	g.depth = 0;
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	depth--;
	proto: ref Obj;
	p := getv(f, a_prototype);
	if(p.t == Tobj)
		proto = p.o;
	else if(g.kind == Kasyncgen)
		proto = asyncgenproto;
	else
		proto = genproto;
	o := newobj(Cgenobj, proto);
	o.data = ref Data.Gen(g);
	g.obj = o;
	return objv(o);
}

# resume the coroutine with a message; its answer
resume(g: ref Gen, kind: int, v: V): ref Msg
{
	if(g.state == Grunning)
		throwtype("Generator is already running");
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	sdepth := depth;
	svstk := vstk;
	svsp := vsp;
	sgen := curgen;
	scv := cv;
	g.state = Grunning;
	if(!g.started) {
		g.started = 1;
		g.tocoro = chan of ref Msg;
		g.fromcoro = chan of ref Msg;
		livegens = g :: livegens;
		spawn coro(g, depth);
	}
	g.tocoro <-= ref Msg(kind, v);
	r := <-g.fromcoro;
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	depth = sdepth;
	vstk = svstk;
	vsp = svsp;
	curgen = sgen;
	cv = scv;
	ctl = 0;
	if(r.kind == Mdone || r.kind == Merror) {
		g.state = Gdone;
		dropgen(g);
	} else
		g.state = Gsuspended;
	return r;
}

dropgen(g: ref Gen)
{
	r: list of ref Gen;
	for(l := livegens; l != nil; l = tl l)
		if(hd l != g)
			r = hd l :: r;
	livegens = r;
}

# the coroutine: wait to be started, run the body, answer with how it ended
coro(g: ref Gen, d: int)
{
	m := <-g.tocoro;
	if(m == nil)
		return;
	fr = g.fr;
	env = g.env;
	curfn = g.f;
	newt = nil;
	argc = g.nargs;
	depth = d;
	vstk = array[16] of V;
	vsp = 0;
	curgen = g;
	ctl = 0;
	r: ref Msg;
	{
		case m.kind {
		Mthrow =>
			throwv(m.v);
		Mreturn =>
			g.retv = m.v;
			raise "JSgenret";
		}
		if(g.nat > 0)
			r = ref Msg(Mdone, natasync(g));
		else {
			c := g.code;
			if(g.kind == Kasync) {
				if((c.flags & (Cstrict|Carrow)) == 0) {
					t := fr[0].t;
					if(t == Tundef || t == Tnull)
						fr[0] = globalthis;
					else if(t != Tobj)
						fr[0] = objv(toobj(fr[0]));
				}
				if(c.prologue >= 0)
					ev(c.prologue);
			}
			ev(c.body);
			v := undef;
			if(ctl == Cret)
				v = regv();
			ctl = 0;
			r = ref Msg(Mdone, v);
		}
	} exception e {
	"JS" =>
		r = ref Msg(Merror, thrown);
	"JSgenret" =>
		r = ref Msg(Mdone, g.retv);
	"JSkill" =>
		return;
	"*" =>
		# the engine broke: say so to whoever is waiting
		r = ref Msg(Merror, objv(mkerror(EError, "internal error in generator: " + e)));
	}
	g.fromcoro <-= r;
}

# yield v from the running coroutine; what it is resumed with
coyield(kind: int, v: V): V
{
	g := curgen;
	if(g == nil)
		throwerr(ESyntax, "yield outside a generator");
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	sdepth := depth;
	svstk := vstk;
	svsp := vsp;
	scv := cv;
	g.fromcoro <-= ref Msg(kind, v);
	m := <-g.tocoro;
	if(m == nil)
		raise "JSkill";
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	depth = sdepth;
	vstk = svstk;
	vsp = svsp;
	curgen = g;
	cv = scv;
	case m.kind {
	Mthrow =>
		throwv(m.v);
	Mreturn =>
		if(g.kind == Kasyncgen)
			g.retv = await(m.v);
		else
			g.retv = m.v;
		raise "JSgenret";
	}
	return m.v;
}

genyield(v: V): V
{
	g := curgen;
	if(g.kind == Kasyncgen)
		v = await(v);
	return coyield(Myield, v);
}

# yield*: the inner iterator's results passed through
genyieldstar(v: V): V
{
	g := curgen;
	async := g.kind == Kasyncgen;
	it := getiterator(v, async);
	next := getvalue(it, a_next);
	received := Msg(Mnext, undef);
	for(;;) {
		r: V;
		case received.kind {
		Mnext =>
			r = call1(next, it, array[] of {received.v});
		Mthrow =>
			th := getmethod(it, a_throw);
			if(th == nil) {
				# no throw: close the iterator and say so
				if(async)
					asynciterclose(it);
				else
					iterclose(it, 0);
				throwtype("The iterator does not provide a 'throw' method");
			}
			r = call(th, it, array[] of {received.v});
		* =>
			rm := getmethod(it, a_return);
			if(rm == nil) {
				g.retv = received.v;
				if(async)
					g.retv = await(received.v);
				raise "JSgenret";
			}
			r = call(rm, it, array[] of {received.v});
		}
		if(async)
			r = await(r);
		if(r.t != Tobj)
			throwtype("Iterator result " + showv(r) + " is not an object");
		if(tobool(getv(r.o, a_done))) {
			x := getv(r.o, a_value);
			if(received.kind == Mreturn) {
				g.retv = x;
				raise "JSgenret";
			}
			return x;
		}
		{
			if(async)
				received.v = coyield(Myield, getv(r.o, a_value));
			else
				received.v = coyield(Myieldraw, r);
			received.kind = Mnext;
		} exception {
		"JS" =>
			received.kind = Mthrow;
			received.v = thrown;
		"JSgenret" =>
			received.kind = Mreturn;
			received.v = g.retv;
		}
	}
}

asynciterclose(it: V)
{
	m := getmethod(it, a_return);
	if(m == nil)
		return;
	r := await(call(m, it, nil));
	if(r.t != Tobj)
		throwtype("Iterator result is not an object");
}

# await v in the running async coroutine
await(v: V): V
{
	g := curgen;
	if(g == nil || g.kind == Kgen)
		return toplevelawait(v);
	p := promiseresolve(promisector, v);
	return coyield(Mawait, objv(p));
}

# the generator object's next, throw and return
gennext(this: V, kind: int, v: V): V
{
	g := thisgen(this, Kgen);
	case g.state {
	Gdone =>
		case kind {
		Mthrow =>
			throwv(v);
		Mreturn =>
			return iterresult(v, 1);
		}
		return iterresult(undef, 1);
	Gstart =>
		if(kind == Mreturn) {
			g.state = Gdone;
			return iterresult(v, 1);
		}
		if(kind == Mthrow) {
			g.state = Gdone;
			throwv(v);
		}
	}
	r := resume(g, kind, v);
	case r.kind {
	Myield =>
		return iterresult(r.v, 0);
	Myieldraw =>
		return r.v;
	Mdone =>
		return iterresult(r.v, 1);
	Merror =>
		throwv(r.v);
	}
	throwtype("generator: unexpected await");
	return undef;
}

thisgen(this: V, kind: int): ref Gen
{
	if(this.t == Tobj && this.o.cls == Cgenobj) {
		pick d := this.o.data {
		Gen =>
			if(kind < 0 || d.g.kind == kind)
				return d.g;
		}
	}
	throwtype("next method called on incompatible receiver " + showv(this));
	return nil;
}

iterresult(v: V, done: int): V
{
	o := plainobj();
	addprop(o, a_value, Adefault, v);
	addprop(o, a_done, Adefault, boolv(done));
	return objv(o);
}

# an async function's coroutine has stopped: at an await, or for good
asyncstep(g: ref Gen, r: ref Msg)
{
	case r.kind {
	Mawait =>
		awaiton(g, r.v.o);
	Mdone =>
		resolvecap(g.cap, r.v);
	Merror =>
		rejectcap(g.cap, r.v);
	* =>
		rejectcap(g.cap, objv(mkerror(EError, "async function yielded")));
	}
}

# resume g when promise p settles
awaiton(g: ref Gen, p: ref Obj)
{
	ok := ref React(0, nil, nil, 1, g);
	bad := ref React(1, nil, nil, 1, g);
	performthen(p, ok, bad);
}

# a promise reaction of the engine's own: resume the coroutine waiting on it
reactnative(rc: ref React, v: V)
{
	g := rc.g;
	kind := Mnext;
	if(rc.kind == 1)
		kind = Mthrow;
	if(g.kind == Kasync) {
		r := resume(g, kind, v);
		asyncstep(g, r);
		return;
	}
	# an async generator
	g.awaiting = 0;
	r := resume(g, kind, v);
	agstep(g, r);
}

# ---- async generators ----

agrequest(this: V, kind: int, v: V): V
{
	cap := newcap();
	g: ref Gen;
	if(this.t == Tobj && this.o.cls == Cgenobj) {
		pick d := this.o.data {
		Gen =>
			if(d.g.kind == Kasyncgen)
				g = d.g;
		}
	}
	if(g == nil) {
		rejectcap(cap, objv(mkerror(EType, "not an async generator")));
		return objv(cap.promise);
	}
	req := ref Areq(kind, v, cap);
	l: list of ref Areq;
	for(q := g.queue; q != nil; q = tl q)
		l = hd q :: l;
	l = req :: l;
	g.queue = nil;
	for(; l != nil; l = tl l)
		g.queue = hd l :: g.queue;
	if(g.state != Grunning && !g.awaiting)
		agresumenext(g);
	return objv(cap.promise);
}

agresumenext(g: ref Gen)
{
	while(g.queue != nil && !g.awaiting && g.state != Grunning) {
		req := hd g.queue;
		if(g.state == Gstart && (req.kind == Mreturn || req.kind == Mthrow))
			g.state = Gdone;
		if(g.state == Gdone) {
			case req.kind {
			Mnext =>
				g.queue = tl g.queue;
				resolvecap(req.cap, iterresult(undef, 1));
			Mthrow =>
				g.queue = tl g.queue;
				rejectcap(req.cap, req.v);
			Mreturn =>
				# await the value, then done
				g.awaiting = 1;
				{
					p := promiseresolve(promisector, req.v);
					performthen(p, ref React(0, nil, nil, 2, g), ref React(1, nil, nil, 2, g));
				} exception {
				"JS" =>
					g.awaiting = 0;
					g.queue = tl g.queue;
					rejectcap(req.cap, thrown);
				}
			}
			continue;
		}
		r := resume(g, req.kind, req.v);
		agstep(g, r);
	}
}

# a return() on a finished async generator: its value awaited
agreturned(g: ref Gen, kind: int, v: V)
{
	g.awaiting = 0;
	req := hd g.queue;
	g.queue = tl g.queue;
	if(kind == 0)
		resolvecap(req.cap, iterresult(v, 1));
	else
		rejectcap(req.cap, v);
	agresumenext(g);
}

agstep(g: ref Gen, r: ref Msg)
{
	case r.kind {
	Mawait =>
		g.awaiting = 1;
		awaiton(g, r.v.o);
		return;
	Myield or Myieldraw =>
		req := hd g.queue;
		g.queue = tl g.queue;
		resolvecap(req.cap, iterresult(r.v, 0));
	Mdone =>
		req := hd g.queue;
		g.queue = tl g.queue;
		resolvecap(req.cap, iterresult(r.v, 1));
	Merror =>
		req := hd g.queue;
		g.queue = tl g.queue;
		rejectcap(req.cap, r.v);
	}
	agresumenext(g);
}

# %AsyncFromSyncIteratorPrototype%: a sync iterator for for await and yield*
asyncfromsync(it: V): ref Obj
{
	o := newobj(Citer, asyncfromsyncproto);
	o.data = ref Data.Iter(Iasyncfromsync, it.o, getvalue(it, a_next), 0, 0, nil);
	return o;
}

# ---- for await ----

forawait(n: int, v: V, inf: ref Info.Loop, benv: ref Env)
{
	it := getiterator(v, 1);
	next := getvalue(it, a_next);
	for(;;) {
		r := await(call1(next, it, nil));
		if(r.t != Tobj)
			throwtype("Iterator result " + showv(r) + " is not an object");
		if(tobool(getv(r.o, a_done)))
			return;
		setr(getv(r.o, a_value));
		{
			forbind(n, inf, benv);
			ev(nc[n]);
		} exception {
		"JS" =>
			env = benv;
			ex := thrown;
			{
				asynciterclose(it);
			} exception {
			"JS" =>
				;
			}
			throwv(ex);
		"JS*" =>
			env = benv;
			asynciterclose(it);
			raise;
		}
		env = benv;
		if(ctl) {
			if(!loopctl(nd[n])) {
				asynciterclose(it);
				return;
			}
		}
	}
}

# await at the top of a module (or where nothing can wait): run the jobs until it settles
toplevelawait(v: V): V
{
	p := promiseresolve(promisector, v);
	pick d := p.data {
	Promise =>
		while(d.state == Ppending && jobs != nil)
			runjob();
		case d.state {
		Pfulfilled =>
			return d.v;
		Prejected =>
			d.handled = 1;
			throwv(d.v);
		}
		throwtype("await: the promise never settled");
	}
	return undef;
}

# ---- promises ----

Ppending, Pfulfilled, Prejected: con iota;

promisector: ref Obj;

newpromise(proto: ref Obj): ref Obj
{
	o := newobj(Cpromise, proto);
	o.data = ref Data.Promise(Ppending, undef, nil, 0);
	return o;
}

# NewPromiseCapability(%Promise%)
newcap(): ref Cap
{
	p := newpromise(promiseproto);
	(res, rej) := resolvingfns(p);
	return ref Cap(p, res, rej);
}

# NewPromiseCapability(C)
newcapof(c: V): ref Cap
{
	if(c.t != Tobj || !isctor(c.o))
		throwtype("Promise resolver is not a constructor");
	if(c.o == promisector)
		return newcap();
	cap := ref Cap(nil, nil, nil);
	exec := mknative(Npromisecapexec, "", 2);
	exec.data = ref Data.Capexec(cap);
	p := construct(c.o, array[] of {objv(exec)}, c.o);
	if(cap.resolve == nil || cap.resolve.fun == nil)
		throwtype("Promise resolve function is not callable");
	if(cap.reject == nil || cap.reject.fun == nil)
		throwtype("Promise reject function is not callable");
	cap.promise = p.o;
	return cap;
}

# CreateResolvingFunctions
resolvingfns(p: ref Obj): (ref Obj, ref Obj)
{
	done := ref Flag(0);
	res := mknative(Npromiseresolvefn, "", 1);
	res.data = ref Data.Resolver(p, done, 0);
	rej := mknative(Npromiseresolvefn, "", 1);
	rej.data = ref Data.Resolver(p, done, 1);
	return (res, rej);
}

resolvecap(cap: ref Cap, v: V)
{
	if(cap.promise != nil && cap.resolve != nil) {
		pick d := cap.resolve.data {
		Resolver =>
			if(!d.done.v) {
				d.done.v = 1;
				resolvepromise(d.p, v);
			}
			return;
		}
	}
	call(cap.resolve, undef, array[] of {v});
}

rejectcap(cap: ref Cap, v: V)
{
	if(cap.promise != nil && cap.reject != nil) {
		pick d := cap.reject.data {
		Resolver =>
			if(!d.done.v) {
				d.done.v = 1;
				rejectpromise(d.p, v);
			}
			return;
		}
	}
	call(cap.reject, undef, array[] of {v});
}

# a resolve function's work: settle p with x, or follow x if it is a thenable
resolvepromise(p: ref Obj, x: V)
{
	if(x.t == Tobj && x.o == p) {
		rejectpromise(p, objv(mkerror(EType, "Chaining cycle detected for promise")));
		return;
	}
	if(x.t != Tobj) {
		fulfil(p, x);
		return;
	}
	then: V;
	{
		then = getv(x.o, a_then);
	} exception {
	"JS" =>
		rejectpromise(p, thrown);
		return;
	}
	if(!iscallable(then)) {
		fulfil(p, x);
		return;
	}
	enqueue(ref Job.Thenable(p, x, then.o));
}

fulfil(p: ref Obj, v: V)
{
	pick d := p.data {
	Promise =>
		if(d.state != Ppending)
			return;
		r := d.reacts;
		d.state = Pfulfilled;
		d.v = v;
		d.reacts = nil;
		trigger(r, 0, v);
	}
}

rejectpromise(p: ref Obj, v: V)
{
	pick d := p.data {
	Promise =>
		if(d.state != Ppending)
			return;
		r := d.reacts;
		d.state = Prejected;
		d.v = v;
		d.reacts = nil;
		if(!d.handled)
			unhandled = p :: unhandled;
		trigger(r, 1, v);
	}
}

# the reactions in the order they were added
trigger(l: list of ref React, kind: int, v: V)
{
	r: list of ref React;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	for(; r != nil; r = tl r) {
		rc := hd r;
		if(rc.kind == kind)
			enqueue(ref Job.Reaction(rc, v));
	}
}

# PerformPromiseThen, with the two reactions
performthen(p: ref Obj, ok, bad: ref React)
{
	pick d := p.data {
	Promise =>
		case d.state {
		Ppending =>
			d.reacts = bad :: ok :: d.reacts;
		Pfulfilled =>
			enqueue(ref Job.Reaction(ok, d.v));
		Prejected =>
			if(!d.handled)
				removeunhandled(p);
			enqueue(ref Job.Reaction(bad, d.v));
		}
		d.handled = 1;
	}
}

# PromiseResolve(C, x)
promiseresolve(c: ref Obj, x: V): ref Obj
{
	if(x.t == Tobj && x.o.cls == Cpromise) {
		xc := getv(x.o, a_constructor);
		if(xc.t == Tobj && xc.o == c)
			return x.o;
	}
	cap := newcapof(objv(c));
	call(cap.resolve, undef, array[] of {x});
	return cap.promise;
}

unhandled: list of ref Obj;

removeunhandled(p: ref Obj)
{
	r: list of ref Obj;
	for(l := unhandled; l != nil; l = tl l)
		if(hd l != p)
			r = hd l :: r;
	unhandled = r;
}

# ---- jobs ----

Job: adt {
	pick {
	Reaction =>
		r:	ref React;
		v:	V;
	Thenable =>
		p:	ref Obj;
		x:	V;
		then:	ref Obj;
	Call =>
		f:	ref Obj;
		args:	array of V;
	}
};

jobs: list of ref Job;
jobstail: list of ref Job;	# jobs to come, newest first: moved to jobs when it runs dry

enqueue(j: ref Job)
{
	jobstail = j :: jobstail;
}

runjob()
{
	if(jobs == nil) {
		for(; jobstail != nil; jobstail = tl jobstail)
			jobs = hd jobstail :: jobs;
	}
	if(jobs == nil)
		return;
	j := hd jobs;
	jobs = tl jobs;
	pick x := j {
	Reaction =>
		rc := x.r;
		if(rc.native == 1) {
			reactnative(rc, x.v);
			return;
		}
		if(rc.native == 2) {
			agreturned(rc.g, rc.kind, x.v);
			return;
		}
		if(rc.handler == nil) {
			if(rc.cap == nil)
				return;
			if(rc.kind == 0)
				resolvecap(rc.cap, x.v);
			else
				rejectcap(rc.cap, x.v);
			return;
		}
		r: V;
		{
			r = call(rc.handler, undef, array[] of {x.v});
		} exception {
		"JS" =>
			if(rc.cap != nil)
				rejectcap(rc.cap, thrown);
			return;
		}
		if(rc.cap != nil)
			resolvecap(rc.cap, r);
	Thenable =>
		(res, rej) := resolvingfns(x.p);
		{
			call(x.then, x.x, array[] of {objv(res), objv(rej)});
		} exception {
		"JS" =>
			ex := thrown;
			pick d := rej.data {
			Resolver =>
				if(!d.done.v) {
					d.done.v = 1;
					rejectpromise(d.p, ex);
				}
			}
		}
	Call =>
		call(x.f, undef, x.args);
	}
}

pending(): int
{
	return jobs != nil || jobstail != nil;
}

# run every job, those they make too; errors from them are reported, not thrown
runjobs(): string
{
	err: string;
	while(pending()) {
		{
			runjob();
		} exception {
		"JS" =>
			if(err == nil)
				err = showexc(thrown);
		}
	}
	return err;
}
