implement Jscheck;

#
# The early errors that need the whole tree, by one walk over it.
#
# Declarations follow the specification's LexicallyDeclaredNames and
# VarDeclaredNames: in each statement list, a name declared lexically
# twice, or both lexically and by a var anywhere within, is an error.
# At the top level of a function or script, function declarations are
# var declarations; in a block, or a module, they are lexical (and in
# sloppy code a block may declare a plain function twice, Annex B.3.2).
#
# The walk carries what may appear where: break and continue targets,
# super property and super call, new.target, and the private names of
# the classes around.
#

include "sys.m";
	sys: Sys;

include "jsparse.m";
	jsparse: Jsparse;
	Node, Fgen, Fasync, Farrow, Fdecl, Fmethod, Fstrict, Kvar, Klet, Kconst, Kusing, Kawaitusing,
	Pinit, Pget, Pset, Pmethod, Pctor, Pfield, Pblock, Idefault, Inamespace, Inamed: import jsparse;

include "jscheck.m";

# a declared name
Name: adt {
	s:	string;
	pos:	int;
	plainfn:	int;	# a plain function declaration (not async, not a generator)
};

# a class's private names, for the references within it
Privs: adt {
	names:	list of string;
};

Ctx: adt {
	strict:	int;
	superprop:	int;	# super.x is allowed
	supercall:	int;	# super() is allowed
	newtarget:	int;
	labels:	list of (string, int);	# (label, labels a loop)
	inloop:	int;
	inswitch:	int;
	privs:	list of ref Privs;
};

init()
{
	sys = load Sys Sys->PATH;
}

check(prog: ref Node): (int, string)
{
	return checkeval(prog, 0, nil);
}

checkeval(prog: ref Node, ctx: int, privnames: list of string): (int, string)
{
	if(sys == nil)
		init();
	{
		pick p := prog {
		Program =>
			c := ref Ctx(p.strict, (ctx & Jsparse->Esuperprop) != 0, (ctx & Jsparse->Esupercall) != 0, (ctx & Jsparse->Enewtarget) != 0, nil, 0, 0, nil);
			if(privnames != nil)
				c.privs = ref Privs(privnames) :: nil;
			if(p.ismod)
				moduletop(p.body);
			else
				toplevel(p.body, nil, c.strict);
			stmts(p.body, c);
		}
		return (-1, nil);
	} exception e {
	"check:*" =>
		e = e[6:];
		for(i := 0; i < len e; i++)
			if(e[i] == ':')
				return (int e[0:i], e[i+1:]);
		return (0, e);
	}
}

err(pos: int, msg: string)
{
	raise sys->sprint("check:%d:%s", pos, msg);
}

# ---- names ----

# the names a binding pattern binds
bound(n: ref Node, acc: list of ref Name): list of ref Name
{
	if(n == nil)
		return acc;
	pick x := n {
	Ident =>
		return ref Name(x.name, x.pos, 0) :: acc;
	AssignPat =>
		return bound(x.target, acc);
	Rest =>
		return bound(x.arg, acc);
	ArrayPat =>
		for(i := 0; i < len x.elems; i++)
			acc = bound(x.elems[i], acc);
	ObjectPat =>
		for(i := 0; i < len x.props; i++)
			pick pr := x.props[i] {
			Prop =>
				acc = bound(pr.value, acc);
			Rest =>
				acc = bound(pr.arg, acc);
			}
	Var =>
		for(i := 0; i < len x.decls; i++)
			pick d := x.decls[i] {
			Decl =>
				acc = bound(d.id, acc);
			}
	}
	return acc;
}

boundall(a: array of ref Node): list of ref Name
{
	acc: list of ref Name;
	for(i := 0; i < len a; i++)
		acc = bound(a[i], acc);
	return acc;
}

funcname(n: ref Node): ref Name
{
	pick f := n {
	Func =>
		if(f.id == nil)
			return nil;
		pick id := f.id {
		Ident =>
			return ref Name(id.name, id.pos, (f.flags & (Fgen|Fasync)) == 0);
		}
	Class =>
		if(f.id == nil)
			return nil;
		pick id := f.id {
		Ident =>
			return ref Name(id.name, id.pos, 0);
		}
	}
	return nil;
}

isfuncdecl(n: ref Node): int
{
	pick f := n {
	Func =>
		return (f.flags & Fdecl) != 0;
	}
	return 0;
}

