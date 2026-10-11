#
# jsigc.b - the realm's own collector.
#
# Dis frees an object when its last reference goes, but a cycle (a DOM
# node holding a closure holding the node; a prototype and its
# constructor) waits for Dis's collector, which is paced by the
# scheduler and marks one pass per pointer that points backwards in
# memory: a busy thread making lists outruns it until the heap is full.
# So the realm traces its own objects.  Every object made is on a
# registry; a collection marks what the roots reach and clears the
# fields of the rest, so the cycles they formed come apart and Dis
# frees them at once.  A cleared object stays a valid, empty object: a
# reference to it kept where the tracer cannot see (a Limbo local) is a
# bug, found with js -g n, which collects at every nth allocation.
#
# A collection runs only at safe points (between statements, at loops'
# back edges, between jobs), never inside a built-in: a built-in's
# locals are not roots.  The evaluator's own temporaries that live
# across a call into script are rooted on the pattern stack (vstk) or
# the frame stack here (rootfr: frames being filled, argument arrays).
# A coroutine parked at a yield keeps its state in its Gen; whoever
# resumed it keeps theirs in resumers.
#

gcreg: array of ref Obj;	# every object made, those cleared since gone
ngcreg := 0;
gcalloc := 0;		# objects made since the last collection
gcnext := 0;		# collect when gcalloc reaches it
gcwanted := 0;
gcstress := 0;		# js -g n: collect at every nth allocation
gchold := 0;		# no collection: the realm is being made or torn down
natdepth := 0;		# built-ins in progress, in the running chain of threads
natlocal := 0;		# this thread's own
gcruns := 0;
gcms := 0;		# time spent collecting
gclive := 0;		# objects that survived the last collection
Gcmin: con 1 << 16;
Fmark: con Fdead << 1;

# frames and argument arrays being filled or run, this thread's, with the callee
# and the env in force when each was pushed (a caller's block env lives nowhere else)
rootfr: array of array of V;
rootobj: array of ref Obj;
rootenv: array of ref Env;
nroot := 0;

# what a thread that resumed a coroutine holds while the coroutine runs
Saved: adt {
	fr:	array of V;
	env:	ref Env;
	curfn:	ref Obj;
	newt:	ref Obj;
	vstk:	array of V;
	rootfr:	array of array of V;
	rootobj:	array of ref Obj;
	rootenv:	array of ref Env;
	nroot:	int;
	cv:	V;
	gen:	ref Gen;	# the coroutine the resumer was running, if one
};
resumers: list of ref Saved;
curjob: ref Job;	# the job being run

deadshape: ref Shape;	# the shape of a cleared object

gcinit()
{
	gcreg = array[4096] of ref Obj;
	ngcreg = 0;
	gcalloc = 0;
	gcnext = Gcmin;
	gcwanted = 0;
	gchold = 0;
	natdepth = 0;
	natlocal = 0;
	gcruns = 0;
	gcms = 0;
	gclive = 0;
	rootfr = array[256] of array of V;
	rootobj = array[256] of ref Obj;
	rootenv = array[256] of ref Env;
	nroot = 0;
	resumers = nil;
	curjob = nil;
	deadshape = ref Shape(nil, nil, 0, nil, 1, nil, nil, nil, 0, nil);
	(ok, nil) := sys->stat("/env/jsgcdebug");
	gcdebug = ok >= 0;
}

gcnew(o: ref Obj)
{
	if(ngcreg == len gcreg) {
		a := array[2 * ngcreg] of ref Obj;
		a[0:] = gcreg;
		gcreg = a;
	}
	gcreg[ngcreg++] = o;
	if(++gcalloc >= gcnext)
		gcwanted = 1;
}

# a safe point
gcpoint()
{
	if(gcwanted && natdepth == 0 && gchold == 0)
		gccollect();
}

rootpush(a: array of V, f: ref Obj)
{
	if(nroot == len rootfr)
		rootgrow();
	rootfr[nroot] = a;
	rootobj[nroot] = f;
	rootenv[nroot] = env;
	nroot++;
}

rootgrow()
{
	na := array[2 * nroot] of array of V;
	na[0:] = rootfr;
	rootfr = na;
	no := array[2 * nroot] of ref Obj;
	no[0:] = rootobj;
	rootobj = no;
	ne := array[2 * nroot] of ref Env;
	ne[0:] = rootenv;
	rootenv = ne;
}

rootpop()
{
	nroot--;
	rootfr[nroot] = nil;
	rootobj[nroot] = nil;
	rootenv[nroot] = nil;
}

# after an exception: back to what a catch site saw
rootreset(n: int)
{
	while(nroot > n)
		rootpop();
}

