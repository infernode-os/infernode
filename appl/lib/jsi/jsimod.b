#
# jsimod.b - modules: loading, linking, evaluation, namespace objects,
# import.meta and import().  The records and the resolution follow
# appl/lib/js/jsmod.b's.
#
# Every top-level binding of a module lives in its Env, so that other
# modules can be linked to it: an imported name compiles to Nimportget,
# which reads through the module's link for it to the exporter's slot
# (or namespace), so bindings are live.  A module is instantiated by
# running its prologue (the Env, the function declarations), linked,
# then evaluated by running its body; one that awaits at its top level
# runs as an async coroutine.
#

Mnew, Mlinking, Mlinked, Mevaluating, Mevaluated: con iota;

Module: adt {
	id:	int;
	url:	string;
	code:	ref Code;
	sc:	ref Scope;
	env:	ref Env;
	status:	int;
	err:	V;
	failed:	int;
	imports:	array of ref Imp;
	links:	array of ref Link;
	localexports:	list of (string, string);	# export name, local name
	indirect:	list of (string, string, string);	# export name, specifier, import name ("*": a namespace)
	stars:	list of string;
	requested:	list of string;
	resolved:	list of (string, ref Module);
	ns:	ref Obj;
	meta:	ref Obj;
	async:	int;
	promise:	ref Obj;
};

Imp: adt {
	spec:	string;
	name:	string;	# "*": the namespace
	local:	string;
};

Link: adt {
	env:	ref Env;
	slot:	int;
	ns:	ref Obj;
};

modules: array of ref Module;
nmods := 0;
curmod: ref Module;	# the module being compiled

modbyurl(url: string): ref Module
{
	for(i := 0; i < nmods; i++)
		if(modules[i].url == url)
			return modules[i];
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
	if(len p > 0 && p[0] != '/' && len r > 0)
		r = r[1:];
	return r;
}

# load a module and what it imports, recursively: its record
loadmodule(url, src: string): ref Module
{
	m := modbyurl(url);
	if(m != nil)
		return m;
	if(len url > 5 && url[len url-5:] == ".json")
		src = "export default JSON.parse(" + jsonquote(src) + ");";
	(prog, err) := jsparse->parse(src, 1, 1);
	if(err != nil)
		throwerr(ESyntax, url + ": " + err);
	(pos, msg) := jscheck->check(prog);
	if(msg != nil)
		throwerr(ESyntax, sys->sprint("%s:%d: %s", url, pos, msg));
	if(modules == nil)
		modules = array[16] of ref Module;
	if(nmods == len modules) {
		a := array[2 * nmods] of ref Module;
		a[0:] = modules;
		modules = a;
	}
	m = ref Module(nmods, url, nil, nil, nil, Mnew, undef, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, nil);
	modules[nmods++] = m;
	pick p := prog {
	Program =>
		entries(m, p.body);
		(c, cerr) := compilemodule(p, src, m);
		if(cerr != nil)
			throwerr(ESyntax, url + ": " + cerr);
		m.code = c;
		m.async = (c.flags & Casync) != 0;
	}
	# a host may start fetching what the module imports all at once
	if(prefetcher != nil && m.requested != nil)
		prefetcher(url, revstrs(m.requested));
	for(l := revstrs(m.requested); l != nil; l = tl l) {
		spec := hd l;
		if(lookupres(m, spec) != nil)
			continue;
		ld := loader;
		if(ld == nil)
			ld = fileloader;
		(rurl, rsrc, lerr) := ld(url, spec);
		if(lerr != nil)
			throwerr(ESyntax, lerr);
		dep := modbyurl(rurl);
		if(dep == nil)
			dep = loadmodule(rurl, rsrc);
		m.resolved = (spec, dep) :: m.resolved;
	}
	return m;
}

prefetcher: ref fn(referrer: string, specifiers: list of string);

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

lookupres(m: ref Module, spec: string): ref Module
{
	for(l := m.resolved; l != nil; l = tl l) {
		(s, d) := hd l;
		if(s == spec)
			return d;
	}
	return nil;
}

