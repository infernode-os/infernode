implement Runner;

#
# runner - Internal test runner for InferNode
#
# This runs inside the emulator to execute:
#   - Limbo tests (*_test.dis in /tests)
#   - Inferno sh tests (*.sh in /tests/inferno)
#
# Usage: runner [-v]
#
# Exit: raises "fail:tests failed" on any failure
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";
	arg: Arg;

include "readdir.m";
	readdir: Readdir;

include "sh.m";
	sh: Sh;

Runner: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

TestModule: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

verbosemode := 0;
ctxt: ref Draw->Context;

# Counts
limbopassed := 0;
limbofailed := 0;
limboskipped := 0;
shpassed := 0;
shfailed := 0;
shskipped := 0;

init(drawctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg = load Arg Arg->PATH;
	readdir = load Readdir Readdir->PATH;
	sh = load Sh Sh->PATH;
	ctxt = drawctxt;

	if(arg == nil) {
		sys->fprint(sys->fildes(2), "runner: cannot load arg: %r\n");
		raise "fail:init";
	}
	if(readdir == nil) {
		sys->fprint(sys->fildes(2), "runner: cannot load readdir: %r\n");
		raise "fail:init";
	}
	if(sh == nil) {
		sys->fprint(sys->fildes(2), "runner: cannot load sh: %r\n");
		raise "fail:init";
	}

	arg->init(args);
	arg->setusage("runner [-v]");

	while((opt := arg->opt()) != 0) {
		case opt {
		'v' =>
			verbosemode = 1;
		* =>
			arg->usage();
		}
	}

	sys->fprint(sys->fildes(2), "=== LIMBO TESTS ===\n");
	runlimbotests("/tests");

	sys->fprint(sys->fildes(2), "\n=== INFERNO SH TESTS ===\n");
	runshtests("/tests/inferno");

	# Print summary
	sys->fprint(sys->fildes(2), "\n========================================\n");
	sys->fprint(sys->fildes(2), "Internal Test Summary\n");
	sys->fprint(sys->fildes(2), "========================================\n");
	sys->fprint(sys->fildes(2), "Limbo tests:    %d passed, %d failed, %d skipped\n",
		limbopassed, limbofailed, limboskipped);
	sys->fprint(sys->fildes(2), "Inferno sh:     %d passed, %d failed, %d skipped\n",
		shpassed, shfailed, shskipped);

	totalfailed := limbofailed + shfailed;
	totalpassed := limbopassed + shpassed;
	totalskipped := limboskipped + shskipped;

	sys->fprint(sys->fildes(2), "Total:          %d passed, %d failed, %d skipped\n",
		totalpassed, totalfailed, totalskipped);

	if(totalfailed > 0) {
		sys->fprint(sys->fildes(2), "\nFAIL\n");
		raise "fail:tests failed";
	}

	sys->fprint(sys->fildes(2), "\nPASS\n");
}

# runlimbotests: discover and run *_test.dis files
runlimbotests(dir: string)
{
	(dirs, n) := readdir->init(dir, Readdir->NAME);
	if(n < 0) {
		sys->fprint(sys->fildes(2), "runner: cannot read %s: %r\n", dir);
		return;
	}

	for(i := 0; i < n; i++) {
		d := dirs[i];
		if(issuffix(d.name, "_test.dis")) {
			fullpath := dir + "/" + d.name;
			runlimbotest(fullpath);
		}
	}
}

