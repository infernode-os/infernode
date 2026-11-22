implement GefsHashTest;

#
# gefs's hashes, against values pinned when the Limbo was checked
# against 9front's hash.c: MetroHash64 with gefs's seed, over every
# tail length the algorithm treats differently (it reads 32, 16, 8, 4,
# 2 and 1 bytes at a time), and the 32-bit integer hash. Every block
# pointer on a gefs disk carries the first, so a change here makes
# every disk unreadable, 9front's included. 9front's C sign-extends its
# 16- and 8-bit tail products through int, and so must this.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

GefsHashTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

include "../appl/cmd/disk/gefs/dat.b";
include "../appl/cmd/disk/gefs/hash.b";

SRCFILE: con "/tests/gefs_hash_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" or "fail:skip" =>
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

testMetro(t: ref T)
{
	buf := array[16384] of byte;
	for(i := 0; i < len buf; i++)
		buf[i] = byte (i*131+7);
	want := array[] of {
		(0, "35d244c2ba0d952f"), (1, "354ee7a9e41d5801"), (2, "44aabe4860c7dd40"),
		(3, "a07a8ab86a83ce77"), (4, "75c92c2b7cc69cf2"), (5, "a8595d561e18b1f6"),
		(7, "4de78a78b3cdd816"), (8, "f446d1763c795bd9"), (9, "ee299eb9ae6b7ed0"),
		(15, "450a07789d0a2437"), (16, "4b7f8ecc3b621909"), (17, "b92437c72bb24faf"),
		(31, "8361a6e65a10a550"), (32, "09cb6dc9618bb366"), (33, "85b8b0bba5a1541d"),
		(63, "2db29cffab371e69"), (64, "b6490198ae27d5fa"), (100, "52a538cef4bf1648"),
		(1000, "36bc5650fa1d2041"), (16384, "941e707f6493ac5a"),
	};
	for(j := 0; j < len want; j++){
		(n, h) := want[j];
		t.assertseq(sys->sprint("%16.16bux", metrohash64(buf, n, 16r6765)), h,
			sys->sprint("metrohash64 of %d bytes", n));
	}
}

testIhash(t: ref T)
{
	t.assertseq(sys->sprint("%8.8ux", ihash(big 12345)), "4265dd51", "ihash 12345");
	t.assertseq(sys->sprint("%8.8ux", ihash(big 16rdeadbeefcafe)), "c1c5d651", "ihash deadbeefcafe");
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
	run("MetroHash64", testMetro);
	run("Ihash", testIhash);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
