implement JitCallreschedTest;

#
# A recursion with no loop in it gives up the VM while it runs.
#
# The arm64 and riscv64 JITs checked the interpreter's time slice only at
# backward jumps, never at a call; a recursive function has calls and no
# loop, so compiled, it kept the VM until it returned.  jitbench's
# fib(30) held a Pi Zero 2 W's VM for 4.7 s, and every other Prog in it
# waited (amd64's ICALL falls into IJMP's check and never had the gap).
# The interpreter counts every instruction, so -c0 was never affected.
#
# A ticker sleeps 10 ms at a time and keeps its worst lateness while
# another Prog runs fib in a loop; the worst must stay far below the
# time one fib takes.  tests/host/jit_callresched_test.sh runs it under
# -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitCallreschedTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_callresched_test.b";

passed := 0;
failed := 0;
skipped := 0;

# How long the recursion runs, and the lateness allowed: a time slice is
# a few milliseconds of Dis instructions, so a ticker that is late by
# more than this was shut out for many of them in a row.  Held, it was
# late by all of a fib (hundreds of ms on the Jetson, seconds on a Zero).
RUNMS: con 3000;
LIMITMS: con 250;

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

fib(n: int): int
{
	if(n < 2)
		return n;
	return fib(n-1) + fib(n-2);
}

# mutual recursion: one of the two calls is to an earlier address
even(n: int): int
{
	if(n == 0)
		return 1;
	return odd(n-1);
}

odd(n: int): int
{
	if(n == 0)
		return 0;
	return even(n-1);
}

recurse(kind: string, stop: chan of int, done: chan of int)
{
	calls := 0;
	for(;;){
		alt {
		<-stop =>
			done <-= calls;
			return;
		* =>
			if(kind == "fib")
				fib(27);
			else
				even(200000);
			calls++;
		}
	}
}

ticker(stop: chan of int, res: chan of int)
{
	worst := 0;
	for(;;){
		alt {
		<-stop =>
			res <-= worst;
			return;
		* =>
			t0 := sys->millisec();
			sys->sleep(10);
			late := sys->millisec() - t0 - 10;
			if(late > worst)
				worst = late;
		}
	}
}

lateness(t: ref T, kind: string)
{
	tstop := chan of int;
	tres := chan of int;
	rstop := chan of int;
	rdone := chan of int;
	spawn ticker(tstop, tres);
	spawn recurse(kind, rstop, rdone);
	sys->sleep(RUNMS);
	rstop <-= 1;
	calls := <-rdone;
	tstop <-= 1;
	worst := <-tres;
	t.log(sys->sprint("%s: %d calls in %d ms, worst ticker lateness %d ms", kind, calls, RUNMS, worst));
	t.assert(calls > 0, kind + " ran");
	t.assert(worst < LIMITMS, sys->sprint("%s: worst lateness %d ms, want < %d", kind, worst, LIMITMS));
}

testFib(t: ref T)
{
	lateness(t, "fib");
}

testMutual(t: ref T)
{
	lateness(t, "mutual");
}

testResult(t: ref T)
{
	# a reschedule in the middle of a call must not change what it returns
	t.asserteq(fib(25), 75025, "fib(25)");
	t.asserteq(even(100001), 0, "even(100001)");
	t.asserteq(odd(100001), 1, "odd(100001)");
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

	run("Result", testResult);
	run("Fib", testFib);
	run("Mutual", testMutual);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