# runlimbotest: run a single Limbo test
runlimbotest(dispath: string)
{
	# Extract test name (remove path and _test.dis suffix)
	name := basename(dispath);
	if(len name > 9)
		name = name[:len name - 9];  # remove "_test.dis"

	sys->fprint(sys->fildes(2), "=== RUN   %s\n", name);
	start := sys->millisec();

	# Load the test module
	testmod := load TestModule dispath;
	if(testmod == nil) {
		elapsed := sys->millisec() - start;
		sys->fprint(sys->fildes(2), "--- FAIL: %s (%.2fs)\n", name, real elapsed / 1000.0);
		sys->fprint(sys->fildes(2), "    cannot load %s: %r\n", dispath);
		limbofailed++;
		return;
	}

	# Build args
	args: list of string;
	args = dispath :: nil;
	if(verbosemode)
		args = dispath :: "-v" :: nil;

	# Run the test
	#
	# Suite-skip convention: a test whose environmental precondition is
	# absent (no display, no GPU/codec built in, no live backend) should
	# raise "skip:<reason>" from init() so the whole module is recorded as
	# a clean SKIP, not a FAIL. A bare "fail:..." raise lands in the "fail:*"
	# arm below and is counted as a failure — which is correct for genuine
	# setup errors but wrong for "environment absent on this host" (INFR-312).
	status := "PASS";
	{
		testmod->init(ctxt, args);
	} exception e {
	"fail:skip" or "skip:*" =>
		status = "SKIP";
		limboskipped++;
	"fail:*" =>
		status = "FAIL";
		limbofailed++;
	"*" =>
		status = "FAIL";
		limbofailed++;
		sys->fprint(sys->fildes(2), "    exception: %s\n", e);
	}

	testmod = nil;

	elapsed := sys->millisec() - start;
	if(status == "PASS") {
		limbopassed++;
		sys->fprint(sys->fildes(2), "--- PASS: %s (%.2fs)\n", name, real elapsed / 1000.0);
	} else if(status == "SKIP") {
		sys->fprint(sys->fildes(2), "--- SKIP: %s (%.2fs)\n", name, real elapsed / 1000.0);
	} else {
		sys->fprint(sys->fildes(2), "--- FAIL: %s (%.2fs)\n", name, real elapsed / 1000.0);
	}
}

# runshtests: discover and run *.sh files in directory
runshtests(dir: string)
{
	(ok, nil) := sys->stat(dir);
	if(ok < 0) {
		sys->fprint(sys->fildes(2), "runner: %s does not exist, skipping\n", dir);
		return;
	}

	(dirs, n) := readdir->init(dir, Readdir->NAME);
	if(n < 0) {
		sys->fprint(sys->fildes(2), "runner: cannot read %s: %r\n", dir);
		return;
	}

	for(i := 0; i < n; i++) {
		d := dirs[i];
		if(issuffix(d.name, ".sh") || issuffix(d.name, "_test.sh")) {
			fullpath := dir + "/" + d.name;
			runshtest(fullpath);
		}
	}
}

# runshtest: run a single Inferno sh test
runshtest(scriptpath: string)
{
	# Extract test name
	name := basename(scriptpath);
	if(issuffix(name, "_test.sh"))
		name = name[:len name - 8];  # remove "_test.sh"
	else if(issuffix(name, ".sh"))
		name = name[:len name - 3];  # remove ".sh"

	sys->fprint(sys->fildes(2), "=== TEST  %s\n", name);
	start := sys->millisec();

	# Run the script via sh->system()
	err := sh->system(ctxt, scriptpath);

	elapsed := sys->millisec() - start;

	if(err == nil || err == "") {
		shpassed++;
		sys->fprint(sys->fildes(2), "--- PASS: %s (%.2fs)\n", name, real elapsed / 1000.0);
	} else if(hasprefix(err, "skip:")) {
		shskipped++;
		sys->fprint(sys->fildes(2), "--- SKIP: %s (%.2fs)\n", name, real elapsed / 1000.0);
		sys->fprint(sys->fildes(2), "    %s\n", err[5:]);
	} else {
		shfailed++;
		sys->fprint(sys->fildes(2), "--- FAIL: %s (%.2fs)\n", name, real elapsed / 1000.0);
		if(err != nil)
			sys->fprint(sys->fildes(2), "    %s\n", err);
	}
}

# basename: return filename portion of path
basename(path: string): string
{
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/')
			return path[i+1:];
	return path;
}

# issuffix: check if s ends with suffix
issuffix(s, suffix: string): int
{
	if(len s < len suffix)
		return 0;
	return s[len s - len suffix:] == suffix;
}

# hasprefix: check if s starts with prefix
hasprefix(s, prefix: string): int
{
	if(len s < len prefix)
		return 0;
	return s[:len prefix] == prefix;
}
