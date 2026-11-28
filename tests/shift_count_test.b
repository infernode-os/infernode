implement ShiftCountTest;

#
# A shift by its operand's width or more gives the same answer from the
# interpreter and every JIT: the count is taken mod 64 and the value as
# 64 bits, then the result cut to the operand's size, as int shifts
# already did.
#
# Byte and big shifts were C's undefined behaviour in the interpreter
# (int << 33 is a shift by 1 where the compiler masks the count to five
# bits): 200 << 33 was 144 from the interpreter and amd64's JIT, 0 from
# arm64's and riscv64's.  disfuzz found it.  The answers here are made
# with multiplication and division, not shifts, and every count comes
# from an array, so the compiler folds none of it.
# tests/host/shift_count_test.sh runs it under -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

ShiftCountTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/shift_count_test.b";

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

# every count from 0 to 130, through an array the compiler cannot see into
counts: array of int;

# 2 ** n as a big for 0 <= n < 64, made by multiplying
pow2(n: int): big
{
	p := big 1;
	for(i := 0; i < n; i++)
		p *= big 2;
	return p;
}

# what x << n must be, for a value of width bits seen as unsigned:
# (x * 2**(n mod 64)) mod 2**width
want_shl(x: big, n: int, width: int): big
{
	n &= 63;
	if(n >= width)
		return big 0;
	return (x * pow2(n)) % pow2(width);
}

# what x >> n must be for a non-negative x: x / 2**(n mod 64)
want_shr(x: big, n: int): big
{
	n &= 63;
	return x / pow2(n);
}

testByte(t: ref T)
{
	vals := array[] of {byte 0, byte 1, byte 127, byte 128, byte 200, byte 255};
	bad := 0;
	for(i := 0; i < len vals; i++)
		for(j := 0; j < len counts; j++){
			b := vals[i];
			n := counts[j];
			got := big (b << n);
			want := want_shl(big b, n, 8);
			if(got != want && bad++ < 8)
				t.error(sys->sprint("byte %d << %d = %bd, want %bd", int b, n, got, want));
			got = big (b >> n);
			want = want_shr(big b, n);
			if(got != want && bad++ < 8)
				t.error(sys->sprint("byte %d >> %d = %bd, want %bd", int b, n, got, want));
		}
	t.asserteq(bad, 0, "byte shifts by every count");
}

testBig(t: ref T)
{
	vals := array[] of {big 0, big 1, big 16r7FFFFFFF, big 16r123456789ABCDEF};
	bad := 0;
	for(i := 0; i < len vals; i++)
		for(j := 0; j < len counts; j++){
			v := vals[i];
			n := counts[j];
			# left: compare the low 63 bits, which the arithmetic can hold
			got := (v << n) & big 16r7FFFFFFFFFFFFFFF;
			# a big product wraps mod 2**64, as a shift's bits fall off
			want := (v * pow2(n & 63)) & big 16r7FFFFFFFFFFFFFFF;
			if(got != want && bad++ < 8)
				t.error(sys->sprint("big %bd << %d = %bd (low 63 bits), want %bd", v, n, got, want));
			got = v >> n;
			want = want_shr(v, n);
			if(got != want && bad++ < 8)
				t.error(sys->sprint("big %bd >> %d = %bd, want %bd", v, n, got, want));
		}
	t.asserteq(bad, 0, "big shifts by every count");
}

testInt(t: ref T)
{
	# int shifts were already defined this way; kept as they were
	vals := array[] of {0, 1, 200, 16r7FFFFFFF};
	bad := 0;
	for(i := 0; i < len vals; i++)
		for(j := 0; j < len counts; j++){
			x := vals[i];
			n := counts[j];
			got := big (x << n) & big 16rFFFFFFFF;
			want := want_shl(big x, n, 32);
			if(got != want && bad++ < 8)
				t.error(sys->sprint("int %d << %d = %bd (low 32 bits), want %bd", x, n, got, want));
		}
	t.asserteq(bad, 0, "int shifts by every count");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	counts = array[131] of int;
	for(i := 0; i < len counts; i++)
		counts[i] = i;

	run("Byte", testByte);
	run("Big", testBig);
	run("Int", testInt);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
