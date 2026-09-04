implement JITBug2;

include "sys.m";
	sys: Sys;
include "draw.m";

JITBug2: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	sys->print("=== CVTLW / MOVL Bug Investigation ===\n\n");

	# Test 1: Simple big variable assignment and conversion
	sys->print("--- Test 1: Sequential big assignments ---\n");
	a := big 100;
	sys->print("a = %bd (expect 100)\n", a);
	a = big 200;
	sys->print("a = %bd (expect 200)\n", a);
	a = big -1;
	sys->print("a = %bd (expect -1)\n", a);
	a = big -42;
	sys->print("a = %bd (expect -42)\n", a);

	# Test 2: Different big variables
	sys->print("\n--- Test 2: Separate big variables ---\n");
	b1 := big 111;
	b2 := big 222;
	b3 := big -333;
	b4 := big -444;
	sys->print("b1 = %bd (expect 111)\n", b1);
	sys->print("b2 = %bd (expect 222)\n", b2);
	sys->print("b3 = %bd (expect -333)\n", b3);
	sys->print("b4 = %bd (expect -444)\n", b4);

	# Test 3: int(big) conversions
	sys->print("\n--- Test 3: int(big) conversions ---\n");
	sys->print("int b1 = %d (expect 111)\n", int b1);
	sys->print("int b2 = %d (expect 222)\n", int b2);
	sys->print("int b3 = %d (expect -333)\n", int b3);
	sys->print("int b4 = %d (expect -444)\n", int b4);

	# Test 4: big(int) then int(big) round-trip
	sys->print("\n--- Test 4: Round-trip conversions ---\n");
	for (i := -5; i <= 5; i++) {
		bv := big i;
		iv := int bv;
		status := "OK";
		if (iv != i)
			status = "FAIL";
		sys->print("  %d -> big -> int = %d [%s]\n", i, iv, status);
	}

	# Test 5: big assignment from expression
	sys->print("\n--- Test 5: Big from expression ---\n");
	x := big 10;
	y := big 20;
	z := x + y;
	sys->print("10 + 20 = %bd (expect 30)\n", z);
	z = x - y;
	sys->print("10 - 20 = %bd (expect -10)\n", z);
	sys->print("int(10-20) = %d (expect -10)\n", int z);

	# Test 6: big copy
	sys->print("\n--- Test 6: Big copy ---\n");
	src := big 99999;
	dst := src;
	sys->print("src = %bd, dst = %bd (both expect 99999)\n", src, dst);
	src = big -99999;
	dst = src;
	sys->print("src = %bd, dst = %bd (both expect -99999)\n", src, dst);
}
