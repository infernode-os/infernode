implement PQSigTest;

#
# Keyring's post-quantum signature algorithms against certificates made
# outside libsec (fixtures in /tests/pqsig, made by mkfixtures.py there).
#
# SLH-DSA (slhdsa192s, slhdsa256s) signed something that was not FIPS
# 205's signature: its WOTS+ checksum kept only its low byte, so a
# signature could be chained forward to another message with the public
# hash alone; the tree and leaf index were other bits of the digest; the
# FORS key pair address was always 0; and the message was signed without
# the header the standard's interface puts before it.  The tests here
# could not see it, being round trips.  Now a fixed key's certificate is
# the one the standard's reference makes, byte for byte, and a
# certificate in the old format is refused.
#
# ML-DSA (mldsa65, mldsa87) certificates must go on verifying as they
# did: a certificate made by OpenSSL in Keyring's format is the guard.
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

# mkfixtures.py's MSG; the owner and expiry are in the fixtures' text
MSG: con "InferNode post-quantum certificate fixture";

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

sha256hex(s: string): string
{
	a := array of byte s;
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return hex(d);
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
checkcert(t: ref T, alg: string, pk: ref Keyring->PK, cert: ref Keyring->Certificate)
{
	t.assert(kr->verify(pk, cert, state(MSG)) != 0, alg + ": certificate verifies");
	t.assert(kr->verify(pk, cert, state(MSG + ".")) == 0, alg + ": certificate refused for another message");
	text := kr->certtostr(cert);
	for(i := 0; i < 3; i++){
		c := kr->strtocert(changed(text, 7 + i*1201));
		t.assert(c != nil, alg + ": a changed signature is still a signature's text");
		if(c != nil)
			t.assert(kr->verify(pk, c, state(MSG)) == 0, alg + ": changed signature refused");
	}
}

# a fixed key's certificate is the reference's, byte for byte
slhkat(t: ref T, alg: string)
{
	sk := kr->strtosk(readfile(t, alg + ".sk"));
	if(sk == nil)
		t.fatal(alg + ": fixture key not read");
	pk := kr->sktopk(sk);
	cert := kr->sign(sk, 0, state(MSG), "sha256");
	if(cert == nil)
		t.fatal(alg + ": sign gave no certificate");
	want := readfile(t, alg + ".sum");
	if(len want > 0 && want[len want - 1] == '\n')
		want = want[0:len want - 1];
	t.assertseq(sha256hex(kr->certtostr(cert)), want, alg + ": certificate is FIPS 205's pure signature of the digest");
	checkcert(t, alg, pk, cert);
}

testSLH192Known(t: ref T)
{
	slhkat(t, "slhdsa192s");
}

testSLH256Known(t: ref T)
{
	slhkat(t, "slhdsa256s");
}

# a certificate in the format made before is a signature of the right
# length for the key, and is refused
testSLHOldFormat(t: ref T)
{
	sk := kr->strtosk(readfile(t, "slhdsa192s.sk"));
	if(sk == nil)
		t.fatal("fixture key not read");
	pk := kr->sktopk(sk);
	cert := kr->strtocert(readfile(t, "slhdsa192s.oldcert"));
	if(cert == nil)
		t.fatal("old-format certificate not read");
	t.assertseq(cert.sa.name, "slhdsa192s", "old-format certificate's algorithm");
	t.assert(kr->verify(pk, cert, state(MSG)) == 0, "a certificate in the old SLH-DSA format is refused");
}

# ML-DSA certificates made elsewhere in Keyring's format still verify
mldsafix(t: ref T, alg: string)
{
	pk := kr->strtopk(readfile(t, alg + ".pk"));
	if(pk == nil)
		t.fatal(alg + ": fixture key not read");
	cert := kr->strtocert(readfile(t, alg + ".cert"));
	if(cert == nil)
		t.fatal(alg + ": fixture certificate not read");
	checkcert(t, alg, pk, cert);
}

testMLDSA65Fixture(t: ref T)
{
	mldsafix(t, "mldsa65");
}

testMLDSA87Fixture(t: ref T)
{
	mldsafix(t, "mldsa87");
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

testMLDSA65Generated(t: ref T)
{
	generated(t, "mldsa65");
}

testMLDSA87Generated(t: ref T)
{
	generated(t, "mldsa87");
}

# slhdsa192s only: a signature takes seconds, and slhdsa_test generates both
testSLH192Generated(t: ref T)
{
	generated(t, "slhdsa192s");
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

	run("SLH192Known", testSLH192Known);
	run("SLH256Known", testSLH256Known);
	run("SLHOldFormat", testSLHOldFormat);
	run("MLDSA65Fixture", testMLDSA65Fixture);
	run("MLDSA87Fixture", testMLDSA87Fixture);
	run("MLDSA65Generated", testMLDSA65Generated);
	run("MLDSA87Generated", testMLDSA87Generated);
	run("SLH192Generated", testSLH192Generated);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
