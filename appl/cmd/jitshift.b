implement JITShift;

include "sys.m";
	sys: Sys;
include "draw.m";

JITShift: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	sys->print("=== Big Shift Debug ===\n");

	# Test basic big values
	a := big 1;
	sys->print("big 1 = %bd\n", a);

	b := a << 32;
	sys->print("big 1 << 32 = %bd\n", b);

	c := b >> 32;
	sys->print("(big 1 << 32) >> 32 = %bd\n", c);

	# Direct constant
	d := big 4294967296;
	sys->print("big 4294967296 = %bd\n", d);

	e := d >> 32;
	sys->print("big 4294967296 >> 32 = %bd\n", e);

	# Smaller shifts
	sys->print("\nbig 256 >> 4 = %bd\n", big 256 >> 4);
	sys->print("big 256 >> 8 = %bd\n", big 256 >> 8);

	# Shift within 32-bit range
	f := big 16r80000000;
	sys->print("big 16r80000000 = %bd\n", f);
	sys->print("big 16r80000000 >> 1 = %bd\n", f >> 1);
	sys->print("big 16r80000000 >> 31 = %bd\n", f >> 31);

	# Cross-word boundary
	g := big 16r100000000;
	sys->print("\nbig 16r100000000 = %bd\n", g);
	sys->print("big 16r100000000 >> 1 = %bd\n", g >> 1);
	sys->print("big 16r100000000 >> 16 = %bd\n", g >> 16);
	sys->print("big 16r100000000 >> 31 = %bd\n", g >> 31);
	sys->print("big 16r100000000 >> 32 = %bd\n", g >> 32);
	sys->print("big 16r100000000 >> 33 = %bd\n", g >> 33);
}
