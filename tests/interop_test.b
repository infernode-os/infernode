implement InteropTest;

#
# Node-to-node interoperability over the native Inferno transport:
# cert authentication + the hybrid post-quantum (ML-KEM-768) STS handshake
# + ssl line encryption, then a real Styx/9P file transfer across the
# encrypted channel.
#
# This is the end-to-end exercise the unit-level pqauth_test only approximates:
# one proc plays the serving node (auth->server + sys->export), the other plays
# the connecting node (auth->client + sys->mount), and the test asserts that a
# real file read *through the mount* (i.e. marshalled as 9P, encrypted by the
# ssl device, sent over a real TCP socket, decrypted and de-marshalled on the
# far side) is byte-identical to the file read directly.
#
# Coverage -- every certificate signature algorithm the keyring registers
# (except the SLH-DSA pair, whose multi-second signing makes the full
# export/mount exercise too slow for the auto-run suite; SLH-DSA-192s/256s
# node auth is covered over TCP by the scratch harness and documented in
# docs/NODE-INTEROP-TESTING.md):
#   - InteropEd25519   classical ed25519 certificates over the PQ handshake
#   - InteropMLDSA65   fully post-quantum: ML-DSA-65 certs + ML-KEM-768 KEM
#   - InteropMLDSA87   fully post-quantum: ML-DSA-87 certs + ML-KEM-768 KEM
#   - InteropRSA       classical RSA-2048 certificates
#   - InteropDSA       classical DSA-1024 (regression guard for the key
#                      (de)serialisation fix in libkeyring/dsaalg.c)
#   - InteropElgamal   classical ElGamal-2048 certificates
#
# All ride aes_256_cbc/sha256 line encryption -- the same default `mount -k`
# and `styxlisten` negotiate between InferNode and NERVA3 nodes.
#
# Skips cleanly (not fails) where the host has no IP stack at all.
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

InteropTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/interop_test.b";

# The serving node exports this subtree; the connecting node mounts it at
# MOUNTPT and reads XFER through the mount.  /lib is stable, read-only, and
# present in both the InferNode and NERVA3 trees; /mnt is a pre-existing
# mountpoint.  XFER is relative to the exported root.
EXPORTTREE: con "/lib";
MOUNTPT: con "/mnt";
XFER: con "/ndb/inferno";

# line-encryption algorithms (server offers a list, client a single spec) --
# aes_256_cbc + sha256 is the default mount -k / styxlisten negotiates.
CLIENTALG: con "aes_256_cbc sha256";

serveralgs(): list of string
{
	return "aes_256_cbc" :: "sha256" :: nil;
}

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

byteseq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[0] of byte;
	tmp := array[8192] of byte;
	for(;;){
		n := sys->read(fd, tmp, len tmp);
		if(n < 0)
			return nil;
		if(n == 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = tmp[0:n];
		buf = nb;
	}
	return buf;
}

readpath(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	return readall(fd);
}

# Build an Authinfo for `name`, certified by the given signer, sharing the
# DH group.  Mirrors appl/cmd/auth/mkauthinfo.b and tests/pqauth_test.b.
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

# Create a signer and a mutually-trusting (server, client) authinfo pair.
setupPair(t: ref T, signeralg: string, bits: int): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	signersk := kr->genSK(signeralg, "interop-signer", bits);
	if(signersk == nil)
		t.fatal("genSK signer (" + signeralg + ") failed");
	signerpk := kr->sktopk(signersk);

	(alpha, p) := kr->dhparams(2048);	# precomputed (RFC 3526), fast
	if(alpha == nil || p == nil)
		t.fatal("dhparams failed");

	srv := mkauthinfo(signersk, signerpk, alpha, p, "servernode");
	cli := mkauthinfo(signersk, signerpk, alpha, p, "clientnode");
	return (srv, cli);
}

Srv: adt {
	err:	string;	# non-nil on failure
};

