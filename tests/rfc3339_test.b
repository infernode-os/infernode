implement Rfc3339Test;

#
# rfc3339_test - Tests for appl/lib/rfc3339.b
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

Rfc3339Test: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/rfc3339_test.b";

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
# Happy paths
# ============================================================================

testZForm(t: ref T)
{
	# 2030-01-01T00:00:00Z = 1893456000 epoch seconds. Year is kept under
	# the 2038-01-19 32-bit signed-int boundary because Inferno's
	# daytime->tm2epoch returns int and overflows past it.
	(epoch, err) := rfc3339->parse("2030-01-01T00:00:00Z");
	t.assertseq(err, "", "Z form parses");
	t.asserteq(epoch, 1893456000, "Z form -> 1893456000");
}

testLowercaseZ(t: ref T)
{
	(epochZ, eZ)   := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochz, ez)   := rfc3339->parse("2030-01-01T00:00:00z");
	t.assertseq(eZ, "", "uppercase Z parses");
	t.assertseq(ez, "", "lowercase z parses");
	t.asserteq(epochZ, epochz, "Z and z are equivalent");
}

testSpaceSeparator(t: ref T)
{
	# RFC 3339 §5.6 NOTE: "applications that generate this format
	# SHOULD use uppercase 'T' character" but allow space as alternative
	(epochT,   eT)   := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochSp,  eSp)  := rfc3339->parse("2030-01-01 00:00:00Z");
	t.assertseq(eT,  "", "T separator parses");
	t.assertseq(eSp, "", "space separator parses");
	t.asserteq(epochT, epochSp, "T and space are equivalent");
}

testPositiveOffset(t: ref T)
{
	# 2030-01-01T00:00:00Z and 2030-01-01T02:00:00+02:00 are the same instant
	(epochZ, eZ)     := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochOff, eOff) := rfc3339->parse("2030-01-01T02:00:00+02:00");
	t.assertseq(eZ,   "", "Z form parses");
	t.assertseq(eOff, "", "+02:00 form parses");
	t.asserteq(epochZ, epochOff, "+02:00 equivalence");
}

testNegativeOffset(t: ref T)
{
	# 2030-01-01T00:00:00Z and 2029-12-31T19:00:00-05:00 are the same instant
	(epochZ, eZ)     := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochOff, eOff) := rfc3339->parse("2029-12-31T19:00:00-05:00");
	t.assertseq(eZ,   "", "Z form parses");
	t.assertseq(eOff, "", "-05:00 form parses");
	t.asserteq(epochZ, epochOff, "-05:00 equivalence");
}

testFractionalSeconds(t: ref T)
{
	# Fractional seconds are tolerated (skipped, not retained)
	(epochPlain, ePlain) := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochFrac,  eFrac)  := rfc3339->parse("2030-01-01T00:00:00.123456Z");
	t.assertseq(ePlain, "", "plain form parses");
	t.assertseq(eFrac,  "", "fractional form parses");
	t.asserteq(epochPlain, epochFrac, "fractional seconds discarded");
}

testNoonOffset(t: ref T)
{
	# Half-hour offset (e.g. India IST is +05:30): exercise the minutes
	# field of the offset.
	(epochZ,   eZ)   := rfc3339->parse("2030-01-01T00:00:00Z");
	(epochIST, eIST) := rfc3339->parse("2030-01-01T05:30:00+05:30");
	t.assertseq(eZ,   "", "Z form parses");
	t.assertseq(eIST, "", "+05:30 form parses");
	t.asserteq(epochZ, epochIST, "+05:30 equivalence");
}

# ============================================================================
# Rejections
# ============================================================================

testRejectShort(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-01-01");
	t.assertne(len err, 0, "date-only rejected");
}

testRejectEmpty(t: ref T)
{
	(epoch, err) := rfc3339->parse("");
	t.assertne(len err, 0, "empty rejected");
}

testRejectGarbage(t: ref T)
{
	(epoch, err) := rfc3339->parse("not a date at all");
	t.assertne(len err, 0, "garbage rejected");
}

testRejectBadPunctuation(t: ref T)
{
	# Underscore in place of T (note: SPKI uses this format, RFC3339 does not)
	(epoch, err) := rfc3339->parse("2099-01-01_00:00:00Z");
	t.assertne(len err, 0, "underscore separator rejected");
}

testRejectMonth13(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-13-01T00:00:00Z");
	t.assertne(len err, 0, "month 13 rejected");
}

testRejectMonth0(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-00-01T00:00:00Z");
	t.assertne(len err, 0, "month 0 rejected");
}

testRejectDay32(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-01-32T00:00:00Z");
	t.assertne(len err, 0, "day 32 rejected");
}

testRejectHour24(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-01-01T24:00:00Z");
	t.assertne(len err, 0, "hour 24 rejected");
}

testRejectMissingTz(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-01-01T00:00:00");
	t.assertne(len err, 0, "missing TZ rejected");
}

testRejectBadOffset(t: ref T)
{
	(epoch, err) := rfc3339->parse("2099-01-01T00:00:00+25:00");
	t.assertne(len err, 0, "offset hour 25 rejected");
}

testRejectNonDigit(t: ref T)
{
	# A letter where a digit must be should fail without silent truncation.
	(epoch, err) := rfc3339->parse("20XX-01-01T00:00:00Z");
	t.assertne(len err, 0, "non-digit year rejected");
}

# ============================================================================
# Round-trip via daytime
# ============================================================================

testRoundTrip(t: ref T)
{
	# Synthesize a timestamp from current time, format it as RFC3339,
	# parse it back, assert agreement (within the second-resolution loss).
	if(daytime == nil) {
		t.skip("daytime not loaded");
		return;
	}
	now := daytime->now();
	tm := daytime->gmt(now);
	if(tm == nil) {
		t.skip("daytime->gmt returned nil");
		return;
	}
	stamp := sys->sprint("%4d-%02d-%02dT%02d:%02d:%02dZ",
		tm.year + 1900, tm.mon + 1, tm.mday,
		tm.hour, tm.min, tm.sec);
	(parsed, err) := rfc3339->parse(stamp);
	t.assertseq(err, "", "synthesized stamp parses");
	t.asserteq(parsed, now, "round-trip preserves epoch");
}

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
	if(rfc3339 == nil) {
		sys->fprint(sys->fildes(2), "cannot load Rfc3339 module: %r\n");
		raise "fail:cannot load Rfc3339";
	}

	testing->init();
	rfc3339->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Happy paths
	run("ZForm",              testZForm);
	run("LowercaseZ",         testLowercaseZ);
	run("SpaceSeparator",     testSpaceSeparator);
	run("PositiveOffset",     testPositiveOffset);
	run("NegativeOffset",     testNegativeOffset);
	run("FractionalSeconds",  testFractionalSeconds);
	run("HalfHourOffset",     testNoonOffset);

	# Rejections
	run("RejectShort",         testRejectShort);
	run("RejectEmpty",         testRejectEmpty);
	run("RejectGarbage",       testRejectGarbage);
	run("RejectBadPunctuation",testRejectBadPunctuation);
	run("RejectMonth13",       testRejectMonth13);
	run("RejectMonth0",        testRejectMonth0);
	run("RejectDay32",         testRejectDay32);
	run("RejectHour24",        testRejectHour24);
	run("RejectMissingTz",     testRejectMissingTz);
	run("RejectBadOffset",     testRejectBadOffset);
	run("RejectNonDigit",      testRejectNonDigit);

	# Round-trip
	run("RoundTrip",           testRoundTrip);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
