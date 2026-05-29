implement SoftkbdTest;

#
# softkbd_test — Unit tests for /dis/lib/softkbd.dis.
#
# Coverage:
#   - show(mode) emits the legacy verbs ("kbd on" / "kbd ontop" / "kbd off")
#     in the exact wire format devcons.c parses.
#   - set_rect(x,y,w,h) emits a four-int "kbd rect" line that matches
#     the sscanf in devcons.c.
#   - set_rect with w<=0 or h<=0 emits the canonical "kbd rect 0 0 0 0"
#     (override clear) — the legacy top/bottom heuristic comes back.
#   - clear_rect() emits the same canonical clear.
#   - Unknown modes are silently dropped (no spurious writes).
#
# We can't drive the SDL slide from a host build (no soft keyboard on
# macOS/Linux SDL3). What we *can* verify is that the bytes going
# downstream match devcons's parser — that's the contract.
#
# Mechanism: the module reads /env/SOFTKBD_PATH at init() and writes
# verbs to that path instead of /dev/consctl. The test sets the env
# var to /tmp/softkbd_test_fixture, then for each sub-case truncates
# the fixture, exercises the API, and reads the bytes back.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "softkbd.m";
	softkbd: Softkbd;

SoftkbdTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/softkbd_test.b";
FIXTURE: con "/tmp/softkbd_test_fixture";

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

# Replace fixture with an empty file so the next API call sees a clean
# slate. Used at the start of every sub-case so verbs don't pile up.
reset_fixture()
{
	sys->remove(FIXTURE);
	fd := sys->create(FIXTURE, Sys->OWRITE, 8r600);
	if(fd == nil)
		raise sys->sprint("fail:cannot create fixture: %r");
}

