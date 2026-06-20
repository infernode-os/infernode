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

# Every spawned proc self-reports its pid first, so the parent can kill
# stragglers.  A proc left blocked (on a pipe read after a stalled handshake,
# or in a long sleep) keeps the emu from ever exiting — every Dis proc must
# terminate before cleanexit.  On CI that leak surfaced as a hang or a stray
# "process dis faults" at teardown right after the suite PASSed (INFR-303).
killpid(pid: int)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, pidc: chan of int, c: chan of ref Result)
{
	pidc <-= sys->pctl(0, nil);
	(owner, secret) := kr->auth(fd, ai, 0);
	c <-= ref Result(owner, secret);
}

# Sleep in slices, polling a cancel channel: a "kill" via #p/n/ctl does not
# interrupt a proc blocked in the host nanosleep on macOS (swiproc's
# host-syscall interrupt path is a no-op there), so a plain sleep(ms) would
# always run to completion and delay emu exit by the full timeout.
timerproc(cancel: chan of int, c: chan of int, ms: int)
{
	for(elapsed := 0; elapsed < ms; elapsed += 100){
		sys->sleep(100);
		alt {
		<-cancel =>
			return;
		* =>
			;
		}
	}
	c <-= 1;
}

# kr->auth on both ends of a fresh pipe; returns both Results, or (nil,nil) on timeout
runHandshake(t: ref T, a, b: ref Keyring->Authinfo, ms: int): (ref Result, ref Result)
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));
	pidc := chan[1] of int;
	# Buffered result/timeout/cancel chans: a proc that finishes after we
	# have stopped listening must not block forever on the send.
	ca := chan[1] of ref Result;
	cb := chan[1] of ref Result;
	tmo := chan[1] of int;
	cancel := chan[1] of int;
	spawn authproc(fds[0], a, pidc, ca);
	pida := <-pidc;
	spawn authproc(fds[1], b, pidc, cb);
	pidb := <-pidc;
	spawn timerproc(cancel, tmo, ms);
	fds = nil;	# only the authprocs hold the pipe ends now
	ra, rb: ref Result;
	for(got := 0; got < 2;){
		alt {
		r := <-ca => ra = r; got++;
		r := <-cb => rb = r; got++;
		<-tmo =>
			# Stalled handshake: kill the blocked authprocs so the
			# leak doesn't pin the emu open; the caller reports the
			# stall as a test failure.
			killpid(pida);
			killpid(pidb);
			return (nil, nil);
		}
	}
	cancel <-= 1;	# stop the timer so its sleep doesn't delay emu exit
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

	pidc := chan[1] of int;
	cr := chan[1] of ref Result;
	spawn authproc(fds[0], alice, pidc, cr);
	pida := <-pidc;
	tmo := chan[1] of int;
	cancel := chan[1] of int;
	spawn timerproc(cancel, tmo, 15000);
	fds = nil;	# the reflector unblocks via pipe close when authproc goes away

	alt {
	r := <-cr =>
		cancel <-= 1;
		t.assert(r.secret == nil, "a reflected handshake must NOT yield a session secret");
		t.assert(contains(r.owner, "replay"),
			sys->sprint("reflection rejected as a replay (got %q)", r.owner));
	<-tmo =>
		killpid(pida);
		t.fatal("peer hung on a reflected handshake");
	}
}

# ---- CorruptedCert -------------------------------------------------------

# Corrupt a serialised certificate so its signature no longer verifies, while
# keeping it parseable.  Flip the last TWO base64 characters, to a character
# that differs in its high bits.
#
# Flipping a *single* trailing character (e.g. A<->B, which differ only in
# bit 0) is not reliable: the final 6-bit base64 group is only partially
# significant when the signature's byte length is not a multiple of 3, so the
# flipped bit can decode to nothing.  The signature bytes are then unchanged,
# the certificate stays valid, and the test sees a false negative for ~20-25%
# of random signing keys (the rate at which the final group lands on padding
# bits).  Corrupting two adjacent significant characters guarantees the
# decoded signature changes regardless of the final group's byte alignment.
corruptB64(s: string): string
{
	a := array of byte s;
	flipped := 0;
	for(i := len a - 1; i >= 0 && flipped < 2; i--){
		c := int a[i];
		isb64 := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
			 (c >= '0' && c <= '9') || c == '+' || c == '/';
		if(isb64){
			if(c == 'A')
				a[i] = byte 'V';
			else
				a[i] = byte 'A';
			flipped++;
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