# Serving node: accept the connection, authenticate + wrap in ssl, then
# export this namespace as a 9P service over the encrypted channel.
servernode(ac: Sys->Connection, ai: ref Keyring->Authinfo, ready: chan of string,
		done: chan of ref Srv)
{
	s := ref Srv;
	(lok, nc) := sys->listen(ac);
	if(lok < 0){
		s.err = sys->sprint("listen failed: %r");
		ready <-= s.err;
		done <-= s;
		return;
	}
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		s.err = sys->sprint("open data failed: %r");
		ready <-= s.err;
		done <-= s;
		return;
	}

	# authenticate the peer and push the negotiated cipher onto the line.
	# setid=0: we are not establishing a host owner, just a secure channel.
	(wrapped, who) := auth->server(serveralgs(), ai, dfd, 0);
	if(wrapped == nil){
		s.err = "server auth+ssl failed: " + who;
		ready <-= s.err;
		done <-= s;
		return;
	}

	ready <-= nil;	# auth done; client may proceed

	# serve the exported subtree over the encrypted channel until the peer leaves
	sys->export(wrapped, EXPORTTREE, Sys->EXPWAIT);
	done <-= s;
}

testInterop(t: ref T, label, signeralg: string, bits, port: int)
{
	if(auth == nil)
		t.fatal("auth module not loaded");
	if((e := auth->init()) != nil)
		t.fatal("auth init failed: " + e);

	# the reference bytes, read straight from the local filesystem
	want := readpath(EXPORTTREE + XFER);
	if(want == nil)
		t.fatal(sys->sprint("cannot read reference file %s: %r", EXPORTTREE + XFER));

	addr := sys->sprint("tcp!127.0.0.1!%d", port);
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		t.skip(sys->sprint("network unavailable: %r"));
		return;
	}

	(srvai, cliai) := setupPair(t, signeralg, bits);

	ready := chan of string;
	done := chan of ref Srv;
	spawn servernode(ac, srvai, ready, done);

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		t.skip(sys->sprint("dial failed (no loopback?): %r"));
		return;
	}

	(wrapped, cerr) := auth->client(CLIENTALG, cliai, dc.dfd);
	if(wrapped == nil)
		t.fatal(label + ": client auth+ssl failed: " + cerr);

	# wait for the server to finish its half of the handshake
	serr := <-ready;
	if(serr != nil)
		t.fatal(label + ": " + serr);

	# mount the remote node's exported tree over the encrypted channel
	sys->unmount(nil, MOUNTPT);	# start from a clean mountpoint
	if(sys->mount(wrapped, nil, MOUNTPT, Sys->MREPL, "") < 0)
		t.fatal(sys->sprint("%s: mount over encrypted channel failed: %r", label));

	# read the file *through the mount* -- this traffic is 9P, encrypted,
	# over the real TCP socket, authenticated by the PQ handshake.
	got := readpath(MOUNTPT + XFER);
	if(got == nil){
		sys->unmount(nil, MOUNTPT);
		t.fatal(sys->sprint("%s: read through mount failed: %r", label));
	}

	t.asserteq(len got, len want, label + ": transferred length matches");
	t.assert(byteseq(got, want), label + ": file bytes round-trip intact over cert-auth + PQC + ssl");
	t.log(sys->sprint("%s: %d bytes of %s round-tripped over an encrypted 9P channel",
		label, len got, EXPORTTREE + XFER));

	sys->unmount(nil, MOUNTPT);
}

testEd25519(t: ref T)
{
	testInterop(t, "ed25519", "ed25519", 0, 19811);
}

testMLDSA65(t: ref T)
{
	testInterop(t, "mldsa65", "mldsa65", 0, 19812);
}

testMLDSA87(t: ref T)
{
	testInterop(t, "mldsa87", "mldsa87", 0, 19813);
}

testRSA(t: ref T)
{
	testInterop(t, "rsa", "rsa", 2048, 19814);
}

testDSA(t: ref T)
{
	# regression guard: the DSA key (de)serialiser used to re-read the
	# first field as `q`, corrupting every wire-transmitted DSA key and
	# failing cert auth with "bad certificate".
	testInterop(t, "dsa", "dsa", 1024, 19815);
}

testElgamal(t: ref T)
{
	# 2048 selects precomputed RFC 3526 DH params (fast keygen)
	testInterop(t, "elgamal", "elgamal", 2048, 19816);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	testing = load Testing Testing->PATH;

	if(sys == nil || kr == nil || testing == nil){
		raise "fail:cannot load core modules";
	}
	if(auth == nil){
		sys->fprint(sys->fildes(2), "cannot load auth module: %r\n");
		raise "fail:cannot load auth";
	}

	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("InteropEd25519", testEd25519);
	run("InteropMLDSA65", testMLDSA65);
	run("InteropMLDSA87", testMLDSA87);
	run("InteropRSA", testRSA);
	run("InteropDSA", testDSA);
	run("InteropElgamal", testElgamal);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
