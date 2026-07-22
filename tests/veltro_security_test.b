implement VeltroSecurityTest;

#
# Veltro Namespace Security Tests (v3)
#
# Tests verify the security properties of the FORKNS + bind-replace
# namespace isolation model.
#
# Security Properties Tested:
#    1. restrictdir() allowlist - only allowed items visible after bind-replace
#    2. restrictdir() exclusion - non-allowed items invisible
#    3. restrictdir() idempotent - can be called multiple times safely
#    4. restrictns() full policy - /dis, /dev, /n, /lib, /tmp restricted
#    5. restrictns() with paths - granted paths remain accessible
#    6. restrictns() with shellcmds - grants sh.dis + named commands
#    7. restrictns() concurrency - concurrent restriction calls are safe
#    8. verifyns() - catches namespace violations
#    9. Audit logging - restriction operations recorded
#   10. /tmp writable after restriction (MCREATE on shadow bind)
#   11. exec in tools grants sh.dis (shell interpreter needed by exec tool)
#   12. caps.paths exposes granted /n/local/ subtree
#   13. pctl(NODEVS) blocks attach of devices outside |esDa allowlist
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

VeltroSecurityTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

# Include nsconstruct for testing
include "nsconstruct.m";
	nsconstruct: NsConstruct;

# Source file path for clickable error addresses
SRCFILE: con "/tests/veltro_security_test.b";

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
# Test 1: RestrictDir - Allowlist
# Verifies that restrictdir() makes only allowed items visible
# ============================================================================
testRestrictDir(t: ref T)
{
	result := chan of string;
	spawn restrictDirWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

restrictDirWorker(result: chan of string)
{
	# Fork namespace so restriction doesn't affect test runner
	sys->pctl(Sys->FORKNS, nil);

	# Create test directory with known contents
	testdir := "/tmp/veltro/test-restrict";
	mkdirp(testdir);
	mkdirp(testdir + "/keepdir");
	mkdirp(testdir + "/removedir");
	createfile(testdir + "/keep.txt");
	createfile(testdir + "/remove.txt");

	# Restrict to only "keepdir" and "keep.txt"
	err := nsconstruct->restrictdir(testdir, "keepdir" :: "keep.txt" :: nil, 0);
	if(err != nil) {
		result <-= sys->sprint("restrictdir failed: %s", err);
		return;
	}

	# Verify allowed items are visible
	(ok1, nil) := sys->stat(testdir + "/keepdir");
	if(ok1 < 0) {
		result <-= "keepdir should be visible after restrictdir";
		return;
	}

	(ok2, nil) := sys->stat(testdir + "/keep.txt");
	if(ok2 < 0) {
		result <-= "keep.txt should be visible after restrictdir";
		return;
	}

	# Verify removed items are NOT visible
	(ok3, nil) := sys->stat(testdir + "/removedir");
	if(ok3 >= 0) {
		result <-= "removedir should NOT be visible after restrictdir";
		return;
	}

	(ok4, nil) := sys->stat(testdir + "/remove.txt");
	if(ok4 >= 0) {
		result <-= "remove.txt should NOT be visible after restrictdir";
		return;
	}

	result <-= "";  # Success
}

# ============================================================================
# Test 2: RestrictDir - Exclusion
# Verifies that items NOT in allowed list are truly invisible
# ============================================================================
testRestrictDirExclusion(t: ref T)
{
	result := chan of string;
	spawn restrictDirExclusionWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

restrictDirExclusionWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Create test directory with many items
	testdir := "/tmp/veltro/test-exclusion";
	mkdirp(testdir);
	items := array[] of {"a", "b", "c", "d", "e"};
	for(i := 0; i < len items; i++)
		createfile(testdir + "/" + items[i]);

	# Allow only "b" and "d"
	err := nsconstruct->restrictdir(testdir, "b" :: "d" :: nil, 0);
	if(err != nil) {
		result <-= sys->sprint("restrictdir failed: %s", err);
		return;
	}

	# Read directory - should only contain "b" and "d"
	fd := sys->open(testdir, Sys->OREAD);
	if(fd == nil) {
		result <-= "cannot open restricted directory";
		return;
	}

	visible: list of string;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(j := 0; j < n; j++)
			visible = dirs[j].name :: visible;
	}
	fd = nil;

	# Count visible items - should be exactly 2
	count := 0;
	for(v := visible; v != nil; v = tl v)
		count++;

	if(count != 2) {
		result <-= sys->sprint("expected 2 visible items, got %d", count);
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 3: RestrictDir - Idempotent
# Verifies restrictdir() can be called multiple times safely
# ============================================================================
testBindReplaceIdempotent(t: ref T)
{
	result := chan of string;
	spawn idempotentWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

idempotentWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	testdir := "/tmp/veltro/test-idempotent";
	mkdirp(testdir);
	mkdirp(testdir + "/a");
	mkdirp(testdir + "/b");
	mkdirp(testdir + "/c");

	# First restriction: allow a, b
	err := nsconstruct->restrictdir(testdir, "a" :: "b" :: nil, 0);
	if(err != nil) {
		result <-= sys->sprint("first restrictdir failed: %s", err);
		return;
	}

	# Second restriction: narrow to just a
	err = nsconstruct->restrictdir(testdir, "a" :: nil, 0);
	if(err != nil) {
		result <-= sys->sprint("second restrictdir failed: %s", err);
		return;
	}

	# Only "a" should be visible
	(ok1, nil) := sys->stat(testdir + "/a");
	if(ok1 < 0) {
		result <-= "a should be visible after second restrictdir";
		return;
	}

	(ok2, nil) := sys->stat(testdir + "/b");
	if(ok2 >= 0) {
		result <-= "b should NOT be visible after second restrictdir";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 4: RestrictNs - Full Policy
# Verifies restrictns() applies the complete restriction policy
# ============================================================================
testRestrictNs(t: ref T)
{
	createdkeys := 0;
	(ok, nil) := sys->stat("/lib/veltro/keys");
	if(ok < 0) {
		fd := sys->create("/lib/veltro/keys", Sys->OREAD, Sys->DMDIR | 8r700);
		if(fd == nil) {
			t.skip("cannot create legacy key-directory fixture");
			return;
		}
		fd = nil;
		createdkeys = 1;
	}
	canary := "/lib/veltro/keys/ns-secret-canary";
	fd := sys->create(canary, Sys->OWRITE, 8r600);
	if(fd == nil) {
		if(createdkeys)
			sys->remove("/lib/veltro/keys");
		t.skip("cannot create legacy key fixture");
		return;
	}
	sys->fprint(fd, "synthetic-secret");
	fd = nil;
	sys->create("/tmp/veltro/tasks", Sys->OREAD, Sys->DMDIR | 8r700);
	taskcanary := "/tmp/veltro/tasks/instructions.99999";
	fd = sys->create(taskcanary, Sys->OWRITE, 8r600);
	if(fd == nil) {
		sys->remove(canary);
		if(createdkeys)
			sys->remove("/lib/veltro/keys");
		t.skip("cannot create task metadata fixture");
		return;
	}
	sys->fprint(fd, "hostile-message-body");
	fd = nil;
	result := chan of string;
	spawn restrictNsWorker(result);

	r := <-result;
	sys->remove(taskcanary);
	sys->remove(canary);
	if(createdkeys)
		sys->remove("/lib/veltro/keys");
	if(r != "")
		t.error(r);
}

restrictNsWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Build minimal capabilities
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,        # tools
		nil,                  # paths
		nil,                  # shellcmds — no shell
		nil,                  # llmconfig
		0 :: 1 :: 2 :: nil,   # fds
		nil,                  # mcproviders
		0,                    # memory
		0,                    # xenith
		-1,                   # actid
		nil
	, nil);

	# Apply namespace restriction
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	# Verify /dis/lib is accessible (essential runtime)
	(ok1, nil) := sys->stat("/dis/lib");
	if(ok1 < 0) {
		result <-= "/dis/lib should be accessible after restrictns";
		return;
	}

	# Verify /dis/veltro is accessible
	(ok2, nil) := sys->stat("/dis/veltro");
	if(ok2 < 0) {
		result <-= "/dis/veltro should be accessible after restrictns";
		return;
	}

	# Verify /dev/cons is accessible
	(ok3, nil) := sys->stat("/dev/cons");
	if(ok3 < 0) {
		result <-= "/dev/cons should be accessible after restrictns";
		return;
	}

	# Verify /dev/null is accessible
	(ok4, nil) := sys->stat("/dev/null");
	if(ok4 < 0) {
		result <-= "/dev/null should be accessible after restrictns";
		return;
	}

	# Verify /tmp/veltro/scratch is accessible
	(ok5, nil) := sys->stat("/tmp/veltro/scratch");
	if(ok5 < 0) {
		result <-= "/tmp/veltro/scratch should be accessible after restrictns";
		return;
	}

	# Least privilege: with NO /mnt grant in caps.paths, a confined child sees no
	# /mnt at all — not even /mnt/llm. The model service is NOT granted by mere
	# existence; an agent that needs it lists /mnt/llm in caps.paths (repl), and a
	# spawned sub-agent drives the LLM through a pre-opened FD that survives the
	# restriction. (mntgen would make /mnt/llm *stat* as present in the parent ns;
	# the root-level restriction is what hides /mnt here.)
	(llmok, nil) := sys->stat("/mnt/llm");
	if(llmok >= 0) {
		result <-= "/mnt/llm must NOT be visible without an explicit /mnt grant (least privilege)";
		return;
	}

	(acmeok, nil) := sys->stat("/mnt/acme");
	if(acmeok >= 0) {
		result <-= "/mnt/acme must NOT be visible without a grant";
		return;
	}

	(netok, nil) := sys->stat("/net");
	if(netok >= 0) {
		result <-= "/net must NOT be visible without a network tool capability";
		return;
	}
	(fdok, nil) := sys->stat("/fd");
	if(fdok >= 0) {
		result <-= "/fd must NOT expose inherited descriptors";
		return;
	}
	(nvok, nil) := sys->stat("/nvfs");
	if(nvok >= 0) {
		result <-= "/nvfs must NOT expose node identity state";
		return;
	}
	(nsstateok, nil) := sys->stat("/tmp/.veltro-ns");
	if(nsstateok >= 0) {
		result <-= "trusted namespace construction state remains visible";
		return;
	}
	(taskok, nil) := sys->stat("/tmp/veltro/tasks/instructions.99999");
	if(taskok >= 0) {
		result <-= "ordinary tool can read another activity task prompt";
		return;
	}

	(keyok, nil) := sys->stat("/lib/veltro/keys/ns-secret-canary");
	if(keyok >= 0) {
		result <-= "legacy plaintext credential remained visible";
		return;
	}

	result <-= "";
}

testTaskMetadataCapability(t: ref T)
{
	fd := sys->create("/tmp/veltro/tasks/instructions.99998", Sys->OWRITE, 8r600);
	if(fd == nil) {
		t.skip("cannot create task metadata capability fixture");
		return;
	}
	sys->fprint(fd, "task-only");
	fd = nil;
	result := chan of string;
	spawn taskMetadataCapabilityWorker(result);
	r := <-result;
	sys->remove("/tmp/veltro/tasks/instructions.99998");
	if(r != "")
		t.error(r);
}

taskMetadataCapabilityWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"task" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (task tool) failed: %s", err);
		return;
	}
	(ok, nil) := sys->stat("/tmp/veltro/tasks/instructions.99998");
	if(ok < 0) {
		result <-= "task tool cannot access task metadata exchange";
		return;
	}
	result <-= "";
}