# the names a statement list declares lexically; top: a function's or
# script's top level, where function declarations are vars
lexnames(body: array of ref Node, top: int): list of ref Name
{
	acc: list of ref Name;
	for(i := 0; i < len body; i++) {
		s := body[i];
		# a labelled function declaration is a function declaration
		for(;;) {
			pick l := s {
			Labeled =>
				s = l.body;
				continue;
			}
			break;
		}
		pick x := s {
		Var =>
			if(x.kind != Kvar)
				acc = bound(s, acc);
		Func =>
			if(!top && x.flags & Fdecl && (nm := funcname(s)) != nil)
				acc = nm :: acc;
		Class =>
			if(x.decl && (nm := funcname(s)) != nil)
				acc = nm :: acc;
		}
	}
	return acc;
}

# the names a statement declares with var, wherever within it (not in
# functions); top: and function declarations at this level
varnames(s: ref Node, top: int, acc: list of ref Name): list of ref Name
{
	if(s == nil)
		return acc;
	pick x := s {
	Var =>
		if(x.kind == Kvar)
			acc = bound(s, acc);
	Func =>
		if(top && x.flags & Fdecl && (nm := funcname(s)) != nil)
			acc = nm :: acc;
	Block =>
		acc = varlist(x.body, 0, acc);
	If =>
		acc = varnames(x.cons, 0, acc);
		acc = varnames(x.els, 0, acc);
	While =>
		acc = varnames(x.body, 0, acc);
	DoWhile =>
		acc = varnames(x.body, 0, acc);
	For =>
		acc = varnames(x.init, 0, acc);
		acc = varnames(x.body, 0, acc);
	ForIn =>
		acc = varnames(x.left, 0, acc);
		acc = varnames(x.body, 0, acc);
	ForOf =>
		acc = varnames(x.left, 0, acc);
		acc = varnames(x.body, 0, acc);
	With =>
		acc = varnames(x.body, 0, acc);
	Labeled =>
		acc = varnames(x.body, top, acc);
	Switch =>
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				acc = varlist(c.body, 0, acc);
			}
	Try =>
		acc = varnames(x.block, 0, acc);
		acc = varnames(x.handler, 0, acc);
		acc = varnames(x.final, 0, acc);
	Export =>
		acc = varnames(x.decl, top, acc);
	}
	return acc;
}

varlist(body: array of ref Node, top: int, acc: list of ref Name): list of ref Name
{
	for(i := 0; i < len body; i++)
		acc = varnames(body[i], top, acc);
	return acc;
}

find(l: list of ref Name, s: string): ref Name
{
	for(; l != nil; l = tl l)
		if((hd l).s == s)
			return hd l;
	return nil;
}

# no name twice; sloppyfns: plain function declarations may repeat
nodups(l: list of ref Name, sloppyfns: int)
{
	for(; l != nil; l = tl l)
		for(m := tl l; m != nil; m = tl m)
			if((hd l).s == (hd m).s && !(sloppyfns && (hd l).plainfn && (hd m).plainfn))
				err(later(hd l, hd m).pos, sys->sprint("'%s' is declared twice", (hd l).s));
}

later(a, b: ref Name): ref Name
{
	if(a.pos > b.pos)
		return a;
	return b;
}

# no name in both
disjoint(a, b: list of ref Name)
{
	for(; a != nil; a = tl a)
		if((n := find(b, (hd a).s)) != nil)
			err(later(hd a, n).pos, sys->sprint("'%s' is declared twice", n.s));
}

# a block's statements, or a case block's
block(body: array of ref Node, strict: int)
{
	lex := lexnames(body, 0);
	nodups(lex, !strict);
	disjoint(lex, varlist(body, 0, nil));
}

# a function's or script's statements; params: a function's parameter names
toplevel(body: array of ref Node, params: list of ref Name, nil: int)
{
	lex := lexnames(body, 1);
	nodups(lex, 0);
	disjoint(lex, varlist(body, 1, nil));
	disjoint(lex, params);
}

