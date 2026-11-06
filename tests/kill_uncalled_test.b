implement KillUncalledTest;

#
# kill_uncalled_test - a Prog killed between a frame and its call, the
# frame in a new stack extension, is destroyed whole and nothing else.
#
# A Prog's time slice ends at any instruction, so a Prog can be left
# ready to run after a frame instruction that extended its stack and
# before the call: R.EX is then the new extension, whose only frame is
# not yet called, while R.FP is still the caller's, in the extension
# before. A Prog killed while ready has its stack destroyed by the
# killer (destroystack). It walked the frames from R.FP down, freeing
# each with its type, and a frame that begins an extension has none of
# its own: it took the type of the extension it was in -- but the
# extension it took was the new one, not the frame's. Every
# extension's first frame below was freed with the uncalled frame's
# type, and what that type says is a pointer, the frame held as
# anything else: destroy() of a callee frame's address
# ("alloc:D2B ... in main: in block at", a Dis stack, on macOS AMD64
# CI in web_browser_test's LeaveEarly, which kills a page's script
# while it runs), or of an integer.
#
# Here a victim recurses through two functions whose frames differ --
# integers where the other has strings -- deep enough that their frames
# extend the stack every few calls, and is killed again and again at
# the end of one of its time slices, wherever that falls. The test
# passing at all (emu still here) is most of it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

KillUncalledTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/kill_uncalled_test.b";

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

# integers that are no address, where g's frame holds strings
f(n: int): int
{
	a0 := 16r41414141 + n;
	a1 := 16r42424242 + n;
	a2 := 16r43434343 + n;
	a3 := 16r44444444 + n;
	a4 := 16r45454545 + n;
	a5 := 16r46464646 + n;
	a6 := 16r47474747 + n;
	a7 := 16r48484848 + n;
	# a backward branch: compiled code ends its time slice only at one,
	# and with none but the victim's outer loop a slice lasted 2048
	# runs of f(300) (the test ran past the runner's 900s on Linux ARM64)
	for(j := 0; j < 1; j++)
		;
	if(n <= 0)
		return a0;
	r: int;
	if(n % 3 == 0)	# not f, g, f, g: then each extension began with the same one
		r = f(n-1);
	else
		r = g(n-1, a1, a2, a3);
	return r + a0 + a4 + a5 + a6 + a7;
}

g(n: int, x, y, z: int): int
{
	s0 := "s0";
	s1 := "s1";
	s2 := "s2";
	s3 := "s3";
	s4 := "s4";
	s5 := "s5";
	s6 := "s6";
	s7 := "s7";
	if(n <= 0)
		return x + y + z;
	r := f(n-1);
	return r + len s0 + len s1 + len s2 + len s3 + len s4 + len s5 + len s6 + len s7;
}

# skew: a slice is a fixed count of instructions, so a victim started
# afresh each time would always be stopped at the same few places;
# a loop of skew turns first puts the slices' ends elsewhere each time
victim(pidc: chan of int, skew: int)
{
	pidc <-= sys->pctl(0, nil);
	for(k := 0; k < skew; k++)
		;
	for(;;)
		f(300);
}

kill(pid: int): int
{
	fd := sys->open(sys->sprint("#p/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		return -1;
	if(sys->fprint(fd, "kill") < 0)
		return -1;
	return 0;
}

Nkills: con 3000;
Budget: con 120*1000;	# ms: a slow machine stops early, saying how far it got

testKilledAnywhere(t: ref T)
{
	pidc := chan of int;
	t0 := sys->millisec();
	i: int;
	for(i = 0; i < Nkills && sys->millisec() - t0 < Budget; i++){
		spawn victim(pidc, i);
		pid := <-pidc;
		# let it run a slice or a few: it is ready, not running, when
		# this runs again, stopped wherever its slice ended
		for(j := 0; j < 1 + i % 5; j++)
			sys->sleep(0);
		if(kill(pid) < 0)
			t.fatal(sys->sprint("kill %d: %r", pid));
	}
	# and the VM still runs Limbo
	t.log(sys->sprint("%d kills in %dms", i, sys->millisec() - t0));
	t.assert(i >= 100, sys->sprint("killed %d times within the budget", i));
	t.asserteq(f(10), f(10), "the recursion after the kills");
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

	run("KilledAnywhere", testKilledAnywhere);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
