implement CaselTest;

#
# casel_test - the Dis `casel` instruction (case on big).
#
# The 64-bit limbo compiler emits casel tables in the icase layout
# (one pointer-sized word per entry, stride 3); the interpreter's
# OP(casel) and both JITs' comcasel used to walk the historical
# 32-bit stride-6 layout instead, so the FIRST module ever to use
# `case big` (ventisrv, INFR-355) hung the interpreter and crashed
# the JIT. Nothing else in the tree used the instruction — this test
# keeps it exercised under both -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

CaselTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/casel_test.b";

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

# mirrors ventisrv's offsetread dispatch — the code that surfaced the bug
magicname(v: big): string
{
	case v {
	big 16r2f9d81e5 =>
		return "dhdr";
	big 16r78c66a15 =>
		return "fhdr";
	* =>
		return "bad";
	}
}

# a wider table so the binary search takes both branches
# (`case big` allows single labels only — no ranges)
bucket(v: big): int
{
	case v {
	big -9000000000 =>
		return 0;
	big 0 =>
		return 1;
	big 99 =>
		return 2;
	big 16r100000000 =>
		return 3;
	big 16r7ffffffffffffffe =>
		return 4;
	* =>
		return 5;
	}
}

testMagics(t: ref T)
{
	t.assertseq(magicname(big 16r2f9d81e5), "dhdr", "first arm");
	t.assertseq(magicname(big 16r78c66a15), "fhdr", "second arm");
	t.assertseq(magicname(big 0), "bad", "default below");
	t.assertseq(magicname(big 16r7fffffffffffffff), "bad", "default above");
	t.assertseq(magicname(big 16r2f9d81e4), "bad", "just below first arm");
	t.assertseq(magicname(big 16r2f9d81e6), "bad", "just above first arm");
}

testRanges(t: ref T)
{
	t.asserteq(bucket(big -9000000000), 0, "negative label");
	t.asserteq(bucket(big 0), 1, "zero label");
	t.asserteq(bucket(big 99), 2, "small label");
	t.asserteq(bucket(big 98), 5, "just below small label");
	t.asserteq(bucket(big 100), 5, "just above small label");
	t.asserteq(bucket(big 16r100000000), 3, "value above 32 bits");
	t.asserteq(bucket(big 16rffffffff), 5, "just below 2^32 label");
	t.asserteq(bucket(big 16r100000001), 5, "just above 2^32 label");
	t.asserteq(bucket(big 16r7ffffffffffffffe), 4, "high label");
	t.asserteq(bucket(big 16r7fffffffffffffff), 5, "maxint big default");
	t.asserteq(bucket(big -9000000001), 5, "below lowest label");
}

testLoop(t: ref T)
{
	# hammer the dispatch so a JIT-compiled body gets exercised too
	n := 0;
	for(i := 0; i < 10000; i++) {
		v := big i * big 16r10000001;
		case v {
		big 0 =>
			n++;
		big 16r10000001 =>
			n += 2;
		big 16r700000070 =>
			n += 3;
		* =>
			n += 5;
		}
	}
	# i=0 -> +1; i=1 -> +2; i=112 (0x70*0x10000001) -> +3; rest (9997) -> +5
	t.asserteq(n, 1 + 2 + 3 + 9997*5, "loop dispatch sum");
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

	run("Magics", testMagics);
	run("Ranges", testRanges);
	run("Loop", testLoop);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
