implement JitUnloadTest;

#
# A module that returns from a call after the caller has let go of it.
#
# The caller holds the module in a global; a second thread sets the
# global to nil while the module's function is running, so the call's
# own reference is the last one, and the return is what releases it.
# A compiled module returns by calling into the VM from its own code
# (the JITs' ret macro), and releasing the module there unloaded it and
# unmapped its code with that return still to run in it: a jump into
# unmapped memory, "PC not in any loaded image". libinterp/xec.c's
# OP(ret) now holds the release until control is back in C.
#
# Meaningful under the JIT (emu -c1); it passes under the interpreter
# too, which never had the bug.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitUnloadTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

JitUnloadHelper: module
{
	PATH:	con "/dis/tests/jit_unload_helper.dis";
	hold:	fn(ms: int): int;
	pad:	fn(a: int): int;
};

SRCFILE: con "/tests/jit_unload_test.b";

passed := 0;
failed := 0;
skipped := 0;

# the only reference, apart from the call's own
g: JitUnloadHelper;

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

dropper(ms: int, done: chan of int)
{
	sys->sleep(ms);
	g = nil;
	done <-= 1;
}

testLastReferenceReturn(t: ref T)
{
	for(i := 0; i < 20; i++){
		g = load JitUnloadHelper JitUnloadHelper->PATH;
		if(g == nil)
			t.fatal(sys->sprint("cannot load %s: %r", JitUnloadHelper->PATH));
		done := chan of int;
		spawn dropper(10, done);
		r := g->hold(60);
		<-done;
		t.asserteq(r, 61, sys->sprint("round %d: hold returned", i));
		if(g != nil)
			t.error(sys->sprint("round %d: the dropper did not run first", i));
	}
}

# the ordinary case beside it: the caller keeps its reference
testHeldReferenceReturn(t: ref T)
{
	h := load JitUnloadHelper JitUnloadHelper->PATH;
	if(h == nil)
		t.fatal(sys->sprint("cannot load %s: %r", JitUnloadHelper->PATH));
	for(i := 0; i < 20; i++)
		t.asserteq(h->hold(1), 2, "hold returned");
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

	run("LastReferenceReturn", testLastReferenceReturn);
	run("HeldReferenceReturn", testHeldReferenceReturn);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
