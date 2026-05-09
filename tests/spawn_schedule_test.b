implement SpawnScheduleTest;

#
# spawn_schedule_test - Unit tests for the at= / every= parsing helpers
# in appl/veltro/tools/spawn.b (INFR-14).
#
# These exercise pure-logic helpers — they do not invoke runchild() or
# create real subagents. Helpers are duplicated inline (same pattern as
# spawn_helpers_test.b) because spawn.b is a tool module whose only
# public surface is exec(). Keep this file in sync with spawn.b's
# parseduration() and parserfc3339delta().
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;

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

parserfc3339delta(s: string): (int, string)
{
	if(daytime == nil)
		return (0, "daytime module not available");
	(tm, tzoff_s, perr) := parserfc3339(s);
	if(perr != "")
		return (0, perr);
	target_local := daytime->tm2epoch(tm);
	target_utc := target_local - tzoff_s;
	now := daytime->now();
	if(target_utc <= now)
		return (0, "target time is in the past");
	return ((target_utc - now) * 1000, "");
}

parserfc3339(s: string): (ref Daytime->Tm, int, string)
{
	if(len s < 20)
		return (nil, 0, "rfc3339 timestamp too short");
	if(s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != ' ') ||
	   s[13] != ':' || s[16] != ':')
		return (nil, 0, "rfc3339 punctuation: expected YYYY-MM-DDTHH:MM:SS<TZ>");
	year   := atoi4(s[0:4]);
	month  := atoi2(s[5:7]);
	day    := atoi2(s[8:10]);
	hour   := atoi2(s[11:13]);
	minute := atoi2(s[14:16]);
	sec    := atoi2(s[17:19]);
	if(year < 0 || month < 1 || month > 12 || day < 1 || day > 31 ||
	   hour < 0 || hour > 23 || minute < 0 || minute > 59 ||
	   sec < 0 || sec > 60)
		return (nil, 0, "rfc3339 numeric field out of range");
	tz := s[19:];
	if(len tz > 0 && tz[0] == '.') {
		i := 1;
		while(i < len tz && tz[i] >= '0' && tz[i] <= '9')
			i++;
		tz = tz[i:];
	}
	tzoff := 0;
	if(len tz == 1 && (tz[0] == 'Z' || tz[0] == 'z')) {
		tzoff = 0;
	} else if(len tz == 6 && (tz[0] == '+' || tz[0] == '-') && tz[3] == ':') {
		off_h := atoi2(tz[1:3]);
		off_m := atoi2(tz[4:6]);
		if(off_h < 0 || off_h > 23 || off_m < 0 || off_m > 59)
			return (nil, 0, "rfc3339 timezone offset out of range");
		tzoff = (off_h * 3600) + (off_m * 60);
		if(tz[0] == '-')
			tzoff = -tzoff;
	} else {
		return (nil, 0, "rfc3339 timezone: expected Z, +HH:MM, or -HH:MM");
	}
	tm := ref Daytime->Tm;
	tm.sec = sec; tm.min = minute; tm.hour = hour;
	tm.mday = day; tm.mon = month - 1; tm.year = year - 1900;
	tm.zone = "GMT"; tm.tzoff = 0;
	return (tm, tzoff, "");
}

atoi2(s: string): int
{
	if(len s != 2 || s[0] < '0' || s[0] > '9' || s[1] < '0' || s[1] > '9')
		return -1;
	return (s[0] - '0') * 10 + (s[1] - '0');
}

atoi4(s: string): int
{
	if(len s != 4)
		return -1;
	v := 0;
	for(i := 0; i < 4; i++) {
		if(s[i] < '0' || s[i] > '9')
			return -1;
		v = v * 10 + (s[i] - '0');
	}
	return v;
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
	# "30" has length 2 with no recognized unit ('0' is not s/m/h/d)
	(ms, err) := parseduration("30");
	t.assertne(len err, 0, "no unit rejected");
	t.asserteq(ms, 0, "no unit -> 0 ms");
}

testDurationNonDigit(t: ref T)
{
	# "abcs" — non-digit prefix should be rejected before int conversion
	# silently strips the suffix.
	(ms, err) := parseduration("abcs");
	t.assertne(len err, 0, "non-digit prefix rejected");
	t.asserteq(ms, 0, "non-digit -> 0 ms");
}

testDurationZero(t: ref T)
{
	# Zero is parsed successfully; the spawn-side caller is responsible
	# for rejecting period == 0 with a clearer "must be positive" error.
	(ms, err) := parseduration("0s");
	t.assertseq(err, "", "0s parses");
	t.asserteq(ms, 0, "0s -> 0 ms");
}

# ============================================================================
# parserfc3339delta tests
# ============================================================================

