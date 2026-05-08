implement VeltroMoreToolsTest;

#
# veltro_more_tools_test.b - Coverage for the long tail of Veltro tools
#
# These tools have no dedicated test file.  They share a pattern: the agent
# calls exec(args), the tool dispatches on the first word, and most error
# paths are reached without any external service running (no /n/ui, /n/wallet,
# /n/wikia, /tmp/veltro/man/).  We exercise:
#
#   mount    — stub: must always refuse, never expand the namespace
#   wallet   — argument parsing, command dispatch, missing-arg errors
#   keyring  — subcommand dispatch (open / need / check), bad-input errors
#   man      — subcommand dispatch, missing-arg errors
#   gap      — subcommand dispatch (add / resolve / list), bad-input errors
#   task     — subcommand dispatch (create / status / list / close), errors
#   wiki     — argument validation, unmounted-/n/wikia error path
#
# These tools are an attack surface for the agent: every tool's exec()
# accepts a free-form string from the LLM.  Bad parsing here = agent
# misbehaviour or worse.  Each test asserts both that valid commands are
# accepted by the parser and that malformed/missing input is rejected with
# a clear error message rather than crashing the tool or doing nothing.
#
# To run: cd $ROOT && ./emu/MacOSX/o.emu -r. /tests/veltro_more_tools_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

# Tool interface (matches /appl/veltro/tool.m)
Tool: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
};

VeltroMoreToolsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/veltro_more_tools_test.b";

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

# Load a tool and call init().  Returns nil and skips the test if either
# the load or the init fails.
loadtool(t: ref T, name: string): Tool
{
	path := "/dis/veltro/tools/" + name + ".dis";
	mod := load Tool path;
	if(mod == nil) {
		t.skip("cannot load " + name + " tool");
		return nil;
	}
	err := mod->init();
	if(err != nil) {
		t.skip(name + " init failed: " + err);
		return nil;
	}
	return mod;
}

# ============================================================================
# mount stub
#
# mount is intentionally a stub: agents must not be able to expand their
# own namespace.  Any non-empty arg should still produce a refusal, never
# a successful mount.  This is a CRITICAL invariant and worth pinning.
# ============================================================================

testMountAlwaysRefuses(t: ref T)
{
	tool := loadtool(t, "mount");
	if(tool == nil)
		return;

	t.assertseq(tool->name(), "mount", "mount tool name");
	t.assert(hassubstr(tool->doc(), "user"), "doc explains user-only");

	# All call patterns must refuse
	args := array[] of {
		"",
		"/n/local /tmp/foo",
		"-c #s/* /srv",
		"anything at all here",
	};
	for(i := 0; i < len args; i++) {
		r := tool->exec(args[i]);
		t.assert(hassubstr(r, "error"),
			"mount('" + args[i] + "') refused");
		t.assert(hassubstr(r, "user operation") || hassubstr(r, "[+]"),
			"mount refusal explains why");
	}
}

# ============================================================================
# wallet — argument parsing
#
# Without /n/wallet mounted, every command path that touches the filesystem
# returns an error message.  We assert the parser correctly dispatches:
# missing args produce "error: missing/need ...", unknown commands list the
# valid set.
# ============================================================================

testWalletNameDoc(t: ref T)
{
	tool := loadtool(t, "wallet");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "wallet", "wallet tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "Wallet"), "doc mentions Wallet");
	t.assert(hassubstr(doc, "accounts"), "doc lists accounts");
	t.assert(hassubstr(doc, "pay"), "doc lists pay");
}

testWalletEmpty(t: ref T)
{
	tool := loadtool(t, "wallet");
	if(tool == nil)
		return;
	r := tool->exec("");
	t.assert(hassubstr(r, "usage") || hassubstr(r, "wallet"),
		"empty wallet args returns usage");
}

