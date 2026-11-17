implement KeyringRSATest;

#
# Keyring's RSA and DSA keys as adts a program fills in, and RSA keys as
# strings (libinterp/keyring.c, libsec's rsafill, rsagen, rsaencrypt,
# rsadecrypt, dsasign, libkeyring/rsaalg.c).
#
# - RSAsk.fill with p equal to q raised out of libsec with two of its
#   numbers made and nothing to free them: 768 bytes of the kernel's main
#   pool a call, for good, from any program. With a negative p or q it
#   raised where nil is the refusal; with a negative e and d it made a
#   key every use of which raised.
# - DSAsk.sign with a q that is not prime raised when its nonce had no
#   inverse, with five numbers made: 800 bytes a call.
# - RSAsk.gen's dk was negative for one key in ten, and RSAsk.fill
#   refused such a key.
# - A signature with the modulus added to it, or taken from it, verified
#   (RFC 8017 5.2.2 says there is none), and a message at or past the
#   modulus was encrypted, decrypted and signed (5.1.1, 5.1.2, 5.2.1).
# - RSAsk.sign and decrypt gave out what their key computed whatever the
#   key: with kq (or kp, or c2) not the key's, the result is right modulo
#   one prime and wrong modulo the other, and gcd(s^e - m, n) is a prime
#   of the key. A result is now checked before it is given: nil.
# - A key's numbers were of any length, and libsec's time is the cube of
#   a modulus's with nothing to end it sooner: none is longer than the
#   generators make (65536 bits).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint, RSApk, RSAsk, RSAsig, DSApk, DSAsk: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringRSATest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_rsa_test.b";

passed := 0;
failed := 0;
skipped := 0;

only: list of string;

run(name: string, testfn: ref fn(t: ref T))
{
	if(only != nil){
		for(l := only; l != nil; l = tl l)
			if(hd l == name)
				break;
		if(l == nil)
			return;
	}
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

# the kernel's main pool, in bytes in use
mainpool(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nf, f) := sys->tokenize(hd l, " ");
		if(nf < 2)
			continue;
		name := "";
		for(g := f; g != nil; g = tl g)
			name = hd g;
		if(name == "main")
			return int hd f;
	}
	return -1;
}

# RSAsk.fill's answer: "key", "nil", or the exception
fill(n, e, d, p, q: ref IPint): string
{
	{
		if(RSAsk.fill(n, e, d, p, q) == nil)
			return "nil";
	} exception ex {
	"*" =>
		return "exception: " + ex;
	}
	return "key";
}

testFill(t: ref T)
{
	t.assertseq(fill(ip(9), ip(1), ip(1), ip(3), ip(3)), "nil", "fill with p = q = 3");
	t.assertseq(fill(ip(121), ip(3), ip(67), ip(11), ip(11)), "nil", "fill with p = q = 11");
	t.assertseq(fill(ip(-15), ip(3), ip(3), ip(-3), ip(5)), "nil", "fill with p = -3");
	t.assertseq(fill(ip(-15), ip(3), ip(3), ip(3), ip(-5)), "nil", "fill with q = -5");
	t.assertseq(fill(ip(35), ip(-5), ip(-5), ip(5), ip(7)), "nil", "fill with e = d = -5");
	t.assertseq(fill(ip(35), ip(5), ip(-19), ip(5), ip(7)), "nil", "fill with d = -19");
	t.assertseq(fill(ip(35), ip(5), ip(5), ip(5), ip(7)), "key", "fill(35, 5, 5, 5, 7)");

	m0 := mainpool();
	if(m0 < 0)
		t.skip("no /dev/memory");
	nine := ip(9);
	one := ip(1);
	three := ip(3);
	n := 0;
	for(i := 0; i < 4000; i++)
		if(fill(nine, one, one, three, three) == "nil")
			n++;
	t.asserteq(n, 4000, "4000 fills with p = q are nil");
	grew := mainpool() - m0;
	t.log(sys->sprint("4000 fills with p = q: main pool %d bytes more", grew));
	t.assert(grew < 512*1024, sys->sprint("4000 refused fills kept %d bytes of the main pool", grew));
}

