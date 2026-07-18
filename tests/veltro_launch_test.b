implement VeltroLaunchTest;

#
# veltro_launch_test.b - Tests for the Launch tool
#
# Launch is the agent's only path for starting GUI applications inside
# Lucifer's presentation zone.  Its exec() does several security-relevant
# things before ever talking to luciuisrv:
#
#   1. Normalizes the app name (strips /dis/wm/, wm/, .dis suffix)
#   2. Rejects names that still contain '/' after normalization (path-escape
#      defense — agents can't reach /dis/auth/factotum.dis or similar)
#   3. Rejects Tk-only apps that aren't built into emu (clear error rather
#      than a confusing runtime failure)
#   4. Rejects apps not in /dis/wm/ unless explicitly whitelisted
#      (extraapp() — currently only xenith)
#   5. "list" enumerates non-Tk /dis/wm/ apps + the explicit whitelist
#
# These tests exercise the parser + whitelist directly via the loaded
# module.  They run without lucifer/luciuisrv being up — most of the
# validation completes (and rejects bad input) before that mount is touched.
# Tests that would require luciuisrv assert that the validation phase
# either succeeds enough to reach the "cannot reach presentation zone"
# error, or short-circuits before then.
#
# To run: cd $ROOT && ./emu/MacOSX/o.emu -r. /tests/veltro_launch_test.dis
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

VeltroLaunchTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/veltro_launch_test.b";

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

loadlaunch(t: ref T): Tool
{
	tool := load Tool "/dis/veltro/tools/launch.dis";
	if(tool == nil) {
		t.skip("cannot load launch.dis");
		return nil;
	}
	err := tool->init();
	if(err != nil) {
		t.skip("launch init failed: " + err);
		return nil;
	}
	return tool;
}

# ============================================================================
# Identity
# ============================================================================

testNameAndDoc(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;
	t.assertseq(tool->name(), "launch", "name() returns 'launch'");

	doc := tool->doc();
	t.assert(len doc > 0, "doc() is non-empty");
	t.assert(hassubstr(doc, "Launch"), "doc mentions Launch");
	t.assert(hassubstr(doc, "list"), "doc mentions 'list' subcommand");
	t.assert(hassubstr(doc, "presentation"), "doc mentions presentation zone");
}

# ============================================================================
# 'list' — enumerates available apps
# ============================================================================

testListApps(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	r := tool->exec("list");
	# /dis/wm should always exist in the runtime tree
	if(hassubstr(r, "cannot open /dis/wm")) {
		t.skip("/dis/wm not present in runtime tree");
		return;
	}

	# Either "no apps available" or "<N> apps available"
	t.assert(hassubstr(r, "apps available") || hassubstr(r, "no apps"),
		"list returns app summary");

	# Common apps should appear
	t.assert(hassubstr(r, "clock") || hassubstr(r, "date"),
		"common /dis/wm apps appear in list");
}

testEmptyArgsListsApps(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# Empty args is documented to behave like 'list'
	r := tool->exec("");
	t.assert(hassubstr(r, "apps available") || hassubstr(r, "no apps"),
		"empty args lists apps");
}

# ============================================================================
# Tk-app rejection: apps that need Tk (not built into this emu) are
# rejected with a helpful message rather than spawning and failing.
# ============================================================================

testRejectsTkApps(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# Each of these is in the istk() whitelist
	tkapps := array[] of {"task", "tetris", "sh", "ftree", "deb"};
	for(i := 0; i < len tkapps; i++) {
		r := tool->exec(tkapps[i]);
		t.assert(hassubstr(r, "Tk"),
			tkapps[i] + " rejection mentions Tk");
		t.assert(hassubstr(r, "error"),
			tkapps[i] + " rejected as error");
	}
}

# ============================================================================
# Unknown apps are rejected
# ============================================================================

testRejectsUnknownApp(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# An app that doesn't exist in /dis/wm/ and isn't whitelisted
	r := tool->exec("definitelynotrealapp");
	t.assert(hassubstr(r, "not found") || hassubstr(r, "error"),
		"unknown app rejected");
}

# ============================================================================
# Path-traversal defenses
#
# After normalization (strip /dis/wm/, wm/, .dis), the residual name is
# checked for '/'.  Any survivor is a normalization gap and rejected.
# These tests probe both pre- and post-normalization escape attempts.
# ============================================================================

testRejectsAbsolutePathOutsideWm(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# A /dis/auth/... path: stripping the leading /dis/wm/ fails (no match),
	# then the loop strips up to the last '/'.  After stripping, "factotum"
	# remains — it has no .dis in /dis/wm/ and isn't whitelisted.
	r := tool->exec("/dis/auth/factotum");
	t.assert(hassubstr(r, "not found") || hassubstr(r, "error"),
		"path outside /dis/wm/ rejected");
}

