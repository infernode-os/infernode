implement JsEngineTest;

#
# The JavaScript engine through its host interface (module/js.m):
# scripts and their values, errors, modules, the host's functions and
# calls back into the realm, realms kept apart.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "jslex.m";
	jslex: Jslex;
include "jsparse.m";
	jsparse: Jsparse;
include "web/dom.m";
include "js.m";

JsEngineTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/js_engine_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

realm(t: ref T): Js
{
	js := load Js Js->PATH;
	if(js == nil)
		t.fatal(sys->sprint("cannot load %s: %r", Js->PATH));
	if((err := js->init()) != nil)
		t.fatal(err);
	return js;
}

ev(js: Js, src: string): string
{
	(r, e) := js->evalscript(src, "test");
	if(e != nil)
		return "error: " + e;
	return r;
}

testValues(t: ref T)
{
	js := realm(t);
	t.assertseq(ev(js, "1 + 2"), "3", "arithmetic");
	t.assertseq(ev(js, "'a' + 'b'"), "ab", "strings");
	t.assertseq(ev(js, "[1, 2, 3].map(x => x * 2).join()"), "2,4,6", "arrays and arrows");
	t.assertseq(ev(js, "class A { #x = 1; get x() { return this.#x; } }; new A().x"), "1", "classes");
	t.assertseq(ev(js, "JSON.stringify({a: [1, {b: null}]})"), "{\"a\":[1,{\"b\":null}]}", "JSON");
	t.assertseq(ev(js, "/(\\d+)-(\\d+)/.exec('10-20')[2]"), "20", "regular expressions");
	t.assertseq(ev(js, "let n = 0; for (const k of new Map([[1, 2], [3, 4]]).keys()) n += k; n"), "4", "iteration");
	t.assertseq(ev(js, "typeof (10n ** 20n)"), "bigint", "BigInt");
	js->shutdown();
}

testControl(t: ref T)
{
	js := realm(t);
	t.assertseq(ev(js, "let i = 0; for (;;) { i++; switch (i) { case 1: continue; case 2: break; } if (i == 2) break; } i"), "2", "continue in a switch goes to the loop");
	t.assertseq(ev(js, "let j = 0; for (;;) try { j++; switch (j) { case 1: continue; default: break; } break; } catch (e) {} j"), "2", "and from inside a try");
	t.assertseq(ev(js, "let k = 0; out: for (;;) { switch (k++) { case 0: continue out; case 1: break out; } } k"), "2", "labelled");
	t.assertseq(ev(js, "let s = ''; for (const c of 'abc') { switch (c) { case 'b': continue; } s += c; } s"), "ac", "in a for-of");
	t.assertseq(ev(js, "(function e(t) { for (let e of [1, 2]) {} return typeof e; })(0)"), "function", "a function expression's own name");
	t.assertseq(ev(js, "(function e() { e = 1; return typeof e; })()"), "function", "assigned in sloppy code");
	js->shutdown();
}

# every function compiled when first called, as a large script's are
testLazy(t: ref T)
{
	js := realm(t);
	js->lazy(0);
	t.assertseq(ev(js, "(function () { function m(f) { return function () { return f.apply(this, arguments); }; } function bz() { return 1; } function bj() { return m(function () { return (function () { return (function () { return bz(arguments); })(); })(); }).apply(null, arguments); } return bj(); })()"), "1", "a function's own arguments, inside one whose arguments are used");
	t.assertseq(ev(js, "function g() { var arguments = 5; return (() => (() => arguments)())(); } g(1)"), "5", "a variable named arguments, through arrows");
	t.assertseq(ev(js, "function h() { return (function () { return (() => arguments[0])(); })(9) + arguments[0]; } h(1)"), "10", "an arrow's arguments are its function's");
	t.assertseq(ev(js, "class A { constructor() {} }; const B = class { static name = 'own' }; A.name + B.name"), "Aown", "class names");
	js->shutdown();
}

