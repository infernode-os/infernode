implement LimboLdtTest;

#
# limbo_ldt_test - a module that takes a ref fn of its own functions
# can load another module through a module type equal to its own
# (INFR-310).
#
# A ref fn of a function the module does not declare adds that
# function to the module's interface, and the interface is shared
# by every structurally equal module type.  The compiler used to
# put those functions in the shared link table, so loading
# /dis/echo.dis through Cmd below demanded that echo implement
# this file's test functions ("link typecheck Echo->testforeign()").
#
# This module's own type is deliberately identical to Cmd, and run()
# takes a ref fn of every test: the pattern every test file uses.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboLdtTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/limbo_ldt_test.b";

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

# Another module loads through the type equal to this one's.
testforeign(t: ref T)
{
	c := load Cmd "/dis/echo.dis";
	if(c == nil)
		t.fatal(sys->sprint("load Cmd /dis/echo.dis: %r"));
	t.log("echo loaded through Cmd");
}

# And through this module's own type.
testforeignself(t: ref T)
{
	c := load LimboLdtTest "/dis/echo.dis";
	if(c == nil)
		t.fatal(sys->sprint("load LimboLdtTest /dis/echo.dis: %r"));
}

# The module itself, loaded by name, still links.
testselfload(t: ref T)
{
	c := load Cmd "/dis/tests/limbo_ldt_test.dis";
	if(c == nil)
		t.fatal(sys->sprint("load of this module: %r"));
}

double(n: int): int
{
	return 2*n;
}

square(n: int): int
{
	return n*n;
}

apply(f: ref fn(n: int): int, n: int): int
{
	return f(n);
}

# A ref fn of a function the module does not declare still calls it.
testreffn(t: ref T)
{
	t.asserteq(apply(double, 21), 42, "ref fn double");
	t.asserteq(apply(square, 9), 81, "ref fn square");
	f: ref fn(n: int): int = square;
	t.asserteq(f(7), 49, "ref fn held in a variable");
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

	run("ForeignLoad", testforeign);
	run("ForeignLoadOwnType", testforeignself);
	run("SelfLoad", testselfload);
	run("RefFn", testreffn);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
