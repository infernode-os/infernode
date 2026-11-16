implement PrimeKillTest;

#
# A Prog killed while it searches for a prime stops searching.
#
# The searches (libsec's genprime, genstrongprime and gensafeprime,
# through $IPints and under Keyring's ElGamal keys) run with the Dis VM
# let go.  A kill then only marks the Prog: it was gone when the search
# ended, minutes later for a safe prime of 2048 bits, and until then it
# had one of the machine's processors.  gensafeprime's search had no
# end but its luck.  Each now asks between candidates whether its Prog
# is being killed.
#
# - a Prog killed half a second into gensafeprime(2048), genprime(16384),
#   genstrongprime(8192) or the making of a 1536-bit ElGamal key is gone
#   from /prog within fifteen seconds (each takes minutes)
# - the generators still make what they are asked for: a safe prime
#   with its generator, a prime, a strong prime, at small sizes
# - IPint.bits() of zero is 0 (it was 1)
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

PrimeKillTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/prime_kill_test.b";

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

worker(what: string, pidc: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	case what {
	"gensafeprime" =>
		ipints->gensafeprime(2048, 0);
	"genprime" =>
		ipints->genprime(16384, 0);
	"genstrongprime" =>
		ipints->genstrongprime(8192, 0);
	"elgamal" =>
		kr->genSK("elgamal", "prime_kill_test", 1536);
	}
	done <-= 1;
}

there(pid: int): int
{
	return sys->open(sys->sprint("/prog/%d/status", pid), Sys->OREAD) != nil;
}

# ms until the Prog killed in its search is gone, or -1 if it is still there after limit
killed(what: string, limit: int): (int, int)
{
	pidc := chan of int;
	done := chan[1] of int;
	spawn worker(what, pidc, done);
	pid := <-pidc;
	sys->sleep(500);
	alt{
	<-done =>
		return (0, 1);	# it finished: nothing to kill
	* =>
		;
	}
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		return (-1, 0);
	t0 := sys->millisec();
	sys->fprint(fd, "kill");
	fd = nil;
	while(there(pid)){
		if(sys->millisec() - t0 > limit)
			return (-1, 0);
		sys->sleep(50);
	}
	return (sys->millisec() - t0, 0);
}

testKilled(t: ref T)
{
	what := array[] of {"gensafeprime", "genprime", "genstrongprime", "elgamal"};
	for(i := 0; i < len what; i++){
		(ms, finished) := killed(what[i], 15000);
		if(finished){
			t.log(what[i] + " finished in half a second: not timed");
			continue;
		}
		t.assert(ms >= 0, what[i] + ": a Prog killed in its search is still searching after 15 s");
		if(ms >= 0)
			t.log(sys->sprint("%s: gone %d ms after its kill", what[i], ms));
	}
}

testStillMakes(t: ref T)
{
	one := IPint.inttoip(1);
	for(n := 3; n <= 40; n += 37){
		(p, alpha) := ipints->gensafeprime(n, 0);
		t.assert(p != nil && alpha != nil && p.bits() == n, sys->sprint("gensafeprime(%d) makes a prime of %d bits", n, n));
		if(p == nil)
			continue;
		q := p.sub(one).shr(1);
		t.assert(ipints->probably_prime(p, 20) && (n == 3 || ipints->probably_prime(q, 20)), sys->sprint("gensafeprime(%d): p and (p-1)/2 are primes", n));
		t.assert(!alpha.expmod(q, p).eq(one) && !alpha.mul(alpha).mod(p).eq(one), sys->sprint("gensafeprime(%d): alpha generates the group", n));
	}
	p := ipints->genprime(200, 0);
	t.assert(p != nil && p.bits() == 200 && ipints->probably_prime(p, 20), "genprime(200) makes a prime of 200 bits");
	p = ipints->genstrongprime(256, 0);
	t.assert(p != nil && p.bits() == 256 && ipints->probably_prime(p, 20), "genstrongprime(256) makes a prime of 256 bits");
}

testBits(t: ref T)
{
	t.asserteq(IPint.inttoip(0).bits(), 0, "bits of zero");
	t.asserteq(IPint.inttoip(1).bits(), 1, "bits of one");
	t.asserteq(IPint.inttoip(255).bits(), 8, "bits of 255");
	t.asserteq(IPint.inttoip(256).bits(), 9, "bits of 256");
	t.asserteq(IPint.inttoip(-256).bits(), 9, "bits of -256");
	t.asserteq(IPint.bytestoip(array[4] of {* => byte 0}).bits(), 0, "bits of four zero bytes");
	t.asserteq(IPint.inttoip(7).sub(IPint.inttoip(7)).bits(), 0, "bits of 7 - 7");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ipints = load IPints IPints->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Bits", testBits);
	run("StillMakes", testStillMakes);
	run("Killed", testKilled);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
