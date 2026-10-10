implement Js;

#
# A JavaScript realm: the engine of docs/JS-ENGINE.md.
#
# The source is split into fragments included here, so that all of it
# is one module, whose globals (the heap's tables, the value stack) the
# whole engine reaches directly.  Each loaded instance is a realm.
#
#	jsval.b		values, strings, keys, shapes, own properties, the collector
#	jsobj.b		the object internal methods, conversions, comparisons
#	jsops.b		the bytecode
#	jscomp.b	the compiler
#	jsvm.b		the interpreter
#	jsrt.b		generators, promises, iteration, eval
#	jsbuiltin.b	the realm's intrinsics; Object, Function, errors, Symbol, Boolean, globals
#	jsarray.b	Array
#	jsstring.b	String, Number, Math, JSON
#	jscoll.b	Map, Set, weak collections, Promise, Reflect, iterators, generators
#

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "jslex.m";
	jslex: Jslex;

include "jsparse.m";
	jsparse: Jsparse;
	Node, Kvar, Klet, Kconst, Kusing, Kawaitusing: import jsparse;

include "jsre.m";
	jsre: Jsre;

include "js.m";

include "jsval.b";
include "jsobj.b";
include "jsops.b";
include "jscomp.b";
include "jsvm.b";
include "jsrt.b";
include "jsbuiltin.b";
include "jsarray.b";
include "jsstring.b";
include "jscoll.b";
include "jsregexp.b";

output: ref fn(s: string);

init(): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	jsre = load Jsre Jsre->PATH;
	if(math == nil || jslex == nil || jsparse == nil || jsre == nil)
		return sys->sprint("cannot load the engine's modules: %r");
	jslex->init();
	jsparse->init();
	jsre->init();
	resetstate();
	valinit();
	strinit();
	atominit();
	objinit();
	shapeinit();
	vminit();
	{
		realminit();
	} exception e {
	"js:throw" =>
		return "making the realm: " + showexc(thrown);
	}
	return nil;
}

# a module instance may be made a fresh realm again: everything starts over
resetstate()
{
	nstr = 0;
	nsfree = 0;
	strsince = 0;
	natom = 0;
	nobj = 0;
	nofree = 0;
	objsince = 0;
	gcwanted = 0;
	gcobjlimit = 100000;
	gcstrlimit = 200000;
	nmark = 0;
	ncollect = 0;
	nintr = 0;
	intr = nil;
	sp = 0;
	nframe = 0;
	pc = 0;
	base = 0;
	ops = nil;
	code = nil;
	thrown = V(0, 0, 0.0);
	genreturning = 0;
	jobs = nil;
	jobstail = nil;
	njobs = 0;
	gens = nil;
	rootstk = nil;
	globalcodes = nil;
	glex = nil;
	glexconst = nil;
	glexconsts = nil;
	symregistry = nil;
	joining = nil;
	mapiterators = 0;
	cs = nil;
	cscope = nil;
	completion = -1;
	pendinglabels = nil;
	envdepth = 0;
	output = nil;
}

setoutput(out: ref fn(s: string))
{
	output = out;
}

emitout(s: string)
{
	if(output != nil)
		output(s);
	else
		sys->print("%s\n", s);
}

evalscript(src, name: string): (string, string)
{
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		return (nil, "SyntaxError: " + name + ":" + err);
	sp0 := sp;
	nf := nframe;
	{
		pick p := prog {
		Program =>
			c := compilescript(p, src, 0, 0);
			c.file = name;
			keepcode(c);
			v := runcode(c);
			r := display(v);
			runjobs();
			sp = sp0;
			return (r, nil);
		}
	} exception e {
	"js:throw" =>
		sp = sp0;
		nframe = nf;
		ex := showexc(thrown);
		{
			runjobs();
		} exception {
		"js:throw" =>
			;
		}
		return (nil, ex);
	}
	return (nil, "internal: not a program");
}

# a script's code, kept for its template objects' sake while it may run again
keepcode(c: ref Code)
{
	n := array[len globalcodes + 1] of ref Code;
	n[0:] = globalcodes;
	n[len globalcodes] = c;
	globalcodes = n;
}

# a value as the shell shows it
display(v: V): string
{
	case v.t {
	Tstr =>
		return str(v.x);
	Tobj =>
		{
			return tostring(v);
		} exception {
		"js:throw" =>
			return "[object]";
		}
	}
	{
		return tostring(v);
	} exception {
	"js:throw" =>
		return show(v);
	}
	return show(v);
}

# an uncaught exception, as "Name: message"
showexc(v: V): string
{
	if(v.t == Tobj) {
		{
			n := getv(v, aname);
			m := getv(v, amessage);
			ns := "Error";
			if(n.t == Tstr)
				ns = str(n.x);
			if(m.t == Tstr && slen[m.x] > 0)
				return ns + ": " + str(m.x);
			if(n.t == Tstr)
				return ns;
		} exception {
		"js:throw" =>
			;
		}
	}
	{
		return "uncaught " + tostring(v);
	} exception {
	"js:throw" =>
		return "uncaught " + show(v);
	}
	return "uncaught exception";
}