testTmpVeltroIpcHidden(t: ref T)
{
	sys->create("/tmp/veltro/ftree", Sys->OREAD, Sys->DMDIR | 8r755);
	fd := sys->create("/tmp/veltro/ftree/ctl", Sys->OWRITE, 8r666);
	if(fd == nil) {
		t.skip("cannot create ftree IPC fixture");
		return;
	}
	sys->fprint(fd, "refresh");
	fd = nil;
	result := chan of string;
	spawn tmpVeltroIpcHiddenWorker(result);
	r := <-result;
	sys->remove("/tmp/veltro/ftree/ctl");
	sys->remove("/tmp/veltro/ftree");
	if(r != "")
		t.error(r);
}

tmpVeltroIpcHiddenWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrict tmp IPC worker: %s", err);
		return;
	}
	(ok, nil) := sys->stat("/tmp/veltro/ftree/ctl");
	if(ok >= 0) {
		result <-= "restricted agent can reach trusted ftree IPC";
		return;
	}
	result <-= "";
}

testTmpVeltroExplicitGrant(t: ref T)
{
	sys->create("/tmp/veltro/shared", Sys->OREAD, Sys->DMDIR | 8r755);
	fd := sys->create("/tmp/veltro/shared/state", Sys->OWRITE, 8r666);
	if(fd == nil) {
		t.skip("cannot create shared tmp fixture");
		return;
	}
	sys->fprint(fd, "open");
	fd = nil;
	result := chan of string;
	spawn tmpVeltroExplicitGrantWorker(result);
	r := <-result;
	sys->remove("/tmp/veltro/shared/state");
	sys->remove("/tmp/veltro/shared");
	if(r != "")
		t.error(r);
}

tmpVeltroExplicitGrantWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, "/tmp/veltro/shared" :: nil, nil, nil,
		0 :: 1 :: 2 :: nil, nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrict tmp explicit worker: %s", err);
		return;
	}
	(ok, nil) := sys->stat("/tmp/veltro/shared/state");
	if(ok < 0) {
		result <-= "explicit /tmp/veltro/shared grant missing";
		return;
	}
	result <-= "";
}

testTmpVeltroTrustedIpcNotGrantable(t: ref T)
{
	result := chan of string;
	spawn tmpVeltroTrustedIpcNotGrantableWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

tmpVeltroTrustedIpcNotGrantableWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, "/tmp/veltro/ftree" :: nil, nil, nil,
		0 :: 1 :: 2 :: nil, nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err == nil) {
		result <-= "trusted ftree IPC grant unexpectedly succeeded";
		return;
	}
	result <-= "";
}

testActivityScratchIsolation(t: ref T)
{
	sys->remove("/tmp/veltro/scratch/41001/canary");
	sys->remove("/tmp/veltro/scratch/41001");
	sys->remove("/tmp/veltro/scratch/41002/canary");
	sys->remove("/tmp/veltro/scratch/41002");
	result := chan of string;
	spawn activityScratchWriter(result, 41001);
	r := <-result;
	if(r == "") {
		spawn activityScratchReader(result, 41002);
		r = <-result;
	}
	(ok, nil) := sys->stat("/tmp/veltro/scratch/41001/canary");
	if(r == "" && ok < 0)
		r = "activity scratch write did not reach its backing directory";
	sys->remove("/tmp/veltro/scratch/41001/canary");
	sys->remove("/tmp/veltro/scratch/41001");
	sys->remove("/tmp/veltro/scratch/41002/canary");
	sys->remove("/tmp/veltro/scratch/41002");
	if(r != "")
		t.error(r);
}

activityScratchWriter(result: chan of string, id: int)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"write" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, id, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrict writer scratch: %s", err);
		return;
	}
	fd := sys->create("/tmp/veltro/scratch/canary", Sys->OWRITE, 8r600);
	if(fd == nil) {
		result <-= sys->sprint("create activity scratch canary: %r");
		return;
	}
	sys->fprint(fd, "activity-secret");
	result <-= "";
}

activityScratchReader(result: chan of string, id: int)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, id, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrict reader scratch: %s", err);
		return;
	}
	(ok, nil) := sys->stat("/tmp/veltro/scratch/canary");
	if(ok >= 0) {
		result <-= "activity can read another activity's scratch file";
		return;
	}
	result <-= "";
}

testNetworkCapability(t: ref T)
{
	result := chan of string;
	spawn networkCapabilityWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

networkCapabilityWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"webfetch" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (network tool) failed: %s", err);
		return;
	}
	(netok, nil) := sys->stat("/net");
	if(netok < 0) {
		result <-= "/net missing with explicit webfetch capability";
		return;
	}
	result <-= "";
}

