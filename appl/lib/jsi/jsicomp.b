#
# jsicomp.b - the tree the evaluator walks, made from the parser's.
#
# The tree is flat: a node is an index into parallel arrays of ints
# (its operation and up to five operands), so that walking it moves no
# Limbo pointers and counts no references.  A node's children are
# other indices; lists of them are runs in kids.  Constants live in
# knum and kstr, the rest of what a node needs (a loop's labels, a
# class's members) in infos.
#
# Names are resolved here, once.  A binding that no function inside its
# own captures lives in its function's frame; one that is captured lives
# in an Env, and a scope with such a binding makes one when it is
# entered.  Whether a binding is captured is known only when its scope
# is closed, so a reference is first emitted as Nvar and rewritten,
# when the whole unit has been compiled, into the node for where the
# binding turned out to live.
#

# ---- the nodes ----

Nundef, Nnull, Ntrue, Nfalse, Nint, Nnum, Nstr, Nacc,
Nlocal, Nlocalchk, Nsetlocal, Nsetlocalchk, Nenv, Nenvchk, Nsetenv, Nsetenvchk,
Nglobal, Nsetglobal, Nglex, Nsetglex, Ndyn, Nsetdyn, Nconsterr, Nignore, Nvar, Nglobalthis,
Nget, Ngetelem, Ngetopt, Ngetelemopt, Nset, Nsetelem, Nmemop, Nelemop, Nmemlog, Nelemlog,
Nupdvar, Nincl, Nupdmem, Nupdelem,
Nadd, Nsub, Nmul, Ndiv, Nmod, Nexp, Nshl, Nshr, Nushr, Nband, Nbor, Nbxor,
Neq, Nne, Nseq, Nsne, Nlt, Ngt, Nle, Nge, Nin, Ninstof, Nprivin,
Nand, Nor, Nnullish, Nnot, Nneg, Npos, Nbitnot, Ntypeof, Nvoid,
Ndelmem, Ndelelem, Ndelname, Ndeltrue, Ncond, Ncomma,
Ncall, Ncallm, Ncalle, Ncallp, Ncalldyn, Ncallsm, Nsupercall, Neval, Nnew,
Nfunc, Nclass, Narray, Nspread, Nobject, Nprop, Npropc, Npropget, Npropset, Npropspread, Nproto,
Ntemplate, Ntmplobj, Nregex, Nyield, Nyieldstar, Nawait, Nchain,
Nprivget, Nprivset, Nprivop, Nprivupd, Nprivlog, Nsuperget, Nsuperset,
Nimportmeta, Nimportcall, Npat, Ppatarr, Ppatobj, Pprop, Prest, Prestobj, Pdefault, Phole,
Nblock, Nseqs, Ncompl, Nif, Nwhile, Ndo, Nfor, Nforin, Nforof, Nreturn, Nbreak, Ncontinue,
Nthrow, Ntry, Nswitch, Ncase, Nlabeled, Nwith, Nempty,
Nmkenv, Nframe2env, Nmkargs, Nmkrest, Nholes, Ndeclvar, Ndeclfn, Nglobalinst, Ndyndeclvar,
Ndyndeclfn, Nsetfnname, Nnewtarget, Nusing, Nbigint, Nnewpriv, Noptchk, Nimportget, Nusingscope, Ncvreset, Nkeepcv, Nchaincall, Nlast: con iota;

op, na, nb, nc, nd, ne, npos: array of int;
nn := 0;
kids: array of int;
nkids := 0;
knum: array of real;
nknum := 0;
kstr: array of string;
nkstr := 0;
infos: array of ref Info;
ninfo := 0;
codes: array of ref Code;
ncode := 0;
scis: array of ref Sci;
nsci := 0;

# inline caches, by node
icsh: array of ref Shape;
icslot: array of int;
icobj: array of ref Obj;
icep: array of int;

# call flags
Fspr, Fopt, Fobjopt: con 1 << iota;

# Code flags
Cstrict, Carrow, Cgen, Casync, Cmethod, Cctor, Cderived, Cclassctor, Csimple, Cgetter,
Csetter, Cstatic, Cfield, Cscript, Ceval, Cmodule, Cdyn, Cnoproto, Canonfield: con 1 << iota;

Code: adt {
	name:	string;
	length:	int;		# the length property
	npos:	int;		# arguments that have frame slots: 1..npos
	nframe:	int;
	body:	int;
	prologue:	int;
	flags:	int;
	fun:	ref Fn;		# shared by the closures made from it
	src:	ref Srcref;
	spos, send:	int;
	fields:	int;	# a class constructor's: the Info of its fields, or -1
	evalsc:	ref Scope;	# eval code: the scope it was compiled in
	thisnode:	int;	# a derived constructor's: reading this at its end
	paramenv:	array of int;	# by argument: the env slot of a captured simple parameter, or -1
	dupparams:	array of int;	# by argument: 1 if a later parameter has its name (not mapped)
};

Srcref: adt {
	s:	string;
	url:	string;	# where it came from: a script's name, a module's URL (import() resolves against it)
};

Fn: adt {
	code:	ref Code;
	native:	int;
	nargs:	int;
};

Env: adt {
	v:	array of V;
	up:	ref Env;
	sci:	ref Sci;
	obj:	ref Obj;	# a with's object, or the variables eval added
	with:	int;
	gcm:	int;	# marked in this collection (jsigc.b)
};

# what dynamic lookups need of a scope at run time
Sci: adt {
	names:	array of int;	# atoms, by env slot
	kinds:	array of int;
	evalvars:	int;	# sloppy eval may add variables here (an object in Env.obj)
	isfunc:	int;	# a variable scope: 2 for the parameters of a function with expressions in them
};

Info: adt {
	pick {
	Loop =>
		labels:	list of int;
		nper:	int;	# a for loop's per-iteration environment: copied each time round
		await:	int;
		decl:	int;	# for-in/of: the binding is declared (a fresh env per iteration if nper)
		sci:	ref Sci;
		kind:	int;	# for-in/of declaration kind (let, const, var)
	Scope =>
		nenv:	int;
		sci:	ref Sci;
	Class =>
		c:	ref Node.Class;
		ctor:	int;		# code index
		sup:	int;		# node, or -1
		nenv:	int;
		sci:	ref Sci;
		entry:	int;		# node making the private names, or -1
		members:	array of ref Member;
		nameset:	int;	# node storing the class into its inner binding, or -1
		fields:	array of ref Member;	# instance fields and private methods
		statics:	array of ref Member;	# static fields and blocks, in order
		name:	string;
	Eval =>
		sc:	ref Scope;
		strict:	int;
		ctx:	int;
		paramargs:	int;	# in parameters, where a var arguments would clash
	Tmpl =>
		cooked:	array of string;	# nil entries: undefined
		raws:	array of string;
		obj:	ref Obj;
	Ginst =>
		vars:	list of string;
		fns:	list of (string, int);	# name, node making it
		lexs:	list of (string, int, int);	# name, glex slot, const
	Re =>
		pat:	ref Jsre->Pattern;
	Super =>
		home:	int;	# node reading the method's home object
		this:	int;	# node reading this
		fun:	int;	# a super call's: the constructor
		nt:	int;	# new.target
		thisset:	int;	# a super call's: initialising this from the pattern stack
	}
};

Member: adt {
	kind:	int;	# Jsparse->Pmethod...
	static:	int;
	key:	int;	# atom, or -1: computed (keynode), or private (priv)
	keynode:	int;
	priv:	int;	# node reading the private name, or -1
	val:	int;	# node: the function, or a field's initialiser code index
	isfield:	int;
};

# ---- compiling ----

Bvar, Blet, Bconst, Bclass, Bfunc, Bparam, Bcatch, Bthis, Bnt, Bhome, Bargs, Bfname, Bpriv, Bimport, Bcinner: con iota;

Bind: adt {
	name:	string;
	kind:	int;
	captured:	int;
	slot:	int;
	sc:	ref Scope;
	declend:	int;
	id:	int;
	used:	int;
	argpos:	int;	# a simple parameter's argument slot, or -1
};

Sglobal, Sfunc, Sblock, Scatch, Sfor, Sclass, Swith, Seval, Smodule, Sswitch: con iota;

Scope: adt {
	kind:	int;
	binds:	list of ref Bind;
	up:	ref Scope;
	fs:	ref Fs;
	id:	int;
	needenv:	int;
	nenv:	int;
	dyn:	int;
	evalvars:	int;
	closed:	int;
	sci:	ref Sci;
	modid:	int;	# a module's top scope: its module's id + 1
	cplxparams:	int;	# a function's scope, its parameters having expressions
};

Fs: adt {
	code:	ref Code;
	up:	ref Fs;
	sc:	ref Scope;
	nframe:	int;
	strict:	int;
	arrow:	int;
	labels:	list of (string, int);
	pending:	list of int;	# labels for the next loop
	gen, async:	int;
	this, nt, home, args, fname, ctor:	ref Bind;
	method:	int;
	inparams:	int;	# compiling the parameters' initialisation
};

Ment: adt {
	name:	string;
	binds:	list of ref Bind;
};

cu: ref Unit;

Unit: adt {
	src:	ref Srcref;
	binds:	array of ref Bind;
	nbind:	int;
	scopes:	array of ref Scope;
	nscope:	int;
	names:	array of list of ref Ment;
	start:	int;		# first node of the unit
	fs:	ref Fs;
	sc:	ref Scope;
	ismod:	int;
	script:	int;		# top-level script: its lexical names are global
	lexnames:	list of (string, int);	# this script's own top-level lexical names, slot
	evalctx:	int;
	errpos:	int;
	err:	string;
};

nlabel := 0;
cururl: string;	# the unit being compiled comes from here

compinit()
{
	op = array[1024] of int;
	na = array[1024] of int;
	nb = array[1024] of int;
	nc = array[1024] of int;
	nd = array[1024] of int;
	ne = array[1024] of int;
	npos = array[1024] of int;
	icsh = array[1024] of ref Shape;
	icslot = array[1024] of int;
	icobj = array[1024] of ref Obj;
	icep = array[1024] of int;
	nn = 0;
	kids = array[1024] of int;
	nkids = 0;
	knum = array[64] of real;
	nknum = 0;
	kstr = array[256] of string;
	nkstr = 0;
	infos = array[64] of ref Info;
	ninfo = 0;
	codes = array[64] of ref Code;
	ncode = 0;
	scis = array[16] of ref Sci;
	nsci = 0;
	nlabel = 0;
	# node 0 is undefined, for operands that are absent
	emit(Nundef, 0, 0, 0, 0, 0);
}

growint(a: array of int, n: int): array of int
{
	b := array[n] of int;
	b[0:] = a;
	return b;
}

emit(o, a, b, c, d, e: int): int
{
	if(nn == len op) {
		m := 2 * nn;
		op = growint(op, m);
		na = growint(na, m);
		nb = growint(nb, m);
		nc = growint(nc, m);
		nd = growint(nd, m);
		ne = growint(ne, m);
		npos = growint(npos, m);
		icslot = growint(icslot, m);
		icep = growint(icep, m);
		s := array[m] of ref Shape;
		s[0:] = icsh;
		icsh = s;
		ob := array[m] of ref Obj;
		ob[0:] = icobj;
		icobj = ob;
	}
	op[nn] = o;
	na[nn] = a;
	nb[nn] = b;
	nc[nn] = c;
	nd[nn] = d;
	ne[nn] = e;
	npos[nn] = curpos;
	icslot[nn] = -1;
	icsh[nn] = nil;
	icobj[nn] = nil;
	icep[nn] = 0;
	return nn++;
}

curpos := 0;

e0(o: int): int
{
	return emit(o, 0, 0, 0, 0, 0);
}

e1(o, a: int): int
{
	return emit(o, a, 0, 0, 0, 0);
}

e2(o, a, b: int): int
{
	return emit(o, a, b, 0, 0, 0);
}

e3(o, a, b, c: int): int
{
	return emit(o, a, b, c, 0, 0);
}

e4(o, a, b, c, d: int): int
{
	return emit(o, a, b, c, d, 0);
}

# a list of nodes as a run in kids: its start
addkids(l: list of int, n: int): int
{
	while(nkids + n > len kids)
		kids = growint(kids, 2 * len kids);
	s := nkids;
	# l is in reverse
	for(i := n - 1; i >= 0; i--) {
		kids[s + i] = hd l;
		l = tl l;
	}
	nkids += n;
	return s;
}

addkidsa(a: array of int): int
{
	while(nkids + len a > len kids)
		kids = growint(kids, 2 * len kids);
	s := nkids;
	kids[s:] = a;
	nkids += len a;
	return s;
}

addnum(x: real): int
{
	if(nknum == len knum) {
		a := array[2 * nknum] of real;
		a[0:] = knum;
		knum = a;
	}
	knum[nknum] = x;
	return nknum++;
}

addstr(s: string): int
{
	if(nkstr == len kstr) {
		a := array[2 * nkstr] of string;
		a[0:] = kstr;
		kstr = a;
	}
	kstr[nkstr] = s;
	return nkstr++;
}

addinfo(i: ref Info): int
{
	if(ninfo == len infos) {
		a := array[2 * ninfo] of ref Info;
		a[0:] = infos;
		infos = a;
	}
	infos[ninfo] = i;
	return ninfo++;
}