# ---- marking ----

mstk: array of ref Obj;		# objects marked, their fields still to follow
nm := 0;
estk: list of ref Env;
gcepoch := 0;			# an Env or Gen is marked when its gcm is this

mark(o: ref Obj)
{
	if(o == nil || (o.flags & Fmark))
		return;
	o.flags |= Fmark;
	if(nm == len mstk) {
		a := array[2 * nm] of ref Obj;
		a[0:] = mstk;
		mstk = a;
	}
	mstk[nm++] = o;
}

markv(v: V)
{
	if(v.t >= Trope)
		mark(v.o);
}

markvs(a: array of V)
{
	if(a != nil)
		for(i := 0; i < len a; i++)
			if(a[i].t >= Trope)
				mark(a[i].o);
}

markenv(e: ref Env)
{
	if(e != nil && e.gcm != gcepoch) {
		e.gcm = gcepoch;
		estk = e :: estk;
	}
}

markcap(c: ref Cap)
{
	if(c == nil)
		return;
	mark(c.promise);
	mark(c.resolve);
	mark(c.reject);
}

markreact(r: ref React)
{
	if(r == nil)
		return;
	mark(r.handler);
	markcap(r.cap);
	markgen(r.g);
}

markgen(g: ref Gen)
{
	if(g == nil || g.gcm == gcepoch)
		return;
	g.gcm = gcepoch;
	mark(g.f);
	mark(g.obj);
	mark(g.nt);
	markenv(g.env);
	markvs(g.fr);
	markv(g.retv);
	markcap(g.cap);
	for(l := g.queue; l != nil; l = tl l) {
		markv((hd l).v);
		markcap((hd l).cap);
	}
	markvs(g.vstk);
	for(i := 0; i < g.nroot; i++) {
		markvs(g.rootfr[i]);
		mark(g.rootobj[i]);
		markenv(g.rootenv[i]);
	}
	markv(g.nthis);
	markvs(g.natargs);
}

markjob(j: ref Job)
{
	if(j == nil)
		return;
	pick x := j {
	Reaction =>
		markreact(x.r);
		markv(x.v);
	Thenable =>
		mark(x.p);
		markv(x.x);
		mark(x.then);
	Call =>
		mark(x.f);
		markvs(x.args);
	}
}

markmap(m: ref Hmap)
{
	if(m == nil)
		return;
	for(i := 0; i < m.n; i++) {
		markv(m.keys[i]);
		markv(m.vals[i]);
	}
}

markmod(m: ref Module)
{
	if(m == nil)
		return;
	markenv(m.env);
	markv(m.err);
	mark(m.ns);
	mark(m.meta);
	mark(m.promise);
	if(m.links != nil)
		for(i := 0; i < len m.links; i++)
			if(m.links[i] != nil) {
				markenv(m.links[i].env);
				mark(m.links[i].ns);
			}
}

