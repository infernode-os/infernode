implement NanTest;

#
# NaN and infinity in the kernel's own VM: math->isnan, the canonical NaN
# the Limbo compiler checks at startup, and reals of "NaN" and "Inf".
#
# libkernfp/nan.c took a double apart as two longs, which on an LP64
# kernel (arm64, riscv64) are two 64-bit words: isNaN read the bytes past
# the double, so it never saw a NaN, and NaN() and Inf() built a denormal
# and a zero. limbo.dis, run on a board, died at once with "bad canonical
# NaN". The hosted emulator uses the C library's and was always right;
# like fltfmt_test, this is a test for a kernel run.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "testing.m";
	testing: Testing;
	T: import testing;

NanTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/nan_test.b";

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

testIsnan(t: ref T)
{
	t.assert(math->isnan(Math->NaN) != 0, "isnan(NaN)");
	t.assert(math->isnan(1.5) == 0, "isnan(1.5) is false");
	t.assert(math->isnan(Math->Infinity) == 0, "isnan(Infinity) is false");
	t.assert(math->isnan(0.0) == 0, "isnan(0.0) is false");
}

testCanonical(t: ref T)
{
	# exactly what limbo.b does before it compiles anything
	na := array[1] of {0.};
	math->import_real(array[8] of {byte 16r7f, * => byte 16rff}, na);
	t.assert(math->isnan(na[0]) != 0, "the canonical NaN 7fffffffffffffff is a NaN");
}

testStrings(t: ref T)
{
	n := real "NaN";
	t.assert(math->isnan(n) != 0, "real \"NaN\" is a NaN");
	# the round trip: what string prints, real must read back. The
	# kernel prints infinity as "+Inf" and used to read only "Infinity"
	s := string Math->Infinity;
	i := real s;
	t.assert(i > 1e308, "real (string Infinity) is infinite: " + s + " read back as " + string i);
	t.assert(math->finite(i) == 0, "real (string Infinity) is not finite");
	m := real string (-Math->Infinity);
	t.assert(m < -1e308, "real (string -Infinity) is below -1e308: got " + string m);
	for(l := "Inf" :: "inf" :: "Infinity" :: "+Inf" :: nil; l != nil; l = tl l)
		t.assert(real hd l > 1e308, "real \"" + hd l + "\" is infinite");
	t.assert(math->isnan(real string Math->NaN) != 0, "real (string NaN) is a NaN");
}

testExport(t: ref T)
{
	b := array[8] of byte;
	math->export_real(b, array[1] of {Math->Infinity});
	s := "";
	for(i := 0; i < 8; i++)
		s += sys->sprint("%.2x", int b[i]);
	t.assertseq(s, "7ff0000000000000", "Infinity's bits");
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(math == nil || testing == nil){
		sys->fprint(sys->fildes(2), "nan_test: cannot load math or testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	run("Isnan", testIsnan);
	run("Canonical", testCanonical);
	run("Strings", testStrings);
	run("Export", testExport);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