addcode(c: ref Code): int
{
	if(ncode == len codes) {
		a := array[2 * ncode] of ref Code;
		a[0:] = codes;
		codes = a;
	}
	codes[ncode] = c;
	c.fun = ref Fn(c, 0, 0);
	return ncode++;
}

addsci(s: ref Sci): int
{
	if(nsci == len scis) {
		a := array[2 * nsci] of ref Sci;
		a[0:] = scis;
		scis = a;
	}
	scis[nsci] = s;
	return nsci++;
}

numnode(x: real): int
{
	if(x >= -1073741824.0 && x <= 1073741823.0 && !isnan(x)) {
		i := int x;
		if(real i == x && (i != 0 || !negzero(x)))
			return e1(Nint, i);
	}
	return e1(Nnum, addnum(x));
}

strnode(s: string): int
{
	return e1(Nstr, addstr(s));
}

# ---- errors found while compiling (early errors the parser leaves) ----

cerror(pos: int, msg: string)
{
	cu.errpos = pos;
	cu.err = msg;
	raise "JScompile";
}

# ---- names ----

newunit(src: string): ref Unit
{
	u := ref Unit;
	u.src = ref Srcref(src, cururl);
	u.binds = array[64] of ref Bind;
	u.scopes = array[16] of ref Scope;
	u.names = array[256] of list of ref Ment;
	u.start = nn;
	return u;
}

ment(name: string, make: int): ref Ment
{
	h := strhash(name) & (len cu.names - 1);
	for(l := cu.names[h]; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	if(!make)
		return nil;
	m := ref Ment(name, nil);
	cu.names[h] = m :: cu.names[h];
	return m;
}

openscope(kind: int): ref Scope
{
	s := ref Scope;
	s.kind = kind;
	s.up = cu.sc;
	s.fs = cu.fs;
	s.id = cu.nscope;
	if(cu.nscope == len cu.scopes) {
		a := array[2 * cu.nscope] of ref Scope;
		a[0:] = cu.scopes;
		cu.scopes = a;
	}
	cu.scopes[cu.nscope++] = s;
	cu.sc = s;
	return s;
}

# leave the scope: its names go out of sight, and its bindings get their places
closescope(s: ref Scope)
{
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		m := ment(b.name, 0);
		if(m != nil && m.binds != nil && hd m.binds == b)
			m.binds = tl m.binds;
	}
	placebinds(s);
	s.closed = 1;
	cu.sc = s.up;
}

# where each binding lives: the frame, or the scope's Env
placebinds(s: ref Scope)
{
	if(s.kind == Sglobal)
		return;
	n := 0;
	binds := revbinds(s.binds);
	for(l := binds; l != nil; l = tl l) {
		b := hd l;
		if(b.kind == Bimport)
			continue;
		if(b.captured || s.dyn) {
			b.captured = 1;
			b.slot = n++;
		}
	}
	if(n > 0 || s.evalvars || s.dyn && (s.kind == Sfunc || s.kind == Seval)) {
		s.needenv = 1;
		s.nenv = n;
		names := array[n] of int;
		kinds := array[n] of int;
		for(l = binds; l != nil; l = tl l) {
			b := hd l;
			if(b.captured && b.kind != Bimport) {
				nm := b.name;
				names[b.slot] = intern(nm);
				kinds[b.slot] = b.kind;
			}
		}
		# a variable scope: a function's, or strict eval code's (sloppy eval's vars are its caller's)
		isfunc := s.kind == Sfunc || s.kind == Seval && s.fs.strict;
		if(isfunc && s.cplxparams)
			isfunc = 2;
		s.sci = ref Sci(names, kinds, s.evalvars, isfunc);
	}
	for(l = binds; l != nil; l = tl l) {
		b := hd l;
		if(b.captured || b.kind == Bimport)
			continue;
		if(b.kind == Bthis) {
			b.slot = 0;
			continue;
		}
		if(b.argpos >= 0) {
			b.slot = b.argpos;
			continue;
		}
		b.slot = s.fs.nframe++;
	}
}

revbinds(l: list of ref Bind): list of ref Bind
{
	r: list of ref Bind;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# declare name in scope s
declare(s: ref Scope, name: string, kind: int, pos: int): ref Bind
{
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.name == name) {
			# var and function may be declared again; the first stays
			if(kind == Bfunc && (b.kind == Bvar || b.kind == Bfunc || b.kind == Bargs))
				b.kind = Bfunc;
			else if(b.kind == Bargs && (kind == Bvar))
				;
			else if(b.kind == Bargs || b.kind == Bfname)
				b.kind = kind;
			return b;
		}
	}
	b := ref Bind(name, kind, 0, -1, s, pos, cu.nbind, 0, -1);
	if(cu.nbind == len cu.binds) {
		a := array[2 * cu.nbind] of ref Bind;
		a[0:] = cu.binds;
		cu.binds = a;
	}
	cu.binds[cu.nbind++] = b;
	s.binds = b :: s.binds;
	m := ment(name, 1);
	m.binds = b :: m.binds;
	return b;
}

# the binding name refers to here, or nil (a global)
lookup(name: string): ref Bind
{
	m := ment(name, 0);
	if(m == nil || m.binds == nil)
		return nil;
	b := hd m.binds;
	b.used = 1;
	if(b.sc.fs != cu.fs)
		b.captured = 1;
	return b;
}

# Nvar modes
Mget, Mtypeof, Mset, Minit, Mcall, Mraw: con iota;

# a reference to name: Nvar(bind, scope, mode, value), fixed up later
varref(name: string, mode, val: int): int
{
	b := lookup(name);
	bid := -1;
	if(b != nil)
		bid = b.id;
	return emit(Nvar, bid, cu.sc.id, mode, val, addstr(name));
}

# ---- the unit's fix-up ----

fixup()
{
	for(i := cu.start; i < nn; i++)
		if(op[i] == Nvar)
			fixvar(i);
	# x++ on a local without a TDZ: in place
	for(i = cu.start; i < nn; i++)
		if(op[i] == Nupdvar) {
			r := na[i];
			w := nb[i];
			if(op[r] == Nlocal && op[w] == Nsetlocal && na[r] == na[w])
				setop(i, Nincl, na[r], nc[i], nd[i], 0, 0);
		}
}

fixvar(i: int)
{
	bid := na[i];
	from := cu.scopes[nb[i]];
	mode := nc[i];
	val := nd[i];
	name := kstr[ne[i]];
	if(bid < 0) {
		fixglobal(i, from, mode, val, name);
		return;
	}
	b := cu.binds[bid];
	# a with, or variables a sloppy eval may add, between here and the binding: look it up
	# by name (this and the other specials cannot be shadowed so)
	special := name == "this" || name[0] == '%';
	for(s := from; !special && s != nil && s != b.sc; s = s.up)
		if(s.kind == Swith || s.evalvars) {
			setdyn(i, mode, val, name);
			return;
		}
	if(b.kind == Bimport) {
		case mode {
		Mset =>
			setop(i, Nconsterr, val, addstr(name), 0, 0, 0);
		Minit =>
			setop(i, Nignore, val, 0, 0, 0, 0);
		* =>
			setop(i, Nimportget, b.argpos, b.sc.modid - 1, addstr(name), 0, 0);
		}
		return;
	}
	chk := needtdz(b, from, npos[i]);
	if(b.kind == Bfname) {
		case mode {
		Mset =>
			if(from.fs.strict)
				setop(i, Nconsterr, val, addstr(name), 0, 0, 0);
			else
				setop(i, Nignore, val, 0, 0, 0, 0);
			return;
		}
	}
	if(mode == Mset && (b.kind == Bconst || b.kind == Bcinner || b.kind == Bimport)) {
		# a TDZ error comes before the const one
		if(chk) {
			if(b.captured)
				setop(i, Nenvchk, envdepth(from, b.sc), b.slot, addstr(name), 0, 0);
			else
				setop(i, Nlocalchk, b.slot, addstr(name), 0, 0, 0);
			# then the error: Nconsterr evaluating the value first is close enough
			x := emit(op[i], na[i], nb[i], nc[i], nd[i], ne[i]);
			setop(i, Ncomma, addkidsa(array[] of {x, emit(Nconsterr, val, addstr(name), 0, 0, 0)}), 2, 0, 0, 0);
			return;
		}
		setop(i, Nconsterr, val, addstr(name), 0, 0, 0);
		return;
	}
	if(mode == Minit || mode == Mraw)
		chk = 0;
	if(b.captured) {
		d := envdepth(from, b.sc);
		case mode {
		Mget or Mtypeof or Mcall or Mraw =>
			if(chk)
				setop(i, Nenvchk, d, b.slot, addstr(name), 0, 0);
			else
				setop(i, Nenv, d, b.slot, 0, 0, 0);
		* =>
			if(chk)
				setop(i, Nsetenvchk, d, b.slot, val, addstr(name), 0);
			else
				setop(i, Nsetenv, d, b.slot, val, 0, 0);
		}
		return;
	}
	case mode {
	Mget or Mtypeof or Mcall or Mraw =>
		if(chk)
			setop(i, Nlocalchk, b.slot, addstr(name), 0, 0, 0);
		else
			setop(i, Nlocal, b.slot, 0, 0, 0, 0);
	* =>
		if(chk)
			setop(i, Nsetlocalchk, b.slot, val, addstr(name), 0, 0);
		else
			setop(i, Nsetlocal, b.slot, val, 0, 0, 0);
	}
}

setop(i, o, a, b, c, d, e: int)
{
	op[i] = o;
	na[i] = a;
	nb[i] = b;
	nc[i] = c;
	nd[i] = d;
	ne[i] = e;
}

# whether a read at pos might see the binding before it is initialised
needtdz(b: ref Bind, from: ref Scope, pos: int): int
{
	case b.kind {
	Blet or Bconst or Bclass or Bcinner =>
		;
	Bparam =>
		# only a complex parameter list's names have a declend
		return pos < b.declend;
	Bthis =>
		return (b.sc.fs.code.flags & Cderived) != 0;
	* =>
		return 0;
	}
	if(from.fs != b.sc.fs)
		return 1;
	if(pos < b.declend)
		return 1;
	for(s := from; s != nil && s != b.sc.up; s = s.up)
		if(s.kind == Sswitch)
			return 1;
	return 0;
}

# how many envs are made between from and the scope of the binding
envdepth(from, dst: ref Scope): int
{
	d := 0;
	for(s := from; s != nil && s != dst; s = s.up)
		if(s.needenv || s.kind == Swith)	# a with's object has an Env of its own
			d++;
	return d;
}

setdyn(i, mode, val: int, name: string)
{
	a := intern(name);
	case mode {
	Mget or Mcall or Mraw =>
		setop(i, Ndyn, a, 0, 0, 0, 0);
	Mtypeof =>
		setop(i, Ndyn, a, 1, 0, 0, 0);
	Minit =>
		setop(i, Nsetdyn, a, val, 2, 0, 0);
	* =>
		strict := 0;
		if(cu.scopes[nb[i]].fs.strict)
			strict = 1;
		setop(i, Nsetdyn, a, val, strict, 0, 0);
	}
}

fixglobal(i: int, from: ref Scope, mode, val: int, name: string)
{
	strict := from.fs.strict;
	# this and the other specials are never a with object's or an eval's var: only
	# direct eval code needs to find them in the function around it
	special := name == "this" || name[0] == '%';
	for(s := from; s != nil; s = s.up)
		if(s.kind == Seval && s.dyn || !special && (s.kind == Swith || s.evalvars)) {
			setdyn(i, mode, val, name);
			return;
		}
	if(name == "this") {
		if(cu.ismod)
			setop(i, Nundef, 0, 0, 0, 0, 0);
		else
			setop(i, Nglobalthis, 0, 0, 0, 0, 0);
		return;
	}
	if(name == "%nt" || name == "%home" || name == "%ctor") {
		setop(i, Nundef, 0, 0, 0, 0, 0);
		return;
	}
	# a top-level let, const or class
	slot := -1;
	isconst := 0;
	for(l := cu.lexnames; l != nil; l = tl l) {
		(n, s) := hd l;
		if(n == name) {
			slot = s;
			break;
		}
	}
	if(slot < 0) {
		(slot, isconst) = glexfind(name);
	} else
		isconst = glexconst[slot];
	if(slot >= 0) {
		case mode {
		Mget or Mtypeof or Mcall or Mraw =>
			setop(i, Nglex, slot, addstr(name), 0, 0, 0);
		Minit =>
			setop(i, Nsetglex, slot, val, 0, 0, 0);
		* =>
			f := 1;
			if(isconst)
				f |= 2;
			setop(i, Nsetglex, slot, val, f, 0, 0);
		}
		return;
	}
	a := intern(name);
	case mode {
	Mget or Mcall or Mraw =>
		setop(i, Nglobal, a, 0, 0, 0, 0);
	Mtypeof =>
		setop(i, Nglobal, a, 1, 0, 0, 0);
	Minit =>
		setop(i, Nsetglobal, a, val, 2, 0, 0);
	* =>
		setop(i, Nsetglobal, a, val, strict, 0, 0);
	}
}

# ---- the global lexical names, kept across scripts ----

glexnames: array of int;	# atom by slot
glexv: array of V;
glexconst: array of int;
glexstate: array of int;	# 0 reserved, 1 declared
nglex := 0;
glexepoch := 0;

glexinit()
{
	glexnames = array[64] of int;
	glexv = array[64] of V;
	glexconst = array[64] of int;
	glexstate = array[64] of int;
	nglex = 0;
}

