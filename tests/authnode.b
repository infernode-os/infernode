implement Authnode;

#
# Two-node test harness for the native PQ STS handshake (Keyring->auth).
# Run as separate emu processes that connect over real TCP, to exercise
# CNSA-strict ML-KEM-1024 across nodes and prove cross-mode rejection.
#
#   authnode gen    <skfile> [alg]           # generate a shared signer key
#   authnode listen <addr> <skfile> <name>   # accept + auth
#   authnode dial   <addr> <skfile> <name>   # connect + auth
#
# Prints AUTH-OK (with the derived secret length) or AUTH-FAIL.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;

Authnode: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

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

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	tot := 0;
	for(;;){
		n := sys->read(fd, buf[tot:], len buf - tot);
		if(n <= 0)
			break;
		tot += n;
	}
	if(tot <= 0)
		return nil;
	return string buf[0:tot];
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil){ sys->print("FAIL: no keyring\n"); return; }

	argv = tl argv;
	if(argv == nil){ sys->print("usage: authnode gen|listen|dial ...\n"); return; }
	role := hd argv; argv = tl argv;

	if(role == "gen"){
		if(argv == nil){ sys->print("usage: authnode gen <skfile> [alg]\n"); return; }
		skfile := hd argv;
		argv = tl argv;
		alg := "ed25519";
		if(argv != nil)
			alg = hd argv;
		sk := kr->genSK(alg, "test-signer", 0);
		if(sk == nil){ sys->print("FAIL: genSK\n"); return; }
		s := kr->sktostr(sk);
		fd := sys->create(skfile, Sys->OWRITE, 8r600);
		if(fd == nil){ sys->print("FAIL: create %s: %r\n", skfile); return; }
		b := array of byte s;
		sys->write(fd, b, len b);
		sys->print("gen: %s signer written to %s\n", alg, skfile);
		return;
	}

	if(tl argv == nil || tl tl argv == nil){
		sys->print("usage: authnode %s <addr> <skfile> <name>\n", role);
		return;
	}
	addr := hd argv; argv = tl argv;
	skfile := hd argv; argv = tl argv;
	myname := hd argv;

	signersk := kr->strtosk(readfile(skfile));
	if(signersk == nil){ sys->print("FAIL: cannot load signer from %s\n", skfile); return; }
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil){ sys->print("FAIL: dhparams\n"); return; }
	ai := mkauthinfo(signersk, signerpk, alpha, p, myname);

	fd: ref Sys->FD;
	case role {
	"listen" =>
		(ok, c) := sys->announce(addr);
		if(ok < 0){ sys->print("FAIL: announce %s: %r\n", addr); return; }
		sys->print("listening %s\n", addr);
		(ok2, nc) := sys->listen(c);
		if(ok2 < 0){ sys->print("FAIL: listen: %r\n"); return; }
		fd = sys->open(nc.dir + "/data", Sys->ORDWR);
	"dial" =>
		(ok, c) := sys->dial(addr, nil);
		if(ok < 0){ sys->print("FAIL: dial %s: %r\n", addr); return; }
		fd = c.dfd;
	* =>
		sys->print("unknown role %s\n", role);
		return;
	}
	if(fd == nil){ sys->print("FAIL: no data fd\n"); return; }

	(owner, secret) := kr->auth(fd, ai, 0);
	if(secret == nil)
		sys->print("AUTH-FAIL: %s\n", owner);
	else
		sys->print("AUTH-OK owner=%s secretlen=%d\n", owner, len secret);
}
