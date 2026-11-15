implement KeyringDegenerateTest;

#
# Keys and signatures as strings, which a peer or a file supplies, that
# are not keys (libkeyring's rsaalg.c, egalg.c, dsaalg.c, ed25519alg.c;
# base64tobig in libinterp/keyring.c):
#  - a key string with an empty field (a bare newline where a number is
#    due) is refused: base64tobig gave nil for it without saying where
#    the field ended, and the next field was read from wherever the
#    caller's stack pointed
#  - an RSA, ElGamal or DSA key whose modulus or prime is 0 or 1, or
#    whose other numbers are outside it, is refused when it is read: it
#    reached mpdiv, whose answer to a zero divisor ends the emulator
#  - genSKfromPK of an RSA key too small to make primes for gives nil
#    (rsa_gen had the check; this path, the one given another's key,
#    had not)
#  - an Ed25519 signature whose S has the group's order added to it is
#    refused (RFC 8032 5.1.7): it verified, as did S+2L and the rest
#  - an Ed25519 secret key whose public half is another key's is refused
#  - keys that are keys still read, sign and verify
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "encoding.m";
	base64: Encoding;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringDegenerateTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_degenerate_test.b";

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

# the lines of a key or certificate string
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

# a big-endian number of these bytes, as a key string has it
b64(a: array of byte): string
{
	return base64->enc(a);
}

ZERO: con "AA==";
ONE: con "AQ==";
THREE: con "Aw==";
FIVE: con "BQ==";

nopk(t: ref T, alg, fields, what: string)
{
	pk := kr->strtopk(alg + "\nt\n" + fields);
	t.assert(pk == nil, alg + ": a public key with " + what + " is refused");
}

testEmptyFields(t: ref T)
{
	algs := array[] of {"rsa", "elgamal", "dsa", "ed25519"};
	for(i := 0; i < len algs; i++){
		a := algs[i];
		# nothing after the owner; a bare newline; a first field and then nothing
		nopk(t, a, "", "no fields");
		nopk(t, a, "\n", "an empty first field");
		nopk(t, a, "\n\n\n\n\n", "every field empty");
		nopk(t, a, THREE + "\n", "one field of several");
		nopk(t, a, THREE + "\n\n", "its second field empty");
		nopk(t, a, "!!!!\n" + THREE + "\n", "a first field that is not base64");
		t.assert(kr->strtosk(a + "\nt\n\n") == nil, a + ": a secret key with an empty first field is refused");
		t.assert(kr->strtosk(a + "\nt\n" + THREE + "\n\n\n") == nil, a + ": a secret key with empty fields after its first is refused");
	}
	t.assert(kr->strtocert("rsa\nsha256\nt\n0\n\n") == nil, "a certificate with an empty signature is refused");
	t.assert(kr->strtocert("elgamal\nsha256\nt\n0\n\n\n") == nil, "an ElGamal certificate with empty r and s is refused");
}

