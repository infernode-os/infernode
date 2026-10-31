implement FltfmtTest;

#
# A REAL formatted and parsed as text: Limbo's sprint with %g, %f and
# %e, string of a real, and real of a string.
#
# On the bare-metal kernel every one of these printed garbage -- 70.0
# as 4.15e-322, 37.81 under %.6f as 0.000000 -- with the JIT and
# without it. A double passed to a variadic C function travels in a
# vector register, and the kernel's snprint was compiled
# -mgeneral-regs-only, so va_start never saved it for the %g converter
# to read (os/port/printfp.c). Matrix's geo-demo writes positions with
# %.6f and reads them back, and on those numbers it spun holding the
# VM. The hosted emulator was always right, which is why nothing
# caught it; this test runs on both.
#
# The last case passes nine reals to one sprint: AAPCS64 has eight
# vector argument registers, so the ninth goes on the stack, the
# other path through va_arg.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

FltfmtTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/fltfmt_test.b";

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

testG(t: ref T)
{
	t.assertseq(sys->sprint("%g", 70.0), "70", "%g of 70.0");
	t.assertseq(sys->sprint("%g", 6.0), "6", "%g of 6.0");
	t.assertseq(sys->sprint("%g", 0.5), ".5", "%g of 0.5 (Inferno writes no leading zero)");
	t.assertseq(sys->sprint("%g", -2.25), "-2.25", "%g of -2.25");
}

testF(t: ref T)
{
	t.assertseq(sys->sprint("%.6f", 37.81), "37.810000", "%.6f of 37.81");
	t.assertseq(sys->sprint("%.6f", -122.41), "-122.410000", "%.6f of -122.41");
	t.assertseq(sys->sprint("%.2f", 3.14159), "3.14", "%.2f of 3.14159");
}

testE(t: ref T)
{
	t.assertseq(sys->sprint("%e", 1234.5), "1.234500e+03", "%e of 1234.5");
}

testString(t: ref T)
{
	t.assertseq(string 37.81, "37.81", "string of 37.81");
	t.assertseq(string 0.1, ".1", "string of 0.1 (no leading zero)");
	t.assertseq(string 1e10, "1e+10", "string of 1e10");
}

testParse(t: ref T)
{
	# compared as numbers, so this holds even if formatting is broken
	t.assert(real "37.810000" == 37.81, "real of \"37.810000\" is 37.81");
	t.assert(real "-122.410000" == -122.41, "real of \"-122.410000\" is -122.41");
	t.assert(real "1e3" == 1000.0, "real of \"1e3\" is 1000");
}

testRoundTrip(t: ref T)
{
	vals := array[] of {37.81000921721551, -122.41, 0.1, 1.0/3.0, 6.02214076e23, 1.5e-300};
	for(i := 0; i < len vals; i++){
		v := vals[i];
		s := string v;
		t.assert(real s == v, "real of string survives for " + s);
	}
}

testMixed(t: ref T)
{
	t.assertseq(sys->sprint("%d %g %s %.2f %bd", 1, 2.5, "x", 3.14159, big 7), "1 2.5 x 3.14 7",
		"ints, reals, a string and a big in one sprint");
}

testNine(t: ref T)
{
	t.assertseq(sys->sprint("%g %g %g %g %g %g %g %g %g",
		1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0),
		"1 2 3 4 5 6 7 8 9", "nine reals: the ninth is passed on the stack");
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

	run("G", testG);
	run("F", testF);
	run("E", testE);
	run("String", testString);
	run("Parse", testParse);
	run("RoundTrip", testRoundTrip);
	run("Mixed", testMixed);
	run("Nine", testNine);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
