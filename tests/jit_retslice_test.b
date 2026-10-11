implement JitRetsliceTest;

#
# A call to another module, from compiled code, keeps the thread
# running: it does not end its time slice.
#
# OP(mcall) sets R.t on every call between modules.  The JITs return
# from a compiled frame by themselves, ignoring R.t, but punt to
# OP(ret) for a frame they cannot (one in a stack extension, when the
# call fell just past the end of a stack segment), and after it they
# leave compiled code for the scheduler if R.t is set.  OP(ret) left
# R.t as mcall had set it, so at such a depth every call and return
# ended the slice: a loop of calls there ran a thousand times as many
# slices as anywhere else, and each one, with the heap half full, a
# collector pass (a JavaScript benchmark ran 6x slower under one
# command than another, by where its stack happened to be).
#
# The test calls a function in another module 2000 times at each of
# many stack depths, so that some of the calls fall at a segment's
# end, while a second thread runs whenever this one's slice ends.  The
# calls at any one depth must see that thread run far less often than
# once a call.  Meaningful under the JIT (emu -c1); it passes under the
# interpreter too, which never had the bug.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitRetsliceTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

JitUnloadHelper: module
{
	PATH:	con "/dis/tests/jit_unload_helper.dis";
	hold:	fn(ms: int): int;
	holdfile:	fn(ms: int): int;
	pad:	fn(a: int): int;
};

SRCFILE: con "/tests/jit_retslice_test.b";
HELPERS: con "/tests/jit_unload_helper.dis";

Calls: con 2000;
Depths: con 400;

passed := 0;
failed := 0;
skipped := 0;

h: JitUnloadHelper;
ran := 0;	# set by the other thread whenever it runs
stop := 0;

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

spinner()
{
	while(!stop)
		ran = 1;
}

# the calls, at this depth: how many times the other thread ran
calls(): int
{
	n := 0;
	s := 0;
	ran = 0;
	for(i := 0; i < Calls; i++) {
		s += h->pad(i);
		if(ran) {
			n++;
			ran = 0;
		}
	}
	if(s == 12345)
		n++;
	return n;
}

# down d frames, each of some size, then the calls
deep(d: int, a, b, c, e, f, g, k: int): int
{
	if(d > 0)
		return deep(d - 1, a + 1, b, c, e, f, g, k) + a;
	return calls();
}

testCallsKeepSlice(t: ref T)
{
	h = load JitUnloadHelper HELPERS;
	if(h == nil)
		h = load JitUnloadHelper JitUnloadHelper->PATH;
	if(h == nil)
		t.fatal(sys->sprint("cannot load the helper: %r"));
	spawn spinner();
	worst := 0;
	at := 0;
	for(d := 0; d < Depths; d++) {
		n := deep(d, 0, 0, 0, 0, 0, 0, 0) - d * (d - 1) / 2;
		if(n > worst) {
			worst = n;
			at = d;
		}
	}
	stop = 1;
	t.log(sys->sprint("the other thread ran at most %d times in %d calls, at depth %d", worst, Calls, at));
	t.assert(worst < Calls / 4, sys->sprint("%d slices ended in %d calls at depth %d", worst, Calls, at));
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
	run("CallsKeepSlice", testCallsKeepSlice);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
