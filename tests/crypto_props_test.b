implement CryptoPropsTest;

#
# Cryptographic-property tests for the node auth handshake -- the security
# guarantees the protocol is supposed to provide, asserted directly:
#
#   - SecretUniqueness   two handshakes with the SAME certificates derive
#                        DIFFERENT 64-byte session secrets (ephemeral DH +
#                        ML-KEM => a forward-secrecy proxy: a reused long-term
#                        key never yields a reused session key), and both peers
#                        independently agree on the same secret each time
#   - ReplayRejected     a reflection (the peer's own alpha**r0 echoed back as
#                        the response) is caught by the protocol's replay check
#                        ("possible replay attack"), not turned into a session
#   - CorruptedCert      a single flipped byte in an otherwise-valid identity
#                        certificate's signature is rejected ("pk doesn't match
#                        certificate"); the handshake fails closed
#
# Runs over pipes; each case has a timeout safety net.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

include "testing.m";
	testing: Testing;
	T: import testing;

CryptoPropsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/crypto_props_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

byteseq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

allzero(a: array of byte): int
{
	for(i := 0; i < len a; i++)
		if(a[i] != byte 0)
			return 0;
	return 1;
}

contains(hay, needle: string): int
{
	n := len needle;
	if(n == 0)
		return 1;
	for(i := 0; i + n <= len hay; i++)
		if(hay[i:i+n] == needle)
			return 1;
	return 0;
}

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");
	ai := ref Keyring->Authinfo;
	ai.mysk = sk; ai.mypk = pk; ai.cert = cert;
	ai.spk = signerpk; ai.alpha = alpha; ai.p = p;
	return ai;
}

newsigner(t: ref T): (ref Keyring->SK, ref Keyring->PK)
{
	sk := kr->genSK("ed25519", "props-signer", 0);
	if(sk == nil)
		t.fatal(sys->sprint("genSK signer: %r"));
	return (sk, kr->sktopk(sk));
}

dhgroup(t: ref T): (ref Keyring->IPint, ref Keyring->IPint)
{
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");
	return (alpha, p);
}

Result: adt {
	owner:	string;
	secret:	array of byte;
};

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of ref Result)
{
	(owner, secret) := kr->auth(fd, ai, 0);
	c <-= ref Result(owner, secret);
}

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# kr->auth on both ends of a fresh pipe; returns both Results, or (nil,nil) on timeout
runHandshake(t: ref T, a, b: ref Keyring->Authinfo, ms: int): (ref Result, ref Result)
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));
	ca := chan of ref Result;
	cb := chan of ref Result;
	tmo := chan of int;
	spawn authproc(fds[0], a, ca);
	spawn authproc(fds[1], b, cb);
	spawn timerproc(tmo, ms);
	ra, rb: ref Result;
	for(got := 0; got < 2;){
		alt {
		r := <-ca => ra = r; got++;
		r := <-cb => rb = r; got++;
		<-tmo => return (nil, nil);
		}
	}
	return (ra, rb);
}

# ---- SecretUniqueness ----------------------------------------------------

testSecretUniqueness(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	alice := mkauthinfo(sk, pk, alpha, p, "alice");
	bob := mkauthinfo(sk, pk, alpha, p, "bob");

	(a1, b1) := runHandshake(t, alice, bob, 15000);
	if(a1 == nil || b1 == nil)
		t.fatal("handshake 1 hung (timeout)");
	(a2, b2) := runHandshake(t, alice, bob, 15000);
	if(a2 == nil || b2 == nil)
		t.fatal("handshake 2 hung (timeout)");

	if(a1.secret == nil || b1.secret == nil || a2.secret == nil || b2.secret == nil)
		t.fatal("a handshake failed to derive a secret");

	t.asserteq(len a1.secret, 64, "session secret is 64 bytes (SHA3-512)");
	t.assert(!allzero(a1.secret), "session secret is non-zero");
	t.assert(byteseq(a1.secret, b1.secret), "run 1: both peers derive the same secret");
	t.assert(byteseq(a2.secret, b2.secret), "run 2: both peers derive the same secret");
	t.assert(!byteseq(a1.secret, a2.secret),
		"two handshakes with the same certs derive DIFFERENT secrets (ephemeral key agreement)");
}

# ---- ReplayRejected ------------------------------------------------------

# Echo everything the peer sends straight back to it, so its own alpha**r0
# returns as the "response".  A read-blocked echo over a full-duplex pipe end.
reflector(fd: ref Sys->FD, done: chan of int)
{
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		if(sys->write(fd, buf[0:n], n) != n)
			break;
	}
	done <-= 1;
}

testReplayRejected(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	alice := mkauthinfo(sk, pk, alpha, p, "alice");

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	rdone := chan[1] of int;
	spawn reflector(fds[1], rdone);

	cr := chan of ref Result;
	spawn authproc(fds[0], alice, cr);
	tmo := chan of int;
	spawn timerproc(tmo, 15000);

	alt {
	r := <-cr =>
		t.assert(r.secret == nil, "a reflected handshake must NOT yield a session secret");
		t.assert(contains(r.owner, "replay"),
			sys->sprint("reflection rejected as a replay (got %q)", r.owner));
	<-tmo =>
		t.fatal("peer hung on a reflected handshake");
	}
}

# ---- CorruptedCert -------------------------------------------------------

# Flip the last base64 character of a serialised certificate to a different
# valid base64 character: keeps the structure parseable but changes the
# decoded signature bytes, so verification must fail.
corruptB64(s: string): string
{
	a := array of byte s;
	for(i := len a - 1; i >= 0; i--){
		c := int a[i];
		isb64 := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			 (c >= '0' && c <= '9') || c == '+' || c == '/';
		if(isb64){
			if(c == 'A')
				a[i] = byte 'B';
			else
				a[i] = byte 'A';
			return string a;
		}
	}
	return string a;
}

testCorruptedCert(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	alice := mkauthinfo(sk, pk, alpha, p, "alice");
	bob := mkauthinfo(sk, pk, alpha, p, "bob");

	# corrupt bob's identity certificate signature, keeping it parseable
	cs := kr->certtostr(bob.cert);
	bad := kr->strtocert(corruptB64(cs));
	if(bad == nil)
		t.fatal("strtocert of the corrupted cert returned nil (corruption broke parsing, not the test intent)");
	bob.cert = bad;

	(ra, rb) := runHandshake(t, alice, bob, 15000);
	if(ra == nil || rb == nil)
		t.fatal("handshake hung (timeout)");

	# alice verifies bob's (corrupted) cert against the trusted signer key and
	# must reject it; the handshake fails closed.
	t.assert(ra.secret == nil, "a one-byte-corrupted certificate is rejected (no secret derived)");
	t.assert(contains(ra.owner, "certificate") || contains(ra.owner, "match"),
		sys->sprint("rejection cites the bad certificate (got %q)", ra.owner));
}

# ---- entry point ---------------------------------------------------------

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;
	if(sys == nil || kr == nil || testing == nil)
		raise "fail:cannot load core modules";
	if(auth != nil)
		auth->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("SecretUniqueness", testSecretUniqueness);
	run("ReplayRejected", testReplayRejected);
	run("CorruptedCert", testCorruptedCert);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
