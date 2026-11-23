implement KeyringNoresultTest;

#
# Keyring's builtins when libsec has no result to give.
#
# libsec's dsasign, eggen and gensafeprime say when they made nothing: a
# DSA group that is none (q of 2, or a q that is not prime: the adt is a
# program's to fill in), a search for a safe prime that gave up or was
# told to stop because its Prog is being killed.  Three builtins used
# the answer without looking.  DSAsk.sign and EGsk.gen followed the nil
# pointer, which ends the emulator (in the native kernels it stops the
# machine); dhparams made a group of two zeros.  Each raises.
#
# - DSAsk.sign with p = 5 and q = 2 is "bad encryption key", every time;
#   with a q that is not prime (p = 31, q = 15) each call is a signature
#   or "bad
#   encryption key", and of sixty most are refused.  The emulator ended at the
#   first refusal.
# - a Prog killed half a second into EGsk.gen of a size with no known
#   prime is gone, and the emulator goes on (it ended: eggen had
#   stopped and given nil).
# - a Prog killed in dhparams of such a size is gone too.  When the
#   builtins first raised for no result they raised for this as well,
#   and a Prog that was being killed stayed, broken, with "dhparams: no
#   prime found" (and "EGsk.gen: no key made"): a kill is not an error
#   of the Prog's, and is raised as the call returns.  The other way a
#   search ends with nothing cannot be made to happen from Limbo: it
#   tries 64n+1000 candidates, and there is a safe prime of every size.
# - the builtins still make what they are asked for.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint, DSApk, DSAsk, DSAsig, EGsk: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringNoresultTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_noresult_test.b";

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

ip(n: int): ref IPint
{
	return IPint.inttoip(n);
}

# 1 a signature, 0 "bad key", -1 anything else
sign(sk: ref DSAsk, m: ref IPint): (int, string)
{
	{
		sig := sk.sign(m);
		if(sig == nil || sig.r == nil || sig.s == nil)
			return (-1, "nil signature");
		return (1, nil);
	} exception e {
	"bad encryption key*" =>
		return (0, e);
	"*" =>
		return (-1, e);
	}
}

testDSANoGroup(t: ref T)
{
	# q divides p-1 and both pass the checks made before libsec is asked
	sk := ref DSAsk(ref DSApk(ip(5), ip(2), ip(4), ip(4)), ip(1));
	for(i := 0; i < 5; i++){
		(r, e) := sign(sk, ip(3+i));
		t.asserteq(r, 0, sys->sprint("DSAsk.sign with q = 2 is a bad key (%s)", e));
	}

	# q = 15 is no prime: a k with no inverse mod q ends the signing
	sk = ref DSAsk(ref DSApk(ip(31), ip(15), ip(2), ip(8)), ip(3));
	nsig := nbad := 0;
	for(i = 0; i < 60; i++){
		(r, e) := sign(sk, ip(100+i));
		case r {
		1 =>	nsig++;
		0 =>	nbad++;
		* =>	t.error("DSAsk.sign with q = 15: " + e);
		}
	}
	t.log(sys->sprint("q = 15: %d signatures, %d refused", nsig, nbad));
	t.assert(nbad > 0, "DSAsk.sign with a q that is not prime is refused when k has no inverse");

	# and a key that is one still signs and verifies
	pk := ref DSApk(ip(23), ip(11), ip(4), ip(18));
	sk = ref DSAsk(pk, ip(3));
	sig := sk.sign(ip(7));
	t.assert(sig != nil && pk.verify(sig, ip(7)), "a DSA key signs and its signature verifies");
}

worker(what: string, pidc: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	case what {
	"EGsk.gen" =>
		EGsk.gen(1030, 0);
	"dhparams" =>
		kr->dhparams(2050);
	}
	done <-= 1;
}

there(pid: int): int
{
	return sys->open(sys->sprint("/prog/%d/status", pid), Sys->OREAD) != nil;
}

# ms until the Prog killed in its builtin is gone, -1 if it is still there
killed(what: string, limit: int): (int, int)
{
	pidc := chan of int;
	done := chan[1] of int;
	spawn worker(what, pidc, done);
	pid := <-pidc;
	sys->sleep(500);
	alt{
	<-done =>
		return (0, 1);
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

testKilledInSearch(t: ref T)
{
	what := array[] of {"EGsk.gen", "dhparams"};
	for(i := 0; i < len what; i++){
		(ms, finished) := killed(what[i], 15000);
		if(finished){
			t.log(what[i] + " finished in half a second: nothing to kill");
			continue;
		}
		t.assert(ms >= 0, what[i] + ": a Prog killed in its search is still there after 15 s");
		if(ms >= 0)
			t.log(sys->sprint("%s: gone %d ms after its kill", what[i], ms));
	}
	# the emulator is still here, and the builtins still answer
	(alpha, p) := kr->dhparams(40);
	t.assert(alpha != nil && p != nil && p.bits() == 40, "dhparams(40) makes a prime of 40 bits");
	sk := EGsk.gen(40, 0);
	t.assert(sk != nil && sk.pk != nil && sk.pk.p.bits() == 40, "EGsk.gen(40) makes a key of 40 bits");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DSANoGroup", testDSANoGroup);
	run("KilledInSearch", testKilledInSearch);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
