implement PQSigTest;

#
# Keyring's signature algorithms that sign bytes (SLH-DSA, ML-DSA,
# Ed25519) against certificates made outside libsec (fixtures in
# /tests/pqsig, made by mkfixtures.py there).
#
# SLH-DSA (slhdsa192s, slhdsa256s) signed something that was not FIPS
# 205's signature: its WOTS+ checksum kept only its low byte, so a
# signature could be chained forward to another message with the public
# hash alone; the tree and leaf index were other bits of the digest; the
# FORS key pair address was always 0; and the message was signed without
# the header the standard's interface puts before it.  Then it was the
# standard's deterministic variant; now it is hedged, the standard's
# default: a certificate the reference made with randomness of its own
# verifies, a certificate in the old format is refused, and two
# certificates of one message differ.
#
# ML-DSA (mldsa65, mldsa87) signed FIPS 204's internal interface
# (Sign_internal on the digest, with no header on M'): no conforming
# verifier took its signatures, and none it took was made by a
# conforming signer.  Now a certificate made by OpenSSL's ML-DSA (the
# pure signature, with an empty context string) verifies, and one in the
# old format is refused.  Its signing left the standard's randomness
# out, so a message's signature was always the same; and a secret key's
# text was taken whatever its fields held.
#
# For all of them: the digest is signed at its full length.  Keyring
# gave every algorithm the digest as a number, and these the number's
# bytes, which have no leading zeros: one digest in 256 was signed as 31
# bytes.  MSG0's digest begins with a zero byte; a certificate on it
# made outside, over all 32 bytes, verifies (cert0), and Ed25519's old
# signature of the 31 is refused (oldcert0).
#
# For every algorithm: a changed signature is refused, and a key that is
# generated signs and verifies.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

PQSigTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/pqsig_test.b";
FIX: con "/tests/pqsig/";

# mkfixtures.py's MSG and MSG0 (whose digest begins with a zero byte);
# the owner and expiry are in the fixtures' text
MSG: con "InferNode post-quantum certificate fixture";
MSG0: con "InferNode post-quantum certificate fixture 251";

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

readfile(t: ref T, name: string): string
{
	fd := sys->open(FIX + name, Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("cannot open %s%s: %r", FIX, name));
	buf := array[65536] of byte;
	n := 0;
	while((m := sys->read(fd, buf[n:], len buf - n)) > 0)
		n += m;
	return string buf[0:n];
}

state(msg: string): ref Keyring->DigestState
{
	a := array of byte msg;
	return kr->sha256(a, len a, nil, nil);
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}


# the certificate's text with one character of its signature changed
# (to another character of base64, so that it is still a signature's text)
changed(certtext: string, at: int): string
{
	# the signature is the last line
	e := len certtext - 1;
	b := e;
	while(b > 0 && certtext[b-1] != '\n')
		b--;
	i := b + at % (e - b - 4);
	c := 'A';
	if(certtext[i] == 'A')
		c = 'B';
	return certtext[0:i] + sys->sprint("%c", c) + certtext[i+1:];
}

# a certificate must verify, and not once its signature or message is changed
checkcertmsg(t: ref T, alg: string, pk: ref Keyring->PK, cert: ref Keyring->Certificate, msg: string)
{
	t.assert(kr->verify(pk, cert, state(msg)) != 0, alg + ": certificate verifies");
	t.assert(kr->verify(pk, cert, state(msg + ".")) == 0, alg + ": certificate refused for another message");
	text := kr->certtostr(cert);
	for(i := 0; i < 3; i++){
		c := kr->strtocert(changed(text, 7 + i*1201));
		t.assert(c != nil, alg + ": a changed signature is still a signature's text");
		if(c != nil)
			t.assert(kr->verify(pk, c, state(msg)) == 0, alg + ": changed signature refused");
	}
}

checkcert(t: ref T, alg: string, pk: ref Keyring->PK, cert: ref Keyring->Certificate)
{
	checkcertmsg(t, alg, pk, cert, MSG);
}

# the first byte of what Keyring signs for msg: sha256(msg || "pqsig 0")
digest0(msg: string): int
{
	a := array of byte (msg + "pqsig 0");
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return int d[0];
}

testDigests(t: ref T)
{
	t.assert(digest0(MSG) != 0, "MSG's digest does not begin with a zero byte");
	t.asserteq(digest0(MSG0), 0, "MSG0's digest begins with a zero byte");
}

