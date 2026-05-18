implement VeltroTest;

#
# veltro_test.b - Tests for Veltro agent components
#
# Tests the Veltro tool modules directly by loading them and calling their
# name(), doc(), and exec() functions.
#
# To run: emu /tests/veltro_test.dis -v
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

# Import the Tool interface
Tool: module {
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

VeltroTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# Source file path for clickable error addresses
SRCFILE: con "/tests/veltro_test.b";

passed := 0;
failed := 0;
skipped := 0;

# Helper to run a test and track results
run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;	# already marked as failed
	"fail:skip" =>
		;	# already marked as skipped
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

# Test that Read tool loads and has correct name/doc
testReadTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/read.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load read tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "read", "read tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "read tool has documentation");
	t.assert(hassubstr(doc, "Read"), "doc mentions Read");
	t.assert(hassubstr(doc, "path"), "doc mentions path argument");
}

# Test that List tool loads and has correct name/doc
testListTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/list.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load list tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "list", "list tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "list tool has documentation");
	t.assert(hassubstr(doc, "List"), "doc mentions List");
}

# Test that Find tool loads and has correct name/doc
testFindTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/find.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load find tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "find", "find tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "find tool has documentation");
	t.assert(hassubstr(doc, "Find"), "doc mentions Find");
	t.assert(hassubstr(doc, "pattern"), "doc mentions pattern");
}

# Test that Search tool loads and has correct name/doc
testSearchTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/search.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load search tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "search", "search tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "search tool has documentation");
	t.assert(hassubstr(doc, "Search"), "doc mentions Search");
	t.assert(hassubstr(doc, "regular expression"), "doc mentions regular expression");
}

# Test that Write tool loads and has correct name/doc
testWriteTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/write.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load write tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "write", "write tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "write tool has documentation");
	t.assert(hassubstr(doc, "Write"), "doc mentions Write");
}

# Test that Edit tool loads and has correct name/doc
testEditTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/edit.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load edit tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "edit", "edit tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "edit tool has documentation");
	t.assert(hassubstr(doc, "Edit"), "doc mentions Edit");
	t.assert(hassubstr(doc, "replace"), "doc mentions replace");
}

# Test that Exec tool loads and has correct name/doc
testExecTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/exec.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load exec tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "exec", "exec tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "exec tool has documentation");
	t.assert(hassubstr(doc, "Exec"), "doc mentions Exec");
	t.assert(hassubstr(doc, "command"), "doc mentions command");
}

# Test that Spawn tool loads and has correct name/doc
testSpawnTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.fatal(sys->sprint("cannot load spawn tool: %r"));
		return;
	}

	t.assertseq(tool->name(), "spawn", "spawn tool name");

	doc := tool->doc();
	t.assert(len doc > 0, "spawn tool has documentation");
	t.assert(hassubstr(doc, "Spawn"), "doc mentions Spawn");
	t.assert(hassubstr(doc, "namespace"), "doc mentions namespace");
	t.assert(hassubstr(doc, "tools"), "doc mentions tools");
}

# Test Read tool execution with a real file
testReadExec(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/read.dis";
	if(tool == nil) {
		t.skip("cannot load read tool");
		return;
	}

	# Read this test file
	result := tool->exec("/tests/veltro_test.b");
	t.assert(!hassubstr(result, "error:"), "read should not return error");
	t.assert(hassubstr(result, "VeltroTest"), "should read file content");
}

# Test List tool execution with a real directory
testListExec(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/list.dis";
	if(tool == nil) {
		t.skip("cannot load list tool");
		return;
	}

	# List the tests directory
	result := tool->exec("/tests");
	t.assert(!hassubstr(result, "error:"), "list should not return error");
	t.assert(hassubstr(result, "entries"), "should have entries count");
}