testWalletUnknownCommand(t: ref T)
{
	tool := loadtool(t, "wallet");
	if(tool == nil)
		return;
	r := tool->exec("banana");
	t.assert(hassubstr(r, "error") && hassubstr(r, "unknown command"),
		"unknown wallet command rejected");
	t.assert(hassubstr(r, "accounts"),
		"unknown-command error lists valid commands");
}

testWalletMissingArgs(t: ref T)
{
	tool := loadtool(t, "wallet");
	if(tool == nil)
		return;

	# 'address' / 'balance' / 'chain' / 'history' need an account name
	for(i := 0; i < 4; i++) {
		cmd := array[] of {"address", "balance", "chain", "history"};
		r := tool->exec(cmd[i]);
		t.assert(hassubstr(r, "error") && hassubstr(r, "missing account"),
			cmd[i] + " missing-arg rejected");
	}

	# 'sign' needs account + 64-hex-char hash
	r := tool->exec("sign");
	t.assert(hassubstr(r, "error"), "sign with no args rejected");

	# 'sign acct shorthex' rejected for non-64-char hash
	r = tool->exec("sign myacct deadbeef");
	t.assert(hassubstr(r, "64 hex"),
		"sign with short hash rejected");

	# 'pay' needs at least account + amount
	r = tool->exec("pay myacct");
	t.assert(hassubstr(r, "error"), "pay with one arg rejected");
}

testWalletDoubledCommand(t: ref T)
{
	tool := loadtool(t, "wallet");
	if(tool == nil)
		return;

	# 'wallet wallet accounts' should be normalized to 'wallet accounts'
	# (handles agents that double-prefix the tool name)
	r := tool->exec("wallet accounts");
	# Without /n/wallet mounted, doaccounts() returns a "no accounts
	# configured" message — never an "unknown command" error.
	t.assert(!hassubstr(r, "unknown command"),
		"doubled 'wallet wallet accounts' not treated as unknown");
}

# ============================================================================
# keyring — subcommand dispatch
# ============================================================================

testKeyringNameDoc(t: ref T)
{
	tool := loadtool(t, "keyring");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "keyring", "keyring tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "Keyring"), "doc mentions Keyring");
	t.assert(hassubstr(doc, "factotum") || hassubstr(doc, "credential"),
		"doc mentions credentials");
}

testKeyringUnknownSubcommand(t: ref T)
{
	tool := loadtool(t, "keyring");
	if(tool == nil)
		return;
	r := tool->exec("destroy everything");
	t.assert(hassubstr(r, "error") && hassubstr(r, "unknown command"),
		"unknown keyring subcommand rejected");
}

testKeyringNeedRequiresDescription(t: ref T)
{
	tool := loadtool(t, "keyring");
	if(tool == nil)
		return;
	r := tool->exec("need");
	t.assert(hassubstr(r, "error") && hassubstr(r, "usage"),
		"keyring need with no description rejected");
}

testKeyringCheckRequiresService(t: ref T)
{
	tool := loadtool(t, "keyring");
	if(tool == nil)
		return;
	r := tool->exec("check");
	t.assert(hassubstr(r, "error") && hassubstr(r, "usage"),
		"keyring check with no service rejected");
}

testKeyringCheckUnknownService(t: ref T)
{
	tool := loadtool(t, "keyring");
	if(tool == nil)
		return;
	# Even without factotum mounted, this returns a structured response
	# (either "unknown: factotum not available" or "no: ..."), never crashes
	r := tool->exec("check definitely-not-a-real-service-12345");
	t.assert(hassubstr(r, "no") || hassubstr(r, "unknown"),
		"check returns structured response for unknown service");
}

# ============================================================================
# man — subcommand dispatch
# ============================================================================

testManNameDoc(t: ref T)
{
	tool := loadtool(t, "man");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "man", "man tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "manual"), "doc mentions manual");
	t.assert(hassubstr(doc, "scroll"), "doc lists scroll subcommand");
}

testManEmpty(t: ref T)
{
	tool := loadtool(t, "man");
	if(tool == nil)
		return;
	r := tool->exec("");
	t.assert(hassubstr(r, "error") && hassubstr(r, "no command"),
		"empty man args rejected");
}

