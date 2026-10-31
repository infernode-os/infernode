implement JitBoundsTest;

#
# Out-of-range array, string and slice indices raise "array bounds error"
# from compiled code as they do from the interpreter.
#
# The interpreter's index ops compare the index with the length as
# unsigned, so a negative index is out of range like one past the end.
# A JIT must do the same on every index it compiles -- indb, indw, indl,
# indf, indx and indc, with the index in a register or an immediate --
# and the slice ops it punts to the interpreter must still be checked
# there. Charon's OpenType parser once passed an uninitialised
# (negative) offset to an array index: under -c0 that raised the bounds
# error, under -c1 on amd64 the read went through and emu died in a
# segmentation violation, because the JIT compiled the index with no
# check at all (bflag, which gates the check, was never set).
#
# Each case runs with the index computed at run time, so the compiler
# cannot fold it, and once more with the index as a literal, which
# limbo emits as an immediate operand and the JITs compile differently.
# Run under -c1 to test a JIT; under -c0 it pins the interpreter's
# behaviour the JIT must match. tests/host/jit_bounds_test.sh runs both.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitBoundsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_bounds_test.b";

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

Pt: adt {
	x, y: int;
};

# set at run time, so limbo cannot fold the indices away
onev := -1;

one(): int
{
	return onev;
}

# the indices under test, all computed at run time
neg(): int
{
	return -1 * onev;
}

veryneg(): int
{
	return int 16r80000000 * onev;
}

huge(): int
{
	return int 16r7fffffff * onev;
}

BOUNDS: con "array bounds error";

# run case k; the exception string it raised, or "none"
fault(k: int): string
{
	ab := array[4] of byte;
	aw := array[4] of int;
	al := array[4] of big;
	af := array[4] of real;
	ap := array[4] of ref Pt;
	ax := array[4] of Pt;
	as := array[4] of string;
	aa := array[4] of array of int;
	s := "abcd";
	rs := "αβγδ";
	ns: string;
	na: array of int;
	x := 0;
	{
		case k {
		# register index, every element size
		0 =>	x = int ab[neg()];
		1 =>	ab[neg()] = byte 1;
		2 =>	x = aw[neg()];
		3 =>	aw[neg()] = 1;
		4 =>	x = int al[neg()];
		5 =>	al[neg()] = big 1;
		6 =>	x = int af[neg()];
		7 =>	af[neg()] = 1.0;
		8 =>	x = ap[neg()].x;
		9 =>	ap[neg()] = ref Pt(1, 2);
		10 =>	x = ax[neg()].x;
		11 =>	ax[neg()].x = 1;
		12 =>	x = len as[neg()];
		13 =>	as[neg()] = "x";
		14 =>	x = len aa[neg()];
		15 =>	aa[neg()] = array[1] of int;
		# strings
		16 =>	x = s[neg()];
		17 =>	x = rs[neg()];
		18 =>	x = s[4 * one()];
		19 =>	x = rs[4 * one()];
		# the extremes of int
		20 =>	x = int ab[veryneg()];
		21 =>	x = aw[veryneg()];
		22 =>	x = int ab[huge()];
		23 =>	x = aw[huge()];
		24 =>	x = s[veryneg()];
		25 =>	x = s[huge()];
		# one past the end
		26 =>	x = int ab[4 * one()];
		27 =>	x = aw[4 * one()];
		28 =>	x = ax[4 * one()].x;
		# slices
		29 =>	x = len ab[neg():];
		30 =>	x = len ab[0:neg()];
		31 =>	x = len ab[3:2 * one()];
		32 =>	x = len ab[0:5 * one()];
		33 =>	x = len aw[neg():];
		34 =>	x = len ap[neg():];
		35 =>	x = len s[neg():];
		36 =>	x = len s[0:neg()];
		37 =>	x = len s[0:5 * one()];
		38 =>	x = len rs[neg():];
		39 =>	x = len ax[neg():];
		40 =>	x = len aa[0:neg()];
		# immediate index: limbo emits the literal as an operand
		41 =>	x = int ab[-1];
		42 =>	ab[-1] = byte 1;
		43 =>	x = aw[-1];
		44 =>	aw[-1] = 1;
		45 =>	x = int al[-1];
		46 =>	x = int af[-1];
		47 =>	x = ap[-1].x;
		48 =>	x = ax[-1].x;
		49 =>	x = int ab[4];
		50 =>	x = aw[4];
		51 =>	x = ax[4].x;
		52 =>	x = int ab[16r7fffffff];
		53 =>	x = aw[16r7fffffff];
		54 =>	x = int ab[int 16r80000000];
		55 =>	x = int ab[5000];
		56 =>	x = aw[5000];
		57 =>	x = s[-1];
		58 =>	x = s[4];
		# in range: no fault
		60 =>	x = int ab[3 * one()];
		61 =>	x = aw[3 * one()];
		62 =>	x = ax[3 * one()].x;
		63 =>	x = s[3 * one()];
		64 =>	x = rs[3 * one()];
		65 =>	x = len ab[0:4 * one()];
		66 =>	x = len s[4 * one():];
		67 =>	x = int ab[3];
		68 =>	x = aw[3];
		69 =>	x = ax[3].x;
		# nil operands
		70 =>	x = na[0];
		71 =>	x = na[neg()];
		72 =>	x = ns[0];
		73 =>	x = ns[neg()];
		74 =>	x = len na[0:];
		75 =>	x = len ns[0:];
		}
	} exception e {
	"*" =>
		return e;
	}
	if(x < 0)
		return "negative";
	return "none";
}

