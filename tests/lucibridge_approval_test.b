implement LucibridgeApprovalTest;

#
# lucibridge_approval_test.b - Tests for needsapproval(), the security gate
# that decides which agent tool calls require explicit user consent.
#
# This is the most safety-relevant pure function in lucibridge.b.  It runs
# before EVERY tool call (in pretoolapproval) and gates whether the agent's
# request reaches the tool or pauses for an Allow/Deny dialogue.  A bug
# here means either:
#
#   - false negatives: dangerous calls slip past approval (the bad case)
#   - false positives: agent is blocked on every read, UX collapses
#
# The function is small but has subtle rules.  We re-implement it locally
# here (matching lucibridge_test.b's pattern) and pin the contract:
#
#   exec  ──  rm -r outside /tmp           → require approval
#         ──  rm -r /tmp/...               → no approval (sandbox cleanup)
#         ──  bind/mount/unmount anything  → require approval (ns mutation)
#         ──  anything else                → no approval
#   write ──  /dis/...  /lib/...  /dev/... → require approval (system files)
#         ──  /tmp/... or /home/... etc.   → no approval
#   edit  ──  same rules as write
#   read/list/find/...                     → never require approval
#
# Also tested:
#   - firstlines(): preview truncation of large tool results.
#     Used by lucibridge to inline a small preview into the LLM context;
#     getting "n" wrong leaks bytes or starves the model of context.
#
# To run: cd $ROOT && ./emu/MacOSX/o.emu -r. /tests/lucibridge_approval_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LucibridgeApprovalTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/lucibridge_approval_test.b";

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

# ============================================================================
# Local copies of lucibridge / agentlib helpers.
#
# These mirror the production implementations:
#   - lucibridge.b: needsapproval, firstlines
#   - agentlib.b:   contains, hasprefix
#
# If you change the production behaviour, change these too.
# ============================================================================

# agentlib->contains
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

# agentlib->hasprefix
hasprefix(s, pfx: string): int
{
	return len s >= len pfx && s[0:len pfx] == pfx;
}

# lucibridge->needsapproval
#
# Mirrors the implementation at /appl/cmd/lucibridge.b:396.
needsapproval(toolname, args: string): int
{
	if(toolname != "exec" && toolname != "write" && toolname != "edit")
		return 0;
	if(toolname == "exec") {
		if(contains(args, "rm") && contains(args, "-r")) {
			if(!hasprefix(args, "rm") || !contains(args, "/tmp"))
				return 1;
		}
		if(contains(args, "bind ") || contains(args, "mount ") ||
		   contains(args, "unmount "))
			return 1;
	}
	if(toolname == "write" || toolname == "edit") {
		if(hasprefix(args, "/dis/") || hasprefix(args, "/lib/") ||
		   hasprefix(args, "/dev/"))
			return 1;
	}
	return 0;
}

# lucibridge->firstlines
firstlines(s: string, n: int): string
{
	out := "";
	count := 0;
	for(i := 0; i < len s && count < n; i++) {
		out[len out] = s[i];
		if(s[i] == '\n')
			count++;
	}
	return out;
}

# ============================================================================
# Read-class tools never require approval
# ============================================================================

testReadNeverApproval(t: ref T)
{
	t.asserteq(needsapproval("read", "/etc/passwd"), 0,
		"read of any path ok without approval");
	t.asserteq(needsapproval("read", "/dis/sh.dis"), 0,
		"read of /dis/sh.dis ok");
	t.asserteq(needsapproval("list", "/"), 0,
		"list / ok without approval");
	t.asserteq(needsapproval("find", "/dis -name *"), 0,
		"find ok without approval");
	t.asserteq(needsapproval("search", "password /lib"), 0,
		"search ok without approval");
}

# ============================================================================
# exec: rm -r rules
# ============================================================================

testExecRmRfRootRequiresApproval(t: ref T)
{
	# The classic dangerous case
	t.asserteq(needsapproval("exec", "rm -rf /"), 1,
		"rm -rf / requires approval");
	t.asserteq(needsapproval("exec", "rm -rf /home/user"), 1,
		"rm -rf /home/user requires approval");
}

testExecRmInTmpAllowed(t: ref T)
{
	# Cleanup inside the sandbox is allowed without prompting — the agent
	# uses /tmp/veltro/scratch heavily and prompting for every cleanup
	# would render the agent unusable.
	t.asserteq(needsapproval("exec", "rm -rf /tmp/scratch"), 0,
		"rm -rf inside /tmp ok");
	t.asserteq(needsapproval("exec", "rm -r /tmp/veltro/foo"), 0,
		"rm -r inside /tmp ok");
}

