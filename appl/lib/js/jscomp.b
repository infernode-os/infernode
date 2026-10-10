#
# jscomp.b - the tree to bytecode.  Included by js.b.
#
# Two passes over a function's tree.  The first finds its scopes, what
# each declares, and which bindings closures (or eval, or with) reach;
# the second emits code.  A binding nothing else reaches is a register;
# one that something does is a slot in its scope's environment, an
# object made when the scope is entered.  Where with or direct eval
# could change what a name means, it is looked up by name at run time.
#

Bvar, Blet, Bconst, Bclass, Bfunc, Bparam, Bcatch, Bfnself, Bpriv, Bthis, Bnewtarget, Bcallee, Barguments, Bhome, Bimport: con iota;

Sfunc, Sblock, Sscript, Seval, Swith, Sclass, Sfnname, Scatch, Sfor, Sswitch, Smodule: con iota;

Bind: adt {
	name:	string;
	kind:	int;
	captured:	int;
	reg:	int;		# a register, or -1
	slot:	int;		# an environment slot, or -1
	annexb:	int;	# a block function's var twin (Annex B.3.3)
};

CScope: adt {
	kind:	int;
	parent:	ref CScope;
	fid:	int;		# the function it is in
	binds:	list of ref Bind;
	needsenv:	int;
	named:	int;	# its environment knows its names (for with and eval)
	evalvars:	int;	# a sloppy direct eval in it may add vars
	strict:	int;
	rt:	int;		# its Scope in the code's scopes, once emitted
	nslots:	int;
	nbinds:	int;
	tab:	array of list of ref Bind;	# binds by name's hash, once there are many
};

CFunc: adt {
	id:	int;
	node:	ref Node.Func;
	parent:	ref CFunc;
	scope:	ref CScope;	# its top scope
	flags:	int;
	usesargs:	int;
	usesthis:	int;	# an arrow or eval within reaches its this
	haseval:	int;
	# code being emitted
	ops:	array of int;
	nops:	int;
	pos:	array of int;
	consts:	list of V;
	nconst:	int;
	funcs:	list of ref Code;
	nfunc:	int;
	handlers:	list of Handler;
	scopes:	list of ref Scope;
	nscope:	int;
	decls:	list of ref Gdecl;
	ndecl:	int;
	nic:	int;
	tmpls:	list of (array of string, array of string);
	ntmpl:	int;
	regexps:	list of (string, string);
	nregexp:	int;
	nregs:	int;
	tmp:	int;		# the next free temporary
	nlocal:	int;	# registers below this are bindings
	labels:	list of ref Label;
	finally:	list of ref Fin;
	allreg:	int;
	src:	string;
	curpos:	int;
	disps:	list of (int, int);	# using scopes: (disposal stack register, async)
	evalctx0:	int;	# eval code: its caller's context
	evalprivs0:	list of string;
	inparams:	int;	# emitting the parameters' code
};

# where an optional chain's short circuits jump
Ends: adt {
	l:	list of int;
};

# a break or continue target
Label: adt {
	names:	list of string;	# its labels
	isloop:	int;
	breaks:	list of int;	# jumps to patch
	conts:	list of int;
	contpc:	int;	# -1 until known
	scopedepth:	int;	# environments pushed at its start (popped on the way out)
	findepth:	int;	# finally blocks around it
	iterreg:	int;	# a for-of's iterator, closed on break, or -1
	iterasync:	int;	# a for await's: closing awaits
};

# a finally block between a jump and its target: the jump goes through it
Fin: adt {
	jumps:	list of (int, int);	# (jump to patch, completion code)
	ncodes:	int;
	reg:	int;		# completion register: 0 normal, 1 throw, 2 return, 3+ jumps
	val:	int;		# the value register
	targets:	list of (int, ref Label, int);	# (code, label, is a continue)
	retseen:	int;
	scopedepth:	int;
	iterreg:	int;	# a for-of iterator to close, -1
};

cs: ref CFunc;			# the function being compiled
cscope: ref CScope;		# the innermost scope, during emission
scopemap: array of list of (int, ref CScope);
nfid := 0;
envdepth := 0;		# environments pushed in the current function

compileerr(pos: int, msg: string)
{
	throwerr(SyntaxError, msg);
	pos = 0;
}

# ---- scope bookkeeping ----

skey(n: ref Node, kind: int): int
{
	return n.pos * 16 + kind;
}

sput(k: int, s: ref CScope)
{
	b := (k & 16r7FFFFFFF) % len scopemap;
	scopemap[b] = (k, s) :: scopemap[b];
}

sget(k: int): ref CScope
{
	b := (k & 16r7FFFFFFF) % len scopemap;
	for(l := scopemap[b]; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return nil;
}

newscope(kind: int, parent: ref CScope, fid: int, strict: int): ref CScope
{
	return ref CScope(kind, parent, fid, nil, 0, 0, 0, strict, -1, 0, 0, nil);
}

# a scope of a minified bundle can have thousands of names, each looked
# up at every reference: past Tabmin they are hashed
Tabmin: con 16;

findlocal(s: ref CScope, name: string): ref Bind
{
	l := s.binds;
	if(s.tab != nil)
		l = s.tab[namehash(name) % len s.tab];
	for(; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

namehash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h * 31 + s[i];
	return h & 16r7FFFFFFF;
}

addbind(s: ref CScope, b: ref Bind)
{
	s.binds = b :: s.binds;
	s.nbinds++;
	if(s.tab == nil && s.nbinds < Tabmin)
		return;
	if(s.tab == nil || s.nbinds > 2 * len s.tab) {
		t := array[4 * s.nbinds + 1] of list of ref Bind;
		for(l := s.binds; l != nil; l = tl l) {
			k := namehash((hd l).name) % len t;
			t[k] = hd l :: t[k];
		}
		s.tab = t;
		return;
	}
	k := namehash(b.name) % len s.tab;
	s.tab[k] = b :: s.tab[k];
}

declare(s: ref CScope, name: string, kind: int): ref Bind
{
	b := findlocal(s, name);
	if(b != nil) {
		# a var or function twice, or a function over a var: one binding
		if(kind == Bfunc && (b.kind == Bvar || b.kind == Bparam))
			b.kind = Bfunc;
		return b;
	}
	b = ref Bind(name, kind, 0, -1, -1, 0);
	addbind(s, b);
	return b;
}

# the function scope a var goes to
varscope(s: ref CScope): ref CScope
{
	while(s.kind != Sfunc && s.kind != Sscript && s.kind != Seval && s.kind != Smodule)
		s = s.parent;
	return s;
}

# ---- pass 1: scopes, declarations, captures ----

R1: adt {
	s:	ref CScope;
	fid:	int;
	fnscope:	ref CScope;	# the nearest non-arrow function's scope (for this, arguments)
	inarrowof:	int;
	strict:	int;
};

# a reference to name from scope s, in function fid
ref1(s: ref CScope, fid: int, name: string)
{
	dyn := 0;
	for(; s != nil; s = s.parent) {
		if(s.kind == Swith)
			dyn = 1;
		b := findlocal(s, name);
		if(b != nil) {
			if(s.fid != fid || dyn)
				capture(s, b);
			return;
		}
	}
}

capture(s: ref CScope, b: ref Bind)
{
	b.captured = 1;
	s.needsenv = 1;
}

# everything visible from s is reachable by name (eval, with)
allnamed(s: ref CScope)
{
	for(; s != nil; s = s.parent) {
		s.named = 1;
		if(s.kind == Sscript)
			continue;
		s.needsenv = 1;
		for(l := s.binds; l != nil; l = tl l)
			(hd l).captured = 1;
	}
}

# a function's declarations, into its top scope
hoistfunc(fs: ref CScope, f: ref Node.Func, strict: int)
{
	# parameters with defaults or patterns are initialised in order, uninitialised before
	pk := Bparam;
	if(!simpleparams(f.params))
		pk = Blet;
	for(i := 0; i < len f.params; i++)
		for(l := patnames(f.params[i], nil); l != nil; l = tl l)
			declare(fs, hd l, pk);
	hoistbody(fs, f.body, strict, 1);
}

# a script's or function's body: its vars and top-level functions; lexical declarations too
hoistbody(fs: ref CScope, body: array of ref Node, strict: int, isfunc: int)
{
	vars := varlist1(body, nil);
	for(l := vars; l != nil; l = tl l)
		declare(fs, hd l, Bvar);
	for(i := 0; i < len body; i++) {
		s := unlabel(body[i]);
		pick x := s {
		Func =>
			if(x.flags & Jsparse->Fdecl && x.id != nil)
				declare(fs, idname(x.id), Bfunc);
		Var =>
			if(x.kind != Kvar)
				for(nl := patnames(s, nil); nl != nil; nl = tl nl)
					declare(fs, hd nl, lexkind(x.kind));
		Class =>
			if(x.decl && x.id != nil)
				declare(fs, idname(x.id), Bclass);
		}
	}
	# Annex B: functions in blocks are vars here too, when nothing lexical is in the way
	if(!strict)
		annexb(fs, body, isfunc);
}

lexkind(k: int): int
{
	if(k == Klet)
		return Blet;
	return Bconst;
}

unlabel(s: ref Node): ref Node
{
	for(;;) {
		pick l := s {
		Labeled =>
			s = l.body;
			continue;
		}
		return s;
	}
}

idname(n: ref Node): string
{
	pick x := n {
	Ident =>
		return x.name;
	}
	return nil;
}

# the names a pattern or declaration binds
patnames(n: ref Node, acc: list of string): list of string
{
	if(n == nil)
		return acc;
	pick x := n {
	Ident =>
		return x.name :: acc;
	AssignPat =>
		return patnames(x.target, acc);
	Rest =>
		return patnames(x.arg, acc);
	ArrayPat =>
		for(i := 0; i < len x.elems; i++)
			acc = patnames(x.elems[i], acc);
	ObjectPat =>
		for(i := 0; i < len x.props; i++)
			pick p := x.props[i] {
			Prop =>
				acc = patnames(p.value, acc);
			Rest =>
				acc = patnames(p.arg, acc);
			}
	Var =>
		for(i := 0; i < len x.decls; i++)
			pick d := x.decls[i] {
			Decl =>
				acc = patnames(d.id, acc);
			}
	}
	return acc;
}

# the var names of statements, deep (not into functions)
varlist1(body: array of ref Node, acc: list of string): list of string
{
	for(i := 0; i < len body; i++)
		acc = vars1(body[i], acc);
	return acc;
}

vars1(s: ref Node, acc: list of string): list of string
{
	if(s == nil)
		return acc;
	pick x := s {
	Var =>
		if(x.kind == Kvar)
			acc = patnames(s, acc);
	Block =>
		acc = varlist1(x.body, acc);
	If =>
		acc = vars1(x.cons, acc);
		acc = vars1(x.els, acc);
	While =>
		acc = vars1(x.body, acc);
	DoWhile =>
		acc = vars1(x.body, acc);
	For =>
		acc = vars1(x.init, acc);
		acc = vars1(x.body, acc);
	ForIn =>
		acc = vars1(x.left, acc);
		acc = vars1(x.body, acc);
	ForOf =>
		acc = vars1(x.left, acc);
		acc = vars1(x.body, acc);
	With =>
		acc = vars1(x.body, acc);
	Labeled =>
		acc = vars1(x.body, acc);
	Switch =>
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				acc = varlist1(c.body, acc);
			}
	Try =>
		acc = vars1(x.block, acc);
		acc = vars1(x.handler, acc);
		acc = vars1(x.final, acc);
	}
	return acc;
}

# Annex B.3.3: a sloppy function declaration in a block is also a var
# of the function, unless that would clash with a lexical declaration
annexb(fs: ref CScope, body: array of ref Node, nil: int)
{
	lex: list of string;
	for(i := 0; i < len body; i++) {
		s := unlabel(body[i]);
		pick x := s {
		Var =>
			if(x.kind != Kvar)
				lex = patnames(s, lex);
		Class =>
			if(x.id != nil)
				lex = idname(x.id) :: lex;
		}
	}
	params: list of string;
	for(l := fs.binds; l != nil; l = tl l)
		if((hd l).kind == Bparam)
			params = (hd l).name :: params;
	for(i = 0; i < len body; i++)
		annexbstmt(fs, body[i], lex);
}

annexbstmt(fs: ref CScope, s: ref Node, lex: list of string)
{
	if(s == nil)
		return;
	pick x := s {
	Block =>
		inner := lex;
		for(i := 0; i < len x.body; i++) {
			t := unlabel(x.body[i]);
			pick y := t {
			Var =>
				if(y.kind != Kvar)
					inner = patnames(t, inner);
			Class =>
				if(y.id != nil)
					inner = idname(y.id) :: inner;
			}
		}
		for(i = 0; i < len x.body; i++) {
			t := unlabel(x.body[i]);
			pick f := t {
			Func =>
				if(f.flags & Jsparse->Fdecl && (f.flags & (Jsparse->Fgen|Jsparse->Fasync)) == 0 && f.id != nil) {
					n := idname(f.id);
					if(!hasname(lex, n) && !lexinblockbutnotfn(x.body, n, t)) {
						b := declare(fs, n, Bvar);
						if(b.kind == Bvar)
							b.annexb = 1;
					}
				}
			}
			annexbstmt(fs, x.body[i], inner);
		}
	If =>
		annexbif(fs, x.cons, lex);
		annexbif(fs, x.els, lex);
	While =>
		annexbstmt(fs, x.body, lex);
	DoWhile =>
		annexbstmt(fs, x.body, lex);
	For =>
		annexbstmt(fs, x.body, lexof(x.init, lex));
	ForIn =>
		annexbstmt(fs, x.body, lexof(x.left, lex));
	ForOf =>
		annexbstmt(fs, x.body, lexof(x.left, lex));
	With =>
		annexbstmt(fs, x.body, lex);
	Labeled =>
		annexbstmt(fs, x.body, lex);
	Switch =>
		all: array of ref Node;
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				all = catnodes(all, c.body);
			}
		annexbstmt(fs, ref Node.Block(x.pos, x.end, all), lex);
	Try =>
		annexbstmt(fs, x.block, lex);
		if(x.handler != nil) {
			inner := lex;
			if(x.param != nil && tagof x.param != tagof Node.Ident)
				inner = patnames(x.param, inner);
			annexbstmt(fs, x.handler, inner);
		}
		annexbstmt(fs, x.final, lex);
	}
}

# the function of `if (x) function f(){}` is as if in a block
annexbif(fs: ref CScope, s: ref Node, lex: list of string)
{
	if(s == nil)
		return;
	pick f := s {
	Func =>
		annexbstmt(fs, ref Node.Block(s.pos, s.end, array[] of {s}), lex);
		return;
	}
	annexbstmt(fs, s, lex);
}

lexof(init: ref Node, lex: list of string): list of string
{
	if(init == nil)
		return lex;
	pick v := init {
	Var =>
		if(v.kind != Kvar)
			return patnames(init, lex);
	}
	return lex;
}