# a fixture: a certificate on msg made elsewhere verifies under its key
fixture(t: ref T, alg: string, pk: ref Keyring->PK, name: string, msg: string): ref Keyring->Certificate
{
	cert := kr->strtocert(readfile(t, name));
	if(cert == nil)
		t.fatal(name + ": fixture certificate not read");
	t.assertseq(cert.sa.name, alg, name + ": the certificate's algorithm");
	checkcertmsg(t, name, pk, cert, msg);
	return cert;
}

# a certificate made elsewhere in a format no longer made is refused
refused(t: ref T, alg: string, pk: ref Keyring->PK, name: string, msg: string)
{
	cert := kr->strtocert(readfile(t, name));
	if(cert == nil)
		t.fatal(name + ": fixture certificate not read");
	t.assertseq(cert.sa.name, alg, name + ": the certificate's algorithm");
	t.assert(kr->verify(pk, cert, state(msg)) == 0, name + ": a certificate in the old format is refused");
}

slhkey(t: ref T, alg: string): (ref Keyring->SK, ref Keyring->PK)
{
	sk := kr->strtosk(readfile(t, alg + ".sk"));
	if(sk == nil)
		t.fatal(alg + ": fixture key not read");
	return (sk, kr->sktopk(sk));
}

# the reference's hedged certificate, on the digest that begins 00, at
# its full length; and what the fixed key makes of that message verifies
# and is not the reference's (other randomness)
testSLH192Known(t: ref T)
{
	(sk, pk) := slhkey(t, "slhdsa192s");
	ref0 := fixture(t, "slhdsa192s", pk, "slhdsa192s.cert0", MSG0);
	cert := kr->sign(sk, 0, state(MSG0), "sha256");
	if(cert == nil)
		t.fatal("slhdsa192s: sign gave no certificate");
	t.assert(kr->verify(pk, cert, state(MSG0)) != 0, "slhdsa192s: own certificate on a digest beginning 00 verifies");
	t.assert(kr->certtostr(cert) != kr->certtostr(ref0), "slhdsa192s: signing is hedged: not the reference's signature");
}

testSLH256Known(t: ref T)
{
	(nil, pk) := slhkey(t, "slhdsa256s");
	fixture(t, "slhdsa256s", pk, "slhdsa256s.cert", MSG);
}

# a certificate in the format made before is a signature of the right
# length for the key, and is refused
testSLHOldFormat(t: ref T)
{
	(nil, pk) := slhkey(t, "slhdsa192s");
	refused(t, "slhdsa192s", pk, "slhdsa192s.oldcert", MSG);
}

# ML-DSA certificates made by OpenSSL in Keyring's format verify: the
# pure signature of the digest; Sign_internal's, which Keyring made
# before, does not
mldsafix(t: ref T, alg: string)
{
	pk := kr->strtopk(readfile(t, alg + ".pk"));
	if(pk == nil)
		t.fatal(alg + ": fixture key not read");
	fixture(t, alg, pk, alg + ".cert", MSG);
	fixture(t, alg, pk, alg + ".cert0", MSG0);
	refused(t, alg, pk, alg + ".oldcert", MSG);
}

testMLDSA65Fixture(t: ref T)
{
	mldsafix(t, "mldsa65");
}

testMLDSA87Fixture(t: ref T)
{
	mldsafix(t, "mldsa87");
}

# Ed25519: OpenSSL's signature of all 32 bytes of a digest beginning 00
# verifies; of the 31 after the zero, which Keyring signed before, not
testEd25519Fixture(t: ref T)
{
	pk := kr->strtopk(readfile(t, "ed25519.pk"));
	if(pk == nil)
		t.fatal("ed25519: fixture key not read");
	fixture(t, "ed25519", pk, "ed25519.cert", MSG);
	fixture(t, "ed25519", pk, "ed25519.cert0", MSG0);
	refused(t, "ed25519", pk, "ed25519.oldcert0", MSG0);
}

# every algorithm that signs bytes signs and verifies a digest beginning
# 00 (RSA signs a number, and does as it did)
testZeroDigestRoundTrip(t: ref T)
{
	algs := array[] of {"ed25519", "mldsa65", "mldsa87", "rsa"};
	for(i := 0; i < len algs; i++){
		alg := algs[i];
		n := 0;
		if(alg == "rsa")
			n = 1024;
		sk := kr->genSK(alg, "pqsig", n);
		if(sk == nil){
			t.error(alg + ": genSK gave no key");
			continue;
		}
		pk := kr->sktopk(sk);
		cert := kr->sign(sk, 0, state(MSG0), "sha256");
		if(cert == nil){
			t.error(alg + ": sign gave no certificate");
			continue;
		}
		t.assert(kr->verify(pk, cert, state(MSG0)) != 0, alg + ": certificate on a digest beginning 00 verifies");
		t.assert(kr->verify(pk, cert, state(MSG)) == 0, alg + ": and not for another message");
		c2 := kr->strtocert(kr->certtostr(cert));
		t.assert(c2 != nil && kr->verify(pk, c2, state(MSG0)) != 0, alg + ": and after a round trip through its text");
	}
}

