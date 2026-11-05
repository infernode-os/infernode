implement JitNilmodTest;

#
# jit_nilmod_test - a call through a nil module reference raises "module
# not loaded" where the handler around the call catches it, from compiled
# code as from the interpreter. tests/host/jit_nilmod_test.sh runs this
# under -c0 and -c1.
#
# The amd64 JIT sent a nil module into its call macros: for a builtin
# module (Sys) the macro read through H, "dereference of nil"; for a
# Limbo module, mframe's helper raised "module not loaded" without the
# instruction's pc. Either way no handler in the calling function saw
# it, and the Prog died. disfuzz (tools/disfuzz) found it, calling into
# a second instance of a module whose init had not run (its sys nil).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "arg.m";

JitNilmodTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_nilmod_test.b";

passed := 0;
failed := 0;
skipped := 0;

nosys: Sys;	# never loaded
noarg: Arg;

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

# a builtin module's function, no result, and one with a result
testBuiltin(t: ref T)
{
	got := "";
	{
		nosys->print("not printed\n");
		got = "returned";
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "module not loaded", "nil Sys, print");

	got = "";
	{
		s := nosys->sprint("%d", 1);
		got = "returned " + s;
	} exception e {
	"module*" =>
		got = e;
	}
	t.assertseq(got, "module not loaded", "nil Sys, sprint");
}

# a Limbo module's function: mframe, then mcall
testLimbo(t: ref T)
{
	got := "";
	{
		noarg->init("a" :: nil);
		got = "returned";
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "module not loaded", "nil Arg, init");

	# and the same module loaded is called as ever
	a := load Arg Arg->PATH;
	if(a == nil)
		t.fatal(sys->sprint("cannot load %s: %r", Arg->PATH));
	a->init("x" :: "-v" :: nil);
	t.asserteq(a->opt(), 'v', "loaded Arg, opt");
}

# raised in a callee, caught by the caller
callnil(): int
{
	return len nosys->sprint("x");
}

testCallee(t: ref T)
{
	got := "";
	{
		callnil();
		got = "returned";
	} exception e {
	"*" =>
		got = e;
	}
	t.assertseq(got, "module not loaded", "nil Sys in a callee");
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

	run("Builtin", testBuiltin);
	run("Limbo", testLimbo);
	run("Callee", testCallee);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