# ============================================================================
# Test 5: RestrictNs - Shell via shellcmds
# Verifies that sh.dis + named commands appear when shellcmds is set
# ============================================================================
testRestrictNsShell(t: ref T)
{
	result := chan of string;
	spawn shellWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

shellWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# shellcmds non-nil → sh.dis + cat.dis should appear in /dis
	caps := ref NsConstruct->Capabilities(
		"read" :: "exec" :: nil,  # tools
		nil,                      # paths
		"cat" :: nil,             # shellcmds — grants sh.dis + cat.dis
		nil,                      # llmconfig
		0 :: 1 :: 2 :: nil,       # fds
		nil,                      # mcproviders
		0,                        # memory
		0,                        # xenith
		-1,                       # actid
		nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (shell) failed: %s", err);
		return;
	}

	# Verify sh.dis is accessible
	(shok, nil) := sys->stat("/dis/sh.dis");
	if(shok < 0) {
		result <-= "shellcmds should grant /dis/sh.dis";
		return;
	}

	# Verify granted shell command is accessible
	(catok, nil) := sys->stat("/dis/cat.dis");
	if(catok < 0) {
		result <-= "shellcmds should grant /dis/cat.dis";
		return;
	}
	(netok, nil) := sys->stat("/net");
	if(netok >= 0) {
		result <-= "exec shell capability exposes raw network devices";
		return;
	}
	(fdok, nil) := sys->stat("/fd");
	if(fdok >= 0) {
		result <-= "exec shell capability exposes inherited descriptors";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 5b: RestrictNs - /mnt application mount points (MCP adapters)
# Verifies that an explicit "/mnt/mcp" path grant exposes /mnt/mcp but NOT
# sibling /mnt entries — the least-privilege gate behind the sub-agent MCP
# bridge (INFR-252/INFR-247, docs/NAMESPACE-LAYOUT.md).
# ============================================================================
testRestrictNsMnt(t: ref T)
{
	result := chan of string;
	spawn mntWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

mntWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Grant exactly the /mnt/mcp subtree via caps.paths.
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,            # tools
		"/mnt/mcp" :: nil,        # paths — grants the /mnt/mcp application mount
		nil,                      # shellcmds
		nil,                      # llmconfig
		0 :: 1 :: 2 :: nil,       # fds
		nil,                      # mcproviders
		0,                        # memory
		0,                        # xenith
		-1,                       # actid
		nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (mnt) failed: %s", err);
		return;
	}

	# Granted subtree must be visible.
	(mcpok, nil) := sys->stat("/mnt/mcp");
	if(mcpok < 0) {
		result <-= "/mnt/mcp should be accessible when granted via caps.paths";
		return;
	}

	# A sibling /mnt entry that was NOT granted must be restricted away.
	# /mnt/acme ships as a real mount-point placeholder in the tree, so if the
	# grant leaked the whole /mnt it would be visible here.
	(acmeok, nil) := sys->stat("/mnt/acme");
	if(acmeok >= 0) {
		result <-= "/mnt/acme must NOT be visible when only /mnt/mcp is granted (least-privilege leak)";
		return;
	}

	result <-= "";
}

# An explicit LLM grant must expose only that service. This is the positive
# counterpart to restrictNsWorker's assertion that /mnt/llm is hidden by
# default, and pins the path-based contract used by the top-level agent loop.
testRestrictNsMntLlm(t: ref T)
{
	created := 0;
	(ok, nil) := sys->stat("/mnt/llm");
	if(ok < 0) {
		fd := sys->create("/mnt/llm", Sys->OREAD, Sys->DMDIR | 8r755);
		if(fd == nil) {
			t.skip("cannot create /mnt/llm test fixture");
			return;
		}
		fd = nil;
		created = 1;
	}
	result := chan of string;
	spawn mntLlmWorker(result);
	r := <-result;
	if(created)
		sys->remove("/mnt/llm");
	if(r != "")
		t.error(r);
}

mntLlmWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		"/mnt/llm" :: nil,
		nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (llm grant) failed: %s", err);
		return;
	}
	(llmok, nil) := sys->stat("/mnt/llm");
	if(llmok < 0) {
		result <-= "/mnt/llm missing with explicit grant";
		return;
	}
	(mcpok, nil) := sys->stat("/mnt/mcp");
	if(mcpok >= 0) {
		result <-= "ungranted /mnt/mcp visible with only /mnt/llm granted";
		return;
	}
	(acmeok, nil) := sys->stat("/mnt/acme");
	if(acmeok >= 0) {
		result <-= "ungranted /mnt/acme visible with only /mnt/llm granted";
		return;
	}
	result <-= "";
}


# Combined /mnt grants must compose rather than replace one another.
testRestrictNsMntCombined(t: ref T)
{
	fd := sys->create("/mnt/combined", Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd == nil) {
		t.skip("cannot create combined /mnt test fixture");
		return;
	}
	fd = nil;
	result := chan of string;
	spawn mntCombinedWorker(result);
	r := <-result;
	sys->remove("/mnt/combined");
	if(r != "")
		t.error(r);
}

mntCombinedWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	provider := ref NsConstruct->MCProvider("test-provider", nil, 0);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		"/mnt/combined" :: nil,
		nil,
		nil,
		0 :: 1 :: 2 :: nil,
		provider :: nil,
		0,
		0,
		-1,
		nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (combined mnt) failed: %s", err);
		return;
	}
	(combinedok, nil) := sys->stat("/mnt/combined");
	if(combinedok < 0) {
		result <-= "/mnt/combined missing from combined grant";
		return;
	}
	(mcpok, nil) := sys->stat("/mnt/mcp");
	if(mcpok < 0) {
		result <-= "/mnt/mcp missing when mcproviders is combined with another /mnt grant";
		return;
	}
	(acmeok, nil) := sys->stat("/mnt/acme");
	if(acmeok >= 0) {
		result <-= "ungranted /mnt sibling visible in combined grant";
		return;
	}
	result <-= "";
}

# mcpdeny must attenuate inside a granted MCP server without dropping sibling
# tools. This pins the defense-in-depth path used by spawn.b before MCP discovery.
testRestrictNsMcpDeny(t: ref T)
{
	base := "/mnt/mcp/codexdeny";
	mkdirp(base + "/_meta");
	writefilecontent(base + "/_meta/name", "codexdeny\n");
	mkdirp(base + "/tools/weather");
	createfile(base + "/tools/weather/call");
	mkdirp(base + "/tools/geocode");
	createfile(base + "/tools/geocode/call");

	(ok, nil) := sys->stat(base + "/tools/geocode/call");
	if(ok < 0) {
		t.skip("cannot create synthetic /mnt/mcp test fixture");
		return;
	}

	result := chan of string;
	spawn mcpDenyWorker(result);
	r := <-result;

	sys->remove(base + "/tools/geocode/call");
	sys->remove(base + "/tools/geocode");
	sys->remove(base + "/tools/weather/call");
	sys->remove(base + "/tools/weather");
	sys->remove(base + "/tools");
	sys->remove(base + "/_meta/name");
	sys->remove(base + "/_meta");
	sys->remove(base);

	if(r != "")
		t.error(r);
}

mcpDenyWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		"/mnt/mcp/codexdeny" :: nil,
		nil,
		nil,
		0 :: 1 :: 2 :: nil,
		nil,
		0,
		0,
		-1,
		nil,
		"geocode" :: nil
	);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (mcpdeny) failed: %s", err);
		return;
	}

	(weatherok, nil) := sys->stat("/mnt/mcp/codexdeny/tools/weather/call");
	if(weatherok < 0) {
		result <-= "mcpdeny hid an allowed MCP tool";
		return;
	}
	(geocodeok, nil) := sys->stat("/mnt/mcp/codexdeny/tools/geocode/call");
	if(geocodeok >= 0) {
		result <-= "mcpdeny left a denied MCP tool call path visible";
		return;
	}
	(acmeok, nil) := sys->stat("/mnt/acme");
	if(acmeok >= 0) {
		result <-= "mcpdeny grant leaked an unrelated /mnt sibling";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 6: RestrictNs - Concurrent
# Verifies concurrent restrictns calls don't race
# ============================================================================
testRestrictNsRace(t: ref T)
{
	done := chan of int;
	errors := chan of string;
	nthreads := 3;

	for(i := 0; i < nthreads; i++)
		spawn raceWorker(done, errors);

	# Collect results
	errs: list of string;
	for(i = 0; i < nthreads; i++) {
		alt {
		e := <-errors =>
			errs = e :: errs;
		<-done =>
			;
		}
	}

	t.assert(errs == nil, "all concurrent restrictns calls should succeed");
	for(; errs != nil; errs = tl errs)
		t.log(hd errs);
}

raceWorker(done: chan of int, errors: chan of string)
{
	# Each worker forks its own namespace
	sys->pctl(Sys->FORKNS, nil);

	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		nil,
		nil,
		nil,
		0 :: 1 :: 2 :: nil,
		nil,
		0,
		0,
		-1,
		nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil)
		errors <-= sys->sprint("restrictns race failed: %s", err);
	else
		done <-= 1;
}