markroots()
{
	i := 0;
	mark(global);
	mark(objproto);
	mark(funcproto);
	mark(arrproto);
	mark(strproto);
	mark(numproto);
	mark(boolproto);
	mark(symproto);
	mark(bigproto);
	mark(errproto);
	if(errprotos != nil)
		for(i = 0; i < len errprotos; i++)
			mark(errprotos[i]);
	mark(genfuncproto);
	mark(asyncfuncproto);
	mark(asyncgenfuncproto);
	mark(genproto);
	mark(asyncgenproto);
	mark(iterproto);
	mark(asynciterproto);
	mark(arrayiterproto);
	mark(asyncfromsyncproto);
	mark(promiseproto);
	mark(regexpproto);
	mark(dateproto);
	mark(mapproto);
	mark(setprotoobj);
	mark(weakmapproto);
	mark(weaksetproto);
	mark(throwerfn);
	mark(evalfn);
	mark(notcallable);
	mark(objectctor);
	mark(functionctor);
	mark(arrayctor);
	markmap(symregistry);
	mark(mapiterproto);
	mark(setiterproto);
	mark(iterhelperproto);
	mark(wrapforvalidproto);
	mark(setctor);
	mark(suppproto);
	mark(dsproto);
	mark(adsproto);
	mark(promisector);
	mark(regexpctor);
	mark(rxstriterproto);
	mark(rxexecfn);
	markmap(rxcache);
	mark(striterproto);
	mark(rawjsonproto);
	if(tyctor != nil)
		for(i = 0; i < len tyctor; i++)
			mark(tyctor[i]);
	if(typroto != nil)
		for(i = 0; i < len typroto; i++)
			mark(typroto[i]);
	mark(typedarrayctor);
	mark(typedarrayproto);
	mark(abufproto);
	mark(abufctor);
	mark(dviewproto);
	mark(arrayvalues);
	mark(arrayiternextfn);
	for(i = 0; i < natom && i < len atomsym; i++)
		mark(atomsym[i]);
	for(i = 0; i < nglex && i < len glexv; i++)
		markv(glexv[i]);
	for(i = 0; i < len icobj; i++)
		mark(icobj[i]);
	for(i = 0; i < len infos; i++)
		if(infos[i] != nil)
			pick t := infos[i] {
			Tmpl =>
				mark(t.obj);
			}
	# the running state
	markvs(fr);
	markenv(env);
	mark(curfn);
	mark(newt);
	mark(ro);
	mark(th);
	markv(thrown);
	markv(cv);
	markvs(vstk);
	for(i = 0; i < nroot; i++) {
		markvs(rootfr[i]);
		mark(rootobj[i]);
		markenv(rootenv[i]);
	}
	for(rl := resumers; rl != nil; rl = tl rl) {
		s := hd rl;
		markvs(s.fr);
		markenv(s.env);
		mark(s.curfn);
		mark(s.newt);
		markvs(s.vstk);
		for(i = 0; i < s.nroot; i++) {
			markvs(s.rootfr[i]);
			mark(s.rootobj[i]);
			markenv(s.rootenv[i]);
		}
		markv(s.cv);
		markgen(s.gen);
	}
	markgen(curgen);
	markjob(curjob);
	for(jl := jobs; jl != nil; jl = tl jl)
		markjob(hd jl);
	for(jl = jobstail; jl != nil; jl = tl jl)
		markjob(hd jl);
	for(ul := unhandled; ul != nil; ul = tl ul)
		mark(hd ul);
	for(hl := helpers; hl != nil; hl = tl hl) {
		(ho, h) := hd hl;
		mark(ho);
		markv(h.it);
		markv(h.next);
		markv(h.fun);
		markv(h.inner);
		markv(h.innernext);
		if(h.items != nil)
			for(i = 0; i < len h.items; i++) {
				(a, b) := h.items[i];
				markv(a);
				markv(b);
			}
	}
	for(ol := joining; ol != nil; ol = tl ol)
		mark(hd ol);
	for(i = 0; i < nmods && modules != nil; i++)
		markmod(modules[i]);
	markmod(curmod);
	for(dl := dscopes; dl != nil; dl = tl dl)
		for(rsl := (hd dl).res; rsl != nil; rsl = tl rsl) {
			markv((hd rsl).v);
			mark((hd rsl).m);
		}
	for(dl = disposing; dl != nil; dl = tl dl)
		for(rsl2 := (hd dl).res; rsl2 != nil; rsl2 = tl rsl2) {
			markv((hd rsl2).v);
			mark((hd rsl2).m);
		}
	mark(pghooks);
}

# an object's references
markobj(o: ref Obj)
{
	if(o.sh != nil)
		mark(o.sh.proto);
	markvs(o.slots);
	markvs(o.elems);
	markenv(o.env);
	d := o.data;
	if(d == nil)
		return;
	pick x := d {
	Prim =>
		markv(x.v);
	Acc =>
		mark(x.get);
		mark(x.set);
	Bound =>
		mark(x.target);
		markv(x.this);
		markvs(x.args);
	Func =>
		mark(x.home);
		mark(x.privbrand);
		if(x.fields != nil)
			for(i := 0; i < len x.fields; i++) {
				f := x.fields[i];
				mark(f.meth);
				mark(f.getter);
				mark(f.setter);
				markv(f.kv);
				markenv(f.env);
			}
	Map =>
		markmap(x.m);
	Promise =>
		markv(x.v);
		for(l := x.reacts; l != nil; l = tl l)
			markreact(hd l);
	Args =>
		markvs(x.fr);
		markenv(x.env);
	Proxy =>
		mark(x.target);
		mark(x.handler);
	Gen =>
		markgen(x.g);
	Typed =>
		mark(x.buf);
	Iter =>
		mark(x.o);
		markv(x.v);
		mark(x.aux);
	Weak =>
		markv(x.target);
	Ns =>
		markmod(x.m);
	Resolver =>
		mark(x.p);
	Capexec =>
		markcap(x.cap);
	Native =>
		markv(x.v);
		markv(x.w);
	Pall =>
		if(x.st != nil) {
			mark(x.st.values);
			markcap(x.st.cap);
		}
	Finreg =>
		mark(x.cleanup);
		for(l := x.cells; l != nil; l = tl l) {
			(a, b, c) := hd l;
			markv(a);
			markv(b);
			markv(c);
		}
	Disp =>
		for(l := x.stack; l != nil; l = tl l) {
			(v, m, nil) := hd l;
			markv(v);
			mark(m);
		}
	Shape =>
		if(x.sh != nil)
			mark(x.sh.proto);
	}
}

