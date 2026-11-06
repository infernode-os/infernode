implement KeyringSaSwapTest;

#
# A key, signature or certificate is used with the algorithm it was
# made with, whatever its sa field says.
#
# SK, PK and Certificate's sa is a field Limbo can assign
# (sk.sa = otherkey.sa). keyring's C took the algorithm from it, so an
# ed25519 SK given an RSA SigAlg had its ed25519 key handed to RSA's
# sign, sk2pk and sk2str, an ed25519 certificate's signature to RSA's
# sig2str, an RSA public key to ed25519's verify (AddressSanitizer: a
# heap-buffer-overflow read), and the collector freed the key with the
# other algorithm's free. A SigAlg Limbo made itself (ref SigAlg("rsa"))
# had its hidden algorithm read from past its block.
#
# Now each object keeps the algorithm it was made with, and one whose
# sa is not a genuine SigAlg of that algorithm is refused with an
# exception, not used. Another SigAlg of the same algorithm is fine. A
# certificate checked against a public key of another algorithm is not
# that key's signature: verify says 0, as it did.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint, SK, PK, Certificate, SigAlg, Authinfo: import kr;

include "testing.m";
	testing: Testing;
	T: import testing;

KeyringSaSwapTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_sa_swap_test.b";

# what keyring raises (libinterp/keyring.c: exType with exSAMismatch, exBadSA)
NOTKEYS: con "type not constructed correctly: signature algorithm is not the key's";
BADSA: con "type not constructed correctly: bad signature algorithm";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# keys made once: RSA's generation is the slow part
edsk, edsk2, rsask: ref SK;
edpk, rsapk: ref PK;

msg: con "a message to be signed";

newkeys()
{
	edsk = kr->genSK("ed25519", "ed", 256);
	edsk2 = kr->genSK("ed25519", "ed2", 256);
	rsask = kr->genSK("rsa", "rsa", 1024);
	if(edsk == nil || edsk2 == nil || rsask == nil)
		return;
	edpk = kr->sktopk(edsk);
	rsapk = kr->sktopk(rsask);
}

# a fresh ed25519 SK, its sa still its own
fresh(): ref SK
{
	return kr->strtosk(kr->sktostr(edsk));
}

ipmsg(): ref IPint
{
	return IPint.inttoip(16r1234567);
}

edcert(): ref Certificate
{
	return kr->signm(edsk, ipmsg(), "sha256");
}

digest(): ref Keyring->DigestState
{
	b := array of byte msg;
	return kr->sha256(b, len b, nil, nil);
}

#
# op names one use of an SK, PK or Certificate; it is made, and what it
# raised returned ("" when it returned).
#
tryop(op: string, sk: ref SK, pk: ref PK, c: ref Certificate): string
{
	{
		case op {
		"signm" =>
			kr->signm(sk, ipmsg(), "sha256");
		"sign" =>
			kr->sign(sk, 0, digest(), "sha256");
		"sktopk" =>
			kr->sktopk(sk);
		"sktostr" =>
			kr->sktostr(sk);
		"sktoattr" =>
			kr->sktoattr(sk);
		"genSKfromPK" =>
			kr->genSKfromPK(pk, "x");
		"pktostr" =>
			kr->pktostr(pk);
		"pktoattr" =>
			kr->pktoattr(pk);
		"verifym" =>
			kr->verifym(pk, c, ipmsg());
		"verify" =>
			kr->verify(pk, c, digest());
		"certtostr" =>
			kr->certtostr(c);
		"certtoattr" =>
			kr->certtoattr(c);
		"writeauthinfo" =>
			ai := ref Authinfo(sk, pk, c, pk, IPint.inttoip(2), IPint.inttoip(23));
			kr->writeauthinfo("/tmp/keyring_sa_swap_test.authinfo", ai);
		* =>
			return "no op " + op;
		}
	} exception e {
	"*" =>
		return e;
	}
	return "";
}

refused(t: ref T, op: string, sk: ref SK, pk: ref PK, c: ref Certificate, want: string)
{
	got := tryop(op, sk, pk, c);
	if(got == "")
		t.error(op + ": used, not refused");
	else
		t.assertseq(got, want, op + " refused");
}

# an ed25519 SK labelled RSA is refused by everything taking an SK
testSKSwapped(t: ref T)
{
	sk := fresh();
	sk.sa = rsask.sa;
	for(ops := "signm" :: "sign" :: "sktopk" :: "sktostr" :: "sktoattr" :: "writeauthinfo" :: nil; ops != nil; ops = tl ops)
		refused(t, hd ops, sk, edpk, edcert(), NOTKEYS);

	# and an RSA SK labelled ed25519
	rsk := kr->strtosk(kr->sktostr(rsask));
	rsk.sa = edsk.sa;
	refused(t, "signm", rsk, nil, nil, NOTKEYS);
	refused(t, "sktopk", rsk, nil, nil, NOTKEYS);
}

# a PK labelled with another algorithm is refused, alone or against a certificate
testPKSwapped(t: ref T)
{
	pk := kr->strtopk(kr->pktostr(rsapk));
	pk.sa = edsk.sa;
	c := edcert();
	for(ops := "genSKfromPK" :: "pktostr" :: "pktoattr" :: "verifym" :: "verify" :: nil; ops != nil; ops = tl ops)
		refused(t, hd ops, nil, pk, c, NOTKEYS);
}

