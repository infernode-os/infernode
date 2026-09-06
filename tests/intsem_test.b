implement IntsemTest;

#
# Limbo int is 32 bits, whatever the size of the VM's word. On a
# 64-bit VM an int lives in a 64-bit slot, and every result has to be
# stored sign-extended or a value that prints as -1 is not equal to
# -1: that was a dossrv wstat that ignored nulldir, and an MPEG
# escape level that would not sign-extend. These cases are computed
# at run time from values the compiler cannot fold, so they exercise
# the interpreter and the JIT, not the constant folder. Run under
# both: emu -c0 and emu -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

IntsemTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/intsem_test.b";

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

# Values the compiler cannot see through.
ff := byte 16rff;
one := 1;
b24 := 24;
b31 := 31;
big1 := big 1;
MININT: con -2147483647 - 1;

testBytesToMinusOne(t: ref T)
{
	a := array[4] of { * => ff };
	y := (((((int a[3] << 8) | int a[2]) << 8) | int a[1]) << 8) | int a[0];
	t.asserteq(y, -1, "four 0xff bytes assemble to -1");
	t.assert(y == -1, "and compare equal to -1");
	t.assert(y == ~0, "and to ~0");
	t.assert(big y == big -1, "and widen to big -1");
	t.asserteq(y + one, 0, "-1 + 1 is 0");
}

testShiftSignExtends(t: ref T)
{
	x := 16r80;				# a byte with its top bit set
	t.asserteq((x << b24) >> b24, -128, "(x<<24)>>24 sign-extends a byte");
	t.assert((x << b24) < 0, "x<<24 is negative");
	t.asserteq(one << b31, MININT, "1<<31 is the minimum int");
	t.assert((one << b31) < 0, "and negative");
}

testWraparound(t: ref T)
{
	m := 2147483647;
	t.asserteq(m + one, MININT, "max int + 1 wraps to min int");
	t.assert(m + one < 0, "and is negative");
	n := MININT;
	t.asserteq(n - one, 2147483647, "min int - 1 wraps to max int");
	t.asserteq(m * 2 / 2, -1, "max int * 2 wraps");
	t.asserteq(65536 * 65536, 0, "2^32 as an int is 0");
	t.asserteq(n / -one, n, "min int / -1 wraps, no trap");
	t.asserteq(n % -one, 0, "min int % -1 is 0");
}

testArithmeticShift(t: ref T)
{
	x := -256;
	t.asserteq(x >> b24, -1, "arithmetic shift of a negative keeps the sign");
	t.asserteq(x >> one, -128, "-256 >> 1 is -128");
	t.asserteq((x << b24) >> b24, 0, "-256<<24 loses its bits; back is 0");
	y := 16r7f;
	t.asserteq((y << b24) >> b24, 127, "(0x7f<<24)>>24 is 127");
}

testBigAndBack(t: ref T)
{
	v := big 16rffffffff;
	t.asserteq(int v, -1, "int of big 0xffffffff is -1");
	t.assert(int v == -1, "and compares equal");
	w := big 16r100000000 + big1;
	t.asserteq(int w, 1, "int truncates to the low 32 bits");
	r := 4294967295.0;
	t.asserteq(int r, -1, "int of a real 2^32-1 is -1");
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

	run("BytesToMinusOne", testBytesToMinusOne);
	run("ShiftSignExtends", testShiftSignExtends);
	run("Wraparound", testWraparound);
	run("ArithmeticShift", testArithmeticShift);
	run("BigAndBack", testBigAndBack);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
