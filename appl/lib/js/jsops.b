#
# jsops.b - the bytecode: opcodes and the code object.  Included by js.b.
#
# Code is an array of ints: an opcode, then its operands.  Operands are
# registers (r: an offset from the frame's base), constants (k: an
# index into consts), atoms (a), function templates (f: into funcs),
# jump targets (j: an index into the code) and small integers (n).
#
# A frame's registers: 0 this, 1 the function called, 2 new.target,
# 3 the current environment, 4 on the arguments as passed (up to the
# number of formal parameters), then locals and temporaries.
#

Rthis, Rfn, Rnewtarget, Renv, Rarg0: con iota;

# a function parsed lazily (Jsparse->Flazy): what compiling it needs
Lazy: adt {
	node:	ref Node.Func;	# its parameters and where its body is
	fs:	ref CScope;	# its scope, from the compile it was found in
	fnscope:	ref CScope;	# the nearest non-arrow function's scope (for an arrow)
	parent:	ref CFunc;	# the function it is in
	extra:	int;
	ismod:	int;
};

# an object literal whose keys are all known: its objects share a shape
# made the first time, and are filled slot by slot
Lit: adt {
	keys:	array of int;
	shape:	ref Shape;
};

Oundef,		# r
Onull,		# r
Otrue,		# r
Ofalse,		# r
Oempty,		# r		the uninitialised marker
Oint,		# r n
Oconst,		# r k
Omove,		# r r
Ochktdz,	# r a		ReferenceError if r is uninitialised
Ochkthis,	# r		ReferenceError if this is not yet bound (a derived constructor)
Ogetenv,	# r n n		r = slot n2 of the environment n1 out
Ogetenvc,	# r n n a	and check it is initialised
Osetenv,	# n n r
Osetenvc,	# n n r a	assign, checking it is initialised
Opushenv,	# n		a new environment for scope n, inside the current one
Opopenv,
Ocopyenv,	# 		replace the current environment with a copy (per-iteration bindings)
Ogetglobal,	# r a n		n: the inline cache
Otypeofglobal,	# r a
Osetglobal,	# a r
Oinitglobal,	# a r		initialise a global lexical binding
Odelglobal,	# r a
Oglobalinit,	# n		the script's global declarations (decls[n])
Ogetname,	# r a		a name found at run time (with, eval)
Otypeofname,	# r a
Osetname,	# a r
Oinitname,	# a r
Odelname,	# r a
Ocallname,	# r r a		callee and this for a call to a name found at run time
Ogetprop,	# r r a n
Osetprop,	# r a r n
Ogetelem,	# r r r
Osetelem,	# r r r
Odelprop,	# r r a
Odelelem,	# r r r
Oin,		# r r r		r1 = r2 in r3
Oadd, Osub, Omul, Odiv, Omod, Oexp, Oshl, Oshr, Oushr, Oband, Obor, Obxor,	# r r r
Oeq, One, Oseq, Osne, Olt, Ole, Ogt, Oge, Oinstof,				# r r r
Oneg, Opos, Otonumeric, Onot, Obnot, Otypeof, Oinc, Odec,			# r r
Ojmp,		# j
Ojt,		# r j
Ojf,		# r j
Ojnullish,	# r j
Ojnnullish,	# r j
Ojundef,	# r j
Ojnundef,	# r j
Ocall,		# r r r r n	dst, callee, this, first argument, count
Ocallspread,	# r r r r	dst, callee, this, array of arguments
Onew,		# r r r n	dst, callee, first argument, count
Onewspread,	# r r r
Osupercall,	# r r n
Osupercallspread,	# r r
Oeval,		# r r r n n	a call that is a direct eval if the callee is %eval%; n2: scope
Oret,		# r
Othrow,		# r
Othrowerr,	# n k		throw a new error of kind n with message k
Oclosure,	# r f
Onewobj,	# r
Onewarr,	# r
Oarrpush,	# r r
Oarrhole,	# r
Oarrspread,	# r r
Odefdata,	# r r r		CreateDataProperty(o, key, v)
Odefdataa,	# r a r
Odefacc,	# r r r n	n: 1 getter, 2 setter, +4 enumerable
Osetproto,	# r r		an object literal's __proto__: v
Ocopyprops,	# r r r		CopyDataProperties(o, src, the excluded keys' array or undefined)
Osetfnname,	# r r n		SetFunctionName(f, key, n: 0, 1 "get", 2 "set")
Osethome,	# r r
Otemplate,	# r n
Oregexp,	# r n
Ogetiter,	# r r n		r1 = the iterator, r1+1 = its next method; n: 1 async
Oiternext,	# r r r		value, done, the iterator (and next in r3+1)
Oiterclose,	# r
Oforin,		# r r
Oforinnext,	# r r j		key, the enumerator; jump when done
Oargs,		# r n		n: mapped
Orest,		# r n		an array of the arguments from n
Oreqobj,	# r		TypeError if null or undefined
Otokey,		# r r
Otostr,		# r r
Oconcat,	# r r r		strings
Oyield,		# r r
Oyieldraw,	# r r r		value, resume mode, yielded (for yield*)
Oawait,		# r r
Ogenstart,
Oclass,		# r r r f	constructor, prototype, superclass (or empty), constructor's template
Odefmethod,	# r r r n	object, key, function, n: 0 method, 1 getter, 2 setter (+4 enumerable)
Ogetsuper,	# r r		super[key]
Osetsuper,	# r r
Onewprivate,	# r a
Ogetpriv,	# r r r
Osetpriv,	# r r r
Odefpriv,	# r r r		a private field
Ohaspriv,	# r r r		#x in o
Oprivmethod,	# r r r n	n: 0 method, 1 getter, 2 setter
Oinitfields,
Odebugger,
Opushwith,	# r
Oimportmeta,	# r
Oimport,	# r r r		import(specifier, options)
Ospreadobj,	# r r		object spread
Oiterdone,	# r		mark an iterator done (no close)
Olineno,	# n		source position, for messages
Ohome,		# r		the active function's home object
Ofinish,	# r		end of a finally: rethrow or resume what the completion register says
Ologicnot,	# reserved
Oiterthrow,	# r r		call the iterator's throw
Oiterreturn,	# r r r		call the iterator's return
Oasynciter,	# r		wrap a sync iterator for for-await
Oitercall,	# r r		r1 = the iterator's next() (r2, its next in r2+1)
Oiterres,	# r r r r	value, done from an iterator result r3 (TypeError if not an object); r4 the iterator, marked exhausted when done
Oitreturn,	# r r		r1 = the iterator's return() result, or empty if it has none (or is exhausted)
Ojempty,	# r j
Ochkobj,	# r		TypeError if r is not an object
Oystep,		# r r r r r	yield*: res, done, the iterator, the mode, what was sent
Onewdisp,	# r		a new disposal stack (using)
Oaddres,	# r r n		add a resource to the stack; n: 1 await using
Odisnext,	# r r j		pop a resource into r1 (or jump when none are left)
Odiscall,	# r r		r1 = call the resource's dispose method
Oaccum,		# r r		r1 = r2 if r1 is empty, else a SuppressedError(r2, r1)
Omodinit,	#		a module's stop between instantiation and evaluation
Othisdyn,	# r		eval code's this: a %this binding around it, else the frame's
Ogenret,	# r		go on returning r from a generator (after an Hclose handler)
Onewlit,	# r n		a new object with literal n's keys (code.lits[n]) and their slots
Oslot,		# r n r		slot n of r1 = r3 (a literal being filled)
Onop: con iota;

