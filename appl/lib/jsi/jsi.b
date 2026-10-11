implement Js;

#
# jsi - a JavaScript interpreter: the alternative to appl/lib/js's
# compiling engine, for the two to be measured against each other.
#
# It implements the same module interface (module/js.m), so a host
# loads one or the other by its path: /dis/lib/js/js.dis, or this,
# /dis/lib/jsi/jsi.dis.  It shares the front end (jslex, jsparse,
# jscheck) and the regular expressions (jsre) with appl/lib/js; the
# rest is its own.
#
# The design (docs/JSI-ENGINE.md): the parser's tree is made into a
# flat tree of int nodes with names resolved (jsicomp.b), which a
# recursive evaluator walks (jsieval.b) with the value it computes in
# registers.  Objects are Limbo objects, freed by Dis.  Generators and
# async functions are coroutines on Dis threads (jsigen.b).
#
#	jsival.b	values, atoms, shapes, objects, strings, maps
#	jsiobj.b	the object internal methods, conversions, comparisons
#	jsicomp.b	the tree, and making it
#	jsieval.b	the evaluator
#	jsigen.b	generators, async functions, promises, jobs
#	jsibuiltin.b	the realm; Object, Function, Symbol, errors, globals
#	jsiarray.b	Array
#	jsistring.b	String, Number, Math, JSON
#	jsicoll.b	Map, Set, weak collections, Promise, Reflect, Proxy, iterators
#	jsiregexp.b	RegExp
#	jsidate.b	Date
#	jsibig.b	BigInt
#	jsityped.b	ArrayBuffer, the typed arrays, DataView
#	jsimod.b	modules
#	jsidispose.b	using, DisposableStack, SuppressedError; async built-ins
#	jsigc.b	the realm's collector: cycles freed
#	jsidom.b	a web page's realm: the DOM's natives, the event loop, confinement, fetching
#

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "daytime.m";
	daytime: Daytime;

include "keyring.m";
	keyring: Keyring;
	IPint: import keyring;

include "jslex.m";
	jslex: Jslex;

include "jsparse.m";
	jsparse: Jsparse;
	Node, Kvar, Klet, Kconst, Kusing, Kawaitusing: import jsparse;

include "jscheck.m";
	jscheck: Jscheck;

include "jsre.m";
	jsre: Jsre;

include "draw.m";

include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/originfs.m";
	originfs: Originfs;

include "js.m";

include "jsival.b";
include "jsiobj.b";
include "jsicomp.b";
include "jsieval.b";
include "jsigen.b";
include "jsibuiltin.b";
include "jsiarray.b";
include "jsistring.b";
include "jsicoll.b";
include "jsiregexp.b";
include "jsidate.b";
include "jsibig.b";
include "jsityped.b";
include "jsimod.b";
include "jsidispose.b";
include "jsigc.b";
include "jsidom.b";

output: ref fn(s: string);

init(): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	jscheck = load Jscheck Jscheck->PATH;
	jsre = load Jsre Jsre->PATH;
	if(math == nil || jslex == nil || jsparse == nil || jscheck == nil || jsre == nil)
		return sys->sprint("cannot load the engine's modules: %r");
	keyring = load Keyring Keyring->PATH;
	jslex->init();
	jsparse->init();
	jscheck->init();
	jsre->init();
	resetstate();
	gcinit();
	valinit();
	atominit();
	shapeinit();
	compinit();
	glexinit();
	atomsinit();
	vstk = array[64] of V;
	vsp = 0;
	gchold++;
	{
		realminit();
	} exception e {
	"JS" =>
		return "making the realm: " + showexc(thrown);
	"*" =>
		return "making the realm: " + e;
	}
	gchold--;
	return nil;
}

# a module instance may be made a fresh realm again
resetstate()
{
	fr = nil;
	env = nil;
	curfn = nil;
	newt = nil;
	argc = 0;
	depth = 0;
	ctl = 0;
	ctlid = 0;
	jobs = nil;
	jobstail = nil;
	unhandled = nil;
	curgen = nil;
	livegens = nil;
	globalvars = nil;
	helpers = nil;
	rxcache = nil;
	protoepoch = 0;
	glexepoch = 0;
	nobjhash = 0;
	arrayvalues = arrayiternextfn = nil;
	joining = nil;
	hostfns = nil;
	loader = nil;
	modules = nil;
	nmods = 0;
	cururl = nil;
	lazyunit = nil;
	lazyunitsc = nil;
	lazychain = nil;
	iterresultsh = nil;
	disposing = nil;
	dscopes = nil;
}

setoutput(out: ref fn(s: string))
{
	output = out;
}

profile(nil: int)
{
}

profiled(nil: int): string
{
	return gcreport();
}