glexfind(name: string): (int, int)
{
	a := intern(name);
	for(i := 0; i < nglex; i++)
		if(glexnames[i] == a && glexstate[i])
			return (i, glexconst[i]);
	return (-1, 0);
}

glexslot(name: string, isconst: int): int
{
	a := intern(name);
	if(nglex == len glexnames) {
		m := 2 * nglex;
		glexnames = growint(glexnames, m);
		glexconst = growint(glexconst, m);
		glexstate = growint(glexstate, m);
		v := array[m] of V;
		v[0:] = glexv;
		glexv = v;
	}
	glexnames[nglex] = a;
	glexconst[nglex] = isconst;
	glexstate[nglex] = 0;
	glexv[nglex] = holev;
	return nglex++;
}

# ---- statements ----

# var-scoped names declared in body (not inside functions), with function declarations at top level
hoistvars(body: array of ref Node, s: ref Scope, top: int)
{
	for(i := 0; i < len body; i++)
		hoistvar(body[i], s, top);
}

hoistvar(n: ref Node, s: ref Scope, top: int)
{
	if(n == nil)
		return;
	pick x := n {
	Var =>
		if(x.kind == Kvar)
			for(i := 0; i < len x.decls; i++)
				pick d := x.decls[i] {
				Decl =>
					patnames(d.id, s, Bvar);
				}
	Func =>
		if(top && x.id != nil)
			;	# declared with the lexical ones (lexdecls)
		else if(!top && x.id != nil && !cu.fs.strict && (x.flags & (Jsparse->Fgen|Jsparse->Fasync)) == 0) {
			# Annex B.3.3: a block's function is also a var of the function
			nm := idname(x.id);
			if(!conflictsannexb(s, nm))
				declare(s, nm, Bvar, x.pos);
		}
	Block =>
		hoistvars(x.body, s, 0);
	If =>
		hoistvar(x.cons, s, 0);
		hoistvar(x.els, s, 0);
	For =>
		hoistvar(x.init, s, 0);
		hoistvar(x.body, s, 0);
	ForIn =>
		hoistvar(x.left, s, 0);
		hoistvar(x.body, s, 0);
	ForOf =>
		hoistvar(x.left, s, 0);
		hoistvar(x.body, s, 0);
	While =>
		hoistvar(x.body, s, 0);
	DoWhile =>
		hoistvar(x.body, s, 0);
	Labeled =>
		hoistvar(x.body, s, top);
	Try =>
		hoistvar(x.block, s, 0);
		hoistvar(x.handler, s, 0);
		hoistvar(x.final, s, 0);
	Switch =>
		for(i := 0; i < len x.cases; i++)
			pick c := x.cases[i] {
			Case =>
				hoistvars(c.body, s, 0);
			}
	With =>
		hoistvar(x.body, s, 0);
	Export =>
		hoistvar(x.decl, s, top);
	}
}

# Annex B: a block function does not become a var where a let or parameter of the name is
conflictsannexb(s: ref Scope, name: string): int
{
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.name == name && (b.kind == Blet || b.kind == Bconst || b.kind == Bclass))
			return 1;
	}
	return 0;
}

idname(n: ref Node): string
{
	pick x := n {
	Ident =>
		return x.name;
	}
	return nil;
}

# the names a binding pattern declares
patnames(n: ref Node, s: ref Scope, kind: int)
{
	if(n == nil)
		return;
	pick x := n {
	Ident =>
		declare(s, x.name, kind, x.end);
	ArrayPat =>
		for(i := 0; i < len x.elems; i++)
			patnames(x.elems[i], s, kind);
	ObjectPat =>
		for(i := 0; i < len x.props; i++)
			pick p := x.props[i] {
			Prop =>
				patnames(p.value, s, kind);
			Rest =>
				patnames(p.arg, s, kind);
			}
	AssignPat =>
		patnames(x.target, s, kind);
	Rest =>
		patnames(x.arg, s, kind);
	}
}

# the lexical declarations directly in a statement list
lexdecls(body: array of ref Node, s: ref Scope, funcsarevar: int)
{
	for(i := 0; i < len body; i++)
		lexdecl(body[i], s, funcsarevar);
}

lexdecl(n: ref Node, s: ref Scope, funcsarevar: int)
{
	pick x := n {
	Var =>
		if(x.kind != Kvar) {
			k := Blet;
			if(x.kind == Kconst || x.kind == Kusing || x.kind == Kawaitusing)
				k = Bconst;
			for(j := 0; j < len x.decls; j++)
				pick d := x.decls[j] {
				Decl =>
					patnames(d.id, s, k);
					# the declaration's end is where reads stop needing a check
					setdeclend(d.id, s, x.end);
				}
		}
	Class =>
		if(x.decl && x.id != nil) {
			b := declare(s, idname(x.id), Bclass, x.end);
			b.declend = x.end;
		}
	Func =>
		if(x.id != nil) {
			if(funcsarevar)
				declare(s, idname(x.id), Bfunc, x.pos);
			else
				declare(s, idname(x.id), Blet, x.pos).kind = Bfunc;
		}
	Labeled =>
		lexdecl(x.body, s, funcsarevar);
	Export =>
		if(x.decl != nil)
			lexdecl(x.decl, s, funcsarevar);
	}
}

setdeclend(n: ref Node, s: ref Scope, end: int)
{
	pick x := n {
	Ident =>
		for(l := s.binds; l != nil; l = tl l)
			if((hd l).name == x.name)
				(hd l).declend = end;
	* =>
		;
	}
}

# a statement list in a new block scope (if it declares anything lexically)
block(body: array of ref Node, pos: int): int
{
	if(!haslex(body))
		return stmts(body);
	s := openscope(Sblock);
	lexdecls(body, s, 0);
	fnodes := hoistfuncs(body);
	b := usingwrap(body, stmts(body));
	closescope(s);
	return scoped(s, b, fnodes, pos);
}

# the using declarations directly in a statement list: 0 none, 1 using, 2 await using
hasusing(body: array of ref Node): int
{
	u := 0;
	for(i := 0; i < len body; i++)
		pick x := body[i] {
		Var =>
			if(x.kind == Kawaitusing)
				u = 2;
			else if(x.kind == Kusing && u == 0)
				u = 1;
		}
	return u;
}

# a statement list with using declarations disposes of its resources however it ends
usingwrap(body: array of ref Node, b: int): int
{
	u := hasusing(body);
	if(u == 0)
		return b;
	return emit(Nusingscope, b, u == 2, 0, 0, 0);
}

haslex(body: array of ref Node): int
{
	for(i := 0; i < len body; i++)
		pick x := body[i] {
		Var =>
			if(x.kind != Kvar)
				return 1;
		Class =>
			if(x.decl)
				return 1;
		Func =>
			return 1;
		Labeled =>
			if(haslex(array[] of {x.body}))
				return 1;
		}
	return 0;
}

# wrap b in the scope s: make its env, hole its frame lets, run its function declarations
scoped(s: ref Scope, b: int, fnodes: list of int, pos: int): int
{
	entry: list of int;
	ne := 0;
	holes: list of int;
	nh := 0;
	for(l := s.binds; l != nil; l = tl l) {
		bd := hd l;
		if(!bd.captured && (bd.kind == Blet || bd.kind == Bconst || bd.kind == Bclass)) {
			holes = bd.slot :: holes;
			nh++;
		}
	}
	if(nh > 0) {
		entry = e2(Nholes, addkids(holes, nh), nh) :: entry;
		ne++;
	}
	for(; fnodes != nil; fnodes = tl fnodes) {
		entry = hd fnodes :: entry;
		ne++;
	}
	en := -1;
	if(ne > 0)
		en = e2(Nseqs, addkids(entry, ne), ne);
	if(!s.needenv && en < 0)
		return b;
	inf := -1;
	if(s.needenv)
		inf = addinfo(ref Info.Scope(s.nenv, s.sci));
	curpos = pos;
	return emit(Nblock, b, 0, en, s.needenv, inf);
}

# function declarations in a statement list: made when the scope is entered
hoistfuncs(body: array of ref Node): list of int
{
	r: list of int;
	for(i := 0; i < len body; i++) {
		n := body[i];
		pick l := n {
		Labeled =>
			n = l.body;
			while(n != nil) {
				pick l2 := n {
				Labeled =>
					n = l2.body;
					continue;
				}
				break;
			}
		Export =>
			n = l.decl;
		}
		if(n == nil)
			continue;
		pick f := n {
		Func =>
			if(f.id != nil) {
				fnode := funcexpr(f, idname(f.id));
				r = varref(idname(f.id), Minit, fnode) :: r;
			}
		}
	}
	return revints(r);
}

revints(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

stmts(body: array of ref Node): int
{
	l: list of int;
	n := 0;
	for(i := 0; i < len body; i++) {
		s := stmt(body[i]);
		if(s != 0) {
			l = s :: l;
			n++;
		}
	}
	if(n == 1)
		return hd l;
	return e2(Nseqs, addkids(l, n), n);
}

compl := 0;	# script and eval code keep the value of the last expression statement

# in script and eval code, a statement whose completion is never empty starts out undefined
# (UpdateEmpty(..., undefined)); the evaluator keeps the value in cv
stmt(n: ref Node): int
{
	if(compl && nonempty(n)) {
		r := stmt2(n);
		return e2(Nseqs, addkidsa(array[] of {e0(Ncvreset), r}), 2);
	}
	return stmt2(n);
}

nonempty(n: ref Node): int
{
	pick x := n {
	If => return 1;
	While => return 1;
	DoWhile => return 1;
	For => return 1;
	ForIn => return 1;
	ForOf => return 1;
	Switch => return 1;
	With => return 1;
	Try => return 1;
	}
	return 0;
}

stmt2(n: ref Node): int
{
	curpos = n.pos;
	pick x := n {
	Expr =>
		e := expr(x.e);
		if(compl)
			return e1(Ncompl, e);
		return e;
	Var =>
		return vardecl(x);
	Func =>
		# hoisted; Annex B: in a sloppy block, the var gets the function's value here
		if(x.id != nil && !cu.fs.strict && cu.sc.kind != Sfunc && cu.sc.kind != Sglobal && cu.sc.kind != Seval &&
		   (x.flags & (Jsparse->Fgen|Jsparse->Fasync)) == 0) {
			nm := idname(x.id);
			vb := annexbvar(nm);
			if(vb != nil) {
				# read the block's binding, write the var
				r := varref(nm, Mget, 0);
				return annexbset(vb, nm, r);
			}
		}
		return 0;
	Class =>
		v := classexpr(x);
		return varref(idname(x.id), Minit, v);
	Block =>
		return block(x.body, x.pos);
	Empty or Debugger =>
		return 0;
	If =>
		t := expr(x.test);
		c := stmt1(x.cons);
		el := -1;
		if(x.els != nil)
			el = stmt1(x.els);
		return e3(Nif, t, c, el);
	While =>
		inf := loopinfo(0);
		t := expr(x.test);
		b := stmt1(x.body);
		cu.fs.labels = poplabels(cu.fs.labels, inf);
		return e3(Nwhile, t, b, inf);
	DoWhile =>
		inf := loopinfo(0);
		b := stmt1(x.body);
		t := expr(x.test);
		cu.fs.labels = poplabels(cu.fs.labels, inf);
		return e3(Ndo, b, t, inf);
	For =>
		return forstmt(x);
	ForIn =>
		return forinof(x.left, x.right, x.body, 0, 0, x.pos);
	ForOf =>
		if(x.await && cu.fs.sc != nil && cu.fs.sc.kind == Smodule)
			cu.fs.code.flags |= Casync;
		return forinof(x.left, x.right, x.body, 1, x.await, x.pos);
	Return =>
		if(x.arg == nil)
			return e1(Nreturn, -1);
		return e1(Nreturn, expr(x.arg));
	Break =>
		return e1(Nbreak, labelid(x.label));
	Continue =>
		return e1(Ncontinue, labelid(x.label));
	Throw =>
		return e1(Nthrow, expr(x.arg));
	Try =>
		return trystmt(x);
	Switch =>
		return switchstmt(x);
	Labeled =>
		id := ++nlabel;
		cu.fs.labels = (x.label, id) :: cu.fs.labels;
		# a loop takes the labels in front of it
		body := x.body;
		isloop := isloopnode(body);
		if(isloop)
			cu.fs.pending = id :: cu.fs.pending;
		b: int;
		pick f := body {
		Func =>
			b = stmt(body);
		* =>
			b = stmt1(body);
		}
		cu.fs.labels = tl cu.fs.labels;
		if(b == 0)
			b = e0(Nempty);
		return e2(Nlabeled, id, b);
	With =>
		o := expr(x.obj);
		s := openscope(Swith);
		markdyn(s);
		b := stmt1(x.body);
		closescope(s);
		return e2(Nwith, o, b);
	Import =>
		return 0;
	Export =>
		if(x.decl != nil) {
			if(x.default) {
				pick d := x.decl {
				Func =>
					if(d.id == nil)
						return 0;
					return stmt(x.decl);
				Class =>
					if(d.id == nil)
						return varref("*default*", Minit, classexpr1(d, "default"));
					return stmt(x.decl);
				* =>
					v := namedexpr(x.decl, "default");
					return varref("*default*", Minit, v);
				}
			}
			return stmt(x.decl);
		}
		return 0;
	}
	cerror(n.pos, "unsupported statement");
	return 0;
}

# a statement that is the body of something: never 0
stmt1(n: ref Node): int
{
	s := stmt(n);
	if(s == 0)
		return e0(Nempty);
	return s;
}

isloopnode(n: ref Node): int
{
	pick x := n {
	While => return 1;
	DoWhile => return 1;
	For => return 1;
	ForIn => return 1;
	ForOf => return 1;
	Labeled => return 1;
	}
	return 0;
}

ispatnode(n: ref Node): int
{
	pick x := n {
	ArrayPat => return 1;
	ObjectPat => return 1;
	Array => return 1;
	Object => return 1;
	}
	return 0;
}

annexbvar(name: string): ref Bind
{
	fsc := cu.fs.sc;
	for(l := fsc.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.name == name && (b.kind == Bvar || b.kind == Bfunc))
			return b;
	}
	if(fsc.kind == Sglobal || fsc.kind == Seval)
		return ref Bind(name, Bvar, 0, -1, fsc, 0, -1, 0, -1);
	return nil;
}

