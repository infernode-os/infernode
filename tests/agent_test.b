implement AgentTest;

#
# agent_test - Tests for the agent error handling and retry logic
#
# Tests:
# - Error classification (istransient, isfatal)
# - Backoff timing (getbackoff)
# - Contains helper function
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

AgentTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

# Source file path for clickable error addresses
SRCFILE: con "/tests/agent_test.b";

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

# ============================================================
# Helper functions (copied from agent.b for testing)
# ============================================================

# Check if string contains substring
contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++) {
		match := 1;
		for(j := 0; j < len sub; j++) {
			if(s[i+j] != sub[j]) {
				match = 0;
				break;
			}
		}
		if(match)
			return 1;
	}
	return 0;
}

# Check if error is transient (should retry)
istransient(err: string): int
{
	if(contains(err, "rate limit") || contains(err, "rate_limit") ||
	   contains(err, "timeout") || contains(err, "timed out") ||
	   contains(err, "connection refused") || contains(err, "connection reset") ||
	   contains(err, "temporarily unavailable") || contains(err, "try again") ||
	   contains(err, "overloaded") || contains(err, "503") || contains(err, "529") ||
	   contains(err, "ECONNREFUSED") || contains(err, "ETIMEDOUT"))
		return 1;
	return 0;
}

# Check if error is fatal (should stop agent)
isfatal(err: string): int
{
	if(contains(err, "cannot open /mnt/llm") || contains(err, "not mounted") ||
	   contains(err, "namespace") || contains(err, "permission denied on /mnt/llm") ||
	   contains(err, "authentication failed") || contains(err, "invalid API key"))
		return 1;
	return 0;
}

# Backoff constants
BACKOFF_1 := 1000;
BACKOFF_2 := 2000;
BACKOFF_3 := 4000;

# Get backoff delay for retry attempt
getbackoff(attempt: int): int
{
	if(attempt == 0)
		return BACKOFF_1;
	if(attempt == 1)
		return BACKOFF_2;
	return BACKOFF_3;
}

# ============================================================
# Tests
# ============================================================

# Test contains helper function
testContains(t: ref T)
{
	t.assert(contains("hello world", "hello") == 1, "should find 'hello' in 'hello world'");
	t.assert(contains("hello world", "world") == 1, "should find 'world' in 'hello world'");
	t.assert(contains("hello world", "lo wo") == 1, "should find 'lo wo' in 'hello world'");
	t.assert(contains("hello", "hello") == 1, "should find exact match");
	t.assert(contains("hello", "goodbye") == 0, "should not find 'goodbye' in 'hello'");
	t.assert(contains("short", "this is longer") == 0, "should not find longer in shorter");
	t.assert(contains("", "x") == 0, "should not find in empty string");
	t.assert(contains("x", "") == 1, "empty substring always matches");
}

# Test istransient - rate limit errors
testIsTransientRateLimit(t: ref T)
{
	t.assert(istransient("rate limit exceeded") == 1, "rate limit");
	t.assert(istransient("rate_limit_error") == 1, "rate_limit");
	t.assert(istransient("API rate limit reached") == 1, "API rate limit");
}

# Test istransient - timeout errors
testIsTransientTimeout(t: ref T)
{
	t.assert(istransient("request timeout") == 1, "timeout");
	t.assert(istransient("connection timed out") == 1, "timed out");
	t.assert(istransient("ETIMEDOUT") == 1, "ETIMEDOUT");
}

# Test istransient - connection errors
testIsTransientConnection(t: ref T)
{
	t.assert(istransient("connection refused") == 1, "connection refused");
	t.assert(istransient("connection reset by peer") == 1, "connection reset");
	t.assert(istransient("ECONNREFUSED") == 1, "ECONNREFUSED");
}

# Test istransient - server errors
testIsTransientServer(t: ref T)
{
	t.assert(istransient("server temporarily unavailable") == 1, "temporarily unavailable");
	t.assert(istransient("please try again later") == 1, "try again");
	t.assert(istransient("server overloaded") == 1, "overloaded");
	t.assert(istransient("503 Service Unavailable") == 1, "503");
	t.assert(istransient("529 overloaded") == 1, "529");
}