lazy(minlen: int)
{
	jsparse->setlazy(minlen);
}

jit(nil: int)
{
}

jitstats(): (int, int)
{
	return (0, 0);
}

# run a script, then the jobs
evalscript(src, name: string): (string, string)
{
	cururl = name;
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		return (nil, "SyntaxError: " + name + ":" + err);
	(pos, msg) := jscheck->check(prog);
	if(msg != nil)
		return (nil, sys->sprint("SyntaxError: %s:%d: %s", name, pos, msg));
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		pick p := prog {
		Program =>
			(c, cerr) := compilescript(p, src, 0, nil, 0);
			if(cerr != nil)
				return (nil, "SyntaxError: " + name + ": " + cerr);
			v := rununit(c, globalthis, nil);
			r := display(v);
			runjobsquiet();
			return (r, nil);
		}
	} exception e {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		ex := showexc(thrown);
		runjobsquiet();
		return (nil, ex);
	"JSgenret" or "JSopt" or "JSkill" or "JSnoclose" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		return (nil, "internal: stray " + e);
	}
	return (nil, "internal: not a program");
}

runjobsquiet()
{
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	while(pending()) {
		{
			runjob();
		} exception {
		"JS" =>
			depth = sdepth;
			vsp = svsp;
			rootreset(snroot);
		}
	}
}

evalmodule(src, url: string): (string, string)
{
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		runmodule(src, url);
		runjobsquiet();
		return ("undefined", nil);
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		ex := showexc(thrown);
		runjobsquiet();
		return (nil, ex);
	}
	return (nil, nil);
}

loader: ref fn(referrer, specifier: string): (string, string, string);

setloader(l: ref fn(referrer, specifier: string): (string, string, string))
{
	loader = l;
}

# ---- the host's functions ----

hostfns: array of ref fn(args: array of string): string;

deffn(path: string, f: ref fn(args: array of string): string)
{
	idx := len hostfns;
	nf := array[idx + 1] of ref fn(args: array of string): string;
	if(idx > 0)
		nf[0:] = hostfns;
	nf[idx] = f;
	hostfns = nf;
	(o, name) := pathobj(path, 1);
	h := mknative(Nhostfn, name, 0);
	h.data = ref Data.Native(intv(idx), undef, 0, nil);
	defprop(o, intern(name), objv(h), Awrite|Aconf);
}

pathobj(path: string, make: int): (ref Obj, string)
{
	o := global;
	for(;;) {
		for(i := 0; i < len path; i++)
			if(path[i] == '.')
				break;
		if(i == len path)
			return (o, path);
		k := intern(path[0:i]);
		v := get(o, k, objv(o));
		if(v.t != Tobj) {
			if(!make)
				return (nil, nil);
			v = objv(plainobj());
			defprop(o, k, v, Awrite|Aconf);
		}
		o = v.o;
		path = path[i+1:];
	}
}

hostcall(f: ref Obj, args: array of V): V
{
	idx := 0;
	pick d := f.data {
	Native =>
		idx = d.v.i;
	}
	a := array[len args] of string;
	for(i := 0; i < len args; i++)
		a[i] = tostr(args[i]);
	return strv(hostfns[idx](a));
}

callfn(path: string, args: array of string): (string, string)
{
	sdepth := depth;
	svsp := vsp;
	snroot := nroot;
	{
		(o, name) := pathobj(path, 0);
		if(o == nil)
			return (nil, nil);
		fv := get(o, intern(name), objv(o));
		if(!iscallable(fv))
			return (nil, nil);
		va := array[len args] of V;
		for(i := 0; i < len args; i++)
			va[i] = strv(args[i]);
		r := display(call(fv.o, objv(o), va));
		runjobsquiet();
		return (r, nil);
	} exception {
	"JS" =>
		depth = sdepth;
		vsp = svsp;
		rootreset(snroot);
		return (nil, showexc(thrown));
	}
}

# ---- test262's host object ----

N262evalscript, N262gc, N262createrealm, N262detach, N262dda: con Ndisposebase + 50 + iota;

test262()
{
	h := plainobj();
	defprop(global, intern("$262"), objv(h), Awrite|Aconf);
	defval(h, "global", globalthis, Awrite|Aconf);
	defmethod(h, "evalScript", N262evalscript, 1);
	defmethod(h, "gc", N262gc, 0);
	defmethod(h, "createRealm", N262createrealm, 0);
	defmethod(h, "detachArrayBuffer", N262detach, 1);
	defval(h, "agent", objv(plainobj()), Awrite|Aconf);
}