# a generated key signs, verifies, and survives its text
generated(t: ref T, alg: string)
{
	sk := kr->genSK(alg, "pqsig", 0);
	if(sk == nil)
		t.fatal(alg + ": genSK gave no key");
	pk := kr->sktopk(sk);
	cert := kr->sign(sk, 0, state(MSG), "sha256");
	if(cert == nil)
		t.fatal(alg + ": sign gave no certificate");
	checkcert(t, alg, pk, cert);
	pk2 := kr->strtopk(kr->pktostr(pk));
	cert2 := kr->strtocert(kr->certtostr(cert));
	t.assert(pk2 != nil && cert2 != nil && kr->verify(pk2, cert2, state(MSG)) != 0,
		alg + ": key and certificate verify after a round trip through their text");
	other := kr->sktopk(kr->genSK(alg, "pqsig", 0));
	t.assert(kr->verify(other, cert, state(MSG)) == 0, alg + ": certificate refused under another key");
}

# signing is hedged (FIPS 204 Algorithm 2, FIPS 205 Algorithm 22): fresh
# randomness goes into each signature, so two of one message differ
# (they were the same), and both verify
hedged(t: ref T, alg: string)
{
	sk := kr->genSK(alg, "pqsig", 0);
	if(sk == nil)
		t.fatal(alg + ": genSK gave no key");
	pk := kr->sktopk(sk);
	c1 := kr->sign(sk, 0, state(MSG), "sha256");
	c2 := kr->sign(sk, 0, state(MSG), "sha256");
	if(c1 == nil || c2 == nil)
		t.fatal(alg + ": sign gave no certificate");
	t.assert(kr->certtostr(c1) != kr->certtostr(c2), alg + ": two signatures of one message differ");
	t.assert(kr->verify(pk, c1, state(MSG)) != 0 && kr->verify(pk, c2, state(MSG)) != 0, alg + ": both verify");
}

# a secret key's text whose s1 holds fields no key has (bytes of ff:
# coefficients of -11 where they lie between -4 and 4, or -5 for -2 to 2)
# is not a key.  It was taken, and signed with.
badkey(t: ref T, alg: string)
{
	sk := kr->genSK(alg, "pqsig", 0);
	if(sk == nil)
		t.fatal(alg + ": genSK gave no key");
	text := kr->sktostr(sk);
	t.assert(kr->strtosk(text) != nil, alg + ": a key's own text is read back");
	# the third line is the secret key in base64; its bytes 150 to 152
	# (in s1, which starts at byte 128) are characters 200 to 203
	b := 0;
	for(nl := 0; nl < 2; b++)
		if(text[b] == '\n')
			nl++;
	bad := text[0:b+200] + "////" + text[b+204:];
	t.assert(len bad == len text, alg + ": changed text is the same length");
	t.assert(kr->strtosk(bad) == nil, alg + ": a secret key with fields out of range is refused");
}

testMLDSA65Generated(t: ref T)
{
	generated(t, "mldsa65");
	hedged(t, "mldsa65");
}

testMLDSA87Generated(t: ref T)
{
	generated(t, "mldsa87");
	hedged(t, "mldsa87");
}

testMLDSABadKey(t: ref T)
{
	badkey(t, "mldsa65");
	badkey(t, "mldsa87");
}

# slhdsa192s only: a signature takes seconds, and slhdsa_test generates both
testSLH192Generated(t: ref T)
{
	generated(t, "slhdsa192s");
}

testSLH192Hedged(t: ref T)
{
	hedged(t, "slhdsa192s");
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

	run("Digests", testDigests);
	run("SLH192Known", testSLH192Known);
	run("SLH256Known", testSLH256Known);
	run("SLHOldFormat", testSLHOldFormat);
	run("MLDSA65Fixture", testMLDSA65Fixture);
	run("MLDSA87Fixture", testMLDSA87Fixture);
	run("Ed25519Fixture", testEd25519Fixture);
	run("ZeroDigestRoundTrip", testZeroDigestRoundTrip);
	run("MLDSA65Generated", testMLDSA65Generated);
	run("MLDSA87Generated", testMLDSA87Generated);
	run("MLDSABadKey", testMLDSABadKey);
	run("SLH192Generated", testSLH192Generated);
	run("SLH192Hedged", testSLH192Hedged);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