moduletop(body: array of ref Node)
{
	lex := lexnames(body, 0);
	vars := varlist(body, 0, nil);
	exported: list of ref Name;
	locals: list of ref Name;
	for(i := 0; i < len body; i++)
		pick x := body[i] {
		Import =>
			for(j := 0; j < len x.specs; j++)
				pick sp := x.specs[j] {
				ImportSpec =>
					lex = ref Name(sp.local, sp.pos, 0) :: lex;
				}
		Export =>
			if(x.default) {
				exported = ref Name("default", x.pos, 0) :: exported;
				if(x.decl != nil && (isfuncdecl(x.decl) || isclassdecl(x.decl)) && (nm := funcname(x.decl)) != nil)
					lex = nm :: lex;
			} else if(x.decl != nil) {
				pick d := x.decl {
				Var =>
					for(l := bound(x.decl, nil); l != nil; l = tl l)
						exported = hd l :: exported;
					if(d.kind != Kvar)
						lex = bound(x.decl, lex);
				* =>
					if((nm := funcname(x.decl)) != nil) {
						exported = ref Name(nm.s, nm.pos, 0) :: exported;
						lex = nm :: lex;
					}
				}
			} else if(x.all) {
				if(x.allas != nil)
					exported = ref Name(x.allas, x.pos, 0) :: exported;
			} else
				for(j := 0; j < len x.specs; j++)
					pick sp := x.specs[j] {
					ExportSpec =>
						exported = ref Name(sp.exported, sp.pos, 0) :: exported;
						if(x.source == nil)
							locals = ref Name(sp.local, sp.pos, 0) :: locals;
					}
		}
	nodups(lex, 0);
	disjoint(lex, vars);
	nodups(exported, 0);
	for(; locals != nil; locals = tl locals)
		if(find(lex, (hd locals).s) == nil && find(vars, (hd locals).s) == nil)
			err((hd locals).pos, sys->sprint("export of '%s', which is not declared", (hd locals).s));
}

isclassdecl(n: ref Node): int
{
	pick c := n {
	Class =>
		return 1;
	}
	return 0;
}

# ---- the walk ----

stmts(a: array of ref Node, c: ref Ctx)
{
	for(i := 0; i < len a; i++)
		walk(a[i], c);
}

exprs(a: array of ref Node, c: ref Ctx)
{
	for(i := 0; i < len a; i++)
		if(a[i] != nil)
			walk(a[i], c);
}

isloop(n: ref Node): int
{
	t := tagof n;
	if(t == tagof Node.While || t == tagof Node.DoWhile || t == tagof Node.For || t == tagof Node.ForIn || t == tagof Node.ForOf)
		return 1;
	pick x := n {
	Labeled =>
		return isloop(x.body);
	}
	return 0;
}

loopctx(c: ref Ctx): ref Ctx
{
	d := ref *c;
	d.inloop = 1;
	# the labels just above a loop label it: continue may name them
	l: list of (string, int);
	for(m := c.labels; m != nil; m = tl m) {
		(s, isl) := hd m;
		if(isl == 2)
			isl = 1;
		l = (s, isl) :: l;
	}
	d.labels = nil;
	for(; l != nil; l = tl l)
		d.labels = hd l :: d.labels;
	return d;
}

# a labelled statement's label, pending: 2 until we know whether a loop follows
unpend(c: ref Ctx): ref Ctx
{
	d := ref *c;
	l: list of (string, int);
	for(m := c.labels; m != nil; m = tl m) {
		(s, isl) := hd m;
		if(isl == 2)
			isl = 0;
		l = (s, isl) :: l;
	}
	d.labels = nil;
	for(; l != nil; l = tl l)
		d.labels = hd l :: d.labels;
	return d;
}

# a function's own context: no labels or loops from outside; super as its kind allows
fnctx(c: ref Ctx, f: ref Node.Func, method, ctor: int): ref Ctx
{
	d := ref *c;
	if(f.flags & Fstrict)
		d.strict = 1;
	if(f.flags & Farrow)
		return d;
	d.labels = nil;
	d.inloop = 0;
	d.inswitch = 0;
	d.newtarget = 1;
	d.superprop = method;
	d.supercall = ctor;
	return d;
}

func(f: ref Node.Func, c: ref Ctx)
{
	pnames := boundall(f.params);
	toplevel(f.body, pnames, c.strict);
	exprs(f.params, c);
	stmts(f.body, c);
}