nat262(id: int, args: array of V): V
{
	case id {
	N262evalscript =>
		src := tostr(arg(args, 0));
		(prog, err) := jsparse->parse(src, 0, 0);
		if(err != nil)
			throwerr(ESyntax, err);
		(nil, msg) := jscheck->check(prog);
		if(msg != nil)
			throwerr(ESyntax, msg);
		pick p := prog {
		Program =>
			(c, cerr) := compilescript(p, src, 0, nil, 0);
			if(cerr != nil)
				throwerr(ESyntax, cerr);
			return rununit(c, globalthis, nil);
		}
	N262gc =>
		return undef;
	N262createrealm =>
		throwtype("$262.createRealm is not supported");
	N262detach =>
		detachbuffer(arg(args, 0));
		return nullv;
	}
	return undef;
}

detachbuffer(v: V)
{
	if(v.t != Tobj || v.o.cls != Cbuf)
		throwtype("not an ArrayBuffer");
	pick d := v.o.data {
	Buf =>
		d.b = nil;
		d.detached = 1;
	}
}

# a web page's realm: not yet

shutdown()
{
	gchold++;
	# stop the coroutines still waiting to be resumed
	for(l := livegens; l != nil; l = tl l) {
		g := hd l;
		alt {
		g.tocoro <-= nil =>
			;
		* =>
			;
		}
	}
	teardown();
	# and what was not reachable: the garbage since the last collection,
	# cycles reference counting cannot free, which the registry still lists
	for(i := 0; i < ngcreg; i++)
		if(gcreg[i] != nil)
			clearobj(gcreg[i]);
	gcreg = nil;
	ngcreg = 0;
	livegens = nil;
	global = nil;
	globalthis = undef;
	objproto = nil;
	funcproto = nil;
	arrproto = nil;
	fr = nil;
	env = nil;
	curfn = nil;
	newt = nil;
	jobs = nil;
	jobstail = nil;
	codes = nil;
	infos = nil;
	icsh = nil;
	icobj = nil;
	atomsym = nil;
	atomstr = nil;
	glexv = nil;
	vstk = nil;
	hostfns = nil;
	output = nil;
	loader = nil;
	helpers = nil;
	rxcache = nil;
	symregistry = nil;
	modules = nil;
	cu = nil;
	tenv = nil;
	th = nil;
	ro = nil;
	rs = nil;
	cv = undef;
	thrown = undef;
}

# A realm is a graph full of cycles (every constructor and its prototype,
# every closure and the scope that holds it), which only Dis's collector
# would free, and a busy emulator seldom runs it.  So a realm shut down
# is taken apart: every object reachable from its roots has its fields
# cleared, and reference counting frees the rest at once.
tdstk: list of ref Obj;
tdenv: list of ref Env;

teardown()
{
	tdstk = nil;
	tdenv = nil;
	tdpush(global);
	tdpush(objproto);
	tdpush(funcproto);
	tdpush(arrproto);
	tdpush(curfn);
	tdpush(newt);
	tdpush(ro);
	tdpush(th);
	tdv(thrown);
	tdv(cv);
	for(i := 0; i < len icobj; i++)
		tdpush(icobj[i]);
	for(i = 0; i < len infos; i++)
		if(infos[i] != nil)
			pick t := infos[i] {
			Tmpl =>
				tdpush(t.obj);
			}
	for(i = 0; i < nglex && i < len glexv; i++)
		tdv(glexv[i]);
	for(i = 0; i < len vstk; i++)
		tdv(vstk[i]);
	for(i = 0; i < natom && i < len atomsym; i++)
		tdpush(atomsym[i]);
	for(i = 0; i < nmods && modules != nil; i++) {
		m := modules[i];
		tdenv = m.env :: tdenv;
		tdpush(m.ns);
		tdpush(m.meta);
		tdpush(m.promise);
		tdv(m.err);
	}
	for(l := livegens; l != nil; l = tl l) {
		g := hd l;
		tdpush(g.f);
		tdpush(g.obj);
		tdenv = g.env :: tdenv;
		for(k := 0; k < len g.fr; k++)
			tdv(g.fr[k]);
	}
	for(jl := jobs; jl != nil; jl = tl jl)
		tdjob(hd jl);
	for(jl = jobstail; jl != nil; jl = tl jl)
		tdjob(hd jl);
	if(fr != nil)
		for(k := 0; k < len fr; k++)
			tdv(fr[k]);
	tdenv = env :: tdenv;
	if(symregistry != nil)
		tdmap(symregistry);
	for(;;) {
		if(tdenv != nil) {
			e := hd tdenv;
			tdenv = tl tdenv;
			for(; e != nil && e.v != nil; e = e.up) {
				for(k := 0; k < len e.v; k++)
					tdv(e.v[k]);
				e.v = nil;
				tdpush(e.obj);
				e.obj = nil;
			}
			continue;
		}
		if(tdstk == nil)
			break;
		o := hd tdstk;
		tdstk = tl tdstk;
		tdobj(o);
	}
}

