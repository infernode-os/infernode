implement Jittest;

#
# The module the JIT boots run.  It is compiled twice -- once by the
# interpreter (interptest) and once to native code (jittest) -- and the
# harness requires the same lines from both, which is the only honest
# test of a code generator: the same program, the same answers.
#
# What it touches, in the order it touches it: integer arithmetic in a
# loop, REALs and their formatting, a string and an array (heap types),
# a case, recursion (frames and calls), an exception (the error
# machinery, which punts rather than compiles), and a spawn with a
# channel (a second Prog in the same VM).
#

include "sys.m";
	sys: Sys;

include "draw.m";

Jittest: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

add(a, b: int): int
{
	return a + b;
}

fact(n: int): int
{
	if(n <= 1)
		return 1;
	return n * fact(n - 1);
}

worker(ch: chan of int)
{
	ch <-= 3 + 4;
}

halt()
{
	fd := sys->open("#c/sysctl", Sys->OWRITE);
	if(fd != nil){
		b := array of byte "halt\n";
		sys->write(fd, b, len b);
	}
}

fail(msg: string)
{
	sys->print("jittest failed: %s\n", msg);
	halt();
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	if(add(40, 2) != 42)
		fail("add");

	sum := 0;
	for(i := 0; i < 1000; i++)
		sum += i;
	if(sum != 499500)
		fail("loop");
	sys->print("jittest: sum=%d\n", sum);

	x := 1.5;
	y := 2.0;
	if(x*y != 3.0 || x+y != 3.5)
		fail("real");
	sys->print("jittest: real=%g\n", x*y);

	s := "kernel";
	a := array[8] of { 1, 2, 3, 4, 5, 6, 7, 8 };
	if(len s != 6 || s[5] != 'l' || a[7] != 8)
		fail("string/array");

	r := 0;
	case 3 {
	1 =>	r = 1;
	3 =>	r = 3;
	* =>	r = 9;
	}
	if(r != 3)
		fail("case");

	if(fact(6) != 720)
		fail("fact");
	sys->print("jittest: fact=%d\n", fact(6));

	{
		raise "fail:deliberate";
	} exception e {
	"fail:*" =>
		sys->print("jittest: caught %s\n", e);
	}

	ch := chan of int;
	spawn worker(ch);
	if(<-ch != 7)
		fail("spawn");
	sys->print("jittest: spawn=7\n");

	sys->print("jittest passed\n");
	halt();
}
