implement ArrayInitTest;

#
# Regression test for Limbo array zero-initialization (INFR-261).
#
# Limbo specifies that `array[n] of T` creates every element with its zero
# value. The Dis allocator hands out recycled heap memory, so without the VM
# explicitly clearing value-type array data, a freshly-allocated array could
# expose stale bytes from a previously-freed object -- a correctness bug (it
# surfaced as a corrupted DES/AES cipher IV) and an information-disclosure
# risk. Fresh arena memory is zero, so the gap only appears once a block is
# reused; these tests force reuse and assert the new arrays are zero.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

ArrayInitTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/arrayinit_test.b";

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

# allocate an array of `n` bytes filled with 0xAA, then drop it, churning the
# heap so the next allocation is likely to reuse this block.
churn(n: int)
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte 16r41;
	a = nil;
}

allzero(a: array of byte): int
{
	for(i := 0; i < len a; i++)
		if(a[i] != byte 0)
			return 0;
	return 1;
}

# After freeing non-zero arrays, a new array of the same size must be zero.
testByteArrayZeroed(t: ref T)
{
	for(i := 0; i < 8; i++)
		churn(8);
	for(i = 0; i < 8; i++)
		churn(16);

	# the IV-shaped case that originally broke (8-byte DES IV)
	iv := array[8] of byte;
	t.assert(allzero(iv), "8-byte array is zero after heap reuse");

	# a few other sizes
	b16 := array[16] of byte;
	t.assert(allzero(b16), "16-byte array is zero after heap reuse");

	b1 := array[1] of byte;
	t.assert(allzero(b1), "1-byte array is zero after heap reuse");
}

# int arrays (value type, no pointers) must also be zeroed.
testIntArrayZeroed(t: ref T)
{
	for(i := 0; i < 16; i++) {
		junk := array[8] of int;
		for(j := 0; j < 8; j++)
			junk[j] = 16r41414141;
		junk = nil;
	}
	a := array[8] of int;
	z := 1;
	for(i = 0; i < len a; i++)
		if(a[i] != 0)
			z = 0;
	t.assert(z, "int array is zero after heap reuse");
}

# a fresh (cold) array is zero too -- the always-worked baseline.
testColdZeroed(t: ref T)
{
	a := array[32] of byte;
	t.assert(allzero(a), "cold array is zero");
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

	run("ColdZeroed", testColdZeroed);
	run("ByteArrayZeroed", testByteArrayZeroed);
	run("IntArrayZeroed", testIntArrayZeroed);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