annexbset(vb: ref Bind, name: string, r: int): int
{
	if(vb.id < 0) {
		# a global var
		if(cu.fs.sc.kind == Seval && !cu.fs.strict)
			return emit(Nsetdyn, intern(name), r, 2, 0, 0);
		return emit(Nsetglobal, intern(name), r, 2, 0, 0);
	}
	vb.used = 1;
	if(vb.sc.fs != cu.fs)
		vb.captured = 1;
	return emit(Nvar, vb.id, cu.sc.id, Minit, r, addstr(name));
}

markdyn(s: ref Scope)
{
	# every binding in sight must be found by name
	for(sc := s; sc != nil; sc = sc.up) {
		sc.dyn = 1;
		for(l := sc.binds; l != nil; l = tl l)
			(hd l).captured = 1;
	}
}

loopinfo(kind: int): int
{
	l := cu.fs.pending;
	cu.fs.pending = nil;
	return addinfo(ref Info.Loop(l, 0, 0, 0, nil, kind));
}

poplabels(l: list of (string, int), nil: int): list of (string, int)
{
	return l;
}

labelid(label: string): int
{
	if(label == nil)
		return 0;
	for(l := cu.fs.labels; l != nil; l = tl l) {
		(n, id) := hd l;
		if(n == label)
			return id;
	}
	cerror(curpos, "undefined label '" + label + "'");
	return 0;
}

vardecl(x: ref Node.Var): int
{
	l: list of int;
	n := 0;
	for(i := 0; i < len x.decls; i++) {
		pick d := x.decls[i] {
		Decl =>
			s := declinit(d, x.kind);
			if(s != 0) {
				l = s :: l;
				n++;
			}
		}
	}
	if(n == 0)
		return 0;
	if(n == 1)
		return hd l;
	return e2(Nseqs, addkids(l, n), n);
}

declinit(d: ref Node.Decl, kind: int): int
{
	curpos = d.pos;
	pick id := d.id {
	Ident =>
		if(d.init == nil) {
			if(kind == Kvar)
				return 0;
			return varref(id.name, Minit, e0(Nundef));
		}
		v := namedexpr(d.init, id.name);
		if(kind == Kusing || kind == Kawaitusing)
			v = emit(Nusing, v, kind == Kawaitusing, 0, 0, 0);
		if(kind == Kvar)
			return varref(id.name, Mset, v);
		return varref(id.name, Minit, v);
	}
	if(d.init == nil)
		return 0;
	mode := Minit;
	if(kind == Kvar)
		mode = Mset;
	return e2(Npat, expr(d.init), pattern(d.id, mode));
}

forstmt(x: ref Node.For): int
{
	inf := loopinfo(0);
	s: ref Scope;
	lexical := 0;
	if(x.init != nil) {
		pick v := x.init {
		Var =>
			if(v.kind != Kvar) {
				s = openscope(Sfor);
				lexdecl(x.init, s, 0);
				lexical = 1;
			}
		}
	}
	init := -1;
	if(x.init != nil) {
		pick v := x.init {
		Var =>
			init = vardecl(v);
			if(init == 0)
				init = -1;
		* =>
			init = expr(x.init);
		}
	}
	test := -1;
	if(x.test != nil)
		test = expr(x.test);
	upd := -1;
	if(x.update != nil)
		upd = expr(x.update);
	body := stmt1(x.body);
	r: int;
	if(lexical) {
		closescope(s);
		pick li := infos[inf] {
		Loop =>
			if(s.needenv) {
				li.nper = s.nenv;
				li.sci = s.sci;
			}
		}
		r = emit(Nfor, init, test, upd, body, inf);
		return scoped(s, r, nil, x.pos);
	}
	return emit(Nfor, init, test, upd, body, inf);
}

forinof(left, right, body: ref Node, isof, await, pos: int): int
{
	inf := loopinfo(0);
	s: ref Scope;
	decl := 0;
	kind := Kvar;
	target: ref Node;
	pick v := left {
	Var =>
		kind = v.kind;
		pick d := v.decls[0] {
		Decl =>
			target = d.id;
			if(d.init != nil && kind == Kvar && !isof) {
				# Annex B: for (var x = init in o)
				;
			}
		}
		decl = 1;
	* =>
		target = left;
	}
	# the object is evaluated with the loop's names in their TDZ
	if(decl && kind != Kvar) {
		s = openscope(Sfor);
		patnames(target, s, Blet);
		if(kind == Kconst || kind == Kusing || kind == Kawaitusing)
			for(l := s.binds; l != nil; l = tl l)
				(hd l).kind = Bconst;
	}
	obj := expr(right);
	if(s != nil) {
		# the names are not in scope for the body's iterations until bound: close and reopen
		closescope(s);
		olds := s;
		s = openscope(Sfor);
		patnames(target, s, Blet);
		if(kind == Kconst || kind == Kusing || kind == Kawaitusing)
			for(l := s.binds; l != nil; l = tl l)
				(hd l).kind = Bconst;
		# the TDZ scope only needs to exist if something captured its names
		if(olds.needenv)
			obj = emit(Nblock, obj, 0, -1, 1, addinfo(ref Info.Scope(olds.nenv, olds.sci)));
	}
	init := -1;
	pick v := left {
	Var =>
		pick d := v.decls[0] {
		Decl =>
			if(d.init != nil && kind == Kvar && !isof)
				init = declinit(d, kind);
		}
	}
	mode := Mset;
	if(decl && kind != Kvar)
		mode = Minit;
	tgt := pattern(target, mode);
	b := stmt1(body);
	if(kind == Kusing || kind == Kawaitusing) {
		# each iteration's value is a resource, disposed of when the iteration ends
		pick t := target {
		Ident =>
			u := emit(Nusing, varref(t.name, Mget, 0), kind == Kawaitusing, 0, 0, 0);
			b = emit(Nusingscope, e2(Nseqs, addkidsa(array[] of {u, b}), 2), kind == Kawaitusing, 0, 0, 0);
		}
	}
	pick li := infos[inf] {
	Loop =>
		li.await = await;
		li.decl = decl;
		li.kind = kind;
	}
	r: int;
	o := Nforin;
	if(isof)
		o = Nforof;
	if(s != nil) {
		closescope(s);
		pick li := infos[inf] {
		Loop =>
			if(s.needenv) {
				li.nper = s.nenv;
				li.sci = s.sci;
			}
		}
		r = emit(o, obj, tgt, b, inf, kind);
	} else
		r = emit(o, obj, tgt, b, inf, kind);
	if(init >= 0)
		r = e2(Nseqs, addkidsa(array[] of {init, r}), 2);
	curpos = pos;
	return r;
}

trystmt(x: ref Node.Try): int
{
	b := stmt1(x.block);
	param := -1;
	h := -1;
	inf := -1;
	if(x.handler != nil) {
		if(x.param != nil) {
			s := openscope(Scatch);
			patnames(x.param, s, Bcatch);
			param = pattern(x.param, Minit);
			pick hb := x.handler {
			Block =>
				# the catch block's own lexical names are in a scope of their own
				h = block(hb.body, hb.pos);
			* =>
				h = stmt1(x.handler);
			}
			closescope(s);
			if(s.needenv)
				inf = addinfo(ref Info.Scope(s.nenv, s.sci));
		} else
			h = stmt1(x.handler);
	}
	f := -1;
	if(compl && h >= 0)
		h = e2(Nseqs, addkidsa(array[] of {e0(Ncvreset), h}), 2);
	if(x.final != nil) {
		f = stmt1(x.final);
		if(compl)
			f = e1(Nkeepcv, f);	# a finally completing normally leaves the value as it was
	}
	return emit(Ntry, b, param, h, f, inf);
}

switchstmt(x: ref Node.Switch): int
{
	d := expr(x.disc);
	id := ++nlabel;
	s := openscope(Sswitch);
	all: list of ref Node;
	for(i := len x.cases - 1; i >= 0; i--)
		pick c := x.cases[i] {
		Case =>
			for(j := len c.body - 1; j >= 0; j--)
				all = c.body[j] :: all;
		}
	body := array[len all] of ref Node;
	for(i = 0; all != nil; all = tl all)
		body[i++] = hd all;
	lexdecls(body, s, 0);
	fnodes := hoistfuncs(body);
	l: list of int;
	n := 0;
	for(i = 0; i < len x.cases; i++)
		pick c := x.cases[i] {
		Case =>
			t := -1;
			if(c.test != nil)
				t = expr(c.test);
			bl: list of int;
			bn := 0;
			for(j := 0; j < len c.body; j++) {
				st := stmt(c.body[j]);
				if(st != 0) {
					bl = st :: bl;
					bn++;
				}
			}
			l = e3(Ncase, t, addkids(bl, bn), bn) :: l;
			n++;
		}
	closescope(s);
	sw := usingwrap(body, emit(Nswitch, d, addkids(l, n), n, 0, 0));
	return scoped(s, sw, fnodes, x.pos);
}

# ---- patterns ----

# a pattern assigning or binding the value at the top of the pattern stack
pattern(n: ref Node, mode: int): int
{
	curpos = n.pos;
	pick x := n {
	Ident =>
		return varref(x.name, mode, e0(Nacc));
	Paren =>
		return pattern(x.e, mode);
	Member =>
		return assigntarget(n);
	ArrayPat =>
		l: list of int;
		k := 0;
		for(i := 0; i < len x.elems; i++) {
			el := x.elems[i];
			p: int;
			if(el == nil)
				p = e0(Phole);
			else {
				pick r := el {
				Rest =>
					p = e1(Prest, pattern(r.arg, mode));
				* =>
					p = pattern(el, mode);
				}
			}
			l = p :: l;
			k++;
		}
		return e2(Ppatarr, addkids(l, k), k);
	Array =>
		return pattern(arraytopat(x), mode);
	ObjectPat =>
		l: list of int;
		k := 0;
		for(i := 0; i < len x.props; i++) {
			pick p := x.props[i] {
			Prop =>
				key := -1;
				kn := -1;
				if(p.computed)
					kn = expr(p.key);
				else
					key = litkeyatom(p.key);
				l = e3(Pprop, key, kn, pattern(p.value, mode)) :: l;
				k++;
			Rest =>
				l = e1(Prestobj, pattern(p.arg, mode)) :: l;
				k++;
			}
		}
		return e2(Ppatobj, addkids(l, k), k);
	Object =>
		return pattern(objtopat(x), mode);
	AssignPat =>
		t := pattern(x.target, mode);
		nm := "";
		pick id := x.target {
		Ident =>
			nm = id.name;
		}
		dv: int;
		if(nm != "")
			dv = namedexpr(x.dflt, nm);
		else
			dv = expr(x.dflt);
		return e2(Pdefault, t, dv);
	Assign =>
		if(x.op == "=")
			return pattern(ref Node.AssignPat(x.pos, x.end, x.target, x.value), mode);
	}
	cerror(n.pos, "invalid destructuring target");
	return 0;
}

# an assignment's target that is an expression (a member): a set node taking its value from the pattern stack
assigntarget(n: ref Node): int
{
	pick x := n {
	Member =>
		strict := cu.fs.strict;
		if(issuper(x.obj)) {
			if(x.computed)
				return e4(Nsuperset, -1, expr(x.prop), e0(Nacc), superinfo());
			return e4(Nsuperset, propatom(x.prop), 0, e0(Nacc), superinfo());
		}
		o := expr(x.obj);
		pick pr := x.prop {
		Private =>
			return e3(Nprivset, o, privref(pr.name), e0(Nacc));
		}
		if(x.computed)
			return e4(Nsetelem, o, expr(x.prop), e0(Nacc), strict);
		return e4(Nset, o, propatom(x.prop), e0(Nacc), strict);
	Paren =>
		return assigntarget(x.e);
	}
	return pattern(n, Mset);
}

arraytopat(x: ref Node.Array): ref Node
{
	el := array[len x.elems] of ref Node;
	for(i := 0; i < len x.elems; i++) {
		e := x.elems[i];
		if(e != nil) {
			pick s := e {
			Spread =>
				e = ref Node.Rest(s.pos, s.end, s.arg);
			}
		}
		el[i] = e;
	}
	return ref Node.ArrayPat(x.pos, x.end, el);
}

