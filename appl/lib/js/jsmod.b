#
# jsmod.b - modules (ECMAScript 2025 §16.2): loading, linking,
# evaluation, namespace objects, import.meta and import().  Included by js.b.
#
# A module's code runs as a coroutine: first to its Omodinit stop, which
# makes its environment and function declarations; the loader then
# points each import binding at the exporting module's slot (a Timport
# value, followed on every read), and later resumes it to run its body.
# A module whose top level awaits runs as an async function would.
#

Mstatus_new, Mstatus_linking, Mstatus_linked, Mstatus_evaluating, Mstatus_evaluated: con iota;

Mod: adt {
	id:	int;
	url:	string;
	code:	ref Code;
	g:	ref Genstate;
	env:	int;
	status:	int;
	err:	V;		# the evaluation's exception, if it threw
	failed:	int;
	imports:	list of (string, string, string);	# (specifier, import name, local name)
	localexports:	list of (string, string);	# (export name, local name)
	indirect:	list of (string, string, string);	# (export name, specifier, import name)
	stars:	list of string;
	requested:	list of string;
	resolved:	list of (string, int);	# specifier to module id
	ns:	int;		# its namespace object, or -1
	meta:	int;
	promise:	int;	# an async module's evaluation, or -1
	async:	int;
};

mods: array of ref Mod;
nmod := 0;
loader: ref fn(referrer, specifier: string): (string, string, string);

setloader(l: ref fn(referrer, specifier: string): (string, string, string))
{
	loader = l;
}

markmods()
{
	for(i := 1; i < nmod; i++) {
		m := mods[i];
		if(m == nil)
			continue;
		markgen(m.g);
		marko(m.env);
		markv(m.err);
		marko(m.ns);
		marko(m.meta);
		marko(m.promise);
		markcode(m.code);
	}
}

modbyurl(url: string): ref Mod
{
	for(i := 1; i < nmod; i++)
		if(mods[i] != nil && mods[i].url == url)
			return mods[i];
	return nil;
}

# the default loader: files, relative to the referrer's directory
fileloader(referrer, spec: string): (string, string, string)
{
	url := resolvepath(referrer, spec);
	fd := sys->open(url, Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("cannot load module %s: %r", spec));
	buf := array[0] of byte;
	b := array[65536] of byte;
	for(;;) {
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = b[0:n];
		buf = nb;
	}
	return (url, jslex->utf16(buf), nil);
}

resolvepath(referrer, spec: string): string
{
	if(len spec > 0 && spec[0] == '/')
		return cleanpath(spec);
	dir := "";
	for(i := len referrer - 1; i >= 0; i--)
		if(referrer[i] == '/') {
			dir = referrer[0:i+1];
			break;
		}
	return cleanpath(dir + spec);
}

cleanpath(p: string): string
{
	(nil, parts) := sys->tokenize(p, "/");
	out: list of string;
	for(; parts != nil; parts = tl parts) {
		s := hd parts;
		if(s == ".")
			continue;
		if(s == ".." && out != nil && hd out != "..") {
			out = tl out;
			continue;
		}
		out = s :: out;
	}
	r := "";
	for(; out != nil; out = tl out)
		r = "/" + hd out + r;
	if(len p > 0 && p[0] != '/')
		r = r[1:];
	return r;
}

# load a module and (recursively) what it imports; its record
loadmodule(url, src: string): ref Mod
{
	m := modbyurl(url);
	if(m != nil)
		return m;
	if(len url > 5 && url[len url-5:] == ".json")
		src = "export default " + jsonmodulesource(src) + ";";
	(prog, err) := jsparse->parse(src, 1, 1);
	if(err != nil)
		throwerr(SyntaxError, url + ": " + err);
	if(nmod == 0) {
		mods = array[16] of ref Mod;
		nmod = 1;
	}
	if(nmod == len mods) {
		a := array[2 * nmod] of ref Mod;
		a[0:] = mods;
		mods = a;
	}
	id := nmod++;
	m = ref Mod(id, url, nil, nil, -1, Mstatus_new, undef, 0, nil, nil, nil, nil, nil, nil, -1, -1, -1, 0);
	mods[id] = m;
	pick p := prog {
	Program =>
		m.code = compilemodule(p, src, id);
		setfile(m.code, url);
		setmodid(m.code, id);
		m.async = (m.code.flags & Casync) != 0;
		entries(m, p.body);
	}
	for(l := revstrs(m.requested); l != nil; l = tl l) {
		spec := hd l;
		if(lookupres(m, spec) >= 0)
			continue;
		ld := loader;
		if(ld == nil)
			ld = fileloader;
		(rurl, rsrc, lerr) := ld(url, spec);
		if(lerr != nil)
			throwerr(SyntaxError, lerr);
		dep := modbyurl(rurl);
		if(dep == nil)
			dep = loadmodule(rurl, rsrc);
		m.resolved = (spec, dep.id) :: m.resolved;
	}
	return m;
}

