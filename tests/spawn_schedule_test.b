implement SpawnScheduleTest;

#
# spawn_schedule_test - Unit tests for the at= / every= scheduling
# helpers in appl/veltro/tools/spawn.b (INFR-14).
#
# parseduration is duplicated inline here (same pattern as
# spawn_helpers_test.b) because spawn.b is a tool module whose only
# public surface is exec(). Keep this in sync with spawn.b.
#
# RFC 3339 parsing now lives in appl/lib/rfc3339.b and has its own test
# file (tests/rfc3339_test.b). This file just exercises the spawn-side
# wrapper (parserfc3339delta) for the past-rejection policy and the
# delta computation that scheduling needs.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;

include "rfc3339.m";
	rfc3339: Rfc3339;

include "testing.m";
	testing: Testing;
	T: import testing;

SpawnScheduleTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/spawn_schedule_test.b";

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
	* =>
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
# Helpers (DUPLICATED FROM spawn.b — keep in sync)
# ============================================================================

parseduration(s: string): (int, string)
{
	if(s == "")
		return (0, "empty duration");
	n := len s;
	if(n < 2)
		return (0, "duration too short (need <int><s|m|h|d>)");
	unit := s[n-1];
	digits := s[0:n-1];
	for(i := 0; i < len digits; i++)
		if(digits[i] < '0' || digits[i] > '9')
			return (0, "duration must be <int><unit>");
	val := int digits;
	if(val < 0)
		return (0, "negative duration");
	mult: int;
	case unit {
	's' => mult = 1000;
	'm' => mult = 60 * 1000;
	'h' => mult = 3600 * 1000;
	'd' => mult = 86400 * 1000;
	*   => return (0, "unknown unit (use s/m/h/d)");
	}
	return (val * mult, "");
}

# parserfc3339delta is the same wrapper spawn.b uses: rfc3339->parse,
# then reject-if-past, then return delta in milliseconds.
parserfc3339delta(s: string): (int, string)
{
	if(rfc3339 == nil || daytime == nil)
		return (0, "rfc3339 / daytime module not available");
	(target, perr) := rfc3339->parse(s);
	if(perr != "")
		return (0, perr);
	now := daytime->now();
	if(target <= now)
		return (0, "target time is in the past");
	return ((target - now) * 1000, "");
}

# ============================================================================
# parseduration tests
# ============================================================================

testDurationSeconds(t: ref T)
{
	(ms, err) := parseduration("30s");
	t.assertseq(err, "", "30s parse");
	t.asserteq(ms, 30000, "30s -> 30000 ms");
}

testDurationMinutes(t: ref T)
{
	(ms, err) := parseduration("5m");
	t.assertseq(err, "", "5m parse");
	t.asserteq(ms, 300000, "5m -> 300000 ms");
}

testDurationHours(t: ref T)
{
	(ms, err) := parseduration("1h");
	t.assertseq(err, "", "1h parse");
	t.asserteq(ms, 3600000, "1h -> 3600000 ms");
}

testDurationDays(t: ref T)
{
	(ms, err) := parseduration("1d");
	t.assertseq(err, "", "1d parse");
	t.asserteq(ms, 86400000, "1d -> 86400000 ms");
}

testDurationEmpty(t: ref T)
{
	(ms, err) := parseduration("");
	t.assertne(len err, 0, "empty input rejected");
	t.asserteq(ms, 0, "empty -> 0 ms");
}

testDurationUnknownUnit(t: ref T)
{
	(ms, err) := parseduration("5x");
	t.assertne(len err, 0, "unknown unit rejected");
	t.asserteq(ms, 0, "unknown unit -> 0 ms");
}

testDurationNoUnit(t: ref T)
{
	(ms, err) := parseduration("30");
	t.assertne(len err, 0, "no unit rejected");
	t.asserteq(ms, 0, "no unit -> 0 ms");
}

testDurationNonDigit(t: ref T)
{
	(ms, err) := parseduration("abcs");
	t.assertne(len err, 0, "non-digit prefix rejected");
	t.asserteq(ms, 0, "non-digit -> 0 ms");
}

testDurationZero(t: ref T)
{
	(ms, err) := parseduration("0s");
	t.assertseq(err, "", "0s parses");
	t.asserteq(ms, 0, "0s -> 0 ms");
}

# ============================================================================
# parserfc3339delta tests — only the spawn-specific wrapper policy
# (past rejection + delta computation). Format-correctness coverage
# lives in tests/rfc3339_test.b.
# ============================================================================

testDeltaFuture(t: ref T)
{
	(ms, err) := parserfc3339delta("2030-01-01T00:00:00Z");
	t.assertseq(err, "", "future timestamp parses");
	t.assert(ms > 0, "delta is positive");
}

testDeltaPast(t: ref T)
{
	(ms, err) := parserfc3339delta("2000-01-01T00:00:00Z");
	t.assertne(len err, 0, "past timestamp rejected");
	t.asserteq(ms, 0, "past -> 0 ms");
}

testDeltaSoonInFuture(t: ref T)
{
	# Synthesize ~10 minutes in future via daytime->now() + 600s
	if(daytime == nil) {
		t.skip("daytime not loaded");
		return;
	}
	target := daytime->now() + 600;
	tm := daytime->gmt(target);
	if(tm == nil) {
		t.skip("daytime->gmt returned nil");
		return;
	}
	stamp := sys->sprint("%4d-%02d-%02dT%02d:%02d:%02dZ",
		tm.year + 1900, tm.mon + 1, tm.mday,
		tm.hour, tm.min, tm.sec);
	(ms, err) := parserfc3339delta(stamp);
	t.assertseq(err, "", "synthesized future stamp parses");
	# Allow ~1s slack for the now() between target build and parserfc3339delta
	t.assert(ms > 599000, "delta > 599s in ms");
	t.assert(ms < 601000, "delta < 601s in ms");
}

# ============================================================================
# Main entry point
# ============================================================================

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	daytime = load Daytime Daytime->PATH;
	rfc3339 = load Rfc3339 Rfc3339->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(rfc3339 != nil)
		rfc3339->init();

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# parseduration: 9 cases
	run("DurationSeconds",     testDurationSeconds);
	run("DurationMinutes",     testDurationMinutes);
	run("DurationHours",       testDurationHours);
	run("DurationDays",        testDurationDays);
	run("DurationEmpty",       testDurationEmpty);
	run("DurationUnknownUnit", testDurationUnknownUnit);
	run("DurationNoUnit",      testDurationNoUnit);
	run("DurationNonDigit",    testDurationNonDigit);
	run("DurationZero",        testDurationZero);

	# parserfc3339delta: 3 cases (wrapper policy only)
	run("DeltaFuture",         testDeltaFuture);
	run("DeltaPast",           testDeltaPast);
	run("DeltaSoonInFuture",   testDeltaSoonInFuture);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