objtopat(x: ref Node.Object): ref Node
{
	p := array[len x.props] of ref Node;
	for(i := 0; i < len x.props; i++) {
		e := x.props[i];
		pick s := e {
		Spread =>
			e = ref Node.Rest(s.pos, s.end, s.arg);
		Prop =>
			if(s.shorthand && s.value != nil) {
				pick a := s.value {
				Assign =>
					e = ref Node.Prop(s.pos, s.end, s.key, ref Node.AssignPat(a.pos, a.end, a.target, a.value), s.kind, s.computed, s.shorthand);
				}
			}
		}
		p[i] = e;
	}
	return ref Node.ObjectPat(x.pos, x.end, p);
}

litkeyatom(k: ref Node): int
{
	pick x := k {
	Ident =>
		return intern(x.name);
	Str =>
		return intern(x.s);
	Num =>
		return intern(numstr(x.n));
	BigInt =>
		return intern(bigdecstr(x.digits));
	Private =>
		return intern("#" + x.name);
	}
	cerror(k.pos, "bad property key");
	return 0;
}

propatom(k: ref Node): int
{
	pick x := k {
	Ident =>
		return intern(x.name);
	}
	return litkeyatom(k);
}

issuper(n: ref Node): int
{
	pick x := n {
	Super =>
		return 1;
	}
	return 0;
}

privref(name: string): int
{
	return varref("#" + name, Mget, 0);
}

# ---- expressions ----

expr(n: ref Node): int
{
	curpos = n.pos;
	pick x := n {
	Ident =>
		if(x.name == "undefined") {
			b := lookup("undefined");
			if(b == nil)
				return varref("undefined", Mget, 0);
		}
		return varref(x.name, Mget, 0);
	Num =>
		return numnode(x.n);
	Str =>
		return strnode(x.s);
	Bool =>
		if(x.v)
			return e0(Ntrue);
		return e0(Nfalse);
	Null =>
		return e0(Nnull);
	This =>
		return thisref();
	Paren =>
		return expr(x.e);
	Template =>
		l: list of int;
		k := 0;
		for(i := 0; i < len x.quasis; i++) {
			if(x.quasis[i] != nil) {
				l = strnode(x.quasis[i]) :: l;
				k++;
			}
			if(i < len x.exprs) {
				l = expr(x.exprs[i]) :: l;
				k++;
			}
		}
		return e2(Ntemplate, addkids(l, k), k);
	Tagged =>
		return tagged(x);
	Regex =>
		return e2(Nregex, addstr(x.pattern), addstr(x.flags));
	BigInt =>
		return e1(Nbigint, addstr(bigdecstr(x.digits)));
	Array =>
		l: list of int;
		k := 0;
		flags := 0;
		for(i := 0; i < len x.elems; i++) {
			e := x.elems[i];
			if(e == nil) {
				l = -1 :: l;
				flags |= 2;
			} else {
				pick s := e {
				Spread =>
					l = e1(Nspread, expr(s.arg)) :: l;
					flags |= 1;
				* =>
					l = expr(e) :: l;
				}
			}
			k++;
		}
		return e3(Narray, addkids(l, k), k, flags);
	Object =>
		return objlit(x);
	Func =>
		return funcexpr(x, nil);
	Class =>
		return classexpr(x);
	Unary =>
		return unary(x);
	Update =>
		return update(x);
	Binary =>
		if(x.op == "in") {
			pick p := x.l {
			Private =>
				return e2(Nprivin, privref(p.name), expr(x.r));
			}
		}
		l := expr(x.l);
		return binary(x.op, l, expr(x.r), x);
	Logical =>
		o := Nand;
		case x.op {
		"||" => o = Nor;
		"??" => o = Nnullish;
		}
		return e2(o, expr(x.l), expr(x.r));
	Assign =>
		return assign(x);
	Cond =>
		return e3(Ncond, expr(x.test), expr(x.cons), expr(x.els));
	Seq =>
		l: list of int;
		for(i := 0; i < len x.exprs; i++)
			l = expr(x.exprs[i]) :: l;
		return e2(Ncomma, addkids(l, len x.exprs), len x.exprs);
	Call =>
		return callexpr(x, 0);
	New =>
		(ks, k, fl) := args(x.args);
		return e4(Nnew, expr(x.callee), ks, k, fl);
	Member =>
		return member(x, 0);
	Chain =>
		return e1(Nchain, expr(x.e));
	Yield =>
		a := 0;
		if(x.arg != nil)
			a = expr(x.arg);
		else
			a = e0(Nundef);
		if(x.delegate)
			return e1(Nyieldstar, a);
		return e1(Nyield, a);
	Await =>
		if(cu.fs.sc != nil && cu.fs.sc.kind == Smodule)
			cu.fs.code.flags |= Casync;
		return e1(Nawait, expr(x.arg));
	Meta =>
		if(x.meta == "new")
			return varref("%nt", Mget, 0);
		mid := -1;
		for(s := cu.sc; s != nil; s = s.up)
			if(s.modid > 0)
				mid = s.modid - 1;
		return e1(Nimportmeta, mid);
	ImportCall =>
		o := -1;
		if(x.options != nil)
			o = expr(x.options);
		return e3(Nimportcall, expr(x.source), o, addstr(cu.src.url));
	Super =>
		cerror(x.pos, "'super' keyword unexpected here");
	Spread =>
		cerror(x.pos, "unexpected spread");
	Private =>
		cerror(x.pos, "unexpected private name");
	}
	cerror(n.pos, "unsupported expression");
	return 0;
}

thisref(): int
{
	return varref("this", Mget, 0);
}

# what a super property reference needs: its Info
superinfo(): int
{
	return addinfo(ref Info.Super(varref("%home", Mget, 0), thisref(), -1, -1, -1));
}

# an expression that names an anonymous function or class after name
namedexpr(n: ref Node, name: string): int
{
	pick x := n {
	Func =>
		if(x.id == nil)
			return funcexpr(x, name);
	Class =>
		if(x.id == nil)
			return classexpr1(x, name);
	Paren =>
		# (function(){}) is named too: the parentheses cover it
		return namedexpr(x.e, name);
	}
	return expr(n);
}

isanonfn(n: ref Node): int
{
	pick x := n {
	Func =>
		return x.id == nil;
	Class =>
		return x.id == nil;
	Paren =>
		return isanonfn(x.e);
	}
	return 0;
}

binop(s: string): int
{
	case s {
	"+" => return Nadd;
	"-" => return Nsub;
	"*" => return Nmul;
	"/" => return Ndiv;
	"%" => return Nmod;
	"**" => return Nexp;
	"<<" => return Nshl;
	">>" => return Nshr;
	">>>" => return Nushr;
	"&" => return Nband;
	"|" => return Nbor;
	"^" => return Nbxor;
	"==" => return Neq;
	"!=" => return Nne;
	"===" => return Nseq;
	"!==" => return Nsne;
	"<" => return Nlt;
	">" => return Ngt;
	"<=" => return Nle;
	">=" => return Nge;
	"in" => return Nin;
	"instanceof" => return Ninstof;
	}
	return -1;
}

binary(o: string, l, r: int, nil: ref Node.Binary): int
{
	return e2(binop(o), l, r);
}

unary(x: ref Node.Unary): int
{
	case x.op {
	"!" =>
		return e1(Nnot, expr(x.arg));
	"-" =>
		pick nm := x.arg {
		Num =>
			return numnode(-nm.n);
		}
		return e1(Nneg, expr(x.arg));
	"+" =>
		return e1(Npos, expr(x.arg));
	"~" =>
		return e1(Nbitnot, expr(x.arg));
	"void" =>
		return e1(Nvoid, expr(x.arg));
	"typeof" =>
		a := x.arg;
		while(a != nil) {
			pick p := a {
			Paren =>
				a = p.e;
				continue;
			}
			break;
		}
		pick id := a {
		Ident =>
			return e1(Ntypeof, varref(id.name, Mtypeof, 0));
		}
		return e1(Ntypeof, expr(x.arg));
	"delete" =>
		a := x.arg;
		while(a != nil) {
			pick p := a {
			Paren =>
				a = p.e;
				continue;
			}
			break;
		}
		pick m := a {
		Member =>
			if(issuper(m.obj)) {
				# delete super.x: a ReferenceError, after the key
				k := 0;
				if(m.computed)
					k = expr(m.prop);
				return e2(Ncomma, addkidsa(array[] of {k, e1(Nthrow, e2(Nnew, varref("ReferenceError", Mget, 0), 0))}), 2);
			}
			if(m.optional) {
				# delete a?.b
				o := expr(m.obj);
				return e1(Nchain, e3(Ndelelem, e1(Noptchk, o), keyof(m), cu.fs.strict));
			}
			o := expr(m.obj);
			if(m.computed)
				return e3(Ndelelem, o, expr(m.prop), cu.fs.strict);
			return e3(Ndelmem, o, propatom(m.prop), cu.fs.strict);
		Chain =>
			return e1(Nchain, deletechain(m.e));
		Ident =>
			b := lookup(m.name);
			if(b != nil && !insidedyn(b))
				return e0(Nfalse);
			return e1(Ndelname, intern(m.name));
		}
		return e1(Ndeltrue, expr(x.arg));
	}
	cerror(x.pos, "unknown unary operator " + x.op);
	return 0;
}

insidedyn(b: ref Bind): int
{
	for(s := cu.sc; s != nil && s != b.sc; s = s.up)
		if(s.kind == Swith)
			return 1;
	return 0;
}

keyof(m: ref Node.Member): int
{
	if(m.computed)
		return expr(m.prop);
	return strnode(atomstr[propatom(m.prop)]);
}

# delete in an optional chain: the last member is deleted
deletechain(n: ref Node): int
{
	pick m := n {
	Member =>
		o := expr(m.obj);
		if(m.optional)
			o = e1(Noptchk, o);
		return e3(Ndelelem, o, keyof(m), cu.fs.strict);
	}
	return e1(Ndeltrue, expr(n));
}

update(x: ref Node.Update): int
{
	delta := 1;
	if(x.op == "--")
		delta = -1;
	post := !x.prefix;
	a := x.arg;
	while(a != nil) {
		pick p := a {
		Paren =>
			a = p.e;
			continue;
		}
		break;
	}
	pick t := a {
	Ident =>
		r := varref(t.name, Mget, 0);
		w := varref(t.name, Mset, e0(Nacc));
		return e4(Nupdvar, r, w, delta, post);
	Member =>
		strict := cu.fs.strict;
		if(issuper(t.obj)) {
			k := -1;
			kn := 0;
			if(t.computed)
				kn = expr(t.prop);
			else
				k = propatom(t.prop);
			si := superinfo();
			return e4(Nupdvar, e3(Nsuperget, k, kn, si), e4(Nsuperset, k, kn, e0(Nacc), si), delta, post);
		}
		o := expr(t.obj);
		pick pr := t.prop {
		Private =>
			return e4(Nprivupd, o, privref(pr.name), delta, post);
		}
		if(t.computed)
			return e4(Nupdelem, o, expr(t.prop), delta, post | strict << 1);
		return e4(Nupdmem, o, propatom(t.prop), delta, post | strict << 1);
	}
	cerror(x.pos, "Invalid left-hand side expression in postfix operation");
	return 0;
}

assign(x: ref Node.Assign): int
{
	t := x.target;
	while(t != nil) {
		pick p := t {
		Paren =>
			t = p.e;
			continue;
		}
		break;
	}
	if(x.op == "=" && ispatnode(t)) {
		p := pattern(t, Mset);
		return e2(Npat, expr(x.value), p);
	}
	if(x.op == "=") {
		pick tt := t {
		Ident =>
			# (f) = function(){} does not name the function: (f) is not an identifier reference
			if(t != x.target)
				return varref(tt.name, Mset, expr(x.value));
			return varref(tt.name, Mset, namedexpr(x.value, tt.name));
		Member =>
			strict := cu.fs.strict;
			if(issuper(tt.obj)) {
				if(tt.computed) {
					k := expr(tt.prop);
					return e4(Nsuperset, -1, k, expr(x.value), superinfo());
				}
				return e4(Nsuperset, propatom(tt.prop), 0, expr(x.value), superinfo());
			}
			o := expr(tt.obj);
			pick pr := tt.prop {
			Private =>
				return e3(Nprivset, o, privref(pr.name), expr(x.value));
			}
			if(tt.computed) {
				k := expr(tt.prop);
				return e4(Nsetelem, o, k, expr(x.value), strict);
			}
			return e4(Nset, o, propatom(tt.prop), expr(x.value), strict);
		Call =>
			# f() = x: a ReferenceError at run time (sloppy, web compatibility)
			return e2(Ncomma, addkidsa(array[] of {expr(t), e1(Nthrow, e2(Nnew, varref("ReferenceError", Mget, 0), 0))}), 2);
		}
		cerror(x.pos, "Invalid left-hand side in assignment");
	}
	opname := x.op[0:len x.op - 1];
	logical := -1;
	case opname {
	"&&" => logical = 0;
	"||" => logical = 1;
	"??" => logical = 2;
	}
	pick tt := t {
	Ident =>
		r := varref(tt.name, Mget, 0);
		if(logical >= 0) {
			w := varref(tt.name, Mset, namedexpr(x.value, tt.name));
			lo := Nand;
			if(logical == 1)
				lo = Nor;
			else if(logical == 2)
				lo = Nnullish;
			return e2(lo, r, w);
		}
		return varref(tt.name, Mset, e2(binop(opname), r, expr(x.value)));
	Member =>
		strict := cu.fs.strict;
		if(issuper(tt.obj)) {
			k := -1;
			kn := 0;
			if(tt.computed)
				kn = expr(tt.prop);
			else
				k = propatom(tt.prop);
			si := superinfo();
			g := e3(Nsuperget, k, kn, si);
			if(logical >= 0) {
				lo := Nand;
				if(logical == 1)
					lo = Nor;
				else if(logical == 2)
					lo = Nnullish;
				return e2(lo, g, e4(Nsuperset, k, kn, expr(x.value), si));
			}
			return e4(Nsuperset, k, kn, e2(binop(opname), g, expr(x.value)), si);
		}
		o := expr(tt.obj);
		pick pr := tt.prop {
		Private =>
			if(logical >= 0)
				return e4(Nprivlog, o, privref(pr.name), expr(x.value), logical);
			return e4(Nprivop, o, privref(pr.name), expr(x.value), binop(opname));
		}
		if(tt.computed) {
			k := expr(tt.prop);
			if(logical >= 0)
				return e4(Nelemlog, o, k, expr(x.value), logical << 1 | strict);
			return e4(Nelemop, o, k, expr(x.value), binop(opname) << 1 | strict);
		}
		a := propatom(tt.prop);
		if(logical >= 0)
			return e4(Nmemlog, o, a, expr(x.value), logical << 1 | strict);
		return e4(Nmemop, o, a, expr(x.value), binop(opname) << 1 | strict);
	Call =>
		return e2(Ncomma, addkidsa(array[] of {expr(t), e1(Nthrow, e2(Nnew, varref("ReferenceError", Mget, 0), 0))}), 2);
	}
	cerror(x.pos, "Invalid left-hand side in assignment");
	return 0;
}