# a JSON module's source, as an expression the module exports: checked as JSON first
jsonmodulesource(src: string): string
{
	p := ref Jp(src, 0);
	jsonws(p);
	jsonvalue(p);
	jsonws(p);
	if(p.i < len src)
		jsonerr(p);
	return "JSON.parse(" + jsonquote(src) + ")";
}

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

setmodid(c: ref Code, id: int)
{
	c.modid = id;
	for(i := 0; i < len c.funcs; i++)
		setmodid(c.funcs[i], id);
}

lookupres(m: ref Mod, spec: string): int
{
	for(l := m.resolved; l != nil; l = tl l)
		if((hd l).t0 == spec)
			return (hd l).t1;
	return -1;
}

addreq(m: ref Mod, spec: string)
{
	for(l := m.requested; l != nil; l = tl l)
		if(hd l == spec)
			return;
	m.requested = spec :: m.requested;
}

# the import and export entries of a module's statements (§16.2.1.6.1)
entries(m: ref Mod, body: array of ref Node)
{
	imported: list of (string, string, string);
	for(i := 0; i < len body; i++)
		pick x := body[i] {
		Import =>
			addreq(m, x.source);
			for(j := 0; j < len x.specs; j++)
				pick sp := x.specs[j] {
				ImportSpec =>
					imp := sp.imported;
					if(sp.kind == Jsparse->Inamespace)
						imp = "*";
					imported = (x.source, imp, sp.local) :: imported;
				}
		}
	m.imports = imported;
	for(i = 0; i < len body; i++)
		pick x := body[i] {
		Export =>
			if(x.source != nil)
				addreq(m, x.source);
			if(x.all) {
				if(x.allas != nil)
					m.indirect = (x.allas, x.source, "*") :: m.indirect;
				else
					m.stars = x.source :: m.stars;
				continue;
			}
			if(x.default) {
				local := "*default*";
				if(x.decl != nil)
					pick d := x.decl {
					Func =>
						if(d.flags & Jsparse->Fdecl && d.id != nil)
							local = idname(d.id);
					Class =>
						if(d.decl && d.id != nil)
							local = idname(d.id);
					}
				m.localexports = ("default", local) :: m.localexports;
				continue;
			}
			if(x.decl != nil) {
				pick d := x.decl {
				Var =>
					for(l := patnames(x.decl, nil); l != nil; l = tl l)
						m.localexports = (hd l, hd l) :: m.localexports;
				Func =>
					m.localexports = (idname(d.id), idname(d.id)) :: m.localexports;
				Class =>
					m.localexports = (idname(d.id), idname(d.id)) :: m.localexports;
				}
				continue;
			}
			for(j := 0; j < len x.specs; j++)
				pick sp := x.specs[j] {
				ExportSpec =>
					if(x.source != nil) {
						m.indirect = (sp.exported, x.source, sp.local) :: m.indirect;
						continue;
					}
					# a re-export of an import is indirect
					found := 0;
					for(il := imported; il != nil; il = tl il) {
						(src, imp, loc) := hd il;
						if(loc == sp.local) {
							found = 1;
							if(imp == "*")
								m.localexports = (sp.exported, sp.local) :: m.localexports;
							else
								m.indirect = (sp.exported, src, imp) :: m.indirect;
							break;
						}
					}
					if(!found)
						m.localexports = (sp.exported, sp.local) :: m.localexports;
				}
		}
}

# ---- linking ----

