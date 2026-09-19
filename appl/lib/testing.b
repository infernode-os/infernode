implement Testing;

include "sys.m";
	sys: Sys;

include "testing.m";

verbosemode := 0;

init()
{
	sys = load Sys Sys->PATH;
}

verbose(v: int)
{
	verbosemode = v;
}

getverbose(): int
{
	return verbosemode;
}

newT(name: string): ref T
{
	sys->fprint(sys->fildes(2), "=== RUN   %s\n", name);
	return ref T(name, nil, 0, 0, nil, sys->millisec());
}

# newTsrc: create test with source file for clickable addresses
# On failure, outputs file:/testname/ format for Xenith plumbing
newTsrc(name, srcfile: string): ref T
{
	sys->fprint(sys->fildes(2), "=== RUN   %s\n", name);
	return ref T(name, srcfile, 0, 0, nil, sys->millisec());
}

# T.log: add message to test output
T.log(t: self ref T, msg: string)
{
	t.output = msg :: t.output;
	if(verbosemode)
		sys->fprint(sys->fildes(2), "    %s: %s\n", t.name, msg);
}

# T.error: mark test as failed, continue execution
T.error(t: self ref T, msg: string)
{
	t.failed = 1;
	t.log(msg);
}

# T.fatal: mark test as failed, stop execution
T.fatal(t: self ref T, msg: string)
{
	t.failed = 1;
	t.log(msg);
	raise "fail:fatal";
}

# T.skip: skip this test
T.skip(t: self ref T, msg: string)
{
	# Skipping cannot retract a failure that has already been recorded.
	#
	# Several tests call t.error() when an operation fails and then
	# t.skip() to stop, treating the failure as an unavailable feature.
	# Leaving skipped set there loses the failure twice over: done()
	# would report SKIP, and the standard run() helper in every test
	# file tallies "else if(t.skipped) skipped++" before it reaches
	# failed++, so the count would be wrong even once done() got the
	# precedence right. Not setting the flag fixes both at the source.
	if(!t.failed)
		t.skipped = 1;
	t.log(msg);
	raise "fail:skip";
}

# T.assert: check condition, report failure
T.assert(t: self ref T, cond: int, msg: string): int
{
	if(!cond) {
		t.error(msg);
		return 0;
	}
	return 1;
}

# T.asserteq: check int equality
T.asserteq(t: self ref T, got, want: int, msg: string): int
{
	if(got != want) {
		t.error(sys->sprint("%s: got %d, want %d", msg, got, want));
		return 0;
	}
	return 1;
}

# T.assertne: check int inequality
T.assertne(t: self ref T, got, notexpect: int, msg: string): int
{
	if(got == notexpect) {
		t.error(sys->sprint("%s: got %d, did not expect %d", msg, got, notexpect));
		return 0;
	}
	return 1;
}

# T.assertseq: check string equality
T.assertseq(t: self ref T, got, want: string, msg: string): int
{
	if(got != want) {
		t.error(sys->sprint("%s: got \"%s\", want \"%s\"", msg, got, want));
		return 0;
	}
	return 1;
}

# T.assertsne: check string inequality
T.assertsne(t: self ref T, got, notexpect: string, msg: string): int
{
	if(got == notexpect) {
		t.error(sys->sprint("%s: got \"%s\", did not expect it", msg, got));
		return 0;
	}
	return 1;
}

# T.assertnil: check string is nil
T.assertnil(t: self ref T, got: string, msg: string): int
{
	if(got != nil) {
		t.error(sys->sprint("%s: got \"%s\", want nil", msg, got));
		return 0;
	}
	return 1;
}

# T.assertnotnil: check string is not nil
T.assertnotnil(t: self ref T, got: string, msg: string): int
{
	if(got == nil) {
		t.error(sys->sprint("%s: got nil, want non-nil", msg));
		return 0;
	}
	return 1;
}

# printoutput: print accumulated test output
printoutput(t: ref T)
{
	# output is in reverse order, reverse it
	out: list of string;
	for(l := t.output; l != nil; l = tl l)
		out = hd l :: out;
	for(; out != nil; out = tl out)
		sys->fprint(sys->fildes(2), "    %s\n", hd out);
}

# done: finalize a test and print result
# Call this after running the test function
# Returns 1 on pass, 0 on fail/skip
done(t: ref T): int
{
	elapsed := sys->millisec() - t.start;
	elapsedSec := real elapsed / 1000.0;

	# A recorded failure outranks a skip.
	#
	# These were the other way round, so a test that called t.error()
	# and then t.skip() -- which several do when an operation fails and
	# they treat it as an unavailable feature -- reported SKIP, and the
	# failure was discarded. summary() counts skips as non-failures, so
	# the suite still exited 0. A test that has already established
	# something is broken must not be able to retract that by skipping
	# afterwards; the skip can only mean "and I could not continue".
	if(t.failed) {
		sys->fprint(sys->fildes(2), "--- FAIL: %s (%.2fs)\n", t.name, elapsedSec);
		# Print clickable address: file:/testname/ format for Xenith plumbing
		if(t.srcfile != nil)
			sys->fprint(sys->fildes(2), "    %s:/test%s/\n", t.srcfile, t.name);
		if(!verbosemode && t.output != nil)
			printoutput(t);
		return 0;
	} else if(t.skipped) {
		sys->fprint(sys->fildes(2), "--- SKIP: %s (%.2fs)\n", t.name, elapsedSec);
		if(!verbosemode && t.output != nil)
			printoutput(t);
		return 0;
	}

	sys->fprint(sys->fildes(2), "--- PASS: %s (%.2fs)\n", t.name, elapsedSec);
	return 1;
}

# summary: print final summary and return exit code
summary(passed, failed, skipped: int): int
{
	sys->fprint(sys->fildes(2), "\n");
	if(failed > 0) {
		sys->fprint(sys->fildes(2), "FAIL\n");
		sys->fprint(sys->fildes(2), "%d passed, %d failed, %d skipped\n", passed, failed, skipped);
		return failed;
	}

	sys->fprint(sys->fildes(2), "PASS\n");
	if(skipped > 0)
		sys->fprint(sys->fildes(2), "%d passed, %d skipped\n", passed, skipped);
	else
		sys->fprint(sys->fildes(2), "%d passed\n", passed);
	return 0;
}