trace()
{
	for(;;) {
		if(estk != nil) {
			e := hd estk;
			estk = tl estk;
			for(; e != nil; e = e.up) {
				markvs(e.v);
				mark(e.obj);
				if(e.up == nil || e.up.gcm == gcepoch)
					break;
				e.up.gcm = gcepoch;
			}
			continue;
		}
		if(nm == 0)
			break;
		o := mstk[--nm];
		mstk[nm] = nil;
		markobj(o);
	}
}

# ---- the collection ----

gccollect()
{
	t0 := sys->millisec();
	gchold++;
	gcepoch++;
	if(mstk == nil)
		mstk = array[1024] of ref Obj;
	nm = 0;
	estk = nil;
	if(gcdebug) sys->fprint(sys->fildes(2), "gc: roots\n");
	markroots();
	if(gcdebug) sys->fprint(sys->fildes(2), "gc: trace\n");
	trace();
	if(gcdebug) sys->fprint(sys->fildes(2), "gc: sweep %d\n", ngcreg);
	# sweep: the registry kept to what survived; the rest cleared
	j := 0;
	for(i := 0; i < ngcreg; i++) {
		o := gcreg[i];
		if(o.flags & Fmark) {
			o.flags &= ~Fmark;
			gcreg[j++] = o;
			continue;
		}
		if(gcdebug && o.cls == Ctyped)
			gcwhy(o, i);
		clearobj(o);
	}
	for(i = j; i < ngcreg; i++)
		gcreg[i] = nil;
	ngcreg = j;
	gclive = j;
	gcalloc = 0;
	gcwanted = 0;
	if(gcstress > 0)
		gcnext = gcstress;
	else {
		gcnext = 2 * j;
		if(gcnext < Gcmin)
			gcnext = Gcmin;
	}
	gchold--;
	gcruns++;
	gcms += sys->millisec() - t0;
	if(gcdebug) sys->fprint(sys->fildes(2), "gc: done, %d live\n", j);
}

gcdebug := 0;

# debugging: a typed array about to be cleared: is it in a rooted frame?
gcwhy(o: ref Obj, i: int)
{
	e := sys->fildes(2);
	sys->fprint(e, "gc: clearing typed array, registry %d of %d; nroot %d depth %d natdepth %d\n", i, ngcreg, nroot, depth, natdepth);
	s := 0;
	for(k := 0; k < nroot; k++) {
		a := rootfr[k];
		for(s = 0; a != nil && s < len a; s++)
			if(a[s].t == Tobj && a[s].o == o)
				sys->fprint(e, "gc:   in rootfr[%d] slot %d (len %d)\n", k, s, len a);
	}
	if(fr != nil)
		for(s = 0; s < len fr; s++)
			if(fr[s].t == Tobj && fr[s].o == o)
				sys->fprint(e, "gc:   in fr slot %d\n", s);
	for(ee := env; ee != nil; ee = ee.up)
		for(s = 0; ee.v != nil && s < len ee.v; s++)
			if(ee.v[s].t == Tobj && ee.v[s].o == o)
				sys->fprint(e, "gc:   in env slot %d (marked %d)\n", s, ee.gcm == gcepoch);
	for(s = 0; s < len vstk; s++)
		if(vstk[s].t == Tobj && vstk[s].o == o)
			sys->fprint(e, "gc:   in vstk %d (vsp %d)\n", s, vsp);
}

# an unreachable object: its references dropped, so that what it was
# part of comes apart; it stays an empty object, in case something
# the tracer could not see still has it
clearobj(o: ref Obj)
{
	if(o.data != nil)
		pick x := o.data {
		Gen =>
			# a coroutine parked for ever: stopped, its thread freed
			g := x.g;
			if(g != nil && g.started && g.state != Gdone) {
				alt {
				g.tocoro <-= nil =>
					;
				* =>
					;
				}
				g.state = Gdone;
				dropgen(g);
			}
		}
	o.sh = deadshape;
	o.slots = nil;
	o.elems = nil;
	o.alen = 0;
	o.env = nil;
	o.data = nil;
}

# Js->stress: collect at every nth allocation (0: as usual)
stress(n: int)
{
	gcstress = n;
	if(n > 0)
		gcnext = n;
	else
		gcnext = Gcmin;
}

gcreport(): string
{
	return sys->sprint("gc: %d collections, %d ms; %d objects live, %d on the registry", gcruns, gcms, gclive, ngcreg);
}