testRejectsRelativePath(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# "../something" — after the path-strip loop, only "something" remains
	r := tool->exec("../something");
	t.assert(hassubstr(r, "error") || hassubstr(r, "not found"),
		"relative path traversal rejected");
}

# ============================================================================
# Name normalization: many forms of the same app name should resolve
# to the same .dis target.  We use 'clock' which is reliably in /dis/wm/.
# When luciuisrv isn't running, the validation phase passes but the
# eventual presentation/ctl open fails with a recognisable error.
# ============================================================================

testNormalizationFullPath(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# /dis/wm/clock.dis — full canonical form
	(ok, nil) := sys->stat("/dis/wm/clock.dis");
	if(ok < 0) {
		t.skip("/dis/wm/clock.dis not present");
		return;
	}
	r := tool->exec("/dis/wm/clock.dis");
	# Either succeeds (luciuisrv up) or fails reaching presentation zone
	t.assert(hassubstr(r, "launched") || hassubstr(r, "presentation zone"),
		"full path resolves to clock");
}

testNormalizationWmPrefix(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	(ok, nil) := sys->stat("/dis/wm/clock.dis");
	if(ok < 0) {
		t.skip("/dis/wm/clock.dis not present");
		return;
	}
	r := tool->exec("wm/clock");
	t.assert(hassubstr(r, "launched") || hassubstr(r, "presentation zone"),
		"wm/ prefix resolves to clock");
}

testNormalizationBareName(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	(ok, nil) := sys->stat("/dis/wm/clock.dis");
	if(ok < 0) {
		t.skip("/dis/wm/clock.dis not present");
		return;
	}
	r := tool->exec("clock");
	t.assert(hassubstr(r, "launched") || hassubstr(r, "presentation zone"),
		"bare name resolves to clock");
}

# ============================================================================
# Whitelist enforcement: only apps in /dis/wm/ or extraapp()'s explicit
# whitelist are launchable.  /dis/cmd/cat.dis exists, but the agent must
# not be able to launch arbitrary /dis/*.dis files as GUI apps.
# ============================================================================

testWhitelistOnlyWm(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	# 'cat' exists at /dis/cat.dis but is NOT in /dis/wm/ and NOT whitelisted
	r := tool->exec("cat");
	t.assert(hassubstr(r, "not found") || hassubstr(r, "error"),
		"non-wm app cat rejected by whitelist");
}

testRejectsLocalCharonUrls(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	bad := array[] of {
		"file:/lib/veltro/system.txt",
		"FILE:///env/secret",
		"ftp://localhost/private"
	};
	for(i := 0; i < len bad; i++) {
		r := tool->exec("charon " + bad[i]);
		t.assert(hassubstr(r, "only accepts http:// and https://"),
			"charon rejects non-network URL " + bad[i]);
	}
}

testRejectsControlCharonUrls(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	bad := array[] of {
		"http://example.com data=-c owned",
		"https://example.com\n" + "dis=/dis/wm/shell.dis",
	};
	for(i := 0; i < len bad; i++) {
		r := tool->exec("charon " + bad[i]);
		t.assert(hassubstr(r, "only accepts http:// and https://"),
			"charon rejects control-delimited URL");
	}
}

testRejectsDataForOtherApps(t: ref T)
{
	tool := loadlaunch(t);
	if(tool == nil)
		return;

	r := tool->exec("editor /lib/veltro/system.txt");
	t.assert(hassubstr(r, "launch data is only supported for charon"),
		"launch does not pass attacker-controlled data to arbitrary GUI apps");
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

	# Listing
	run("ListApps", testListApps);
	run("EmptyArgsListsApps", testEmptyArgsListsApps);

	# Rejection paths
	run("RejectsTkApps", testRejectsTkApps);
	run("RejectsUnknownApp", testRejectsUnknownApp);
	run("RejectsAbsolutePathOutsideWm", testRejectsAbsolutePathOutsideWm);
	run("RejectsRelativePath", testRejectsRelativePath);

	# Name normalization
	run("NormalizationFullPath", testNormalizationFullPath);
	run("NormalizationWmPrefix", testNormalizationWmPrefix);
	run("NormalizationBareName", testNormalizationBareName);

	# Whitelist
	run("WhitelistOnlyWm", testWhitelistOnlyWm);
	run("RejectsLocalCharonUrls", testRejectsLocalCharonUrls);
	run("RejectsControlCharonUrls", testRejectsControlCharonUrls);
	run("RejectsDataForOtherApps", testRejectsDataForOtherApps);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