# GetExportedNames
exportednames(m: ref Mod, visited: list of int): list of string
{
	if(hasint(visited, m.id))
		return nil;
	visited = m.id :: visited;
	names: list of string;
	for(l := m.localexports; l != nil; l = tl l)
		names = addname(names, (hd l).t0);
	for(il := m.indirect; il != nil; il = tl il)
		names = addname(names, (hd il).t0);
	for(sl := m.stars; sl != nil; sl = tl sl) {
		dep := mods[lookupres(m, hd sl)];
		for(nl := exportednames(dep, visited); nl != nil; nl = tl nl)
			if(hd nl != "default")
				names = addname(names, hd nl);
	}
	return names;
}

addname(l: list of string, s: string): list of string
{
	for(x := l; x != nil; x = tl x)
		if(hd x == s)
			return l;
	return s :: l;
}

# ResolveExport: (module id, local binding name), with "*namespace*" for
# a namespace; id 0: not found; id -1: ambiguous
resolveexport(m: ref Mod, name: string, set: list of (int, string)): (int, string)
{
	for(l := set; l != nil; l = tl l)
		if((hd l).t0 == m.id && (hd l).t1 == name)
			return (0, nil);	# a cycle
	set = (m.id, name) :: set;
	for(el := m.localexports; el != nil; el = tl el)
		if((hd el).t0 == name)
			return (m.id, (hd el).t1);
	for(il := m.indirect; il != nil; il = tl il) {
		(en, spec, imp) := hd il;
		if(en == name) {
			dep := mods[lookupres(m, spec)];
			if(imp == "*")
				return (dep.id, "*namespace*");
			return resolveexport(dep, imp, set);
		}
	}
	if(name == "default")
		return (0, nil);
	starid := 0;
	starname := "";
	for(sl := m.stars; sl != nil; sl = tl sl) {
		dep := mods[lookupres(m, hd sl)];
		(rid, rname) := resolveexport(dep, name, set);
		if(rid == -1)
			return (-1, nil);
		if(rid > 0) {
			if(starid == 0) {
				starid = rid;
				starname = rname;
			} else if(starid != rid || starname != rname)
				return (-1, nil);
		}
	}
	return (starid, starname);
}

# a module's binding slot, by name
modslot(m: ref Mod, name: string): int
{
	pick d := odata[m.env] {
	Env =>
		a := intern(name);
		for(i := 0; i < len d.scope.names; i++)
			if(d.scope.names[i] == a)
				return i;
	}
	return -1;
}

# Link: instantiate every module in the graph, then point the imports
linkmodule(m: ref Mod)
{
	instantiate(m);
	wire(m, nil);
}

instantiate(m: ref Mod)
{
	if(m.status != Mstatus_new)
		return;
	m.status = Mstatus_linking;
	for(l := m.resolved; l != nil; l = tl l)
		instantiate(mods[(hd l).t1]);
	# run the code to its stop: the environment, the function declarations
	c := m.code;
	dummy := newobj(Kord, -1);
	g := ref Genstate(Gstart, c, dummy, nil, 0, -1, -1, undef, 0, undef, m.async, -1, -1, nil, 0, 0);
	m.g = g;
	nb := sp;
	need := nb + c.nregs + 8;
	if(need > len vs)
		growvs(need);
	for(i := 0; i < c.nregs; i++)
		vs[nb+i] = undef;
	sp = nb + c.nregs;
	pushframe(Frame(c, nb, 0, -1, 0, g, 1));
	run();
	sp = nb;
	m.env = g.regs[Renv].x;
	m.status = Mstatus_linked;
}

wire(m: ref Mod, done: list of int): list of int
{
	if(hasint(done, m.id))
		return done;
	done = m.id :: done;
	for(l := m.resolved; l != nil; l = tl l)
		done = wire(mods[(hd l).t1], done);
	# indirect exports must resolve
	for(il := m.indirect; il != nil; il = tl il) {
		(en, nil, nil) := hd il;
		(rid, nil) := resolveexport(m, en, nil);
		if(rid <= 0)
			throwerr(SyntaxError, "the requested module does not provide an export named '" + en + "'");
	}
	for(ml := m.imports; ml != nil; ml = tl ml) {
		(spec, imp, local) := hd ml;
		dep := mods[lookupres(m, spec)];
		slot := modslot(m, local);
		if(imp == "*") {
			oslots[m.env][slot] = objv(namespace(dep));
			continue;
		}
		(rid, rname) := resolveexport(dep, imp, nil);
		if(rid == -1)
			throwerr(SyntaxError, "the requested module contains conflicting star exports for name '" + imp + "'");
		if(rid == 0)
			throwerr(SyntaxError, "the requested module does not provide an export named '" + imp + "'");
		target := mods[rid];
		if(rname == "*namespace*") {
			oslots[m.env][slot] = objv(namespace(target));
			continue;
		}
		ts := modslot(target, rname);
		oslots[m.env][slot] = V(Timport, target.env, real ts);
	}
	return done;
}

