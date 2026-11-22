implement IPintsPrimeTest;

#
# The prime generators (libsec's dsaprimes, genprime, genstrongprime,
# through $IPints).
#
# - DSAprimes kept a sum from one candidate for p to the next, so the p
#   it returned was not the one its seed gives, about one time in two:
#   the seed is returned "so that sceptics can later confirm the
#   computation", and they could not.
# - genprime's prime had a bit more than asked for when the count up
#   from its start passed a power of two (at four bits, one time in
#   three), and genstrongprime's a bit fewer as its parts fell.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;
include "testing.m";
	testing: Testing;
	T: import testing;

IPintsPrimeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ipints_prime_test.b";

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

ip(i: int): ref IPint
{
	return IPint.inttoip(i);
}

hincr(s: array of byte)
{
	for(i := 0; i < len s; i++){
		s[i] = byte (int s[i] + 1);
		if(s[i] != byte 0)
			break;
	}
}

# a little-endian number
letoip(a: array of byte): ref IPint
{
	b := array[len a] of byte;
	for(i := 0; i < len a; i++)
		b[len a - 1 - i] = a[i];
	return IPint.bebytestoip(b);
}

sha1(a: array of byte): array of byte
{
	d := array[Keyring->SHA1dlen] of byte;
	kr->sha1(a, len a, d, nil);
	return d;
}

# q and p from a seed, by the Handbook of Applied Cryptography's 4.56
# as DSAprimes has it (little-endian counters, n = 6, b = 63)
fromseed(seed: array of byte): (ref IPint, ref IPint)
{
	sj := array[20] of byte;
	sj[0:] = seed;
	hs := sha1(seed);
	hincr(sj);
	hs1 := sha1(sj);
	for(i := 0; i < 20; i++)
		hs[i] ^= hs1[i];
	hs[0] |= byte 1;
	hs[19] |= byte 16r80;
	q := letoip(hs);
	hincr(sj);
	q2 := q.shl(1);
	two1023 := ip(1).shl(1023);
	mb := ip(1).shl(63);
	one := ip(1);
	for(i = 0; i < 4096; i++){
		w := ip(0);
		sjk := array[20] of byte;
		sjk[0:] = sj;
		for(k := 0; k <= 6; k++){
			v := letoip(sha1(sjk));
			if(k == 6)
				v = v.mod(mb);
			w = w.add(v.shl(160*k));
			hincr(sjk);
		}
		x := w.add(two1023);
		p := x.sub(x.mod(q2).sub(one));
		if(p.cmp(two1023) >= 0 && ipints->probably_prime(p, 18))
			return (q, p);
		for(k = 0; k < 7; k++)
			hincr(sj);
	}
	return (q, nil);
}

# the primes are the ones their seed gives
testDSAprimes(t: ref T)
{
	for(n := 0; n < 4; n++){
		(q, p, seed) := ipints->DSAprimes();
		t.asserteq(q.bits(), 160, "q has 160 bits");
		t.asserteq(p.bits(), 1024, "p has 1024 bits");
		t.assert(p.sub(ip(1)).mod(q).eq(ip(0)), "q divides p-1");
		(q2, p2) := fromseed(seed);
		t.assert(q2.eq(q), "q is the seed's");
		t.assert(p2 != nil && p2.eq(p), "p is the seed's");
	}
}

testPrimeSizes(t: ref T)
{
	for(n := 2; n <= 12; n++){
		off := 0;
		for(i := 0; i < 150; i++){
			p := ipints->genprime(n, 0);
			if(p.bits() != n)
				off++;
		}
		t.asserteq(off, 0, sys->sprint("of 150 primes of %d bits, those of another length", n));
	}
	sizes := array[] of {64, 65, 96, 128, 200};
	for(j := 0; j < len sizes; j++){
		off := 0;
		for(i := 0; i < 12; i++){
			p := ipints->genstrongprime(sizes[j], 0);
			if(p.bits() != sizes[j] || !ipints->probably_prime(p, 18))
				off++;
		}
		t.asserteq(off, 0, sys->sprint("of 12 strong primes of %d bits, those of another length", sizes[j]));
	}
	t.asserteq(ipints->genstrongprime(10, 0).bits(), 64, "a strong prime asked for with 10 bits has 64");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	kr = load Keyring Keyring->PATH;
	ipints = load IPints IPints->PATH;
	if(kr == nil || ipints == nil){
		sys->fprint(sys->fildes(2), "cannot load Keyring or IPints: %r\n");
		raise "fail:cannot load Keyring";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DSAprimes", testDSAprimes);
	run("PrimeSizes", testPrimeSizes);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
