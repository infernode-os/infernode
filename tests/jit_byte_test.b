implement JitByteTest;

#
# jit_byte_test - byte divide and remainder give from compiled code what
# the interpreter gives. tests/host/jit_byte_test.sh runs this under -c0
# and -c1.
#
# The amd64 JIT compiled divb and modb as cdq and the 8-bit idiv, which
# divides AX: AH was whatever RAX held before, so an earlier value's bits
# (a real converted just before) made 0 % 1 overflow the quotient, and
# that was raised as a zero divide; the divide was signed (255/200 was
# -4); and modb took EDX, the sign of EAX, for the remainder, so x % y
# was 0 (or 255) for nearly every x and y. disfuzz (tools/disfuzz) found
# it: the same program printed "dereference of nil" under -c0 and "zero
# divide" under -c1.
#
# Each byte result is checked against the same operation on int, which
# compiles to a different instruction (divw, modw) under both modes.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitByteTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_byte_test.b";

passed := 0;
failed := 0;
skipped := 0;

# module data, so the compiler folds nothing
big1: real;
gx, gy: byte;

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

# every dividend, every divisor but 0
testDivMod(t: ref T)
{
	bad := 0;
	for(i := 0; i < 256; i++)
	for(j := 1; j < 256; j++){
		a := byte i;
		b := byte j;
		q := a / b;
		r := a % b;
		if(int q != i / j || int r != i % j){
			if(bad++ < 5)
				t.error(sys->sprint("%d/%d: got %d %% %d, want %d %% %d", i, j, int q, int r, i / j, i % j));
		}
	}
	t.asserteq(bad, 0, "byte / and % over every pair");
}

# x /= y and x %= y: the destination is the left operand
testAssignOps(t: ref T)
{
	for(i := 0; i < 256; i += 3)
	for(j := 1; j < 256; j += 7){
		x := byte i;
		x /= byte j;
		y := byte i;
		y %= byte j;
		if(int x != i / j || int y != i % j)
			t.error(sys->sprint("%d op= %d: got %d %d, want %d %d", i, j, int x, int y, i / j, i % j));
	}
}

# what RAX held before the divide is not the dividend's: a real converted
# to a byte leaves its upper bits there
testHighBits(t: ref T)
{
	big1 = 4.159578277903125e14;
	gx = byte 0;
	gy = byte 0;
	{
		v := (gx % (gy | byte 1)) * byte big1;
		t.asserteq(int v, 0, "0 % 1 after a real's bits");
		w := (byte 200 + gx) / (gy | byte 7) + byte big1 * byte 0;
		t.asserteq(int w, 28, "200 / 7 after a real's bits");
	} exception e {
	"*" =>
		t.error("raised " + e);
	}
}

testZero(t: ref T)
{
	z := gy;	# 0
	got := "";
	{
		x := byte 9 / z;
		got = sys->sprint("%d", int x);
	} exception e {
	"zero divide" =>
		got = e;
	}
	t.assertseq(got, "zero divide", "byte / 0");
	got = "";
	{
		x := byte 9 % z;
		got = sys->sprint("%d", int x);
	} exception e {
	"zero divide" =>
		got = e;
	}
	t.assertseq(got, "zero divide", "byte % 0");
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

	run("DivMod", testDivMod);
	run("AssignOps", testAssignOps);
	run("HighBits", testHighBits);
	run("Zero", testZero);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
