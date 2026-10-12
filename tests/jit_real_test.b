implement JitRealTest;

#
# Arithmetic, comparison, conversion, negation and moves of reals give
# from compiled code what the interpreter (xec.c) gives.
#
# The amd64 JIT sent every real operation but movf and negf to the
# interpreter, and did those two through the x87 with an FNINIT each;
# they are compiled to SSE2 now.  These are the cases that differ if a
# JIT gets them wrong: the operand order of - and / (F(d) = F(m) op
# F(s)); a NaN, which no comparison but != is true of; the signed zeros;
# the conversions' rounding (half away from zero, f < 0 ? f - .5 : f +
# .5, then truncated, and an int's low 32 bits); the sign negation flips
# on a NaN and a zero; and a signalling NaN's payload, which a move
# through the x87 quietened.
#
# Every operand is read from an array at run time, so the compiler
# cannot fold it.  Run under -c1 to test a JIT; under -c0 it pins the
# interpreter's behaviour the JIT must match.  tests/host/jit_real_test.sh
# runs both.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "math.m";
	math: Math;

include "testing.m";
	testing: Testing;
	T: import testing;

JitRealTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_real_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# the operands, read at run time
v: array of real;
ONE, TWO, THREE, HALF, PZERO, NZERO, NAN, INF, TENTH, FIFTH, SIX: con iota;

bits(x: real): big
{
	return math->realbits64(x);
}

# x's bits are want's
sameb(t: ref T, x: real, want: big, what: string)
{
	if(bits(x) != want)
		t.error(sys->sprint("%s: bits %bux, want %bux", what, bits(x), want));
}

testArith(t: ref T)
{
	sameb(t, v[TENTH] + v[FIFTH], big 16r3FD3333333333334, "0.1 + 0.2");
	sameb(t, v[ONE] - v[THREE], math->realbits64(-2.0), "1 - 3 (the operands in order)");
	sameb(t, v[SIX] / v[THREE], math->realbits64(2.0), "6 / 3 (the operands in order)");
	sameb(t, v[THREE] * v[HALF], math->realbits64(1.5), "3 * 0.5");
	sameb(t, v[ONE] / v[PZERO], big 16r7FF0000000000000, "1 / +0");
	sameb(t, v[ONE] / v[NZERO], big 16rFFF0000000000000, "1 / -0");
	sameb(t, v[NZERO] + v[PZERO], big 0, "-0 + +0");
	sameb(t, v[NZERO] * v[NZERO], big 0, "-0 * -0");
	t.assert(isnan(v[INF] - v[INF]), "Inf - Inf is a NaN");
	t.assert(isnan(v[PZERO] / v[PZERO]), "0 / 0 is a NaN");
	# a result kept in an operand: d = d op s
	y := v[ONE];
	for(i := 0; i < 3; i++)
		y = y + v[HALF];
	sameb(t, y, math->realbits64(2.5), "1 + .5 + .5 + .5, accumulated");
}

# by its bits: limbo folds x != x, so that cannot tell
isnan(x: real): int
{
	b := bits(x);
	return (b & big 16r7FF0000000000000) == big 16r7FF0000000000000 && (b & big 16rFFFFFFFFFFFFF) != big 0;
}

# What each comparison of a and b gives, as the interpreter has it.
# limbo compiles if(a < b) as a branch on the inverse (bgef) past the
# then part, so with a NaN, which no ordered comparison is true of, the
# then part runs: the answers below are the interpreter's, which a JIT
# must give too (its bgef false for a NaN, as C's >= is).
cmp(a, b: real): string
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

testCompare(t: ref T)
{
	t.assertseq(cmp(v[ONE], v[TWO]), "<l...!", "1 ? 2");
	t.assertseq(cmp(v[TWO], v[ONE]), "..>g.!", "2 ? 1");
	t.assertseq(cmp(v[ONE], v[ONE]), ".l.g=.", "1 ? 1");
	t.assertseq(cmp(v[NAN], v[ONE]), "<l>g.!", "NaN ? 1 (the inverse branches not taken)");
	t.assertseq(cmp(v[ONE], v[NAN]), "<l>g.!", "1 ? NaN");
	t.assertseq(cmp(v[NAN], v[NAN]), "<l>g.!", "NaN ? NaN");
	t.assertseq(cmp(v[NZERO], v[PZERO]), ".l.g=.", "-0 ? +0");
	t.assertseq(cmp(v[INF], v[ONE]), "..>g.!", "Inf ? 1");
	# a loop on a real compare: taken, not taken, and the count right
	n := 0;
	for(x := v[PZERO]; x < v[THREE]; x += v[HALF])
		n++;
	t.asserteq(n, 6, "0 to 3 by .5");
}

testConvert(t: ref T)
{
	h := array[] of {0.5, -0.5, 1.5, 2.5, -2.5, 0.49999999999999994, -0.25, 2147483647.6, -7.75, 1e10};
	wi := array[] of {1, -1, 2, 3, -3, 1, 0, -2147483647-1, -8, 1410065408};
	wb := array[] of {big 1, big -1, big 2, big 3, big -3, big 1, big 0, big 2147483648, big -8, big 10000000000};
	for(i := 0; i < len h; i++) {
		t.asserteq(int h[i], wi[i], sys->sprint("int %g", h[i]));
		if(big h[i] != wb[i])
			t.error(sys->sprint("big %g: %bd, want %bd", h[i], big h[i], wb[i]));
	}
	t.asserteq(int v[NZERO], 0, "int -0");
	t.asserteq(int v[NAN], 0, "int NaN (what the interpreter gives)");
	ints := array[] of {-7, 0, 2147483647, -2147483647-1};
	for(i = 0; i < len ints; i++)
		sameb(t, real ints[i], math->realbits64(real ints[i]), sys->sprint("real %d", ints[i]));
	t.assert(real ints[0] == -7.0, "real -7");
	b := (big 1 << 53) + big 1;
	sameb(t, real b, big 16r4340000000000000, "real 2^53+1 (rounded to even)");
	t.assert(real (big -3) == -3.0, "real big -3");
}

testNegate(t: ref T)
{
	sameb(t, -v[PZERO], big 16r8000000000000000, "-(+0)");
	sameb(t, -v[NZERO], big 0, "-(-0)");
	sameb(t, -v[HALF], math->realbits64(-0.5), "-(0.5)");
	n := v[NAN];
	sameb(t, -n, bits(n) ^ big 16r8000000000000000, "-NaN: the sign flipped");
}

testMove(t: ref T)
{
	snan := math->bits64real(big 16r7FF0000000000001);	# a signalling NaN
	a := array[2] of real;
	a[0] = snan;
	a[1] = a[0];
	x := a[1];
	sameb(t, x, big 16r7FF0000000000001, "a signalling NaN moved");
	sameb(t, a[1], big 16r7FF0000000000001, "a signalling NaN stored");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || math == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing or math: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	v = array[] of {1.0, 2.0, 3.0, 0.5, 0.0, -0.0, Math->NaN, Math->Infinity, 0.1, 0.2, 6.0};
	if(math->realbits64(v[NZERO]) != big 16r8000000000000000)
		v[NZERO] = -v[PZERO];	# (in case the constant lost its sign)

	run("Arith", testArith);
	run("Compare", testCompare);
	run("Convert", testConvert);
	run("Negate", testNegate);
	run("Move", testMove);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