testGen(t: ref T)
{
	zero := ip(0);
	neg := 0;
	refused := 0;
	for(i := 0; i < 40; i++){
		sk := RSAsk.gen(256, 6, 0);
		if(sk.dk.cmp(zero) <= 0)
			neg++;
		if(fill(sk.pk.n, sk.pk.ek, sk.dk, sk.p, sk.q) != "key")
			refused++;
	}
	t.asserteq(neg, 0, "keys of 40 from RSAsk.gen whose dk is not positive");
	t.asserteq(refused, 0, "keys of 40 from RSAsk.gen that RSAsk.fill refuses");
}

# what a call raises, "nil", or "ok"
enc(pk: ref RSApk, m: ref IPint): string
{
	{
		if(pk.encrypt(m) == nil)
			return "nil";
	} exception ex {
	"*" =>
		return "exception: " + ex;
	}
	return "ok";
}

dec(sk: ref RSAsk, m: ref IPint): string
{
	{
		if(sk.decrypt(m) == nil)
			return "nil";
	} exception ex {
	"*" =>
		return "exception: " + ex;
	}
	return "ok";
}

sgn(sk: ref RSAsk, m: ref IPint): string
{
	{
		if(sk.sign(m) == nil)
			return "nil";
	} exception ex {
	"*" =>
		return "exception: " + ex;
	}
	return "ok";
}

testRange(t: ref T)
{
	sk := RSAsk.gen(512, 6, 0);
	pk := sk.pk;
	n := pk.n;
	m := IPint.random(500, 500);
	sig := sk.sign(m);
	t.assert(sig != nil && pk.verify(sig, m) == 1, "a signature verifies");
	t.assert(sk.decrypt(pk.encrypt(m)).eq(m), "what is encrypted is decrypted");

	# RFC 8017 5.2.2: a signature representative is in 0..n-1
	t.asserteq(pk.verify(ref RSAsig(sig.n.add(n)), m), 0, "the signature plus n");
	t.asserteq(pk.verify(ref RSAsig(sig.n.sub(n)), m), 0, "the signature minus n");
	t.asserteq(pk.verify(ref RSAsig(sig.n.add(n).add(n)), m), 0, "the signature plus 2n");

	# 5.1.1, 5.1.2, 5.2.1: and a message
	t.assertseq(enc(pk, m.add(n)), "nil", "encrypt of m+n");
	t.assertseq(enc(pk, n), "nil", "encrypt of n");
	t.assertseq(enc(pk, ip(-5)), "nil", "encrypt of -5");
	t.assertseq(enc(pk, n.sub(ip(1))), "ok", "encrypt of n-1");
	t.assertseq(enc(pk, ip(0)), "ok", "encrypt of 0");
	t.assertseq(dec(sk, m.add(n)), "nil", "decrypt of m+n");
	t.assertseq(dec(sk, ip(-5)), "nil", "decrypt of -5");
	t.assertseq(sgn(sk, m.add(n)), "nil", "sign of m+n");
	t.assertseq(sgn(sk, m), "ok", "sign of m");
}

# a key's CRT parts that are not the key's: no result, where the result
# gave the key away
testFault(t: ref T)
{
	sk := RSAsk.gen(512, 6, 0);
	m := IPint.random(500, 500);
	two := ip(2);
	bad := array[] of {
		("kq", ref RSAsk(sk.pk, sk.dk, sk.p, sk.q, sk.kp, sk.kq.add(two), sk.c2)),
		("kp", ref RSAsk(sk.pk, sk.dk, sk.p, sk.q, sk.kp.add(two), sk.kq, sk.c2)),
		("c2", ref RSAsk(sk.pk, sk.dk, sk.p, sk.q, sk.kp, sk.kq, sk.c2.add(ip(1)))),
	};
	for(i := 0; i < len bad; i++){
		(name, k) := bad[i];
		t.assertseq(sgn(k, m), "nil", "sign with a key whose " + name + " is not its own");
		t.assertseq(dec(k, m), "nil", "decrypt with a key whose " + name + " is not its own");
	}
	t.assertseq(sgn(sk, m), "ok", "sign with the key as made");
}