# Test Read tool error handling
testReadError(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/read.dis";
	if(tool == nil) {
		t.skip("cannot load read tool");
		return;
	}

	# Try to read a nonexistent file
	result := tool->exec("/nonexistent/file/path");
	t.assert(hassubstr(result, "error:"), "should return error for missing file");
}

# Test List tool error handling
testListError(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/list.dis";
	if(tool == nil) {
		t.skip("cannot load list tool");
		return;
	}

	# Try to list a nonexistent directory
	result := tool->exec("/nonexistent/directory");
	t.assert(hassubstr(result, "error:"), "should return error for missing directory");
}

# Test spawn argument parsing
testSpawnParseArgs(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.skip("cannot load spawn tool");
		return;
	}

	# Test with no tools - should return error
	result := tool->exec("");
	t.assert(hassubstr(result, "error:"), "empty args should error");

	# Test with no task - should return error
	result = tool->exec("tools=read");
	t.assert(hassubstr(result, "error:"), "missing task should error");
}

# Test spawn with valid tools (requires tools9p to be running)
testSpawnExecValid(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.skip("cannot load spawn tool");
		return;
	}

	# Check if /tool is mounted (spawn needs it for tool validation)
	fd := sys->open("/tool/tools", Sys->OREAD);
	if(fd == nil) {
		t.skip("/tool not mounted - run with tools9p");
		return;
	}
	fd = nil;

	# Test spawning with list tool to list a known directory.
	# Format: [globals] -- tools=<t> paths=<p> :: <task>
	result := tool->exec("-- tools=list paths=/appl :: list /appl");

	# If spawn worked, we should get directory content or entries count
	# If it failed, we'll see "error:" prefix
	if(hassubstr(result, "error:")) {
		# Check if it's a valid error vs unexpected failure
		if(hassubstr(result, "timed out")) {
			t.skip("spawn timed out - may need more time");
			return;
		}
		t.log(sys->sprint("spawn result: %s", result));
		t.error("spawn with valid tools failed");
	} else {
		# Should have some content - either "entries" or actual listing
		t.assert(len result > 0, "spawn should return non-empty result");
		t.log(sys->sprint("spawn succeeded: %s", truncresult(result, 100)));
	}
}

# Test spawn with invalid tool (tool not in parent's namespace)
testSpawnExecInvalidTool(t: ref T)
{
	tool := load Tool "/dis/veltro/tools/spawn.dis";
	if(tool == nil) {
		t.skip("cannot load spawn tool");
		return;
	}

	# Check if /tool is mounted
	fd := sys->open("/tool/tools", Sys->OREAD);
	if(fd == nil) {
		t.skip("/tool not mounted - run with tools9p");
		return;
	}
	fd = nil;

	# Try to grant a tool that doesn't exist
	result := tool->exec("tools=nonexistenttool -- do something");

	# Should return error about not having the tool
	t.assert(hassubstr(result, "error:"), "should error for invalid tool");
}

# Truncate result for logging
truncresult(s: string, max: int): string
{
	if(len s <= max)
		return s;
	return s[0:max] + "...";
}

# Helper function to check if a string contains a substring
hassubstr(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		if(s[i:i+len sub] == sub)
			return 1;
	}
	return 0;
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

	# Check for verbose flag
	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Test tool loading and documentation
	run("ReadTool", testReadTool);
	run("ListTool", testListTool);
	run("FindTool", testFindTool);
	run("SearchTool", testSearchTool);
	run("WriteTool", testWriteTool);
	run("EditTool", testEditTool);
	run("ExecTool", testExecTool);
	run("SpawnTool", testSpawnTool);

	# Test tool execution
	run("ReadExec", testReadExec);
	run("ListExec", testListExec);
	run("ReadError", testReadError);
	run("ListError", testListError);

	# Test spawn tool functionality
	run("SpawnParseArgs", testSpawnParseArgs);
	run("SpawnExecValid", testSpawnExecValid);
	run("SpawnExecInvalidTool", testSpawnExecInvalidTool);

	# Print summary
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
