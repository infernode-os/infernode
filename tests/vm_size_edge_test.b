implement VmSizeEdgeTest;

#
# Sizes and counts a Limbo program gives the Dis VM (libinterp, libmp):
#  - a channel's buffer: chan[n] of T made an array of n elements whose
#    size in bytes was n times the element's, in an int.
#    chan[16r20000000] of big is 2^32 bytes, which wrapped to none: the
#    array said it had 2^29 elements and had no storage, and each send
#    stored its value further up the heap
#  - IPint.shl and shr: the count was added to the number's bits in an
#    int. Near the largest int the sum wrapped, no room was made and the
#    digits were stored far past the number's block; the most negative
#    int sent the two shifts calling each other without end; a count
#    merely large asked for more memory than there is, which the library
#    answered by ending the emulator
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
	IPint: import keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

VmSizeEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/vm_size_edge_test.b";

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

# what making a channel of n bigs does: "" if it was made
mkbig(n: int): string
{
	{
		c := chan[n] of big;
		c = nil;
		return "";
	} exception e {
	"*" =>
		return e;
	}
}

mkbyte(n: int): string
{
	{
		c := chan[n] of byte;
		c = nil;
		return "";
	} exception e {
	"*" =>
		return e;
	}
}

testChannelBuffer(t: ref T)
{
	# sizes whose bytes wrap an int, or pass it
	sizes := array[] of {16r20000000, 16r20000001, 16r40000000, 16r10000000, 16r7FFFFFFF, 16r1FFFFFFF};
	for(i := 0; i < len sizes; i++){
		e := mkbig(sizes[i]);
		t.assert(e != "", sys->sprint("chan[%#ux] of big is refused: %q", sizes[i], e));
	}
	e := mkbyte(16r7FFFFFFF);
	t.assert(e != "", sys->sprint("chan[16r7FFFFFFF] of byte is refused: %q", e));
	e = mkbig(-1);
	t.assert(e != "", sys->sprint("chan[-1] of big is refused: %q", e));

	# and buffered channels still work
	c := chan[4] of big;
	for(i = 0; i < 4; i++)
		c <-= big i * big 16r100000000;
	sum := big 0;
	for(i = 0; i < 4; i++)
		sum += <-c;
	t.assert(sum == big 6 * big 16r100000000, "a channel with a buffer of four carries four values");
	t.assertseq(mkbig(1000), "", "a buffer of a thousand is made");
}

shl(x: ref IPint, n: int): (ref IPint, string)
{
	{
		return (x.shl(n), "");
	} exception e {
	"*" =>
		return (nil, e);
	}
}

shr(x: ref IPint, n: int): (ref IPint, string)
{
	{
		return (x.shr(n), "");
	} exception e {
	"*" =>
		return (nil, e);
	}
}

testShifts(t: ref T)
{
	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		t.skip(sys->sprint("no Keyring: %r"));
	one := IPint.inttoip(1);
	big3 := IPint.strtoip("123456789abcdef0123456789abcdef0123456789abcdef", 16);
	zero := IPint.inttoip(0);
	MININT: con int 16r80000000;
	MAXINT: con 16r7FFFFFFF;

	# left by far too much: refused, each way of saying it
	(r, e) := shl(one, MAXINT);
	t.assert(r == nil && e != "", "1 shifted left by the largest int is refused: " + e);
	(r, e) = shl(big3, MAXINT - 100);
	t.assert(r == nil && e != "", "and a number of 188 bits by nearly that: " + e);
	(r, e) = shl(one, 16r40000000);
	t.assert(r == nil && e != "", "and by 2^30: " + e);
	(r, e) = shr(one, MININT);
	t.assert(r == nil && e != "", "a right shift by the most negative int is refused: " + e);
	(r, e) = shr(one, -MAXINT);
	t.assert(r == nil && e != "", "and by minus the largest: " + e);

	# right by far too much, or left by a negative: nothing left
	(r, e) = shr(big3, MAXINT);
	t.assert(r != nil && r.eq(zero), "a right shift by the largest int leaves nothing: " + e);
	(r, e) = shl(big3, MININT);
	t.assert(r != nil && r.eq(zero), "a left shift by the most negative int leaves nothing: " + e);
	(r, e) = shl(big3, -MAXINT);
	t.assert(r != nil && r.eq(zero), "and by minus the largest: " + e);

	# and shifts still shift
	(r, e) = shl(one, 200);
	t.assert(r != nil && r.bits() == 201, "1 shifted left by 200 has 201 bits: " + e);
	(r, e) = shr(r, 200);
	t.assert(r != nil && r.eq(one), "and back by 200 is 1");
	(r, e) = shl(big3, -4);
	t.assert(r != nil && r.eq(big3.shr(4)), "a left shift by -4 is a right shift by 4");
	(r, e) = shr(big3, -4);
	t.assert(r != nil && r.eq(big3.shl(4)), "a right shift by -4 is a left shift by 4");
	(r, e) = shl(one, 1<<20);
	t.assert(r != nil && r.bits() == (1<<20)+1, "1 shifted left by 2^20 is made: " + e);
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

	run("ChannelBuffer", testChannelBuffer);
	run("Shifts", testShifts);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
