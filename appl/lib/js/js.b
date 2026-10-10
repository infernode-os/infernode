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
#	jsbuiltin.b	the realm's built-in objects
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
include "jsstubs.b";

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

reportuncaught(v: V)
{
	emitout("uncaught (in a job): " + showexc(v));
}