testRfc3339Future(t: ref T)
{
	# A timestamp far in the future (year 2099)
	(ms, err) := parserfc3339delta("2099-01-01T00:00:00Z");
	t.assertseq(err, "", "future timestamp parses");
	t.assert(ms > 0, "delta is positive");
}

testRfc3339Past(t: ref T)
{
	# Year 2000 is definitely in the past as of this writing
	(ms, err) := parserfc3339delta("2000-01-01T00:00:00Z");
	t.assertne(len err, 0, "past timestamp rejected");
	t.asserteq(ms, 0, "past -> 0 ms");
}

testRfc3339Garbage(t: ref T)
{
	(ms, err) := parserfc3339delta("not a date");
	t.assertne(len err, 0, "garbage rejected");
	t.asserteq(ms, 0, "garbage -> 0 ms");
}

testRfc3339Empty(t: ref T)
{
	(ms, err) := parserfc3339delta("");
	t.assertne(len err, 0, "empty rejected");
	t.asserteq(ms, 0, "empty -> 0 ms");
}

testRfc3339SoonInFuture(t: ref T)
{
	# Build a timestamp ~10 minutes in the future via daytime->now() + 600s
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
	# RFC3339 format: 2026-05-09T22:00:00Z (gmt -> Z suffix)
	stamp := sys->sprint("%4d-%02d-%02dT%02d:%02d:%02dZ",
		tm.year + 1900, tm.mon + 1, tm.mday,
		tm.hour, tm.min, tm.sec);
	(ms, err) := parserfc3339delta(stamp);
	t.assertseq(err, "", "synthesized future stamp parses");
	# Allow generous slack for slow CI: between 599_000 and 601_000 ms
	t.assert(ms > 599000, "delta > 599s in ms");
	t.assert(ms < 601000, "delta < 601s in ms");
}

testRfc3339TzOffsetEquivalence(t: ref T)
{
	# 2099-01-01T00:00:00Z and 2099-01-01T02:00:00+02:00 are the same
	# instant. Their deltas-from-now must agree (allow 100ms slack for
	# the now() call drifting between the two parses).
	(msZ,   eZ)   := parserfc3339delta("2099-01-01T00:00:00Z");
	(msPos, ePos) := parserfc3339delta("2099-01-01T02:00:00+02:00");
	t.assertseq(eZ,   "", "Z form parses");
	t.assertseq(ePos, "", "+02:00 form parses");
	diff := msZ - msPos;
	if(diff < 0)
		diff = -diff;
	t.assert(diff < 100, "Z and +02:00 deltas agree within 100 ms");
}

testRfc3339NegativeTzOffset(t: ref T)
{
	# 2099-01-01T00:00:00Z and 2098-12-31T19:00:00-05:00 are the same
	# instant (5h west of UTC).
	(msZ,   eZ)   := parserfc3339delta("2099-01-01T00:00:00Z");
	(msNeg, eNeg) := parserfc3339delta("2098-12-31T19:00:00-05:00");
	t.assertseq(eZ,   "", "Z form parses");
	t.assertseq(eNeg, "", "-05:00 form parses");
	diff := msZ - msNeg;
	if(diff < 0)
		diff = -diff;
	t.assert(diff < 100, "Z and -05:00 deltas agree within 100 ms");
}

testRfc3339FractionalSeconds(t: ref T)
{
	# Fractional seconds should be tolerated (skipped, not parsed).
	(ms, err) := parserfc3339delta("2099-01-01T00:00:00.123Z");
	t.assertseq(err, "", "fractional-second form parses");
	t.assert(ms > 0, "delta is positive");
}

# ============================================================================
# Main entry point
# ============================================================================

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	daytime = load Daytime Daytime->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("DurationSeconds",     testDurationSeconds);
	run("DurationMinutes",     testDurationMinutes);
	run("DurationHours",       testDurationHours);
	run("DurationDays",        testDurationDays);
	run("DurationEmpty",       testDurationEmpty);
	run("DurationUnknownUnit", testDurationUnknownUnit);
	run("DurationNoUnit",      testDurationNoUnit);
	run("DurationNonDigit",    testDurationNonDigit);
	run("DurationZero",        testDurationZero);
	run("Rfc3339Future",                 testRfc3339Future);
	run("Rfc3339Past",                   testRfc3339Past);
	run("Rfc3339Garbage",                testRfc3339Garbage);
	run("Rfc3339Empty",                  testRfc3339Empty);
	run("Rfc3339SoonInFuture",           testRfc3339SoonInFuture);
	run("Rfc3339TzOffsetEquivalence",    testRfc3339TzOffsetEquivalence);
	run("Rfc3339NegativeTzOffset",       testRfc3339NegativeTzOffset);
	run("Rfc3339FractionalSeconds",      testRfc3339FractionalSeconds);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