walk(n: ref Node, c: ref Ctx)
{
	if(n == nil)
		return;
	if(tagof n != tagof Node.Labeled && tagof n != tagof Node.While && tagof n != tagof Node.DoWhile &&
	   tagof n != tagof Node.For && tagof n != tagof Node.ForIn && tagof n != tagof Node.ForOf)
		c = unpend(c);
	pick x := n {
	Program =>
		stmts(x.body, c);
	Expr =>
		walk(x.e, c);
	Block =>
		block(x.body, c.strict);
		stmts(x.body, c);
	Empty or Debugger =>
		;
	With =>
		walk(x.obj, c);
		walk(x.body, c);
	Return =>
		walk(x.arg, c);
	Labeled =>
		for(l := c.labels; l != nil; l = tl l)
			if((hd l).t0 == x.label)
				err(x.pos, sys->sprint("label '%s' is already in use", x.label));
		d := ref *c;
		d.labels = (x.label, 2) :: c.labels;
		walk(x.body, d);
	Break =>
		if(x.label != nil) {
			if(!haslabel(c, x.label, 0))
				err(x.pos, sys->sprint("break to label '%s', which is not around it", x.label));
		} else if(!c.inloop && !c.inswitch)
			err(x.pos, "break outside a loop or switch");
	Continue =>
		if(x.label != nil) {
			if(!haslabel(c, x.label, 1))
				err(x.pos, sys->sprint("continue to label '%s', which does not label a loop around it", x.label));
		} else if(!c.inloop)
			err(x.pos, "continue outside a loop");
	If =>
		walk(x.test, c);
		walk(x.cons, c);
		walk(x.els, c);
	Switch =>
		walk(x.disc, c);
		all: array of ref Node;
		for(i := 0; i < len x.cases; i++)
			pick cs := x.cases[i] {
			Case =>
				all = cat(all, cs.body);
			}
		block(all, c.strict);
		d := ref *c;
		d.inswitch = 1;
		for(i = 0; i < len x.cases; i++)
			pick cs := x.cases[i] {
			Case =>
				walk(cs.test, d);
				stmts(cs.body, d);
			}
	Case =>
		walk(x.test, c);
		stmts(x.body, c);
	Throw =>
		walk(x.arg, c);
	Try =>
		walk(x.block, c);
		if(x.param != nil) {
			pn := bound(x.param, nil);
			nodups(pn, 0);
			pick h := x.handler {
			Block =>
				disjoint(pn, lexnames(h.body, 0));
			}
			walk(x.param, c);
		}
		walk(x.handler, c);
		walk(x.final, c);
	While =>
		walk(x.test, c);
		walk(x.body, loopctx(c));
	DoWhile =>
		walk(x.body, loopctx(c));
		walk(x.test, c);
	For =>
		forhead(x.init, x.body);
		walk(x.init, unpend(c));
		walk(x.test, unpend(c));
		walk(x.update, unpend(c));
		walk(x.body, loopctx(c));
	ForIn =>
		forhead(x.left, x.body);
		walk(x.left, unpend(c));
		walk(x.right, unpend(c));
		walk(x.body, loopctx(c));
	ForOf =>
		forhead(x.left, x.body);
		walk(x.left, unpend(c));
		walk(x.right, unpend(c));
		walk(x.body, loopctx(c));
	Var =>
		exprs(x.decls, c);
	Decl =>
		walk(x.id, c);
		walk(x.init, c);
	Func =>
		func(x, fnctx(c, x, 0, 0));
	Class =>
		class(x, c);
	Method =>
		;	# within class and object
	Export =>
		walk(x.decl, c);
	Private =>
		privref(x.name, x.pos, c);
	Super =>
		err(x.pos, "super out of place");
	Template =>
		exprs(x.exprs, c);
	Tagged =>
		walk(x.tag, c);
		walk(x.quasi, c);
	Array =>
		exprs(x.elems, c);
	Object =>
		proto := 0;
		for(i := 0; i < len x.props; i++)
			pick pr := x.props[i] {
			Prop =>
				if(pr.kind == Pinit && !pr.computed && !pr.shorthand && isproto(pr.key)) {
					if(proto)
						err(pr.pos, "__proto__ twice in an object literal");
					proto = 1;
				}
				if(tagof pr.value == tagof Node.AssignPat)
					err(pr.pos, "a = default outside a pattern");
				if(pr.computed)
					walk(pr.key, c);
				pick f := pr.value {
				Func =>
					if(f.flags & Fmethod) {
						func(f, fnctx(c, f, 1, 0));
						continue;
					}
				}
				walk(pr.value, c);
			* =>
				walk(x.props[i], c);
			}
	Prop =>
		if(x.computed)
			walk(x.key, c);
		walk(x.value, c);
	Spread =>
		walk(x.arg, c);
	Unary =>
		walk(x.arg, c);
	Update =>
		walk(x.arg, c);
	Binary =>
		walk(x.l, c);
		walk(x.r, c);
	Logical =>
		walk(x.l, c);
		walk(x.r, c);
	Assign =>
		walk(x.target, c);
		walk(x.value, c);
	Cond =>
		walk(x.test, c);
		walk(x.cons, c);
		walk(x.els, c);
	Call =>
		if(tagof x.callee == tagof Node.Super) {
			if(!c.supercall)
				err(x.callee.pos, "super() outside a derived class's constructor");
		} else
			walk(x.callee, c);
		exprs(x.args, c);
	New =>
		walk(x.callee, c);
		exprs(x.args, c);
	Member =>
		if(tagof x.obj == tagof Node.Super) {
			if(!c.superprop)
				err(x.obj.pos, "super property outside a method");
			if(tagof x.prop == tagof Node.Private)
				err(x.prop.pos, "super.#name");
		} else
			walk(x.obj, c);
		if(x.computed || tagof x.prop == tagof Node.Private)
			walk(x.prop, c);
	Chain =>
		walk(x.e, c);
	Seq =>
		exprs(x.exprs, c);
	Yield =>
		walk(x.arg, c);
	Await =>
		walk(x.arg, c);
	Meta =>
		if(x.meta == "new" && !c.newtarget)
			err(x.pos, "new.target outside a function");
	ImportCall =>
		walk(x.source, c);
		walk(x.options, c);
	Paren =>
		walk(x.e, c);
	ArrayPat =>
		exprs(x.elems, c);
	ObjectPat =>
		for(i := 0; i < len x.props; i++)
			walk(x.props[i], c);
	AssignPat =>
		walk(x.target, c);
		walk(x.dflt, c);
	Rest =>
		walk(x.arg, c);
	}
}