shutdown()
{
	okind = nil;
	oflags = nil;
	oshape = nil;
	oproto = nil;
	oslots = nil;
	oelems = nil;
	onelem = nil;
	oalen = nil;
	odata = nil;
	omark = nil;
	ofree = nil;
	sflat = nil;
	sleft = nil;
	sright = nil;
	slen = nil;
	satom = nil;
	smark = nil;
	sfree = nil;
	atomstr = nil;
	atomsh = nil;
	atomsym = nil;
	atomidx = nil;
	atomhash = nil;
	vs = nil;
	frames = nil;
	jobs = nil;
	jobstail = nil;
	njobs = 0;
	gens = nil;
	globalcodes = nil;
	glex = nil;
	code = nil;
	ops = nil;
	cs = nil;
	cscope = nil;
	scopemap = nil;
	rootshape = nil;
	output = nil;
	intr = nil;
	markstk = nil;
	rootstk = nil;
}

test262()
{
	h := newplain();
	keep(h);
	defown(iglobal, intern("$262"), Awrite|Aconf, objv(h));
	value(h, "global", objv(iglobal));
	method(h, "evalScript", 1, t262_evalscript);
	method(h, "gc", 0, t262_gc);
	method(h, "disasm", 1, t262_disasm);
	method(h, "createRealm", 0, t262_createrealm);
	method(h, "detachArrayBuffer", 1, t262_detach);
	dda := nativefn("IsHTMLDDA", 0, t262_dda);
	oflags[dda] |= Ohtmldda;
	value(h, "IsHTMLDDA", objv(dda));
	agent := newplain();
	value(h, "agent", objv(agent));
}

t262_disasm(nil: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(f.t != Tobj || okind[f.x] != Kfunc)
		typeerr("disasm: not a script function");
	pick d := odata[f.x] {
	Func =>
		return strv(disasm(d.code));
	}
	return undef;
}

disasm(c: ref Code): string
{
	r := sys->sprint("%s nregs %d nparams %d flags %ux\n", c.name, c.nregs, c.nparams, c.flags);
	for(i := 0; i < len c.ops; ) {
		op := c.ops[i];
		l := oplen(op);
		nm := "?";
		if(op >= 0 && op < len opnames)
			nm = opnames[op];
		r += sys->sprint("%4d %s", i, nm);
		for(k := 1; k < l && i + k < len c.ops; k++)
			r += sys->sprint(" %d", c.ops[i+k]);
		r += "\n";
		i += l;
	}
	for(i = 0; i < len c.handlers; i++) {
		h := c.handlers[i];
		r += sys->sprint("handler [%d,%d) -> %d reg %d kind %d\n", h.start, h.end, h.target, h.reg, h.kind);
	}
	return r;
}

opnames := array[] of {
	"undef", "null", "true", "false", "empty", "int", "const", "move", "chktdz", "chkthis", "getenv", "getenvc", "setenv", "setenvc", "pushenv", "popenv", "copyenv", "getglobal", "typeofglobal", "setglobal", "initglobal", "delglobal", "globalinit", "getname", "typeofname", "setname", "initname", "delname", "callname", "getprop", "setprop", "getelem", "setelem", "delprop", "delelem", "in", "add", "sub", "mul", "div", "mod", "exp", "shl", "shr", "ushr", "band", "bor", "bxor", "eq", "ne", "seq", "sne", "lt", "le", "gt", "ge", "instof", "neg", "pos", "tonumeric", "not", "bnot", "typeof", "inc", "dec", "jmp", "jt", "jf", "jnullish", "jnnullish", "jundef", "jnundef", "call", "callspread", "new", "newspread", "supercall", "supercallspread", "eval", "ret", "throw", "throwerr", "closure", "newobj", "newarr", "arrpush", "arrhole", "arrspread", "defdata", "defdataa", "defacc", "setproto", "copyprops", "setfnname", "sethome", "template", "regexp", "getiter", "iternext", "iterclose", "forin", "forinnext", "args", "rest", "reqobj", "tokey", "tostr", "concat", "yield", "yieldraw", "await", "genstart", "class", "defmethod", "getsuper", "setsuper", "newprivate", "getpriv", "setpriv", "defpriv", "haspriv", "privmethod", "initfields", "debugger", "pushwith", "importmeta", "import", "spreadobj", "iterdone", "lineno", "home", "finish", "logicnot", "iterthrow", "iterreturn", "asynciter", "itercall", "iterres", "itreturn", "jempty", "chkobj", "ystep", "nop",
};

t262_evalscript(nil: V, a, n: int, nil: V, nil: int): V
{
	src := tostring(arg(a, n, 0));
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		throwerr(SyntaxError, err);
	pick p := prog {
	Program =>
		c := compilescript(p, src, 0, 0);
		keepcode(c);
		return runcode(c);
	}
	return undef;
}

t262_gc(nil: V, nil, nil: int, nil: V, nil: int): V
{
	gcwanted = 1;
	return undef;
}

t262_createrealm(nil: V, nil, nil: int, nil: V, nil: int): V
{
	typeerr("$262.createRealm is not supported");
	return undef;
}

t262_detach(nil: V, a, n: int, nil: V, nil: int): V
{
	detachbuffer(arg(a, n, 0));
	return null;
}

t262_dda(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return null;
}

detachbuffer(v: V)
{
	if(v.t != Tobj || okind[v.x] != Kabuf)
		typeerr("not an ArrayBuffer");
	pick d := odata[v.x] {
	Abuf =>
		d.b = nil;
		d.detached = 1;
	}
}

reportuncaught(v: V)
{
	emitout("uncaught (in a job): " + showexc(v));
}