# Code flags
Cstrict, Carrow, Cgen, Casync, Cmethod, Cctor, Cderived, Cargs, Cmapped, Cextra,
Cclassfields, Cscript, Ceval, Cmodule, Cstatic, Cgetter, Csetter, Cnoctor, Cindirect: con 1 << iota;

# exception handlers
Hcatch, Hfinally, Hclose: con iota;	# Hclose: catches throws and a generator's return (reg+1 says which)

Handler: adt {
	start, end:	int;	# [start, end) of the code
	target:	int;
	reg:	int;		# where the exception goes
	kind:	int;
	envdepth:	int;	# unused: the code restores the environment itself
};

# an environment's layout
Scope: adt {
	nslots:	int;
	names:	array of int;	# atoms, by slot; nil if no lookups by name
	kinds:	array of int;	# by slot: Bvar, Blet, Bconst, ...
	tdz:	array of int;	# by slot: starts uninitialised
	evalvars:	int;	# eval may declare vars here (an object holds them)
	isfunc:	int;	# a function's top scope (where eval's vars go)
};

# a script's global declarations
Gdecl: adt {
	vars:	array of int;
	funcs:	array of (int, int);	# (name, template)
	lets:	array of int;
	consts:	array of int;
	annexb:	array of int;	# Annex B function names, as vars if they can be
};

Code: adt {
	name:	string;
	flen:	int;		# the function's length
	nparams:	int;	# formal parameters with registers
	nregs:	int;
	ops:	array of int;
	consts:	array of V;
	funcs:	array of ref Code;
	handlers:	array of Handler;
	scopes:	array of ref Scope;
	decls:	array of ref Gdecl;
	ics:	array of ref Shape;
	icslot:	array of int;
	icproto:	array of int;	# the holder, for a property found on the prototype, or -1
	icgen:	array of int;	# the shape's gen when cached (an owned shape changes in place)
	icref:	array of ref V;	# a global lexical binding's cell, for a global name's cache
	tmpls:	array of (array of string, array of string);
	tmplcache:	array of int;	# the template objects, made once per site
	regexps:	array of (string, string);
	flags:	int;
	src:	string;	# the function's text, for toString, if not whole[spos:send]
	spos, send:	int;
	lits:	array of ref Lit;	# object literals' keys, and the shape made from them
	lazy:	ref Lazy;	# not yet compiled: how to, when first called
	pos:	array of int;	# by pc: source position (for messages), or nil
	whole:	string;	# the source those positions are in
	file:	string;
	allreg:	int;	# Cextra: the register given every argument, as an array
	paramnames:	array of int;	# atoms, by formal parameter (simple ones), for mapped arguments
	modid:	int;	# a module's code: its module, else 0
	evalctx:	int;	# eval code: what its caller allowed (Jsparse->Enewtarget...)
	evalprivs:	list of string;	# and the private names around it
	marked:	int;	# the collection that last marked it
};