hasname(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# whether a lexical declaration other than function f in the same block names n
lexinblockbutnotfn(body: array of ref Node, n: string, f: ref Node): int
{
	for(i := 0; i < len body; i++) {
		t := unlabel(body[i]);
		if(t == f)
			continue;
		pick y := t {
		Var =>
			if(y.kind != Kvar && hasname(patnames(t, nil), n))
				return 1;
		Class =>
			if(y.id != nil && idname(y.id) == n)
				return 1;
		}
	}
	return 0;
}

catnodes(a, b: array of ref Node): array of ref Node
{
	r := array[len a + len b] of ref Node;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# declare a block's lexical names and functions into scope s
hoistblock(s: ref CScope, body: array of ref Node)
{
	for(i := 0; i < len body; i++) {
		t := unlabel(body[i]);
		pick x := t {
		Var =>
			if(x.kind != Kvar)
				for(l := patnames(t, nil); l != nil; l = tl l)
					declare(s, hd l, lexkind(x.kind));
		Class =>
			if(x.decl && x.id != nil)
				declare(s, idname(x.id), Bclass);
		Func =>
			if(x.flags & Jsparse->Fdecl && x.id != nil)
				declare(s, idname(x.id), Blet);
		}
	}
}

walk1(n: ref Node, r: ref R1)
{
	if(n == nil)
		return;
	pick x := n {
	Program =>
		walklist1(x.body, r);
	Expr =>
		walk1(x.e, r);
	Block =>
		s := newscope(Sblock, r.s, r.fid, r.strict);
		sput(skey(n, Sblock), s);
		hoistblock(s, x.body);
		r2 := ref *r;
		r2.s = s;
		walklist1(x.body, r2);
	With =>
		walk1(x.obj, r);
		s := newscope(Swith, r.s, r.fid, r.strict);
		sput(skey(n, Swith), s);
		allnamed(r.s);
		r2 := ref *r;
		r2.s = s;
		walk1(x.body, r2);
	Return =>
		walk1(x.arg, r);
	Labeled =>
		walk1(x.body, r);
	If =>
		walk1(x.test, r);
		walksub1(x.cons, r);
		walksub1(x.els, r);
	Switch =>
		walk1(x.disc, r);
		s := newscope(Sswitch, r.s, r.fid, r.strict);
		sput(skey(n, Sswitch), s);
		all: array of ref Node;
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				all = catnodes(all, c.body);
			}
		hoistblock(s, all);
		r2 := ref *r;
		r2.s = s;
		for(i = 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				walk1(c.test, r2);
				walklist1(c.body, r2);
			}
	Throw =>
		walk1(x.arg, r);
	Try =>
		walk1(x.block, r);
		if(x.handler != nil) {
			s := newscope(Scatch, r.s, r.fid, r.strict);
			sput(skey(n, Scatch), s);
			r2 := ref *r;
			r2.s = s;
			if(x.param != nil) {
				for(l := patnames(x.param, nil); l != nil; l = tl l)
					declare(s, hd l, Bcatch);
				walk1(x.param, r2);
			}
			walk1(x.handler, r2);
		}
		walk1(x.final, r);
	While =>
		walk1(x.test, r);
		walk1(x.body, r);
	DoWhile =>
		walk1(x.body, r);
		walk1(x.test, r);
	For =>
		r2 := forscope1(n, x.init, r);
		walk1(x.init, r2);
		walk1(x.test, r2);
		walk1(x.update, r2);
		walk1(x.body, r2);
	ForIn =>
		walk1(x.right, forscope1tdz(n, x.left, r));
		r2 := forscope1(n, x.left, r);
		walk1(x.left, r2);
		walk1(x.body, r2);
	ForOf =>
		walk1(x.right, forscope1tdz(n, x.left, r));
		r2 := forscope1(n, x.left, r);
		walk1(x.left, r2);
		walk1(x.body, r2);
	Var =>
		for(i := 0; i < len x.decls; i++)
			walk1(x.decls[i], r);
	Decl =>
		walk1(x.id, r);
		walk1(x.init, r);
	Func =>
		func1(x, r);
	Class =>
		class1(x, r);
	Export =>
		walk1(x.decl, r);
	Ident =>
		ref1(r.s, r.fid, x.name);
		if(x.name == "arguments")
			argsref1(r);
	This =>
		thisref1(r);
	Super =>
		thisref1(r);
		superref1(r);
	Meta =>
		if(x.meta == "new")
			pseudo1(r, "%newtarget", Bnewtarget);
	Template =>
		walklist1(x.exprs, r);
	Tagged =>
		walk1(x.tag, r);
		walk1(x.quasi, r);
	Array =>
		walklist1(x.elems, r);
	Object =>
		walklist1(x.props, r);
	Prop =>
		if(x.computed)
			walk1(x.key, r);
		walk1(x.value, r);
	Spread =>
		walk1(x.arg, r);
	Unary =>
		walk1(x.arg, r);
	Update =>
		walk1(x.arg, r);
	Binary =>
		walk1(x.l, r);
		walk1(x.r, r);
	Logical =>
		walk1(x.l, r);
		walk1(x.r, r);
	Assign =>
		walk1(x.target, r);
		walk1(x.value, r);
	Cond =>
		walk1(x.test, r);
		walk1(x.cons, r);
		walk1(x.els, r);
	Call =>
		walk1(x.callee, r);
		walklist1(x.args, r);
		pick c := x.callee {
		Ident =>
			if(c.name == "eval" && !x.optional)
				eval1(r);
		}
	New =>
		walk1(x.callee, r);
		walklist1(x.args, r);
	Member =>
		walk1(x.obj, r);
		if(x.computed)
			walk1(x.prop, r);
		pick p := x.prop {
		Private =>
			ref1(r.s, r.fid, "#" + p.name);
		}
	Chain =>
		walk1(x.e, r);
	Seq =>
		walklist1(x.exprs, r);
	Yield =>
		walk1(x.arg, r);
	Await =>
		walk1(x.arg, r);
	ImportCall =>
		walk1(x.source, r);
		walk1(x.options, r);
	Paren =>
		walk1(x.e, r);
	ArrayPat =>
		walklist1(x.elems, r);
	ObjectPat =>
		walklist1(x.props, r);
	AssignPat =>
		walk1(x.target, r);
		walk1(x.dflt, r);
	Rest =>
		walk1(x.arg, r);
	Private =>
		ref1(r.s, r.fid, "#" + x.name);
	}
}

walklist1(a: array of ref Node, r: ref R1)
{
	for(i := 0; i < len a; i++)
		walk1(a[i], r);
}

# the body of an if: a sloppy function there is in a block of its own
walksub1(n: ref Node, r: ref R1)
{
	if(n == nil)
		return;
	pick f := n {
	Func =>
		if(f.flags & Jsparse->Fdecl) {
			s := newscope(Sblock, r.s, r.fid, r.strict);
			sput(skey(n, Sblock), s);
			declare(s, idname(f.id), Blet);
			r2 := ref *r;
			r2.s = s;
			walk1(n, r2);
			return;
		}
	}
	walk1(n, r);
}

# a for statement's scope for its let or const declarations
forscope1(n: ref Node, init: ref Node, r: ref R1): ref R1
{
	if(init == nil)
		return r;
	pick v := init {
	Var =>
		if(v.kind != Kvar) {
			s := newscope(Sfor, r.s, r.fid, r.strict);
			sput(skey(n, Sfor), s);
			for(l := patnames(init, nil); l != nil; l = tl l)
				declare(s, hd l, lexkind(v.kind));
			r2 := ref *r;
			r2.s = s;
			return r2;
		}
	}
	return r;
}

# for-in/of's expression sees the loop's names, uninitialised
forscope1tdz(n: ref Node, init: ref Node, r: ref R1): ref R1
{
	pick v := init {
	Var =>
		if(v.kind != Kvar) {
			s := newscope(Sblock, r.s, r.fid, r.strict);
			sput(skey(n, Sblock), s);
			for(l := patnames(init, nil); l != nil; l = tl l)
				declare(s, hd l, lexkind(v.kind));
			r2 := ref *r;
			r2.s = s;
			return r2;
		}
	}
	return r;
}

# this from scope r: an arrow's comes from the function around it
thisref1(r: ref R1)
{
	if(r.fnscope == nil)
		return;
	if(r.inarrowof || r.fnscope.fid != r.fid) {
		b := declare(r.fnscope, "%this", Bthis);
		capture(r.fnscope, b);
	}
}

superref1(r: ref R1)
{
	if(r.fnscope != nil && (r.inarrowof || r.fnscope.fid != r.fid)) {
		b := declare(r.fnscope, "%callee", Bcallee);
		capture(r.fnscope, b);
		b = declare(r.fnscope, "%newtarget", Bnewtarget);
		capture(r.fnscope, b);
	}
}

pseudo1(r: ref R1, name: string, kind: int)
{
	if(r.fnscope == nil)
		return;
	b := declare(r.fnscope, name, kind);
	if(r.inarrowof || r.fnscope.fid != r.fid)
		capture(r.fnscope, b);
}

argsref1(r: ref R1)
{
	if(r.fnscope == nil)
		return;
	# a binding of its own named arguments shadows the object
	for(s := r.s; s != nil && s != r.fnscope.parent; s = s.parent) {
		ob := findlocal(s, "arguments");
		if(ob != nil && ob.kind != Barguments)
			return;
	}
	b := declare(r.fnscope, "arguments", Barguments);
	if(r.inarrowof || r.fnscope.fid != r.fid)
		capture(r.fnscope, b);
}

eval1(r: ref R1)
{
	allnamed(r.s);
	if(!r.strict) {
		vs := varscope(r.s);
		vs.evalvars = 1;
	}
	if(r.fnscope != nil) {
		for(_l := array[] of {"%this", "%newtarget", "%callee"}; len _l > 0; _l = _l[1:]) {
			b := declare(r.fnscope, _l[0], Bthis);
			case _l[0] {
			"%newtarget" => b.kind = Bnewtarget;
			"%callee" => b.kind = Bcallee;
			}
			capture(r.fnscope, b);
		}
		if(!isarrowscope(r))
			argsref1(r);
	}
}

isarrowscope(r: ref R1): int
{
	return r.inarrowof;
}

func1(f: ref Node.Func, r: ref R1)
{
	id := nfid++;
	strict := r.strict || (f.flags & Jsparse->Fstrict) != 0;
	outer := r.s;
	# a named function expression's name, in a scope of its own
	if(f.id != nil && (f.flags & Jsparse->Fdecl) == 0) {
		ns := newscope(Sfnname, outer, id, strict);
		sput(skey(f, Sfnname), ns);
		declare(ns, idname(f.id), Bfnself);
		outer = ns;
	}
	fs := newscope(Sfunc, outer, id, strict);
	sput(skey(f, Sfunc), fs);
	hoistfunc(fs, f, strict);
	r2 := ref R1(fs, id, fs, 0, strict);
	if(f.flags & Jsparse->Farrow) {
		r2.fnscope = r.fnscope;
		r2.inarrowof = 1;
	}
	walklist1(f.params, r2);
	walklist1(f.body, r2);
	# a sloppy function with simple parameters and an arguments object: the
	# parameters live where the object can alias them
	ab := findlocal(fs, "arguments");
	if(ab != nil && ab.kind == Barguments && !strict && (f.flags & Jsparse->Farrow) == 0 && simpleparams(f.params))
		for(l := fs.binds; l != nil; l = tl l)
			if((hd l).kind == Bparam)
				capture(fs, hd l);
}

simpleparams(params: array of ref Node): int
{
	for(i := 0; i < len params; i++)
		if(tagof params[i] != tagof Node.Ident)
			return 0;
	return 1;
}

class1(c: ref Node.Class, r: ref R1)
{
	walk1(c.super, r);
	s := newscope(Sclass, r.s, r.fid, 1);
	sput(skey(c, Sclass), s);
	if(c.id != nil) {
		b := declare(s, idname(c.id), Bconst);
		b.kind = Bconst;
	}
	for(i := 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.key != nil)
				pick k := m.key {
				Private =>
					b := declare(s, "#" + k.name, Bpriv);
					capture(s, b);
				}
		}
	r2 := ref *r;
	r2.s = s;
	r2.strict = 1;
	for(i = 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.computed)
				walk1(m.key, r2);
			case m.kind {
			Jsparse->Pfield or Jsparse->Pblock =>
				# initialisers and static blocks run as methods: their own function
				id := nfid++;
				fs := newscope(Sfunc, s, id, 1);
				sput(skey(c.body[i], Sfunc), fs);
				r3 := ref R1(fs, id, fs, 0, 1);
				if(m.kind == Jsparse->Pblock) {
					pick b := m.value {
					Block =>
						hoistbody(fs, b.body, 1, 1);
						walklist1(b.body, r3);
					}
				} else
					walk1(m.value, r3);
			* =>
				walk1(m.value, r2);
			}
		}
	if(c.id != nil)
		ref1(s, r.fid, idname(c.id));
}

# ---- pass 2: emission ----

emit(op: int)
{
	if(cs.nops == len cs.ops) {
		a := array[2 * len cs.ops + 64] of int;
		a[0:] = cs.ops[0:cs.nops];
		cs.ops = a;
		p := array[len a] of int;
		p[0:] = cs.pos[0:cs.nops];
		cs.pos = p;
	}
	cs.pos[cs.nops] = cs.curpos;
	cs.ops[cs.nops++] = op;
}

e1(op, a: int)
{
	emit(op);
	emit(a);
}

e2(op, a, b: int)
{
	emit(op);
	emit(a);
	emit(b);
}

e3(op, a, b, c: int)
{
	emit(op);
	emit(a);
	emit(b);
	emit(c);
}

e4(op, a, b, c, d: int)
{
	emit(op);
	emit(a);
	emit(b);
	emit(c);
	emit(d);
}

e5(op, a, b, c, d, e: int)
{
	emit(op);
	emit(a);
	emit(b);
	emit(c);
	emit(d);
	emit(e);
}

here(): int
{
	return cs.nops;
}

# emit a jump whose target is not yet known; returns where to patch
ejump(op, r: int): int
{
	emit(op);
	if(op != Ojmp)
		emit(r);
	emit(-1);
	return cs.nops - 1;
}

patch(at: int)
{
	cs.ops[at] = cs.nops;
}

patchto(at, target: int)
{
	cs.ops[at] = target;
}

jumpto(op, r, target: int)
{
	emit(op);
	if(op != Ojmp)
		emit(r);
	emit(target);
}

tmp(): int
{
	r := cs.tmp++;
	if(cs.tmp > cs.nregs)
		cs.nregs = cs.tmp;
	return r;
}

tmps(n: int): int
{
	r := cs.tmp;
	cs.tmp += n;
	if(cs.tmp > cs.nregs)
		cs.nregs = cs.tmp;
	return r;
}

freeto(r: int)
{
	cs.tmp = r;
}

kconst(v: V): int
{
	cs.consts = v :: cs.consts;
	return cs.nconst++;
}

kstr(s: string): int
{
	return kconst(V(Tstr, atomsh[intern(s)], 0.0));
}

newic(): int
{
	return cs.nic++;
}

# a binding's register, in the function's register space
localreg(): int
{
	r := cs.tmp++;
	if(cs.tmp > cs.nregs)
		cs.nregs = cs.tmp;
	return r;
}

# ---- entering and leaving scopes ----

