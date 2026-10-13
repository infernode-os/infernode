implement JitBigTest;

#
# jit_big_test - big multiply, divide and remainder, and the head of a
# list of big, give from compiled code what the interpreter gives.
#
# The amd64 JIT punted mull, divl, modl and headl to the interpreter;
# it compiles them now, as imul, idiv (the remainder from rdx) and a
# load. tests/host/jit_big_test.sh runs this under -c0 and -c1.
#
# Covered: signs (division truncates, the remainder takes the dividend's
# sign), values past 32 bits, a product that wraps, the three-operand
# and two-operand (x *= y) forms, a zero divisor for / and % (in a
# function called from compiled code, caught by its own handler), and
# the most negative big over -1, which overflows: it wraps, with no
# exception, under -c0 and -c1 alike (x86's idiv would trap on it).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitBigTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_big_test.b";

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

Arith: adt {
	a, b:	big;
	prod, quo, rem:	big;
};

arithcases(): array of Arith
{
	mn := big 1 << 63;
	return array[] of {
	Arith(big 7, big 3, big 21, big 2, big 1),
	Arith(-big 7, big 3, -big 21, -big 2, -big 1),
	Arith(big 7, -big 3, -big 21, -big 2, big 1),
	Arith(-big 7, -big 3, big 21, big 2, -big 1),
	Arith(big 0, big 5, big 0, big 0, big 0),
	Arith(big 1, big 1, big 1, big 1, big 0),
	Arith(big 123456789012345, big 987, big 121851850755184515, big 125082866273, big 894),
	Arith(-big 123456789012345, big 987, -big 121851850755184515, -big 125082866273, -big 894),
	Arith(big 9223372036854775807, big 2, -big 2, big 4611686018427387903, big 1),
	Arith(mn, big 2, big 0, -big 4611686018427387904, big 0),
	Arith(mn, big 1, mn, mn, big 0),
	Arith(big 4294967296, big 4294967296, big 0, big 1, big 0),
	Arith(big 9223372036854775807, big 9223372036854775807, big 1, big 1, big 0),
	Arith(big 3037000500, big 3037000500, -big 9223372036709301616, big 1, big 0),
	Arith(-big 1, -big 1, big 1, big 1, big 0),
	Arith(big 81985529216486895, big 16, big 1311768467463790320, big 5124095576030430, big 15),
	Arith(big 5, big 9223372036854775807, big 9223372036854775803, big 0, big 5),
	Arith(-big 5, mn, mn, big 0, -big 5),
	Arith(big 5, -big 1, -big 5, -big 5, big 0),
	Arith(mn, -big 1, mn, mn, big 0)
	};
}

assertbig(t: ref T, got, want: big, what: string)
{
	if(got != want)
		t.error(sys->sprint("%s: got %bd, want %bd", what, got, want));
}

testArith(t: ref T)
{
	c := arithcases();
	for(i := 0; i < len c; i++){
		a := c[i].a;
		b := c[i].b;
		what := sys->sprint("%bd, %bd", a, b);
		assertbig(t, a * b, c[i].prod, what + ": *");
		assertbig(t, a / b, c[i].quo, what + ": /");
		assertbig(t, a % b, c[i].rem, what + ": %");
	}
}

# x op= y: the destination is the left operand
testAssignOps(t: ref T)
{
	c := arithcases();
	for(i := 0; i < len c; i++){
		what := sys->sprint("%bd, %bd", c[i].a, c[i].b);
		x := c[i].a;
		x *= c[i].b;
		assertbig(t, x, c[i].prod, what + ": *=");
		x = c[i].a;
		x /= c[i].b;
		assertbig(t, x, c[i].quo, what + ": /=");
		x = c[i].a;
		x %= c[i].b;
		assertbig(t, x, c[i].rem, what + ": %=");
	}
}

# Operands from the frame, the module data and a constant.
gb := big 1000007;
testOperandKinds(t: ref T)
{
	x := big 123456789123;
	assertbig(t, x * gb, big 123457653320523861, "frame * module");
	assertbig(t, x / gb, big 123455, "frame / module");
	assertbig(t, x % gb, big 924938, "frame % module");
	assertbig(t, x * big 3, big 370370367369, "frame * constant");
	assertbig(t, x / big 1000, big 123456789, "frame / constant");
	assertbig(t, x % big 1000, big 123, "frame % constant");
}

divide(a, b: big, op: int): (big, string)
{
	{
		if(op == '/')
			return (a / b, nil);
		return (a % b, nil);
	} exception e {
	"*" =>
		return (big 0, e);
	}
}

testZeroDivide(t: ref T)
{
	for(l := big 0 :: big 5 :: -big 5 :: (big 1 << 63) :: nil; l != nil; l = tl l){
		(nil, e) := divide(hd l, big 0, '/');
		t.assertseq(e, "zero divide", sys->sprint("%bd / 0", hd l));
		(nil, e) = divide(hd l, big 0, '%');
		t.assertseq(e, "zero divide", sys->sprint("%bd %% 0", hd l));
	}
}

testMinOverMinusOne(t: ref T)
{
	mn := big 1 << 63;
	(q, e) := divide(mn, -big 1, '/');
	t.assertnil(e, "most negative big / -1 raises nothing");
	assertbig(t, q, mn, "most negative big / -1");
	(q, e) = divide(mn, -big 1, '%');
	t.assertnil(e, "most negative big % -1 raises nothing");
	assertbig(t, q, big 0, "most negative big % -1");
}

testHeadOfBigs(t: ref T)
{
	mn := big 1 << 63;
	l := big 0 :: big 16r123456789abcdef0 :: -big 1 :: mn :: big 16r7fffffffffffffff :: nil;
	want := array[] of {big 0, big 16r123456789abcdef0, -big 1, mn, big 16r7fffffffffffffff};
	for(i := 0; l != nil; l = tl l)
		assertbig(t, hd l, want[i++], sys->sprint("hd of element %d", i));
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

	run("Arith", testArith);
	run("AssignOps", testAssignOps);
	run("OperandKinds", testOperandKinds);
	run("ZeroDivide", testZeroDivide);
	run("MinOverMinusOne", testMinOverMinusOne);
	run("HeadOfBigs", testHeadOfBigs);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
