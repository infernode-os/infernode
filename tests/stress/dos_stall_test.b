implement DosStallTest;

#
# Denial-of-service resistance: a server must keep serving legitimate clients
# while misbehaving peers hold connections open without completing the
# authentication handshake (a slowloris-style stall).
#
# The server mirrors node_server.b: an accept loop that spawns a per-connection
# handler which runs auth->server.  A stalled client dials but never sends a
# handshake byte, pinning its handler proc in auth->server forever.  The test
# asserts that:
#
#   - StalledDoesNotBlock   one legitimate client still authenticates and is
#                           served while a stalled client holds a connection
#   - ManyStallsDoNotBlock  a legitimate client still succeeds with many
#                           stalled connections outstanding (the accept loop
#                           is not serialised behind a slow handshake)
#
# This documents the design property (spawn-per-connection isolates a slow/
# hostile handshake) and would catch a regression to an inline accept->auth
# loop, which a single staller would wedge.
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

DosStallTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/stress/dos_stall_test.b";

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

# spawn-per-connection server, mirroring node_server.b
serve(ai: ref Keyring->Authinfo, dfd: ref Sys->FD)
{
	(wrapped, nil) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, dfd, 0);
	if(wrapped == nil)
		return;
	buf := array[256] of byte;
	n := sys->read(wrapped, buf, len buf);
	if(n > 0)
		sys->write(wrapped, buf[0:n], n);	# echo
}

server(ac: Sys->Connection, ai: ref Keyring->Authinfo)
{
	for(;;){
		(lok, nc) := sys->listen(ac);
		if(lok < 0)
			return;
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd == nil)
			continue;
		spawn serve(ai, dfd);
	}
}

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# Hold a dialled connection open without ever sending a handshake byte.
# Keeps the ref alive until told to release, so the server handler stays
# pinned in auth->server.
staller(addr: string, hold: chan of int)
{
	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0)
		return;
	<-hold;			# block, keeping dc (and the connection) alive
	dc.dfd = nil;
}

# A legitimate client: full handshake + echo round-trip.  Returns "" on
# success or an error string.
legit(addr: string, ai: ref Keyring->Authinfo): string
{
	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0)
		return sys->sprint("dial: %r");
	(wrapped, cerr) := auth->client("aes_256_cbc sha256", ai, dc.dfd);
	if(wrapped == nil)
		return "client auth: " + cerr;
	msg := array of byte "legit-ping";
	if(sys->write(wrapped, msg, len msg) != len msg)
		return sys->sprint("write: %r");
	echo := array[len msg] of byte;
	if(readn(wrapped, echo, len echo) != len echo)
		return "short echo";
	return nil;
}

legitproc(addr: string, ai: ref Keyring->Authinfo, rc: chan of string)
{
	rc <-= legit(addr, ai);
}

setup(t: ref T, port: int): (string, ref Keyring->Authinfo)
{
	signersk := kr->genSK("ed25519", "dos-signer", 0);
	if(signersk == nil)
		t.fatal(sys->sprint("genSK: %r"));
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	srvai := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cliai := mkauthinfo(signersk, signerpk, alpha, p, "client");

	addr := sys->sprint("tcp!127.0.0.1!%d", port);
	(aok, ac) := sys->announce(addr);
	if(aok < 0)
		t.skip(sys->sprint("announce failed: %r"));
	spawn server(ac, srvai);
	return (addr, cliai);
}

# run a legit client with a timeout; returns (err, ok) where ok=0 means it
# hung (server wedged).
legitWithTimeout(addr: string, ai: ref Keyring->Authinfo, ms: int): (string, int)
{
	rc := chan of string;
	tmo := chan of int;
	spawn legitproc(addr, ai, rc);
	spawn timerproc(tmo, ms);
	alt {
	e := <-rc => return (e, 1);
	<-tmo => return ("timeout", 0);
	}
}

testStalledDoesNotBlock(t: ref T)
{
	(addr, cliai) := setup(t, 19610);

	hold := chan of int;
	spawn staller(addr, hold);
	sys->sleep(200);		# let the staller's connection land + pin a handler

	(e, ok) := legitWithTimeout(addr, cliai, 15000);
	hold <-= 1;			# release the staller
	if(!ok)
		t.fatal("legitimate client hung while a stalled client held a connection (server serialised?)");
	t.assertnil(e, "legitimate client authenticates despite a stalled peer: " + e);
}

testManyStallsDoNotBlock(t: ref T)
{
	(addr, cliai) := setup(t, 19611);

	NSTALL: con 25;
	holds := array[NSTALL] of chan of int;
	i: int;
	for(i = 0; i < NSTALL; i++){
		holds[i] = chan of int;
		spawn staller(addr, holds[i]);
	}
	sys->sleep(500);		# let them land

	(e, ok) := legitWithTimeout(addr, cliai, 20000);
	for(i = 0; i < NSTALL; i++)
		holds[i] <-= 1;		# release all
	if(!ok)
		t.fatal(sys->sprint("legitimate client hung with %d stalled connections outstanding", NSTALL));
	t.assertnil(e, "legitimate client authenticates with many stalled peers: " + e);
	t.log(sys->sprint("served a legit client while %d stalled handshakes were pinned", NSTALL));
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

	run("StalledDoesNotBlock", testStalledDoesNotBlock);
	run("ManyStallsDoNotBlock", testManyStallsDoNotBlock);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