testManMissingArgs(t: ref T)
{
	tool := loadtool(t, "man");
	if(tool == nil)
		return;

	# open requires a title or path
	r := tool->exec("open");
	t.assert(hassubstr(r, "error") && hassubstr(r, "title"),
		"man open with no arg rejected");

	# scroll requires direction or line
	r = tool->exec("scroll");
	t.assert(hassubstr(r, "error") && hassubstr(r, "direction"),
		"man scroll with no arg rejected");

	# find requires text
	r = tool->exec("find");
	t.assert(hassubstr(r, "error") && hassubstr(r, "search text"),
		"man find with no arg rejected");
}

testManUnknownCommand(t: ref T)
{
	tool := loadtool(t, "man");
	if(tool == nil)
		return;
	r := tool->exec("teleport SYNOPSIS");
	t.assert(hassubstr(r, "error") && hassubstr(r, "unknown command"),
		"unknown man subcommand rejected");
}

# ============================================================================
# gap — subcommand dispatch and parsing
# ============================================================================

testGapNameDoc(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "gap", "gap tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "Gap") || hassubstr(doc, "gap"),
		"doc mentions gaps");
	t.assert(hassubstr(doc, "relevance"),
		"doc explains relevance levels");
}

testGapEmpty(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	r := tool->exec("");
	t.assert(hassubstr(r, "error") && hassubstr(r, "no command"),
		"empty gap args rejected");
}

testGapAddRequiresDescription(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	r := tool->exec("add");
	t.assert(hassubstr(r, "error") && hassubstr(r, "usage"),
		"gap add with no description rejected");
}

testGapResolveRequiresDescription(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	r := tool->exec("resolve");
	t.assert(hassubstr(r, "error") && hassubstr(r, "usage"),
		"gap resolve with no description rejected");
}

testGapUnknownCommand(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	r := tool->exec("destroy everything");
	t.assert(hassubstr(r, "error") && hassubstr(r, "unknown command"),
		"unknown gap subcommand rejected");
}

testGapAddNoUI(t: ref T)
{
	tool := loadtool(t, "gap");
	if(tool == nil)
		return;
	# Without /n/ui mounted, currentactid() returns -1; the tool reports
	# "no active activity" instead of crashing.
	r := tool->exec("add \"some thoughtful gap\" high");
	t.assert(hassubstr(r, "error"),
		"gap add without /n/ui mounted returns error");
	t.assert(hassubstr(r, "no active activity") || hassubstr(r, "luciuisrv"),
		"error explains UI is not running");
}

# ============================================================================
# task — subcommand dispatch
# ============================================================================

testTaskNameDoc(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "task", "task tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "task"), "doc mentions tasks");
	t.assert(hassubstr(doc, "create"), "doc lists create subcommand");
}

testTaskEmpty(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	r := tool->exec("");
	t.assert(hassubstr(r, "error") && hassubstr(r, "no command"),
		"empty task args rejected");
}

testTaskCreateRequiresLabel(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	# create with no attrs at all
	r := tool->exec("create");
	t.assert(hassubstr(r, "error") && hassubstr(r, "label"),
		"task create with no label rejected");

	# create with attributes but missing label
	r = tool->exec("create tools=read,list");
	t.assert(hassubstr(r, "error") && hassubstr(r, "label"),
		"task create without label= rejected");
}

testTaskStatusRequiresId(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	r := tool->exec("status");
	t.assert(hassubstr(r, "error") && hassubstr(r, "id"),
		"task status with no id rejected");

	r = tool->exec("status notanumber");
	t.assert(hassubstr(r, "error"),
		"task status with non-numeric id rejected");
}

