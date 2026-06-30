implement PQAuthTest;

#
# Tests for the hybrid post-quantum native authentication handshake
# (Keyring->auth, the Station-to-Station protocol in libinterp/keyring.c).
#
# Protocol v2 combines classical Diffie-Hellman with a mutual ML-KEM-768
# key encapsulation; the session secret returned to the caller (and fed to
# the ssl device for 9P line encryption) is
#
#     SHA3-512("infernode-pq-sts-v2" || dh || kem_lo || kem_hi || ek_lo || ek_hi)
#
# Coverage:
#   - HybridAuthHandshake        happy path, ed25519 signer
#   - HybridHandshakeMLDSA        fully post-quantum (ML-DSA-65 signer + ML-KEM)
#   - HybridEncryptedChannel      real Auth->client/server + ssl data round-trip (pipe)
#   - HybridTcpChannel            same, over a real TCP connection (skips w/o network)
#   - DowngradeRejected           a v1 (classical-only) peer is refused
#   - TamperedEkRejected          a flipped byte in an ML-KEM public key fails the handshake
#   - MalformedEkRejected         a wrong-length ML-KEM public key is rejected
#
# The negative cases use a configurable man-in-the-middle relay between two
# real auth() endpoints, parsing the wire framing (5-byte "%4.4d\n" header).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

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

# man-in-the-middle relay corruption modes
Clean, FlipByte, Truncate, Replace: con iota;

# frame indices in the client->server direction
# (0=version, 1=alpha**r0, 2=cert, 3=pubkey, 4=ml-kem ek)
VERFRAME: con 0;
DHFRAME: con 1;		# the peer's DH public value (validated in keyring.c)
EKFRAME: con 4;

# payload substituted into the corrupted frame in Replace mode
replacement: array of byte;

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

# ---- helpers -------------------------------------------------------------

byteseq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
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

# strstr: does haystack contain needle?
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

# Create a signer and a mutually-trusting pair (alice, bob) using the given
# signer key algorithm.
setupPair(t: ref T, signeralg: string, bits: int): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	signersk := kr->genSK(signeralg, "test-signer", bits);
	if(signersk == nil)
		t.fatal("genSK signer (" + signeralg + ") failed");
	signerpk := kr->sktopk(signersk);

	(alpha, p) := kr->dhparams(2048);	# 2048 is precomputed (RFC 3526), fast
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");

	alice := mkauthinfo(signersk, signerpk, alpha, p, "alice");
	bob := mkauthinfo(signersk, signerpk, alpha, p, "bob");
	return (alice, bob);
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

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# collect a spawned peer's result with a timeout safety net.
# returns (result, ok); ok=0 means it timed out (the peer hung).
collect(cb: chan of ref Result, ms: int): (ref Result, int)
{
	tmo := chan[1] of int;
	spawn timerproc(tmo, ms);
	alt {
	r := <-cb =>
		return (r, 1);
	<-tmo =>
		return (nil, 0);
	}
}

joinpump(done: chan of int, ms: int): int
{
	tmo := chan[1] of int;
	spawn timerproc(tmo, ms);
	alt {
	<-done =>
		return 1;
	<-tmo =>
		return 0;
	}
}

# ---- happy-path tests ----------------------------------------------------

handshakeOK(t: ref T, signeralg: string, bits: int)
{
	(alice, bob) := setupPair(t, signeralg, bits);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	cb := chan of ref Result;
	spawn authproc(fds[1], bob, cb);
	(aowner, asecret) := kr->auth(fds[0], alice, 0);	# alice runs in main
	rb := <-cb;

	if(asecret == nil)
		t.fatal("alice auth failed: " + aowner);
	if(rb.secret == nil)
		t.fatal("bob auth failed: " + rb.err);

	t.assertseq(aowner, "bob", "alice authenticates bob");
	t.assertseq(rb.owner, "alice", "bob authenticates alice");
	t.asserteq(len asecret, 64, "alice secret is 64 bytes (SHA3-512)");
	t.asserteq(len rb.secret, 64, "bob secret is 64 bytes (SHA3-512)");
	t.assert(byteseq(asecret, rb.secret), "both peers derive the same hybrid session secret");
	t.log(sys->sprint("%s signer: hybrid secret %s", signeralg, hex(asecret)));
}

testHandshake(t: ref T)
{
	handshakeOK(t, "ed25519", 0);
}

testHandshakeMLDSA(t: ref T)
{
	# ML-DSA-65 signer + ML-KEM-768 KEM = a fully post-quantum handshake
	handshakeOK(t, "mldsa65", 0);
}

# ---- encrypted-channel tests (real Auth->client/server + ssl) ------------

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