# ---- evaluation ----

evaluatemodule(m: ref Mod)
{
	if(m.status == Mstatus_evaluated || m.status == Mstatus_evaluating) {
		if(m.failed)
			throwv(m.err);
		return;
	}
	m.status = Mstatus_evaluating;
	{
		for(l := revres(m.resolved); l != nil; l = tl l) {
			dep := mods[(hd l).t1];
			evaluatemodule(dep);
			# an async dependency: wait for it
			if(dep.async && dep.promise >= 0)
				waitpromise(dep.promise);
		}
		g := m.g;
		if(m.async) {
			pr := newpromise(ipromisector);
			m.promise = pr;
			g.promise = pr;
			asyncstep(g, Rnext, undef);
		} else
			resumegen(g, Rnext, undef, -1);
	} exception e {
	"js:throw" =>
		m.failed = 1;
		m.err = thrown;
		m.status = Mstatus_evaluated;
		raise e;
	}
	m.status = Mstatus_evaluated;
}

revres(l: list of (string, int)): list of (string, int)
{
	r: list of (string, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# run jobs until a promise settles; its rejection is thrown
waitpromise(p: int)
{
	d := promisedata(p);
	while(d.state == Ppending && (jobs != nil || jobstail != nil))
		runjobs1();
	if(d.state == Prejected)
		throwv(d.result);
}

# one job from the queue
runjobs1()
{
	if(jobs == nil) {
		for(; jobstail != nil; jobstail = tl jobstail)
			jobs = hd jobstail :: jobs;
	}
	if(jobs == nil)
		return;
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
}

# a module from source, linked and evaluated (Js->evalmodule)
runmodule(src, url: string)
{
	m := loadmodule(url, src);
	linkmodule(m);
	evaluatemodule(m);
	if(m.async && m.promise >= 0)
		waitpromise(m.promise);
}

# ---- namespace objects (§10.4.6) ----

namespace(m: ref Mod): int
{
	if(m.ns >= 0)
		return m.ns;
	h := newobj(Kmodns, -1);
	oflags[h] &= ~Oext;
	odata[h] = ref Data.Prim(num(real m.id));
	defown(h, asymtostrtag, 0, strv("Module"));
	m.ns = h;
	return h;
}

nsmod(h: int): ref Mod
{
	pick d := odata[h] {
	Prim =>
		return mods[int d.v.n];
	}
	return nil;
}

# the namespace's export names, sorted
nsnames(m: ref Mod): array of string
{
	l := exportednames(m, nil);
	r: list of string;
	for(; l != nil; l = tl l) {
		(rid, nil) := resolveexport(m, hd l, nil);
		if(rid > 0)
			r = hd l :: r;
	}
	a := array[len r] of string;
	for(i := 0; r != nil; r = tl r)
		a[i++] = hd r;
	for(i = 1; i < len a; i++) {
		x := a[i];
		j := i - 1;
		while(j >= 0 && a[j] > x) {
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = x;
	}
	return a;
}

nsvalue(m: ref Mod, name: string): V
{
	(rid, rname) := resolveexport(m, name, nil);
	if(rid <= 0)
		return undef;
	t := mods[rid];
	if(rname == "*namespace*")
		return objv(namespace(t));
	slot := modslot(t, rname);
	v := oslots[t.env][slot];
	if(v.t == Timport)
		v = oslots[v.x][int v.n];
	if(v.t == Tempty)
		throwerr(ReferenceError, "cannot access '" + name + "' before initialization");
	return v;
}

isnsname(m: ref Mod, name: string): int
{
	(rid, nil) := resolveexport(m, name, nil);
	return rid > 0;
}

modnsgetown(h, k: int): (int, ref Desc)
{
	if(issymkey(k)) {
		(ok, v, a) := getownprop(h, k);
		if(!ok)
			return (0, nil);
		return (1, ref Desc(Hvalue|Hwrite|Henum|Hconf, v, undef, undef, a));
	}
	m := nsmod(h);
	name := keystr(k);
	if(!isnsname(m, name))
		return (0, nil);
	v := nsvalue(m, name);
	return (1, ref Desc(Hvalue|Hwrite|Henum|Hconf, v, undef, undef, Awrite|Aenum));
}

modnsdefine(h, k: int, d: ref Desc): int
{
	if(issymkey(k))
		return ordinarydefine(h, k, d);
	(found, cur) := modnsgetown(h, k);
	if(!found)
		return 0;
	if((d.has & Hconf) && (d.attrs & Aconf))
		return 0;
	if((d.has & Henum) && (d.attrs & Aenum) == 0)
		return 0;
	if(isaccdesc(d))
		return 0;
	if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
		return 0;
	if(d.has & Hvalue)
		return samevalue(d.value, cur.value);
	return 1;
}

modnsdelete(h, k: int): int
{
	if(issymkey(k)) {
		(found, d) := getown(h, k);
		if(!found)
			return 1;
		if((d.attrs & Aconf) == 0)
			return 0;
		removeown(h, k);
		return 1;
	}
	return !isnsname(nsmod(h), keystr(k));
}

modnsownkeys(h: int): array of int
{
	names := nsnames(nsmod(h));
	r := array[len names + 1] of int;
	for(i := 0; i < len names; i++)
		r[i] = strkey(names[i]);
	r[len names] = asymtostrtag;
	return r;
}

# ---- import.meta and import() ----

importmeta(c: ref Code): V
{
	if(c.modid <= 0)
		throwerr(SyntaxError, "import.meta outside a module");
	m := mods[c.modid];
	if(m.meta < 0) {
		m.meta = newobj(Kord, -1);
		defown(m.meta, intern("url"), Adefault, strv(m.url));
	}
	return objv(m.meta);
}

# import(specifier, options): a promise for the namespace
dynimport(spec, opts: V): V
{
	pr := newpromise(ipromisector);
	sp0 := sp;
	push(objv(pr));
	referrer := code.file;
	if(code.modid > 0)
		referrer = mods[code.modid].url;
	{
		s := tostring(spec);
		if(opts.t != Tundef) {
			if(opts.t != Tobj)
				typeerr("the second argument to import() must be an object");
			w := getv(opts, intern("with"));
			if(w.t != Tundef) {
				if(w.t != Tobj)
					typeerr("the 'with' option to import() must be an object");
				ks := ownkeys(w.x);
				for(i := 0; i < len ks; i++) {
					if(issymkey(ks[i]))
						continue;
					(found, d) := getown(w.x, ks[i]);
					if(found && (d.attrs & Aenum)) {
						v := get(w.x, ks[i], w);
						if(v.t != Tstr)
							typeerr("import attribute values must be strings");
					}
				}
			}
		}
		# load, link and evaluate in a job of its own, after the caller
		f := nativefn("", 0, importjob);
		setcap(f, array[] of {objv(pr), strv(s), strv(referrer)});
		enqueue(ref Job.Call(objv(f), nil));
	} exception e {
	"js:throw" =>
		rejectpromise(pr, thrown);
	}
	sp = sp0;
	return objv(pr);
}

importjob(nil: V, nil, nil: int, nil: V, f: int): V
{
	pr := capof(f, 0).x;
	spec := str(capof(f, 1).x);
	referrer := str(capof(f, 2).x);
	{
		ld := loader;
		if(ld == nil)
			ld = fileloader;
		(url, src, err) := ld(referrer, spec);
		if(err != nil)
			throwerr(TypeError, err);
		m := loadmodule(url, src);
		linkmodule(m);
		evaluatemodule(m);
		if(m.async && m.promise >= 0) {
			# resolve when its evaluation does
			ns := namespace(m);
			ok := nativefn("", 1, returnvalue);
			setcap(ok, array[] of {objv(ns)});
			(res, rej) := resolvingfns(pr);
			performthencap(m.promise, objv(ok), undef, pr, objv(res), objv(rej));
			return undef;
		}
		resolvepromise(pr, objv(namespace(m)));
	} exception e {
	"js:throw" =>
		rejectpromise(pr, thrown);
	}
	return undef;
}
