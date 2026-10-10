implement Jsfuzz;

#
# jsfuzz - differential testing of the compiled tier (docs/JS-ENGINE.md
# §11, phase 6): random programs, each run in a realm that interprets
# and one that compiles every function at its first loop, their results
# compared.
#
#	jsfuzz [-n count] [-s seed] [-v] [-p]
#
# The programs are loops over what compiled code has in line, and what
# makes it leave to the interpreter: numbers (NaN, -0, past 32 bits),
# strings, booleans, null and undefined mixed in; arithmetic, %,
# bitwise operators and comparisons; property and element reads and
# writes, holes, a shape changed in the loop; closures; a value's type
# changed in the loop.  A difference prints the seed and the program;
# the exit status is failure if there was one.  -p prints the programs
# and runs none; -v says each case as it starts.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "web/dom.m";
include "js.m";

Jsfuzz: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

rng := 1;
ncompiled := 0;	# functions the compiling realms compiled
nrefused := 0;	# and the verifier refused

rand(n: int): int
{
	# xorshift32
	x := rng;
	x ^= x << 13;
	x ^= (x >> 17) & 16r7FFF;
	x ^= x << 5;
	rng = x & 16r7FFFFFFF;
	if(rng == 0)
		rng = 1;
	return rng % n;
}

# (a local: inlined, this function's result corrupts the heap, a Limbo
# compiler bug being looked into)
pick1(a: array of string): string
{
	k := rand(len a);
	r := a[k];
	return r;
}

lits := array[] of {"0", "1", "-1", "2", "3", "7", "0.5", "-0", "NaN", "Infinity", "2147483647", "-2147483648",
	"4294967296", "1e20", "'a'", "'3'", "''", "true", "false", "null", "undefined", "1.5", "-7", "100"};
binops := array[] of {"+", "-", "*", "/", "%", "&", "|", "^", ">>", "<", "<=", ">", ">=", "===", "!==", "==", "!="};
nvars := 5;

expr(d: int): string
{
	if(d <= 0)
		return leaf();
	case rand(10) {
	0 or 1 or 2 =>
		return leaf();
	3 or 4 or 5 =>
		return "(" + expr(d-1) + " " + pick1(binops) + " " + expr(d-1) + ")";
	6 =>
		return pick1(array[] of {"-", "!", "+"}) + "(" + expr(d-1) + ")";
	7 =>
		return "(" + expr(d-1) + " ? " + expr(d-1) + " : " + expr(d-1) + ")";
	8 =>
		return "f(" + expr(d-1) + ", " + expr(d-1) + ")";
	* =>
		return "g(" + expr(d-1) + ")";
	}
}

leaf(): string
{
	case rand(9) {
	0 or 1 =>
		return pick1(lits);
	2 or 3 =>
		return "v" + string rand(nvars);
	4 =>
		return "i";
	5 =>
		return "o." + pick1(array[] of {"a", "b", "c", "z"});
	6 =>
		return "arr[" + pick1(array[] of {"i % 6", "i", "(i & 3)", "0", "-1", "i * 0.5"}) + "]";
	7 =>
		return "k";
	* =>
		return "vals[i % vals.length]";
	}
}

stmt(d: int): string
{
	v := "v" + string rand(nvars);
	case rand(14) {
	0 or 1 or 2 =>
		return v + " = " + expr(2) + ";";
	3 =>
		return "o." + pick1(array[] of {"a", "b", "c"}) + " = " + expr(2) + ";";
	4 =>
		return "arr[" + pick1(array[] of {"i % 6", "(i & 7)", "i"}) + "] = " + expr(2) + ";";
	5 =>
		if(d <= 0)
			return v + "++;";
		return "if (" + expr(2) + ") { " + stmt(d-1) + " } else { " + stmt(d-1) + " }";
	6 =>
		return "out.push(" + expr(2) + ");";
	7 =>
		return v + pick1(array[] of {"++", "--"}) + ";";
	8 =>
		return "if (i === " + string rand(20) + ") o." + pick1(array[] of {"n" + string rand(3), "a"}) + " = " + expr(1) + ";";
	9 =>
		return "if (i === " + string rand(20) + ") delete o." + pick1(array[] of {"a", "b"}) + ";";
	10 =>
		return "if (i === " + string rand(20) + ") " + v + " = " + pick1(array[] of {"'s'", "null", "{}", "[1]", "1.5", "true"}) + ";";
	11 =>
		return "k = k + " + expr(1) + ";";
	12 =>
		return "try { " + v + " = " + expr(2) + "; } catch (e) { out.push('E'); }";
	* =>
		return "s += show(" + expr(2) + ");";
	}
}

