implement LimboFoldTest;

#
# limbo_fold_test - constants the compiler folds, and calls it inlines,
# come out as the VM computes them. disfuzz (tools/disfuzz) found each:
#
#	big ** 0 was folded to an int 1, and a big operation using it took
#	an immediate source operand, which compiled code read as an address
#	(dereference of nil); f() ** 0 did not call f.
#	3 ** (-2147483647-1) hung limbo: the exponent negated as an int.
#	The most negative big over -1, or mod -1, folded by C's division:
#	limbo died of SIGFPE.
#	A function returning nil was inlined as an untyped nil: len, tl and
#	an index of the call were fatal compiler errors, or a fault.
#	4.9e-324 as a literal hung limbo (strtod; see realconv_test).
#
# That this file compiles at all is half the test; the build compiles it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboFoldTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/limbo_fold_test.b";

passed := 0;
failed := 0;
skipped := 0;

gb: big;
ncalls := 0;

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

counted(): big
{
	ncalls++;
	return big 7;
}

testExpZero(t: ref T)
{
	gb = big 2;
	x := big 88129 % ((gb ** 0) | big 1);
	y := (gb ** 0) | big 16r100000000;
	z := gb ** 0;
	t.assert(x == big 0, "88129 % (big ** 0 | 1)");
	t.assert(y == big 16r100000001, "big ** 0 | 2^32");
	t.assert(z == big 1, "big ** 0");
	ncalls = 0;
	w := counted() ** 0;
	t.assert(w == big 1, "f() ** 0");
	t.asserteq(ncalls, 1, "f() ** 0 calls f");
}

testFolds(t: ref T)
{
	a := 3 ** (-2147483647-1);
	t.asserteq(a, 0, "3 ** most negative int");
	r := 2.0 ** (-2147483647-1);
	t.assert(r == 0.0, "2.0 ** most negative int");
	q := (-16r7fffffffffffffff-big 1) / big -1;
	m := (-16r7fffffffffffffff-big 1) % big -1;
	t.assert(q == -16r7fffffffffffffff-big 1, "most negative big / -1 wraps");
	t.assert(m == big 0, "most negative big % -1");
	t.asserteq(7 / -1, -7, "7 / -1");
	t.assert(4.9e-324 > 0.0, "4.9e-324 is the least denormal, not 0");
}

nl(): list of int { return nil; }
nai(): array of int { return nil; }

testInlinedNil(t: ref T)
{
	t.asserteq(len nl(), 0, "len of an inlined nil list");
	t.asserteq(len nai(), 0, "len of an inlined nil array");
	got := "";
	{
		l := tl nl();
		got = sys->sprint("%d", len l);
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "dereference of nil", "tl of an inlined nil");
	got = "";
	{
		got = sys->sprint("%d", (nai())[5]);
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "array bounds error", "an index of an inlined nil array");
	t.asserteq(hd (1 :: nl()), 1, "hd of a cons onto an inlined nil");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ExpZero", testExpZero);
	run("Folds", testFolds);
	run("InlinedNil", testInlinedNil);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