enterscope(s: ref CScope)
{
	s.parent = cscope;	# (emission's scope chain is the same as pass 1's)
	cscope = s;
	# registers for what nothing captures; slots for the rest
	slots := 0;
	names: list of int;
	kinds: list of int;
	tdzs: list of int;
	for(l := revbinds(s.binds); l != nil; l = tl l) {
		b := hd l;
		if(b.captured || s.named) {
			b.captured = 1;
			b.slot = slots++;
			names = intern(b.name) :: names;
			kinds = b.kind :: kinds;
			tdzs = istdz(b) :: tdzs;
		} else if(b.reg < 0)
			b.reg = localreg();
	}
	s.nslots = slots;
	if(s.needsenv || s.named || s.evalvars) {
		s.needsenv = 1;
		rt := ref Scope(slots, nil, lista(kinds), lista(tdzs), s.evalvars, s.kind == Sfunc);
		if(s.named || 1)
			rt.names = lista(names);
		cs.scopes = rt :: cs.scopes;
		s.rt = cs.nscope++;
		e1(Opushenv, s.rt);
		envdepth++;
	}
	# uninitialised lexical registers
	for(l = s.binds; l != nil; l = tl l) {
		b := hd l;
		if(!b.captured && istdz(b))
			e1(Oempty, b.reg);
	}
}

leavescope(s: ref CScope)
{
	if(s.needsenv) {
		emit(Opopenv);
		envdepth--;
	}
	cscope = s.parent;
}

istdz(b: ref Bind): int
{
	return b.kind == Blet || b.kind == Bconst || b.kind == Bclass || b.kind == Bimport;
}