# drive the real auth handshake (now hybrid PQ) then push ssl keyed by the
# derived secret, exactly as styxlisten -A / 9P transport do, and confirm a
# 9P-style payload survives the encrypted channel.
encryptedRoundtrip(t: ref T, cfd, sfdForServer: ref Sys->FD,
		alice, bob: ref Keyring->Authinfo)
{
	msg := array of byte "9P-over-hybrid-PQC: the quick brown fox authenticates the lazy node";

	rc := chan of (array of byte, string);
	spawn serverside(sfdForServer, bob, len msg, rc);

	(wrapped, cerr) := auth->client("aes_256_cbc sha256", alice, cfd);
	if(wrapped == nil)
		t.fatal("client auth+ssl failed: " + cerr);
	if(sys->write(wrapped, msg, len msg) != len msg)
		t.fatal(sys->sprint("encrypted write failed: %r"));

	(got, serr) := <-rc;
	if(serr != nil)
		t.fatal(serr);
	t.asserteq(len got, len msg, "bytes received over encrypted channel");
	t.assert(byteseq(got, msg), "plaintext survives AES-256 round-trip keyed by the hybrid PQ secret");
}

testEncryptedChannel(t: ref T)
{
	if(auth == nil || (e := auth->init()) != nil)
		t.fatal("auth init failed");
	(alice, bob) := setupPair(t, "ed25519", 0);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));
	encryptedRoundtrip(t, fds[0], fds[1], alice, bob);
	t.log("9P-style payload decrypted intact over hybrid-keyed ssl channel (pipe)");
}

tcpserver(ac: Sys->Connection, ai: ref Keyring->Authinfo, expect: int,
		rc: chan of (array of byte, string))
{
	(lok, nc) := sys->listen(ac);
	if(lok < 0){
		rc <-= (nil, sys->sprint("listen failed: %r"));
		return;
	}
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		rc <-= (nil, sys->sprint("open data failed: %r"));
		return;
	}
	serverside(dfd, ai, expect, rc);
}

testTcpChannel(t: ref T)
{
	if(auth == nil || (e := auth->init()) != nil)
		t.fatal("auth init failed");

	addr := "tcp!127.0.0.1!19897";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}

	(alice, bob) := setupPair(t, "ed25519", 0);

	msg := array of byte "9P-over-hybrid-PQC across a real TCP socket";
	rc := chan of (array of byte, string);
	spawn tcpserver(ac, bob, len msg, rc);

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		t.skip(sys->sprint("dial failed (no loopback?): %r"));
		return;
	}

	(wrapped, cerr) := auth->client("aes_256_cbc sha256", alice, dc.dfd);
	if(wrapped == nil)
		t.fatal("client auth+ssl over tcp failed: " + cerr);
	if(sys->write(wrapped, msg, len msg) != len msg)
		t.fatal(sys->sprint("encrypted write over tcp failed: %r"));

	(got, serr) := <-rc;
	if(serr != nil)
		t.fatal(serr);
	t.asserteq(len got, len msg, "tcp: bytes received over encrypted channel");
	t.assert(byteseq(got, msg), "9P payload round-trips over hybrid-keyed TCP channel");
	t.log("9P-style payload decrypted intact over hybrid-keyed ssl channel (tcp)");
}

# ---- negative / security tests -------------------------------------------

# pump one direction of the wire, optionally corrupting a target frame.
# Frames are: 5-byte header "%4.4d\n" (or "!%3.3d\n" for errors) + payload.
pump(src, dst: ref Sys->FD, mode, target: int, done: chan of int)
{
	idx := 0;
	for(;;){
		hdr := array[5] of byte;
		if(readn(src, hdr, 5) != 5)
			break;
		neg := (hdr[0] == byte '!');
		ns: string;
		if(neg)
			ns = string hdr[1:4];
		else
			ns = string hdr[0:4];
		n := int ns;
		if(n < 0 || n > 9000)
			break;
		payload := array[n] of byte;
		if(n > 0 && readn(src, payload, n) != n)
			break;

		if(!neg && idx == target && mode == Truncate){
			# rewrite the frame with a bogus (too-short) length
			newn := 100;
			nh := array of byte sys->sprint("%4.4d\n", newn);
			sys->write(dst, nh, len nh);
			sys->write(dst, payload[0:newn], newn);
			idx++;
			continue;
		}
		if(!neg && idx == target && mode == Replace){
			# substitute the whole frame payload with an attacker-chosen value
			nh := array of byte sys->sprint("%4.4d\n", len replacement);
			sys->write(dst, nh, len nh);
			if(len replacement > 0)
				sys->write(dst, replacement, len replacement);
			idx++;
			continue;
		}
		if(!neg && idx == target && mode == FlipByte && n > 0)
			payload[0] = byte (int payload[0] ^ 16r01);

		sys->write(dst, hdr, len hdr);
		if(n > 0)
			sys->write(dst, payload, n);
		idx++;
	}
	done <-= 1;
}