testRSA(t: ref T)
{
	sk := kr->genSK("rsa", "t", 512);
	if(sk == nil)
		t.fatal("cannot make a 512-bit RSA key");
	pk := kr->sktopk(sk);
	f := lines(kr->pktostr(pk));	# rsa, owner, n, ek
	if(len f != 4)
		t.fatal(sys->sprint("an RSA public key has %d lines", len f));
	n := f[2];
	nopk(t, "rsa", ZERO + "\n" + THREE + "\n", "a modulus of 0");
	nopk(t, "rsa", ONE + "\n" + THREE + "\n", "a modulus of 1");
	nopk(t, "rsa", n + "\n" + ZERO + "\n", "an exponent of 0");
	nopk(t, "rsa", n + "\n" + ONE + "\n", "an exponent of 1");
	nopk(t, "rsa", n + "\n" + n + "\n", "an exponent that is its modulus");

	# a secret key with a prime of 0
	g := lines(kr->sktostr(sk));	# rsa, owner, n, ek, dk, p, q, kp, kq, c2
	if(len g != 10)
		t.fatal(sys->sprint("an RSA secret key has %d lines", len g));
	for(i := 5; i <= 6; i++){
		h := array[len g] of string;
		h[0:] = g;
		h[i] = ZERO;
		t.assert(kr->strtosk(join(h)) == nil, sys->sprint("rsa: a secret key whose prime %d is 0 is refused", i-4));
	}

	# a modulus too small to make primes for
	small := kr->strtopk("rsa\nt\n" + FIVE + "\n" + THREE + "\n");
	if(small != nil)
		t.assert(kr->genSKfromPK(small, "t") == nil, "rsa: no key is made to match a modulus of 5");

	# and a key that is one
	pk2 := kr->strtopk(kr->pktostr(pk));
	t.assert(pk2 != nil, "rsa: a key that is one is read");
	sk2 := kr->strtosk(kr->sktostr(sk));
	t.assert(sk2 != nil, "rsa: a secret key that is one is read");
	msg := array of byte "a message";
	cert := kr->sign(sk2, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	t.assert(cert != nil && kr->verify(pk2, cert, kr->sha256(msg, len msg, nil, nil)) == 1, "rsa: it signs and its signature verifies");
}

testElGamalDSA(t: ref T)
{
	# ElGamal: p, alpha, key
	nopk(t, "elgamal", ZERO + "\n" + THREE + "\n" + THREE + "\n", "a modulus of 0");
	nopk(t, "elgamal", THREE + "\n" + ONE + "\n" + ONE + "\n", "a modulus of 3");
	nopk(t, "elgamal", b64(array[] of {byte 23}) + "\n" + ZERO + "\n" + THREE + "\n", "a generator of 0");
	nopk(t, "elgamal", b64(array[] of {byte 23}) + "\n" + b64(array[] of {byte 23}) + "\n" + THREE + "\n", "a generator that is its modulus");
	nopk(t, "elgamal", b64(array[] of {byte 23}) + "\n" + FIVE + "\n" + b64(array[] of {byte 40}) + "\n", "a key past its modulus");
	eg := kr->strtopk("elgamal\nt\n" + b64(array[] of {byte 23}) + "\n" + FIVE + "\n" + THREE + "\n");
	t.assert(eg != nil, "elgamal: a key in its domain is read");

	# DSA: p, q, alpha, key
	p := b64(array[] of {byte 16r0b, byte 16rcd});
	q := b64(array[] of {byte 16rfb});	# 251, a prime
	nopk(t, "dsa", ZERO + "\n" + q + "\n" + THREE + "\n" + THREE + "\n", "a p of 0");
	nopk(t, "dsa", p + "\n" + ZERO + "\n" + THREE + "\n" + THREE + "\n", "a q of 0");
	nopk(t, "dsa", p + "\n" + ONE + "\n" + THREE + "\n" + THREE + "\n", "a q of 1");
	nopk(t, "dsa", q + "\n" + p + "\n" + THREE + "\n" + THREE + "\n", "a q past its p");
	nopk(t, "dsa", p + "\n" + q + "\n" + ZERO + "\n" + THREE + "\n", "a generator of 0");
	nopk(t, "dsa", p + "\n" + q + "\n" + THREE + "\n" + p + "\n", "a key that is its p");
	dsa := kr->strtopk("dsa\nt\n" + p + "\n" + q + "\n" + THREE + "\n" + FIVE + "\n");
	t.assert(dsa != nil, "dsa: a key in its domain is read");
	# a secret key whose q is not a prime (dsasign ends the emulator on one)
	comp := b64(array[] of {byte 16rff});	# 255 = 3*5*17
	t.assert(kr->strtosk("dsa\nt\n" + p + "\n" + comp + "\n" + THREE + "\n" + FIVE + "\n" + THREE + "\n") == nil, "dsa: a secret key whose q is not a prime is refused");
}

# L, the order of Ed25519's group, little-endian
L := array[] of {
	byte 16red, byte 16rd3, byte 16rf5, byte 16r5c, byte 16r1a, byte 16r63, byte 16r12, byte 16r58,
	byte 16rd6, byte 16r9c, byte 16rf7, byte 16ra2, byte 16rde, byte 16rf9, byte 16rde, byte 16r14,
	byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0,
	byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 16r10,
};

testEd25519(t: ref T)
{
	sk := kr->genSK("ed25519", "t", 256);
	if(sk == nil)
		t.fatal("cannot make an Ed25519 key");
	pk := kr->sktopk(sk);
	msg := array of byte "a message to sign";
	cert := kr->sign(sk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	if(cert == nil)
		t.fatal("cannot sign");
	t.asserteq(kr->verify(pk, cert, kr->sha256(msg, len msg, nil, nil)), 1, "the signature verifies");

	# the same signature with L added to its S
	f := lines(kr->certtostr(cert));
	sig := base64->dec(f[len f - 1]);
	if(len sig != 64)
		t.fatal(sys->sprint("an Ed25519 signature of %d bytes", len sig));
	for(k := 1; k <= 2; k++){
		carry := 0;
		for(i := 0; i < 32; i++){
			v := int sig[32+i] + int L[i] + carry;
			sig[32+i] = byte v;
			carry = v >> 8;
		}
		if(carry != 0)
			break;
		g := array[len f] of string;
		g[0:] = f;
		g[len g - 1] = base64->enc(sig);
		c2 := kr->strtocert(join(g));
		if(c2 == nil)
			t.error("the changed signature does not parse");
		else
			t.asserteq(kr->verify(pk, c2, kr->sha256(msg, len msg, nil, nil)), 0, sys->sprint("the signature with %dL added to its S is refused", k));
	}

	# a secret key carrying another key's public half
	other := kr->genSK("ed25519", "t", 256);
	a := lines(kr->sktostr(sk));	# ed25519, owner, seed, pk
	b := lines(kr->sktostr(other));
	if(len a != 4 || len b != 4)
		t.fatal(sys->sprint("an Ed25519 secret key has %d lines", len a));
	t.assert(kr->strtosk(join(a)) != nil, "a secret key that is one is read");
	a[3] = b[3];
	t.assert(kr->strtosk(join(a)) == nil, "a secret key with another key's public half is refused");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || kr == nil || base64 == nil){
		sys->fprint(sys->fildes(2), "cannot load testing, keyring or base64: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("EmptyFields", testEmptyFields);
	run("RSA", testRSA);
	run("ElGamalDSA", testElGamalDSA);
	run("Ed25519", testEd25519);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