# loops compiled to Dis from their first iteration, against what the
# interpreter makes of them
testJit(t: ref T)
{
	src := array[] of {
		"let s = 0; for (let i = 0; i < 100; i++) s = s + i * 2; s",
		"let t = 0; for (let k = 0; k < 4; k++) { let x = -k; if (!(x < 0)) t = t + 1; else t = t - x; } t",
		"let a = 1.5; for (let i = 0; i < 200; i++) a = a / 1.001 - 0.0001; a.toFixed(9)",
		"let c = 0; for (let i = 0; i < 10; i++) { c = c + (NaN < i) + (i <= NaN) + (i >= 5); } c",
		"let s = ''; for (let i = 0; i < 5; i++) s = s + i; s",
		"let o = 0; for (let i = 0; i < 6; i = i + 1.5) o = o - i; o",
		"let n = 0, u; for (let i = 0; i < 3; i++) { u = i > 1 ? undefined : i; n = n + (u === undefined); } n",
		"const p = {x: 1, y: 2}; let s = 0; for (let i = 0; i < 50; i++) { p.x = p.x + p.y; s = s + p.x; } s",
		"const a = [{v: 1}, {w: 2, v: 3}]; let s = 0; for (let i = 0; i < 40; i++) { const o = a[i & 1]; s = s + o.v; } s",
		"const q = {g: 1}; let s = 0; for (let i = 0; i < 30; i++) { if (i == 10) delete q.g; if (i == 20) q.g = 5; s = s + (q.g || 0); } s",
		"let s = 0; for (let i = 0; i < 30; i++) { const o = i < 15 ? {k: i} : {get k() { return 2; }}; s = s + o.k; } s",
		"const xs = [0, 1, -1, 7, -7, 3.5, 2147483647, -2147483648, 2147483648, 4294967295, NaN, Infinity, -0, 1e20, 0.5]; const out = []; " +
			"for (let i = 0; i < xs.length; i++) for (let j = 0; j < xs.length; j++) { const a = xs[i], b = xs[j]; " +
			"out.push(a % b, a & b, a | b, a ^ b, a >> b, a === b, a !== b, Object.is(a % b, -0), a < b, a >= b, a * b, a - b); } out.join()",
		"const a = []; for (let i = 0; i < 20; i++) a.push(i); a[25] = 1; let s = 0; for (let k = 0; k < 3; k++) for (let i = -1; i < 30; i++) { if (i < 20) a[i] = (a[i] | 0) + 1; s = s + (a[i] === undefined ? 1000 : a[i]); } s",
		"let c = 0; const f = () => { for (let i = 0; i < 50; i++) c = c + 1; }; f(); f(); c",
		"const args = (function () { return arguments; })(1, 2, 3); let s = 0; for (let i = 0; i < 9; i++) s = s + args[i % 3]; s",
		"const o = {a: 1}; const arr = ['x', 'y', o, o, 'x']; let n = 0; for (let i = 0; i < 5; i++) for (let j = 0; j < 5; j++) n = n + (arr[i] === arr[j]); n",
	};
	for(i := 0; i < len src; i++) {
		js := realm(t);
		js->jit(-1);
		want := ev(js, src[i]);
		js->shutdown();
		js = realm(t);
		js->jit(0);
		t.assertseq(ev(js, src[i]), want, "compiled as interpreted: " + src[i]);
		js->shutdown();
	}
}

testErrors(t: ref T)
{
	js := realm(t);
	t.assertseq(ev(js, "null.x"), "error: TypeError: cannot read properties of null (reading 'x')", "a TypeError");
	t.assertseq(ev(js, "throw new RangeError('r')"), "error: RangeError: r", "thrown");
	(nil, e) := js->evalscript("1 +", "bad.js");
	t.assert(e != nil && len e > 11 && e[0:11] == "SyntaxError", "a syntax error: " + e);
	t.assertseq(ev(js, "'still alive'"), "still alive", "the realm survives");
	js->shutdown();
}

testJobs(t: ref T)
{
	js := realm(t);
	t.assertseq(ev(js, "var log = []; Promise.resolve(1).then(v => log.push(v)); (async () => { await null; log.push(2); })(); log.length"), "0", "jobs wait");
	t.assertseq(ev(js, "log.join()"), "1,2", "jobs ran after the script");
	js->shutdown();
}

calls: list of string;

hostecho(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++) {
		if(i > 0)
			s += "|";
		s += a[i];
	}
	calls = s :: calls;
	return "<" + s + ">";
}

testHostFunctions(t: ref T)
{
	js := realm(t);
	js->deffn("echo", hostecho);
	js->deffn("Host.sub.echo", hostecho);
	t.assertseq(ev(js, "echo('a', 2, true)"), "<a|2|true>", "a host function");
	t.assertseq(ev(js, "Host.sub.echo('x')"), "<x>", "one on an object made for it");
	t.assertseq(ev(js, "[...echo('\\u{1F600}')].map(c => c.codePointAt(0).toString(16)).join()"), "3c,1f600,3e", "characters past the BMP both ways");
	t.asserteq(len calls, 3, "calls made");
	ev(js, "var Win = {onexec(cmd, arg) { return cmd === 'Go' ? 'took ' + arg : false; }}");
	(r, e) := js->callfn("Win.onexec", array[] of {"Go", "there"});
	t.assertseq(r, "took there", "a call into the realm");
	t.assertnil(e, "no error");
	(r, e) = js->callfn("Win.onexec", array[] of {"Stop", ""});
	t.assertseq(r, "false", "its value");
	(r, e) = js->callfn("Win.nothing", nil);
	t.assert(r == nil && e == nil, "no function there");
	ev(js, "Win.bad = () => { throw new Error('no') }");
	(r, e) = js->callfn("Win.bad", nil);
	t.assertseq(e, "Error: no", "its exception");
	js->shutdown();
}

testRealmsApart(t: ref T)
{
	a := realm(t);
	b := realm(t);
	ev(a, "globalThis.x = 'a'; Array.prototype.mine = 1");
	t.assertseq(ev(b, "typeof x"), "undefined", "globals are a realm's own");
	t.assertseq(ev(b, "[].mine"), "undefined", "and so are the intrinsics");
	t.assertseq(ev(a, "x"), "a", "the other keeps its own");
	a->shutdown();
	b->shutdown();
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	if(testing == nil || jslex == nil || jsparse == nil) {
		sys->fprint(sys->fildes(2), "js_engine_test: cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	jslex->init();
	jsparse->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	run("Values", testValues);
	run("Control", testControl);
	run("Lazy", testLazy);
	run("Jit", testJit);
	run("Errors", testErrors);
	run("Jobs", testJobs);
	run("HostFunctions", testHostFunctions);
	run("RealmsApart", testRealmsApart);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
