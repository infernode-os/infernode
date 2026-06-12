implement InterruptTest;

#
# Interruptibility: an abrupt connection drop during the auth handshake or
# during an encrypted data transfer must make the peer fail/EOF cleanly --
# never crash, never hang forever.  Uses real TCP sockets (loopback); the
# "disconnect" is dropping every reference to the socket so it closes and the
# OS delivers the hangup to the peer.  Each case has a timeout safety net so a
# HANG is reported as a failure rather than wedging the suite.
#
#   - DropMidHandshake   the peer aborts the connection part-way through the
#                        handshake; the other side's auth must return an error
#                        (not block)
#   - DropMidTransfer    the writer aborts after a successful handshake, part
#                        way through a transfer; the reader must hit EOF and
#                        stop with the partial data (not block, not crash)
#
# Skips cleanly where the host has no IP stack.
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

InterruptTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/interrupt_test.b";

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

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

setup(t: ref T): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	signersk := kr->genSK("ed25519", "intr-signer", 0);
	if(signersk == nil)
		t.fatal(sys->sprint("genSK: %r"));
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	srv := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cli := mkauthinfo(signersk, signerpk, alpha, p, "client");
	return (srv, cli);
}

# ---- DropMidHandshake ----------------------------------------------------

# Accept a connection, read a little of the peer's handshake, then drop the
# socket (return) so it closes mid-handshake.
abortingServer(ac: Sys->Connection, ready: chan of int)
{
	ready <-= 1;
	(lok, nc) := sys->listen(ac);
	if(lok < 0)
		return;
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil)
		return;
	buf := array[64] of byte;
	sys->read(dfd, buf, len buf);	# consume a bit, then drop dfd -> close
}

clientAuthProc(dfd: ref Sys->FD, ai: ref Keyring->Authinfo, rc: chan of string)
{
	(wrapped, err) := auth->client("aes_256_cbc sha256", ai, dfd);
	if(wrapped == nil)
		rc <-= "err:" + err;	# clean failure (expected)
	else
		rc <-= "ok";		# unexpectedly succeeded
}

testDropMidHandshake(t: ref T)
{
	(nil, cli) := setup(t);

	addr := "tcp!127.0.0.1!19620";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}
	ready := chan of int;
	spawn abortingServer(ac, ready);
	<-ready;

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		t.skip(sys->sprint("dial failed: %r"));
		return;
	}

	rc := chan of string;
	spawn clientAuthProc(dc.dfd, cli, rc);
	tmo := chan of int;
	spawn timerproc(tmo, 15000);

	alt {
	r := <-rc =>
		t.assertsne(r, "ok", "client auth must fail (not succeed) when the peer drops mid-handshake");
		t.assert(r != "ok", "client returns a clean error on mid-handshake disconnect");
		t.log(sys->sprint("client result: %s", r));
	<-tmo =>
		t.fatal("client hung on a mid-handshake disconnect (should error within the timeout)");
	}
}

# ---- DropMidTransfer -----------------------------------------------------

# Authenticate, then read the encrypted channel until EOF, reporting how many
# bytes arrived before the writer vanished.
drainingServer(ac: Sys->Connection, ai: ref Keyring->Authinfo, rc: chan of int)
{
	(lok, nc) := sys->listen(ac);
	if(lok < 0){ rc <-= -1; return; }
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil){ rc <-= -1; return; }
	(wrapped, nil) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, dfd, 0);
	if(wrapped == nil){ rc <-= -1; return; }

	buf := array[65536] of byte;
	got := 0;
	for(;;){
		n := sys->read(wrapped, buf, len buf);
		if(n <= 0)
			break;		# EOF / error when the writer aborts
		got += n;
	}
	rc <-= got;			# reaching here means we did NOT hang
}

testDropMidTransfer(t: ref T)
{
	(srv, cli) := setup(t);

	addr := "tcp!127.0.0.1!19621";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}
	rc := chan of int;
	spawn drainingServer(ac, srv, rc);

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		t.skip(sys->sprint("dial failed: %r"));
		return;
	}

	(wrapped, cerr) := auth->client("aes_256_cbc sha256", cli, dc.dfd);
	if(wrapped == nil)
		t.fatal("client auth failed: " + cerr);

	# write a partial transfer (3 x 64 KiB) of an intended-much-larger stream
	chunk := array[65536] of byte;
	for(i := 0; i < len chunk; i++)
		chunk[i] = byte i;
	partial := 0;
	for(k := 0; k < 3; k++){
		if(sys->write(wrapped, chunk, len chunk) != len chunk)
			break;
		partial += len chunk;
	}

	# abrupt disconnect: drop every reference to the socket so it closes and
	# the server's read sees EOF.
	wrapped = nil;
	dc.dfd = nil;
	dc.cfd = nil;

	tmo := chan of int;
	spawn timerproc(tmo, 15000);
	alt {
	got := <-rc =>
		t.assert(got >= 0, "server returned (did not hang) after a mid-transfer disconnect");
		t.assert(got <= partial, "server received at most the bytes actually sent before the drop");
		t.log(sys->sprint("server drained %d of %d sent bytes, then EOF cleanly", got, partial));
	<-tmo =>
		t.fatal("server hung reading after a mid-transfer disconnect (should EOF within the timeout)");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;
	if(sys == nil || kr == nil || testing == nil)
		raise "fail:cannot load core modules";
	if(auth == nil)
		raise "fail:cannot load auth";
	auth->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DropMidHandshake", testDropMidHandshake);
	run("DropMidTransfer", testDropMidTransfer);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
