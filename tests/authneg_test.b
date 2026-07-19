implement AuthNegTest;

#
# Negative / adversarial node-authentication tests: the native STS handshake
# and the ssl line-encryption it pushes must FAIL CLOSED.  Where pqauth_test
# covers handshake-mechanics negatives (downgrade, tampered/malformed ML-KEM
# key), this covers the trust- and integrity-layer negatives that a real
# node-to-node deployment depends on:
#
#   - UntrustedSigner    peer certificate signed by a different (untrusted)
#                        signer must be rejected ("pk doesn't match certificate")
#   - ExpiredCert        a certificate past its expiry must be rejected
#   - CipherMismatch     a client cipher the server did not offer must be refused
#   - TamperedCiphertext flipping one byte on the encrypted channel must be
#                        detected by the ssl record MAC (read fails), not
#                        delivered as if valid
#
# A NotExpiredSucceeds positive control guards the ExpiredCert case against
# passing for the wrong reason.  Every case asserts the security-relevant
# *failure*, with a timeout safety net so a hang is reported rather than
# wedging the suite.
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

AuthNegTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/authneg_test.b";

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

# ---- helpers -------------------------------------------------------------

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

# Build an Authinfo for `name`, certified by `signersk`/`signerpk`, sharing the
# DH group, with certificate expiry `exp` (0 == never expires).
mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string, exp: int): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, exp, state, "sha256");

	ai := ref Keyring->Authinfo;
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}

newsigner(t: ref T): (ref Keyring->SK, ref Keyring->PK)
{
	sk := kr->genSK("ed25519", "neg-signer", 0);
	if(sk == nil)
		t.fatal(sys->sprint("genSK signer failed: %r"));
	return (sk, kr->sktopk(sk));
}

dhgroup(t: ref T): (ref Keyring->IPint, ref Keyring->IPint)
{
	(alpha, p) := kr->dhparams(2048);	# precomputed RFC 3526, fast
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");
	return (alpha, p);
}

Result: adt {
	owner:	string;
	secret:	array of byte;
};

# INFR-378: emu only reaches cleanexit once every Dis proc has terminated
# (progexit exits when isched.head == nil).  A helper proc left blocked --
# on a reader-less channel send, a pipe read after its peer is gone, or a
# long sleep -- keeps the emu open and races the process-group teardown
# that runs when the test's init() returns.  That leak surfaced as an
# intermittent hang or a stray "process ... faults" at teardown, right
# after the suite had already PASSed (the same failure mode fixed for the
# sibling handshake test crypto_props_test in INFR-303).  The discipline
# that avoids it: spawned procs self-report their pid so stragglers can be
# killed, every result/timeout channel is buffered so a late send never
# blocks, and timers sleep in cancellable slices instead of one long
# uninterruptible nap.  With that in place authneg_test tears down cleanly
# and no longer poisons runner.dis.
killpid(pid: int)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		fd = sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

killpids(pids: list of int)
{
	for(; pids != nil; pids = tl pids)
		killpid(hd pids);
}

rawauthproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, pidc: chan of int, c: chan of ref Result)
{
	pidc <-= sys->pctl(0, nil);
	(owner, secret) := kr->auth(fd, ai, 0);
	c <-= ref Result(owner, secret);
}

# Sleep in slices, polling a cancel channel: a "kill" via #p/n/ctl does not
# interrupt a proc blocked in the host nanosleep on every platform, so a
# plain sleep(ms) would run to completion and delay emu exit by the full
# timeout even after the test is done with it.
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

# Run kr->auth on both ends of a pipe; return both Results, or nil on timeout.
rawHandshake(t: ref T, a, b: ref Keyring->Authinfo, ms: int): (ref Result, ref Result)
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
	spawn rawauthproc(fds[0], a, pidc, ca);
	pida := <-pidc;
	spawn rawauthproc(fds[1], b, pidc, cb);
	pidb := <-pidc;
	spawn timerproc(cancel, tmo, ms);
	fds = nil;	# only the authprocs hold the pipe ends now

	ra, rb: ref Result;
	for(got := 0; got < 2;){
		alt {
		r := <-ca => ra = r; got++;
		r := <-cb => rb = r; got++;
		<-tmo =>
			# Stalled handshake: kill the blocked authprocs so the leak
			# doesn't pin the emu open; the caller reports the stall.
			killpid(pida);
			killpid(pidb);
			return (nil, nil);
		}
	}
	cancel <-= 1;	# stop the timer so its sleep doesn't delay emu exit
	return (ra, rb);
}

# ---- UntrustedSigner -----------------------------------------------------

