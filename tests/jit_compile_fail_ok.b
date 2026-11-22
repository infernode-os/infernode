implement JitCompileFailOk;

#
# A small module any JIT compiles, with a frame instruction, a case and
# a goto in it.  tests/host/jit_compile_fail_test.sh makes copies of it
# that a JIT must refuse (tests/host/jit_compile_fail/mkbad.py changes
# an instruction or a table entry in each), and one whose header says
# it must be compiled; tests/jit_compile_fail.b loads them.  The case
# labels are ones mkbad.py can find in the file, and far enough apart
# that limbo makes a case of them (near ones become a goto).
#

JitCompileFailOk: module
{
	f:	fn(a: int): int;
};

fact(n: int): int
{
	if(n <= 1)
		return 1;
	return n * fact(n-1);
}

f(a: int): int
{
	r := 0;
	case a {
	1000001 =>
		r = 11;
	2000003 =>
		r = 13;
	3000005 to 3000009 =>
		r = 15;
	* =>
		r = fact(a);
	}
	c := chan[1] of int;
	d := chan[1] of int;
	if(a & 1)
		c <-= a;
	else
		d <-= a;
	alt{
	v := <-c =>
		r += v;
	v := <-d =>
		r -= v;
	}
	return r;
}
