implement CipherMatrixTest;

#
# Line-encryption negotiation matrix for node-to-node sessions.
#
# pqauth_test / interop_test only exercise the default aes_256_cbc/sha256.
# This sweeps every cipher and MAC the ssl device offers (devssl.c
# encrypttab/hashtab) plus the unencrypted ("none") path, driving each through
# a real auth->server / auth->client handshake and a data round-trip, and
# asserting the payload survives byte-for-byte.
#
#   ciphers: aes_256_cbc, aes_128_cbc
#   MACs:    sha256
#   plus:    none (auth succeeds, no ssl pushed)
#
# Runs over a pipe (no TCP ports needed); each case has a timeout safety net.
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

CipherMatrixTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/cipher_matrix_test.b";

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

# shared signer + (server, client) Authinfos, generated once
signerpk: ref Keyring->PK;
alpha, p: ref Keyring->IPint;

setup(): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	srv := mkauthinfo(signersk, signerpk, alpha, p, "server");
	cli := mkauthinfo(signersk, signerpk, alpha, p, "client");
	return (srv, cli);
}

# signer state is module-global so every case shares one trust root
signersk: ref Keyring->SK;

timerproc(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# server half: authenticate, push the offered ssl, read `expect` bytes, and
# report whether they match the canonical payload.
serverside(fd: ref Sys->FD, ai: ref Keyring->Authinfo, algs: list of string,
		expect: int, rc: chan of (int, string))
{
	(wrapped, who) := auth->server(algs, ai, fd, 0);
	if(wrapped == nil){
		rc <-= (0, "server auth failed: " + who);
		return;
	}
	buf := array[expect] of byte;
	n := readn(wrapped, buf, expect);
	if(n != expect){
		rc <-= (0, sys->sprint("short read %d != %d", n, expect));
		return;
	}
	ok := 1;
	for(i := 0; i < expect; i++)
		if(int buf[i] != ('A' + (i % 26)))
			ok = 0;
	rc <-= (ok, nil);
}

# Drive one (serverAlgs, clientAlg) negotiation and assert a 256-byte payload
# round-trips intact across the negotiated channel.
roundtrip(t: ref T, label: string, serverAlgs: list of string, clientAlg: string)
{
	(srv, cli) := setup();

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));

	rc := chan of (int, string);
	spawn serverside(fds[0], srv, serverAlgs, 256, rc);

	(wrapped, cerr) := auth->client(clientAlg, cli, fds[1]);
	if(wrapped == nil)
		t.fatal(label + ": client auth failed: " + cerr);

	msg := array[256] of byte;
	for(i := 0; i < len msg; i++)
		msg[i] = byte ('A' + (i % 26));
	if(sys->write(wrapped, msg, len msg) != len msg)
		t.fatal(sys->sprint("%s: encrypted write failed: %r", label));

	tmo := chan[1] of int;
	spawn timerproc(tmo, 15000);
	ok: int;
	serr: string;
	alt {
	(rok, re) := <-rc => ok = rok; serr = re;
	<-tmo => t.fatal(label + ": server hung (timeout)");
	}
	if(serr != nil)
		t.fatal(label + ": " + serr);
	t.assert(ok != 0, label + ": payload survives the negotiated channel intact");
	t.log(sys->sprint("%s: 256 bytes round-tripped", label));
}

rejectsubset(t: ref T, label, clientAlg: string)
{
	(srv, cli) := setup();
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe failed: %r"));
	rc := chan of (int, string);
	spawn serverside(fds[0], srv, "aes_256_cbc"::"sha256"::nil, 0, rc);
	auth->client(clientAlg, cli, fds[1]);
	(ok, err) := <-rc;
	t.asserteq(ok, 0, label + ": incomplete policy rejected");
	t.assert(err != nil, label + ": server reports policy error");
}

# ---- cipher sweep (sha256 MAC) ----
testAes256(t: ref T)  { roundtrip(t, "aes_256_cbc/sha256", "aes_256_cbc"::"sha256"::nil, "aes_256_cbc sha256"); }
testAes128(t: ref T)  { roundtrip(t, "aes_128_cbc/sha256", "aes_128_cbc"::"sha256"::nil, "aes_128_cbc sha256"); }
testCipherAlternative(t: ref T) { roundtrip(t, "aes alternative with sha256", "aes_256_cbc"::"aes_128_cbc"::"sha256"::nil, "aes_128_cbc sha256"); }
testHashOnlySubset(t: ref T) { rejectsubset(t, "sha256-only subset", "sha256"); }
testCipherOnlySubset(t: ref T) { rejectsubset(t, "aes-only subset", "aes_256_cbc"); }
testEmptySubset(t: ref T) { rejectsubset(t, "empty subset", ""); }
testHashOnlyPolicy(t: ref T) { roundtrip(t, "intentional sha256-only policy", "sha256"::nil, "sha256"); }

# ---- unencrypted path ----
testNone(t: ref T) { roundtrip(t, "none", nil, "none"); }
testExplicitNone(t: ref T) { roundtrip(t, "explicit none", "none"::"aes_256_cbc"::"sha256"::nil, "none"); }

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
	if((e := auth->init()) != nil){
		sys->fprint(sys->fildes(2), "auth init: %s\n", e);
		raise "fail:auth init";
	}

	# one shared trust root for every case
	signersk = kr->genSK("ed25519", "matrix-signer", 0);
	if(signersk == nil){
		sys->fprint(sys->fildes(2), "genSK signer: %r\n");
		raise "fail:genSK";
	}
	signerpk = kr->sktopk(signersk);
	(alpha, p) = kr->dhparams(2048);
	if(alpha == nil || p == nil)
		raise "fail:dhparams";

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Aes256Sha256", testAes256);
	run("Aes128Sha256", testAes128);
	run("CipherAlternative", testCipherAlternative);
	run("HashOnlyPolicySubset", testHashOnlySubset);
	run("CipherOnlyPolicySubset", testCipherOnlySubset);
	run("EmptyPolicySubset", testEmptySubset);
	run("IntentionalHashOnlyPolicy", testHashOnlyPolicy);
	run("NoEncryption", testNone);
	run("ExplicitNoEncryption", testExplicitNone);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
