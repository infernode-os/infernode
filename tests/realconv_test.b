implement RealconvTest;

#
# realconv_test - strings to reals and back (libmath/dtoa.c), alone and
# from several Progs at once.
#
# Found by disfuzz (tools/disfuzz) and the checks it led to:
#
#	real "4.9e-324" never returned: strtod's correction loop worked on
#	a value scaled by 2^53 and never settled on the least denormal, and
#	the whole VM stopped with it; limbo hung the same way on the
#	literal. real "2e-320" was -7.26e280.
#
#	1 and 100000 zeros, e-100000, is 1: it was infinity, the exponent
#	held at 19999 (for 16-bit ints).
#
#	Two Progs printing reals at once had them wrong: dtoa's Bigint free
#	list was shared with no lock, and Sys->print formats after release(),
#	so two host threads took the same Bigint. A real printed with %.17g
#	and read back was not itself 193 times in 200; with eight Progs the
#	list became a cycle and emu hung.
#
# Each expected value is the correctly rounded double (Python's float()).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "math.m";
	math: Math;

include "testing.m";
	testing: Testing;
	T: import testing;

RealconvTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/realconv_test.b";

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

# the double's bits, as hex
bits(r: real): string
{
	b := array[8] of byte;
	math->export_real(b, array[] of {r});
	s := "";
	for(i := 0; i < 8; i++)
		s += sys->sprint("%.2ux", int b[i]);
	return s;
}

Conv: adt {
	s:	string;
	want:	string;	# the double's bits, big-endian hex
};

convs(): array of Conv
{
	return array[] of {
	Conv("4.9e-324", "0000000000000001"),
	Conv("5e-324", "0000000000000001"),
	Conv("3e-324", "0000000000000001"),
	Conv("2.4703282292062328e-324", "0000000000000001"),	# just over half the least: up
	Conv("2.4703282292062327e-324", "0000000000000000"),	# just under: 0
	Conv("1e-323", "0000000000000002"),
	Conv("2e-320", "0000000000000fd0"),
	Conv("1e-310", "000012688b70e62b"),
	Conv("2.2e-308", "000fd1d7d505cd02"),
	Conv("2.2250738585072014e-308", "0010000000000000"),	# the least normal
	Conv("2.225073858507201e-308", "000fffffffffffff"),	# the greatest denormal
	Conv("1e-400", "0000000000000000"),
	Conv("1.7976931348623157e308", "7fefffffffffffff"),
	Conv("1e309", "7ff0000000000000"),
	Conv("0.30000000000000004", "3fd3333333333334"),
	Conv("123456789012345678901234567890123456789012345678901e-50", "3ff3c0ca428c59fb"),
	};
}

testConvert(t: ref T)
{
	c := convs();
	for(i := 0; i < len c; i++)
		t.assertseq(bits(real c[i].s), c[i].want, c[i].s);
	# the same through the compiler: limbo reads the literal with strtod
	t.assertseq(bits(4.9e-324), "0000000000000001", "the literal 4.9e-324");
	t.assertseq(bits(2e-320), "0000000000000fd0", "the literal 2e-320");
}

# 1 and n zeros, e-n: 1
testLongDigits(t: ref T)
{
	for(n := 10; n <= 100000; n *= 10){
		s := "1";
		z := "0000000000";
		for(i := 0; i < n/10; i++)
			s += z;
		s += sys->sprint("e-%d", n);
		t.assertseq(bits(real s), "3ff0000000000000", sys->sprint("1, %d zeros, e-%d", n, n));
	}
	t.assertseq(bits(real "1e-99999999999"), "0000000000000000", "1e-99999999999");
	t.assertseq(bits(real "1e99999999999"), "7ff0000000000000", "1e99999999999");
}

# %f writes every digit before the point: 309 for the largest real.
# gfltconv formatted into 64 bytes on the emulator's stack and wrote the
# rest past them (sprint("%f", 1e300) ended emu: "stack smashing
# detected"; where nothing detects it, digits over the C stack).  Each
# expected string is Python's.
testLargeF(t: ref T)
{
	t.assertseq(sys->sprint("%f", 1e300), "1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000", "%f of 1e300");
	t.assertseq(sys->sprint("%f", -1.5e300), "-1500000000000000078757140382806630373056702871662238732373781173267703686983362293679557062620671796065556665749325817265413784853040645863467188277180060474272580801389863705606745350692182135089053429852456199917621678558451461320111979114170213741868888183230085264257173504208294580298189100810240.000000", "%f of -1.5e300");
	t.assertseq(sys->sprint("%.20f", 1.7976931348623157e308), "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.00000000000000000000", "%.20f of 1.7976931348623157e308");
	t.assertseq(sys->sprint("%.3f", 123456789012345678901234567890.0), "123456789012345677877719597056.000", "%.3f of 123456789012345678901234567890.0");
	t.assertseq(sys->sprint("%.0f", 1e23), "99999999999999991611392", "%.0f of 1e23");
	t.assertseq(sys->sprint("%f", 0.5), "0.500000", "%f of 0.5");
	t.assertseq(sys->sprint("%f", 1e-300), "0.000000", "%f of 1e-300");
	# with a width and flags: still the whole number
	s := sys->sprint("%+400.2f|%-330f|", 1e300, 1e300);
	t.asserteq(len s, 400 + 1 + 330 + 1, "padded to its width");
	# in the middle of other things, and many times over
	for(i := 0; i < 200; i++){
		x := 1e300 / real (i + 1);
		u := sys->sprint("a%fb%.20fc", x, -x);
		if(len u < 600 || u[0] != 'a' || u[len u - 1] != 'c'){
			t.error(sys->sprint("1e300/%d: %d bytes", i + 1, len u));
			break;
		}
		if(real sys->sprint("%.3f", x) != x){
			t.error(sys->sprint("1e300/%d printed with %%f does not read back", i + 1));
			break;
		}
	}
	# through the other verbs, as before
	t.assertseq(sys->sprint("%g %e %.3e %.10g", 1e300, 1e300, 1.5e300, 1e300), "1e+300 1.000000e+300 1.500e+300 1e+300", "%g and %e of 1e300");
	t.assertseq(sys->sprint("%f %g %.2f", real "1e999", -real "1e999", real "1e999" - real "1e999"), "Infinity -Infinity NaN", "what is no number, by name");
}

worker(id, n: int, done: chan of int)
{
	bad := 0;
	r := 1.0 / real (id + 3);
	for(i := 0; i < n; i++){
		x := r * 1e300 / real (i + 1);
		s := sys->sprint("%.17g %.30e", x, x * 1e-310);
		y := real sys->sprint("%.17g", x);
		if(y != x || len s == 0)
			bad++;
	}
	done <-= bad;
}

# reals printed and read back from Progs running at once
testConcurrent(t: ref T)
{
	np := 6;
	done := chan of int;
	for(i := 0; i < np; i++)
		spawn worker(i, 400, done);
	timeout := chan of int;
	spawn timer(timeout, 60000);
	bad := 0;
	for(i = 0; i < np; i++)
		alt {
		b := <-done =>
			bad += b;
		<-timeout =>
			t.fatal("Progs printing reals did not finish in 60s");
		}
	t.asserteq(bad, 0, "reals printed and read back from six Progs at once");
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Convert", testConvert);
	run("LongDigits", testLongDigits);
	run("LargeF", testLargeF);
	run("Concurrent", testConcurrent);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