testNegativeIndex(t: ref T)
{
	t.assertseq(fault(0), BOUNDS, "byte read");
	t.assertseq(fault(1), BOUNDS, "byte write");
	t.assertseq(fault(2), BOUNDS, "int read");
	t.assertseq(fault(3), BOUNDS, "int write");
	t.assertseq(fault(4), BOUNDS, "big read");
	t.assertseq(fault(5), BOUNDS, "big write");
	t.assertseq(fault(6), BOUNDS, "real read");
	t.assertseq(fault(7), BOUNDS, "real write");
	t.assertseq(fault(8), BOUNDS, "ref read");
	t.assertseq(fault(9), BOUNDS, "ref write");
	t.assertseq(fault(10), BOUNDS, "adt read");
	t.assertseq(fault(11), BOUNDS, "adt write");
	t.assertseq(fault(12), BOUNDS, "string element read");
	t.assertseq(fault(13), BOUNDS, "string element write");
	t.assertseq(fault(14), BOUNDS, "array element read");
	t.assertseq(fault(15), BOUNDS, "array element write");
}

testString(t: ref T)
{
	t.assertseq(fault(16), BOUNDS, "negative index");
	t.assertseq(fault(17), BOUNDS, "negative index, rune string");
	t.assertseq(fault(18), BOUNDS, "index == len");
	t.assertseq(fault(19), BOUNDS, "index == len, rune string");
	t.assertseq(fault(24), BOUNDS, "INT_MIN");
	t.assertseq(fault(25), BOUNDS, "INT_MAX");
}

testExtremes(t: ref T)
{
	t.assertseq(fault(20), BOUNDS, "byte INT_MIN");
	t.assertseq(fault(21), BOUNDS, "int INT_MIN");
	t.assertseq(fault(22), BOUNDS, "byte INT_MAX");
	t.assertseq(fault(23), BOUNDS, "int INT_MAX");
	t.assertseq(fault(26), BOUNDS, "byte index == len");
	t.assertseq(fault(27), BOUNDS, "int index == len");
	t.assertseq(fault(28), BOUNDS, "adt index == len");
}

