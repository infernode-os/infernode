implement HidTest;

#
# hid(2): the mouse report descriptor from the HID specification's own
# appendix (1.11, E.10), and a modern one with a report ID, 12-bit axes
# and a wheel, as the Microsoft mice send; each report decoded to the
# boot layout.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "hid.m";
	hid: Hid;
	Report: import hid;
include "testing.m";
	testing: Testing;
	T: import testing;

HidTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/hid_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# HID 1.11 Appendix E.10: three buttons, five bits of padding, X and Y as signed bytes
specmouse := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r02, byte 16rA1, byte 16r01, byte 16r09, byte 16r01,
	byte 16rA1, byte 16r00, byte 16r05, byte 16r09, byte 16r19, byte 16r01, byte 16r29, byte 16r03,
	byte 16r15, byte 16r00, byte 16r25, byte 16r01, byte 16r95, byte 16r03, byte 16r75, byte 16r01,
	byte 16r81, byte 16r02, byte 16r95, byte 16r01, byte 16r75, byte 16r05, byte 16r81, byte 16r01,
	byte 16r05, byte 16r01, byte 16r09, byte 16r30, byte 16r09, byte 16r31, byte 16r15, byte 16r81,
	byte 16r25, byte 16r7F, byte 16r75, byte 16r08, byte 16r95, byte 16r02, byte 16r81, byte 16r06,
	byte 16rC0, byte 16rC0,
};

# report ID 26; five buttons and three bits of padding; X, Y 12 bits
# signed (-2047..2047); wheel a signed byte
modernmouse := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r02, byte 16rA1, byte 16r01, byte 16r85, byte 16r1A,
	byte 16r09, byte 16r01, byte 16rA1, byte 16r00, byte 16r05, byte 16r09, byte 16r19, byte 16r01,
	byte 16r29, byte 16r05, byte 16r15, byte 16r00, byte 16r25, byte 16r01, byte 16r75, byte 16r01,
	byte 16r95, byte 16r05, byte 16r81, byte 16r02, byte 16r75, byte 16r03, byte 16r95, byte 16r01,
	byte 16r81, byte 16r01, byte 16r05, byte 16r01, byte 16r09, byte 16r30, byte 16r09, byte 16r31,
	byte 16r16, byte 16r01, byte 16rF8, byte 16r26, byte 16rFF, byte 16r07, byte 16r75, byte 16r0C,
	byte 16r95, byte 16r02, byte 16r81, byte 16r06, byte 16r09, byte 16r38, byte 16r15, byte 16r81,
	byte 16r25, byte 16r7F, byte 16r75, byte 16r08, byte 16r95, byte 16r01, byte 16r81, byte 16r06,
	byte 16rC0, byte 16rC0,
};

testSpecMouse(t: ref T)
{
	l := hid->parse(specmouse);
	t.asserteq(len l, 1, "one input report");
	if(l == nil)
		return;
	r := hd l;
	t.asserteq(r.id, 0, "with no report ID");
	t.asserteq(r.bits, 24, "three bytes long");
	t.assert(r.buttons != nil && r.buttons.off == 0 && r.buttons.count == 3, "three buttons at bit 0");
	t.assert(r.x != nil && r.x.off == 8 && r.x.size == 8 && r.x.signed, "X a signed byte at bit 8");
	t.assert(r.y != nil && r.y.off == 16 && r.y.size == 8, "Y at bit 16");
	t.assert(r.wheel == nil, "no wheel");
	b := r.mouse(array[] of { byte 16r05, byte 16rFE, byte 16r10 });
	t.asserteq(int b[0], 5, "buttons 1 and 3");
	t.asserteq(int b[1], 16rFE, "dx -2 as a byte");
	t.asserteq(int b[2], 16r10, "dy 16");
	t.asserteq(int b[3], 0, "wheel 0");
}

testModernMouse(t: ref T)
{
	l := hid->parse(modernmouse);
	t.asserteq(len l, 1, "one input report");
	if(l == nil)
		return;
	r := hid->find(l, 26);
	t.assert(r != nil, "found by its ID, 26");
	if(r == nil)
		return;
	t.asserteq(r.bits, 40, "five bytes long");
	t.assert(r.buttons != nil && r.buttons.count == 5, "five buttons");
	t.assert(r.x != nil && r.x.off == 8 && r.x.size == 12 && r.x.signed, "X 12 bits signed at bit 8");
	t.assert(r.y != nil && r.y.off == 20 && r.y.size == 12, "Y 12 bits at bit 20");
	t.assert(r.wheel != nil && r.wheel.off == 32 && r.wheel.size == 8, "wheel a byte at bit 32");
	# button 1; X = -3 (0xFFD); Y = 5; wheel = -1
	data := array[] of { byte 16r01, byte 16rFD, byte 16r5F, byte 16r00, byte 16rFF };
	b := r.mouse(data);
	t.asserteq(int b[0], 1, "button 1");
	t.asserteq(int b[1], 16rFD, "dx -3");
	t.asserteq(int b[2], 5, "dy 5");
	t.asserteq(int b[3], 16rFF, "wheel -1");
	# a big movement is clamped to the boot range
	data = array[] of { byte 0, byte 16r00, byte 16r05, byte 16r00, byte 0 };	# X = 0x500 = 1280
	b = r.mouse(data);
	t.asserteq(int b[1], 127, "dx 1280 clamps to 127");
	t.assert(hid->find(l, 7) == nil, "an unknown ID finds nothing");
}

testJunk(t: ref T)
{
	t.assert(hid->parse(array[] of { byte 16r05 }) == nil, "a truncated item is malformed");
	t.assert(hid->parse(array[0] of byte) == nil, "an empty map has no reports");
	# a keyboard's map has no mouse collection
	kbd := array[] of { byte 16r05, byte 16r01, byte 16r09, byte 16r06, byte 16rA1, byte 16r01,
		byte 16r05, byte 16r07, byte 16r19, byte 16rE0, byte 16r29, byte 16rE7, byte 16r15, byte 16r00,
		byte 16r25, byte 16r01, byte 16r75, byte 16r01, byte 16r95, byte 16r08, byte 16r81, byte 16r02, byte 16rC0 };
	t.assert(hid->parse(kbd) == nil, "a keyboard's map yields no mouse reports");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	hid = load Hid Hid->PATH;
	hid->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("SpecMouse", testSpecMouse);
	run("ModernMouse", testModernMouse);
	run("Junk", testJunk);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
