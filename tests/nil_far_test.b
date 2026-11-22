implement NilFarTest;

#
# A field far into a nil ref adt (emu/port/dis.c: isnilfault).
#
# Dis's nil is -1, and a field of a ref adt is reached by adding its
# offset to the ref: up to 65535, the most an operand carries.  The Dis VM
# makes no test of its own: the load faults, and the fault is made the
# program's "dereference of nil".  It was, for an address below 512.  A
# field further in than that gave "sys: segmentation violation addr=..."
# in its place, and from compiled code the exception was not caught by
# the handler round the load (R.PC is put right for a nil fault only):
# the program died there, Broken.
#
# The adt here is 65536 bytes, made of adts held by value.  Each access
# is made in a Prog of its own, so that one that dies is one failure.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

NilFarTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/nil_far_test.b";

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

# 128 bytes
A: adt {
	f0, f1, f2, f3, f4, f5, f6, f7:	big;
	f8, f9, f10, f11, f12, f13, f14, f15:	big;
};

# 2048
B: adt {
	a0, a1, a2, a3, a4, a5, a6, a7:	A;
	a8, a9, a10, a11, a12, a13, a14, a15:	A;
};

# 32768
C: adt {
	b0, b1, b2, b3, b4, b5, b6, b7:	B;
	b8, b9, b10, b11, b12, b13, b14, b15:	B;
};

# 65536
D: adt {
	c0, c1:	C;
};

nild(): ref D
{
	return nil;
}

Offsets := array[] of {8, 560, 4800, 65520};

# the field at Offsets[i] of a nil ref, read or written, in a handler
access(i: int, write: int, c: chan of string)
{
	d := nild();
	r := "no exception";
	{
		x := big 0;
		if(write)
			case i {
			0 =>	d.c0.b0.a0.f1 = big 1;
			1 =>	d.c0.b0.a4.f6 = big 1;
			2 =>	d.c0.b2.a5.f8 = big 1;
			3 =>	d.c1.b15.a15.f14 = big 1;
			}
		else
			case i {
			0 =>	x = d.c0.b0.a0.f1;
			1 =>	x = d.c0.b0.a4.f6;
			2 =>	x = d.c0.b2.a5.f8;
			3 =>	x = d.c1.b15.a15.f14;
			}
		r = sys->sprint("no exception (%bd)", x);
	} exception e {
	"*" =>
		r = e;
	}
	c <-= r;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

check(t: ref T, write: int)
{
	what := "read";
	if(write)
		what = "written";
	for(i := 0; i < len Offsets; i++){
		c := chan[1] of string;
		tc := chan[1] of int;
		spawn access(i, write, c);
		spawn timer(tc, 5000);
		r: string;
		alt{
		r = <-c =>
			;
		<-tc =>
			r = "not caught by the handler round it: the Prog went";
		}
		t.assertseq(r, "dereference of nil",
			sys->sprint("a nil ref's field at offset %d %s", Offsets[i], what));
	}
}

testRead(t: ref T)
{
	check(t, 0);
}

testWrite(t: ref T)
{
	check(t, 1);
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

	run("Read", testRead);
	run("Write", testWrite);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
