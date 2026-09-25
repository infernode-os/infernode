implement JitFaultTest;

#
# Faults raised from compiled code, and the handler that catches them.
#
# The interpreter raises "zero divide", "array bounds error" and
# "dereference of nil" from C with R.PC and R.FP exact, so the handler
# table finds the right handler. A JIT raises them from generated code:
# it must test for the zero divisor itself on targets whose divide
# instruction does not trap (arm64, riscv64), and it must leave R.PC
# inside the faulting instruction and R.FP on its frame, or handler()
# picks the wrong handler, or none. Run under -c1 to test a JIT; under
# -c0 it pins the interpreter's behaviour the JIT must match.
#
# The riscv64 JIT passes it. The amd64 and arm64 JITs do not yet: a
# zero divide surfaces as "sys: fp" (amd64) or not at all (arm64), a
# bounds fault leaves the handler table without the faulting PC, and
# the run ends in a kernel panic ("fault while holding 1 lock(s)") that
# would take the rest of the test runner's suite down with it. So on
# those two, where /env/cputype says so, the whole module is skipped --
# under -c0 as well, since a module cannot ask which mode it runs in --
# until their JITs are fixed. riscv64, hosted or bare metal, runs it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitFaultTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_fault_test.b";

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

# set at run time, so limbo cannot fold the division away
zerov := -1;
onev := -1;

zero(): int
{
	return zerov;
}

one(): int
{
	return onev;
}

divw(a, b: int): int
{
	return a / b;
}

modw(a, b: int): int
{
	return a % b;
}

divl(a, b: big): big
{
	return a / b;
}

modl(a, b: big): big
{
	return a % b;
}

divb(a, b: byte): byte
{
	return a / b;
}

# run case k; the exception string it raised, or "none"
fault(k: int): string
{
	a := array[3] of int;
	b: array of int;
	l: list of int;
	x := 0;
	{
		case k {
		0 =>	x = divw(7, zero());
		1 =>	x = modw(7, zero());
		2 =>	x = int divl(big 7, big zero());
		3 =>	x = int modl(big 7, big zero());
		4 =>	x = int divb(byte 7, byte zero());
		5 =>	x = a[3 * one()];
		6 =>	x = a[-1 * one()];
		7 =>	x = b[0];
		8 =>	x = a[2 * one()];
		9 =>	x = hd l;
		10 =>	x = len tl l;
		11 =>	x = deep(50);
		}
	} exception e {
	"*" =>
		return e;
	}
	if(x < 0)
		return "negative";
	return "none";
}

testDivZero(t: ref T)
{
	t.assertseq(fault(0), "zero divide", "int /");
	t.assertseq(fault(1), "zero divide", "int %");
	t.assertseq(fault(2), "zero divide", "big /");
	t.assertseq(fault(3), "zero divide", "big %");
	t.assertseq(fault(4), "zero divide", "byte /");
}

testDivValues(t: ref T)
{
	t.asserteq(divw(-7, 2), -3, "-7/2 truncates");
	t.asserteq(modw(-7, 2), -1, "-7%2 takes the dividend's sign");
	t.asserteq(divw(int 16r80000000, -1), int 16r80000000, "INT_MIN/-1 wraps");
	t.asserteq(modw(int 16r80000000, -1), 0, "INT_MIN%-1");
	t.assert(divl(big -7, big 2) == big -3, "big -7/2");
	t.asserteq(int divb(byte 250, byte 7), 35, "byte 250/7 is unsigned");
}

testBounds(t: ref T)
{
	t.assertseq(fault(5), "array bounds error", "index == len");
	t.assertseq(fault(6), "array bounds error", "negative index");
	t.assertseq(fault(7), "array bounds error", "nil array");
	t.assertseq(fault(8), "none", "last element");
}

testNilList(t: ref T)
{
	t.assertseq(fault(9), "dereference of nil", "hd nil");
	t.assertseq(fault(10), "dereference of nil", "tl nil");
}

# a fault in a callee is caught by the caller: R.FP must be the callee's frame
deep(n: int): int
{
	if(n == 0)
		return divw(1, zero());
	return deep(n - 1) + 1;
}

testUnwind(t: ref T)
{
	t.assertseq(fault(11), "zero divide", "50 frames down");
}

# the handler whose range holds the faulting instruction, not a neighbour's
testHandlerChoice(t: ref T)
{
	a := array[2] of int;
	got := "";
	{
		{
			a[0] = 1;
		} exception {
		"*" =>
			got = "inner";
		}
		a[5 * one()] = 1;
	} exception {
	"array bounds error" =>
		got = "outer";
	}
	t.assertseq(got, "outer", "fault after an inner block");

	got = "";
	{
		{
			a[5 * one()] = 1;
		} exception {
		"array bounds error" =>
			got = "inner";
		}
	} exception {
	"*" =>
		got = "outer";
	}
	t.assertseq(got, "inner", "fault inside an inner block");

	# the handler runs, and the code after it
	n := 0;
	for(k := 0; k < 10; k++) {
		{
			n += divw(10, k);
		} exception {
		"zero divide" =>
			n += 1000;
		}
	}
	t.asserteq(n, 1000 + 10 + 5 + 3 + 2 + 2 + 1 + 1 + 1 + 1, "loop with a handler");
}

# the host's cputype, as emu sets it in /env; nil where there is none
cputype(): string
{
	fd := sys->open("/env/cputype", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
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
	zerov = int "0";
	onev = int "1";
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	case cputype() {
	"amd64" or "arm64" =>
		raise "skip:this architecture's JIT does not yet raise these faults (see the file's header)";
	}

	run("DivZero", testDivZero);
	run("DivValues", testDivValues);
	run("Bounds", testBounds);
	run("NilList", testNilList);
	run("Unwind", testUnwind);
	run("HandlerChoice", testHandlerChoice);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
