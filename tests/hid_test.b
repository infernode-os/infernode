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
	Report, Keys: import hid;
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

# HID 1.11 Appendix B.1, the boot keyboard -- and QEMU's usb-kbd, byte for
# byte: eight modifier bits, a reserved byte, LEDs (an output), six key slots
bootkbd := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r06, byte 16rA1, byte 16r01, byte 16r75, byte 16r01,
	byte 16r95, byte 16r08, byte 16r05, byte 16r07, byte 16r19, byte 16rE0, byte 16r29, byte 16rE7,
	byte 16r15, byte 16r00, byte 16r25, byte 16r01, byte 16r81, byte 16r02, byte 16r95, byte 16r01,
	byte 16r75, byte 16r08, byte 16r81, byte 16r01, byte 16r95, byte 16r05, byte 16r75, byte 16r01,
	byte 16r05, byte 16r08, byte 16r19, byte 16r01, byte 16r29, byte 16r05, byte 16r91, byte 16r02,
	byte 16r95, byte 16r01, byte 16r75, byte 16r03, byte 16r91, byte 16r01, byte 16r95, byte 16r06,
	byte 16r75, byte 16r08, byte 16r15, byte 16r00, byte 16r25, byte 16rFF, byte 16r05, byte 16r07,
	byte 16r19, byte 16r00, byte 16r29, byte 16rFF, byte 16r81, byte 16r00, byte 16rC0,
};

# an n-key-rollover keyboard: report 1 is the modifier bits, a reserved
# byte and a bitmap of usages 0..0x67, one bit each; report 2, in a
# Consumer Control collection of its own, is a 16-bit media key code
nkrokbd := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r06, byte 16rA1, byte 16r01, byte 16r85, byte 16r01,
	byte 16r05, byte 16r07, byte 16r19, byte 16rE0, byte 16r29, byte 16rE7, byte 16r15, byte 16r00,
	byte 16r25, byte 16r01, byte 16r75, byte 16r01, byte 16r95, byte 16r08, byte 16r81, byte 16r02,
	byte 16r95, byte 16r01, byte 16r75, byte 16r08, byte 16r81, byte 16r01, byte 16r19, byte 16r00,
	byte 16r29, byte 16r67, byte 16r95, byte 16r68, byte 16r75, byte 16r01, byte 16r81, byte 16r02,
	byte 16rC0,
	byte 16r05, byte 16r0C, byte 16r09, byte 16r01, byte 16rA1, byte 16r01, byte 16r85, byte 16r02,
	byte 16r19, byte 16r00, byte 16r2A, byte 16r3C, byte 16r02, byte 16r15, byte 16r00, byte 16r26,
	byte 16r3C, byte 16r02, byte 16r75, byte 16r10, byte 16r95, byte 16r01, byte 16r81, byte 16r00,
	byte 16rC0,
};

# report 3: a vendor byte first, then the modifiers, then four key slots
# whose logical range starts at 0 and covers usages 0..0x65
idkbd := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r06, byte 16rA1, byte 16r01, byte 16r85, byte 16r03,
	byte 16r06, byte 16r00, byte 16rFF, byte 16r09, byte 16r01, byte 16r15, byte 16r00, byte 16r26,
	byte 16rFF, byte 16r00, byte 16r75, byte 16r08, byte 16r95, byte 16r01, byte 16r81, byte 16r02,
	byte 16r05, byte 16r07, byte 16r19, byte 16rE0, byte 16r29, byte 16rE7, byte 16r15, byte 16r00,
	byte 16r25, byte 16r01, byte 16r75, byte 16r01, byte 16r95, byte 16r08, byte 16r81, byte 16r02,
	byte 16r19, byte 16r00, byte 16r29, byte 16r65, byte 16r15, byte 16r00, byte 16r25, byte 16r65,
	byte 16r75, byte 16r08, byte 16r95, byte 16r04, byte 16r81, byte 16r00, byte 16rC0,
};