revbinds(l: list of ref Bind): list of ref Bind
{
	r: list of ref Bind;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

lista(l: list of int): array of int
{
	n := len l;
	a := array[n] of int;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# ---- names ----

Lreg, Lenv, Lglobal, Ldyn: con iota;

# how to reach name from here: (how, register or depth, slot, binding)
lookup(name: string): (int, int, int, ref Bind)
{
	depth := 0;
	for(s := cscope; s != nil; s = s.parent) {
		if(s.kind == Swith)
			return (Ldyn, 0, 0, nil);
		b := findlocal(s, name);
		if(b != nil) {
			if(b.captured)
				return (Lenv, depth, b.slot, b);
			return (Lreg, b.reg, 0, b);
		}
		if(s.evalvars)
			return (Ldyn, 0, 0, nil);
		if(s.needsenv)
			depth++;
		if(s.kind == Seval)
			return (Ldyn, 0, 0, nil);
	}
	return (Lglobal, 0, 0, nil);
}

# load name's value into r
getname(name: string, r: int, typeofop: int)
{
	(how, x, slot, b) := lookup(name);
	case how {
	Lreg =>
		if(b.kind == Barguments && 0)
			;
		if(x != r)
			e2(Omove, r, x);
		if(istdz(b))
			e2(Ochktdz, r, intern(name));
	Lenv =>
		if(istdz(b))
			e4(Ogetenvc, r, x, slot, intern(name));
		else
			e3(Ogetenv, r, x, slot);
	Lglobal =>
		if(typeofop)
			e2(Otypeofglobal, r, intern(name));
		else
			e3(Ogetglobal, r, intern(name), newic());
	Ldyn =>
		if(typeofop)
			e2(Otypeofname, r, intern(name));
		else
			e2(Ogetname, r, intern(name));
	}
}

# store r into name; init: a declaration's initialisation (no TDZ check, const allowed)
setname(name: string, r: int, init: int)
{
	(how, x, slot, b) := lookup(name);
	case how {
	Lreg =>
		if(!init)
			assigncheck(b, name, r);
		if(x != r)
			e2(Omove, x, r);
	Lenv =>
		if(!init) {
			if(b.kind == Bconst || b.kind == Bimport) {
				e4(Ogetenvc, tmpscratch(), x, slot, intern(name));
				constassign(name);
				return;
			}
			if(b.kind == Bfnself) {
				if(cs.flags & Cstrict)
					constassign(name);
				return;
			}
			if(istdz(b)) {
				e4(Osetenvc, x, slot, r, intern(name));
				return;
			}
		}
		e3(Osetenv, x, slot, r);
	Lglobal =>
		if(init)
			e2(Oinitglobal, intern(name), r);
		else
			e2(Osetglobal, intern(name), r);
	Ldyn =>
		if(init)
			e2(Oinitname, intern(name), r);
		else
			e2(Osetname, intern(name), r);
	}
}

tmpscratch(): int
{
	t := tmp();
	freeto(t);
	return t;
}

# assignment to a register binding
assigncheck(b: ref Bind, name: string, nil: int)
{
	case b.kind {
	Bconst =>
		e2(Ochktdz, b.reg, intern(name));
		constassign(name);
	Blet or Bclass =>
		e2(Ochktdz, b.reg, intern(name));
	Bfnself =>
		if(cs.flags & Cstrict)
			constassign(name);
	}
}

constassign(name: string)
{
	e2(Othrowerr, TypeError, kstr("assignment to constant variable '" + name + "'"));
}

# ---- functions ----

# compile a function's tree to its code
compilefunc(f: ref Node.Func, parent: ref CFunc, src: string, extra: int): ref Code
{
	fs := sget(skey(f, Sfunc));
	if(fs == nil)
		compileerr(f.pos, "internal: no scope for function");
	return compilebody(f, fs, parent, src, f.flags, extra);
}

newcfunc(parent: ref CFunc, f: ref Node.Func, fs: ref CScope, src: string): ref CFunc
{
	c := ref CFunc;
	c.id = fs.fid;
	c.node = f;
	c.parent = parent;
	c.scope = fs;
	c.ops = array[256] of int;
	c.pos = array[256] of int;
	c.nops = 0;
	c.src = src;
	c.allreg = -1;
	return c;
}

compilebody(f: ref Node.Func, fs: ref CScope, parent: ref CFunc, src: string, pflags, extra: int): ref Code
{
	saved := cs;
	savedscope := cscope;
	savedenv := envdepth;
	savedcompletion := completion;
	savedlabels := pendinglabels;
	completion = -1;
	pendinglabels = nil;
	cs = newcfunc(parent, f, fs, src);
	envdepth = 0;
	strict := (pflags & Jsparse->Fstrict) != 0 || fs.strict;
	flags := 0;
	if(strict)
		flags |= Cstrict;
	if(pflags & Jsparse->Farrow)
		flags |= Carrow;
	if(pflags & Jsparse->Fgen)
		flags |= Cgen;
	if(pflags & Jsparse->Fasync)
		flags |= Casync;
	if(pflags & Jsparse->Fmethod)
		flags |= Cmethod;
	flags |= extra;
	cs.flags = flags;
	nformal := 0;
	flen := -1;
	simple := 1;
	for(i := 0; i < len f.params; i++) {
		t := tagof f.params[i];
		if(t == tagof Node.AssignPat || t == tagof Node.Rest) {
			if(flen < 0)
				flen = i;
			if(t == tagof Node.Rest) {
				simple = 0;
				continue;
			}
		}
		if(t != tagof Node.Ident)
			simple = 0;
		nformal++;
	}
	if(flen < 0)
		flen = len f.params;
	cs.tmp = Rarg0 + nformal;
	cs.nregs = cs.tmp;
	# bindings
	cscope = fs.parent;
	argsb := findlocal(fs, "arguments");
	needall := 0;
	if(argsb != nil && argsb.kind == Barguments && (pflags & Jsparse->Farrow) == 0)
		needall = 1;
	for(i = 0; i < len f.params; i++)
		if(tagof f.params[i] == tagof Node.Rest)
			needall = 1;
	if(needall) {
		cs.allreg = tmp();
		flags |= Cextra;
		cs.flags = flags;
	}
	# simple parameters keep their argument registers when not captured
	if(!fs.named && simpleparams(f.params))
		for(i = 0; i < len f.params; i++)
			pick p := f.params[i] {
			Ident =>
				b := findlocal(fs, p.name);
				if(b != nil && !b.captured && b.reg < 0 && lastparam(f.params, p.name) == i)
					b.reg = Rarg0 + i;
			}
	enterscope(fs);
	# pseudo-bindings
	for(l := fs.binds; l != nil; l = tl l) {
		b := hd l;
		case b.kind {
		Bthis =>
			storebind(b, Rthis);
		Bnewtarget =>
			storebind(b, Rnewtarget);
		Bcallee =>
			storebind(b, Rfn);
		}
	}
	# parameters
	for(i = 0; i < len f.params && simpleparams(f.params); i++) {
		pick p := f.params[i] {
		Ident =>
			b := findlocal(fs, p.name);
			if(lastparam(f.params, p.name) != i)
				continue;
			if(b.captured)
				e3(Osetenv, 0, b.slot, Rarg0 + i);
			else if(b.reg != Rarg0 + i)
				e2(Omove, b.reg, Rarg0 + i);
		}
	}
	# the arguments object
	if(argsb != nil && argsb.kind == Barguments && (pflags & Jsparse->Farrow) == 0) {
		t := tmp();
		mapped := !strict && simple;
		e2(Oargs, t, mapped);
		storebind(argsb, t);
		freeto(t);
		if(mapped)
			flags |= Cmapped;
		flags |= Cargs;
		cs.flags = flags;
	}
	# vars start undefined (params keep their values)
	for(l = fs.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.kind == Bvar && !isparamname(f.params, b.name)) {
			if(!b.captured)
				e1(Oundef, b.reg);
		}
	}
	# destructuring and default parameters
	cs.inparams = 1;
	for(i = 0; i < len f.params; i++) {
		pick p := f.params[i] {
		Ident =>
			if(!simpleparams(f.params))
				setname(p.name, Rarg0 + i, 1);
		Rest =>
			t := tmp();
			e2(Orest, t, i);
			bindpattern(p.arg, t, 1);
			freeto(t);
		* =>
			bindpattern(f.params[i], Rarg0 + i, 1);
		}
	}
	cs.inparams = 0;
	# function declarations
	hoistfuncs(f.body);
	if(flags & Cgen || flags & Casync && (flags & Cgen) == 0 && 0)
		emit(Ogenstart);
	if(flags & Cgen)
		;
	cs.nlocal = cs.tmp;
	# the body
	if(pflags & Jsparse->Fexpr) {
		pick r := f.body[0] {
		Return =>
			t := tmp();
			gexpr(r.arg, t);
			e1(Oret, t);
		}
	} else {
		usingstmts(f.body);
		t := tmp();
		e1(Oundef, t);
		derivedthis();
		e1(Oret, t);
	}
	leavescope(fs);
	code := finish(f.id, flen, nformal);
	code.paramnames = array[len f.params] of {* => -1};
	for(i = 0; i < len f.params; i++)
		pick p := f.params[i] {
		Ident =>
			code.paramnames[i] = intern(p.name);
		}
	cs = saved;
	cscope = savedscope;
	envdepth = savedenv;
	completion = savedcompletion;
	pendinglabels = savedlabels;
	return code;
}

lastparam(params: array of ref Node, name: string): int
{
	last := -1;
	for(i := 0; i < len params; i++)
		for(l := patnames(params[i], nil); l != nil; l = tl l)
			if(hd l == name)
				last = i;
	return last;
}

isparamname(params: array of ref Node, name: string): int
{
	return lastparam(params, name) >= 0;
}

storebind(b: ref Bind, r: int)
{
	if(b.captured)
		e3(Osetenv, 0, b.slot, r);
	else if(b.reg != r)
		e2(Omove, b.reg, r);
}

finish(id: ref Node, flen, nformal: int): ref Code
{
	name := "";
	if(id != nil)
		name = idname(id);
	c := ref Code;
	c.name = name;
	c.flen = flen;
	c.nparams = nformal;
	c.nregs = cs.nregs + 1;
	c.ops = cs.ops[0:cs.nops];
	c.pos = cs.pos[0:cs.nops];
	c.whole = cs.src;
	c.consts = revv(cs.consts);
	c.funcs = revcode(cs.funcs);
	hl := cs.handlers;
	c.handlers = array[len hl] of Handler;
	for(i := len c.handlers - 1; i >= 0; i--) {
		c.handlers[i] = hd hl;
		hl = tl hl;
	}
	# inner handlers first: they were added after the outer ones end... sort by start descending size
	sorthandlers(c.handlers);
	sl := cs.scopes;
	c.scopes = array[len sl] of ref Scope;
	for(i = len c.scopes - 1; i >= 0; i--) {
		c.scopes[i] = hd sl;
		sl = tl sl;
	}
	dl := cs.decls;
	c.decls = array[len dl] of ref Gdecl;
	for(i = len c.decls - 1; i >= 0; i--) {
		c.decls[i] = hd dl;
		dl = tl dl;
	}
	c.ics = array[cs.nic] of ref Shape;
	c.icslot = array[cs.nic] of int;
	c.icproto = array[cs.nic] of int;
	tl0 := cs.tmpls;
	c.tmpls = array[len tl0] of (array of string, array of string);
	for(i = len c.tmpls - 1; i >= 0; i--) {
		c.tmpls[i] = hd tl0;
		tl0 = tl tl0;
	}
	c.tmplcache = array[len c.tmpls] of {* => -1};
	rl := cs.regexps;
	c.regexps = array[len rl] of (string, string);
	for(i = len c.regexps - 1; i >= 0; i--) {
		c.regexps[i] = hd rl;
		rl = tl rl;
	}
	c.flags = cs.flags;
	c.src = cs.src;
	c.allreg = cs.allreg;
	return c;
}

# a handler for an inner try precedes the outer's
sorthandlers(h: array of Handler)
{
	for(i := 1; i < len h; i++) {
		x := h[i];
		j := i - 1;
		while(j >= 0 && (h[j].end - h[j].start) > (x.end - x.start)) {
			h[j+1] = h[j];
			j--;
		}
		h[j+1] = x;
	}
}

revv(l: list of V): array of V
{
	a := array[len l] of V;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

revcode(l: list of ref Code): array of ref Code
{
	a := array[len l] of ref Code;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# a nested function's template; returns its index
addfunc(f: ref Node.Func): int
{
	return addfuncx(f, 0);
}

addfuncx(f: ref Node.Func, extra: int): int
{
	c := compilefunc(f, cs, cs.src, extra);
	# its text is the source's, not a copy (a bundle's functions nest
	# deep: copies would be the source over again at each level)
	c.src = nil;
	if(f.end <= len cs.src && f.pos <= f.end) {
		c.spos = f.pos;
		c.send = f.end;
	}
	cs.funcs = c :: cs.funcs;
	return cs.nfunc++;
}

# the function declarations of a body, made at its start
hoistfuncs(body: array of ref Node)
{
	for(i := 0; i < len body; i++) {
		s := unlabel(body[i]);
		pick f := s {
		Func =>
			if(f.flags & Jsparse->Fdecl && f.id != nil) {
				t := tmp();
				e2(Oclosure, t, addfunc(f));
				setname(idname(f.id), t, 1);
				freeto(t);
			}
		}
	}
}

# ---- modules ----

# a module's statements with exported declarations unwrapped (for hoisting)
modulebody(body: array of ref Node): array of ref Node
{
	r := array[len body] of ref Node;
	for(i := 0; i < len body; i++) {
		r[i] = body[i];
		pick x := body[i] {
		Export =>
			if(x.decl != nil) {
				if(!x.default)
					r[i] = x.decl;
				else
					pick d := x.decl {
					Func =>
						if(d.flags & Jsparse->Fdecl && d.id != nil)
							r[i] = x.decl;
					Class =>
						if(d.decl && d.id != nil)
							r[i] = x.decl;
					}
			}
		}
	}
	return r;
}

# whether a module's top level awaits (then it is evaluated as an async function)
toplevelawait(n: ref Node): int
{
	if(n == nil)
		return 0;
	pick x := n {
	Await =>
		return 1;
	ForOf =>
		if(x.await)
			return 1;
		return toplevelawait(x.left) || toplevelawait(x.right) || toplevelawait(x.body);
	Func =>
		return 0;
	Class =>
		return 0;
	Expr => return toplevelawait(x.e);
	Var =>
		for(i := 0; i < len x.decls; i++)
			if(toplevelawait(x.decls[i]))
				return 1;
	Decl => return toplevelawait(x.init) || toplevelawait(x.id);
	Block => return listawait(x.body);
	If => return toplevelawait(x.test) || toplevelawait(x.cons) || toplevelawait(x.els);
	While => return toplevelawait(x.test) || toplevelawait(x.body);
	DoWhile => return toplevelawait(x.test) || toplevelawait(x.body);
	For => return toplevelawait(x.init) || toplevelawait(x.test) || toplevelawait(x.update) || toplevelawait(x.body);
	ForIn => return toplevelawait(x.right) || toplevelawait(x.body);
	Try => return toplevelawait(x.block) || toplevelawait(x.handler) || toplevelawait(x.final);
	Switch =>
		if(toplevelawait(x.disc))
			return 1;
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				if(toplevelawait(c.test) || listawait(c.body))
					return 1;
			}
	Labeled => return toplevelawait(x.body);
	Return => return toplevelawait(x.arg);
	Throw => return toplevelawait(x.arg);
	Export => return toplevelawait(x.decl);
	Unary => return toplevelawait(x.arg);
	Update => return toplevelawait(x.arg);
	Binary => return toplevelawait(x.l) || toplevelawait(x.r);
	Logical => return toplevelawait(x.l) || toplevelawait(x.r);
	Assign => return toplevelawait(x.target) || toplevelawait(x.value);
	Cond => return toplevelawait(x.test) || toplevelawait(x.cons) || toplevelawait(x.els);
	Call => return toplevelawait(x.callee) || listawait(x.args);
	New => return toplevelawait(x.callee) || listawait(x.args);
	Member => return toplevelawait(x.obj) || x.computed && toplevelawait(x.prop);
	Chain => return toplevelawait(x.e);
	Seq => return listawait(x.exprs);
	Paren => return toplevelawait(x.e);
	Array => return listawait(x.elems);
	Object => return listawait(x.props);
	Prop => return x.computed && toplevelawait(x.key) || toplevelawait(x.value);
	Spread => return toplevelawait(x.arg);
	Template => return listawait(x.exprs);
	Tagged => return toplevelawait(x.tag) || toplevelawait(x.quasi);
	Yield => return toplevelawait(x.arg);
	ImportCall => return toplevelawait(x.source) || toplevelawait(x.options);
	AssignPat => return toplevelawait(x.target) || toplevelawait(x.dflt);
	ArrayPat => return listawait(x.elems);
	ObjectPat => return listawait(x.props);
	Rest => return toplevelawait(x.arg);
	}
	return 0;
}

listawait(a: array of ref Node): int
{
	for(i := 0; i < len a; i++)
		if(toplevelawait(a[i]))
			return 1;
	return 0;
}

# a module's code: its environment and function declarations, a stop
# (Omodinit, where the loader links its imports), then its body
compilemodule(prog: ref Node.Program, src: string, modid: int): ref Code
{
	scopemap = array[len src / 16 + 1021] of list of (int, ref CScope);
	nfid = 1;
	top := newscope(Smodule, nil, 0, 1);
	body := modulebody(prog.body);
	hoistbody(top, body, 1, 0);
	for(i := 0; i < len body; i++) {
		pick f := body[i] {
		Func =>
			# in a module, functions are lexical (but made at the start)
			;
		}
	}
	for(i = 0; i < len prog.body; i++) {
		pick x := prog.body[i] {
		Import =>
			for(j := 0; j < len x.specs; j++)
				pick sp := x.specs[j] {
				ImportSpec =>
					b := declare(top, sp.local, Bimport);
					b.kind = Bimport;
					if(sp.kind == Jsparse->Inamespace)
						b.kind = Bconst;
				}
		Export =>
			if(x.default && x.decl != nil && body[i] == prog.body[i]) {
				# an expression, or an anonymous function or class
				anonfn := 0;
				pick d := x.decl {
				Func =>
					anonfn = (d.flags & Jsparse->Fdecl) != 0;
				}
				if(anonfn)
					declare(top, "*default*", Bfunc);
				else
					declare(top, "*default*", Blet);
			}
		}
	}
	top.named = 1;
	top.needsenv = 1;
	for(l := top.binds; l != nil; l = tl l)
		(hd l).captured = 1;
	r := ref R1(top, 0, nil, 0, 1);
	walklist1(prog.body, r);
	f := ref Node.Func(0, len src, nil, array[0] of ref Node, prog.body, 0);
	saved := cs;
	cs = newcfunc(nil, f, top, src);
	cs.flags = Cmodule | Cstrict;
	if(listawait(prog.body))
		cs.flags |= Casync;
	cs.tmp = Rarg0;
	cs.nregs = Rarg0;
	cscope = nil;
	envdepth = 0;
	completion = -1;
	enterscope(top);
	hoistfuncs(body);
	# an anonymous default function is made now too
	for(i = 0; i < len prog.body; i++)
		pick x := prog.body[i] {
		Export =>
			if(x.default && x.decl != nil)
				pick d := x.decl {
				Func =>
					if(d.flags & Jsparse->Fdecl && d.id == nil) {
						t := tmp();
						e2(Oclosure, t, addfunc(d));
						k := tmp();
						e2(Oconst, k, kstr("default"));
						e3(Osetfnname, t, k, 0);
						setname("*default*", t, 1);
						freeto(t);
					}
				}
		}
	cs.nlocal = cs.tmp;
	emit(Omodinit);
	usingstmts(prog.body);
	t := tmp();
	e1(Oundef, t);
	e1(Oret, t);
	leavescope(top);
	code := finish(nil, 0, 0);
	code.modid = modid;
	cs = saved;
	return code;
}

exportstmt(x: ref Node.Export)
{
	if(x.decl == nil)
		return;	# export { ... } and export * : the loader's
	if(!x.default) {
		stmt(x.decl);
		return;
	}
	pick d := x.decl {
	Func =>
		if(d.flags & Jsparse->Fdecl)
			return;	# made at the start
	Class =>
		if(d.decl && d.id != nil) {
			stmt(x.decl);
			return;
		}
	}
	t := tmp();
	gexpr(x.decl, t);
	if(isanonfn(x.decl)) {
		k := tmp();
		e2(Oconst, k, kstr("default"));
		e3(Osetfnname, t, k, 0);
	}
	setname("*default*", t, 1);
}

# ---- scripts and eval ----

# the code for a script; evalcode: direct eval's (strict: and in strict code)
compilescript(prog: ref Node.Program, src: string, iseval, evalstrict: int): ref Code
{
	scopemap = array[len src / 16 + 1021] of list of (int, ref CScope);
	nfid = 1;
	strict := prog.strict || evalstrict;
	kind := Sscript;
	if(iseval)
		kind = Seval;
	top := newscope(kind, nil, 0, strict);
	if(iseval && strict)
		top.kind = Seval;
	r := ref R1(top, 0, nil, 0, strict);
	if(iseval) {
		# eval code's vars: its own when strict, else the caller's (by name, at run time)
		if(strict)
			hoistbody(top, prog.body, 1, 1);
		else
			hoistlexonly(top, prog.body);
	} else
		hoistlexonly(top, prog.body);
	walklist1(prog.body, r);
	f := ref Node.Func(0, len src, nil, array[0] of ref Node, prog.body, 0);
	saved := cs;
	cs = newcfunc(nil, f, top, src);
	cs.flags = Cscript;
	if(strict)
		cs.flags |= Cstrict;
	if(iseval) {
		cs.flags |= Ceval;
		cs.evalctx0 = evalctxin;
		cs.evalprivs0 = evalprivsin;
	}
	cs.tmp = Rarg0;
	cs.nregs = Rarg0;
	cscope = nil;
	envdepth = 0;
	if(kind == Sscript || iseval && !strict) {
		# global (or the caller's var) declarations
		g := globaldecls(prog.body, strict);
		cs.decls = g :: cs.decls;
		e1(Oglobalinit, cs.ndecl++);
		top.binds = nil;	# all of them are global, or the caller's
		top.tab = nil;
		top.nbinds = 0;
		top.needsenv = 0;
		if(iseval) {
			top.kind = Seval;
			hoistlexonly(top, prog.body);
			top.needsenv = 1;
			top.named = 1;
			for(l := top.binds; l != nil; l = tl l)
				(hd l).captured = 1;
		}
	}
	enterscope(top);
	if(kind == Sscript)
		;
	hoistfuncs(prog.body);
	cs.nlocal = cs.tmp;
	result := tmp();
	e1(Oundef, result);
	completion = result;
	stmts(prog.body);
	completion = -1;
	e1(Oret, result);
	leavescope(top);
	code := finish(nil, 0, 0);
	code.evalctx = evalctxin;
	code.evalprivs = evalprivsin;
	cs = saved;
	return code;
}

# the register a script's statements leave their values in (the completion value), or -1
completion := -1;

# the context the eval code being compiled inherits
evalctxin := 0;
evalprivsin: list of string;

hoistlexonly(s: ref CScope, body: array of ref Node)
{
	for(i := 0; i < len body; i++) {
		t := unlabel(body[i]);
		pick x := t {
		Var =>
			if(x.kind != Kvar)
				for(l := patnames(t, nil); l != nil; l = tl l)
					declare(s, hd l, lexkind(x.kind));
		Class =>
			if(x.decl && x.id != nil)
				declare(s, idname(x.id), Bclass);
		}
	}
}

globaldecls(body: array of ref Node, strict: int): ref Gdecl
{
	vars := revstr(varlist1(body, nil));
	funcs: list of (int, int);
	lets: list of int;
	consts: list of int;
	for(i := 0; i < len body; i++) {
		s := unlabel(body[i]);
		pick x := s {
		Var =>
			if(x.kind == Klet)
				for(nl := patnames(s, nil); nl != nil; nl = tl nl)
					lets = intern(hd nl) :: lets;
			else if(x.kind == Kconst)
				for(cl := patnames(s, nil); cl != nil; cl = tl cl)
					consts = intern(hd cl) :: consts;
		Class =>
			if(x.decl && x.id != nil)
				lets = intern(idname(x.id)) :: lets;
		Func =>
			if(x.flags & Jsparse->Fdecl && x.id != nil)
				funcs = (intern(idname(x.id)), -1) :: funcs;
		}
	}
	ab: list of int;
	if(!strict) {
		fake := newscope(Sfunc, nil, 0, 0);
		annexb(fake, body, 0);
		for(l := fake.binds; l != nil; l = tl l)
			if((hd l).annexb)
				ab = intern((hd l).name) :: ab;
	}
	va := array[len vars] of int;
	j := 0;
	for(l := vars; l != nil; l = tl l)
		va[j++] = intern(hd l);
	fa := array[len funcs] of (int, int);
	j = len fa;
	for(fl := funcs; fl != nil; fl = tl fl)
		fa[--j] = hd fl;
	return ref Gdecl(va, fa, lista(lets), lista(consts), lista(ab));
}

revstr(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# ---- statements ----

stmts(a: array of ref Node)
{
	for(i := 0; i < len a; i++)
		stmt(a[i]);
}

stmt(n: ref Node)
{
	if(n == nil)
		return;
	cs.curpos = n.pos;
	t0 := cs.tmp;
	pick x := n {
	Expr =>
		if(completion >= 0)
			gexpr(x.e, completion);
		else {
			t := tmp();
			gexpr(x.e, t);
		}
	Var =>
		vardecl(x);
	Func =>
		if(x.flags & Jsparse->Fdecl) {
			# made at the start of its scope; Annex B copies a block's to the var
			if(x.id != nil && cscope.kind != Sfunc && cscope.kind != Sscript && cscope.kind != Seval && cscope.kind != Smodule) {
				fsc := varscopeof(cscope);
				name := idname(x.id);
				vb := findlocal(fsc, name);
				if(vb != nil && vb.annexb) {
					t := tmp();
					getname(name, t, 0);
					annexbset(fsc, vb, t);
				} else if(fsc.kind == Sscript && iscriptannexb(name)) {
					t := tmp();
					getname(name, t, 0);
					e2(Osetglobal, intern(name), t);
				}
			}
		} else {
			t := tmp();
			gexpr(n, t);
		}
	Class =>
		t := tmp();
		classexpr(x, t);
		if(x.id != nil)
			setname(idname(x.id), t, 1);
	Block =>
		s := sget(skey(n, Sblock));
		enterscope(s);
		hoistfuncs(x.body);
		usingstmts(x.body);
		leavescope(s);
	Empty or Debugger =>
		;
	Return =>
		t := tmp();
		if(x.arg != nil)
			gexpr(x.arg, t);
		else
			e1(Oundef, t);
		if(cs.flags & Casync && (cs.flags & Cgen) && x.arg != nil)
			e2(Oawait, t, t);
		retthrough(t);
	If =>
		if(completion >= 0)
			e1(Oundef, completion);
		t := tmp();
		gexpr(x.test, t);
		j := ejump(Ojf, t);
		freeto(t0);
		substmt(x.cons);
		if(x.els != nil) {
			j2 := ejump(Ojmp, 0);
			patch(j);
			substmt(x.els);
			patch(j2);
		} else
			patch(j);
	While =>
		lab := newlabel(1, n);
		if(completion >= 0)
			e1(Oundef, completion);
		top := here();
		lab.contpc = top;
		t := tmp();
		gexpr(x.test, t);
		j := ejump(Ojf, t);
		freeto(t0);
		stmt(x.body);
		jumpto(Ojmp, 0, top);
		patch(j);
		endlabel(lab);
	DoWhile =>
		lab := newlabel(1, n);
		if(completion >= 0)
			e1(Oundef, completion);
		top := here();
		stmt(x.body);
		patchconts(lab, here());
		t := tmp();
		gexpr(x.test, t);
		jumpto(Ojt, t, top);
		endlabel(lab);
	For =>
		forstmt(n, x);
	ForIn =>
		forinstmt(n, x.left, x.right, x.body, 0, 0);
	ForOf =>
		forinstmt(n, x.left, x.right, x.body, 1, x.await);
	Labeled =>
		labeled(x);
	Break =>
		breakto(x.label, 0, n.pos);
	Continue =>
		breakto(x.label, 1, n.pos);
	Throw =>
		t := tmp();
		gexpr(x.arg, t);
		e1(Othrow, t);
	Try =>
		trystmt(n, x);
	Switch =>
		switchstmt(n, x);
	With =>
		t := tmp();
		gexpr(x.obj, t);
		if(completion >= 0)
			e1(Oundef, completion);
		s := sget(skey(n, Swith));
		s.parent = cscope;
		cscope = s;
		e1(Opushwith, t);
		envdepth++;
		s.needsenv = 1;
		freeto(t0);
		stmt(x.body);
		emit(Opopenv);
		envdepth--;
		cscope = s.parent;
	Export =>
		exportstmt(x);
	Import =>
		;
	* =>
		compileerr(n.pos, "internal: unexpected statement");
	}
	freeto(t0);
}

varscopeof(s: ref CScope): ref CScope
{
	while(s.kind != Sfunc && s.kind != Sscript && s.kind != Seval && s.kind != Smodule)
		s = s.parent;
	return s;
}

annexbset(fsc: ref CScope, vb: ref Bind, t: int)
{
	if(vb.captured) {
		# the var's depth from here
		depth := 0;
		for(s := cscope; s != nil && s != fsc; s = s.parent)
			if(s.needsenv)
				depth++;
		e3(Osetenv, depth, vb.slot, t);
	} else
		e2(Omove, vb.reg, t);
}

iscriptannexb(name: string): int
{
	# the script's Gdecl lists them
	for(l := cs.decls; l != nil; l = tl l) {
		g := hd l;
		a := intern(name);
		for(i := 0; i < len g.annexb; i++)
			if(g.annexb[i] == a)
				return 1;
	}
	return 0;
}

# an if's branch: a sloppy function declaration there is in a block of its own
substmt(n: ref Node)
{
	if(n == nil)
		return;
	pick f := n {
	Func =>
		if(f.flags & Jsparse->Fdecl) {
			s := sget(skey(n, Sblock));
			enterscope(s);
			hoistfuncs(array[] of {n});
			stmt(n);
			leavescope(s);
			return;
		}
	}
	stmt(n);
}

vardecl(x: ref Node.Var)
{
	for(i := 0; i < len x.decls; i++)
		pick d := x.decls[i] {
		Decl =>
			cs.curpos = d.pos;
			t0 := cs.tmp;
			if(d.init == nil) {
				if(x.kind == Kvar)
					continue;
				t := tmp();
				e1(Oundef, t);
				bindpattern(d.id, t, 1);
			} else {
				t := tmp();
				if(tagof d.id == tagof Node.Ident)
					namedexpr(d.init, t, idname(d.id));
				else
					gexpr(d.init, t);
				if((x.kind == Kusing || x.kind == Kawaitusing) && cs.disps != nil) {
					(ds, nil) := hd cs.disps;
					e3(Oaddres, ds, t, x.kind == Kawaitusing);
				}
				bindpattern(d.id, t, x.kind != Kvar);
			}
			freeto(t0);
		}
}

# an anonymous function or class given a name by where it is (NamedEvaluation)
namedexpr(e: ref Node, r: int, name: string)
{
	if(isanonfn(e)) {
		gexpr(e, r);
		k := kstr(name);
		t := tmp();
		e2(Oconst, t, k);
		e3(Osetfnname, r, t, 0);
		freeto(t);
		return;
	}
	gexpr(e, r);
}

isanonfn(e: ref Node): int
{
	pick x := e {
	Func =>
		return x.id == nil;
	Class =>
		return x.id == nil;
	Paren =>
		return isanonfn(x.e);	# (f) is still an anonymous function definition; (0, f) is not
	}
	return 0;
}

# ---- loops, labels, jumps ----

pendinglabels: list of string;

newlabel(isloop: int, nil: ref Node): ref Label
{
	l := ref Label(pendinglabels, isloop, nil, nil, -1, envdepth, len cs.finally, -1, 0);
	pendinglabels = nil;
	cs.labels = l :: cs.labels;
	return l;
}

endlabel(l: ref Label)
{
	for(b := l.breaks; b != nil; b = tl b)
		patch(hd b);
	if(l.contpc >= 0)
		for(c := l.conts; c != nil; c = tl c)
			patchto(hd c, l.contpc);
	cs.labels = tl cs.labels;
}

patchconts(l: ref Label, pc: int)
{
	l.contpc = pc;
	for(c := l.conts; c != nil; c = tl c)
		patchto(hd c, pc);
	l.conts = nil;
}

labeled(x: ref Node.Labeled)
{
	pendinglabels = x.label :: pendinglabels;
	body := unlabel(x.body);
	bt := tagof body;
	if(bt == tagof Node.While || bt == tagof Node.DoWhile || bt == tagof Node.For || bt == tagof Node.ForIn || bt == tagof Node.ForOf) {
		stmt(x.body);
		return;
	}
	if(tagof x.body == tagof Node.Labeled) {
		stmt(x.body);
		return;
	}
	lab := newlabel(0, x);
	stmt(x.body);
	endlabel(lab);
}

breakto(name: string, iscont: int, nil: int)
{
	lab: ref Label;
	for(l := cs.labels; l != nil; l = tl l) {
		x := hd l;
		# (isloop: 1 a loop, 3 a switch, which only break leaves)
		if(name == nil) {
			if(x.isloop == 1 || !iscont && x.isloop == 3)
				lab = x;
		} else if(hasname(x.names, name) && (!iscont || x.isloop == 1))
			lab = x;
		if(lab != nil)
			break;
	}
	if(lab == nil)
		compileerr(0, "internal: no target for break or continue");
	# out through any finally blocks, popping environments and closing iterators on the way
	jumpout(lab, iscont);
}

jumpout(lab: ref Label, iscont: int)
{
	nfin := len cs.finally - lab.findepth;
	if(nfin > 0) {
		# the innermost finally runs first, then continues the jump
		f := hd cs.finally;
		code := 3 + f.ncodes++;
		f.targets = (code, lab, iscont) :: f.targets;
		popenvs(f.scopedepth);
		e2(Oint, f.reg, code);
		f.jumps = (ejump(Ojmp, 0), code) :: f.jumps;
		return;
	}
	popenvs(lab.scopedepth);
	# leaving a for-of early closes its iterator (inner loops' too)
	for(l := cs.labels; l != nil; l = tl l) {
		x := hd l;
		if(x == lab) {
			if(!iscont && x.iterreg >= 0)
				closeiter(x.iterreg, x.iterasync);
			break;
		}
		if(x.iterreg >= 0)
			closeiter(x.iterreg, x.iterasync);
	}
	j := ejump(Ojmp, 0);
	if(iscont)
		lab.conts = j :: lab.conts;
	else
		lab.breaks = j :: lab.breaks;
}

# a derived constructor whose this an arrow may have bound: the frame's from the binding
derivedthis()
{
	if((cs.flags & Cderived) == 0 || cs.flags & Carrow)
		return;
	(how, nil, slot, b) := lookup("%this");
	if(how == Lenv)
		e3(Ogetenv, Rthis, envdepthof(b), slot);
	else if(how == Lreg && b.reg != Rthis)
		e2(Omove, Rthis, b.reg);
}

envdepthof(nil: ref Bind): int
{
	(nil, depth, nil, nil) := lookup("%this");
	return depth;
}

# IteratorClose (or AsyncIteratorClose) for a normal completion
closeiter(it, async: int)
{
	if(!async) {
		e1(Oiterclose, it);
		return;
	}
	t := tmp();
	e2(Oitreturn, t, it);
	je := ejump(Ojempty, t);
	e2(Oawait, t, t);
	e1(Ochkobj, t);
	patch(je);
	freeto(t);
}

popenvs(depth: int)
{
	for(i := envdepth; i > depth; i--)
		emit(Opopenv);
}

# return, through any finally blocks
retthrough(t: int)
{
	if(cs.finally != nil) {
		f := hd cs.finally;
		popenvs(f.scopedepth);
		e2(Omove, f.val, t);
		e2(Oint, f.reg, 2);
		f.retseen = 1;
		f.jumps = (ejump(Ojmp, 0), 2) :: f.jumps;
		return;
	}
	# close the iterators of for-of loops being left
	for(l := cs.labels; l != nil; l = tl l)
		if((hd l).iterreg >= 0)
			closeiter((hd l).iterreg, (hd l).iterasync);
	derivedthis();
	e1(Oret, t);
}

forstmt(n: ref Node, x: ref Node.For)
{
	s := sget(skey(n, Sfor));
	if(s != nil)
		enterscope(s);
	if(x.init != nil) {
		pick v := x.init {
		Var =>
			vardecl(v);
		* =>
			t := tmp();
			gexpr(x.init, t);
			freeto(t);
		}
	}
	if(completion >= 0)
		e1(Oundef, completion);
	perit := s != nil && s.needsenv;
	if(perit)
		emit(Ocopyenv);
	lab := newlabel(1, n);
	top := here();
	j := -1;
	if(x.test != nil) {
		t := tmp();
		gexpr(x.test, t);
		j = ejump(Ojf, t);
		freeto(t);
	}
	stmt(x.body);
	patchconts(lab, here());
	if(perit)
		emit(Ocopyenv);
	if(x.update != nil) {
		t := tmp();
		gexpr(x.update, t);
		freeto(t);
	}
	jumpto(Ojmp, 0, top);
	if(j >= 0)
		patch(j);
	endlabel(lab);
	if(s != nil)
		leavescope(s);
}

forinstmt(n: ref Node, left, right, body: ref Node, isof, isawait: int)
{
	t0 := cs.tmp;
	# the expression, with the loop's lexical names uninitialised
	ts := sget(skey(n, Sblock));
	if(ts != nil)
		enterscope(ts);
	obj := tmp();
	gexpr(right, obj);
	if(ts != nil)
		leavescope(ts);
	if(completion >= 0)
		e1(Oundef, completion);
	it := tmps(2);
	lab := newlabel(1, n);
	if(isof) {
		e3(Ogetiter, it, obj, isawait);
		lab.iterreg = it;
		lab.iterasync = isawait;
	} else {
		e2(Oforin, it, obj);
	}
	top := here();
	lab.contpc = top;
	val := tmp();
	done := -1;
	if(isof) {
		d := tmp();
		if(isawait) {
			# next(), awaited, then its done and value
			e2(Oitercall, val, it);
			e2(Oawait, val, val);
			e4(Oiterres, val, d, val, it);
		} else
			e3(Oiternext, val, d, it);
		done = ejump(Ojt, d);
	} else {
		emit(Oforinnext);
		emit(val);
		emit(it);
		emit(-1);
		done = cs.nops - 1;
	}
	# the binding, fresh each time
	s := sget(skey(n, Sfor));
	if(s != nil)
		enterscope(s);
	# an exception in the binding or the body closes the iterator
	hstart := here();
	pick v := left {
	Var =>
		pick d := v.decls[0] {
		Decl =>
			if(d.init != nil && v.kind == Kvar) {
				# Annex B: for (var x = e in o)
				t := tmp();
				gexpr(d.init, t);
				bindpattern(d.id, t, 0);
			}
			bindpattern(d.id, val, v.kind != Kvar);
		}
	* =>
		assignpattern(left, val);
	}
	stmt(body);
	hend := here();
	if(s != nil)
		leavescope(s);
	jumpto(Ojmp, 0, top);
	# the handler: close, then rethrow
	if(isof) {
		hr := tmps(2);
		cs.handlers = Handler(hstart, hend, here(), hr, Hclose, 0) :: cs.handlers;
		popenvs(lab.scopedepth);
		# a generator's return closes the iterator (its errors count), then goes on
		jnr := ejump(Ojf, hr + 1);
		closeiter(it, isawait);
		e1(Ogenret, hr);
		patch(jnr);
		if(isawait) {
			# AsyncIteratorClose for a throw: return() and its await, their errors dropped
			t := tmp();
			cstart := here();
			e2(Oitreturn, t, it);
			je := ejump(Ojempty, t);
			e2(Oawait, t, t);
			patch(je);
			cend := here();
			jt := ejump(Ojmp, 0);
			ignored := tmp();
			cs.handlers = Handler(cstart, cend, here(), ignored, Hcatch, 0) :: cs.handlers;
			patch(jt);
		} else
			e1(Oiterdone, it);	# (IteratorClose for a throw completion: errors from return are dropped)
		e1(Othrow, hr);
	}
	patch(done);
	lab.iterreg = -1;
	endlabel(lab);
	freeto(t0);
}

switchstmt(n: ref Node, x: ref Node.Switch)
{
	t0 := cs.tmp;
	d := tmp();
	gexpr(x.disc, d);
	if(completion >= 0)
		e1(Oundef, completion);
	s := sget(skey(n, Sswitch));
	enterscope(s);
	all: array of ref Node;
	for(i := 0; i < len x.cases; i++)
		pick c := x.cases[i] {
		Case =>
			all = catnodes(all, c.body);
		}
	hoistfuncs(all);
	lab := newlabel(0, n);
	lab.isloop = 3;	# a break target
	jumps := array[len x.cases] of int;
	dflt := -1;
	t := tmp();
	for(i = 0; i < len x.cases; i++)
		pick c := x.cases[i] {
		Case =>
			if(c.test == nil) {
				dflt = i;
				continue;
			}
			gexpr(c.test, t);
			e3(Oseq, t, d, t);
			jumps[i] = ejump(Ojt, t);
		}
	nomatch := ejump(Ojmp, 0);
	for(i = 0; i < len x.cases; i++)
		pick c := x.cases[i] {
		Case =>
			if(c.test == nil)
				dflt = here();
			else
				patch(jumps[i]);
			stmts(c.body);
		}
	if(dflt >= 0)
		patchto(nomatch, dflt);
	else
		patch(nomatch);
	endlabel(lab);
	leavescope(s);
	freeto(t0);
}

trystmt(n: ref Node, x: ref Node.Try)
{
	t0 := cs.tmp;
	fin: ref Fin;
	if(x.final != nil) {
		fin = ref Fin(nil, 0, tmp(), tmp(), nil, 0, envdepth, -1);
		if(cs.flags & Cgen)
			fin.retseen = 1;	# a generator's return() may come through
		cs.finally = fin :: cs.finally;
	}
	if(completion >= 0)
		e1(Oundef, completion);
	start := here();
	envsave := tmp();
	e2(Omove, envsave, Renv);
	stmt(x.block);
	end := here();
	toend: list of int;
	if(x.handler != nil) {
		toend = ejump(Ojmp, 0) :: toend;
		ex := tmp();
		cs.handlers = Handler(start, end, here(), ex, Hcatch, 0) :: cs.handlers;
		e2(Omove, Renv, envsave);
		restoredepth := envdepth;
		s := sget(skey(n, Scatch));
		enterscope(s);
		if(x.param != nil)
			bindpattern(x.param, ex, 1);
		if(completion >= 0)
			e1(Oundef, completion);
		stmt(x.handler);
		leavescope(s);
		envdepth = restoredepth;
		end = here();
	}
	if(fin != nil) {
		cs.finally = tl cs.finally;
		# normal completion falls in with code 0
		for(l := toend; l != nil; l = tl l)
			patch(hd l);
		toend = nil;
		e2(Oint, fin.reg, 0);
		jf := ejump(Ojmp, 0);
		# a throw from the try or catch: code 1
		cs.handlers = Handler(start, end, here(), fin.val, Hfinally, 0) :: cs.handlers;
		e2(Oint, fin.reg, 1);	# (first: a generator's return enters after it, with 2)
		e2(Omove, Renv, envsave);
		patch(jf);
		for(jl := fin.jumps; jl != nil; jl = tl jl)
			patch((hd jl).t0);
		saved := completion;
		if(completion >= 0) {
			# the finally's own value does not replace the completion
			completion = tmp();
		}
		stmt(x.final);
		completion = saved;
		# then: 0 go on, 1 rethrow, 2 return, 3+ the jumps
		t := tmp();
		e2(Oint, t, 1);
		e3(Oseq, t, fin.reg, t);
		j := ejump(Ojf, t);
		e1(Othrow, fin.val);
		patch(j);
		if(fin.retseen) {
			e2(Oint, t, 2);
			e3(Oseq, t, fin.reg, t);
			j = ejump(Ojf, t);
			retthrough(fin.val);
			patch(j);
		}
		for(tl0 := fin.targets; tl0 != nil; tl0 = tl tl0) {
			(code, lab, iscont) := hd tl0;
			e2(Oint, t, code);
			e3(Oseq, t, fin.reg, t);
			j = ejump(Ojf, t);
			jumpout(lab, iscont);
			patch(j);
		}
	}
	for(l := toend; l != nil; l = tl l)
		patch(hd l);
	freeto(t0);
}

# statements that may declare using resources: they are disposed of,
# last first, however the statements end (§14.2.3, DisposeResources)
usingstmts(body: array of ref Node)
{
	async := 0;
	has := 0;
	for(i := 0; i < len body; i++)
		pick v := body[i] {
		Var =>
			if(v.kind == Kusing)
				has = 1;
			if(v.kind == Kawaitusing)
				has = async = 1;
		}
	if(!has) {
		stmts(body);
		return;
	}
	t0 := cs.tmp;
	ds := tmp();
	e1(Onewdisp, ds);
	cs.disps = (ds, async) :: cs.disps;
	fin := ref Fin(nil, 0, tmp(), tmp(), nil, 0, envdepth, -1);
	if(cs.flags & Cgen)
		fin.retseen = 1;
	cs.finally = fin :: cs.finally;
	start := here();
	envsave := tmp();
	e2(Omove, envsave, Renv);
	stmts(body);
	end := here();
	cs.finally = tl cs.finally;
	cs.disps = tl cs.disps;
	e2(Oint, fin.reg, 0);
	jf := ejump(Ojmp, 0);
	cs.handlers = Handler(start, end, here(), fin.val, Hfinally, 0) :: cs.handlers;
	e2(Oint, fin.reg, 1);
	e2(Omove, Renv, envsave);
	patch(jf);
	for(jl := fin.jumps; jl != nil; jl = tl jl)
		patch((hd jl).t0);
	# err: the throw being completed, or empty
	err := tmp();
	t := tmp();
	e1(Oempty, err);
	e2(Oint, t, 1);
	e3(Oseq, t, fin.reg, t);
	j := ejump(Ojf, t);
	e2(Omove, err, fin.val);
	patch(j);
	# each resource, last first: dispose, collecting errors
	rec := tmp();
	res := tmp();
	top := here();
	emit(Odisnext);
	emit(rec);
	emit(ds);
	emit(-1);
	done := cs.nops - 1;
	hs := here();
	e2(Odiscall, res, rec);
	if(async)
		e2(Oawait, res, res);
	he := here();
	jok := ejump(Ojmp, 0);
	ex := tmp();
	cs.handlers = Handler(hs, he, here(), ex, Hcatch, 0) :: cs.handlers;
	e2(Oaccum, err, ex);
	patch(jok);
	jumpto(Ojmp, 0, top);
	patch(done);
	# an error (the original throw, or one from disposal) is thrown
	j = ejump(Ojempty, err);
	e1(Othrow, err);
	patch(j);
	if(fin.retseen) {
		e2(Oint, t, 2);
		e3(Oseq, t, fin.reg, t);
		j = ejump(Ojf, t);
		retthrough(fin.val);
		patch(j);
	}
	for(tl0 := fin.targets; tl0 != nil; tl0 = tl tl0) {
		(code, lab, iscont) := hd tl0;
		e2(Oint, t, code);
		e3(Oseq, t, fin.reg, t);
		j = ejump(Ojf, t);
		jumpout(lab, iscont);
		patch(j);
	}
	freeto(t0);
}

# ---- binding and assignment patterns ----

# bind (declare) the pattern's names from register v; init: a lexical initialisation
bindpattern(p: ref Node, v: int, init: int)
{
	pick x := p {
	Ident =>
		setname(x.name, v, init || 1);
	* =>
		destructure(p, v, 1);
	}
}

# assign to a target (a name, property or pattern) from register v
assignpattern(p: ref Node, v: int)
{
	pick x := p {
	Ident =>
		setname(x.name, v, 0);
	Member =>
		t0 := cs.tmp;
		o := tmp();
		gexpr(x.obj, o);
		if(x.computed) {
			k := tmp();
			gexpr(x.prop, k);
			e3(Osetelem, o, k, v);
		} else
			setmember(o, x, v);
		freeto(t0);
	Paren =>
		assignpattern(x.e, v);
	* =>
		destructure(p, v, 0);
	}
}

setmember(o: int, x: ref Node.Member, v: int)
{
	pick k := x.prop {
	Ident =>
		e4(Osetprop, o, intern(k.name), v, newic());
	Private =>
		pr := tmp();
		getname("#" + k.name, pr, 0);
		e3(Osetpriv, o, pr, v);
	}
}

# a target: binding (declare) or assign
target(p: ref Node, v: int, binding: int)
{
	if(binding)
		bindpattern(p, v, 1);
	else
		assignpattern(p, v);
}

destructure(p: ref Node, v: int, binding: int)
{
	t0 := cs.tmp;
	pick x := p {
	AssignPat =>
		t := tmp();
		e2(Omove, t, v);
		j := ejump(Ojnundef, t);
		if(tagof x.target == tagof Node.Ident)
			namedexpr(x.dflt, t, idname(x.target));
		else
			gexpr(x.dflt, t);
		patch(j);
		target(x.target, t, binding);
	ObjectPat =>
		e1(Oreqobj, v);
		keys := -1;
		hasrest := len x.props > 0 && tagof x.props[len x.props - 1] == tagof Node.Rest;
		if(hasrest) {
			keys = tmp();
			e1(Onewarr, keys);
		}
		for(i := 0; i < len x.props; i++) {
			pick pr := x.props[i] {
			Prop =>
				val := tmp();
				k := tmp();
				if(pr.computed) {
					gexpr(pr.key, k);
					e2(Otokey, k, k);
				} else
					litkey(pr.key, k);
				if(hasrest)
					e2(Oarrpush, keys, k);
				e3(Ogetelem, val, v, k);
				pick dv := pr.value {
				AssignPat =>
					j := ejump(Ojnundef, val);
					if(tagof dv.target == tagof Node.Ident)
						namedexpr(dv.dflt, val, idname(dv.target));
					else
						gexpr(dv.dflt, val);
					patch(j);
					target(dv.target, val, binding);
				* =>
					target(pr.value, val, binding);
				}
				freeto(val);
			Rest =>
				r := tmp();
				e1(Onewobj, r);
				e3(Ocopyprops, r, v, keys);
				target(pr.arg, r, binding);
				freeto(r);
			}
		}
	ArrayPat =>
		it := tmps(2);
		e3(Ogetiter, it, v, 0);
		done := tmp();
		e1(Ofalse, done);
		val := tmp();
		hstart := here();
		for(i := 0; i < len x.elems; i++) {
			el := x.elems[i];
			if(el != nil && tagof el == tagof Node.Rest) {
				pick r := el {
				Rest =>
					a := tmp();
					e1(Onewarr, a);
					top := here();
					j := ejump(Ojt, done);
					e3(Oiternext, val, done, it);
					j2 := ejump(Ojt, done);
					e2(Oarrpush, a, val);
					jumpto(Ojmp, 0, top);
					patch(j);
					patch(j2);
					target(r.arg, a, binding);
				}
				continue;
			}
			# the next value, or undefined once done
			e1(Oundef, val);
			j := ejump(Ojt, done);
			e3(Oiternext, val, done, it);
			j2 := ejump(Ojf, done);
			e1(Oundef, val);
			patch(j2);
			patch(j);
			if(el == nil)
				continue;
			pick ap := el {
			AssignPat =>
				j3 := ejump(Ojnundef, val);
				if(tagof ap.target == tagof Node.Ident)
					namedexpr(ap.dflt, val, idname(ap.target));
				else
					gexpr(ap.dflt, val);
				patch(j3);
				target(ap.target, val, binding);
			* =>
				target(el, val, binding);
			}
		}
		hend := here();
		# done normally: close if not exhausted
		j := ejump(Ojt, done);
		e1(Oiterclose, it);
		patch(j);
		jend := ejump(Ojmp, 0);
		# an exception: close (unless the iterator threw), rethrow
		hr := tmps(2);
		cs.handlers = Handler(hstart, hend, here(), hr, Hclose, 0) :: cs.handlers;
		jnr := ejump(Ojf, hr + 1);
		j = ejump(Ojt, done);
		e1(Oiterclose, it);
		patch(j);
		e1(Ogenret, hr);
		patch(jnr);
		j = ejump(Ojt, done);
		e1(Oiterdone, it);
		patch(j);
		e1(Othrow, hr);
		patch(jend);
	Paren =>
		destructure(x.e, v, binding);
	* =>
		assignpattern(p, v);
	}
	freeto(t0);
}

# a literal property key into register r
litkey(k: ref Node, r: int)
{
	pick x := k {
	Ident =>
		e2(Oconst, r, kstr(x.name));
	Str =>
		e2(Oconst, r, kconst(strv(x.s)));
		pinconst();
	Num =>
		e2(Oconst, r, kconst(num(x.n)));
	BigInt =>
		e2(Oconst, r, kconst(strv(bigcanon(x.digits))));
		pinconst();
	* =>
		gexpr(k, r);
	}
}

# a string constant must outlive collections: intern it
pinconst()
{
	v := hd cs.consts;
	if(v.t == Tstr) {
		a := intern(str(v.x));
		cs.consts = V(Tstr, atomsh[a], 0.0) :: tl cs.consts;
	}
}

# ---- expressions ----

# evaluate e into register r
gexpr(e: ref Node, r: int)
{
	t0 := cs.tmp;
	if(r >= t0)
		cs.tmp = r + 1;
	if(cs.tmp > cs.nregs)
		cs.nregs = cs.tmp;
	expr(e, r);
	freeto(t0);
	if(r >= t0 && r >= cs.tmp) {
		cs.tmp = r + 1;
		freeto(t0);
	}
}

expr(e: ref Node, r: int)
{
	pick x := e {
	Num =>
		if(x.n == real int x.n && x.n >= -16r40000000.0 && x.n < 16r40000000.0 && !(x.n == 0.0 && signbit(x.n)))
			e2(Oint, r, int x.n);
		else
			e2(Oconst, r, kconst(num(x.n)));
	Str =>
		e2(Oconst, r, kstr(x.s));
	BigInt =>
		e2(Oconst, r, kconst(V(Tbig, atomsh[intern(bigcanon(x.digits))], 0.0)));
	Bool =>
		if(x.v)
			e1(Otrue, r);
		else
			e1(Ofalse, r);
	Null =>
		e1(Onull, r);
	Ident =>
		if(x.name == "undefined" && lookupisglobal("undefined"))
			e1(Oundef, r);
		else
			getname(x.name, r, 0);
	This =>
		thisinto(r);
	Template =>
		template(x, r);
	Regex =>
		cs.regexps = (x.pattern, x.flags) :: cs.regexps;
		e2(Oregexp, r, cs.nregexp++);
	Paren =>
		expr(x.e, r);
	Array =>
		arraylit(x, r);
	Object =>
		objectlit(x, r);
	Func =>
		funcexpr(x, r);
	Class =>
		classexpr(x, r);
	Unary =>
		unary(x, r);
	Update =>
		update(x, r);
	Binary =>
		binary(x, r);
	Logical =>
		logical(x, r);
	Assign =>
		assign(x, r);
	Cond =>
		t := tmp();
		gexpr(x.test, t);
		j := ejump(Ojf, t);
		gexpr(x.cons, r);
		j2 := ejump(Ojmp, 0);
		patch(j);
		gexpr(x.els, r);
		patch(j2);
	Seq =>
		for(i := 0; i < len x.exprs; i++)
			gexpr(x.exprs[i], r);
	Member =>
		cmember(x, r, -1);
	Chain =>
		ends := ref Ends(nil);
		chain(x.e, r, ends);
		j := ejump(Ojmp, 0);
		for(el := ends.l; el != nil; el = tl el)
			patch(hd el);
		e1(Oundef, r);
		patch(j);
	Call =>
		ccall(x, r);
	New =>
		newexpr(x, r);
	Tagged =>
		tagged(x, r);
	Spread =>
		compileerr(e.pos, "internal: spread out of place");
	Yield =>
		yieldexpr(x, r);
	Await =>
		gexpr(x.arg, r);
		e2(Oawait, r, r);
	Meta =>
		if(x.meta == "new")
			newtargetinto(r);
		else
			e1(Oimportmeta, r);
	ImportCall =>
		s := tmp();
		gexpr(x.source, s);
		o := tmp();
		if(x.options != nil)
			gexpr(x.options, o);
		else
			e1(Oundef, o);
		e3(Oimport, r, s, o);
	Super =>
		compileerr(e.pos, "internal: super out of place");
	Private =>
		compileerr(e.pos, "internal: private name out of place");
	* =>
		compileerr(e.pos, "internal: unexpected expression");
	}
}

lookupisglobal(name: string): int
{
	(how, nil, nil, nil) := lookup(name);
	return how == Lglobal;
}

thisinto(r: int)
{
	if(cs.flags & (Carrow|Cscript|Ceval) || cs.flags & Cstatic) {
		(how, nil, nil, nil) := lookup("%this");
		if(how == Lglobal && cs.flags & Cscript && (cs.flags & Ceval) == 0) {
			e2(Omove, r, Rthis);
			return;
		}
		if(how != Lglobal && how != Ldyn) {
			getname("%this", r, 0);
			e1(Ochkthis, r);
			return;
		}
		if(how == Ldyn) {
			e1(Othisdyn, r);
			e1(Ochkthis, r);
			return;
		}
	}
	if(cs.flags & Cderived) {
		(how, nil, nil, nil) := lookup("%this");
		if(how == Lenv || how == Lreg)
			getname("%this", r, 0);
		else
			e2(Omove, r, Rthis);
		e1(Ochkthis, r);
		return;
	}
	e2(Omove, r, Rthis);
}

newtargetinto(r: int)
{
	if(cs.flags & (Carrow|Ceval)) {
		(how, nil, nil, nil) := lookup("%newtarget");
		if(how == Lenv || how == Lreg) {
			getname("%newtarget", r, 0);
			return;
		}
		if(how == Ldyn) {
			e2(Ogetname, r, intern("%newtarget"));
			return;
		}
		e1(Oundef, r);
		return;
	}
	e2(Omove, r, Rnewtarget);
}

template(x: ref Node.Template, r: int)
{
	e2(Oconst, r, kstr(x.quasis[0]));
	t := tmp();
	for(i := 0; i < len x.exprs; i++) {
		gexpr(x.exprs[i], t);
		e2(Otostr, t, t);
		e3(Oconcat, r, r, t);
		if(x.quasis[i+1] != "") {
			e2(Oconst, t, kstr(x.quasis[i+1]));
			e3(Oconcat, r, r, t);
		}
	}
}

tagged(x: ref Node.Tagged, r: int)
{
	pick q := x.quasi {
	Template =>
		f := tmp();
		this := tmp();
		calleeandthis(x.tag, f, this);
		n := 1 + len q.exprs;
		args := tmps(n);
		cs.tmpls = (q.quasis, q.raws) :: cs.tmpls;
		e2(Otemplate, args, cs.ntmpl++);
		for(i := 0; i < len q.exprs; i++)
			gexpr(q.exprs[i], args + 1 + i);
		e5(Ocall, r, f, this, args, n);
	}
}

arraylit(x: ref Node.Array, r: int)
{
	e1(Onewarr, r);
	t := tmp();
	for(i := 0; i < len x.elems; i++) {
		el := x.elems[i];
		if(el == nil) {
			e1(Oarrhole, r);
			continue;
		}
		pick s := el {
		Spread =>
			gexpr(s.arg, t);
			e2(Oarrspread, r, t);
			continue;
		}
		gexpr(el, t);
		e2(Oarrpush, r, t);
	}
}

objectlit(x: ref Node.Object, r: int)
{
	e1(Onewobj, r);
	k := tmp();
	v := tmp();
	for(i := 0; i < len x.props; i++) {
		pick p := x.props[i] {
		Spread =>
			gexpr(p.arg, v);
			e2(Ospreadobj, r, v);
		Prop =>
			cs.curpos = p.pos;
			if(p.kind == Jsparse->Pinit && !p.computed && !p.shorthand && isprotokey(p.key)) {
				gexpr(p.value, v);
				e2(Osetproto, r, v);
				continue;
			}
			if(p.computed) {
				gexpr(p.key, k);
				e2(Otokey, k, k);
			} else
				litkey(p.key, k);
			case p.kind {
			Jsparse->Pinit =>
				gexpr(p.value, v);
				if(isanonfn(p.value))
					e3(Osetfnname, v, k, 0);
				e3(Odefdata, r, k, v);
			Jsparse->Pmethod =>
				methodfunc(p.value, v, r);
				e3(Osetfnname, v, k, 0);
				e3(Odefdata, r, k, v);
			Jsparse->Pget =>
				methodfunc(p.value, v, r);
				e3(Osetfnname, v, k, 1);
				e4(Odefacc, r, k, v, 1 | 4);
			Jsparse->Pset =>
				methodfunc(p.value, v, r);
				e3(Osetfnname, v, k, 2);
				e4(Odefacc, r, k, v, 2 | 4);
			}
		}
	}
}

isprotokey(k: ref Node): int
{
	pick x := k {
	Ident =>
		return x.name == "__proto__";
	Str =>
		return x.s == "__proto__";
	}
	return 0;
}

# a method's function, with its home object
methodfunc(f: ref Node, r: int, home: int)
{
	pick x := f {
	Func =>
		e2(Oclosure, r, addfunc(x));
		e2(Osethome, r, home);
	}
}

funcexpr(f: ref Node.Func, r: int)
{
	ns := sget(skey(f, Sfnname));
	if(ns != nil && ns.needsenv) {
		enterscope(ns);
		e2(Oclosure, r, addfunc(f));
		b := findlocal(ns, idname(f.id));
		e3(Osetenv, 0, b.slot, r);
		leavescope(ns);
		return;
	}
	if(ns != nil) {
		ns.parent = cscope;
		cscope = ns;
		e2(Oclosure, r, addfunc(f));
		cscope = ns.parent;
		return;
	}
	e2(Oclosure, r, addfunc(f));
}

unary(x: ref Node.Unary, r: int)
{
	case x.op {
	"typeof" =>
		pick id := x.arg {
		Ident =>
			getname(id.name, r, 1);
			e2(Otypeof, r, r);
			return;
		}
		gexpr(x.arg, r);
		e2(Otypeof, r, r);
	"delete" =>
		del(x.arg, r);
	"void" =>
		gexpr(x.arg, r);
		e1(Oundef, r);
	"!" =>
		gexpr(x.arg, r);
		e2(Onot, r, r);
	"-" =>
		gexpr(x.arg, r);
		e2(Oneg, r, r);
	"+" =>
		gexpr(x.arg, r);
		e2(Opos, r, r);
	"~" =>
		gexpr(x.arg, r);
		e2(Obnot, r, r);
	}
}

del(a: ref Node, r: int)
{
	pick x := a {
	Ident =>
		(how, nil, nil, nil) := lookup(x.name);
		case how {
		Lglobal =>
			e2(Odelglobal, r, intern(x.name));
		Ldyn =>
			e2(Odelname, r, intern(x.name));
		* =>
			e1(Ofalse, r);
		}
	Member =>
		if(tagof x.obj == tagof Node.Super) {
			thisinto(tmp());
			e2(Othrowerr, ReferenceError, kstr("unsupported reference to 'super'"));
			return;
		}
		o := tmp();
		gexpr(x.obj, o);
		if(x.computed) {
			k := tmp();
			gexpr(x.prop, k);
			e3(Odelelem, r, o, k);
		} else
			pick k := x.prop {
			Ident =>
				e3(Odelprop, r, o, intern(k.name));
			}
		if(cs.flags & Cstrict) {
			j := ejump(Ojt, r);
			e2(Othrowerr, TypeError, kstr("cannot delete property"));
			patch(j);
		}
	Chain =>
		ends := ref Ends(nil);
		pick m := x.e {
		Member =>
			o := tmp();
			chainobj(m, o, ends);
			if(m.computed) {
				k := tmp();
				gexpr(m.prop, k);
				e3(Odelelem, r, o, k);
			} else
				pick k := m.prop {
				Ident =>
					e3(Odelprop, r, o, intern(k.name));
				}
			if(cs.flags & Cstrict) {
				j := ejump(Ojt, r);
				e2(Othrowerr, TypeError, kstr("cannot delete property"));
				patch(j);
			}
		* =>
			chain(x.e, r, ends);
			e1(Otrue, r);
		}
		j := ejump(Ojmp, 0);
		for(el := ends.l; el != nil; el = tl el)
			patch(hd el);
		e1(Otrue, r);
		patch(j);
	Paren =>
		del(x.e, r);
	* =>
		gexpr(a, r);
		e1(Otrue, r);
	}
}

binop(op: string): int
{
	case op {
	"+" => return Oadd;
	"-" => return Osub;
	"*" => return Omul;
	"/" => return Odiv;
	"%" => return Omod;
	"**" => return Oexp;
	"<<" => return Oshl;
	">>" => return Oshr;
	">>>" => return Oushr;
	"&" => return Oband;
	"|" => return Obor;
	"^" => return Obxor;
	"==" => return Oeq;
	"!=" => return One;
	"===" => return Oseq;
	"!==" => return Osne;
	"<" => return Olt;
	"<=" => return Ole;
	">" => return Ogt;
	">=" => return Oge;
	"instanceof" => return Oinstof;
	}
	return -1;
}

binary(x: ref Node.Binary, r: int)
{
	if(x.op == "in") {
		pick p := x.l {
		Private =>
			pr := tmp();
			getname("#" + p.name, pr, 0);
			o := tmp();
			gexpr(x.r, o);
			e3(Ohaspriv, r, pr, o);
			return;
		}
		k := tmp();
		gexpr(x.l, k);
		o := tmp();
		gexpr(x.r, o);
		e3(Oin, r, k, o);
		return;
	}
	a := tmp();
	gexpr(x.l, a);
	b := tmp();
	gexpr(x.r, b);
	e3(binop(x.op), r, a, b);
}

logical(x: ref Node.Logical, r: int)
{
	gexpr(x.l, r);
	j: int;
	case x.op {
	"&&" => j = ejump(Ojf, r);
	"||" => j = ejump(Ojt, r);
	"??" => j = ejump(Ojnnullish, r);
	}
	gexpr(x.r, r);
	patch(j);
}

assign(x: ref Node.Assign, r: int)
{
	if(x.op == "=") {
		pick t := x.target {
		Ident =>
			namedexpr(x.value, r, t.name);
			setname(t.name, r, 0);
		Member =>
			if(tagof t.obj == tagof Node.Super) {
				k := tmp();
				if(t.computed)
					gexpr(t.prop, k);
				else
					litkey(t.prop, k);
				gexpr(x.value, r);
				superset(k, r);
				return;
			}
			o := tmp();
			gexpr(t.obj, o);
			if(t.computed) {
				k := tmp();
				gexpr(t.prop, k);
				gexpr(x.value, r);
				e3(Osetelem, o, k, r);
			} else {
				gexpr(x.value, r);
				setmember(o, t, r);
			}
		Paren =>
			gexpr(x.value, r);
			assignpattern(x.target, r);
		* =>
			gexpr(x.value, r);
			assignpattern(x.target, r);
		}
		return;
	}
	# compound and logical assignment: read, combine, write
	logic := x.op == "&&=" || x.op == "||=" || x.op == "??=";
	op := -1;
	if(!logic)
		op = binop(x.op[0:len x.op - 1]);
	pick t := unparen(x.target) {
	Ident =>
		getname(t.name, r, 0);
		if(logic) {
			j := logicjump(x.op, r);
			namedexpr(x.value, r, t.name);
			setname(t.name, r, 0);
			patch(j);
			return;
		}
		b := tmp();
		gexpr(x.value, b);
		e3(op, r, r, b);
		setname(t.name, r, 0);
	Member =>
		if(tagof t.obj == tagof Node.Super) {
			k := tmp();
			if(t.computed) {
				gexpr(t.prop, k);
				e2(Otokey, k, k);
			} else
				litkey(t.prop, k);
			superget(r, k);
			if(logic) {
				j := logicjump(x.op, r);
				gexpr(x.value, r);
				superset(k, r);
				patch(j);
				return;
			}
			b := tmp();
			gexpr(x.value, b);
			e3(op, r, r, b);
			superset(k, r);
			return;
		}
		o := tmp();
		gexpr(t.obj, o);
		k := tmp();
		if(t.computed) {
			gexpr(t.prop, k);
			e1(Oreqobj, o);
			e2(Otokey, k, k);
			e3(Ogetelem, r, o, k);
		} else
			getmember(o, t, r);
		if(logic) {
			j := logicjump(x.op, r);
			gexpr(x.value, r);
			if(t.computed)
				e3(Osetelem, o, k, r);
			else
				setmember(o, t, r);
			patch(j);
			return;
		}
		b := tmp();
		gexpr(x.value, b);
		e3(op, r, r, b);
		if(t.computed)
			e3(Osetelem, o, k, r);
		else
			setmember(o, t, r);
	* =>
		# a call (sloppy, Annex B): evaluate it, then fail
		gexpr(x.target, r);
		e2(Othrowerr, ReferenceError, kstr("invalid assignment target"));
	}
}

unparen(e: ref Node): ref Node
{
	for(;;) {
		pick p := e {
		Paren =>
			e = p.e;
			continue;
		}
		return e;
	}
}

logicjump(op: string, r: int): int
{
	case op {
	"&&=" => return ejump(Ojf, r);
	"||=" => return ejump(Ojt, r);
	}
	return ejump(Ojnnullish, r);
}

update(x: ref Node.Update, r: int)
{
	op := Oinc;
	if(x.op == "--")
		op = Odec;
	pick t := unparen(x.arg) {
	Ident =>
		getname(t.name, r, 0);
		e2(Otonumeric, r, r);
		if(x.prefix) {
			e2(op, r, r);
			setname(t.name, r, 0);
		} else {
			n := tmp();
			e2(op, n, r);
			setname(t.name, n, 0);
		}
	Member =>
		if(tagof t.obj == tagof Node.Super) {
			k := tmp();
			if(t.computed) {
				gexpr(t.prop, k);
				e2(Otokey, k, k);
			} else
				litkey(t.prop, k);
			superget(r, k);
			e2(Otonumeric, r, r);
			n := tmp();
			e2(op, n, r);
			superset(k, n);
			if(x.prefix)
				e2(Omove, r, n);
			return;
		}
		o := tmp();
		gexpr(t.obj, o);
		k := tmp();
		if(t.computed) {
			gexpr(t.prop, k);
			e1(Oreqobj, o);
			e2(Otokey, k, k);
			e3(Ogetelem, r, o, k);
		} else
			getmember(o, t, r);
		e2(Otonumeric, r, r);
		n := tmp();
		e2(op, n, r);
		if(t.computed)
			e3(Osetelem, o, k, n);
		else
			setmember(o, t, n);
		if(x.prefix)
			e2(Omove, r, n);
	* =>
		gexpr(x.arg, r);
		e2(Othrowerr, ReferenceError, kstr("invalid update target"));
	}
}

getmember(o: int, x: ref Node.Member, r: int)
{
	pick k := x.prop {
	Ident =>
		e4(Ogetprop, r, o, intern(k.name), newic());
	Private =>
		pr := tmp();
		getname("#" + k.name, pr, 0);
		e3(Ogetpriv, r, o, pr);
	* =>
		kr := tmp();
		gexpr(x.prop, kr);
		e3(Ogetelem, r, o, kr);
	}
}

# a member expression into r; this: where the object goes (for a call), or nil
cmember(x: ref Node.Member, r: int, this: int)
{
	if(tagof x.obj == tagof Node.Super) {
		k := tmp();
		if(x.computed) {
			gexpr(x.prop, k);
			e2(Otokey, k, k);
		} else
			litkey(x.prop, k);
		superget(r, k);
		if(this >= 0)
			thisinto(this);
		return;
	}
	o: int;
	if(this >= 0)
		o = this;
	else
		o = tmp();
	gexpr(x.obj, o);
	if(x.computed) {
		k := tmp();
		gexpr(x.prop, k);
		e3(Ogetelem, r, o, k);
	} else
		getmember(o, x, r);
}

# an optional chain's parts into r; ends: where a short circuit jumps
chain(e: ref Node, r: int, ends: ref Ends)
{
	pick x := e {
	Member =>
		o := tmp();
		chainobj(x, o, ends);
		if(x.computed) {
			k := tmp();
			gexpr(x.prop, k);
			e3(Ogetelem, r, o, k);
		} else
			getmember(o, x, r);
	Call =>
		f := tmp();
		this := tmp();
		chaincallee(x.callee, f, this, ends);
		if(x.optional)
			ends.l = ejump(Ojnullish, f) :: ends.l;
		callargs(x, r, f, this);
	Paren =>
		gexpr(e, r);
	* =>
		gexpr(e, r);
	}
}

chainobj(x: ref Node.Member, o: int, ends: ref Ends)
{
	chainpart(x.obj, o, ends);
	if(x.optional)
		ends.l = ejump(Ojnullish, o) :: ends.l;
}

chainpart(e: ref Node, r: int, ends: ref Ends)
{
	if(tagof e == tagof Node.Member || tagof e == tagof Node.Call)
		chain(e, r, ends);
	else
		gexpr(e, r);
}

chaincallee(e: ref Node, f, this: int, ends: ref Ends)
{
	pick m := e {
	Member =>
		if(tagof m.obj == tagof Node.Super) {
			cmember(m, f, this);
			return;
		}
		chainpart(m.obj, this, ends);
		if(m.optional)
			ends.l = ejump(Ojnullish, this) :: ends.l;
		if(m.computed) {
			k := tmp();
			gexpr(m.prop, k);
			e3(Ogetelem, f, this, k);
		} else
			getmember(this, m, f);
		return;
	}
	chainpart(e, f, ends);
	e1(Oundef, this);
}

# callee and this for a call
calleeandthis(c: ref Node, f, this: int)
{
	pick m := unparen(c) {
	Member =>
		cmember(m, f, this);
		return;
	Ident =>
		(how, nil, nil, nil) := lookup(m.name);
		if(how == Ldyn) {
			e3(Ocallname, f, this, intern(m.name));
			return;
		}
	Chain =>
		gexpr(c, f);
		e1(Oundef, this);
		return;
	}
	gexpr(c, f);
	e1(Oundef, this);
}

ccall(x: ref Node.Call, r: int)
{
	if(tagof x.callee == tagof Node.Super) {
		supercall(x, r);
		return;
	}
	f := tmp();
	this := tmp();
	calleeandthis(x.callee, f, this);
	pick id := x.callee {
	Ident =>
		if(id.name == "eval" && !hasspread(x.args)) {
			n := len x.args;
			args := tmps(n);
			for(i := 0; i < n; i++)
				gexpr(x.args[i], args + i);
			# the scope eval runs in: the function's whole chain is reachable by name
			flags := 0;
			if(cs.flags & Cstrict)
				flags |= 1;
			(ctx, privs) := evalcontext();
			flags |= ctx << 1;
			if(privs != nil) {
				ps := "";
				for(; privs != nil; privs = tl privs)
					ps += " " + hd privs;
				flags |= (kstr(ps) + 1) << 8;
			}
			emit(Oeval);
			emit(r);
			emit(f);
			emit(args);
			emit(n);
			emit(flags);
			return;
		}
	}
	callargs(x, r, f, this);
}

# what a direct eval here may use: new.target, super, the private names around it
evalcontext(): (int, list of string)
{
	ctx := 0;
	c := cs;
	while(c != nil && (c.flags & Carrow))
		c = c.parent;
	if(c != nil && (c.flags & (Cscript|Cmodule)) == 0) {
		if(c.flags & Ceval)
			ctx |= c.evalctx0;
		else {
			ctx |= Jsparse->Enewtarget;
			if(c.flags & Cmethod)
				ctx |= Jsparse->Esuperprop;
			if(c.flags & Cctor && c.flags & Cderived)
				ctx |= Jsparse->Esupercall;
			if(c.flags & Cgetter)
				ctx |= Jsparse->Efield;
		}
	}
	# in parameters: eval's var arguments would clash with the function's own
	# (its arguments object, or a parameter of that name; an arrow has neither)
	if(cs.inparams && ((cs.flags & Carrow) == 0 || lastparam(cs.node.params, "arguments") >= 0))
		ctx |= 32;
	privs: list of string;
	for(s := cscope; s != nil; s = s.parent)
		for(l := s.binds; l != nil; l = tl l)
			if((hd l).kind == Bpriv)
				privs = (hd l).name[1:] :: privs;
	if(cs.flags & Ceval)
		for(pl := cs.evalprivs0; pl != nil; pl = tl pl)
			privs = hd pl :: privs;
	return (ctx, privs);
}

hasspread(a: array of ref Node): int
{
	for(i := 0; i < len a; i++)
		if(tagof a[i] == tagof Node.Spread)
			return 1;
	return 0;
}

callargs(x: ref Node.Call, r, f, this: int)
{
	if(hasspread(x.args)) {
		a := tmp();
		spreadargs(x.args, a);
		e4(Ocallspread, r, f, this, a);
		return;
	}
	n := len x.args;
	args := tmps(n);
	for(i := 0; i < n; i++)
		gexpr(x.args[i], args + i);
	e5(Ocall, r, f, this, args, n);
}

spreadargs(args: array of ref Node, a: int)
{
	e1(Onewarr, a);
	t := tmp();
	for(i := 0; i < len args; i++) {
		pick s := args[i] {
		Spread =>
			gexpr(s.arg, t);
			e2(Oarrspread, a, t);
		* =>
			gexpr(args[i], t);
			e2(Oarrpush, a, t);
		}
	}
}

newexpr(x: ref Node.New, r: int)
{
	f := tmp();
	gexpr(x.callee, f);
	if(hasspread(x.args)) {
		a := tmp();
		spreadargs(x.args, a);
		e3(Onewspread, r, f, a);
		return;
	}
	n := len x.args;
	args := tmps(n);
	for(i := 0; i < n; i++)
		gexpr(x.args[i], args + i);
	e4(Onew, r, f, args, n);
}

supercall(x: ref Node.Call, r: int)
{
	if(hasspread(x.args)) {
		a := tmp();
		spreadargs(x.args, a);
		(fr, ntr) := supercallregs();
		e4(Osupercallspread, r, a, fr, ntr);
	} else {
		n := len x.args;
		args := tmps(n);
		for(i := 0; i < n; i++)
			gexpr(x.args[i], args + i);
		(fr, ntr) := supercallregs();
		e5(Osupercall, r, args, n, fr, ntr);
	}
	# this is now bound: in the frame, and where arrows and eval see it
	(how, nil, nil, nil) := lookup("%this");
	if(how == Lenv || how == Lreg || how == Ldyn)
		setname("%this", r, 1);
}

yieldexpr(x: ref Node.Yield, r: int)
{
	if(x.delegate) {
		yieldstar(x, r);
		return;
	}
	if(x.arg != nil)
		gexpr(x.arg, r);
	else
		e1(Oundef, r);
	if(cs.flags & Casync)
		e2(Oawait, r, r);
	e2(Oyield, r, r);
}

# yield*: delegate to an iterator until it is done (§15.5.5)
yieldstar(x: ref Node.Yield, r: int)
{
	t0 := cs.tmp;
	v := tmp();
	gexpr(x.arg, v);
	it := tmps(2);
	async := (cs.flags & Casync) != 0;
	e3(Ogetiter, it, v, async);
	mode := tmp();
	e2(Oint, mode, 0);
	e1(Oundef, r);
	res := tmp();
	done := tmp();
	top := here();
	# per resume mode: the inner next, throw or return, with what was sent
	emit(Oystep);
	emit(res);
	emit(done);
	emit(it);
	emit(mode);
	emit(r);
	if(async) {
		e2(Oawait, res, res);
		e4(Oiterres, res, done, res, -1);
	}
	jd := ejump(Ojt, done);
	e3(Oyieldraw, r, mode, res);
	jumpto(Ojmp, 0, top);
	patch(jd);
	# a return that finished the inner iterator returns from here
	e2(Oint, done, 2);
	e3(Oseq, done, mode, done);
	jr := ejump(Ojf, done);
	if(async)
		e2(Oawait, res, res);
	retthrough(res);
	patch(jr);
	e2(Omove, r, res);
	freeto(t0);
}

# the function (for its home object) and this for super.x
superregs(): (int, int)
{
	thisr := tmp();
	thisinto(thisr);
	if(cs.flags & (Carrow|Ceval)) {
		fr := tmp();
		calleeinto(fr);
		return (fr, thisr);
	}
	return (Rfn, thisr);
}

calleeinto(r: int)
{
	(how, nil, nil, nil) := lookup("%callee");
	if(how == Lenv || how == Lreg)
		getname("%callee", r, 0);
	else if(how == Ldyn)
		e2(Ogetname, r, intern("%callee"));
	else
		e1(Oundef, r);
}

superget(r, k: int)
{
	(fr, thisr) := superregs();
	e4(Ogetsuper, r, k, fr, thisr);
}

superset(k, v: int)
{
	(fr, thisr) := superregs();
	e4(Osetsuper, k, v, fr, thisr);
}

# the constructor (whose prototype is the super constructor) and new.target for super()
supercallregs(): (int, int)
{
	if(cs.flags & (Carrow|Ceval)) {
		fr := tmp();
		calleeinto(fr);
		ntr := tmp();
		newtargetinto(ntr);
		return (fr, ntr);
	}
	return (Rfn, Rnewtarget);
}

# ---- classes ----

classexpr(c: ref Node.Class, r: int)
{
	t0 := cs.tmp;
	sup := tmp();
	if(c.super != nil) {
		gexpr(c.super, sup);
	} else
		e1(Oempty, sup);
	s := sget(skey(c, Sclass));
	enterscope(s);
	# a new private name for each #x, each time the class is made
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.kind == Bpriv) {
			t := tmp();
			e2(Onewprivate, t, intern(b.name));
			e3(Osetenv, 0, b.slot, t);
			freeto(t);
		}
	}
	# the constructor
	ctor: ref Node.Func;
	for(i := 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.kind == Jsparse->Pctor)
				pick f := m.value {
				Func =>
					ctor = f;
				}
		}
	derived := c.super != nil;
	fidx: int;
	cname := "";
	if(c.id != nil)
		cname = idname(c.id);
	if(ctor != nil) {
		fidx = addfuncflags(ctor, Cctor | Cderived * derived | Cclassfields);
	} else {
		fidx = defaultctor(derived, c);
	}
	proto := tmp();
	e4(Oclass, r, proto, sup, fidx);
	# fields: an initialiser function the constructor runs
	k := tmp();
	v := tmp();
	statics: list of ref Node.Method;
	nfields := 0;
	for(i = 0; i < len c.body; i++) {
		pick m := c.body[i] {
		Method =>
			cs.curpos = m.pos;
			if(m.kind == Jsparse->Pctor)
				continue;
			if(m.kind == Jsparse->Pfield || m.kind == Jsparse->Pblock) {
				if(m.static)
					statics = m :: statics;
				else
					nfields++;
				# a computed key is evaluated now, in order
				continue;
			}
			home := proto;
			if(m.static)
				home = r;
			pick f := m.value {
			Func =>
				e2(Oclosure, v, addfunc(f));
				e2(Osethome, v, home);
			}
			kind := 0;
			case m.kind {
			Jsparse->Pget => kind = 1;
			Jsparse->Pset => kind = 2;
			}
			pick pk := m.key {
			Private =>
				getname("#" + pk.name, k, 0);
				e3(Osetfnname, v, k, kind);
				if(m.static)
					e4(Oprivmethod, r, k, v, kind);
				else
					e4(Oprivmethod, proto, k, v, kind | 8);	# instance: installed by the constructor
				continue;
			}
			if(m.computed) {
				gexpr(m.key, k);
				e2(Otokey, k, k);
			} else
				litkey(m.key, k);
			e3(Osetfnname, v, k, kind);
			e4(Odefmethod, home, k, v, kind);
		}
	}
	# instance fields and their computed keys
	fieldsfn(c, s, r, proto, 0);
	# static fields and blocks, in order
	fieldsfn(c, s, r, proto, 1);
	if(c.id != nil) {
		b := findlocal(s, idname(c.id));
		if(b.captured)
			e3(Osetenv, 0, b.slot, r);
		else
			e2(Omove, b.reg, r);
	}
	leavescope(s);
	freeto(t0);
	if(cname == nil)
		;
}

