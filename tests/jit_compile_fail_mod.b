implement JitCompileFailMod;

#
# A module the amd64 JIT gives up on after it has generated the code:
# huge()'s frame holds 131072 strings, and the code that would initialize
# and free such a frame is more than the JIT's allocator for type code
# hands out.  The module is then interpreted, and its case and goto
# tables have to be what limbo wrote: run() goes through one of each
# kind.  tests/jit_compile_fail.b loads it (tests/host/
# jit_compile_fail_test.sh); where a JIT compiles it, run() is the same.
#

JitCompileFailMod: module
{
	run:	fn(): string;
};

A: adt {
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15: string;
};
B: adt {
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15: A;
};
C: adt {
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15: B;
};
D: adt {
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15: C;
};
E: adt {
	f0, f1: D;
};

huge(n: int): int
{
	x: E;
	x.f0.f0.f0.f0.f0 = "x";
	return n + len x.f0.f0.f0.f0.f0;
}

seli(v: int): string
{
	case v {
	1 =>
		return "one";
	2 =>
		return "two";
	10 to 20 =>
		return "teens";
	* =>
		return "other";
	}
}

sels(s: string): string
{
	case s {
	"ant" =>
		return "ant";
	"bee" to "cow" =>
		return "b-c";
	"eel" or "fox" or "gnu" =>
		return "e-g";
	* =>
		return "none";
	}
}

selb(v: big): string
{
	case v {
	big 1 =>
		return "one";
	big 16r123456789 =>
		return "4G";
	big -5 =>
		return "minus";
	* =>
		return "other";
	}
}

sela(which: int): string
{
	a := chan[1] of int;
	b := chan[1] of int;
	c := chan[1] of int;
	if(which == 0)
		a <-= 1;
	else if(which == 1)
		b <-= 1;
	else
		c <-= 1;
	alt{
	<-a =>
		return "a";
	<-b =>
		return "b";
	<-c =>
		return "c";
	}
}

run(): string
{
	r := seli(1) + " " + seli(2) + " " + seli(15) + " " + seli(99);
	if(seli(3) == "three")
		r += string huge(1);
	r += " / " + sels("ant") + " " + sels("cat") + " " + sels("fox") + " " + sels("zebra");
	r += " / " + selb(big 1) + " " + selb(big 16r123456789) + " " + selb(big -5) + " " + selb(big 7);
	r += " / " + sela(0) + " " + sela(1) + " " + sela(2);
	return r;
}
