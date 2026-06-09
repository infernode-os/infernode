implement ChurnNode;

#
# Connection-churn driver for leak / stability testing of the node-auth path.
#
# Runs a serving node and a connecting node in ONE emu process over loopback
# TCP, then performs `count` sequential connection cycles, each of which:
#
#   dial -> auth->client (hybrid PQ STS + ssl) -> write a message ->
#   read the echo -> drop the connection
#
# with the server spawning a per-connection handler exactly like the real
# node_server.b.  The signer + Authinfos are generated ONCE and reused (as a
# real keyfile would be), so a per-iteration footprint increase isolates a
# per-connection leak in the socket / handshake / ssl / fd lifecycle rather
# than keygen.
#
# It prints "iter N" progress markers and a final "DONE" line; the host
# harness (run-churn.sh) samples the emu's RSS and open-fd count alongside
# those markers to decide whether memory and descriptors plateau.
#
# Usage:  churn_node [count [port [alg]]]
#   count  number of connection cycles      (default 500)
#   port   loopback TCP port                 (default 19500)
#   alg    signer cert algorithm            (default ed25519)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

ChurnNode: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

fail(s: string)
{
	sys->fprint(stderr, "churn_node: %s\n", s);
	raise "fail:error";
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
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}

# per-connection server handler, mirroring node_server.b's spawn-per-conn model
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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	stderr = sys->fildes(2);
	if(kr == nil || auth == nil)
		fail(sys->sprint("load core modules: %r"));
	if((e := auth->init()) != nil)
		fail("auth init: " + e);

	count := 500;
	port := 19500;
	alg := "ed25519";
	args = tl args;
	if(args != nil){ count = int hd args; args = tl args; }
	if(args != nil){ port = int hd args; args = tl args; }
	if(args != nil){ alg = hd args; }

	signersk := kr->genSK(alg, "churn-signer", 0);
	if(signersk == nil)
		fail(sys->sprint("genSK(%s): %r", alg));
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		fail("dhparams failed");

	srvai := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cliai := mkauthinfo(signersk, signerpk, alpha, p, "client");

	addr := sys->sprint("tcp!127.0.0.1!%d", port);
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		sys->print("SKIP: announce %s failed: %r\n", addr);
		return;
	}
	spawn server(ac, srvai);

	sys->print("START churn count=%d port=%d alg=%s\n", count, port, alg);

	msg := array of byte "churn-ping-0123456789";
	echo := array[len msg] of byte;

	for(i := 1; i <= count; i++){
		(dok, dc) := sys->dial(addr, nil);
		if(dok < 0){
			sys->print("dial failed at iter %d: %r\n", i);
			break;
		}
		(wrapped, cerr) := auth->client("aes_256_cbc sha256", cliai, dc.dfd);
		if(wrapped == nil){
			sys->print("client auth failed at iter %d: %s\n", i, cerr);
			break;
		}
		if(sys->write(wrapped, msg, len msg) != len msg){
			sys->print("write failed at iter %d: %r\n", i);
			break;
		}
		if(readn(wrapped, echo, len echo) != len echo){
			sys->print("echo read short at iter %d\n", i);
			break;
		}
		# drop all per-connection references so the fds/ssl state are
		# reclaimable; the next iteration must not inherit them.
		wrapped = nil;
		dc.dfd = nil;
		dc.cfd = nil;

		if(i % 100 == 0)
			sys->print("iter %d\n", i);
	}

	sys->print("DONE %d iterations\n", count);
}
