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

# The longest wait sys->sleep takes: 2^31-1 ms, some 24.8 days.
# Durations and at= times are refused beyond it, not wrapped.
MAXMS: con 16r7FFFFFFF;

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
	mult: big;
	case unit {
	's' => mult = big 1000;
	'm' => mult = big (60 * 1000);
	'h' => mult = big (3600 * 1000);
	'd' => mult = big (86400 * 1000);
	*   => return (0, "unknown unit (use s/m/h/d)");
	}
	# in big: an int of milliseconds holds no more than MAXMS
	if(len digits > 12)
		return (0, "duration too long: at most 24 days");
	ms := big digits * mult;
	if(ms > big MAXMS)
		return (0, "duration too long: at most 24 days");
	return (int ms, "");
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
	ms := (big target - big now) * big 1000;
	if(ms > big MAXMS)
		return (0, "target time is more than 24 days ahead");
	return (int ms, "");
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

# Further ahead than an int of milliseconds reaches: refused, where the
# delta once wrapped (negative on arm64, so a schedule of nothing)
testDeltaTooFar(t: ref T)
{
	(ms, err) := parserfc3339delta("2030-01-01T00:00:00Z");
	t.assertseq(err, "target time is more than 24 days ahead", "2030 is refused");
	t.asserteq(ms, 0, "no delta");
}

testDurationTooLong(t: ref T)
{
	(ms, err) := parseduration("24d");
	t.assertseq(err, "", "24d parses");
	t.asserteq(ms, 24*86400000, "24d -> ms");
	(nil, err) = parseduration("30d");
	t.assertseq(err, "duration too long: at most 24 days", "30d is refused");
	(nil, err) = parseduration("99999999999999s");
	t.assertseq(err, "duration too long: at most 24 days", "a huge count is refused");
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
	run("DurationTooLong",     testDurationTooLong);

	# parserfc3339delta: 3 cases (wrapper policy only)
	run("DeltaTooFar",         testDeltaTooFar);
	run("DeltaPast",           testDeltaPast);
	run("DeltaSoonInFuture",   testDeltaSoonInFuture);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