lines(s: string): array of string
{
	(n, l) := sys->tokenize(s, "\n");
	a := array[n] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

join(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += a[i] + "\n";
	return s;
}

# the same through key strings, Keyring's sign and verify
testStrings(t: ref T)
{
	sk := kr->genSK("rsa", "t", 512);
	if(sk == nil)
		t.fatal("cannot make a 512-bit RSA key");
	pk := kr->sktopk(sk);
	msg := array of byte "a message";
	cert := kr->sign(sk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	t.assert(cert != nil && kr->verify(pk, cert, kr->sha256(msg, len msg, nil, nil)) == 1, "a certificate verifies");

	# the certificate's signature with the modulus added
	c := lines(kr->certtostr(cert));	# rsa, sha256, signer, expiry, signature
	f := lines(kr->pktostr(pk));	# rsa, owner, n, ek
	if(len c != 5 || len f != 4)
		t.fatal(sys->sprint("a certificate has %d lines and a key %d", len c, len f));
	n := IPint.b64toip(f[2]);
	s := IPint.b64toip(c[4]);
	t.assert(n != nil && s != nil, "the modulus and the signature are numbers");
	c[4] = s.add(n).iptob64();
	forged := kr->strtocert(join(c));
	t.assert(forged != nil, "the certificate with its signature plus n is read");
	if(forged != nil)
		t.asserteq(kr->verify(pk, forged, kr->sha256(msg, len msg, nil, nil)), 0, "and does not verify");

	# a secret key whose kq is not its own makes no certificate
	g := lines(kr->sktostr(sk));	# rsa, owner, n, ek, dk, p, q, kp, kq, c2
	if(len g != 10)
		t.fatal(sys->sprint("an RSA secret key has %d lines", len g));
	g[8] = IPint.b64toip(g[8]).add(ip(2)).iptob64();
	damaged := kr->strtosk(join(g));
	t.assert(damaged != nil, "the key with kq+2 is read");
	if(damaged != nil){
		bad: ref Keyring->Certificate;
		e := "";
		{
			bad = kr->sign(damaged, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
		} exception ex {
		"*" =>
			e = ex;
		}
		t.assert(bad == nil, "a key whose kq is not its own signs nothing: " + e);
	}
}

dsasign(sk: ref DSAsk, m: ref IPint): string
{
	{
		if(sk.sign(m) == nil)
			return "nil";
	} exception ex {
	"*" =>
		return "exception: " + ex;
	}
	return "ok";
}

# DSAsk.sign with a q that is not prime: an exception when a nonce has
# no inverse, and nothing kept
testDSAComposite(t: ref T)
{
	pk := ref DSApk(ip(31), ip(15), ip(2), ip(4));
	sk := ref DSAsk(pk, ip(2));
	m := ip(7);
	m0 := mainpool();
	if(m0 < 0)
		t.skip("no /dev/memory");
	raised := 0;
	for(i := 0; i < 4000; i++)
		if(dsasign(sk, m) != "ok")
			raised++;
	t.assert(raised > 500, sys->sprint("%d of 4000 signatures with q = 15 raised", raised));
	grew := mainpool() - m0;
	t.log(sys->sprint("%d raises: main pool %d bytes more", raised, grew));
	t.assert(grew < 512*1024, sys->sprint("%d refused signatures kept %d bytes of the main pool", raised, grew));
}

testLength(t: ref T)
{
	# a modulus of 70000 bits: longer than any key made here
	huge := ip(1).shl(70000).add(ip(1));
	pk := ref RSApk(huge, ip(3));
	e := enc(pk, ip(5));
	t.assert(e != "ok" && e != "nil", "encrypt with a modulus of 70000 bits: " + e);
	pk = ref RSApk(ip(1).shl(1000).add(ip(1)), huge);
	e = enc(pk, ip(5));
	t.assert(e != "ok" && e != "nil", "encrypt with an exponent of 70000 bits: " + e);
	e = fill(huge, ip(3), ip(3), ip(5), ip(7));
	t.assert(e != "key" && e != "nil", "fill with a modulus of 70000 bits: " + e);
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
	if(kr == nil){
		sys->fprint(sys->fildes(2), "cannot load Keyring: %r\n");
		raise "fail:cannot load Keyring";
	}
	testing->init();
	if(args != nil)
		args = tl args;
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		else
			only = hd a :: only;
	}

	run("Fill", testFill);
	run("Gen", testGen);
	run("Range", testRange);
	run("Fault", testFault);
	run("Strings", testStrings);
	run("DSAComposite", testDSAComposite);
	run("Length", testLength);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