# compile the field initialisers (static: and static blocks) as one method,
# run on the instance by the constructor, or on the class now
fieldsfn(c: ref Node.Class, s: ref CScope, ctor, proto, static: int)
{
	n := 0;
	for(i := 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if((m.kind == Jsparse->Pfield || m.kind == Jsparse->Pblock) && m.static == static)
				n++;
		}
	if(n == 0)
		return;
	# the computed keys, now; the initialisers in the method, later
	keys := tmp();
	e1(Onewarr, keys);
	k := tmp();
	for(i = 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.kind != Jsparse->Pfield || m.static != static)
				continue;
			if(m.computed) {
				gexpr(m.key, k);
				e2(Otokey, k, k);
				e2(Oarrpush, keys, k);
			}
		}
	# one function per field or block, run in order by the class (static) or constructor
	fns := tmp();
	e1(Onewarr, fns);
	f := tmp();
	for(i = 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if((m.kind != Jsparse->Pfield && m.kind != Jsparse->Pblock) || m.static != static)
				continue;
			fs := sget(skey(c.body[i], Sfunc));
			ffn := ref Node.Func(m.pos, m.end, nil, array[0] of ref Node, nil, Jsparse->Fmethod | Jsparse->Fstrict);
			if(m.kind == Jsparse->Pblock) {
				pick b := m.value {
				Block =>
					ffn.body = b.body;
				}
			} else {
				ffn.flags |= Jsparse->Fexpr;
				val := m.value;
				if(val == nil)
					val = ref Node.Ident(m.pos, m.pos, "undefined");
				ffn.body = array[1] of ref Node;
				ffn.body[0] = ref Node.Return(m.pos, m.end, val);
			}
			saved := cs;
			fx := 0;
			if(m.kind == Jsparse->Pfield)
				fx = Cgetter;
			if(static)
				fx |= Cstatic;
			code := compilebody(ffn, fs, cs, cs.src, ffn.flags, fx);
			code.flags |= Cmethod;
			if(static)
				code.flags |= Cstatic;
			if(m.kind == Jsparse->Pfield) {
				code.flags |= Cgetter;	# a field: the value is defined as the key
				if(!m.computed && m.key != nil) {
					pick pk := m.key {
					Private =>
						code.name = "#" + pk.name;
					Ident =>
						code.name = pk.name;
					Str =>
						code.name = pk.s;
					Num =>
						code.name = numstr(pk.n);
					}
				}
			}
			cs = saved;
			cs.funcs = code :: cs.funcs;
			e2(Oclosure, f, cs.nfunc++);
			home := proto;
			if(static)
				home = ctor;
			e2(Osethome, f, home);
			# the key, for a field
			if(m.kind == Jsparse->Pfield) {
				if(m.computed)
					e1(Onull, k);	# taken from keys, in order, by the VM
				else {
					pick pk := m.key {
					Private =>
						getname("#" + pk.name, k, 0);
					* =>
						litkey(m.key, k);
					}
				}
				e3(Osetfnname, f, k, 16 | m.computed);	# marks the field's key, not a name
			}
			e2(Oarrpush, fns, f);
		}
	if(static)
		e4(Odefmethod, ctor, fns, keys, 32);	# run the static fields now
	else
		e4(Odefmethod, ctor, fns, keys, 64);	# the constructor runs them
}