testExecRmEmbeddedInPipelineRequiresApproval(t: ref T)
{
	# 'rm' is not the first word — the !hasprefix guard catches this.
	# The shell would still execute it, so it must require approval.
	t.asserteq(needsapproval("exec", "ls /tmp; rm -r /home/user/data"), 1,
		"rm -r in shell pipeline (not first cmd) requires approval");
}

testExecRmWithoutDashRAllowed(t: ref T)
{
	# rm without -r doesn't trigger the rule (rm of single files isn't
	# considered as dangerous as recursive deletion)
	t.asserteq(needsapproval("exec", "rm /tmp/file"), 0,
		"rm without -r in /tmp ok");
	# But check the special case: if "rm" appears but "-r" doesn't, the
	# whole gate is skipped.
	t.asserteq(needsapproval("exec", "rm /home/user/file"), 0,
		"rm without -r outside /tmp ok (rule only catches -r)");
}

# ============================================================================
# exec: namespace mutation requires approval
# ============================================================================

testExecBindRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("exec", "bind /n/local/tmp /tmp"), 1,
		"bind requires approval");
}

testExecMountRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("exec", "mount -c #s/srv /n/foo"), 1,
		"mount requires approval");
}

testExecUnmountRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("exec", "unmount /n/foo"), 1,
		"unmount requires approval");
}

testExecBindWithoutSpaceAllowed(t: ref T)
{
	# The rule looks for "bind " (with trailing space) — words like
	# "rebind" or "binds" must not match.  This is a deliberate check
	# for the keyword-as-command form.
	t.asserteq(needsapproval("exec", "echo hello rebinds the keyboard"), 0,
		"'rebinds' isn't bind");
	t.asserteq(needsapproval("exec", "echo mounted today"), 0,
		"'mounted' isn't mount");
}

testExecOrdinaryCommandsAllowed(t: ref T)
{
	# Most exec calls should sail through without prompting
	t.asserteq(needsapproval("exec", "ls /"), 0, "ls ok");
	t.asserteq(needsapproval("exec", "cat /tmp/x"), 0, "cat ok");
	t.asserteq(needsapproval("exec", "echo hello"), 0, "echo ok");
	t.asserteq(needsapproval("exec", "wc -l /tmp/file"), 0, "wc ok");
}

# ============================================================================
# write/edit: system path protection
# ============================================================================

testWriteToDisRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("write", "/dis/sh.dis hello"), 1,
		"write to /dis requires approval");
	t.asserteq(needsapproval("edit", "/dis/sh.dis old new"), 1,
		"edit /dis requires approval");
}

testWriteToLibRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("write", "/lib/veltro/system.txt new prompt"), 1,
		"write to /lib requires approval");
	t.asserteq(needsapproval("edit", "/lib/veltro/system.txt old new"), 1,
		"edit /lib requires approval");
}

testWriteToDevRequiresApproval(t: ref T)
{
	t.asserteq(needsapproval("write", "/dev/cons hi"), 1,
		"write to /dev requires approval");
	t.asserteq(needsapproval("edit", "/dev/cons old new"), 1,
		"edit /dev requires approval");
}

testWriteToTmpAllowed(t: ref T)
{
	t.asserteq(needsapproval("write", "/tmp/scratch.txt hello"), 0,
		"write to /tmp ok");
	t.asserteq(needsapproval("edit", "/tmp/scratch.txt old new"), 0,
		"edit /tmp ok");
}

testWriteToHomeAllowed(t: ref T)
{
	# /home, /n/local, /usr — all sandbox-y or user-grant paths
	t.asserteq(needsapproval("write", "/home/user/file hello"), 0,
		"write to /home ok");
	t.asserteq(needsapproval("write", "/n/local/Users/x hello"), 0,
		"write to /n/local ok");
}

testWriteRelativePathAllowed(t: ref T)
{
	# Relative paths can't reach /dis, /lib, /dev (the gate is path-prefix
	# based), so they're allowed.  This pins that behaviour — any change
	# would be a security-relevant policy shift.
	t.asserteq(needsapproval("write", "scratch.txt hello"), 0,
		"write to relative path ok");
}

# ============================================================================
# Other tools never require approval
# ============================================================================