# Test istransient - non-transient errors
testIsTransientFalse(t: ref T)
{
	t.assert(istransient("file not found") == 0, "file not found is not transient");
	t.assert(istransient("invalid syntax") == 0, "invalid syntax is not transient");
	t.assert(istransient("permission denied") == 0, "permission denied is not transient");
	t.assert(istransient("") == 0, "empty string is not transient");
}

# Test isfatal - namespace errors
testIsFatalNamespace(t: ref T)
{
	t.assert(isfatal("cannot open /mnt/llm/ask: file does not exist") == 1, "cannot open /mnt/llm");
	t.assert(isfatal("llm9p not mounted") == 1, "not mounted");
	t.assert(isfatal("namespace error") == 1, "namespace");
}

# Test isfatal - authentication errors
testIsFatalAuth(t: ref T)
{
	t.assert(isfatal("authentication failed") == 1, "authentication failed");
	t.assert(isfatal("invalid API key") == 1, "invalid API key");
	t.assert(isfatal("permission denied on /mnt/llm/ask") == 1, "permission denied on /mnt/llm");
}

# Test isfatal - non-fatal errors
testIsFatalFalse(t: ref T)
{
	t.assert(isfatal("rate limit exceeded") == 0, "rate limit is not fatal");
	t.assert(isfatal("timeout") == 0, "timeout is not fatal");
	t.assert(isfatal("empty response") == 0, "empty response is not fatal");
	t.assert(isfatal("") == 0, "empty string is not fatal");
	# Note: generic "permission denied" without /mnt/llm is not fatal
	t.assert(isfatal("permission denied on /tmp/foo") == 0, "permission denied elsewhere is not fatal");
}

# Test getbackoff timing
testGetBackoff(t: ref T)
{
	t.asserteq(getbackoff(0), 1000, "attempt 0 should be 1000ms");
	t.asserteq(getbackoff(1), 2000, "attempt 1 should be 2000ms");
	t.asserteq(getbackoff(2), 4000, "attempt 2 should be 4000ms");
	t.asserteq(getbackoff(3), 4000, "attempt 3+ should be 4000ms");
	t.asserteq(getbackoff(100), 4000, "large attempt should be 4000ms");
}

# Test error classification is mutually exclusive where expected
testErrorClassification(t: ref T)
{
	# Transient errors should not be fatal
	t.assert(istransient("rate limit") == 1 && isfatal("rate limit") == 0,
		"rate limit is transient but not fatal");
	t.assert(istransient("timeout") == 1 && isfatal("timeout") == 0,
		"timeout is transient but not fatal");

	# Fatal errors should not be transient
	t.assert(isfatal("cannot open /mnt/llm") == 1 && istransient("cannot open /mnt/llm") == 0,
		"namespace error is fatal but not transient");
	t.assert(isfatal("invalid API key") == 1 && istransient("invalid API key") == 0,
		"auth error is fatal but not transient");
}

# Test backoff constants
testBackoffConstants(t: ref T)
{
	# Verify exponential increase
	t.assert(BACKOFF_2 > BACKOFF_1, "BACKOFF_2 should be greater than BACKOFF_1");
	t.assert(BACKOFF_3 > BACKOFF_2, "BACKOFF_3 should be greater than BACKOFF_2");

	# Verify reasonable values
	t.assert(BACKOFF_1 >= 1000, "BACKOFF_1 should be at least 1 second");
	t.assert(BACKOFF_3 <= 10000, "BACKOFF_3 should be at most 10 seconds");
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

	# Run tests
	run("Contains", testContains);
	run("IsTransientRateLimit", testIsTransientRateLimit);
	run("IsTransientTimeout", testIsTransientTimeout);
	run("IsTransientConnection", testIsTransientConnection);
	run("IsTransientServer", testIsTransientServer);
	run("IsTransientFalse", testIsTransientFalse);
	run("IsFatalNamespace", testIsFatalNamespace);
	run("IsFatalAuth", testIsFatalAuth);
	run("IsFatalFalse", testIsFatalFalse);
	run("GetBackoff", testGetBackoff);
	run("ErrorClassification", testErrorClassification);
	run("BackoffConstants", testBackoffConstants);

	# Print summary
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
