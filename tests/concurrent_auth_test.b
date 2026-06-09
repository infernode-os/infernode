implement ConcurrentAuthTest;

#
# Concurrency correctness: many legitimate clients authenticating to ONE server
# at the same time must each get their OWN data back -- no cross-talk between
# connections, no races in the shared auth + ssl machinery, no hang/crash.
#
# The server is spawn-per-connection (like node_server.b) and shares one
# Authinfo across all handlers; every client shares one Authinfo too -- the
# realistic case (a node has one keyfile, many simultaneous peers).  Each
# client sends a 4 KiB payload whose every byte is a function of its client
# index and echoes it back; the client asserts the echo equals exactly what it
# sent.  A mixed-up connection (wrong secret / shared ssl state) would corrupt
# the echo and fail.
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

ConcurrentAuthTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/concurrent_auth_test.b";

NCLIENTS: con 12;
MSGLEN:   con 4096;

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

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# distinct 4 KiB payload for a client index
payload(index: int): array of byte
{
	a := array[MSGLEN] of byte;
	for(j := 0; j < MSGLEN; j++)
		a[j] = byte ((index * 7 + j) & 16rff);
	return a;
}

# server: accept forever, spawn a per-connection echo handler
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

serve(ai: ref Keyring->Authinfo, dfd: ref Sys->FD)
{
	(wrapped, nil) := auth->server("aes_256_cbc" :: "sha256" :: nil, ai, dfd, 0);
	if(wrapped == nil)
		return;
	buf := array[MSGLEN] of byte;
	if(readn(wrapped, buf, MSGLEN) == MSGLEN)
		sys->write(wrapped, buf, MSGLEN);	# echo this connection's own bytes
}

# client: dial, auth, send its distinct payload, verify the echo is identical.
# reports its index on success, or -1 on any failure.
clientproc(addr: string, ai: ref Keyring->Authinfo, index: int, rc: chan of int)
{
	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){ rc <-= -1; return; }
	(wrapped, nil) := auth->client("aes_256_cbc sha256", ai, dc.dfd);
	if(wrapped == nil){ rc <-= -1; return; }

	msg := payload(index);
	if(sys->write(wrapped, msg, len msg) != len msg){ rc <-= -1; return; }

	echo := array[MSGLEN] of byte;
	if(readn(wrapped, echo, MSGLEN) != MSGLEN){ rc <-= -1; return; }
	for(j := 0; j < MSGLEN; j++)
		if(echo[j] != msg[j]){ rc <-= -1; return; }	# cross-talk / corruption
	rc <-= index;
}

testConcurrentAuth(t: ref T)
{
	signersk := kr->genSK("ed25519", "conc-signer", 0);
	if(signersk == nil)
		t.fatal(sys->sprint("genSK: %r"));
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	srv := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cli := mkauthinfo(signersk, signerpk, alpha, p, "client");

	addr := "tcp!127.0.0.1!19630";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}
	spawn server(ac, srv);

	# launch all clients (near-)simultaneously
	rc := chan of int;
	i: int;
	for(i = 0; i < NCLIENTS; i++)
		spawn clientproc(addr, cli, i, rc);

	tmo := chan of int;
	spawn timerproc(tmo, 30000);

	seen := array[NCLIENTS] of { * => 0 };
	ok := 0;
	bad := 0;
	for(got := 0; got < NCLIENTS;){
		alt {
		idx := <-rc =>
			got++;
			if(idx < 0)
				bad++;
			else { seen[idx]++; ok++; }
		<-tmo =>
			t.fatal(sys->sprint("only %d/%d clients finished (deadlock/hang under concurrency)", got, NCLIENTS));
		}
	}

	t.asserteq(ok, NCLIENTS, "all concurrent clients authenticated and got their own data back");
	t.asserteq(bad, 0, "no client saw a corrupted / cross-talked echo");
	dups := 0;
	miss := 0;
	for(i = 0; i < NCLIENTS; i++){
		if(seen[i] > 1) dups++;
		if(seen[i] == 0) miss++;
	}
	t.asserteq(dups, 0, "no client index completed twice");
	t.asserteq(miss, 0, "every client index completed exactly once");
	t.log(sys->sprint("%d concurrent authenticated echo sessions, no cross-talk", NCLIENTS));
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

	run("ConcurrentAuth", testConcurrentAuth);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
