implement PrintEdgeTest;

#
# Sys print formats a program writes (libinterp/runt.c's xprint).
#
# A conversion is copied, flags and digits and verb, into 32 bytes on
# the C stack before it is given to the formatter. The compiler lets a
# conversion have any number of digits, and they were copied as they
# came: sys->sprint("%0000...0d", 1) with forty zeros, a constant format
# in an ordinary program, wrote past the buffer (the emulator ended:
# "stack smashing detected"). Flags and digits past what any conversion
# needs are now left out.
#
# And %H, a debugging format, printed the address of the value's type:
# where the emulator is in memory, told to any program.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

PrintEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/print_edge_test.b";

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

testLongConversions(t: ref T)
{
	# what fits: unchanged
	t.assertseq(sys->sprint("%5d|%-5d|%05d|%.3d", 42, 42, 42, 42), "   42|42   |00042|042", "ordinary widths");
	t.assertseq(sys->sprint("%00000000000000000012d", 7), "000000000007", "a width with twenty digits");
	t.assertseq(sys->sprint("%*d|%-*d", 6, 42, 6, 42), "    42|42    ", "a width from an argument");
	t.assertseq(sys->sprint("%10.4f|%bd|%c|%s", 3.14159, big 1 << 40, 16r263A, "x"), "    3.1416|1099511627776|☺|x", "reals, bigs, runes, strings");

	# forty, a hundred and a thousand zeros: the value still comes out
	s := sys->sprint("%0000000000000000000000000000000000000000d", 1);
	t.assertseq(s, "1", "forty zeros before the verb");
	s = sys->sprint("%0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d", 1);
	t.assertseq(s, "1", "a hundred zeros before the verb");
	s = sys->sprint("%0000000000000000000000000000000000000000bd %0000000000000000000000000000000000000000s %0000000000000000000000000000000000000000g", big 9, "str", 1.5);
	t.assertseq(s, "9 str 1.5", "the same before a big, a string and a real");
	a := sys->aprint("%0000000000000000000000000000000000000000x", 255);
	t.assertseq(string a, "ff", "and in aprint");
}

T1: adt { a, b, c: int; };

testH(t: ref T)
{
	x := ref T1(1, 2, 3);
	s := sys->sprint("%H", x);
	(nf, f) := sys->tokenize(s, ".");
	t.asserteq(nf, 2, "%H gives a count and a number: " + s);
	if(nf == 2){
		(n, nil) := (int ("16r" + hd tl f), 0);
		t.assert(n >= 0 && n < 65536, "the number is the type's size, not an address: " + s);
	}
	t.assertseq(sys->sprint("%H", nil), "-1.00000000", "%H of nil");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("H", testH);
	# last: before the fix this one ended the emulator
	run("LongConversions", testLongConversions);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
