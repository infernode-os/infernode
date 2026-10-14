implement LimboNanTest;

#
# The compiler's comparisons of reals with a NaN, which is in no order:
# no comparison but != is true of it, itself included (IEEE 754, and C).
#
# limbo compiled if(a < b) as a branch on the inverse comparison (bgef)
# past the then part, and the value of a < b the same way, so with a NaN
# every ordered comparison came out true; and it folded x == x, x <= x
# and x >= x to 1, x != x and x - x to 0, which a NaN (and Inf - Inf)
# makes wrong.  Both since the 2006 import of Inferno.  An ordered
# comparison of reals now branches on itself past a jump, and only
# x < x and x > x are folded for reals.
#
# Every operand is read from an array at run time, so the compiler
# cannot fold it, but where the folding of x op x is what is tested.
# tests/host/limbo_nan_test.sh runs it under -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboNanTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/limbo_nan_test.b";

passed := 0;
failed := 0;
skipped := 0;

v: array of real;
ONE, TWO, NAN, INF, ZERO: con iota;

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

# each comparison in a branch: if(a op b)
branches(a, b: real): string
{
	s := "";
	if(a < b) s += "<"; else s += ".";
	if(a <= b) s += "l"; else s += ".";
	if(a > b) s += ">"; else s += ".";
	if(a >= b) s += "g"; else s += ".";
	if(a == b) s += "="; else s += ".";
	if(a != b) s += "!"; else s += ".";
	return s;
}

# each comparison's value
values(a, b: real): string
{
	r := array[] of {a < b, a <= b, a > b, a >= b, a == b, a != b};
	s := "";
	for(i := 0; i < len r; i++)
		s += string r[i];
	return s;
}

# each comparison negated: if(!(a op b))
negated(a, b: real): string
{
	s := "";
	if(!(a < b)) s += "<"; else s += ".";
	if(!(a <= b)) s += "l"; else s += ".";
	if(!(a > b)) s += ">"; else s += ".";
	if(!(a >= b)) s += "g"; else s += ".";
	if(!(a == b)) s += "="; else s += ".";
	if(!(a != b)) s += "!"; else s += ".";
	return s;
}

testBranches(t: ref T)
{
	t.assertseq(branches(v[ONE], v[TWO]), "<l...!", "1 ? 2");
	t.assertseq(branches(v[TWO], v[ONE]), "..>g.!", "2 ? 1");
	t.assertseq(branches(v[ONE], v[ONE]), ".l.g=.", "1 ? 1");
	t.assertseq(branches(v[NAN], v[ONE]), ".....!", "NaN ? 1");
	t.assertseq(branches(v[ONE], v[NAN]), ".....!", "1 ? NaN");
	t.assertseq(branches(v[NAN], v[NAN]), ".....!", "NaN ? NaN");
	t.assertseq(branches(v[INF], v[NAN]), ".....!", "Inf ? NaN");
	t.assertseq(branches(v[INF], v[ONE]), "..>g.!", "Inf ? 1");
}

testValues(t: ref T)
{
	t.assertseq(values(v[ONE], v[TWO]), "110001", "1 ? 2");
	t.assertseq(values(v[TWO], v[ONE]), "001101", "2 ? 1");
	t.assertseq(values(v[ONE], v[ONE]), "010110", "1 ? 1");
	t.assertseq(values(v[NAN], v[ONE]), "000001", "NaN ? 1");
	t.assertseq(values(v[ONE], v[NAN]), "000001", "1 ? NaN");
	t.assertseq(values(v[NAN], v[NAN]), "000001", "NaN ? NaN");
}

testNegated(t: ref T)
{
	t.assertseq(negated(v[ONE], v[TWO]), "..>g=.", "!(1 ? 2)");
	t.assertseq(negated(v[ONE], v[ONE]), "<.>..!", "!(1 ? 1)");
	t.assertseq(negated(v[NAN], v[ONE]), "<l>g=.", "!(NaN ? 1)");
	t.assertseq(negated(v[ONE], v[NAN]), "<l>g=.", "!(1 ? NaN)");
}

