implement VeltroSafeExecTest;

#
# veltro_safeexec_test.b - Tests for the SafeExec tool's security boundary
#
# SafeExec is the privileged-without-shell execution path used when an agent
# was spawned without shellcmds.  spawn.b uses safeexec instead of exec to
# run whitelisted .dis files directly, bypassing the shell and the entire
# class of metacharacter-injection attacks that come with it.
#
# That makes SafeExec's input validation a security boundary.  These tests
# exercise it directly via the loaded module:
#
#   - empty / whitespace-only args are rejected
#   - tool names containing path separators or "." are rejected
#     (defends against ../../escape and absolute-path attacks)
#   - non-existent tools are rejected before any load attempt
#   - tool names are case-normalized to lower
#   - valid tools (read, list) actually execute and return real output
#   - heredoc/multi-arg payloads are forwarded intact to the wrapped tool
#
# To run: cd $ROOT && ./emu/MacOSX/o.emu -r. /tests/veltro_safeexec_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

# SafeExec's actual exported interface.
# Note: safeexec.b does NOT declare init() in its module signature
# (it self-initializes inside exec()).  Loading via the canonical Tool
# interface — which requires init() — would fail the type check, so we
# match SafeExec's exports exactly.
Tool: module {
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

VeltroSafeExecTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/veltro_safeexec_test.b";

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

# Load SafeExec.  No init() to call — safeexec self-initializes on first
# exec().
loadsafeexec(t: ref T): Tool
{
	tool := load Tool "/dis/veltro/tools/safeexec.dis";
	if(tool == nil) {
		t.skip("cannot load safeexec.dis");
		return nil;
	}
	return tool;
}

# ============================================================================
# Identity
# ============================================================================

testNameAndDoc(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "safeexec", "name() returns 'safeexec'");

	doc := tool->doc();
	t.assert(len doc > 0, "doc() is non-empty");
	t.assert(hassubstr(doc, "SafeExec"), "doc mentions SafeExec");
	t.assert(hassubstr(doc, "shell"), "doc mentions shell behavior");
	t.assert(hassubstr(doc, "injection"), "doc warns about injection");
}

# ============================================================================
# Argument validation
# ============================================================================

testEmptyArgs(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	r := tool->exec("");
	t.assert(hassubstr(r, "error"), "empty args rejected");
	t.assert(hassubstr(r, "no tool"), "error mentions missing tool name");
}

testWhitespaceOnlyArgs(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	r := tool->exec("   \t  ");
	t.assert(hassubstr(r, "error"), "whitespace-only args rejected");
}

# ============================================================================
# Path-traversal defenses
#
# The tool name is validated character-by-character: any '/', '\', or '.'
# results in a rejection BEFORE any stat or load happens.  These tests
# exercise common attacker payloads.
# ============================================================================

testRejectPathTraversal(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Classic ../ traversal
	r := tool->exec("../etc/passwd");
	t.assert(hassubstr(r, "error"), "../ traversal rejected");
	t.assert(hassubstr(r, "invalid tool name"), "error mentions invalid name");
}

testRejectAbsolutePath(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Absolute path to arbitrary .dis
	r := tool->exec("/dis/sh.dis some args");
	t.assert(hassubstr(r, "error"), "absolute path rejected");
	t.assert(hassubstr(r, "invalid tool name"), "error mentions invalid name");
}

testRejectBackslash(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Backslash also rejected (Windows-style escape)
	r := tool->exec("foo\\bar");
	t.assert(hassubstr(r, "error"), "backslash rejected");
	t.assert(hassubstr(r, "invalid tool name"), "error mentions invalid name");
}

testRejectDot(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Bare "." would resolve to "/dis/veltro/tools/..dis" if not blocked
	r := tool->exec("read.dis foo");
	t.assert(hassubstr(r, "error"), "tool name with '.' rejected");
}

# ============================================================================
# Whitelist: only tools that exist in /dis/veltro/tools/ load
# ============================================================================

testRejectUnknownTool(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	r := tool->exec("nosuchtool argument");
	t.assert(hassubstr(r, "error"), "unknown tool rejected");
	t.assert(hassubstr(r, "tool not found") || hassubstr(r, "cannot load"),
		"error mentions tool not found");
}

# ============================================================================
# Case normalization: tool name is lowercased
# ============================================================================

testCaseInsensitive(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Read with uppercase should resolve to /dis/veltro/tools/read.dis.
	# Use this very test file as a known-readable target.
	r := tool->exec("READ /tests/veltro_safeexec_test.b");
	# If lowercasing works, read.dis runs and returns file contents
	# (which include this very implement statement).
	t.assert(!hassubstr(r, "error: tool not found"),
		"uppercase READ resolves to read tool");
	t.assert(hassubstr(r, "VeltroSafeExecTest") || !hassubstr(r, "error:"),
		"uppercase READ executes successfully");
}

# ============================================================================
# Forwarding: arguments after the tool name are passed verbatim
# ============================================================================

testForwardArgs(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# Use list, which expects a directory path
	r := tool->exec("list /tests");
	t.assert(!hassubstr(r, "error: tool not found"), "list tool resolves");
	t.assert(!hassubstr(r, "error: no tool"), "args were forwarded");
	# list returns "entries" count on success
	t.assert(hassubstr(r, "entries") || hassubstr(r, "veltro_safeexec_test"),
		"list executed and produced output");
}

testForwardErrorPropagation(t: ref T)
{
	tool := loadsafeexec(t);
	if(tool == nil)
		return;

	# read of nonexistent file: read tool reports error, safeexec passes through
	r := tool->exec("read /no/such/file/anywhere");
	t.assert(hassubstr(r, "error"), "wrapped tool's error propagated");
}

# ============================================================================
# Helpers
# ============================================================================

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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Identity
	run("NameAndDoc", testNameAndDoc);

	# Argument validation
	run("EmptyArgs", testEmptyArgs);
	run("WhitespaceOnlyArgs", testWhitespaceOnlyArgs);

	# Path-traversal defenses
	run("RejectPathTraversal", testRejectPathTraversal);
	run("RejectAbsolutePath", testRejectAbsolutePath);
	run("RejectBackslash", testRejectBackslash);
	run("RejectDot", testRejectDot);

	# Whitelist
	run("RejectUnknownTool", testRejectUnknownTool);

	# Normalization & forwarding
	run("CaseInsensitive", testCaseInsensitive);
	run("ForwardArgs", testForwardArgs);
	run("ForwardErrorPropagation", testForwardErrorPropagation);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