member(x: ref Node.Member, nil: int): int
{
	if(issuper(x.obj)) {
		if(x.computed)
			return e3(Nsuperget, -1, expr(x.prop), superinfo());
		return e3(Nsuperget, propatom(x.prop), 0, superinfo());
	}
	o := expr(x.obj);
	pick pr := x.prop {
	Private =>
		if(x.optional)
			o = e1(Noptchk, o);
		return e2(Nprivget, o, privref(pr.name));
	}
	if(x.computed) {
		if(x.optional)
			return e2(Ngetelemopt, o, expr(x.prop));
		return e2(Ngetelem, o, expr(x.prop));
	}
	if(x.optional)
		return e2(Ngetopt, o, propatom(x.prop));
	return e2(Nget, o, propatom(x.prop));
}

# a call's arguments: (kids start, count, flags)
args(a: array of ref Node): (int, int, int)
{
	l: list of int;
	fl := 0;
	for(i := 0; i < len a; i++) {
		pick s := a[i] {
		Spread =>
			l = e1(Nspread, expr(s.arg)) :: l;
			fl |= Fspr;
		* =>
			l = expr(a[i]) :: l;
		}
	}
	return (addkids(l, len a), len a, fl);
}

callexpr(x: ref Node.Call, nil: int): int
{
	c := x.callee;
	while(c != nil) {
		pick p := c {
		Paren =>
			# (a.b)() keeps its this; (0, a.b)() does not
			c = p.e;
			continue;
		Chain =>
			# (a?.b)() keeps its this too, but a short circuit calls undefined
			pick m := p.e {
			Member =>
				r := callexpr(ref Node.Call(x.pos, x.end, p.e, x.args, x.optional), 0);
				return e1(Nchaincall, r);
			}
		}
		break;
	}
	opt := 0;
	if(x.optional)
		opt = Fopt;
	pick s := c {
	Super =>
		(ks, k, fl) := args(x.args);
		inf := ref Info.Super(-1, -1, varref("%ctor", Mget, 0), varref("%nt", Mget, 0), varref("this", Minit, e0(Nacc)));
		inf.this = varref("this", Mraw, 0);
		return e4(Nsupercall, ks, k, fl, addinfo(inf));
	Ident =>
		if(s.name == "eval" && !x.optional) {
			b := lookup("eval");
			if(b == nil || 1) {
				# a direct eval: everything in sight must be found by name
				markdyn(cu.sc);
				fs := cu.fs;
				if(!fs.strict) {
					# it may add variables to the function's (or the script's) var scope
					fs.sc.evalvars = 1;
				}
				for(f := fs; f != nil; f = f.up) {
					forcespecial(f);
					if(!f.arrow)
						break;
				}
				(ks, k, fl) := args(x.args);
				callee := varref("eval", Mcall, 0);
				# in parameters a sloppy eval may not declare var arguments: it would clash with
				# the function's arguments object, or an arrow's parameter of that name
				pa := 0;
				if(fs.inparams) {
					pa = !fs.arrow;
					for(l := fs.sc.binds; l != nil; l = tl l)
						if((hd l).name == "arguments" && (hd l).kind == Bparam)
							pa = 1;
				}
				inf := addinfo(ref Info.Eval(cu.sc, fs.strict, evalctx(fs), pa));
				return emit(Neval, callee, ks, k, fl, inf);
			}
		}
		(ks, k, fl) := args(x.args);
		callee := varref(s.name, Mcall, 0);
		if(inwith())
			return e4(Ncalldyn, intern(s.name), ks, k, fl | opt);
		return e4(Ncall, callee, ks, k, fl | opt);
	Member =>
		if(issuper(s.obj)) {
			key := -1;
			kn := 0;
			if(s.computed)
				kn = expr(s.prop);
			else
				key = propatom(s.prop);
			si := superinfo();
			callee := e3(Nsuperget, key, kn, si);
			(ks, k, fl) := args(x.args);
			return emit(Ncallsm, callee, thisref(), ks, k, fl | opt);
		}
		o := expr(s.obj);
		if(s.optional)
			opt |= Fobjopt;
		pick pr := s.prop {
		Private =>
			p := privref(pr.name);
			(ks, k, fl) := args(x.args);
			return emit(Ncallp, o, p, ks, k, fl | opt);
		}
		if(s.computed) {
			key := expr(s.prop);
			(ks, k, fl) := args(x.args);
			return emit(Ncalle, o, key, ks, k, fl | opt);
		}
		a := propatom(s.prop);
		(ks, k, fl) := args(x.args);
		return emit(Ncallm, o, a, ks, k, fl | opt);
	}
	f := expr(c);
	(ks, k, fl) := args(x.args);
	return e4(Ncall, f, ks, k, fl | opt);
}

inwith(): int
{
	for(s := cu.sc; s != nil; s = s.up)
		if(s.kind == Swith)
			return 1;
	return 0;
}

# a direct eval may use this, new.target, super and arguments: make them bindings it can find
forcespecial(f: ref Fs)
{
	if(f.this != nil)
		f.this.captured = 1;
	if(f.nt != nil) {
		f.nt.used = 1;
		f.nt.captured = 1;
	}
	if(f.home != nil) {
		f.home.used = 1;
		f.home.captured = 1;
	}
	if(f.args != nil && f.args.kind == Bargs) {
		f.args.used = 1;
		f.args.captured = 1;
	}
	if(f.fname != nil) {
		f.fname.used = 1;
		f.fname.captured = 1;
	}
	if(f.ctor != nil) {
		f.ctor.used = 1;
		f.ctor.captured = 1;
	}
}

# what eval code may contain where it is called
evalctx(fs: ref Fs): int
{
	ctx := 0;
	for(f := fs; f != nil; f = f.up) {
		if(f.arrow)
			continue;
		if(f.code != nil && (f.code.flags & (Cscript|Ceval)) == 0) {
			ctx |= Jsparse->Enewtarget;
			if(f.method || (f.code.flags & Cfield))
				ctx |= Jsparse->Esuperprop;
			if(f.code.flags & Cderived)
				ctx |= Jsparse->Esupercall;
			if(f.code.flags & Cfield)
				ctx |= Jsparse->Efield;
		}
		if(f.code != nil && (f.code.flags & Ceval))
			ctx |= cu.evalctx;
		break;
	}
	return ctx;
}

tagged(x: ref Node.Tagged): int
{
	pick q := x.quasi {
	Template =>
		inf := addinfo(ref Info.Tmpl(q.quasis, q.raws, nil));
		l: list of int;
		l = e1(Ntmplobj, inf) :: l;
		for(i := 0; i < len q.exprs; i++)
			l = expr(q.exprs[i]) :: l;
		n := len q.exprs + 1;
		ks := addkids(l, n);
		t := x.tag;
		while(t != nil) {
			pick p := t {
			Paren =>
				t = p.e;
				continue;
			}
			break;
		}
		pick m := t {
		Member =>
			if(!issuper(m.obj)) {
				o := expr(m.obj);
				pick pr := m.prop {
				Private =>
					return emit(Ncallp, o, privref(pr.name), ks, n, 0);
				}
				if(m.computed)
					return emit(Ncalle, o, expr(m.prop), ks, n, 0);
				return emit(Ncallm, o, propatom(m.prop), ks, n, 0);
			}
		}
		return e4(Ncall, expr(x.tag), ks, n, 0);
	}
	cerror(x.pos, "bad tagged template");
	return 0;
}

objlit(x: ref Node.Object): int
{
	l: list of int;
	k := 0;
	for(i := 0; i < len x.props; i++) {
		pick p := x.props[i] {
		Prop =>
			curpos = p.pos;
			case p.kind {
			Jsparse->Pinit =>
				if(!p.computed && !p.shorthand) {
					isproto := 0;
					pick kk := p.key {
					Ident =>
						isproto = kk.name == "__proto__";
					Str =>
						isproto = kk.s == "__proto__";
					}
					if(isproto) {
						l = e1(Nproto, expr(p.value)) :: l;
						k++;
						continue;
					}
				}
				if(p.computed) {
					kn := expr(p.key);
					v: int;
					if(isanonfn(p.value))
						v = namedexpr(p.value, nil);
					else
						v = expr(p.value);
					l = e3(Npropc, kn, v, isanonfn(p.value)) :: l;
				} else {
					a := litkeyatom(p.key);
					v := namedexpr(p.value, atomstr[a]);
					l = e3(Nprop, a, v, 0) :: l;
				}
			Jsparse->Pmethod =>
				fl := 2;
				if(p.computed) {
					kn := expr(p.key);
					l = e3(Npropc, kn, methodexpr1(p.value, nil, p.pos), fl | 1) :: l;
				} else {
					a := litkeyatom(p.key);
					l = e3(Nprop, a, methodexpr1(p.value, atomstr[a], p.pos), fl) :: l;
				}
			Jsparse->Pget or Jsparse->Pset =>
				o := Npropget;
				if(p.kind == Jsparse->Pset)
					o = Npropset;
				if(p.computed) {
					kn := expr(p.key);
					l = e3(o, -1, methodexpr1(p.value, nil, p.pos), kn) :: l;
				} else
					l = e3(o, litkeyatom(p.key), methodexpr1(p.value, nil, p.pos), 0) :: l;
			}
			k++;
		Spread =>
			l = e1(Npropspread, expr(p.arg)) :: l;
			k++;
		}
	}
	return e2(Nobject, addkids(l, k), k);
}

# a method; its source text starts at start (with its get, set, async or *), not its name
methodexpr1(n: ref Node, name: string, start: int): int
{
	pick f := n {
	Func =>
		methodstart = start;
		return funcexpr1(f, name, Cmethod, nil);
	}
	return expr(n);
}

methodstart := -1;

# where a class member's method definition starts: after any static
memberstart(m: ref Node.Method): int
{
	pos := m.pos;
	if(!m.static)
		return pos;
	src := cu.src.s;
	if(pos + 6 > len src || src[pos:pos+6] != "static")
		return pos;
	pos += 6;
	while(pos < len src) {
		c := src[pos];
		if(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 16rA0 || c == 16rFEFF || c == 16r2028 || c == 16r2029 || c >= 16r2000 && c <= 16r200A || c == 16r1680 || c == 16r202F || c == 16r205F || c == 16r3000 || c == 16rB || c == 16rC)
			pos++;
		else if(c == '/' && pos + 1 < len src && src[pos+1] == '*') {
			e := pos + 2;
			while(e + 1 < len src && !(src[e] == '*' && src[e+1] == '/'))
				e++;
			pos = e + 2;
		} else if(c == '/' && pos + 1 < len src && src[pos+1] == '/') {
			while(pos < len src && src[pos] != '\n' && src[pos] != '\r' && src[pos] != 16r2028 && src[pos] != 16r2029)
				pos++;
		} else
			break;
	}
	return pos;
}

# ---- functions ----

funcexpr(f: ref Node.Func, name: string): int
{
	return funcexpr1(f, name, 0, nil);
}

funcexpr1(f: ref Node.Func, name: string, extra: int, cls: ref Info.Class): int
{
	ci := compilefunc(f, name, extra, cls);
	return e1(Nfunc, ci);
}

compilefunc(f: ref Node.Func, name: string, extra: int, nil: ref Info.Class): int
{
	code := ref Code;
	code.flags = extra;
	if(f.flags & Jsparse->Fstrict || cu.fs.strict)
		code.flags |= Cstrict;
	if(f.flags & Jsparse->Farrow)
		code.flags |= Carrow;
	if(f.flags & Jsparse->Fgen)
		code.flags |= Cgen;
	if(f.flags & Jsparse->Fasync)
		code.flags |= Casync;
	if(f.flags & Jsparse->Fmethod)
		code.flags |= Cmethod;
	if(f.flags & Jsparse->Fsimple)
		code.flags |= Csimple;
	if(f.id != nil)
		code.name = idname(f.id);
	else
		code.name = name;
	code.src = cu.src;
	code.spos = f.pos;
	code.send = f.end;
	if(methodstart >= 0) {
		code.spos = methodstart;
		methodstart = -1;
	}
	code.fields = -1;
	ci := addcode(code);
	if(f.flags & Jsparse->Flazy) {
		# the parser kept only where the body is: parse it now
		(body, err) := jsparse->parsebody(cu.src.s, f.bodypos, f.flags, cu.ismod);
		if(err != nil)
			cerror(f.pos, err);
		f = ref Node.Func(f.pos, f.end, f.id, f.params, body, f.flags & ~Jsparse->Flazy, f.bodypos, f.free);
	}
	funcbody(f, code);
	return ci;
}