# ============================================================================
# Test 7: VerifyNs - Catches Violations
# Verifies that verifyns() detects expected paths
# ============================================================================
testVerifyNs(t: ref T)
{
	result := chan of string;
	spawn verifyNsWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

verifyNsWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Seed representative privileged control files before restriction. The
	# shared verifier must prove restriction hides real pre-existing controls,
	# not just paths absent from the test namespace.
	mkdirp("/tool");
	createfile("/tool/ctl");
	mkdirp("/mnt");
	mkdirp("/mnt/toolctl");
	createfile("/mnt/toolctl/ctl");
	mkdirp("/mnt/msg");
	createfile("/mnt/msg/status");
	createfile("/mnt/msg/ctl");
	createfile("/mnt/msg/pending");
	createfile("/mnt/msg/approve");
	createfile("/mnt/msg/deny");

	# Apply restrictions first
	caps := ref NsConstruct->Capabilities(
		nil, "/mnt/msg" :: nil, nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	# Verify with expected paths
	expected := "/dis/lib" :: "/dev/cons" :: "/mnt/msg/status" :: nil;
	verr := nsconstruct->verifyns(expected);
	if(verr != nil) {
		result <-= sys->sprint("verifyns failed: %s", verr);
		return;
	}

	# Verify with a missing expected path should fail
	bad := "/nonexistent/path" :: nil;
	verr = nsconstruct->verifyns(bad);
	if(verr == nil) {
		result <-= "verifyns should fail for missing expected path";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 8: Audit Log
# Verifies that emitauditlog writes correct audit log
# ============================================================================
testAuditLog(t: ref T)
{
	# Emit an audit log
	nsconstruct->emitauditlog("test-audit", "restrictdir /dis" :: "restrictdir /dev" :: nil);

	# Read audit log
	auditpath := "/tmp/.veltro-ns/audit/test-audit.ns";
	fd := sys->open(auditpath, Sys->OREAD);
	if(fd == nil) {
		t.error("cannot open audit log");
		return;
	}

	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;

	if(n <= 0) {
		t.error("audit log is empty");
		return;
	}

	content := string buf[0:n];

	# Verify audit log has header
	t.assert(contains(content, "Veltro Namespace Audit"),
		"audit log should have header");

	# Verify audit log has ID
	t.assert(contains(content, "test-audit"),
		"audit log should contain ID");

	# Verify audit log has operations
	t.assert(contains(content, "restrictdir"),
		"audit log should contain restriction operations");

	# Clean up
	sys->remove(auditpath);
}

# ============================================================================
# Test 9: RestrictDir - Nonexistent Items in Allowed List
# Verifies that restrictdir() gracefully skips items that don't exist
# ============================================================================
testRestrictDirMissing(t: ref T)
{
	result := chan of string;
	spawn restrictDirMissingWorker(result);

	r := <-result;
	if(r != "")
		t.error(r);
}

restrictDirMissingWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	testdir := "/tmp/veltro/test-missing";
	mkdirp(testdir);
	createfile(testdir + "/exists.txt");

	# Allow "exists.txt" and "nonexistent.txt"
	err := nsconstruct->restrictdir(testdir, "exists.txt" :: "nonexistent.txt" :: nil, 0);
	if(err != nil) {
		result <-= sys->sprint("restrictdir should not fail for missing items: %s", err);
		return;
	}

	# Verify existing item is still visible
	(ok, nil) := sys->stat(testdir + "/exists.txt");
	if(ok < 0) {
		result <-= "exists.txt should be visible";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 10: TmpWritable
# Verifies that /tmp is writable after restrictns (MCREATE on shadow bind).
# This was broken before: restrictdir used MREPL only, forbidding creates.
# ============================================================================
testTmpWritable(t: ref T)
{
	result := chan of string;
	spawn tmpWritableWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

tmpWritableWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	caps := ref NsConstruct->Capabilities(
		"write" :: nil,
		nil, nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	# Try creating a file under /tmp/veltro/scratch/
	testfile := "/tmp/veltro/scratch/mcreate_test.txt";
	fd := sys->create(testfile, Sys->OWRITE, 8r644);
	if(fd == nil) {
		result <-= sys->sprint("cannot create file under /tmp after restrictns: %r");
		return;
	}
	sys->fprint(fd, "mcreate test\n");
	fd = nil;

	# Verify file is readable
	(ok, nil) := sys->stat(testfile);
	if(ok < 0) {
		result <-= "created file not visible under /tmp/veltro";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 11: ExecGrantsShDis
# Verifies that "exec" in caps.tools grants /dis/sh.dis without shellcmds.
# The exec tool requires sh.dis to run shell commands.
# ============================================================================
testExecGrantsShDis(t: ref T)
{
	result := chan of string;
	spawn execGrantsShDisWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

execGrantsShDisWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# exec in tools, shellcmds=nil — exec detection should still add sh.dis
	caps := ref NsConstruct->Capabilities(
		"read" :: "exec" :: nil,
		nil, nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	# sh.dis must be accessible for exec tool to spawn a shell
	(shok, nil) := sys->stat("/dis/sh.dis");
	if(shok < 0) {
		result <-= "exec in caps.tools should grant /dis/sh.dis";
		return;
	}

	# Standard commands are NOT granted — exec provides sh.dis only
	# (commands like date.dis require shellcmds= to be explicit)

	result <-= "";
}

# ============================================================================
# Test 12: PathsExposure
# Verifies that caps.paths exposes the specified /n/local/ subtree and
# that paths outside the grant are NOT accessible.
# Skipped if /n/local is not available (headless test environment).
# ============================================================================
testPathsExposure(t: ref T)
{
	# Check if /n/local exists — required for this test
	(nlok, nil) := sys->stat("/n/local");
	if(nlok < 0) {
		t.skip("/n/local not available — skipping path exposure test");
		return;
	}

	result := chan of string;
	spawn pathsExposureWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

pathsExposureWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Find the first entry in /n/local to use as a grant target.
	# /n/local maps the host filesystem; content varies by machine.
	# We use whatever entry exists rather than assuming a specific name.
	fd := sys->open("/n/local", Sys->OREAD);
	if(fd == nil) {
		result <-= "cannot open /n/local";
		return;
	}
	(n, dirs) := sys->dirread(fd);
	fd = nil;
	if(n <= 0) {
		result <-= "/n/local is empty — cannot run path grant test";
		return;
	}
	grantname := dirs[0].name;
	grantpath := "/n/local/" + grantname;

	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		grantpath :: nil,
		nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns with paths failed: %s", err);
		return;
	}

	# Granted path must be accessible after restriction
	(tok, nil) := sys->stat(grantpath);
	if(tok < 0) {
		result <-= sys->sprint("%s should be accessible after path grant", grantpath);
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 13: NodevsBlocksDeviceAttach
# Verifies pctl(NODEVS) blocks attach of devices outside the |esDa kernel
# allowlist. Runtime ground-truth for the SECURITY.md "NODEVS short-term
# fix" applied at the three top-level FORKNS sites (repl.b:169,
# veltro.b:168, tools9p.b:644). Without this gate, a tool or exec
# invocation could sys->bind("#sfactotum", ...) and reach factotum
# regardless of path-based restriction (kernel gate at
# emu/port/chan.c:1041-1051).
# ============================================================================
testNodevsBlocksDeviceAttach(t: ref T)
{
	result := chan of string;
	spawn nodevsWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

nodevsWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Baseline: without NODEVS, bind on #p (proc device, not in |esDa)
	# should succeed. Establishes that the second bind failing is the
	# NODEVS gate, not "device unavailable" or some unrelated error.
	pos := "/tmp/nodevs-test-positive";
	sys->create(pos, Sys->OREAD, Sys->DMDIR | 8r700);
	rc1 := sys->bind("#p", pos, Sys->MREPL);
	if(rc1 < 0) {
		result <-= sys->sprint("baseline: bind(#p) failed without NODEVS: %r");
		return;
	}

	# Apply the gate.
	sys->pctl(Sys->NODEVS, nil);

	# With NODEVS set, bind on #p must fail: 'p' is not in the |esDa
	# allowlist at emu/port/chan.c:1050.
	neg := "/tmp/nodevs-test-negative";
	sys->create(neg, Sys->OREAD, Sys->DMDIR | 8r700);
	rc2 := sys->bind("#p", neg, Sys->MREPL);
	if(rc2 >= 0) {
		result <-= "bind(#p) succeeded after NODEVS — kernel gate did not fire";
		return;
	}

	# Also verify the SECURITY.md exemplar: #sfactotum (subspec of #s).
	# Even with #s itself in |esDa, the kernel disallows subspecs when
	# nodevs is set: r == 's' && genbuf[n] != '\0' triggers Enoattach.
	neg2 := "/tmp/nodevs-test-factotum";
	sys->create(neg2, Sys->OREAD, Sys->DMDIR | 8r700);
	rc3 := sys->bind("#sfactotum", neg2, Sys->MREPL);
	if(rc3 >= 0) {
		result <-= "bind(#sfactotum) succeeded after NODEVS — subspec gate did not fire";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 14: ToolCtlHidden
# Verifies restrictns() removes the generic /tool/ctl mutator from the agent
# view while preserving tool directories and the narrow /tool/provision path
# when task delegation is granted.
# ============================================================================
testToolCtlHidden(t: ref T)
{
	result := chan of string;
	spawn toolCtlHiddenWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

toolCtlHiddenWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	# Build a synthetic /tool tree so restrictns() can exercise its allowlist
	# behavior without requiring a running tools9p instance.
	mkdirp("/tool");
	createfile("/tool/tools");
	createfile("/tool/help");
	createfile("/tool/_registry");
	createfile("/tool/ctl");
	createfile("/tool/paths");
	createfile("/tool/budget");
	createfile("/tool/activity");
	createfile("/tool/provision");
	mkdirp("/tool/read");
	mkdirp("/tool/task");

	caps := ref NsConstruct->Capabilities(
		"read" :: "task" :: nil,
		nil, nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);

	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	(ctlok, nil) := sys->stat("/tool/ctl");
	if(ctlok >= 0) {
		result <-= "/tool/ctl should be hidden after restrictns";
		return;
	}

	(provok, nil) := sys->stat("/tool/provision");
	if(provok < 0) {
		result <-= "/tool/provision should remain visible for task delegation";
		return;
	}

	(readok, nil) := sys->stat("/tool/read");
	if(readok < 0) {
		result <-= "/tool/read should remain visible after restrictns";
		return;
	}

	(taskok, nil) := sys->stat("/tool/task");
	if(taskok < 0) {
		result <-= "/tool/task should remain visible after restrictns";
		return;
	}

	result <-= "";
}

# ============================================================================
# Test 15: InvalidGrantPathsRejected
# Verifies traversal-shaped capability paths fail before namespace mutation.
# A tools9p caller must not be able to force restrictns() to abort midway,
# because tools execute after restrictns() and a partial namespace can leave
# root-level project paths visible.
# ============================================================================
testInvalidGrantPathsRejected(t: ref T)
{
	result := chan of string;
	spawn invalidGrantPathsWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

invalidGrantPathsWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	bad := array[] of {
		"/",
		"/n/local/project/../secret",
		"/n/local/project/./secret",
		"/n/local/project//secret",
		"n/local/project",
	};

	for(i := 0; i < len bad; i++) {
		caps := ref NsConstruct->Capabilities(
			"read" :: nil,
			bad[i] :: nil,
			nil, nil,
			0 :: 1 :: 2 :: nil,
			nil, 0, 0, -1, nil
		, nil);
		err := nsconstruct->restrictns(caps);
		if(err == nil) {
			result <-= "restrictns accepted invalid grant path: " + bad[i];
			return;
		}
	}

	result <-= "";
}

testInvalidCapabilityNamesRejected(t: ref T)
{
	result := chan of string;
	spawn invalidCapabilityNamesWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

invalidCapabilityNamesWorker(result: chan of string)
{
	bad := array[] of {
		"../read",
		"wm/shell",
		"read,list",
		"read tool",
		".",
		"..",
	};

	for(i := 0; i < len bad; i++) {
		one := chan of string;
		spawn invalidCapabilityNameOne(bad[i], 1, one);
		r := <-one;
		if(r != "") {
			result <-= r;
			return;
		}
		one = chan of string;
		spawn invalidCapabilityNameOne(bad[i], 0, one);
		r = <-one;
		if(r != "") {
			result <-= r;
			return;
		}
	}

	result <-= "";
}

invalidCapabilityNameOne(name: string, toolname: int, result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	tools := "read" :: nil;
	shellcmds: list of string;
	if(toolname)
		tools = name :: nil;
	else {
		tools = "exec" :: nil;
		shellcmds = name :: nil;
	}

	caps := ref NsConstruct->Capabilities(
		tools,
		nil,
		shellcmds,
		nil,
		0 :: 1 :: 2 :: nil,
		nil,
		0,
		0,
		-1,
		nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err == nil) {
		if(toolname)
			result <-= "restrictns accepted invalid tool name: " + name;
		else
			result <-= "restrictns accepted invalid shell command name: " + name;
		return;
	}

	result <-= "";
}

testPrivilegedGrantPathsRejected(t: ref T)
{
	result := chan of string;
	spawn privilegedGrantPathsWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

privilegedGrantPathsWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	bad := array[] of {
		"/mnt/ui",
		"/mnt/ui/activity/0/conversation/ctl",
		"/mnt/ui/activity/0/context",
		"/mnt/ui/activity/0/presentation",
		"/mnt/matrix",
		"/mnt/matrix/composition",
		"/phone",
		"/phone/sms",
		"/mnt/msg/ctl",
		"/mnt/msg/ctl/session",
		"/n/wallet/alice/ctl",
		"/n/wallet/alice/ctl/session",
		"/mnt/mail/accounts/alice/compose",
		"/mnt/mail/accounts/alice/boxes/INBOX/1/draft-reply",
		"/tmp/veltro/.ns",
		"/tmp/veltro/cow",
		"/tmp/veltro/tasks",
		"/tmp/veltro/browser",
		"/tmp/veltro/editor",
		"/tmp/veltro/shell",
		"/tmp/veltro/fractal",
		"/tmp/veltro/man",
	};

	for(i := 0; i < len bad; i++) {
		caps := ref NsConstruct->Capabilities(
			"read" :: nil,
			bad[i] :: nil,
			nil, nil,
			0 :: 1 :: 2 :: nil,
			nil, 0, 0, -1, nil
		, nil);
		err := nsconstruct->restrictns(caps);
		if(err == nil) {
			result <-= "restrictns accepted privileged grant path: " + bad[i];
			return;
		}
	}

	result <-= "";
}

testSafeGrantPathsAccepted(t: ref T)
{
	result := chan of string;
	spawn safeGrantPathsWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

safeGrantPathsWorker(result: chan of string)
{
	good := array[] of {
		"/tmp",
		"/tmp/veltro/scratch",
		"/mnt/msg",
		"/mnt/msg/draft",
	};

	for(i := 0; i < len good; i++) {
		one := chan of string;
		spawn safeGrantPathOne(good[i], one);
		r := <-one;
		if(r != "") {
			result <-= r;
			return;
		}
	}

	result <-= "";
}

safeGrantPathOne(path: string, result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);

	mkdirp("/mnt/msg");
	createfile("/mnt/msg/status");
	createfile("/mnt/msg/draft");
	mkdirp("/tmp/veltro/scratch");

	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		path :: nil,
		nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= "restrictns rejected safe grant path " + path + ": " + err;
		return;
	}

	result <-= "";
}

# A path that treats an existing file as a directory must fail closed. Otherwise
# recursive restriction can expose the parent file after the deeper bind fails.
testInvalidGrantTypeRejected(t: ref T)
{
	result := chan of string;
	spawn invalidGrantTypeWorker(result);
	r := <-result;
	if(r != "")
		t.error(r);
}

invalidGrantTypeWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil,
		"/appl/veltro/veltro.b/subpath" :: nil,
		nil, nil,
		0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err == nil) {
		result <-= "restrictns accepted a grant below a regular file";
		return;
	}
	result <-= "";
}


# ============================================================================
# Test 16: StagedWriteManifest
# Verifies the staged-write backend contract that writable granted paths are
# surfaced as perm=cow in the namespace manifest when writepaths + actid are
# present. Full cowfs lifecycle tests still live separately because mounted
# cowfs servers do not yet tear down cleanly inside the Limbo unit runner.
# ============================================================================
testStagedWriteOverlay(t: ref T)
{
	base := "/tmp/veltro/cowgrant";
	mkdirp(base);
	writefilecontent(base + "/file.txt", "original\n");
	manifest := "/tmp/veltro/.ns/test-manifest-cow";
	sys->remove(manifest);

	caps := ref NsConstruct->Capabilities(
		"write" :: nil,
		base :: nil,
		nil, nil,
		0 :: 1 :: 2 :: nil,
		nil,
		0,
		0,
		41,
		base :: nil
	, nil);

	nsconstruct->emitmanifest(caps, manifest);
	mdata := readfilecontent(manifest);
	t.assert(contains(mdata, "path=" + base), "manifest includes writable granted path");
	t.assert(contains(mdata, "perm=cow"), "manifest marks writable path as cow");
	t.assertseq(readfilecontent(base + "/file.txt"), "original\n",
		"manifest generation does not mutate the underlying file");
}

# ============================================================================
# Helpers
# ============================================================================

# Create directory with parents
mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;

	# Find parent
	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			mkdirp(path[0:i]);
			break;
		}
	}

	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

# Create an empty file
createfile(path: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd != nil)
		fd = nil;
}

writefilecontent(path, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	sys->fprint(fd, "%s", content);
	fd = nil;
}

readfilecontent(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# Check if string contains substring
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


# ============================================================================
# Environment allowlist
# Verifies inherited secrets are hidden while VELTRO_SESSION remains available.
# ============================================================================
testEnvironmentAllowlist(t: ref T)
{
	(oldok, nil) := sys->stat("/env/VELTRO_SESSION");
	oldsession := readfilecontent("/env/VELTRO_SESSION");
	writefilecontent("/env/VELTRO_SESSION", "/tmp/veltro/test-session");
	writefilecontent("/env/INFERNODE_NS_CANARY", "synthetic-secret-canary");

	result := chan of string;
	spawn environmentAllowlistWorker(result);
	r := <-result;

	sys->remove("/env/INFERNODE_NS_CANARY");
	if(oldok >= 0)
		writefilecontent("/env/VELTRO_SESSION", oldsession);
	else
		sys->remove("/env/VELTRO_SESSION");

	if(r != "")
		t.error(r);
}

environmentAllowlistWorker(result: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	if(readfilecontent("/env/VELTRO_SESSION") != "/tmp/veltro/test-session") {
		result <-= "VELTRO_SESSION should remain visible after restriction";
		return;
	}
	(secretok, nil) := sys->stat("/env/INFERNODE_NS_CANARY");
	if(secretok >= 0) {
		result <-= "inherited environment secret remains visible";
		return;
	}
	result <-= "";
}


# ============================================================================
# Process namespace allowlist
# Verifies a confined process can inspect itself but not its parent.
# ============================================================================
testProgAllowlist(t: ref T)
{
	result := chan of string;
	parentpid := sys->pctl(0, nil);
	spawn progAllowlistWorker(result, parentpid);
	r := <-result;
	if(r != "")
		t.error(r);
}

testExecProgAllowlist(t: ref T)
{
	result := chan of string;
	parentpid := sys->pctl(0, nil);
	spawn execProgAllowlistWorker(result, parentpid);
	r := <-result;
	if(r != "")
		t.error(r);
}

execProgAllowlistWorker(result: chan of string, parentpid: int)
{
	sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"exec" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns (exec) failed: %s", err);
		return;
	}
	(parentok, nil) := sys->stat(sys->sprint("/prog/%d/ctl", parentpid));
	if(parentok >= 0) {
		result <-= "exec can control a sibling process";
		return;
	}
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil) {
		result <-= "exec restricted process directory is unavailable";
		return;
	}
	(n, nil) := sys->dirread(fd);
	if(n != 0) {
		result <-= "exec process directory is not empty";
		return;
	}
	result <-= "";
}

progAllowlistWorker(result: chan of string, parentpid: int)
{
	selfpid := sys->pctl(Sys->FORKNS, nil);
	caps := ref NsConstruct->Capabilities(
		"read" :: nil, nil, nil, nil, 0 :: 1 :: 2 :: nil,
		nil, 0, 0, -1, nil
	, nil);
	err := nsconstruct->restrictns(caps);
	if(err != nil) {
		result <-= sys->sprint("restrictns failed: %s", err);
		return;
	}

	(selfok, nil) := sys->stat(sys->sprint("/prog/%d/status", selfpid));
	if(selfok < 0) {
		result <-= "current process should remain visible";
		return;
	}
	(parentok, nil) := sys->stat(sys->sprint("/prog/%d/ns", parentpid));
	if(parentok >= 0) {
		result <-= "parent process remains visible";
		return;
	}
	result <-= "";
}

# ============================================================================
# Main entry point
# ============================================================================
init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	nsconstruct = load NsConstruct NsConstruct->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	if(nsconstruct == nil) {
		sys->fprint(sys->fildes(2), "cannot load nsconstruct module: %r\n");
		raise "fail:cannot load nsconstruct";
	}

	testing->init();
	nsconstruct->init();

	# Check for verbose flag
	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Run tests
	run("RestrictDir", testRestrictDir);
	run("RestrictDirExclusion", testRestrictDirExclusion);
	run("BindReplaceIdempotent", testBindReplaceIdempotent);
	run("RestrictNs", testRestrictNs);
	run("TaskMetadataCapability", testTaskMetadataCapability);
	run("TmpVeltroIpcHidden", testTmpVeltroIpcHidden);
	run("TmpVeltroExplicitGrant", testTmpVeltroExplicitGrant);
	run("TmpVeltroTrustedIpcNotGrantable", testTmpVeltroTrustedIpcNotGrantable);
	run("ActivityScratchIsolation", testActivityScratchIsolation);
	run("NetworkCapability", testNetworkCapability);
	run("EnvironmentAllowlist", testEnvironmentAllowlist);
	run("ProgAllowlist", testProgAllowlist);
	run("ExecProgAllowlist", testExecProgAllowlist);
	run("RestrictNsShell", testRestrictNsShell);
	run("RestrictNsMnt", testRestrictNsMnt);
	run("RestrictNsMntLlm", testRestrictNsMntLlm);
	run("RestrictNsMntCombined", testRestrictNsMntCombined);
	run("RestrictNsMcpDeny", testRestrictNsMcpDeny);
	run("RestrictNsRace", testRestrictNsRace);
	run("VerifyNs", testVerifyNs);
	run("AuditLog", testAuditLog);
	run("RestrictDirMissing", testRestrictDirMissing);
	run("TmpWritable", testTmpWritable);
	run("ExecGrantsShDis", testExecGrantsShDis);
	run("PathsExposure", testPathsExposure);
	run("NodevsBlocksDeviceAttach", testNodevsBlocksDeviceAttach);
	run("ToolCtlHidden", testToolCtlHidden);
	run("InvalidGrantPathsRejected", testInvalidGrantPathsRejected);
	run("InvalidCapabilityNamesRejected", testInvalidCapabilityNamesRejected);
	run("PrivilegedGrantPathsRejected", testPrivilegedGrantPathsRejected);
	run("SafeGrantPathsAccepted", testSafeGrantPathsAccepted);
	run("InvalidGrantTypeRejected", testInvalidGrantTypeRejected);
	run("StagedWriteOverlay", testStagedWriteOverlay);

	# Print summary
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