tdjob(j: ref Job)
{
	pick x := j {
	Reaction =>
		tdreact(x.r);
		tdv(x.v);
	Thenable =>
		tdpush(x.p);
		tdv(x.x);
		tdpush(x.then);
	Call =>
		tdpush(x.f);
		for(i := 0; i < len x.args; i++)
			tdv(x.args[i]);
	}
}

tdreact(r: ref React)
{
	if(r == nil)
		return;
	tdpush(r.handler);
	if(r.cap != nil) {
		tdpush(r.cap.promise);
		tdpush(r.cap.resolve);
		tdpush(r.cap.reject);
	}
}

tdpush(o: ref Obj)
{
	if(o == nil || (o.flags & Fdead))
		return;
	o.flags |= Fdead;
	tdstk = o :: tdstk;
}

tdv(v: V)
{
	if(v.t >= Trope)
		tdpush(v.o);
}

tdmap(m: ref Hmap)
{
	for(i := 0; i < m.n; i++) {
		tdv(m.keys[i]);
		tdv(m.vals[i]);
	}
	m.keys = nil;
	m.vals = nil;
	m.hash = nil;
}

# an object's references followed, then cleared
tdobj(o: ref Obj)
{
	if(o.sh != nil) {
		tdpush(o.sh.proto);
		o.sh.proto = nil;
		o.sh.kid = nil;
	}
	o.sh = nil;
	if(o.slots != nil)
		for(i := 0; i < len o.slots; i++)
			tdv(o.slots[i]);
	o.slots = nil;
	if(o.elems != nil)
		for(j := 0; j < len o.elems; j++)
			tdv(o.elems[j]);
	o.elems = nil;
	if(o.env != nil)
		tdenv = o.env :: tdenv;
	o.env = nil;
	o.fun = nil;
	d := o.data;
	o.data = nil;
	if(d == nil)
		return;
	pick x := d {
	Prim =>
		tdv(x.v);
	Acc =>
		tdpush(x.get);
		tdpush(x.set);
	Bound =>
		tdpush(x.target);
		tdv(x.this);
		for(i := 0; i < len x.args; i++)
			tdv(x.args[i]);
	Func =>
		tdpush(x.home);
		tdpush(x.privbrand);
		for(i := 0; i < len x.fields; i++) {
			f := x.fields[i];
			tdpush(f.meth);
			tdpush(f.getter);
			tdpush(f.setter);
			tdv(f.kv);
			if(f.env != nil)
				tdenv = f.env :: tdenv;
		}
	Map =>
		tdmap(x.m);
	Promise =>
		tdv(x.v);
		for(l := x.reacts; l != nil; l = tl l)
			tdreact(hd l);
		x.reacts = nil;
	Args =>
		if(x.fr != nil)
			for(i := 0; i < len x.fr; i++)
				tdv(x.fr[i]);
		x.fr = nil;
		if(x.env != nil)
			tdenv = x.env :: tdenv;
		x.env = nil;
	Proxy =>
		tdpush(x.target);
		tdpush(x.handler);
	Gen =>
		g := x.g;
		tdpush(g.f);
		tdpush(g.obj);
		if(g.env != nil)
			tdenv = g.env :: tdenv;
		if(g.fr != nil)
			for(i := 0; i < len g.fr; i++)
				tdv(g.fr[i]);
		g.fr = nil;
		g.env = nil;
		g.obj = nil;
		if(g.cap != nil) {
			tdpush(g.cap.promise);
			tdpush(g.cap.resolve);
			tdpush(g.cap.reject);
		}
	Typed =>
		tdpush(x.buf);
	Iter =>
		tdpush(x.o);
		tdv(x.v);
		tdpush(x.aux);
	Weak =>
		tdv(x.target);
	Resolver =>
		tdpush(x.p);
	Capexec =>
		if(x.cap != nil) {
			tdpush(x.cap.promise);
			tdpush(x.cap.resolve);
			tdpush(x.cap.reject);
		}
	Native =>
		tdv(x.v);
		tdv(x.w);
	Pall =>
		if(x.st != nil) {
			tdpush(x.st.values);
			if(x.st.cap != nil) {
				tdpush(x.st.cap.promise);
				tdpush(x.st.cap.resolve);
				tdpush(x.st.cap.reject);
			}
		}
	Finreg =>
		tdpush(x.cleanup);
		for(l := x.cells; l != nil; l = tl l) {
			(a, b, c) := hd l;
			tdv(a);
			tdv(b);
			tdv(c);
		}
	Shape =>
		if(x.sh != nil) {
			tdpush(x.sh.proto);
			x.sh.proto = nil;
		}
	}
}