testUntrustedSigner(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(skA, pkA) := newsigner(t);		# signer A
	(skB, pkB) := newsigner(t);		# signer B (independent / untrusted)

	# client certified by A and trusting A; server certified by B and trusting B.
	# Each verifies the peer's cert with its OWN spk, so neither accepts the
	# other -> no mutual secret.
	client := mkauthinfo(skA, pkA, alpha, p, "client", 0);
	server := mkauthinfo(skB, pkB, alpha, p, "server", 0);

	(rc, rs) := rawHandshake(t, client, server, 15000);
	if(rc == nil || rs == nil)
		t.fatal("handshake hung (timeout)");

	t.assert(rc.secret == nil, "client must NOT trust a peer signed by an unknown signer");
	t.assert(rs.secret == nil, "server must NOT trust a peer signed by an unknown signer");
	t.log(sys->sprint("client rejected with: %s", rc.owner));
	t.log(sys->sprint("server rejected with: %s", rs.owner));
}

# ---- ExpiredCert ---------------------------------------------------------

testExpiredCert(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);		# one shared, trusted signer

	# both identity certs expired in the distant past (epoch secs; 2001-09-09)
	past := 1000000000;
	client := mkauthinfo(sk, pk, alpha, p, "client", past);
	server := mkauthinfo(sk, pk, alpha, p, "server", past);

	(rc, rs) := rawHandshake(t, client, server, 15000);
	if(rc == nil || rs == nil)
		t.fatal("handshake hung (timeout)");

	t.assert(rc.secret == nil, "peer must reject an expired certificate (client side)");
	t.assert(rs.secret == nil, "peer must reject an expired certificate (server side)");
	t.assert(contains(rc.owner, "expired") || contains(rs.owner, "expired"),
		sys->sprint("rejection cites expiry (client=%q server=%q)", rc.owner, rs.owner));
}

# sanity: with a future expiry the SAME setup must SUCCEED (guards against the
# expired test passing for the wrong reason).
testNotExpiredSucceeds(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	future := 2000000000;	# 2033 (fits in int32)
	client := mkauthinfo(sk, pk, alpha, p, "client", future);
	server := mkauthinfo(sk, pk, alpha, p, "server", future);

	(rc, rs) := rawHandshake(t, client, server, 15000);
	if(rc == nil || rs == nil)
		t.fatal("handshake hung (timeout)");
	t.assert(rc.secret != nil && rs.secret != nil, "valid (unexpired, shared-signer) certs authenticate");
}

# ---- CipherMismatch ------------------------------------------------------

cipherServer(fd: ref Sys->FD, ai: ref Keyring->Authinfo, pidc: chan of int, rc: chan of (ref Sys->FD, string))
{
	pidc <-= sys->pctl(0, nil);
	# server offers ONLY aes_256_cbc/sha256
	(wrapped, err) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, fd, 0);
	rc <-= (wrapped, err);
}

testCipherMismatch(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	client := mkauthinfo(sk, pk, alpha, p, "client", 0);
	server := mkauthinfo(sk, pk, alpha, p, "server", 0);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	pidc := chan[1] of int;
	rc := chan[1] of (ref Sys->FD, string);
	spawn cipherServer(fds[0], server, pidc, rc);
	spid := <-pidc;

	# client requests aes_128_cbc, which the server did not offer
	(cwrapped, cerr) := auth->client("aes_128_cbc sha256", client, fds[1]);

	tmo := chan[1] of int;
	cancel := chan[1] of int;
	spawn timerproc(cancel, tmo, 15000);
	swrapped: ref Sys->FD;
	serr: string;
	alt {
	(w, e) := <-rc => swrapped = w; serr = e;
	<-tmo =>
		killpid(spid);
		t.fatal("server hung (timeout)");
	}
	cancel <-= 1;	# stop the timer so its sleep doesn't delay emu exit

	t.assert(swrapped == nil, "server must refuse a cipher it did not offer");
	t.assert(contains(serr, "unsupported") || contains(serr, "algorithm"),
		sys->sprint("server cites the unsupported algorithm (got %q)", serr));
	t.log(sys->sprint("client side: wrapped=%d err=%q", cwrapped != nil, cerr));
}

# ---- TamperedCiphertext --------------------------------------------------

# Relay one byte-stream src->dst.  Once `arm` fires, flip the first byte of the
# next chunk forwarded (corrupting one ssl record on the encrypted channel).
tamperRelay(src, dst: ref Sys->FD, arm: chan of int, pidc: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	armed := 0;
	flipped := 0;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(src, buf, len buf);
		if(n <= 0)
			break;
		# check the arm signal AFTER the read, before forwarding, so the
		# flip lands on the data chunk that arrives once armed (arm is
		# buffered, so the producer never blocks on a read-blocked relay).
		if(!armed){
			alt {
			<-arm => armed = 1;
			* => ;
			}
		}
		if(armed && !flipped){
			# corrupt the LAST byte (ssl record MAC/ciphertext body, not
			# the length header) so the record framing stays intact and
			# the receiver fails the digest check rather than desyncing.
			buf[n-1] = byte (int buf[n-1] ^ 16r80);
			flipped = 1;
		}
		if(sys->write(dst, buf[0:n], n) != n)
			break;
	}
	done <-= flipped;
}