# run alice (in main) <-> relay <-> bob, corrupting the client->server EK
# frame.  Returns (alice-result, bob-result-or-nil-if-bob-hung).
relayedHandshake(t: ref T, alice, bob: ref Keyring->Authinfo, mode: int): (ref Result, ref Result)
{
	pa := array[2] of ref Sys->FD;	# alice <-> relay
	pb := array[2] of ref Sys->FD;	# relay <-> bob
	if(sys->pipe(pa) < 0 || sys->pipe(pb) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	cb := chan of ref Result;
	d := chan[2] of int;	# buffered: pumps signal completion without a reader

	spawn authproc(pb[0], bob, cb);			# bob on pb[0]
	spawn pump(pa[1], pb[1], mode, EKFRAME, d);	# alice -> bob (corrupting)
	spawn pump(pb[1], pa[1], Clean, -1, d);		# bob -> alice (clean)
	pb[0] = pa[1] = pb[1] = nil;	# ownership transferred to spawned procs

	(aowner, asecret) := kr->auth(pa[0], alice, 0);	# alice runs in main
	pa[0] = nil;
	ra := ref Result;
	if(asecret == nil)
		ra.err = aowner;
	else {
		ra.owner = aowner;
		ra.secret = asecret;
	}

	(rb, ok) := collect(cb, 20000);
	if(!ok){
		rb = ref Result;
		rb.err = "bob hung";
	}
	if(!joinpump(d, 5000) || !joinpump(d, 5000)){
		rb.secret = nil;
		rb.err = "relay pump hung";
	}
	return (ra, rb);
}

testTamperedEk(t: ref T)
{
	for(iter := 0; iter < 32; iter++){
		(alice, bob) := setupPair(t, "ed25519", 0);
		(ra, rb) := relayedHandshake(t, alice, bob, FlipByte);

		# The EK is bound into the signed transcript, so flipping a byte must
		# break signature verification; neither side may derive a secret.
		t.assert(ra.secret == nil,
			sys->sprint("round %d: alice derives no secret from tampered ek", iter));
		t.assert(rb.secret == nil,
			sys->sprint("round %d: bob derives no secret from tampered ek", iter));
	}
}

testMalformedEk(t: ref T)
{
	(alice, bob) := setupPair(t, "ed25519", 0);
	(nil, rb) := relayedHandshake(t, alice, bob, Truncate);

	# bob reads alice's (truncated) ek and must reject it on length
	t.assert(rb.secret == nil, "bob must reject a wrong-length ML-KEM key");
	t.assert(contains(rb.err, "ml-kem") || contains(rb.err, "length"),
		sys->sprint("bob reports a ml-kem length error (got %q)", rb.err));
}

# write a framed message matching keyring.c's sendmsg ("%4.4d\n" + payload)
sendframe(fd: ref Sys->FD, data: array of byte)
{
	hdr := array of byte sys->sprint("%4.4d\n", len data);
	sys->write(fd, hdr, len hdr);
	if(len data > 0)
		sys->write(fd, data, len data);
}

# a fake peer that speaks classical-only protocol version 1
fakev1peer(fd: ref Sys->FD, done: chan of int)
{
	# the real peer sends its version first; read it
	hdr := array[5] of byte;
	readn(fd, hdr, 5);
	if(int string hdr[0:4] > 0){
		body := array[int string hdr[0:4]] of byte;
		readn(fd, body, len body);
	}
	# claim version "1"; the real (v2) peer will reject.  Then send "OK" so
	# its error-path "read responses" loop terminates cleanly (the protocol
	# ends on an "OK"/error frame, not on fd close -- a ref FD here only
	# shuts on GC, so we must not rely on an implicit hangup).
	sendframe(fd, array of byte "1");
	sendframe(fd, array of byte "OK");
	done <-= 1;
}

testDowngradeRejected(t: ref T)
{
	(alice, nil) := setupPair(t, "ed25519", 0);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	done := chan[1] of int;	# buffered: fake peer signals without a reader
	spawn fakev1peer(fds[1], done);

	# the real (v2) peer runs in main and must reject the v1 claim
	(owner, secret) := kr->auth(fds[0], alice, 0);
	t.assert(secret == nil, "v2 node must refuse a v1 (classical-only) peer");
	t.assert(contains(owner, "incompatible") || contains(owner, "protocol"),
		sys->sprint("downgrade rejected with protocol error (got %q)", owner));
}

# ---- pre-auth DH-share / version validation (INFR-322, INFR-323) ---------

# Substitute the client->server frame `target` with `repl` and return the
# victim (server-side) result. Both peers run in spawned procs collected with
# a timeout, so a regression that crashes the VM or wedges the handshake is
# caught rather than silently passing. target is VERFRAME or DHFRAME.
frameAttack(t: ref T, target: int, repl: array of byte): ref Result
{
	(alice, bob) := setupPair(t, "ed25519", 0);

	pa := array[2] of ref Sys->FD;	# alice <-> relay
	pb := array[2] of ref Sys->FD;	# relay <-> bob
	if(sys->pipe(pa) < 0 || sys->pipe(pb) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	replacement = repl;

	ca := chan of ref Result;
	cb := chan of ref Result;
	d := chan[2] of int;	# buffered: pumps signal without a reader

	spawn authproc(pa[0], alice, ca);		# alice (attacker-relayed client)
	spawn authproc(pb[0], bob, cb);			# bob (victim / server side)
	spawn pump(pa[1], pb[1], Replace, target, d);	# alice -> bob, corrupt `target`
	spawn pump(pb[1], pa[1], Clean, -1, d);		# bob -> alice, clean
	pa[0] = pb[0] = pa[1] = pb[1] = nil;	# ownership transferred

	(rb, ok) := collect(cb, 20000);
	if(!ok){
		rb = ref Result;
		rb.err = "victim hung";
	}
	collect(ca, 5000);	# best-effort drain of the client proc
	if(!joinpump(d, 5000) || !joinpump(d, 5000)){
		rb.secret = nil;
		rb.err = "relay pump hung";
	}
	return rb;
}

# INFR-322: a DH share with no valid base64 digits makes strtomp() return
# nil; pre-fix, mpcmp() then dereferenced nil -> an unauthenticated remote
# crash. The victim must instead reject it cleanly and stay alive.
testMalformedDHShare(t: ref T)
{
	rb := frameAttack(t, DHFRAME, array of byte "!!!!!!!!!!!!!!!!");
	t.assertsne(rb.err, "victim hung",
		"malformed DH share must not crash or hang the server (INFR-322)");
	t.assert(rb.secret == nil, "victim must derive no secret from a malformed DH share");
	t.assert(contains(rb.err, "malformed") || contains(rb.err, "diffie"),
		sys->sprint("server rejects malformed DH share cleanly (got %q)", rb.err));
}

# INFR-323: the weak share 1 lies in [.. <= 1 ..]; pre-fix the validation
# only rejected alphar1 >= p, so 1 slipped through. Must now be "implausible".
testWeakDHShareOne(t: ref T)
{
	one := array of byte IPint.inttoip(1).iptob64();
	rb := frameAttack(t, DHFRAME, one);
	t.assertsne(rb.err, "victim hung", "weak DH share 1 must not hang the server");
	t.assert(rb.secret == nil, "victim must reject DH share 1 (INFR-323)");
	t.assert(contains(rb.err, "implausible"),
		sys->sprint("server rejects weak DH share 1 (got %q)", rb.err));
}

# INFR-323: the share 0 encodes to an empty mpint payload, so it is caught by
# the nil guard rather than the range guard -- either way it must be refused.
testWeakDHShareZero(t: ref T)
{
	zero := array of byte IPint.inttoip(0).iptob64();
	rb := frameAttack(t, DHFRAME, zero);
	t.assertsne(rb.err, "victim hung", "weak DH share 0 must not hang the server");
	t.assert(rb.secret == nil, "victim must reject DH share 0 (INFR-323)");
	t.assert(contains(rb.err, "implausible") || contains(rb.err, "malformed") || contains(rb.err, "diffie"),
		sys->sprint("server rejects weak DH share 0 (got %q)", rb.err));
}

# INFR-322 (additional finding): "2abc" gave atoi()==2 with length 4, which
# slipped past the old `n > 4` length check. The strict parser must require
# exactly "2".
testNonCanonicalVersion(t: ref T)
{
	rb := frameAttack(t, VERFRAME, array of byte "2abc");
	t.assertsne(rb.err, "victim hung", "non-canonical version must not hang the server");
	t.assert(rb.secret == nil, "victim must reject a non-canonical version token");
	t.assert(contains(rb.err, "incompatible") || contains(rb.err, "protocol"),
		sys->sprint("server rejects non-canonical version (got %q)", rb.err));
}

# ---- entry point ---------------------------------------------------------

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
	run("HybridHandshakeMLDSA", testHandshakeMLDSA);
	run("HybridEncryptedChannel", testEncryptedChannel);
	run("HybridTcpChannel", testTcpChannel);
	run("DowngradeRejected", testDowngradeRejected);
	run("TamperedEkRejected", testTamperedEk);
	run("MalformedEkRejected", testMalformedEk);
	run("MalformedDHShareRejected", testMalformedDHShare);
	run("WeakDHShareOneRejected", testWeakDHShareOne);
	run("WeakDHShareZeroRejected", testWeakDHShareZero);
	run("NonCanonicalVersionRejected", testNonCanonicalVersion);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