testLogic(t: ref T)
{
	n := v[NAN];
	one := v[ONE];
	two := v[TWO];
	t.assert(!(n < one && one < two), "NaN < 1 && 1 < 2 is false");
	t.assert(one < two && !(n >= one), "1 < 2 && !(NaN >= 1)");
	t.assert(!(n < one || n > one), "NaN < 1 || NaN > 1 is false");
	t.assert(n < one || one < two, "NaN < 1 || 1 < 2 is true");
	t.assert(n != n || n < one, "NaN != NaN || ...");
	x := n <= one || n >= one;
	t.asserteq(x, 0, "the value of NaN <= 1 || NaN >= 1");
	y := !(n < one) && !(n > one);
	t.asserteq(y, 1, "the value of !(NaN < 1) && !(NaN > 1)");
	# else if chains
	s := "";
	if(n < one)
		s = "lt";
	else if(n > one)
		s = "gt";
	else if(n == one)
		s = "eq";
	else
		s = "unordered";
	t.assertseq(s, "unordered", "an else-if chain on NaN and 1");
}

testLoops(t: ref T)
{
	n := v[NAN];
	k := 0;
	while(n < v[TWO] && k < 10)
		k++;
	t.asserteq(k, 0, "while(NaN < 2) runs no times");
	k = 0;
	for(x := v[ONE]; x <= n && k < 10; x += v[ONE])
		k++;
	t.asserteq(k, 0, "for(x = 1; x <= NaN; ...) runs no times");
	k = 0;
	do
		k++;
	while(n >= v[ONE] && k < 10);
	t.asserteq(k, 1, "do ... while(NaN >= 1) runs once");
	k = 0;
	for(x = v[ZERO]; x < v[TWO]; x += v[ONE])
		k++;
	t.asserteq(k, 2, "for(x = 0; x < 2; x += 1) runs twice");
}

# x op x, which the compiler folds where it may
testSame(t: ref T)
{
	n := v[NAN];
	t.asserteq(n == n, 0, "NaN == NaN");
	t.asserteq(n != n, 1, "NaN != NaN");
	t.asserteq(n <= n, 0, "NaN <= NaN");
	t.asserteq(n >= n, 0, "NaN >= NaN");
	t.asserteq(n < n, 0, "NaN < NaN");
	t.asserteq(n > n, 0, "NaN > NaN");
	d := n - n;
	t.assert(d != d, "NaN - NaN is a NaN");
	i := v[INF];
	d = i - i;
	t.assert(d != d, "Inf - Inf is a NaN");
	o := v[ONE];
	t.asserteq(o == o, 1, "1 == 1");
	t.asserteq(o <= o, 1, "1 <= 1");
	t.asserteq(o != o, 0, "1 != 1");
	t.assert(o - o == 0.0, "1 - 1");
	if(n == n)
		t.error("if(NaN == NaN) taken");
	if(!(n != n))
		t.error("if(!(NaN != NaN)) taken");
}

# what is not a real is compared as it was
testOthers(t: ref T)
{
	a := array[] of {1, 2, -3};
	t.assertseq(sys->sprint("%d%d%d%d%d%d", a[0] < a[1], a[0] <= a[1], a[0] > a[1], a[0] >= a[1], a[0] == a[1], a[0] != a[1]), "110001", "ints");
	k := 0;
	for(i := a[2]; i < a[1]; i++)
		k++;
	t.asserteq(k, 5, "an int loop");
	b := array[] of {big 1, big -2};
	t.assert(b[1] < b[0] && b[0] >= b[1] && !(b[0] < b[1]), "bigs");
	s := array[] of {"abc", "abd"};
	t.assert(s[0] < s[1] && s[1] > s[0] && !(s[0] >= s[1]) && s[0] != s[1], "strings");
	t.assert(s[0] == s[0] && s[0] <= s[0], "a string with itself");
	x := a[0];
	t.assert(x == x && x <= x && !(x < x), "an int with itself");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	z := array[] of {0.0};
	v = array[] of {1.0, 2.0, z[0] / z[0], 1.0 / z[0], 0.0};

	run("Branches", testBranches);
	run("Values", testValues);
	run("Negated", testNegated);
	run("Logic", testLogic);
	run("Loops", testLoops);
	run("Same", testSame);
	run("Others", testOthers);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