testOtherToolsNeverApproval(t: ref T)
{
	# Tools not in the {exec, write, edit} set should always return 0.
	t.asserteq(needsapproval("spawn", "tools=write -- write /dis/x"), 0,
		"spawn never requires approval (gating happens inside spawn)");
	t.asserteq(needsapproval("safeexec", "write /dis/x"), 0,
		"safeexec never requires approval at this layer");
	t.asserteq(needsapproval("plan", "make a plan"), 0,
		"plan never requires approval");
	t.asserteq(needsapproval("memory", "save k v"), 0,
		"memory ops never require approval");
}

# ============================================================================
# firstlines: preview truncation
# ============================================================================

testFirstlinesShorterThanBuffer(t: ref T)
{
	r := firstlines("a\nb\nc\n", 10);
	t.assertseq(r, "a\nb\nc\n",
		"input shorter than n returned in full");
}

testFirstlinesExactN(t: ref T)
{
	# Exactly n newlines: returns up to and including the nth newline.
	# This matches the production implementation: count++ happens when
	# s[i] == '\n', and the loop exits when count >= n at the next
	# iteration.
	r := firstlines("a\nb\nc\nd\n", 3);
	t.assertseq(r, "a\nb\nc\n",
		"first 3 lines returned with terminating newline");
}

testFirstlinesTrunc(t: ref T)
{
	r := firstlines("a\nb\nc\nd\ne\nf\n", 2);
	t.assertseq(r, "a\nb\n",
		"truncated to first 2 lines");
}

testFirstlinesZero(t: ref T)
{
	r := firstlines("a\nb\nc\n", 0);
	t.assertseq(r, "",
		"n=0 returns empty string");
}

testFirstlinesNoNewlines(t: ref T)
{
	# A tool result with no terminating newline: returns the whole string
	r := firstlines("oneline", 5);
	t.assertseq(r, "oneline",
		"no newlines returns whole string");
}

testFirstlinesEmptyInput(t: ref T)
{
	r := firstlines("", 5);
	t.assertseq(r, "",
		"empty input returns empty string");
}

testFirstlinesPreservesContent(t: ref T)
{
	# Non-ascii / special chars within the kept lines must survive
	r := firstlines("hello world\ntab\there\n", 1);
	t.assertseq(r, "hello world\n",
		"first line preserves spaces");
}

# ============================================================================
# Main
# ============================================================================

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

	# Read-class tools
	run("ReadNeverApproval", testReadNeverApproval);

	# exec rm rules
	run("ExecRmRfRootRequiresApproval", testExecRmRfRootRequiresApproval);
	run("ExecRmInTmpAllowed", testExecRmInTmpAllowed);
	run("ExecRmEmbeddedInPipelineRequiresApproval", testExecRmEmbeddedInPipelineRequiresApproval);
	run("ExecRmWithoutDashRAllowed", testExecRmWithoutDashRAllowed);

	# exec ns mutation
	run("ExecBindRequiresApproval", testExecBindRequiresApproval);
	run("ExecMountRequiresApproval", testExecMountRequiresApproval);
	run("ExecUnmountRequiresApproval", testExecUnmountRequiresApproval);
	run("ExecBindWithoutSpaceAllowed", testExecBindWithoutSpaceAllowed);
	run("ExecOrdinaryCommandsAllowed", testExecOrdinaryCommandsAllowed);

	# write / edit system-path protection
	run("WriteToDisRequiresApproval", testWriteToDisRequiresApproval);
	run("WriteToLibRequiresApproval", testWriteToLibRequiresApproval);
	run("WriteToDevRequiresApproval", testWriteToDevRequiresApproval);
	run("WriteToTmpAllowed", testWriteToTmpAllowed);
	run("WriteToHomeAllowed", testWriteToHomeAllowed);
	run("WriteRelativePathAllowed", testWriteRelativePathAllowed);

	# Tools outside the gated set
	run("OtherToolsNeverApproval", testOtherToolsNeverApproval);

	# firstlines
	run("FirstlinesShorterThanBuffer", testFirstlinesShorterThanBuffer);
	run("FirstlinesExactN", testFirstlinesExactN);
	run("FirstlinesTrunc", testFirstlinesTrunc);
	run("FirstlinesZero", testFirstlinesZero);
	run("FirstlinesNoNewlines", testFirstlinesNoNewlines);
	run("FirstlinesEmptyInput", testFirstlinesEmptyInput);
	run("FirstlinesPreservesContent", testFirstlinesPreservesContent);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
