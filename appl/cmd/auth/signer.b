implement Signer;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	random: Random;

Signer: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# size in bits of modulus for public keys
PKmodlen:		con 2048;

# size in bits of modulus for diffie hellman
DHmodlen:		con 2048;

stderr, stdin, stdout: ref Sys->FD;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	random = load Random Random->PATH;
	kr = load Keyring Keyring->PATH;

	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	sys->pctl(Sys->FORKNS, nil);
	if(sys->chdir("/keydb") < 0){
		sys->fprint(stderr, "signer: no key database\n");
		raise "fail:no keydb";
	}

	err := sign();
	if(err != nil){
		sys->fprint(stderr, "signer: %s\n", err);
		raise "fail:error";
	}
}

sign(): string
{
	info := signerkey("signerkey");
	if(info == nil)
		return "can't read key";

	# send public part to client
	mypkbuf := array of byte kr->pktostr(kr->sktopk(info.mysk));
	kr->sendmsg(stdout, mypkbuf, len mypkbuf);
	alphabuf := array of byte info.alpha.iptob64();
	kr->sendmsg(stdout, alphabuf, len alphabuf);
	pbuf := array of byte info.p.iptob64();
	kr->sendmsg(stdout, pbuf, len pbuf);

	# get client's public key
	hisPKbuf := kr->getmsg(stdin);
	if(hisPKbuf == nil)
		return "caller hung up";
	hisPK := kr->strtopk(string hisPKbuf);
	if(hisPK == nil)
		return "illegal caller PK";

	# hash, sign, and blind
	state := certdigest(info.mysk, hisPKbuf);
	cert := kr->sign(info.mysk, 0, state, certhash(info.mysk));

	# sanity clause
	state = certdigest(info.mysk, hisPKbuf);
	if(kr->verify(info.mypk, cert, state) == 0)
		return "bad signer certificate";

	certbuf := array of byte kr->certtostr(cert);
	blind := random->randombuf(random->ReallyRandom, len certbuf);
	for(i := 0; i < len blind; i++)
		certbuf[i] = certbuf[i] ^ blind[i];

	# sum PKs and blinded certificate
	state = kr->md5(mypkbuf, len mypkbuf, nil, nil);
	kr->md5(hisPKbuf, len hisPKbuf, nil, state);
	digest := array[Keyring->MD5dlen] of byte;
	kr->md5(certbuf, len certbuf, digest, state);

	# save sum and blinded cert in a file
	file := "signed/"+hisPK.owner;
	fd := sys->create(file, Sys->OWRITE, 8r600);
	if(fd == nil)
		return "can't create "+file+sys->sprint(": %r");
	if(kr->sendmsg(fd, blind, len blind) < 0 ||
	   kr->sendmsg(fd, digest, len digest) < 0){
		sys->remove(file);
		return "can't write "+file+sys->sprint(": %r");
	}

	# send blinded cert to client
	kr->sendmsg(stdout, certbuf, len certbuf);

	return nil;
}

# CNSA 2.0 strict mode: read the /env/cnsamode policy flag (off by default).
# When set, a freshly-generated auth-domain CA key uses ML-DSA-87 (FIPS 204,
# Category 5) instead of ed25519. Mirrors createsignerkey(8) and the TLS/STS
# gating. Existing keyfiles are read unchanged — this affects only first-run
# key generation.
cnsamode(): int
{
	fd := sys->open("/env/cnsamode", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	c := buf[0];
	return c != byte '0' && c != byte 'n' && c != byte 'N' && c != byte '\n';
}

# CNSA 2.0: bind the certificate hash to the signing key's strength.
# ML-DSA / SLH-DSA (FIPS 204/205, NIST Cat >=3) keys pair with SHA-384;
# classical keys keep SHA-256 so pre-existing certs verify unchanged. The
# chosen name is stored in the certificate, so any verifier re-hashes to match.
certhash(sk: ref Keyring->SK): string
{
	if(sk != nil && sk.sa != nil)
		case sk.sa.name {
		"mldsa65" or "mldsa87" or "slhdsa192s" or "slhdsa256s" =>
			return "sha384";
		}
	return "sha256";
}

certdigest(sk: ref Keyring->SK, buf: array of byte): ref Keyring->DigestState
{
	if(certhash(sk) == "sha384")
		return kr->sha384(buf, len buf, nil, nil);
	return kr->sha256(buf, len buf, nil, nil);
}

signerkey(filename: string): ref Keyring->Authinfo
{
	info := kr->readauthinfo(filename);
	if(info != nil)
		return info;

	# generate a local key (ed25519 by default; ML-DSA-87 under CNSA mode)
	alg := "ed25519";
	if(cnsamode())
		alg = "mldsa87";
	info = ref Keyring->Authinfo;
	info.mysk = kr->genSK(alg, "*", PKmodlen);
	info.mypk = kr->sktopk(info.mysk);
	info.spk = kr->sktopk(info.mysk);
	myPKbuf := array of byte kr->pktostr(info.mypk);
	state := certdigest(info.mysk, myPKbuf);
	info.cert = kr->sign(info.mysk, 0, state, certhash(info.mysk));
	(info.alpha, info.p) = kr->dhparams(DHmodlen);

	if(kr->writeauthinfo(filename, info) < 0){
		sys->fprint(stderr, "can't write signerkey file: %r\n");
		return nil;
	}

	return info;
}