testTaskCloseRequiresId(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	r := tool->exec("close");
	t.assert(hassubstr(r, "error") && hassubstr(r, "id"),
		"task close with no id rejected");

	# Activity 0 is the meta-agent — closing it must be refused
	r = tool->exec("close 0");
	t.assert(hassubstr(r, "error") && hassubstr(r, "meta-agent"),
		"task close 0 (meta-agent) refused");
}

testTaskUnknownCommand(t: ref T)
{
	tool := loadtool(t, "task");
	if(tool == nil)
		return;
	r := tool->exec("forge a backdoor");
	t.assert(hassubstr(r, "error") && hassubstr(r, "unknown command"),
		"unknown task subcommand rejected");
}

# ============================================================================
# wiki — argument validation
# ============================================================================

testWikiNameDoc(t: ref T)
{
	tool := loadtool(t, "wiki");
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "wiki", "wiki tool name");
	doc := tool->doc();
	t.assert(hassubstr(doc, "Wiki") || hassubstr(doc, "wiki"),
		"doc mentions wiki");
	t.assert(hassubstr(doc, "ingest"), "doc lists ingest");
	t.assert(hassubstr(doc, "query"), "doc lists query");
}

testWikiEmpty(t: ref T)
{
	tool := loadtool(t, "wiki");
	if(tool == nil)
		return;
	r := tool->exec("");
	t.assert(hassubstr(r, "error") && hassubstr(r, "usage"),
		"empty wiki args rejected");
}

testWikiUnmounted(t: ref T)
{
	tool := loadtool(t, "wiki");
	if(tool == nil)
		return;
	# /n/wikia is the wiki9p mount.  When not mounted, every wiki command
	# should fail fast with a clear pointer to wiki9p.
	(ok, nil) := sys->stat("/n/wikia/ctl");
	if(ok >= 0) {
		t.skip("/n/wikia is mounted — cannot test the unmounted path");
		return;
	}

	r := tool->exec("status");
	t.assert(hassubstr(r, "error") && hassubstr(r, "/n/wikia"),
		"wiki status without /n/wikia mounted reports the mount");
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

	# mount
	run("MountAlwaysRefuses", testMountAlwaysRefuses);

	# wallet
	run("WalletNameDoc", testWalletNameDoc);
	run("WalletEmpty", testWalletEmpty);
	run("WalletUnknownCommand", testWalletUnknownCommand);
	run("WalletMissingArgs", testWalletMissingArgs);
	run("WalletDoubledCommand", testWalletDoubledCommand);

	# keyring
	run("KeyringNameDoc", testKeyringNameDoc);
	run("KeyringUnknownSubcommand", testKeyringUnknownSubcommand);
	run("KeyringNeedRequiresDescription", testKeyringNeedRequiresDescription);
	run("KeyringCheckRequiresService", testKeyringCheckRequiresService);
	run("KeyringCheckUnknownService", testKeyringCheckUnknownService);

	# man
	run("ManNameDoc", testManNameDoc);
	run("ManEmpty", testManEmpty);
	run("ManMissingArgs", testManMissingArgs);
	run("ManUnknownCommand", testManUnknownCommand);

	# gap
	run("GapNameDoc", testGapNameDoc);
	run("GapEmpty", testGapEmpty);
	run("GapAddRequiresDescription", testGapAddRequiresDescription);
	run("GapResolveRequiresDescription", testGapResolveRequiresDescription);
	run("GapUnknownCommand", testGapUnknownCommand);
	run("GapAddNoUI", testGapAddNoUI);

	# task
	run("TaskNameDoc", testTaskNameDoc);
	run("TaskEmpty", testTaskEmpty);
	run("TaskCreateRequiresLabel", testTaskCreateRequiresLabel);
	run("TaskStatusRequiresId", testTaskStatusRequiresId);
	run("TaskCloseRequiresId", testTaskCloseRequiresId);
	run("TaskUnknownCommand", testTaskUnknownCommand);

	# wiki
	run("WikiNameDoc", testWikiNameDoc);
	run("WikiEmpty", testWikiEmpty);
	run("WikiUnmounted", testWikiUnmounted);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
