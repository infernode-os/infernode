implement SpawnBudgetTest;

#
# spawn inside tools9p: does a subagent get the tools in the delegation
# budget, and only those?
#
# tools9p narrows the namespace of each tool call to that tool's own
# authority. spawn loads each child's tools from /dis/veltro/tools when
# it runs, so a spawn call narrowed to spawn.dis alone could load none:
# every subagent failed with "cannot load tool plan" (INFR-486). The
# spawn call now holds the budget's tools; a tool outside the budget is
# still not there to load.
#
# Run against a tools9p serving spawn with a budget of plan and read
# (tests/host/spawn_budget_test.sh does):
#   tools9p -b plan,read spawn read &
#   /dis/tests/spawn_budget_test.dis -v
#
# No model is needed: a child's tools are loaded before it asks one,
# and with none mounted the child then fails, which is not this test's
# business.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

SpawnBudgetTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/spawn_budget_test.b";

CTL: con "/tool/spawn/ctl";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Call spawn with args and return what it said, read on the same fid.
spawn9p(t: ref T, args: string): string
{
	fd := sys->open(CTL, Sys->ORDWR);
	if(fd == nil) {
		t.skip(sys->sprint("cannot open %s: %r", CTL));
		return nil;
	}
	b := array of byte args;
	if(sys->write(fd, b, len b) != len b) {
		t.fatal(sys->sprint("write %s: %r", CTL));
		return nil;
	}
	s := "";
	buf := array[8192] of byte;
	off := big 0;
	while((n := sys->pread(fd, buf, len buf, off)) > 0) {
		s += string buf[0:n];
		off += big n;
	}
	return s;
}

contains(s, sub: string): int
{
	(nil, r) := str->splitstrl(s, sub);
	return r != nil;
}

testBudgetToolLoads(t: ref T)
{
	r := spawn9p(t, "timeout=8 -- tools=plan :: say hello");
	t.log("spawn said: " + r);
	t.assert(!contains(r, "cannot load tool"),
		"a child granted plan, in the budget, loads it: " + r);
}

testDefaultToolLoads(t: ref T)
{
	# A child given no tools gets plan: the JSON call a model makes.
	r := spawn9p(t, "{\"task\": \"say hello\", \"timeout\": 8}");
	t.log("spawn said: " + r);
	t.assert(!contains(r, "cannot load tool") && !contains(r, "missing"),
		"a child given no tools loads its default, plan: " + r);
}

testOutsideBudgetRefused(t: ref T)
{
	r := spawn9p(t, "timeout=8 -- tools=exec :: say hello");
	t.log("spawn said: " + r);
	t.assert(contains(r, "cannot load tool exec"),
		"a child asking for exec, outside the budget, cannot load it: " + r);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	(ok, nil) := sys->stat(CTL);
	if(ok < 0)
		raise "skip:no tools9p serving spawn at /tool";

	run("BudgetToolLoads", testBudgetToolLoads);
	run("DefaultToolLoads", testDefaultToolLoads);
	run("OutsideBudgetRefused", testOutsideBudgetRefused);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
