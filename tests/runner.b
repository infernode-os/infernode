implement Runner;

#
# runner - Internal test runner for InferNode
#
# This runs inside the emulator to execute:
#   - Limbo tests (*_test.dis in /tests)
#   - Inferno sh tests (*.sh in /tests/inferno)
#
# Usage: runner [-v] [-t seconds] [name ...]
#
# With names, only those tests run (a Limbo test's name is its file's
# without _test.dis, a script's without _test.sh or .sh).
#
# Each test runs in a process of its own, with its own copy of the
# namespace and environment (pctl FORKNS|FORKENV), so a test that binds,
# mounts or unmounts leaves the next one the namespace it began with;
# and in a process group of its own, so that one that runs longer than
# -t seconds (default 900) is killed, with whatever it started, and
# counted a failure, rather than stopping the suite.
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
timeout := 900;	# seconds a test may take
only: list of string;	# if not nil, the tests to run
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
	arg->setusage("runner [-v] [-t seconds] [name ...]");

	while((opt := arg->opt()) != 0) {
		case opt {
		'v' =>
			verbosemode = 1;
		't' =>
			timeout = int arg->earg();
		* =>
			arg->usage();
		}
	}

	only = arg->argv();

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
		if(issuffix(d.name, "_test.dis") && wanted(d.name[0:len d.name - 9])) {
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
	err := isolated(testmod, nil, args);
	status := "PASS";
	if(err == nil) {
		limbopassed++;
	} else if(err == "fail:skip" || hasprefix(err, "skip:")) {
		status = "SKIP";
		limboskipped++;
	} else {
		status = "FAIL";
		limbofailed++;
		if(!hasprefix(err, "fail:"))
			sys->fprint(sys->fildes(2), "    exception: %s\n", err);
	}

	testmod = nil;

	elapsed := sys->millisec() - start;
	if(status == "PASS") {
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
		if(issuffix(d.name, ".sh") && (wanted(d.name[0:len d.name - 3]) ||
		   issuffix(d.name, "_test.sh") && wanted(d.name[0:len d.name - 8]))) {
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
	err := isolated(nil, scriptpath, nil);

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

# Run a test, Limbo (mod) or sh (script), in a process of its own: its
# own namespace, environment and process group.  The result is nil if it
# passed, else what it raised or the script's status; or, if it ran out
# of time, that, its process group killed.
isolated(mod: TestModule, script: string, args: list of string): string
{
	pidc := chan of int;
	done := chan[1] of string;
	spawn runtest(mod, script, args, pidc, done);
	pid := <-pidc;
	tick := chan[1] of int;
	spawn timer(tick, timeout);
	tpid := <-tick;
	alt {
	err := <-done =>
		kill(tpid, "kill");
		return err;
	<-tick =>
		kill(pid, "killgrp");
		return sys->sprint("fail:timed out after %ds", timeout);
	}
}

runtest(mod: TestModule, script: string, args: list of string, pidc: chan of int, done: chan of string)
{
	pidc <-= sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->FORKENV, nil);
	err: string;
	{
		if(mod != nil)
			mod->init(ctxt, args);
		else
			err = sh->system(ctxt, script);
	} exception e {
	"*" =>
		err = e;
		if(err == nil)
			err = "fail:exception";
	}
	if(err == "")
		err = nil;
	done <-= err;
}

timer(tick: chan of int, secs: int)
{
	tick <-= sys->pctl(0, nil);
	sys->sleep(secs * 1000);
	tick <-= 1;
}

kill(pid: int, how: string)
{
	fd := sys->open(sys->sprint("#p/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", how);
}

# Whether the test named n is to run
wanted(n: string): int
{
	if(only == nil)
		return 1;
	for(l := only; l != nil; l = tl l)
		if(hd l == n)
			return 1;
	return 0;
}
