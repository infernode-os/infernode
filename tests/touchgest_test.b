implement TouchgestTest;

#
# touchgest_test -- a touch screen's fingers as pointer events
# (module/touchgest.m), as the Pi's panel (os/init/touch.b) and a USB
# touchscreen (os/init/mouseusb.b) both give them: a tap, a finger
# held still becoming button 3 and sliding to a menu's item, a drag
# that is no hold, two fingers as the wheel, and the gesture lasting
# until every finger is up.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "touchgest.m";
	touchgest: Touchgest;
	Gest: import touchgest;

TouchgestTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/touchgest_test.b";

passed := 0;
failed := 0;
skipped := 0;

Long: con Touchgest->Longms;
Slop: con 16;
Step: con 40;

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

# the events, joined by blanks
s(l: list of string): string
{
	r := "";
	for(; l != nil; l = tl l){
		if(r != "")
			r += " ";
		r += hd l;
	}
	return r;
}

one: list of (int, int);

testTap(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	t.assertseq(s(g.frame(one, 0)), "m 100 200 1", "a finger lands: button 1");
	t.asserteq(g.due(), Long, "a hold is due Longms after it landed");
	t.assertseq(s(g.frame(nil, 50)), "m 100 200 0", "it lifts: button 1 up");
	t.asserteq(g.due(), -1, "nothing is due with no finger");
	t.assertseq(s(g.tick(5*Long)), "", "and nothing comes of time");
}

testHold(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	g.frame(one, 0);
	t.assertseq(s(g.tick(Long-1)), "", "held, not yet long");
	t.assertseq(s(g.tick(Long)), "m 100 200 4", "held long: button 1 up, button 3 down");
	t.asserteq(g.due(), -1, "nothing more is due");
	t.assertseq(s(g.tick(2*Long)), "", "then nothing more");
	t.assertseq(s(g.frame((100, 260) :: nil, 2*Long)), "m 100 260 4", "sliding to an item, button 3 held");
	t.assertseq(s(g.frame(nil, 2*Long)), "m 100 260 0", "lifting chooses it");
	t.assertseq(s(g.frame(one, 3*Long)), "m 100 200 1", "the next touch is button 1 again");
}

testWobble(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	g.frame(one, 0);
	t.assertseq(s(g.frame((110, 205) :: nil, 100)), "m 110 205 1", "wobbling within the slop");
	t.assertseq(s(g.frame((110, 205) :: nil, Long)), "m 110 205 4", "still a hold, from a frame as from a tick");
}

testDrag(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	g.frame(one, 0);
	t.assertseq(s(g.frame((100, 230) :: nil, 100)), "m 100 230 1", "a drag");
	t.asserteq(g.due(), -1, "a drag is no hold");
	t.assertseq(s(g.tick(5*Long)), "", "not even later");
	t.assertseq(s(g.frame((100, 205) :: nil, 6*Long)), "m 100 205 1", "back near where it landed: still a drag");
}

testTwoFingers(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	g.frame(one, 0);
	t.assertseq(s(g.frame((100, 200) :: (200, 200) :: nil, 30)), "m 100 200 0",
		"a second finger lets button 1 go");
	t.assertseq(s(g.frame((100, 200-Step) :: (200, 200-Step) :: nil, 60)),
		"m 150 160 16 m 150 160 0", "up a step: the wheel's down, where the fingers are");
	t.assertseq(s(g.frame((100, 200+Step) :: (200, 200+Step) :: nil, 90)),
		"m 150 240 8 m 150 240 0 m 150 240 8 m 150 240 0", "down two steps: the wheel's up, twice");
	t.assertseq(s(g.frame((100, 250) :: (200, 250) :: nil, 95)), "", "less than a step: nothing yet");
	t.assertseq(s(g.tick(5*Long)), "", "no hold while scrolling");
	t.assertseq(s(g.frame((100, 300) :: nil, 120)), "", "one finger left: nothing");
	t.assertseq(s(g.tick(10*Long)), "", "nor while it rests");
	t.assertseq(s(g.frame(nil, 150)), "", "all up: nothing to release");
	t.assertseq(s(g.frame(one, 200)), "m 100 200 1", "the next touch is a press");
}

testThirdFinger(t: ref T)
{
	g := Gest.new("m", Slop, Step);
	g.frame((100, 200) :: (200, 200) :: nil, 0);
	t.assertseq(s(g.frame((100, 200) :: (200, 200) :: (300, 400) :: nil, 10)), "",
		"a third finger lands: no tick for the jump");
	t.assertseq(s(g.frame((100, 200) :: (200, 200) :: nil, 20)), "",
		"and lifts: none either");
}

testFractions(t: ref T)
{
	# a USB touchscreen's: fractions of the screen, the verb "a"
	g := Gest.new("a", 1310, 5461);
	t.assertseq(s(g.frame((32768, 16384) :: nil, 0)), "a 32768 16384 1", "a press as a fraction");
	t.assertseq(s(g.frame((33000, 16500) :: nil, 100)), "a 33000 16500 1", "a wobble in fractions");
	t.assertseq(s(g.tick(Long)), "a 33000 16500 4", "held: button 3");
	t.assertseq(s(g.frame(nil, Long+10)), "a 33000 16500 0", "lifted");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	touchgest = load Touchgest Touchgest->PATH;
	if(touchgest == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Touchgest->PATH);
		raise "fail:cannot load touchgest";
	}
	one = (100, 200) :: nil;

	run("Tap", testTap);
	run("Hold", testHold);
	run("Wobble", testWobble);
	run("Drag", testDrag);
	run("TwoFingers", testTwoFingers);
	run("ThirdFinger", testThirdFinger);
	run("Fractions", testFractions);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