addfuncflags(f: ref Node.Func, flags: int): int
{
	i := addfuncx(f, flags);
	c := hd cs.funcs;
	c.flags |= flags;
	if((flags & Cderived) == 0)
		c.flags &= ~Cderived;
	return i;
}

# constructor(...args) { super(...args); } or constructor() {}
defaultctor(derived: int, c: ref Node.Class): int
{
	code := ref Code;
	code.name = "";
	if(c.id != nil)
		code.name = idname(c.id);
	code.flen = 0;
	code.nparams = 0;
	code.nregs = Rarg0 + 4;
	code.flags = Cstrict | Cctor | Cclassfields | Cnoctor;
	code.allreg = -1;
	if(derived) {
		# constructor(...args) { super(...args); }
		code.flags |= Cderived | Cextra;
		code.allreg = Rarg0;
		code.ops = array[] of {Orest, Rarg0+1, 0, Osupercallspread, Rarg0+2, Rarg0+1, Rfn, Rnewtarget, Oret, Rarg0+2};
	} else
		code.ops = array[] of {Oundef, Rarg0, Oret, Rarg0};
	code.pos = array[len code.ops] of {* => c.pos};
	code.src = "";
	if(c.end <= len cs.src)
		code.src = cs.src[c.pos:c.end];
	code.funcs = array[0] of ref Code;
	cs.funcs = code :: cs.funcs;
	return cs.nfunc++;
}

# a BigInt literal's digits, canonical decimal
bigcanon(d: string): string
{
	if(len d > 2 && d[0] == '0' && (d[1] == 'x' || d[1] == 'X' || d[1] == 'o' || d[1] == 'O' || d[1] == 'b' || d[1] == 'B')) {
		base := 16;
		case d[1] {
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		return bigfromradix(d[2:], base);
	}
	i := 0;
	while(i < len d - 1 && d[i] == '0')
		i++;
	return d[i:];
}
