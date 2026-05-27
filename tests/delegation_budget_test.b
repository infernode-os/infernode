implement DelegationBudgetTest;

#
# tests/delegation_budget_test.b
#
# Regression test for delegation-token semantics in tools9p.
#
# Design (per the system owner): the meta-agent holds a RESTRICTED active
# toolset, but a broader delegation budget (-b). When it creates a task
# agent it may hand that child any tool from the budget — even a tool the
# parent itself does not have active — and the child runs it in its own
# tools9p.
#
# Bug this guards against: the provisioning gate (childbudget / the
# `provision` handler) checked tool availability against the parent's
# ACTIVE set only (findtool), not the budget pool that is pre-loaded
# inactive (alltools). So every budget-only tool (write, edit, exec,
# websearch, ...) was wrongly DENIED to children, and the meta could
# never delegate the very tools it is meant to delegate. Fixed by
# checking toolavailable() = active OR inactive pool.
#
# Integration test — drives the real /tool 9P interface. Requires tools9p
# mounted at /tool with at least one budget-only tool (the standard
# boot.sh config has write/edit/exec in -b but not -p). Skips gracefully
# if /tool is not mounted or no budget-only tool exists.
#
# To run (matching tools9p_test.b):
#   tools9p -m /tool -b read,list,find,write,edit,exec,memory,present,gap \
#           -p read list find present memory gap &
#   sleep 2
#   /tests/delegation_budget_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

DelegationBudgetTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/delegation_budget_test.b";
TOOLMNT: con "/tool";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip"  => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

writefile(path, content: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte content;
	return sys->write(fd, b, len b);
}

# Exact (whitespace-delimited) membership — avoids 'read' matching 'readfile'.
hasentry(listtext, name: string): int
{
	(nil, toks) := sys->tokenize(listtext, "\n \t\r");
	for(; toks != nil; toks = tl toks)
		if(hd toks == name)
			return 1;
	return 0;
}

# Read /tool.<id>/tools, polling until the child mounts (or timeout).
childtoollist(id: int): string
{
	path := sys->sprint("%s.%d/tools", TOOLMNT, id);
	for(i := 0; i < 40; i++) {
		got := readfile(path);
		if(got != nil && got != "")
			return got;
		sys->sleep(150);
	}
	return "";
}

# Pick a tool that is in the delegation budget but NOT in the active set.
budgetonlytool(): string
{
	budget := readfile(TOOLMNT + "/budget");
	if(budget == nil || budget == "")
		return "";
	active := readfile(TOOLMNT + "/tools");
	(nil, btoks) := sys->tokenize(budget, "\n \t\r");
	for(; btoks != nil; btoks = tl btoks) {
		nm := hd btoks;
		if(nm != "" && !hasentry(active, nm))
			return nm;
	}
	return "";
}

# The core regression: a budget-only (inactive-in-parent) tool MUST be
# delegatable to a child task.
testDelegateBudgetOnlyTool(t: ref T)
{
	if(readfile(TOOLMNT + "/budget") == nil) {
		t.skip("tools9p not mounted at /tool");
		return;
	}
	tool := budgetonlytool();
	if(tool == "") {
		t.skip("no budget-only (inactive) tool present — cannot exercise the gate");
		return;
	}
	t.log("delegating budget-only tool: " + tool);

	id := 8131;
	if(writefile(TOOLMNT + "/provision", sys->sprint("%d tools=%s", id, tool)) < 0) {
		t.fatal("cannot write /tool/provision");
		return;
	}
	got := childtoollist(id);
	t.assertnotnil(got, sys->sprint("child /tool.%d/tools readable after provision", id));
	t.assert(hasentry(got, tool),
		sys->sprint("child received delegated budget-only tool '%s' (child tools: %s)", tool, got));
}

# Negative guard: a tool NOT in the budget must still be refused, so the
# fix doesn't become a free-for-all.
testDenyNonBudgetTool(t: ref T)
{
	if(readfile(TOOLMNT + "/budget") == nil) {
		t.skip("tools9p not mounted at /tool");
		return;
	}
	bogus := "definitelynotarealtool";
	id := 8132;
	writefile(TOOLMNT + "/provision", sys->sprint("%d tools=%s", id, bogus));
	got := childtoollist(id);
	if(got == "") {
		t.skip("child did not mount; cannot verify denial");
		return;
	}
	t.assert(!hasentry(got, bogus), "non-budget tool is refused, not delegated");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module\n");
		raise "fail:load";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DelegateBudgetOnlyTool", testDelegateBudgetOnlyTool);
	run("DenyNonBudgetTool",      testDenyNonBudgetTool);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