tamperServer(fd: ref Sys->FD, ai: ref Keyring->Authinfo, expect: int,
		pidc: chan of int, ready: chan of int, rc: chan of (int, int))
{
	pidc <-= sys->pctl(0, nil);
	(wrapped, nil) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, fd, 0);
	if(wrapped == nil){
		ready <-= 0;
		rc <-= (-1, 0);
		return;
	}
	ready <-= 1;		# our half of the handshake + ssl is up
	buf := array[expect] of byte;
	n := readn(wrapped, buf, expect);
	# report (bytes read, whether they equal the canonical payload)
	ok := 1;
	if(n != expect)
		ok = 0;
	else
		for(i := 0; i < expect; i++)
			if(int buf[i] != ('A' + (i % 26)))
				ok = 0;
	rc <-= (n, ok);
}

testTamperedCiphertext(t: ref T)
{
	(alpha, p) := dhgroup(t);
	(sk, pk) := newsigner(t);
	client := mkauthinfo(sk, pk, alpha, p, "client", 0);
	server := mkauthinfo(sk, pk, alpha, p, "server", 0);

	pc := array[2] of ref Sys->FD;	# client <-> relay
	ps := array[2] of ref Sys->FD;	# relay  <-> server
	if(sys->pipe(pc) < 0 || sys->pipe(ps) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	armc := chan[1] of int;	# client -> relay: start corrupting (buffered)
	rdone := chan[1] of int;
	pidc := chan[1] of int;
	spawn tamperRelay(pc[1], ps[1], armc, pidc, rdone);	# client -> server (corrupting)
	relaypid1 := <-pidc;
	spawn tamperRelay(ps[1], pc[1], chan[1] of int, pidc, rdone);	# server -> client (clean)
	relaypid2 := <-pidc;

	ready := chan[1] of int;
	rc := chan[1] of (int, int);
	spawn tamperServer(ps[0], server, 260, pidc, ready, rc);
	serverpid := <-pidc;

	# The relays and the tamperServer block on pipe reads (or a reader-less
	# rdone send); they must be killed before init() returns or they pin the
	# emu open and race its teardown.  Kill them on every exit path.
	stragglers := relaypid1 :: relaypid2 :: serverpid :: nil;

	(cwrapped, cerr) := auth->client("aes_256_cbc sha256", client, pc[0]);
	if(cwrapped == nil){
		killpids(stragglers);
		t.fatal("client auth+ssl failed: " + cerr);
	}

	# wait for the server's half before sending data, so the byte the relay
	# flips is guaranteed to be encrypted *data*, not a handshake frame.
	tmo := chan[1] of int;
	cancel := chan[1] of int;
	spawn timerproc(cancel, tmo, 20000);
	alt {
	sok := <-ready =>
		if(!sok){
			cancel <-= 1;
			killpids(stragglers);
			t.fatal("server auth+ssl failed");
		}
	<-tmo =>
		killpids(stragglers);
		t.fatal("server handshake hung (timeout)");
	}
	cancel <-= 1;

	armc <-= 1;	# arm the corruption for the next client->server bytes

	msg := array[260] of byte;
	for(i := 0; i < len msg; i++)
		msg[i] = byte ('A' + (i % 26));
	sys->write(cwrapped, msg, len msg);

	tmo2 := chan[1] of int;
	cancel2 := chan[1] of int;
	spawn timerproc(cancel2, tmo2, 20000);
	n, ok: int;
	alt {
	(rn, rok) := <-rc => n = rn; ok = rok;
	<-tmo2 =>
		killpids(stragglers);
		t.fatal("server read hung (timeout)");
	}
	cancel2 <-= 1;

	t.assert(ok == 0, "ssl record MAC must reject a tampered ciphertext (corrupt data not delivered intact)");
	t.log(sys->sprint("server saw n=%d intact=%d after one flipped ciphertext byte", n, ok));

	# Success path: reap the relays and server so no proc outlives the test.
	killpids(stragglers);
}

# NB: handshake-mechanics negatives (protocol downgrade, tampered/malformed
# ML-KEM key, truncated frames) are covered by pqauth_test, which uses a
# man-in-the-middle relay between two real peers -- the correct way to drive
# those paths.  This file deliberately stays on the trust + integrity layer.

# ---- entry point ---------------------------------------------------------

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;

	if(sys == nil || kr == nil || testing == nil)
		raise "fail:cannot load core modules";
	if(auth == nil){
		sys->fprint(sys->fildes(2), "cannot load auth module: %r\n");
		raise "fail:cannot load auth";
	}
	if((e := auth->init()) != nil){
		sys->fprint(sys->fildes(2), "auth init failed: %s\n", e);
		raise "fail:auth init";
	}

	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("UntrustedSigner", testUntrustedSigner);
	run("ExpiredCert", testExpiredCert);
	run("NotExpiredSucceeds", testNotExpiredSucceeds);
	run("CipherMismatch", testCipherMismatch);
	run("TamperedCiphertext", testTamperedCiphertext);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