addreq(m: ref Module, spec: string)
{
	for(l := m.requested; l != nil; l = tl l)
		if(hd l == spec)
			return;
	m.requested = spec :: m.requested;
}

# the import and export entries of a module's statements
entries(m: ref Module, body: array of ref Node)
{
	imps: list of ref Imp;
	ni := 0;
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
					else if(sp.kind == Jsparse->Idefault)
						imp = "default";
					imps = ref Imp(x.source, imp, sp.local) :: imps;
					ni++;
				}
		}
	m.imports = array[ni] of ref Imp;
	for(i = ni - 1; i >= 0; i--) {
		m.imports[i] = hd imps;
		imps = tl imps;
	}
	m.links = array[ni] of ref Link;
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
						if(d.id != nil)
							local = idname(d.id);
					Class =>
						if(d.id != nil)
							local = idname(d.id);
					}
				m.localexports = ("default", local) :: m.localexports;
				continue;
			}
			if(x.decl != nil) {
				pick d := x.decl {
				Var =>
					for(k := 0; k < len d.decls; k++)
						pick dd := d.decls[k] {
						Decl =>
							for(l := boundnames(dd.id); l != nil; l = tl l)
								m.localexports = (hd l, hd l) :: m.localexports;
						}
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
					for(k := 0; k < len m.imports; k++) {
						im := m.imports[k];
						if(im.local == sp.local) {
							found = 1;
							if(im.name == "*")
								m.localexports = (sp.exported, sp.local) :: m.localexports;
							else
								m.indirect = (sp.exported, im.spec, im.name) :: m.indirect;
							break;
						}
					}
					if(!found)
						m.localexports = (sp.exported, sp.local) :: m.localexports;
				}
		}
}

# the names a binding pattern binds
boundnames(n: ref Node): list of string
{
	if(n == nil)
		return nil;
	pick x := n {
	Ident =>
		return x.name :: nil;
	ArrayPat =>
		r: list of string;
		for(i := 0; i < len x.elems; i++)
			r = appendl(r, boundnames(x.elems[i]));
		return r;
	ObjectPat =>
		r: list of string;
		for(i := 0; i < len x.props; i++)
			pick p := x.props[i] {
			Prop =>
				r = appendl(r, boundnames(p.value));
			Rest =>
				r = appendl(r, boundnames(p.arg));
			}
		return r;
	AssignPat =>
		return boundnames(x.target);
	Rest =>
		return boundnames(x.arg);
	}
	return nil;
}

appendl(a, b: list of string): list of string
{
	if(a == nil)
		return b;
	return hd a :: appendl(tl a, b);
}

# ---- compiling a module ----