program(): string
{
	b := "(function () {\n";
	if(rand(3) == 0)
		b += "'use strict';\n";
	b += "const show = (x) => Object.is(x, -0) ? '-0' : typeof x === 'object' && x !== null ? 'obj' : String(x);\n";
	b += "const out = []; let s = ''; let k = 0;\n";
	b += "const vals = [" + pick1(lits);
	for(i := 0; i < 5; i++)
		b += ", " + pick1(lits);
	b += "];\n";
	b += "const o = {a: " + pick1(lits) + ", b: " + pick1(lits) + ", c: " + pick1(lits) + "};\n";
	b += "const arr = [" + pick1(lits) + ", " + pick1(lits) + ", , " + pick1(lits) + ", " + pick1(lits) + "];\n";
	for(i = 0; i < nvars; i++)
		b += "let v" + string i + " = " + pick1(lits) + ";\n";
	b += "function f(x, y) { return " + expr(2) + "; }\n";
	b += "const g = (x) => " + expr(1) + ";\n";
	n := 5 + rand(40);
	b += "for (let i = 0; i < " + string n + "; i++) {\n";
	ns := 1 + rand(6);
	for(i = 0; i < ns; i++)
		b += "\t" + stmt(2) + "\n";
	b += "}\n";
	b += "return [out.map(show).join(','), s, k, v0, v1, v2, v3, v4, o.a, o.b, o.c, arr.length].map(show).join('|');\n";
	b += "})()";
	return b;
}

run(src: string, jit: int): string
{
	js := load Js Js->PATH;
	if(js == nil)
		return sys->sprint("cannot load %s: %r", Js->PATH);
	if((e := js->init()) != nil)
		return e;
	js->jit(jit);
	(r, err) := js->evalscript(src, "fuzz");
	if(jit >= 0) {
		(nc, nr) := js->jitstats();
		ncompiled += nc;
		nrefused += nr;
	}
	js->shutdown();
	if(err != nil)
		return "error: " + err;
	return r;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	count := 1000;
	seed := sys->millisec();
	verbose := 0;
	printonly := 0;
	for(args = tl args; args != nil; args = tl args)
		case hd args {
		"-n" =>
			args = tl args;
			count = int hd args;
		"-s" =>
			args = tl args;
			seed = int hd args;
		"-v" =>
			verbose = 1;
		"-p" =>
			printonly = 1;
		}
	bad := 0;
	for(t := 0; t < count; t++) {
		rng = (seed + t * 7919) & 16r7FFFFFFF;
		if(rng == 0)
			rng = 1;
		src := program();
		if(printonly) {
			sys->print("%s\n", src);
			continue;
		}
		if(verbose)
			sys->fprint(sys->fildes(2), "case %d seed %d\n", t, seed + t * 7919);
		a := run(src, -1);
		b := run(src, 0);
		if(a != b) {
			bad++;
			sys->print("DIFFERENT seed %d (case %d):\ninterpreted: %s\ncompiled:    %s\n%s\n\n", seed + t * 7919, t, a, b, src);
		} else if(verbose)
			sys->print("same %d: %s\n", t, a);
	}
	sys->print("jsfuzz: %d programs from seed %d, %d different; %d functions compiled, %d refused\n", count, seed, bad, ncompiled, nrefused);
	if(bad || nrefused)
		raise "fail:different";
}
