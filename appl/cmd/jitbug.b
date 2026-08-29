implement JITBug;

include "sys.m";
	sys: Sys;
include "draw.m";

JITBug: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	sys->print("=== JIT Bug Investigation ===\n\n");

	# Bug 1: Big right shift
	sys->print("--- Bug 1: Big Right Shift ---\n");
	a := big 16r100000000;   # 2^32 = 4294967296
	sys->print("a = big 16r100000000 = %bd\n", a);
	b := a >> 32;
	sys->print("a >> 32 = %bd (expected 1)\n", b);
	c := a >> 16;
	sys->print("a >> 16 = %bd (expected 65536)\n", c);
	d := a >> 1;
	sys->print("a >> 1 = %bd (expected 2147483648)\n", d);

	# More shift tests
	e := big 16rFFFFFFFF00000000;
	sys->print("\ne = big 16rFFFFFFFF00000000 = %bd\n", e);
	f := e >> 32;
	sys->print("e >> 32 = %bd (expected 4294967295)\n", f);
	g := e >> 16;
	sys->print("e >> 16 = %bd\n", g);

	# Left shift for comparison
	h := big 1 << 32;
	sys->print("\nbig 1 << 32 = %bd (expected 4294967296)\n", h);
	i := big 1 << 16;
	sys->print("big 1 << 16 = %bd (expected 65536)\n", i);

	# Bug 2: CVTLW (big -> int) with negative values
	sys->print("\n--- Bug 2: CVTLW (big->int) negative ---\n");
	bl := big -12345;
	sys->print("big -12345 = %bd\n", bl);
	iv := int bl;
	sys->print("int big(-12345) = %d (expected -12345)\n", iv);

	bl2 := big -1;
	sys->print("int big(-1) = %d (expected -1)\n", int bl2);
	bl3 := big -42;
	sys->print("int big(-42) = %d (expected -42)\n", int bl3);

	# Positive big -> int
	bl4 := big 12345;
	sys->print("int big(12345) = %d (expected 12345)\n", int bl4);
	bl5 := big 0;
	sys->print("int big(0) = %d (expected 0)\n", int bl5);

	# Check big storage
	sys->print("\n--- Big storage layout ---\n");
	x := big 16r0000000100000002;
	sys->print("big 16r0000000100000002 = %bd\n", x);
	xint := int x;
	sys->print("int(above) = %d (expected 4294967298 or truncated)\n", xint);

	# Negative big storage
	y := big -1;
	sys->print("big -1 = %bd (hex should be FFFFFFFFFFFFFFFF)\n", y);
	yint := int y;
	sys->print("int big(-1) = %d (expected -1)\n", yint);
}