compilemodule(prog: ref Node.Program, src: string, m: ref Module): (ref Code, string)
{
	saved := cu;
	savedmod := curmod;
	curmod = m;
	cururl = m.url;
	cu = newunit(src);
	cu.ismod = 1;
	code := ref Code;
	code.flags = Cscript | Cstrict | Cmodule;
	code.src = cu.src;
	code.spos = 0;
	code.send = len src;
	code.fields = -1;
	addcode(code);
	fs := ref Fs;
	fs.code = code;
	fs.strict = 1;
	fs.nframe = 1;
	r: (ref Code, string);
	{
		cu.fs = fs;
		s := openscope(Smodule);
		s.modid = m.id + 1;
		fs.sc = s;
		hoistvars(prog.body, s, 1);
		lexdecls(prog.body, s, 1);
		# export default's binding, when it names no declaration
		for(i := 0; i < len prog.body; i++)
			pick x := prog.body[i] {
			Export =>
				if(x.default) {
					named := 0;
					pick d := x.decl {
					Func =>
						named = d.id != nil;
					Class =>
						named = d.id != nil;
					}
					if(!named)
						declare(s, "*default*", Bconst, x.end);
				}
			}
		# the imports: bindings read through links
		for(i = 0; i < len m.imports; i++) {
			b := declare(s, m.imports[i].local, Bimport, 0);
			b.argpos = i;
		}
		for(l := s.binds; l != nil; l = tl l)
			if((hd l).kind != Bimport)
				(hd l).captured = 1;
		fnodes := hoistfuncs(prog.body);
		# an anonymous default function is hoisted too
		for(i = 0; i < len prog.body; i++)
			pick x := prog.body[i] {
			Export =>
				if(x.default && x.decl != nil)
					pick d := x.decl {
					Func =>
						if(d.id == nil)
							fnodes = appendi(fnodes, varref("*default*", Minit, funcexpr(d, "default")));
					}
			}
		body := usingwrap(prog.body, stmts(prog.body));
		closescope(s);
		m.sc = s;
		pro: list of int;
		np := 0;
		if(s.needenv) {
			pro = e2(Nmkenv, s.nenv, addsci(s.sci)) :: pro;
			np++;
		}
		for(; fnodes != nil; fnodes = tl fnodes) {
			pro = hd fnodes :: pro;
			np++;
		}
		if(np > 0)
			code.prologue = e2(Nseqs, addkids(pro, np), np);
		else
			code.prologue = -1;
		code.body = body;
		code.nframe = fs.nframe;
		fixup();
		r = (code, nil);
	} exception {
	"JScompile" =>
		r = (nil, cu.err);
	}
	cu = saved;
	curmod = savedmod;
	return r;
}

appendi(l: list of int, x: int): list of int
{
	if(l == nil)
		return x :: nil;
	return hd l :: appendi(tl l, x);
}

# ---- linking ----

