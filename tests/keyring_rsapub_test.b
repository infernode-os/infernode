implement KeyringRsapubTest;

#
# The RSA public keys Keyring takes from a string, and the ones it makes.
#
# - An RSA public key from a string (a peer's, in auth; a file's) with
#   an even modulus, or an exponent past 256 bits, is refused (FIPS
#   186-5 A.1.1: e is odd and below 2^256).  Checking one signature
#   with a full-length exponent is hundreds of times the work, and an
#   even modulus takes libmp's slow path: seconds for a check at 8192
#   bits.  Both were read as keys.
# - A key made by genSK("rsa") has an exponent above 2^16 (the same
#   section); it had six bits.  Keys with shorter exponents, made
#   before, are still read.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringRsapubTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_rsapub_test.b";

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

lines(s: string): array of string
{
	(nil, l) := sys->tokenize(s, "\n");
	a := array[len l] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

b64(n: ref IPint): string
{
	return n.iptob64();
}

testRSAPublic(t: ref T)
{
	sk := kr->genSK("rsa", "t", 1024);
	t.assert(sk != nil, "genSK rsa 1024");
	if(sk == nil)
		return;
	f := lines(kr->pktostr(kr->sktopk(sk)));	# rsa, owner, n, ek
	n := IPint.b64toip(f[2]);
	e := IPint.b64toip(f[3]);
	t.assert(e.bits() == 17, sys->sprint("a made key's exponent has 17 bits (it has %d)", e.bits()));
	t.assert(e.cmp(IPint.inttoip(65536)) > 0, "a made key's exponent is above 2^16");
	t.assert(kr->strtopk("rsa\nt\n" + f[2] + "\n" + f[3] + "\n") != nil, "the key made is read back");
	t.assert(kr->strtopk("rsa\nt\n" + f[2] + "\n" + b64(IPint.inttoip(37)) + "\n") != nil, "a key with a six-bit exponent, as they were made, is read");

	one := IPint.inttoip(1);
	even := n.add(one);
	t.assert(kr->strtopk("rsa\nt\n" + b64(even) + "\n" + f[3] + "\n") == nil, "an even modulus is refused");

	# odd exponents of 256 bits (the most) and 257
	e256 := one.shl(255).add(one);
	e257 := one.shl(256).add(one);
	t.assert(kr->strtopk("rsa\nt\n" + f[2] + "\n" + b64(e256) + "\n") != nil, "an exponent of 256 bits is taken");
	t.assert(kr->strtopk("rsa\nt\n" + f[2] + "\n" + b64(e257) + "\n") == nil, "an exponent of 257 bits is refused");
	full := n.sub(IPint.inttoip(2));
	t.assert(kr->strtopk("rsa\nt\n" + f[2] + "\n" + b64(full) + "\n") == nil, "an exponent as long as the modulus is refused");

	# a secret key's public half is held to the same
	g := lines(kr->sktostr(sk));	# rsa, owner, n, ek, dk, p, q, kp, kq, c2
	g[3] = b64(full);
	s := "";
	for(i := 0; i < len g; i++)
		s += g[i] + "\n";
	t.assert(kr->strtosk(s) == nil, "a secret key with such an exponent is refused");

	# small keys (no size to use) are still made, read back and sign
	small := kr->genSK("rsa", "t", 64);
	t.assert(small != nil && kr->strtosk(kr->sktostr(small)) != nil, "a 64-bit key is made and read back");
	msg := array of byte "scrub";
	cert := kr->sign(sk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	t.assert(cert != nil && kr->verify(kr->sktopk(sk), cert, kr->sha256(msg, len msg, nil, nil)) == 1, "the key made signs and its signature verifies");
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

	run("RSAPublic", testRSAPublic);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
