implement TestingTest;

#
# Self-tests for the testing framework
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

TestingTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

# Source file path for clickable error addresses
SRCFILE: con "/tests/testing/testing_test.b";

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

# Test that assertions work correctly
testAssertTrue(t: ref T)
{
	t.assert(1, "1 should be true");
	t.assert(42 > 0, "42 > 0 should be true");
}

testAssertFalse(t: ref T)
{
	# This test verifies that a failed assertion marks the test as failed
	# We'll use a nested T to verify this behavior without affecting our test
	inner := ref T("inner", "", 0, 0, nil, 0);
	inner.assert(0, "expected failure");

	t.assert(inner.failed, "inner test should be marked as failed");
}

testFailOutranksSkip(t: ref T)
{
	# A recorded failure must not be retractable by a later skip.
	#
	# Several tests call t.error() when something fails and then
	# t.skip() to stop. If skip won, done() reported SKIP and summary()
	# counted it as a non-failure, so the suite exited 0 with a real
	# regression recorded and discarded.
	inner := ref T("inner", "", 0, 0, nil, 0);
	inner.error("something is genuinely broken");

	# skip() raises, so catch it the way a test runner would
	{
		inner.skip("giving up");
	} exception {
	"fail:skip" =>
		;
	* =>
		;
	}

	t.assert(inner.failed, "failure must survive a subsequent skip");
	t.assert(!inner.skipped, "skip must not mask an already-recorded failure");
}

testSkipAloneStillSkips(t: ref T)
{
	# The converse: a skip with no prior failure is still a skip.
	inner := ref T("inner", "", 0, 0, nil, 0);
	{
		inner.skip("genuinely unavailable");
	} exception {
	"fail:skip" =>
		;
	* =>
		;
	}

	t.assert(inner.skipped, "a skip with no failure must still be a skip");
	t.assert(!inner.failed, "skipping must not invent a failure");
}

testAssertHelpersFailOnMismatch(t: ref T)
{
	# The assertion helpers were only ever tested in the passing
	# direction, so if all of them were no-ops this file still passed --
	# and with it every suite that rests on them.
	inner := ref T("inner", "", 0, 0, nil, 0);
	inner.asserteq(1, 2, "mismatch");
	t.assert(inner.failed, "asserteq must fail on mismatch");

	inner = ref T("inner", "", 0, 0, nil, 0);
	inner.assertne(3, 3, "equal");
	t.assert(inner.failed, "assertne must fail when equal");

	inner = ref T("inner", "", 0, 0, nil, 0);
	inner.assertseq("a", "b", "mismatch");
	t.assert(inner.failed, "assertseq must fail on mismatch");

	inner = ref T("inner", "", 0, 0, nil, 0);
	inner.assertsne("a", "a", "equal");
	t.assert(inner.failed, "assertsne must fail when equal");

	inner = ref T("inner", "", 0, 0, nil, 0);
	inner.assertnil("not empty", "should be nil");
	t.assert(inner.failed, "assertnil must fail on a non-empty string");

	inner = ref T("inner", "", 0, 0, nil, 0);
	inner.assertnotnil("", "should be non-nil");
	t.assert(inner.failed, "assertnotnil must fail on an empty string");
}

testAssertEq(t: ref T)
{
	t.asserteq(1, 1, "1 should equal 1");
	t.asserteq(0, 0, "0 should equal 0");
	t.asserteq(-1, -1, "-1 should equal -1");
}

testAssertNe(t: ref T)
{
	t.assertne(1, 2, "1 should not equal 2");
	t.assertne(0, 1, "0 should not equal 1");
}

testAssertSeq(t: ref T)
{
	t.assertseq("hello", "hello", "strings should match");
	t.assertseq("", "", "empty strings should match");
}

testAssertSne(t: ref T)
{
	t.assertsne("hello", "world", "different strings should not match");
	t.assertsne("hello", "", "hello should not match empty");
}

testAssertNil(t: ref T)
{
	var: string;
	t.assertnil(var, "uninitialized string should be nil");
	t.assertnil(nil, "nil should be nil");
}

testAssertNotNil(t: ref T)
{
	t.assertnotnil("hello", "non-empty string should not be nil");
	# Note: In Limbo, "" equals nil, so we only test non-empty strings
}

testLog(t: ref T)
{
	t.log("this is a log message");
	# Just verify this doesn't crash
	t.assert(1, "log method should work");
}

testSkip(t: ref T)
{
	# Test that skip works by creating an inner test
	inner := ref T("inner-skip", "", 0, 0, nil, 0);

	# Simulate skip
	{
		inner.skip("skipping for test");
	} exception {
	"fail:skip" =>
		;	# expected
	}

	t.assert(inner.skipped, "inner test should be marked as skipped");
	t.assert(!inner.failed, "skipped test should not be marked as failed");
}

testFatal(t: ref T)
{
	# Test that fatal works by creating an inner test
	inner := ref T("inner-fatal", "", 0, 0, nil, 0);

	# Simulate fatal
	{
		inner.fatal("fatal error");
	} exception {
	"fail:fatal" =>
		;	# expected
	}

	t.assert(inner.failed, "inner test should be marked as failed after fatal");
}

testMultipleAssertions(t: ref T)
{
	# Multiple assertions in one test
	t.assert(1, "first");
	t.asserteq(2, 2, "second");
	t.assertseq("a", "a", "third");
	t.assertne(1, 2, "fourth");
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

	# Run all tests
	run("AssertTrue", testAssertTrue);
	run("AssertFalse", testAssertFalse);
	run("FailOutranksSkip", testFailOutranksSkip);
	run("SkipAloneStillSkips", testSkipAloneStillSkips);
	run("AssertHelpersFailOnMismatch", testAssertHelpersFailOnMismatch);
	run("AssertEq", testAssertEq);
	run("AssertNe", testAssertNe);
	run("AssertSeq", testAssertSeq);
	run("AssertSne", testAssertSne);
	run("AssertNil", testAssertNil);
	run("AssertNotNil", testAssertNotNil);
	run("Log", testLog);
	run("Skip", testSkip);
	run("Fatal", testFatal);
	run("MultipleAssertions", testMultipleAssertions);

	# Print summary
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