# a function's scope, parameters and body
funcbody(f: ref Node.Func, code: ref Code)
{
	fs := ref Fs;
	fs.code = code;
	fs.up = cu.fs;
	fs.strict = (code.flags & Cstrict) != 0;
	fs.arrow = (code.flags & Carrow) != 0;
	fs.gen = (code.flags & Cgen) != 0;
	fs.async = (code.flags & Casync) != 0;
	fs.method = (code.flags & (Cmethod|Cctor)) != 0;
	fs.nframe = 1;
	savedfs := cu.fs;
	savedsc := cu.sc;
	savedcompl := compl;
	compl = 0;
	cu.fs = fs;
	s := openscope(Sfunc);
	fs.sc = s;
	if(!fs.arrow) {
		fs.this = declare(s, "this", Bthis, 0);
		fs.nt = declare(s, "%nt", Bnt, 0);
		if(fs.method)
			fs.home = declare(s, "%home", Bhome, 0);
		fs.args = declare(s, "arguments", Bargs, 0);
		if(f.id != nil && (f.flags & Jsparse->Fdecl) == 0)
			fs.fname = declare(s, idname(f.id), Bfname, 0);
		if(code.flags & Cderived)
			fs.ctor = declare(s, "%ctor", Bfname, 0);
	}
	# parameters: simple ones have argument slots of their own
	simple := 1;
	npos := 0;
	for(i := 0; i < len f.params; i++) {
		pick p := f.params[i] {
		Ident =>
			npos++;
		Rest =>
			simple = 0;
		* =>
			simple = 0;
			npos++;
		}
	}
	code.npos = npos;
	fs.nframe = 1 + npos;
	length := 0;
	seendefault := 0;
	for(i = 0; i < len f.params; i++) {
		before := s.binds;
		pick p := f.params[i] {
		Ident =>
			b := declare(s, p.name, Bparam, 0);
			# among complex parameters a simple one is bound in order too (it has a TDZ)
			if(simple && (b.argpos < 0 || b.kind == Bparam))
				b.argpos = 1 + i;
			if(!seendefault)
				length++;
		Rest =>
			patnames(p.arg, s, Bparam);
			seendefault = 1;
		AssignPat =>
			patnames(p.target, s, Bparam);
			seendefault = 1;
		* =>
			patnames(f.params[i], s, Bparam);
			if(!seendefault)
				length++;
		}
		if(!simple) {
			# a parameter's names are in their TDZ until the parameter is bound
			end := f.bodypos;
			if(i + 1 < len f.params)
				end = f.params[i + 1].pos;
			for(l := s.binds; l != before; l = tl l)
				(hd l).declend = end;
		}
	}
	# a duplicate simple parameter: the last one wins (its argpos); the earlier are not mapped
	for(i = 0; simple && i < len f.params; i++)
		pick p := f.params[i] {
		Ident =>
			for(l := s.binds; l != nil; l = tl l)
				if((hd l).name == p.name) {
					if((hd l).argpos != 1 + i && (hd l).argpos > 0) {
						if(code.dupparams == nil)
							code.dupparams = array[len f.params] of {* => 0};
						code.dupparams[(hd l).argpos - 1] = 1;
					}
					(hd l).argpos = 1 + i;
				}
		}
	code.length = length;
	if(simple) {
		# var names, then the body's lexical names (a separate scope in the spec; one here)
		hoistvars(f.body, s, 1);
		if(fs.args != nil && fs.args.kind != Bargs)
			fs.args = nil;	# a parameter or var named arguments shadows it
	}
	if(fs.args != nil) {
		for(l := s.binds; l != nil; l = tl l)
			if((hd l).name == "arguments" && hd l != fs.args)
				fs.args = nil;
	}
	if(simple) {
		lexdecls(f.body, s, 1);
		if(fs.args != nil && fs.args.kind != Bargs)
			fs.args = nil;
	}
	# the parameters' initialisation
	pinit: list of int;
	np := 0;
	if(!simple) {
		fs.inparams = 1;
		for(i = 0; i < len f.params; i++) {
			p := f.params[i];
			pick r := p {
			Rest =>
				pinit = e2(Nmkrest, i, pattern(r.arg, Minit)) :: pinit;
				np++;
			* =>
				# the argument, then the pattern
				src := e1(Nlocal, 1 + i);
				pinit = e2(Npat, src, pattern(p, Minit)) :: pinit;
				np++;
			}
		}
		fs.inparams = 0;
	}
	# with expressions in the parameters, the body's names are in a scope of their own,
	# which a closure in the parameters cannot see (§10.2.11 step 28); a var named as a
	# parameter (or arguments) starts with its value
	bs := s;
	copies: list of int;
	ncopy := 0;
	if(!simple) {
		s.cplxparams = 1;
		bs = openscope(Sfunc);
		fs.sc = bs;
		hoistvars(f.body, bs, 1);
		lexdecls(f.body, bs, 1);
		curpos = f.bodypos;
		for(l := bs.binds; l != nil; l = tl l) {
			b := hd l;
			if(b.kind != Bvar)
				continue;
			for(pl := s.binds; pl != nil; pl = tl pl) {
				pb := hd pl;
				if(pb.name == b.name && (pb.kind == Bparam || pb.kind == Bargs && pb == fs.args)) {
					pb.used = 1;
					rd := emit(Nvar, pb.id, bs.id, Mget, 0, addstr(b.name));
					copies = emit(Nvar, b.id, bs.id, Minit, rd, addstr(b.name)) :: copies;
					ncopy++;
				}
			}
		}
	}
	fnodes := hoistfuncs(f.body);
	body := usingwrap(f.body, stmts(f.body));
	if(bs != s) {
		if(ncopy > 0)
			body = e2(Nseqs, addkids(body :: copies, ncopy + 1), ncopy + 1);
		closescope(bs);
		body = scoped(bs, body, fnodes, f.bodypos);
		fnodes = nil;
		fs.sc = s;
	}
	closescope(s);
	code.nframe = fs.nframe;
	# the prologue: the env, what goes in it, arguments, then the parameters and the functions
	pro: list of int;
	npro := 0;
	if(s.needenv) {
		pro = e2(Nmkenv, s.nenv, addsci(s.sci)) :: pro;
		npro++;
		for(l := s.binds; l != nil; l = tl l) {
			b := hd l;
			if(!b.captured)
				continue;
			if(b.kind == Bthis) {
				pro = e2(Nframe2env, b.slot, 0) :: pro;
				npro++;
			} else if(b.argpos >= 0) {
				pro = e2(Nframe2env, b.slot, b.argpos) :: pro;
				npro++;
				if(code.paramenv == nil)
					code.paramenv = array[npos] of {* => -1};
				code.paramenv[b.argpos-1] = b.slot;
			}
		}
	}
	if(fs.nt != nil && fs.nt.used) {
		pro = specialinit(fs.nt, s, 0) :: pro;
		npro++;
	}
	if(fs.home != nil && fs.home.used) {
		pro = specialinit(fs.home, s, 1) :: pro;
		npro++;
	}
	if(fs.fname != nil && fs.fname.used && fs.fname.kind == Bfname) {
		pro = specialinit(fs.fname, s, 2) :: pro;
		npro++;
	}
	if(fs.ctor != nil && fs.ctor.used) {
		pro = specialinit(fs.ctor, s, 2) :: pro;
		npro++;
	}
	if(code.flags & Cderived)
		code.thisnode = varref1(fs.this, s);
	if(fs.args != nil && fs.args.used) {
		mapped := !fs.strict && simple;
		pro = e2(Nmkargs, mapped, bindwrite(fs.args, s)) :: pro;
		npro++;
	}
	# complex parameters start in their TDZ (captured ones do in their Env)
	if(!simple) {
		ph: list of int;
		nph := 0;
		for(l := s.binds; l != nil; l = tl l) {
			b := hd l;
			if(!b.captured && b.kind == Bparam && b.argpos < 0) {
				ph = b.slot :: ph;
				nph++;
			}
		}
		if(nph > 0) {
			pro = e2(Nholes, addkids(ph, nph), nph) :: pro;
			npro++;
		}
	}
	# simple parameters that were captured were copied; the others are in place
	for(; pinit != nil; pinit = tl pinit) {
		pro = hd pinit :: pro;	# (pinit is reversed; pro is too)
		npro++;
	}
	pro = revints2(pro, npro, np);
	for(; fnodes != nil; fnodes = tl fnodes) {
		pro = hd fnodes :: pro;
		npro++;
	}
	# lexical frame slots start in their TDZ
	holes: list of int;
	nh := 0;
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		if(!b.captured && (b.kind == Blet || b.kind == Bconst || b.kind == Bclass)) {
			holes = b.slot :: holes;
			nh++;
		}
	}
	if(code.flags & Cderived) {
		# this is in its TDZ until super() returns
		if(!fs.this.captured) {
			holes = 0 :: holes;
			nh++;
		}
	}
	if(nh > 0) {
		pro = e2(Nholes, addkids(holes, nh), nh) :: pro;
		npro++;
	}
	code.nframe = fs.nframe;
	if(npro > 0)
		code.prologue = e2(Nseqs, addkids(pro, npro), npro);
	else
		code.prologue = -1;
	code.body = body;
	cu.fs = savedfs;
	cu.sc = savedsc;
	compl = savedcompl;
}

# pro holds, newest first, the env setup and then np parameter inits in reverse: put the inits in order
revints2(l: list of int, n, np: int): list of int
{
	if(np < 2)
		return l;
	a := array[np] of int;
	for(i := 0; i < np; i++) {
		a[i] = hd l;
		l = tl l;
	}
	for(i = 0; i < np; i++)
		l = a[i] :: l;
	return l;
}

# a node reading b without a TDZ check, b's scope being closed
varref1(b: ref Bind, nil: ref Scope): int
{
	if(b.captured)
		return e2(Nenv, 0, b.slot);
	return e1(Nlocal, b.slot);
}

# store the value of a special binding (0 new.target, 1 home, 2 the function) at function entry
specialinit(b: ref Bind, s: ref Scope, which: int): int
{
	v := emit(Nnewtarget, which, 0, 0, 0, 0);
	if(b.captured)
		return e3(Nsetenv, 0, b.slot, v);
	return e2(Nsetlocal, b.slot, v);
}

# a node writing the pattern stack's top into b, which is in scope s (being closed)
bindwrite(b: ref Bind, nil: ref Scope): int
{
	if(b.captured)
		return e3(Nsetenv, 0, b.slot, e0(Nacc));
	return e2(Nsetlocal, b.slot, e0(Nacc));
}

# ---- classes ----

classexpr(c: ref Node.Class): int
{
	name: string;
	if(c.id != nil)
		name = idname(c.id);
	return classexpr1(c, name);
}

classexpr1(c: ref Node.Class, name: string): int
{
	curpos = c.pos;
	savedstrict := cu.fs.strict;
	# a class is strict code; its heritage too
	s := openscope(Sclass);
	fsstrict := cu.fs.strict;
	cu.fs.strict = 1;
	inner: ref Bind;
	if(c.id != nil) {
		inner = declare(s, idname(c.id), Bcinner, c.end);
		inner.declend = c.end;
	}
	# private names
	for(i := 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.key != nil)
			pick pk := m.key {
			Private =>
				declare(s, "#" + pk.name, Bpriv, 0);
			}
		}
	sup := -1;
	if(c.super != nil)
		sup = expr(c.super);
	derived := c.super != nil;
	# the constructor
	ctor: ref Node.Func;
	for(i = 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			if(m.kind == Jsparse->Pctor)
				pick f := m.value {
				Func =>
					ctor = f;
				}
		}
	inf := ref Info.Class(c, -1, sup, 0, nil, -1, nil, -1, nil, nil, name);
	infn := addinfo(inf);
	fl := Cctor | Cclassctor | Cmethod;
	if(derived)
		fl |= Cderived;
	if(ctor != nil) {
		inf.ctor = compilefunc(ctor, name, fl, inf);
		# a class's source text is the class's
		codes[inf.ctor].spos = c.pos;
		codes[inf.ctor].send = c.end;
	}
	else
		inf.ctor = defaultctor(derived, name, c);
	codes[inf.ctor].name = name;
	# members, in order
	mem: list of ref Member;
	nm := 0;
	for(i = 0; i < len c.body; i++)
		pick m := c.body[i] {
		Method =>
			curpos = m.pos;
			if(m.kind == Jsparse->Pctor)
				continue;
			mb := ref Member(m.kind, m.static, -1, -1, -1, -1, 0);
			if(m.key != nil)
			pick pk := m.key {
			Private =>
				mb.priv = privref(pk.name);
			* =>
				if(m.computed)
					mb.keynode = expr(m.key);
				else if(m.key != nil)
					mb.key = litkeyatom(m.key);
			}
			if(m.kind == Jsparse->Pfield || m.kind == Jsparse->Pblock) {
				mb.isfield = 1;
				mb.val = fieldfunc(m, mb);
			} else {
				pick f := m.value {
				Func =>
					# an accessor is named when it is defined ("get id")
					nmx: string;
					if(mb.key >= 0 && m.kind != Jsparse->Pget && m.kind != Jsparse->Pset)
						nmx = atomstr[mb.key];
					methodstart = memberstart(m);
					mb.val = funcexpr1(f, nmx, Cmethod, inf);
				}
			}
			mem = mb :: mem;
			nm++;
		}
	inf.members = array[nm] of ref Member;
	for(i = nm - 1; i >= 0; i--) {
		inf.members[i] = hd mem;
		mem = tl mem;
	}
	cu.fs.strict = fsstrict;
	closescope(s);
	cu.fs.strict = savedstrict;
	if(s.needenv) {
		inf.nenv = s.nenv;
		inf.sci = s.sci;
	}
	# the private names, made each time the class is
	ent: list of int;
	ne := 0;
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		if(b.kind != Bpriv)
			continue;
		mk := e1(Nnewpriv, addstr(b.name));	# a new private name
		if(b.captured)
			ent = e3(Nsetenv, 0, b.slot, mk) :: ent;
		else
			ent = e2(Nsetlocal, b.slot, mk) :: ent;
		ne++;
	}
	# the class's own name is in its TDZ until the class is made (class x extends x)
	if(inner != nil && !inner.captured) {
		ent = e2(Nholes, addkids(inner.slot :: nil, 1), 1) :: ent;
		ne++;
	}
	if(ne > 0)
		inf.entry = e2(Nseqs, addkids(ent, ne), ne);
	if(inner != nil) {
		if(inner.captured)
			inf.nameset = e3(Nsetenv, 0, inner.slot, e0(Nacc));
		else
			inf.nameset = e2(Nsetlocal, inner.slot, e0(Nacc));
	}
	curpos = c.pos;
	return e1(Nclass, infn);
}

