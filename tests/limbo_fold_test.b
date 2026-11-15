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

# Not folds, but the same operators at run time: zero to a negative
# power is "zero divide" (the compiler refuses it of constants; the VM
# computed 1/0 in C), a power that wraps to nothing and is then inverted
# is 0, and a fixed-point divide by zero is "zero divide" too (it was the
# host's own trap, or none).
Fa: type fixed(0.01, 100.0);
Fb: type fixed(2.0**-8, 1000.0);
Fc: type fixed(0.003, 50.0);

ev := array[] of {0, -1, 2, -40, -64, 1, 3};
e(i: int): int { return ev[i]; }

raised(i: int): string
{
	{
		case i {
		0 =>
			return string (e(0) ** e(1));
		1 =>
			return string (big e(0) ** e(1));
		2 =>
			return string (e(2) ** e(3));
		3 =>
			return string (big e(2) ** e(4));
		4 =>
			return string (e(5) ** e(1));
		5 =>
			return string (e(1) ** e(1));
		6 =>
			return string (e(6) ** e(1));
		7 =>
			return string int (Fa 1.0 / Fa real e(0));
		8 =>
			return string int (Fb 1.0 / Fb real e(0));
		9 =>
			return string int (Fc 1.0 / Fc real e(0));
		10 =>
			return string int (Fa 6.0 / Fa real e(2));
		}
	} exception ex {
	"*" =>
		return "raised: " + ex;
	}
	return "?";
}

testZeroPowerAndFixedDivide(t: ref T)
{
	t.assertseq(raised(0), "raised: zero divide", "0 ** -1");
	t.assertseq(raised(1), "raised: zero divide", "big 0 ** -1");
	t.assertseq(raised(2), "0", "2 ** -40");
	t.assertseq(raised(3), "0", "big 2 ** -64");
	t.assertseq(raised(4), "1", "1 ** -1");
	t.assertseq(raised(5), "-1", "-1 ** -1");
	t.assertseq(raised(6), "0", "3 ** -1");
	t.assertseq(raised(7), "raised: zero divide", "a fixed(0.01) divide by zero");
	t.assertseq(raised(8), "raised: zero divide", "a fixed(2**-8) divide by zero");
	t.assertseq(raised(9), "raised: zero divide", "a fixed(0.003) divide by zero");
	t.assertseq(raised(10), "3", "a fixed divide still divides");
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
	run("ZeroPowerAndFixedDivide", testZeroPowerAndFixedDivide);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
