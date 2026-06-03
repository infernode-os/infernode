implement PQAuthTest;

#
# Tests for the hybrid post-quantum native authentication handshake
# (Keyring->auth, the Station-to-Station protocol in libinterp/keyring.c).
#
# Protocol v2 combines classical Diffie-Hellman with a mutual ML-KEM-768
# key encapsulation; the session secret returned to the caller (and fed to
# the ssl device for 9P line encryption) is
#
#     SHA3-256("infernode-pq-sts-v2" || dh || kem_lo || kem_hi || ek_lo || ek_hi)
#
# Both peers run identical code, so the test runs auth() on both ends of a
# pipe and asserts they mutually authenticate and derive the SAME 32-byte
# secret.  This is the end-to-end proof that two InferNodes negotiate a
# quantum-safe session key over their native transport.
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

PQAuthTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/pqauth_test.b";

passed := 0;
failed := 0;
skipped := 0;

# result of one side of the handshake, passed back over a channel
Result: adt {
	owner:	string;
	secret:	array of byte;
	err:	string;
};

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

# Build an Authinfo for `name`, certified by the given signer, sharing the
# DH group (alpha, p).  Mirrors appl/cmd/auth/mkauthinfo.b.
mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");

	ai := ref Keyring->Authinfo;
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}

# one side of the handshake, run in a spawned proc
authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of ref Result)
{
	(owner, secret) := kr->auth(fd, ai, 0);
	r := ref Result;
	if(secret == nil)
		r.err = owner;
	else {
		r.owner = owner;
		r.secret = secret;
	}
	c <-= r;
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

testHandshake(t: ref T)
{
	# shared signer that certifies both identities
	signersk := kr->genSK("ed25519", "test-signer", 0);
	if(signersk == nil)
		t.fatal("genSK signer failed");
	signerpk := kr->sktopk(signersk);

	# shared DH group; 2048 is precomputed (RFC 3526), so this is fast
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");

	alice := mkauthinfo(signersk, signerpk, alpha, p, "alice");
	bob := mkauthinfo(signersk, signerpk, alpha, p, "bob");

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	c := chan of ref Result;
	spawn authproc(fds[1], bob, c);

	# this proc plays alice; the spawned proc plays bob
	(cowner, csecret) := kr->auth(fds[0], alice, 0);
	sr := <-c;

	# both sides must succeed
	if(csecret == nil)
		t.fatal("client (alice) auth failed: " + cowner);
	if(sr.err != nil)
		t.fatal("server (bob) auth failed: " + sr.err);

	# each side learns the other's authenticated identity
	t.assertseq(cowner, "bob", "alice authenticates bob");
	t.assertseq(sr.owner, "alice", "bob authenticates alice");

	# the derived secret is the 64-byte SHA3-512 hybrid output
	t.asserteq(len csecret, 64, "alice secret is 64 bytes (SHA3-512)");
	t.asserteq(len sr.secret, 64, "bob secret is 64 bytes (SHA3-512)");

	# and, crucially, both sides derive the IDENTICAL session key
	t.assert(byteseq(csecret, sr.secret), "both peers derive the same hybrid session secret");

	t.log(sys->sprint("hybrid session secret: %s", hex(csecret)));
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

readn(fd: ref Sys->FD, buf: array of byte, n: int): int
{
	tot := 0;
	while(tot < n){
		m := sys->read(fd, buf[tot:], n - tot);
		if(m <= 0)
			break;
		tot += m;
	}
	return tot;
}

# server end of a real auth + ssl connection: authenticate, then read
# `expect` bytes off the encrypted channel and hand them back.
serverside(fd: ref Sys->FD, ai: ref Keyring->Authinfo, expect: int,
		rc: chan of (array of byte, string))
{
	(sfd, serr) := auth->server(nil, ai, fd, 0);
	if(sfd == nil){
		rc <-= (nil, "server auth+ssl failed: " + serr);
		return;
	}
	buf := array[expect] of byte;
	n := readn(sfd, buf, expect);
	if(n != expect){
		rc <-= (nil, sys->sprint("short read on encrypted channel: %d != %d", n, expect));
		return;
	}
	rc <-= (buf, nil);
}

# Full end-to-end: two peers run the real Inferno auth handshake (now hybrid
# PQ) and then push the ssl device keyed by the derived secret, exactly as
# styxlisten -A / 9P transport do.  Data written by the client must arrive
# intact at the server, proving the hybrid-derived key keys a working
# encrypted channel.
testEncryptedChannel(t: ref T)
{
	if(auth == nil)
		t.fatal("auth module not loaded");
	if((e := auth->init()) != nil)
		t.fatal("auth init failed: " + e);

	signersk := kr->genSK("ed25519", "test-signer", 0);
	if(signersk == nil)
		t.fatal("genSK signer failed");
	signerpk := kr->sktopk(signersk);

	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");

	alice := mkauthinfo(signersk, signerpk, alpha, p, "alice");
	bob := mkauthinfo(signersk, signerpk, alpha, p, "bob");

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	msg := array of byte "9P-over-hybrid-PQC: the quick brown fox authenticates the lazy node";

	rc := chan of (array of byte, string);
	spawn serverside(fds[1], bob, len msg, rc);

	# client authenticates (hybrid PQ) and gets the ssl-wrapped fd
	(cfd, cerr) := auth->client("aes_256_cbc sha256", alice, fds[0]);
	if(cfd == nil)
		t.fatal("client auth+ssl failed: " + cerr);

	# write plaintext; the ssl device encrypts it with the hybrid key
	if(sys->write(cfd, msg, len msg) != len msg)
		t.fatal(sys->sprint("encrypted write failed: %r"));

	(got, serr) := <-rc;
	if(serr != nil)
		t.fatal(serr);

	t.asserteq(len got, len msg, "bytes received over encrypted channel");
	t.assert(byteseq(got, msg), "plaintext survives AES-256 round-trip keyed by the hybrid PQ secret");
	t.log("9P-style payload decrypted intact over hybrid-keyed ssl channel");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(kr == nil) {
		sys->fprint(sys->fildes(2), "cannot load keyring module: %r\n");
		raise "fail:cannot load keyring";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("HybridAuthHandshake", testHandshake);
	run("HybridEncryptedChannel", testEncryptedChannel);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