# the usages held, sorted, as a string, for comparing
heldstr(l: list of int): string
{
	a := array[len l] of int;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && a[j-1] > a[j]; j--)
			(a[j-1], a[j]) = (a[j], a[j-1]);
	s := "";
	for(i = 0; i < len a; i++)
		s += sys->sprint(" %.2ux", a[i]);
	return s;
}

testBootKeyboard(t: ref T)
{
	l := hid->keyboard(bootkbd);
	t.asserteq(len l, 1, "one keyboard report");
	if(l == nil)
		return;
	k := hd l;
	t.asserteq(k.id, 0, "with no report ID");
	t.asserteq(k.bits, 64, "eight bytes long; the LED output is not part of it");
	# left shift and right alt; 'a' (4) and 'z' (0x1D) held
	(mod, down) := k.held(array[] of { byte 16r42, byte 0, byte 16r04, byte 16r1D, byte 0, byte 0, byte 0, byte 0 });
	t.asserteq(mod, 16r42, "modifiers in the boot layout");
	t.assertseq(heldstr(down), " 04 1d", "the two keys held, and no empty slot");
	# roll-over: every slot says "too many"
	(mod, down) = k.held(array[] of { byte 0, byte 0, byte 1, byte 1, byte 1, byte 1, byte 1, byte 1 });
	t.assert(down == nil, "roll-over error codes are not keys");
	t.assert(hid->parse(bootkbd) == nil, "and it is still no mouse");
}

testNkroKeyboard(t: ref T)
{
	l := hid->keyboard(nkrokbd);
	t.asserteq(len l, 1, "one keyboard report; the consumer collection is not a keyboard");
	k := hid->findkeys(l, 1);
	t.assert(k != nil, "found by its ID, 1");
	if(k == nil)
		return;
	t.asserteq(k.bits, 8 + 8 + 16r68, "modifiers, reserved byte, 104-bit bitmap");
	# left control; bitmap bits for 'a' (4), 'b' (5), '1' (0x1E) and Enter (0x28), and
	# seven more letters at once -- more than a boot report's six slots can carry
	data := array[2 + 13] of { * => byte 0 };
	data[0] = byte 16r01;
	data[2] = byte 16r30;			# usages 4, 5
	data[2 + 16r1E/8] |= byte (1 << (16r1E % 8));
	data[2 + 16r28/8] |= byte (1 << (16r28 % 8));
	data[2 + 1] |= byte 16rFE;		# usages 9..15
	(mod, down) := k.held(data);
	t.asserteq(mod, 1, "left control");
	t.assertseq(heldstr(down), " 04 05 09 0a 0b 0c 0d 0e 0f 1e 28", "eleven keys at once");
	t.assert(hid->findkeys(l, 2) == nil, "report 2 (media keys) is not a keyboard report");
}

testIdKeyboard(t: ref T)
{
	l := hid->keyboard(idkbd);
	k := hid->findkeys(l, 3);
	t.assert(k != nil, "report 3");
	if(k == nil)
		return;
	t.asserteq(k.bits, 8 + 8 + 32, "vendor byte, modifiers, four slots");
	# vendor byte 0x55 must not read as anything; right shift; Escape (0x29) and 'q' (0x14)
	(mod, down) := k.held(array[] of { byte 16r55, byte 16r20, byte 16r29, byte 0, byte 16r14, byte 0 });
	t.asserteq(mod, 16r20, "right shift");
	t.assertseq(heldstr(down), " 14 29", "Escape and q, the vendor byte ignored");
	t.assert(hid->keyboard(specmouse) == nil, "a mouse's map has no keyboard");
	t.assert(hid->keyboard(array[] of { byte 16r05, byte 16r01, byte 16r09 }) == nil, "a truncated map has none");
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
	run("BootKeyboard", testBootKeyboard);
	run("NkroKeyboard", testNkroKeyboard);
	run("IdKeyboard", testIdKeyboard);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
