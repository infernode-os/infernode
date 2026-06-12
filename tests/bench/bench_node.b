implement BenchNode;

#
# Performance baselines for the node-to-node auth path.  Prints three tables:
#
#   1. keygen latency per certificate signature algorithm (one genSK)
#   2. full STS handshake latency per algorithm (auth->client/server over a
#      pipe, averaged over N iterations, reusing one keypair)
#   3. encrypted-channel throughput per ssl cipher (MB/s pushing a fixed
#      payload through a negotiated channel)
#
# Measured with sys->millisec() inside the emu (no host introspection).  These
# are *baselines*: absolute numbers are environment-dependent (host speed, emu
# build, JIT) -- the value is the relative cost between algorithms/ciphers and
# a repeatable methodology.  Run on the target hardware for real figures.
#
# Usage:  bench_node [handshake_iters [throughput_MB]]
#   handshake_iters  fast-alg handshake samples (default 10; SLH-DSA uses 2)
#   throughput_MB    payload size per cipher in MiB (default 8)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

BenchNode: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

fail(s: string)
{
	sys->fprint(stderr, "bench_node: %s\n", s);
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
	ai.mysk = sk; ai.mypk = pk; ai.cert = cert;
	ai.spk = signerpk; ai.alpha = alpha; ai.p = p;
	return ai;
}

Res: adt { owner: string; secret: array of byte; };

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of ref Res)
{
	(owner, secret) := kr->auth(fd, ai, 0);
	c <-= ref Res(owner, secret);
}

# one raw STS handshake over a fresh pipe; returns elapsed ms, or -1 on failure
handshakeOnce(a, b: ref Keyring->Authinfo): int
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return -1;
	ca := chan of ref Res;
	cb := chan of ref Res;
	t0 := sys->millisec();
	spawn authproc(fds[0], a, ca);
	spawn authproc(fds[1], b, cb);
	ra := <-ca;
	rb := <-cb;
	t1 := sys->millisec();
	if(ra.secret == nil || rb.secret == nil)
		return -1;
	return t1 - t0;
}

algbits(alg: string): int
{
	case alg {
	"rsa" => return 2048;
	"dsa" => return 1024;
	"elgamal" => return 2048;
	* => return 0;	# ed25519 / ML-DSA / SLH-DSA ignore the size
	}
}

isslow(alg: string): int
{
	return alg == "slhdsa192s" || alg == "slhdsa256s";
}

benchAlg(alg: string, signerpk: ref Keyring->PK, signersk: ref Keyring->SK,
		alpha, p: ref Keyring->IPint, iters: int)
{
	# keygen: one sample (genSK of a fresh signer of this alg)
	t0 := sys->millisec();
	ksk := kr->genSK(alg, "bench", algbits(alg));
	t1 := sys->millisec();
	if(ksk == nil){
		sys->print("  %-11s  genSK FAILED\n", alg);
		return;
	}

	# handshake: reuse one (server, client) keypair derived from this signer
	srv := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cli := mkauthinfo(signersk, signerpk, alpha, p, "client");

	n := iters;
	if(isslow(alg) && n > 2)
		n = 2;

	tot := 0;
	good := 0;
	for(i := 0; i < n; i++){
		ms := handshakeOnce(srv, cli);
		if(ms >= 0){ tot += ms; good++; }
	}
	if(good == 0){
		sys->print("  %-11s  keygen=%-6d handshake=FAILED\n", alg, t1-t0);
		return;
	}
	sys->print("  %-11s  keygen=%-6d handshake_avg=%-6d ms  (n=%d)\n",
		alg, t1-t0, tot/good, good);
}

# ---- throughput ----------------------------------------------------------

drainproc(fd: ref Sys->FD, total: int, done: chan of int)
{
	buf := array[65536] of byte;
	got := 0;
	while(got < total){
		m := sys->read(fd, buf, len buf);
		if(m <= 0)
			break;
		got += m;
	}
	done <-= got;
}