# a field's initialiser (or a static block) as a method run on the instance (or class)
fieldfunc(m: ref Node.Method, mb: ref Member): int
{
	ffn := ref Node.Func(m.pos, m.end, nil, array[0] of ref Node, nil, Jsparse->Fmethod | Jsparse->Fstrict, 0, nil);
	if(m.kind == Jsparse->Pblock) {
		pick b := m.value {
		Block =>
			ffn.body = b.body;
		}
	} else {
		ffn.flags |= Jsparse->Fexpr;
		val := m.value;
		if(val == nil)
			ffn.body = array[0] of ref Node;
		else {
			ffn.body = array[1] of ref Node;
			ffn.body[0] = ref Node.Return(m.pos, m.end, val);
		}
	}
	name: string;
	if(mb.key >= 0)
		name = atomstr[mb.key];
	ci := compilefieldfn(ffn, name, m.kind == Jsparse->Pfield);
	return ci;
}

compilefieldfn(f: ref Node.Func, name: string, isfield: int): int
{
	code := ref Code;
	code.flags = Cstrict | Cmethod | Cfield;
	code.name = name;
	code.src = cu.src;
	code.spos = f.pos;
	code.send = f.end;
	code.fields = -1;
	ci := addcode(code);
	# an anonymous function in a field's initialiser is named after the field (definefield)
	if(isfield && len f.body == 1) {
		pick r := f.body[0] {
		Return =>
			if(r.arg != nil && isanonfn(r.arg))
				code.flags |= Canonfield;
		}
	}
	funcbody(f, code);
	return ci;
}

defaultctor(derived: int, name: string, c: ref Node.Class): int
{
	code := ref Code;
	code.flags = Cstrict | Cctor | Cclassctor | Cmethod;
	if(derived)
		code.flags |= Cderived;
	code.name = name;
	code.src = cu.src;
	code.spos = c.pos;
	code.send = c.end;
	code.fields = -1;
	ci := addcode(code);
	# constructor(...args) { super(...args) } is done by the evaluator itself
	code.npos = 0;
	code.nframe = 1;
	code.body = -1;
	code.prologue = -1;
	return ci;
}

# ---- units ----

# a script: (its code, nil) or (nil, error)
compilescript(prog: ref Node.Program, src: string, iseval: int, evalinfo: ref Info.Eval, strict: int): (ref Code, string)
{
	saved := cu;
	cu = newunit(src);
	cu.ismod = prog.ismod;
	code := ref Code;
	code.name = nil;
	code.flags = Cscript;
	if(prog.strict || strict)
		code.flags |= Cstrict;
	code.src = cu.src;
	code.spos = 0;
	code.send = len src;
	code.fields = -1;
	addcode(code);
	fs := ref Fs;
	fs.code = code;
	fs.strict = (code.flags & Cstrict) != 0;
	fs.nframe = 1;
	r: (ref Code, string);
	{
		if(iseval && evalinfo != nil) {
			code.flags |= Ceval;
			cu.evalctx = evalinfo.ctx;
			compileevalbody(prog, code, fs, evalinfo);
		} else if(iseval) {
			code.flags |= Ceval;
			compileglobal(prog, code, fs, 1);
		} else
			compileglobal(prog, code, fs, 0);
		fixup();
		r = (code, nil);
	} exception {
	"JScompile" =>
		r = (nil, cu.err);
	}
	cu = saved;
	return r;
}

# script code (or indirect eval): top-level vars and functions are the global object's
compileglobal(prog: ref Node.Program, code: ref Code, fs: ref Fs, iseval: int)
{
	cu.fs = fs;
	s := openscope(Sglobal);
	fs.sc = s;
	cu.script = 1;
	strict := fs.strict;
	if(iseval && strict) {
		# strict eval code has a var scope of its own
		s.kind = Seval;
		compileevalscope(prog, code, fs, s);
		return;
	}
	# var names and functions, for GlobalDeclarationInstantiation
	vs := openscope(Sblock);	# a scratch scope to collect names
	hoistvars(prog.body, vs, 1);
	vars: list of string;
	for(l := vs.binds; l != nil; l = tl l)
		vars = (hd l).name :: vars;
	lexs: list of (string, int, int);
	if(!iseval) {
		ls := openscope(Sblock);
		lexdecls(prog.body, ls, 1);
		for(l = ls.binds; l != nil; l = tl l) {
			b := hd l;
			if(b.kind == Bfunc)
				continue;
			slot := glexslot(b.name, b.kind == Bconst || b.kind == Bcinner);
			lexs = (b.name, slot, b.kind == Bconst) :: lexs;
			cu.lexnames = (b.name, slot) :: cu.lexnames;
		}
		closescopenames(ls);
	} else {
		# indirect eval's lets are its own
		;
	}
	closescopenames(vs);
	cu.sc = s;
	fns: list of (string, int);
	for(i := len prog.body - 1; i >= 0; i--) {
		n := prog.body[i];
		while(n != nil) {
			pick lb := n {
			Labeled =>
				n = lb.body;
				continue;
			}
			break;
		}
		pick f := n {
		Func =>
			if(f.id != nil) {
				nm := idname(f.id);
				dup := 0;
				for(fl := fns; fl != nil; fl = tl fl) {
					(fnm, nil) := hd fl;
					if(fnm == nm)
						dup = 1;
				}
				if(!dup)
					fns = (nm, funcexpr(f, nm)) :: fns;
			}
		}
	}
	if(iseval) {
		# an indirect eval's lexical names: a scope of its own
		ls := openscope(Sblock);
		lexdecls(prog.body, ls, 1);
		compl = 1;
		b := stmts(prog.body);
		compl = 0;
		closescope(ls);
		b = scoped(ls, b, nil, 0);
		inst := e1(Nglobalinst, addinfo(ref Info.Ginst(vars, fns, nil)));
		code.body = e2(Nseqs, addkidsa(array[] of {inst, b}), 2);
	} else {
		compl = 1;
		b := stmts(prog.body);
		compl = 0;
		inst := e1(Nglobalinst, addinfo(ref Info.Ginst(vars, fns, lexs)));
		code.body = e2(Nseqs, addkidsa(array[] of {inst, b}), 2);
	}
	closescope(s);
	code.nframe = fs.nframe;
	code.prologue = -1;
}

closescopenames(s: ref Scope)
{
	for(l := s.binds; l != nil; l = tl l) {
		b := hd l;
		m := ment(b.name, 0);
		if(m != nil && m.binds != nil && hd m.binds == b)
			m.binds = tl m.binds;
	}
	s.binds = nil;
	cu.sc = s.up;
}

# strict eval code: its vars are its own
compileevalscope(prog: ref Node.Program, code: ref Code, fs: ref Fs, s: ref Scope)
{
	hoistvars(prog.body, s, 1);
	lexdecls(prog.body, s, 1);
	fnodes := hoistfuncs(prog.body);
	compl = 1;
	b := stmts(prog.body);
	compl = 0;
	closescope(s);
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
	holes: list of int;
	nh := 0;
	for(l := s.binds; l != nil; l = tl l) {
		bd := hd l;
		if(!bd.captured && (bd.kind == Blet || bd.kind == Bconst || bd.kind == Bclass)) {
			holes = bd.slot :: holes;
			nh++;
		}
	}
	if(nh > 0) {
		pro = e2(Nholes, addkids(holes, nh), nh) :: pro;
		np++;
	}
	pro = revints(pro);
	code.nframe = fs.nframe;
	if(np > 0)
		code.prologue = e2(Nseqs, addkids(revints(pro), np), np);
	else
		code.prologue = -1;
	code.body = b;
}

# direct eval: the caller's scopes are in sight
compileevalbody(prog: ref Node.Program, code: ref Code, fs: ref Fs, ev: ref Info.Eval)
{
	# the caller's scope chain, outermost first, its names visible
	chain: list of ref Scope;
	for(sc := ev.sc; sc != nil; sc = sc.up)
		chain = sc :: chain;
	for(; chain != nil; chain = tl chain) {
		sc = hd chain;
		for(l := revbinds(sc.binds); l != nil; l = tl l) {
			b := hd l;
			b.id = cu.nbind;
			if(cu.nbind == len cu.binds) {
				a := array[2 * cu.nbind] of ref Bind;
				a[0:] = cu.binds;
				cu.binds = a;
			}
			cu.binds[cu.nbind++] = b;
			m := ment(b.name, 1);
			m.binds = b :: m.binds;
		}
		sc.id = cu.nscope;
		if(cu.nscope == len cu.scopes) {
			a := array[2 * cu.nscope] of ref Scope;
			a[0:] = cu.scopes;
			cu.scopes = a;
		}
		cu.scopes[cu.nscope++] = sc;
	}
	# the eval code's own frame, as a function of its own; the caller's function is its outer one
	fs.up = ev.sc.fs;
	cu.fs = fs;
	cu.sc = ev.sc;
	strict := fs.strict;
	s := openscope(Seval);
	fs.sc = s;
	if(!strict) {
		# vars and functions go to the caller's variable scope, found by name
		s.dyn = 1;
		vs := openscope(Sblock);
		hoistvars(prog.body, vs, 1);
		vars: list of string;
		for(l := vs.binds; l != nil; l = tl l) {
			vars = (hd l).name :: vars;
			if(ev.paramargs && (hd l).name == "arguments")
				cerror(0, "eval in parameters cannot declare 'arguments'");
		}
		for(j := 0; ev.paramargs && j < len prog.body; j++)
			pick f := prog.body[j] {
			Func =>
				if(f.id != nil && idname(f.id) == "arguments")
					cerror(0, "eval in parameters cannot declare 'arguments'");
			}
		closescopenames(vs);
		cu.sc = s;
		ls := openscope(Sblock);
		lexdecls(prog.body, ls, 1);
		# functions declared at the top go to the variable scope; the lets stay here
		fns: list of (string, int);
		for(i := len prog.body - 1; i >= 0; i--)
			pick f := prog.body[i] {
			Func =>
				if(f.id != nil)
					fns = (idname(f.id), funcexpr(f, idname(f.id))) :: fns;
			}
		# function names are not lexical here
		nb: list of ref Bind;
		for(l = ls.binds; l != nil; l = tl l)
			if((hd l).kind == Bfunc) {
				m := ment((hd l).name, 0);
				if(m != nil && m.binds != nil && hd m.binds == hd l)
					m.binds = tl m.binds;
			} else
				nb = hd l :: nb;
		ls.binds = nb;
		compl = 1;
		b := stmts(prog.body);
		compl = 0;
		closescope(ls);
		b = scoped(ls, b, nil, 0);
		closescope(s);
		dl: list of int;
		ndl := 0;
		for(vl := vars; vl != nil; vl = tl vl) {
			dl = e1(Ndyndeclvar, intern(hd vl)) :: dl;
			ndl++;
		}
		for(; fns != nil; fns = tl fns) {
			(nm, fnode) := hd fns;
			dl = e2(Ndyndeclfn, intern(nm), fnode) :: dl;
			ndl++;
		}
		dl = b :: dl;
		ndl++;
		pro := -1;
		if(s.needenv)
			pro = e2(Nmkenv, s.nenv, addsci(s.sci));
		code.prologue = pro;
		code.body = e2(Nseqs, addkids(dl, ndl), ndl);
		code.nframe = fs.nframe;
		# the eval's Env is not a variable scope for further evals
		return;
	}
	compileevalscope(prog, code, fs, s);
}