isproto(k: ref Node): int
{
	pick x := k {
	Ident =>
		return x.name == "__proto__";
	Str =>
		return x.s == "__proto__";
	}
	return 0;
}

haslabel(c: ref Ctx, s: string, loop: int): int
{
	for(l := c.labels; l != nil; l = tl l) {
		(t, isl) := hd l;
		if(t == s)
			return !loop || isl == 1;
	}
	return 0;
}

cat(a, b: array of ref Node): array of ref Node
{
	r := array[len a + len b] of ref Node;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# for (let x ...): x not twice, and not a var in the body
forhead(head, body: ref Node)
{
	if(head == nil)
		return;
	pick v := head {
	Var =>
		if(v.kind == Kvar)
			return;
		names := bound(head, nil);
		nodups(names, 0);
		disjoint(names, varnames(body, 0, nil));
	}
}

# ---- classes ----

class(x: ref Node.Class, c: ref Ctx)
{
	# the heritage is evaluated outside the class's private names
	inner := ref *c;
	inner.strict = 1;
	walk(x.super, inner);
	# the private names this class declares
	pv := ref Privs(nil);
	kinds: list of (string, int, int);	# (name, kind, static)
	for(i := 0; i < len x.body; i++)
		pick m := x.body[i] {
		Method =>
			if(m.key == nil)
				continue;
			pick k := m.key {
			Private =>
				for(l := kinds; l != nil; l = tl l) {
					(s, kd, st) := hd l;
					if(s != k.name)
						continue;
					if(!(st == m.static && (kd == Pget && m.kind == Pset || kd == Pset && m.kind == Pget)))
						err(k.pos, sys->sprint("#%s is declared twice", k.name));
				}
				kinds = (k.name, m.kind, m.static) :: kinds;
				pv.names = k.name :: pv.names;
			}
		}
	inner.privs = pv :: c.privs;
	derived := x.super != nil;
	for(i = 0; i < len x.body; i++)
		pick m := x.body[i] {
		Method =>
			if(m.computed)
				walk(m.key, inner);
			else if(m.key != nil && tagof m.key == tagof Node.Private)
				;
			case m.kind {
			Pfield =>
				# a field's initialiser: like a method's body, with no super() or labels
				d := ref *inner;
				d.labels = nil;
				d.inloop = 0;
				d.inswitch = 0;
				d.newtarget = 1;
				d.superprop = 1;
				d.supercall = 0;
				walk(m.value, d);
			Pblock =>
				d := ref *inner;
				d.labels = nil;
				d.inloop = 0;
				d.inswitch = 0;
				d.newtarget = 1;
				d.superprop = 1;
				d.supercall = 0;
				pick b := m.value {
				Block =>
					toplevel(b.body, nil, 1);
					stmts(b.body, d);
				}
			* =>
				pick f := m.value {
				Func =>
					func(f, fnctx(inner, f, 1, m.kind == Pctor && derived));
				}
			}
		}
}

privref(s: string, pos: int, c: ref Ctx)
{
	for(l := c.privs; l != nil; l = tl l)
		for(m := (hd l).names; m != nil; m = tl m)
			if(hd m == s)
				return;
	err(pos, sys->sprint("#%s is not declared by a class around it", s));
}
