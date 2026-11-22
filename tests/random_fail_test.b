implement RandomFailTest;

#
# random(2): bytes that are random, or an exception.
#
# randombuf gave an array of zeros when its device could not be opened,
# and left zeros where a read came back short or failed; randomint gave
# 0.  Neither said so, and a salt, a nonce or a blinding pad of zeros
# was used like any other (signer's pad, the second factor's slot key,
# WPA's nonce).  Both raise now, naming the device.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	random: Random;
include "testing.m";
	testing: Testing;
	T: import testing;

RandomFailTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/random_fail_test.b";

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

# what a call does: "raised: text", or "returned" with what it gave
buf(which, n: int): string
{
	{
		b := random->randombuf(which, n);
		if(b == nil)
			return "returned nil";
		z := 1;
		for(i := 0; i < len b; i++)
			if(b[i] != byte 0)
				z = 0;
		if(z && n > 0)
			return sys->sprint("returned %d zeros", len b);
		return sys->sprint("returned %d bytes", len b);
	} exception e {
	"random:*" =>
		return "raised: " + e;
	}
}

rint(which: int): string
{
	{
		return sys->sprint("returned %d", random->randomint(which));
	} exception e {
	"random:*" =>
		return "raised: " + e;
	}
}

israised(s: string): int
{
	return len s > 8 && s[0:8] == "raised: ";
}

# the devices read as empty files: a read of no bytes
empty(c: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("/dev/null", "/dev/random", Sys->MREPL) < 0 ||
	   sys->bind("/dev/null", "/dev/notquiterandom", Sys->MREPL) < 0){
		c <-= sys->sprint("skip: bind: %r");
		return;
	}
	c <-= buf(Random->ReallyRandom, 32);
	c <-= buf(Random->NotQuiteRandom, 32);
	c <-= rint(Random->ReallyRandom);
	c <-= rint(Random->NotQuiteRandom);
}

# no devices at all: the open fails
absent(c: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	d := "/tmp/random_fail_test." + string sys->pctl(0, nil);
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r700);
	if(sys->bind(d, "/dev", Sys->MREPL) < 0){
		c <-= sys->sprint("skip: bind: %r");
		return;
	}
	c <-= buf(Random->ReallyRandom, 16);
	c <-= buf(Random->NotQuiteRandom, 16);
	c <-= rint(Random->ReallyRandom);
	sys->unmount(nil, "/dev");
	sys->remove(d);
}

testEmptyDevice(t: ref T)
{
	c := chan of string;
	spawn empty(c);
	r := <-c;
	if(len r > 5 && r[0:5] == "skip:")
		t.skip(r);
	t.assert(israised(r), "randombuf of /dev/random that gives nothing: " + r);
	r = <-c;
	t.assert(israised(r), "randombuf of /dev/notquiterandom that gives nothing: " + r);
	r = <-c;
	t.assert(israised(r), "randomint of /dev/random that gives nothing: " + r);
	r = <-c;
	t.assert(israised(r), "randomint of /dev/notquiterandom that gives nothing: " + r);
}

testNoDevice(t: ref T)
{
	c := chan of string;
	spawn absent(c);
	r := <-c;
	if(len r > 5 && r[0:5] == "skip:")
		t.skip(r);
	t.assert(israised(r), "randombuf with no /dev/random: " + r);
	r = <-c;
	t.assert(israised(r), "randombuf with no /dev/notquiterandom: " + r);
	r = <-c;
	t.assert(israised(r), "randomint with no /dev/random: " + r);
}

testStillRandom(t: ref T)
{
	t.assertseq(buf(Random->NotQuiteRandom, 32), "returned 32 bytes", "randombuf of 32 bytes");
	t.assertseq(buf(Random->NotQuiteRandom, 0), "returned 0 bytes", "randombuf of none");
	t.assertseq(buf(Random->NotQuiteRandom, 70000), "returned 70000 bytes", "randombuf past one read");
	a := random->randombuf(Random->NotQuiteRandom, 32);
	b := random->randombuf(Random->NotQuiteRandom, 32);
	same := 1;
	for(i := 0; i < 32; i++)
		if(a[i] != b[i])
			same = 0;
	t.assert(!same, "two calls give different bytes");
	r := buf(Random->NotQuiteRandom, -1);
	t.assert(israised(r), "a negative count: " + r);
	r = buf(7, 4);
	t.assert(israised(r), "a source that is neither: " + r);
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
	random = load Random Random->PATH;
	if(random == nil){
		sys->fprint(sys->fildes(2), "cannot load random: %r\n");
		raise "fail:cannot load random";
	}

	run("EmptyDevice", testEmptyDevice);
	run("NoDevice", testNoDevice);
	run("StillRandom", testStillRandom);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