testSlice(t: ref T)
{
	t.assertseq(fault(29), BOUNDS, "byte [-1:]");
	t.assertseq(fault(30), BOUNDS, "byte [0:-1]");
	t.assertseq(fault(31), BOUNDS, "byte [3:2]");
	t.assertseq(fault(32), BOUNDS, "byte [0:len+1]");
	t.assertseq(fault(33), BOUNDS, "int [-1:]");
	t.assertseq(fault(34), BOUNDS, "ref [-1:]");
	t.assertseq(fault(35), BOUNDS, "string [-1:]");
	t.assertseq(fault(36), BOUNDS, "string [0:-1]");
	t.assertseq(fault(37), BOUNDS, "string [0:len+1]");
	t.assertseq(fault(38), BOUNDS, "rune string [-1:]");
	t.assertseq(fault(39), BOUNDS, "adt [-1:]");
	t.assertseq(fault(40), BOUNDS, "array of array [0:-1]");
}

testImmediateIndex(t: ref T)
{
	t.assertseq(fault(41), BOUNDS, "byte [-1]");
	t.assertseq(fault(42), BOUNDS, "byte [-1] write");
	t.assertseq(fault(43), BOUNDS, "int [-1]");
	t.assertseq(fault(44), BOUNDS, "int [-1] write");
	t.assertseq(fault(45), BOUNDS, "big [-1]");
	t.assertseq(fault(46), BOUNDS, "real [-1]");
	t.assertseq(fault(47), BOUNDS, "ref [-1]");
	t.assertseq(fault(48), BOUNDS, "adt [-1]");
	t.assertseq(fault(49), BOUNDS, "byte [len]");
	t.assertseq(fault(50), BOUNDS, "int [len]");
	t.assertseq(fault(51), BOUNDS, "adt [len]");
	t.assertseq(fault(52), BOUNDS, "byte [INT_MAX]");
	t.assertseq(fault(53), BOUNDS, "int [INT_MAX]");
	t.assertseq(fault(54), BOUNDS, "byte [INT_MIN]");
	t.assertseq(fault(55), BOUNDS, "byte [5000]");
	t.assertseq(fault(56), BOUNDS, "int [5000]");
	t.assertseq(fault(57), BOUNDS, "string [-1]");
	t.assertseq(fault(58), BOUNDS, "string [len]");
}

testInRange(t: ref T)
{
	t.assertseq(fault(60), "none", "byte last element");
	t.assertseq(fault(61), "none", "int last element");
	t.assertseq(fault(62), "none", "adt last element");
	t.assertseq(fault(63), "none", "string last element");
	t.assertseq(fault(64), "none", "rune string last element");
	t.assertseq(fault(65), "none", "whole slice");
	t.assertseq(fault(66), "none", "empty string slice at len");
	t.assertseq(fault(67), "none", "byte [3]");
	t.assertseq(fault(68), "none", "int [3]");
	t.assertseq(fault(69), "none", "adt [3]");
}

testNil(t: ref T)
{
	t.assertseq(fault(70), BOUNDS, "nil array [0]");
	t.assertseq(fault(71), BOUNDS, "nil array [-1]");
	t.assertseq(fault(72), "dereference of nil", "nil string [0]");
	t.assertseq(fault(73), "dereference of nil", "nil string [-1]");
	t.assertseq(fault(74), "none", "nil array [0:] is nil");
	t.assertseq(fault(75), "none", "nil string [0:] is nil");
}

# the fault must be caught by the handler around the index, with
# the frame intact: the code after the handler runs with its locals
testHandlerContinues(t: ref T)
{
	a := array[8] of int;
	for(i := 0; i < len a; i++)
		a[i] = i;
	sum := 0;
	faults := 0;
	for(k := -3; k < 11; k++) {
		{
			sum += a[k * one()];
		} exception {
		BOUNDS =>
			faults++;
		}
	}
	t.asserteq(sum, 0 + 1 + 2 + 3 + 4 + 5 + 6 + 7, "sum of the in-range elements");
	t.asserteq(faults, 3 + 3, "one fault per out-of-range index");
	t.asserteq(a[7], 7, "the array is intact");
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
	onev = int "1";
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("NegativeIndex", testNegativeIndex);
	run("String", testString);
	run("Extremes", testExtremes);
	run("Slice", testSlice);
	run("ImmediateIndex", testImmediateIndex);
	run("InRange", testInRange);
	run("Nil", testNil);
	run("HandlerContinues", testHandlerContinues);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
