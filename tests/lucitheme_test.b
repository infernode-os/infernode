implement LucithemeTest;

#
# Regression tests for Lucitheme module (2026-03, extended 2026-09).
#
# Covers:
#   - Lucitheme->gettheme() renamed from load() (Limbo reserved keyword fix)
#   - Brimstone default colour values used by wmclient and edit
#   - wmclient border colour fix: accent (not hardcoded teal 0x448888FF)
#   - wmclient border colour fix: border (not hardcoded cyan 0x9EEEEEFF)
#   - wmclient background fix: bg is not white (no white flash on window close)
#   - A theme file's colour whose red channel is >= 0x80 is parsed, not
#     silently dropped (2026-09; see FromFileHighRed* below)
#
# What the tests above never exercised: parsehex() packs "RRGGBB" into
# a 32-bit RRGGBBAA int with alpha always FF, and any colour whose red
# channel is >= 0x80 -- most of a light theme's near-white colours --
# sets that int's sign bit and comes back negative. gettheme() used to
# read "value < 0" as "this line failed to parse" and silently kept
# Brimstone's default for that key. On Halo (bg FFFFEA, header
# EAFFFF, ...) the desktop's own hand-drawn zones (conv, ctx,
# presentation -- appl/cmd/luci{conv,ctx,pres}.b) kept Brimstone's
# dark background and header while Halo's accent (2266CC, red channel
# 0x22, unaffected) came through fine: the highlight changed, the
# background didn't. Every test above uses brimstone()'s own
# hardcoded fields (correct regardless, since they are Limbo int
# literals, not parsed) or gettheme() with no theme file on disk (the
# same brimstone() fallback) -- neither one calls parsehex() on a
# colour that would expose the bug.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "lucitheme.m";
	lucitheme: Lucitheme;

LucithemeTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/lucitheme_test.b";

passed  := 0;
failed  := 0;
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

testBrimstoneNotNil(t: ref T)
{
	th := lucitheme->brimstone();
	t.assert(th != nil, "brimstone() returns non-nil");
}

testBrimstoneColors(t: ref T)
{
	th := lucitheme->brimstone();
	if(!t.assert(th != nil, "brimstone() returns non-nil"))
		return;

	# Core UI colours
	t.asserteq(th.bg,     int 16r080808FF, "bg is near-black (0x080808FF)");
	t.asserteq(th.border, int 16r131313FF, "border is near-black (0x131313FF)");
	t.asserteq(th.accent, int 16rE8553AFF, "accent is orange (0xE8553AFF)");
	t.asserteq(th.text,   int 16rCCCCCCFF, "text is light grey (0xCCCCCCFF)");

	# Editor colours (edit theme integration)
	t.asserteq(th.editbg,     int 16r0D0D0DFF, "editbg is near-black (0x0D0D0DFF)");
	t.asserteq(th.edittext,   int 16rCCCCCCFF, "edittext is light grey (0xCCCCCCFF)");
	t.asserteq(th.editcursor, int 16rE8553AFF, "editcursor is orange/accent (0xE8553AFF)");
	t.asserteq(th.red,        int 16rAA4444FF, "red is muted red (0xAA4444FF)");

	# wmclient now draws a single subdued border using th.windowborder
	# regardless of focus state.  Brimstone default sits between bg and
	# header so the frame is visible but doesn't compete with content.
	t.asserteq(th.windowborder, int 16r1A1A1AFF, "windowborder is subdued grey (0x1A1A1AFF)");
	t.assertne(th.windowborder, int 16rFFFFFFFF, "windowborder is not white");

	# wmclient background fix: screenbg = th.bg, must not be white
	t.assertne(th.bg, int 16rFFFFFFFF, "bg is not white — no white flash on window close");
}

testGetThemeNotNil(t: ref T)
{
	# gettheme() was renamed from load() which is a Limbo reserved keyword.
	# If this symbol doesn't exist, the test won't compile — that's the regression.
	th := lucitheme->gettheme();
	t.assert(th != nil, "gettheme() returns non-nil (falls back to brimstone if no theme file)");
}