# a certificate labelled with another algorithm is refused
testCertSwapped(t: ref T)
{
	c := edcert();
	c.sa = rsask.sa;
	refused(t, "certtostr", nil, nil, c, NOTKEYS);
	refused(t, "certtoattr", nil, nil, c, NOTKEYS);
	refused(t, "verifym", nil, edpk, c, NOTKEYS);
	refused(t, "verify", nil, edpk, c, NOTKEYS);
	# with a PK of the algorithm it claims
	refused(t, "verifym", nil, rsapk, c, NOTKEYS);
}

# a SigAlg Limbo made, or none, is no algorithm
testNotSigAlg(t: ref T)
{
	sk := fresh();
	sk.sa = ref SigAlg("rsa");
	refused(t, "signm", sk, nil, nil, BADSA);
	refused(t, "sktostr", sk, nil, nil, BADSA);
	sk.sa = nil;
	refused(t, "signm", sk, nil, nil, BADSA);
	refused(t, "sktopk", sk, nil, nil, BADSA);

	pk := kr->strtopk(kr->pktostr(edpk));
	pk.sa = ref SigAlg("ed25519");
	refused(t, "verifym", nil, pk, edcert(), BADSA);
	c := edcert();
	c.sa = nil;
	refused(t, "certtostr", nil, nil, c, BADSA);
}

# another SigAlg of the key's own algorithm is the key's algorithm
testSameAlg(t: ref T)
{
	sk := fresh();
	sk.sa = edsk2.sa;
	t.assertseq(tryop("signm", sk, nil, nil), "", "signm with another ed25519 SigAlg");
	c := kr->signm(sk, ipmsg(), "sha256");
	t.assert(c != nil, "signed");
	pk := kr->sktopk(sk);
	t.assert(pk != nil, "sktopk");
	t.asserteq(kr->verifym(pk, c, ipmsg()), 1, "its own signature verifies");
	t.asserteq(kr->verifym(edpk, c, ipmsg()), 1, "the key's original PK verifies it");

	# a swapped key given back its own algorithm is usable again
	sk.sa = rsask.sa;
	refused(t, "signm", sk, nil, nil, NOTKEYS);
	sk.sa = edsk.sa;
	t.assertseq(tryop("signm", sk, nil, nil), "", "signm with its own SigAlg back");
}

# a certificate of one algorithm checked against a genuine key of another is 0, not an error
testOtherAlgVerify(t: ref T)
{
	c := edcert();
	t.asserteq(kr->verifym(edpk, c, ipmsg()), 1, "ed25519 signature, ed25519 key");
	t.asserteq(kr->verifym(rsapk, c, ipmsg()), 0, "ed25519 signature, RSA key");
	t.asserteq(kr->verify(rsapk, c, digest()), 0, "ed25519 signature, RSA key (verify)");
	rc := kr->signm(rsask, ipmsg(), "sha256");
	t.asserteq(kr->verifym(edpk, rc, ipmsg()), 0, "RSA signature, ed25519 key");
}

# the collector frees a swapped key with its own algorithm's free
testSwappedFreed(t: ref T)
{
	for(i := 0; i < 50; i++){
		sk := fresh();
		sk.sa = rsask.sa;
		pk := kr->strtopk(kr->pktostr(rsapk));
		pk.sa = edsk.sa;
		c := edcert();
		c.sa = rsask.sa;
		sk = nil;
		pk = nil;
		c = nil;
	}
	# the module is still there and working
	t.assertseq(tryop("signm", fresh(), nil, nil), "", "signing after freeing swapped keys");
}

# auth with a swapped key says so through its result: no exception, no use
testAuthSwapped(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sk := fresh();
	sk.sa = rsask.sa;
	c := kr->signm(rsask, ipmsg(), "sha256");
	ai := ref Authinfo(sk, edpk, c, rsapk, IPint.inttoip(2), IPint.inttoip(23));

	mine := chan of string;
	theirs := chan of string;
	spawn authproc(p[0], ai, mine);
	spawn authproc(p[1], nil, theirs);
	timeout := chan of int;
	spawn timer(timeout, 30000);
	got := 0;
	while(got < 2){
		alt {
		r := <-mine =>
			got++;
			t.assertseq(r, "error: bad sk arg", "auth with a swapped SK");
		<-theirs =>
			got++;
		<-timeout =>
			t.fatal("auth did not finish");
		}
	}
}

authproc(fd: ref Sys->FD, ai: ref Authinfo, r: chan of string)
{
	{
		(err, secret) := kr->auth(fd, ai, 0);
		if(secret != nil)
			r <-= "secret agreed";
		else
			r <-= "error: " + err;
	} exception e {
	"*" =>
		r <-= "exception: " + e;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	if(kr == nil) {
		sys->fprint(sys->fildes(2), "cannot load Keyring: %r\n");
		raise "fail:cannot load Keyring";
	}
	newkeys();
	if(edsk == nil || rsask == nil || edpk == nil || rsapk == nil) {
		sys->fprint(sys->fildes(2), "cannot make the test's keys\n");
		raise "fail:no keys";
	}

	run("SKSwapped", testSKSwapped);
	run("PKSwapped", testPKSwapped);
	run("CertSwapped", testCertSwapped);
	run("NotSigAlg", testNotSigAlg);
	run("SameAlg", testSameAlg);
	run("OtherAlgVerify", testOtherAlgVerify);
	run("SwappedFreed", testSwappedFreed);
	run("AuthSwapped", testAuthSwapped);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