exportednames(m: ref Module, visited: list of ref Module): list of string
{
	for(v := visited; v != nil; v = tl v)
		if(hd v == m)
			return nil;
	visited = m :: visited;
	names: list of string;
	for(l := m.localexports; l != nil; l = tl l) {
		(en, nil) := hd l;
		names = addname(names, en);
	}
	for(il := m.indirect; il != nil; il = tl il) {
		(en, nil, nil) := hd il;
		names = addname(names, en);
	}
	for(sl := m.stars; sl != nil; sl = tl sl) {
		dep := lookupres(m, hd sl);
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

Resolved: adt {
	m:	ref Module;
	name:	string;	# "*namespace*" for a namespace
	ambiguous:	int;
};

# ResolveExport: nil if not found
resolveexport(m: ref Module, name: string, set: list of (ref Module, string)): ref Resolved
{
	for(l := set; l != nil; l = tl l) {
		(sm, sn) := hd l;
		if(sm == m && sn == name)
			return nil;	# a cycle
	}
	set = (m, name) :: set;
	for(el := m.localexports; el != nil; el = tl el) {
		(en, local) := hd el;
		if(en == name)
			return ref Resolved(m, local, 0);
	}
	for(il := m.indirect; il != nil; il = tl il) {
		(en, spec, imp) := hd il;
		if(en == name) {
			dep := lookupres(m, spec);
			if(imp == "*")
				return ref Resolved(dep, "*namespace*", 0);
			return resolveexport(dep, imp, set);
		}
	}
	if(name == "default")
		return nil;
	star: ref Resolved;
	for(sl := m.stars; sl != nil; sl = tl sl) {
		dep := lookupres(m, hd sl);
		r := resolveexport(dep, name, set);
		if(r == nil)
			continue;
		if(r.ambiguous)
			return r;
		if(star == nil)
			star = r;
		else if(star.m != r.m || star.name != r.name)
			return ref Resolved(nil, nil, 1);
	}
	return star;
}

# a module's binding slot by name
modslot(m: ref Module, name: string): int
{
	for(l := m.sc.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.name == name) {
			if(b.kind == Bimport)
				return -2 - b.argpos;	# an import re-exported: follow its link
			return b.slot;
		}
	}
	return -1;
}

instantiate(m: ref Module)
{
	if(m.status != Mnew)
		return;
	m.status = Mlinking;
	for(l := m.resolved; l != nil; l = tl l) {
		(nil, dep) := hd l;
		instantiate(dep);
	}
	# the prologue: the environment and the function declarations
	c := m.code;
	sfr := fr;
	senv := env;
	sfn := curfn;
	fr = array[c.nframe] of V;
	env = nil;
	{
		if(c.prologue >= 0)
			ev(c.prologue);
	} exception {
	"JS*" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		raise;
	}
	m.env = env;
	fr = sfr;
	env = senv;
	curfn = sfn;
	m.status = Mlinked;
}

wire(m: ref Module, done: list of ref Module): list of ref Module
{
	for(d := done; d != nil; d = tl d)
		if(hd d == m)
			return done;
	done = m :: done;
	for(l := m.resolved; l != nil; l = tl l) {
		(nil, dep) := hd l;
		done = wire(dep, done);
	}
	for(il := m.indirect; il != nil; il = tl il) {
		(en, nil, nil) := hd il;
		r := resolveexport(m, en, nil);
		if(r == nil || r.ambiguous)
			throwerr(ESyntax, "The requested module does not provide an export named '" + en + "'");
	}
	for(i := 0; i < len m.imports; i++) {
		im := m.imports[i];
		dep := lookupres(m, im.spec);
		if(im.name == "*") {
			m.links[i] = ref Link(nil, -1, namespace(dep));
			continue;
		}
		r := resolveexport(dep, im.name, nil);
		if(r == nil)
			throwerr(ESyntax, "The requested module '" + im.spec + "' does not provide an export named '" + im.name + "'");
		if(r.ambiguous)
			throwerr(ESyntax, "The requested module '" + im.spec + "' contains conflicting star exports for name '" + im.name + "'");
		if(r.name == "*namespace*") {
			m.links[i] = ref Link(nil, -1, namespace(r.m));
			continue;
		}
		m.links[i] = linkto(r.m, r.name);
	}
	return done;
}

# the link to module t's binding name (an import of t's own followed)
linkto(t: ref Module, name: string): ref Link
{
	s := modslot(t, name);
	if(s <= -2) {
		l := t.links[-2 - s];
		if(l == nil) {
			# not wired yet (a cycle): resolve it now
			im := t.imports[-2 - s];
			dep := lookupres(t, im.spec);
			if(im.name == "*")
				return ref Link(nil, -1, namespace(dep));
			r := resolveexport(dep, im.name, nil);
			if(r == nil || r.ambiguous)
				throwerr(ESyntax, "The requested module does not provide an export named '" + im.name + "'");
			if(r.name == "*namespace*")
				return ref Link(nil, -1, namespace(r.m));
			return linkto(r.m, r.name);
		}
		return l;
	}
	return ref Link(t.env, s, nil);
}

linkmodule(m: ref Module)
{
	instantiate(m);
	wire(m, nil);
}

importget(n: int)
{
	m := modules[nb[n]];
	l := m.links[na[n]];
	if(l == nil)
		throwerr(ERef, "Cannot access '" + kstr[nc[n]] + "' before initialization");
	if(l.ns != nil) {
		setr(objv(l.ns));
		return;
	}
	v := l.env.v[l.slot];
	if(v.t == Thole)
		tdzerror(kstr[nc[n]]);
	setr(v);
}

# ---- evaluation ----

evaluatemodule(m: ref Module)
{
	if(m.status == Mevaluated || m.status == Mevaluating) {
		if(m.failed)
			throwv(m.err);
		return;
	}
	m.status = Mevaluating;
	{
		for(l := revres(m.resolved); l != nil; l = tl l) {
			(nil, dep) := hd l;
			evaluatemodule(dep);
			if(dep.async && dep.promise != nil)
				waitpromise(dep.promise);
		}
		runmodulebody(m);
	} exception e {
	"JS" =>
		m.failed = 1;
		m.err = thrown;
		m.status = Mevaluated;
		raise e;
	}
	m.status = Mevaluated;
}

revres(l: list of (string, ref Module)): list of (string, ref Module)
{
	r: list of (string, ref Module);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

runmodulebody(m: ref Module)
{
	c := m.code;
	if(m.async) {
		# as an async function would: a coroutine over the module's Env
		g := ref Gen;
		g.f = newobj(Cfunc, funcproto);
		g.f.fun = c.fun;
		g.code = c;
		g.kind = Kasync;
		g.ismod = 1;
		g.cap = newcap();
		g.fr = array[c.nframe] of V;
		g.env = m.env;
		g.depth = depth;
		g.state = Gstart;
		m.promise = g.cap.promise;
		r := resume(g, Mnext, undef);
		asyncstep(g, r);
		return;
	}
	sfr := fr;
	senv := env;
	scv := cv;
	fr = array[c.nframe] of V;
	env = m.env;
	{
		ev(c.body);
	} exception {
	"JS*" =>
		fr = sfr;
		env = senv;
		cv = scv;
		ctl = 0;
		raise;
	}
	ctl = 0;
	fr = sfr;
	env = senv;
	cv = scv;
}

# run jobs until promise p settles; a rejection is thrown
waitpromise(p: ref Obj)
{
	pick d := p.data {
	Promise =>
		while(d.state == Ppending && pending())
			runjob();
		if(d.state == Prejected) {
			d.handled = 1;
			throwv(d.v);
		}
	}
}

# a module from source, linked and evaluated (Js->evalmodule)
runmodule(src, url: string)
{
	m := loadmodule(url, src);
	linkmodule(m);
	evaluatemodule(m);
	if(m.async && m.promise != nil)
		waitpromise(m.promise);
}

# ---- namespace objects ----

namespace(m: ref Module): ref Obj
{
	if(m.ns != nil)
		return m.ns;
	o := ref Obj;
	gcnew(o);
	o.cls = Cns;
	o.sh = rootshape;
	o.flags = 0;
	o.data = ref Data.Ns(m);
	addprop(o, a_symtostringtag, 0, strv("Module"));
	o.flags &= ~Fext;
	m.ns = o;
	return o;
}

nsmod(o: ref Obj): ref Module
{
	pick d := o.data {
	Ns =>
		return d.m;
	}
	return nil;
}

nsnames(m: ref Module): array of string
{
	l := exportednames(m, nil);
	r: list of string;
	for(; l != nil; l = tl l) {
		x := resolveexport(m, hd l, nil);
		if(x != nil && !x.ambiguous)
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

isnsname(m: ref Module, name: string): int
{
	x := resolveexport(m, name, nil);
	return x != nil && !x.ambiguous;
}

nsvalue(m: ref Module, name: string): V
{
	x := resolveexport(m, name, nil);
	if(x == nil || x.ambiguous)
		return undef;
	if(x.name == "*namespace*")
		return objv(namespace(x.m));
	l := linkto(x.m, x.name);
	if(l.ns != nil)
		return objv(l.ns);
	if(l.env == nil)
		throwerr(ERef, "Cannot access '" + name + "' before initialization");
	v := l.env.v[l.slot];
	if(v.t == Thole)
		throwerr(ERef, "Cannot access '" + name + "' before initialization");
	return v;
}

nsgetown(o: ref Obj, k: int): (int, V, int)
{
	if(atomsym[k] != nil) {
		s := slotof(o.sh, k);
		if(s < 0)
			return (0, undef, 0);
		return (1, o.slots[s], o.sh.attrs[s]);
	}
	m := nsmod(o);
	name := atomstr[k];
	if(!isnsname(m, name))
		return (0, undef, 0);
	return (1, nsvalue(m, name), Awrite|Aenum);
}

nshas(o: ref Obj, k: int): int
{
	if(atomsym[k] != nil)
		return slotof(o.sh, k) >= 0;
	return isnsname(nsmod(o), atomstr[k]);
}

nsdefine(o: ref Obj, k: int, d: ref Desc): int
{
	if(atomsym[k] != nil) {
		s := slotof(o.sh, k);
		if(s < 0)
			return 0;
		return compatible(d, o.slots[s], o.sh.attrs[s]);
	}
	(found, cur, nil) := nsgetown(o, k);
	if(!found)
		return 0;
	if((d.has & Dconf) && (d.attrs & Aconf))
		return 0;
	if((d.has & Denum) && (d.attrs & Aenum) == 0)
		return 0;
	if(d.has & (Dget|Dset))
		return 0;
	if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
		return 0;
	if(d.has & Dvalue)
		return samevalue(d.v, cur);
	return 1;
}

nsdelete(o: ref Obj, k: int): int
{
	if(atomsym[k] != nil) {
		s := slotof(o.sh, k);
		if(s < 0)
			return 1;
		return 0;
	}
	return !isnsname(nsmod(o), atomstr[k]);
}

nsownkeys(o: ref Obj): array of int
{
	names := nsnames(nsmod(o));
	r := array[len names + 1] of int;
	for(i := 0; i < len names; i++)
		r[i] = intern(names[i]);
	r[len names] = a_symtostringtag;
	return r;
}

# ---- import.meta and import() ----

importmetanode(n: int): V
{
	m := modules[na[n]];
	if(m.meta == nil) {
		m.meta = newobj(Cplain, nil);
		addprop(m.meta, intern("url"), Adefault, strv(m.url));
	}
	return objv(m.meta);
}

# import(specifier, options): a promise for the namespace
dynimport(spec, opts: V, referrer: string): V
{
	cap := newcap();
	{
		s := tostr(spec);
		if(opts.t != Tundef) {
			if(opts.t != Tobj)
				throwtype("The second argument to import() must be an object");
			w := getv(opts.o, intern("with"));
			if(w.t != Tundef) {
				if(w.t != Tobj)
					throwtype("The 'with' option to import() must be an object");
				ks := ownkeys(w.o);
				for(i := 0; i < len ks; i++) {
					if(atomsym[ks[i]] != nil)
						continue;
					d := getowndesc(w.o, ks[i]);
					if(d != nil && (d.attrs & Aenum)) {
						v := get(w.o, ks[i], w);
						if(!isstr(v))
							throwtype("Import attribute values must be strings");
					}
				}
			}
		}
		f := mknative(Nimportjob, "", 0);
		f.data = ref Data.Native(objv(cap.promise), strv(s), 0, nil);
		f.env = ref Env(nil, nil, nil, objv0(strv(referrer)), 0, 0);
		enqueue(ref Job.Call(f, array[0] of V));
	} exception {
	"JS" =>
		rejectcap(cap, thrown);
	}
	return objv(cap.promise);
}

# a holder for a string in an Env's obj
objv0(v: V): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.cls = -1;
	o.data = ref Data.Prim(v);
	return o;
}

importjob(f: ref Obj): V
{
	p: ref Obj;
	spec, referrer: string;
	pick d := f.data {
	Native =>
		p = d.v.o;
		spec = flat(d.w);
	}
	pick r := f.env.obj.data {
	Prim =>
		referrer = flat(r.v);
	}
	{
		ld := loader;
		if(ld == nil)
			ld = fileloader;
		(url, src, err) := ld(referrer, spec);
		if(err != nil)
			throwtype(err);
		m := loadmodule(url, src);
		linkmodule(m);
		evaluatemodule(m);
		if(m.async && m.promise != nil) {
			ok := mknative(NPthunk, "", 0);
			ok.data = ref Data.Native(objv(namespace(m)), undef, 0, nil);
			(res, rej) := resolvingfns(p);
			performthen(m.promise, ref React(0, ok, ref Cap(p, res, rej), 0, nil), ref React(1, nil, ref Cap(p, res, rej), 0, nil));
			return undef;
		}
		resolvepromise(p, objv(namespace(m)));
	} exception {
	"JS" =>
		rejectpromise(p, thrown);
	}
	return undef;
}