read_fixture(): string
{
	fd := sys->open(FIXTURE, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[:n];
}

testShowSlide(t: ref T)
{
	reset_fixture();
	softkbd->show(Softkbd->SLIDE);
	t.assertseq(read_fixture(), "kbd on", "SLIDE -> 'kbd on'");
}

testShowKeeptop(t: ref T)
{
	reset_fixture();
	softkbd->show(Softkbd->KEEPTOP);
	t.assertseq(read_fixture(), "kbd ontop", "KEEPTOP -> 'kbd ontop'");
}

testShowHide(t: ref T)
{
	reset_fixture();
	softkbd->show(Softkbd->HIDE);
	t.assertseq(read_fixture(), "kbd off", "HIDE -> 'kbd off'");
}

testShowUnknownIgnored(t: ref T)
{
	reset_fixture();
	softkbd->show(42);
	t.assertseq(read_fixture(), "",
		"unknown mode does not write to consctl");
}

testSetRectFormatsFourInts(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(10, 20, 300, 40);
	t.assertseq(read_fixture(), "kbd rect 10 20 300 40",
		"four-int form matches devcons sscanf");
}

testSetRectLargeCoords(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(0, 800, 1170, 56);
	t.assertseq(read_fixture(), "kbd rect 0 800 1170 56",
		"phone-resolution coords still fit");
}

testSetRectNegativeOriginAllowed(t: ref T)
{
	# Off-screen origins are legitimate during a layout transition;
	# devcons clamps inside the C path. softkbd must pass them through.
	reset_fixture();
	softkbd->set_rect(-10, -5, 320, 60);
	t.assertseq(read_fixture(), "kbd rect -10 -5 320 60",
		"negative origin passes through");
}

testSetRectZeroWidthClears(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(10, 20, 0, 40);
	t.assertseq(read_fixture(), "kbd rect 0 0 0 0",
		"zero width emits canonical clear");
}

testSetRectZeroHeightClears(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(10, 20, 300, 0);
	t.assertseq(read_fixture(), "kbd rect 0 0 0 0",
		"zero height emits canonical clear");
}

testSetRectNegativeWidthClears(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(10, 20, -1, 40);
	t.assertseq(read_fixture(), "kbd rect 0 0 0 0",
		"negative width emits canonical clear");
}

testClearRect(t: ref T)
{
	reset_fixture();
	softkbd->clear_rect();
	t.assertseq(read_fixture(), "kbd rect 0 0 0 0",
		"clear_rect emits canonical clear");
}

# Ensure each verb is a single write — devcons parses one buffer per
# write() call. If we ever accidentally split the verb, devcons would
# only see the first half. Read fixture and assert no trailing junk.
testNoTrailingJunk(t: ref T)
{
	reset_fixture();
	softkbd->set_rect(1, 2, 3, 4);
	got := read_fixture();
	t.asserteq(len got, len "kbd rect 1 2 3 4",
		"no trailing bytes after the four-int form");
}

# Integration: drive the real /dev/consctl directly with the verbs the
# wrapper would emit. devcons.c parses them; on a headless o.emu the
# rect setter is the stub (USED-only no-op), but the *parse path* still
# runs — this guards the inline int scanner in devcons.c against
# regressions (off-by-one, parse-then-crash on -ve, NUL terminator).
# Anything that would crash the parser would crash the test process.
testRealConsctlAcceptsVerbs(t: ref T)
{
	fd := sys->open("/dev/consctl", Sys->OWRITE);
	if(fd == nil) {
		t.log("/dev/consctl unavailable on this build — skipping");
		t.skipped = 1;
		raise "fail:skip";
	}
	verbs := array[] of {
		"kbd off",
		"kbd on",
		"kbd ontop",
		"kbd rect 10 20 300 40",
		"kbd rect 0 0 0 0",
		"kbd rect -5 -10 320 60",
		"kbd rect 0 800 1170 56",
		# malformed — devcons must accept the prefix and zero
		# the rect rather than walk off the buffer.
		"kbd rect 10 20 300",
		"kbd rect",
		"kbd rect abc def ghi jkl",
	};
	for(i := 0; i < len verbs; i++) {
		b := array of byte verbs[i];
		n := sys->write(fd, b, len b);
		t.assert(n >= 0,
			"write " + verbs[i] + " returns >= 0");
	}
}

setpath()
{
	# Write fixture path into /env/SOFTKBD_PATH so softkbd->init()
	# picks it up.
	fd := sys->create("/env/SOFTKBD_PATH", Sys->OWRITE, 8r600);
	if(fd == nil) {
		sys->fprint(sys->fildes(2),
			"cannot set /env/SOFTKBD_PATH: %r\n");
		raise "fail:env";
	}
	b := array of byte FIXTURE;
	sys->write(fd, b, len b);
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

	setpath();

	softkbd = load Softkbd Softkbd->PATH;
	if(softkbd == nil) {
		sys->fprint(sys->fildes(2),
			"cannot load Softkbd %s: %r\n", Softkbd->PATH);
		raise "fail:cannot load softkbd";
	}
	if((err := softkbd->init()) != nil) {
		sys->fprint(sys->fildes(2), "softkbd init failed: %s\n", err);
		raise "fail:init";
	}

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("ShowSlide", testShowSlide);
	run("ShowKeeptop", testShowKeeptop);
	run("ShowHide", testShowHide);
	run("ShowUnknownIgnored", testShowUnknownIgnored);
	run("SetRectFormatsFourInts", testSetRectFormatsFourInts);
	run("SetRectLargeCoords", testSetRectLargeCoords);
	run("SetRectNegativeOriginAllowed", testSetRectNegativeOriginAllowed);
	run("SetRectZeroWidthClears", testSetRectZeroWidthClears);
	run("SetRectZeroHeightClears", testSetRectZeroHeightClears);
	run("SetRectNegativeWidthClears", testSetRectNegativeWidthClears);
	run("ClearRect", testClearRect);
	run("NoTrailingJunk", testNoTrailingJunk);
	run("RealConsctlAcceptsVerbs", testRealConsctlAcceptsVerbs);

	# Clean up so a re-run doesn't see stale state.
	sys->remove(FIXTURE);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
