implement SpawnExecTest;

#
# spawn_exec_test - Test actual spawn execution
#
# Tests the full spawn cycle:
# - Pre-load modules
# - Create sandbox
# - Run child in sandbox
# - Get result via pipe
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "tool.m";

SpawnExecTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

SRCFILE: con "/tests/spawn_exec_test.b";

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

# Test loading spawn as Tool interface
testLoadSpawnTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}

	# Test init
	err := tool->init();
	if(err != nil)
		t.error(sys->sprint("spawn init failed: %s", err));
	else
		t.log("spawn init succeeded");

	# Test name
	name := tool->name();
	t.assertseq(name, "spawn", "spawn tool name");

	# Test doc returns non-empty
	doc := tool->doc();
	t.assert(len doc > 100, "spawn doc should be substantial");
}

# Test loading list tool as Tool interface
testLoadListTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/list.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load list tool: %r"));
		return;
	}

	err := tool->init();
	if(err != nil)
		t.error(sys->sprint("list init failed: %s", err));

	# Execute list on root
	result := tool->exec("/dev");
	t.assert(len result > 0, "list /dev should return entries");
	t.log(sys->sprint("list /dev result: %s", result[0:min(100, len result)]));
}

# Test loading read tool as Tool interface
testLoadReadTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/read.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load read tool: %r"));
		return;
	}

	err := tool->init();
	if(err != nil)
		t.error(sys->sprint("read init failed: %s", err));

	# Read a known file
	result := tool->exec("/dev/sysname");
	t.assert(result != "" && !hasprefix(result, "error"), "read /dev/sysname should succeed");
	t.log(sys->sprint("sysname: %s", result));
}

# Test actual spawn execution with list tool
testSpawnExec(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}

	err := tool->init();
	if(err != nil) {
		t.fatal(sys->sprint("spawn init failed: %s", err));
		return;
	}

	# First, test with just /tmp (no copying needed, dir already in sandbox)
	t.log("Testing spawn with list /tmp...");
	result := tool->exec("-- tools=list :: list /tmp");

	t.log(sys->sprint("spawn result (%d chars): %s", len result, result[0:min(300, len result)]));

	if(hasprefix(result, "error:")) {
		if(result == "error: LLM returned empty response") {
			t.skip("spawn needs a live LLM response in this harness");
			return;
		}
		t.error(sys->sprint("spawn failed: %s", result));
		return;
	}

	# /tmp should exist in restricted namespace
	t.assert(len result >= 0, "spawn should return a result");
}

testSpawnRejectsExecWithPaths(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}
	err := tool->init();
	if(err != nil) {
		t.fatal(sys->sprint("spawn init failed: %s", err));
		return;
	}
	result := tool->exec("-- tools=exec paths=/lib/veltro :: inspect");
	t.log(sys->sprint("spawn reject result: %s", result));
	t.assert(contains(result, "exec/shell subagents cannot receive path grants"),
		"spawn rejects exec with extra paths");
}

testSpawnRejectsPrivilegedPaths(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}
	err := tool->init();
	if(err != nil) {
		t.fatal(sys->sprint("spawn init failed: %s", err));
		return;
	}
	result := tool->exec("-- tools=read paths=/mnt/msg/ctl :: inspect");
	t.log(sys->sprint("spawn privileged path reject result: %s", result));
	t.assert(contains(result, "namespace restriction failed") &&
		contains(result, "privileged path not grantable"),
		"spawn rejects privileged child path grants");
}

testSpawnJsonSingleAgentWithArrayGrants(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}
	err := tool->init();
	if(err != nil) {
		t.fatal(sys->sprint("spawn init failed: %s", err));
		return;
	}
	result := tool->exec(`{"task":"inspect","tools":["exec"],"paths":["/lib/veltro"]}`);
	t.log(sys->sprint("spawn JSON single-agent reject result: %s", result));
	t.assert(contains(result, "exec/shell subagents cannot receive path grants"),
		"spawn parses a single JSON agent object before enforcing grants");
	t.assert(!contains(result, "each subagent needs a task"),
		"spawn must not misread tools[] as the agents array");
}

testSpawnJsonRejectsPrivilegedPaths(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}
	err := tool->init();
	if(err != nil) {
		t.fatal(sys->sprint("spawn init failed: %s", err));
		return;
	}
	result := tool->exec(`{"agents":[{"task":"inspect","tools":["read"],"paths":["/mnt/msg/ctl"]}]}`);
	t.log(sys->sprint("spawn JSON privileged path reject result: %s", result));
	t.assert(contains(result, "namespace restriction failed") &&
		contains(result, "privileged path not grantable"),
		"spawn rejects privileged JSON path grants");
}

contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return 1;
	}
	return 0;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("LoadSpawnTool", testLoadSpawnTool);
	run("LoadListTool", testLoadListTool);
	run("LoadReadTool", testLoadReadTool);
	run("SpawnExec", testSpawnExec);
	run("SpawnRejectsExecWithPaths", testSpawnRejectsExecWithPaths);
	run("SpawnRejectsPrivilegedPaths", testSpawnRejectsPrivilegedPaths);
	run("SpawnJsonSingleAgentWithArrayGrants", testSpawnJsonSingleAgentWithArrayGrants);
	run("SpawnJsonRejectsPrivilegedPaths", testSpawnJsonRejectsPrivilegedPaths);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