# returns MB/s * 100 (fixed-point, 2 decimals) or -1
throughputOnce(srv, cli: ref Keyring->Authinfo, cipher: string, total: int): int
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return -1;

	# server side runs in a proc: authenticate, then drain `total` bytes.
	# offer the matching algs; for "none" offer nil so the server accepts the
	# client's unencrypted request rather than rejecting an unoffered cipher.
	serverAlgs: list of string;
	if(cipher != "none")
		serverAlgs = cipher :: "sha256" :: nil;
	rc := chan of (ref Sys->FD, string);
	spawn serverWrap(fds[0], srv, serverAlgs, rc);

	clientalg := cipher;
	if(cipher != "none")
		clientalg = cipher + " sha256";
	(wc, cerr) := auth->client(clientalg, cli, fds[1]);
	if(wc == nil)
		return -1;
	(ws, serr) := <-rc;
	if(ws == nil)
		return -1;

	done := chan of int;
	spawn drainproc(ws, total, done);

	chunk := array[65536] of byte;
	for(i := 0; i < len chunk; i++)
		chunk[i] = byte i;

	t0 := sys->millisec();
	sent := 0;
	while(sent < total){
		n := total - sent;
		if(n > len chunk)
			n = len chunk;
		if(sys->write(wc, chunk, n) != n)
			return -1;
		sent += n;
	}
	got := <-done;
	t1 := sys->millisec();
	if(got != total)
		return -1;
	dt := t1 - t0;
	if(dt <= 0)
		dt = 1;
	# MB/s*100 = total bytes / dt(ms) * 1000 / 1048576 * 100
	return (total / dt) * 100000 / 1048576;
}

serverWrap(fd: ref Sys->FD, ai: ref Keyring->Authinfo, algs: list of string,
		rc: chan of (ref Sys->FD, string))
{
	(w, who) := auth->server(algs, ai, fd, 0);
	rc <-= (w, who);
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

	# mode: "all" (default), "lat" (keygen+handshake only), "tp" (throughput
	# only).  SLH-DSA's signing is so slow it can trip a host CPU watchdog
	# mid-run, so "tp" lets the throughput numbers be captured on their own.
	mode := "all";
	iters := 10;
	tmib := 8;
	args = tl args;
	if(args != nil && (hd args == "all" || hd args == "lat" || hd args == "tp")){
		mode = hd args; args = tl args;
	}
	if(args != nil){ iters = int hd args; args = tl args; }
	if(args != nil){ tmib = int hd args; }

	# shared DH group + an ed25519 signer for the throughput section
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		fail("dhparams failed");

	algs := array[] of {
		"ed25519", "mldsa65", "mldsa87", "rsa", "dsa", "elgamal",
		"slhdsa192s", "slhdsa256s"
	};

	i: int;
	if(mode == "all" || mode == "lat"){
		sys->print("== keygen + handshake latency (ms) ==\n");
		for(i = 0; i < len algs; i++){
			alg := algs[i];
			sk := kr->genSK(alg, "signer", algbits(alg));
			if(sk == nil){
				sys->print("  %-11s  signer genSK FAILED\n", alg);
				continue;
			}
			benchAlg(alg, kr->sktopk(sk), sk, alpha, p, iters);
		}
	}

	if(mode == "all" || mode == "tp"){
		sys->print("\n== encrypted-channel throughput (%d MiB payload) ==\n", tmib);
		esk := kr->genSK("ed25519", "tp-signer", 0);
		epk := kr->sktopk(esk);
		srv := mkauthinfo(esk, epk, alpha, p, "server");
		cli := mkauthinfo(esk, epk, alpha, p, "client");
		total := tmib * 1048576;
		ciphers := array[] of { "none", "aes_256_cbc", "aes_128_cbc", "ideacbc", "ideaecb" };
		for(i = 0; i < len ciphers; i++){
			c := ciphers[i];
			mbps100 := throughputOnce(srv, cli, c, total);
			if(mbps100 < 0)
				sys->print("  %-12s  FAILED\n", c);
			else
				sys->print("  %-12s  %d.%2.2d MB/s\n", c, mbps100/100, mbps100%100);
		}
	}

	sys->print("\nDONE\n");
}