testGetThemeAlpha(t: ref T)
{
	# All colour fields produced by gettheme() must have full alpha (0xFF low byte).
	# parsehex() in lucitheme.b always ORs 0xFF; this test confirms the invariant holds.
	th := lucitheme->gettheme();
	if(!t.assert(th != nil, "gettheme() returns non-nil"))
		return;

	t.asserteq(th.bg     & 16rFF, 16rFF, "bg has full alpha");
	t.asserteq(th.border & 16rFF, 16rFF, "border has full alpha");
	t.asserteq(th.accent & 16rFF, 16rFF, "accent has full alpha");
	t.asserteq(th.editbg & 16rFF, 16rFF, "editbg has full alpha");
	t.asserteq(th.text   & 16rFF, 16rFF, "text has full alpha");
}

THEMEDIR: con "/lib/lucifer/theme/";

writefile(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fd = sys->open(path, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil)
		return;
	b := array of byte data;
	sys->write(fd, b, len b);
}

# Fork a namespace, shadow THEMEDIR with a fixture shaped exactly like
# Halo's real file -- a light background, a light header, an accent
# that always worked, and a line that is not a valid colour at all --
# and hand the parsed theme back. The bind is in a forked namespace so
# the tree's real theme files are never touched.
probefromfile(resc: chan of ref Lucitheme->Theme)
{
	sys->pctl(Sys->NEWPGRP, nil);
	sys->pctl(Sys->FORKNS, nil);

	dir := sys->sprint("/tmp/lucitheme_test.%d", sys->pctl(0, nil));
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r755);
	writefile(dir + "/current", "lighttest");
	writefile(dir + "/lighttest",
		"bg FFFFEA\n" +			# red channel 0xFF: the failing case
		"header EAFFFF\n" +		# red channel 0xEA: also failing
		"accent 2266CC\n" +		# red channel 0x22: always worked
		"badline notahexcolour\n");	# still skipped, not a crash

	if(sys->bind(dir, THEMEDIR, Sys->MREPL) < 0) {
		resc <-= nil;
		return;
	}

	lt := load Lucitheme Lucitheme->PATH;
	resc <-= lt->gettheme();
}

fromfiletheme(): ref Lucitheme->Theme
{
	resc := chan of ref Lucitheme->Theme;
	spawn probefromfile(resc);
	return <-resc;
}

testFromFileHighRedBackground(t: ref T)
{
	th := fromfiletheme();
	if(!t.assert(th != nil, "probe could not set up its namespace"))
		return;
	t.asserteq(th.bg, int 16rFFFFEAFF, "bg FFFFEA (red 0xFF) is applied, not left at Brimstone's default");
}

testFromFileHighRedHeader(t: ref T)
{
	th := fromfiletheme();
	if(!t.assert(th != nil, "probe could not set up its namespace"))
		return;
	t.asserteq(th.header, int 16rEAFFFFFF, "header EAFFFF (red 0xEA) is applied, not left at Brimstone's default");
}

testFromFileLowRedAccentStillWorks(t: ref T)
{
	th := fromfiletheme();
	if(!t.assert(th != nil, "probe could not set up its namespace"))
		return;
	t.asserteq(th.accent, int 16r2266CCFF, "accent 2266CC (red 0x22, the case that always worked) is unaffected");
}

testFromFileInvalidLineIsSkippedNotFatal(t: ref T)
{
	th := fromfiletheme();
	# "badline notahexcolour" must not have crashed gettheme() or
	# corrupted a neighbouring field; accent is the check for that.
	t.assert(th != nil, "gettheme survives a line that is not a valid colour");
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

	lucitheme = load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil) {
		sys->fprint(sys->fildes(2), "cannot load lucitheme module: %r\n");
		raise "fail:cannot load lucitheme";
	}

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("BrimstoneNotNil",  testBrimstoneNotNil);
	run("BrimstoneColors",  testBrimstoneColors);
	run("GetThemeNotNil",   testGetThemeNotNil);
	run("GetThemeAlpha",    testGetThemeAlpha);
	run("FromFileHighRedBackground",       testFromFileHighRedBackground);
	run("FromFileHighRedHeader",           testFromFileHighRedHeader);
	run("FromFileLowRedAccentStillWorks",  testFromFileLowRedAccentStillWorks);
	run("FromFileInvalidLineIsSkippedNotFatal", testFromFileInvalidLineIsSkippedNotFatal);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
