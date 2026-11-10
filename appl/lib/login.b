# Inferno Encrypt Key Exchange Protocol
#
# Copyright © 1995-1999 Lucent Techologies Inc.  All rights reserved.
#
# This code uses methods that are subject to one or more patents
# held by Lucent Technologies Inc.  Its use outside Inferno
# requires a separate licence from Lucent.
#
implement Login;

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";

include "string.m";

# see login(6)
login(id, password, dest: string): (string, ref Keyring->Authinfo)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return nomod(Keyring->PATH);

	ssl := load SSL SSL->PATH;
	if(ssl == nil)
		return nomod(SSL->PATH);

	rand := load Random Random->PATH;
	if(rand == nil)
		return nomod(Random->PATH);

	if(dest == nil)
		dest = "$SIGNER";
	# Check if dest already has dial address format (contains '!')
	hasdelim := 0;
	for(j := 0; j < len dest; j++)
		if(dest[j] == '!'){
			hasdelim = 1;
			break;
		}
	if(!hasdelim)
		dest = "net!"+dest+"!inflogin";

	(ok, lc) := sys->dial(dest, nil);
	if(ok < 0)
		return (sys->sprint("can't contact login service: %r"), nil);

	# push ssl, leave in clear mode for now
	(err, c) := ssl->connect(lc.dfd);
	if(c == nil)
		return ("can't push ssl: " + err, nil);
	lc.dfd = nil;
	lc.cfd = nil;

	# user->CA	name
	if(kr->putstring(c.dfd, id) < 0)
		return (sys->sprint("can't send user name: %r"), nil);

	# CA->user	ACK
	(s, why) := kr->getstring(c.dfd);
	if(why != nil)
		return ("remote: " + why, nil);
	if(s != id)
		return ("unexpected reply from signer: " + s, nil);

	# user->CA	ivec: a salt for the key derivation and the AEAD's nonce.
	# Its length says which AEAD the client takes (see login(6)):
	#   32 bytes (20 salt + 12 nonce): ChaCha20-Poly1305, HKDF-SHA-256
	#   44 bytes (32 salt + 12 nonce): AES-256-GCM, HKDF-SHA-384 (CNSA)
	# A client in CNSA mode (/env/cnsamode) sends only the second; a
	# signer in CNSA mode takes only the second.
	cnsa := cnsamode();
	nsalt := 20;
	if(cnsa)
		nsalt = 32;
	ivec := rand->randombuf(rand->ReallyRandom, nsalt+12);
	if(kr->putbytearray(c.dfd, ivec, len ivec) < 0)
		return (sys->sprint("can't send initialization vector: %r"), nil);

	# The AEAD's key, by HKDF (RFC 5869) from the password's SHA-256,
	# which is what the signer keeps (changelogin(8)):
	#   Extract: PRK = HMAC-H(salt, IKM=SHA-256(password))
	#   Expand:  key = HMAC-H(PRK, info || 0x01)[0:32]
	pwbuf := array of byte password;
	pwdigest := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pwbuf, len pwbuf, pwdigest, nil);
	aeadkey := loginkey(cnsa, pwdigest, ivec[0:nsalt]);
	nonce := ivec[nsalt:];

	# CA -> user	AEAD-encrypted alpha**r0 mod p, then its 16-byte tag
	ciphertext: array of byte;
	authtag: array of byte;
	(ciphertext, err) = kr->getbytearray(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect (alpha**r0 mod p)", nil);
		return ("remote:" + err, nil);
	}
	(authtag, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return ("remote:" + err, nil);

	plaintext: array of byte;
	if(cnsa)
		plaintext = kr->aesgcmdecrypt(kr->aesgcmsetup(aeadkey, nonce), ciphertext, nil, authtag);
	else
		plaintext = kr->ccpolydecrypt(ciphertext, nil, authtag, aeadkey, nonce);
	if(plaintext == nil)
		return ("name or secret incorrect (AEAD decryption failed)", nil);
	alphar0 := IPint.b64toip(string plaintext);

	# CA->user	alpha
	(s, err) = kr->getstring(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect (alpha)", nil);
		return ("remote: " + err, nil);
	}
	info := ref Keyring->Authinfo;
	info.alpha = IPint.b64toip(s);

	# CA->user	p
	(s, err) = kr->getstring(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect (p)", nil);
		return ("remote: " + err, nil);
	}
	info.p = IPint.b64toip(s);

	# sanity check
	bits := info.p.bits();
	abits := info.alpha.bits();
	if(abits > bits || abits < 2)
		return ("bogus diffie hellman constants", nil);

	# generate our random diffie hellman part
	r1 := kr->IPint.random(bits/4, bits);
	alphar1 := info.alpha.expmod(r1, info.p);

	# user->CA	alpha**r1 mod p
	if(kr->putstring(c.dfd, alphar1.iptob64()) < 0)
		return (sys->sprint("can't send (alpha**r1 mod p): %r"), nil);

	# compute alpha**(r0*r1) mod p
	alphar0r1 := alphar0.expmod(r1, info.p);

	# turn on digesting
	secret := alphar0r1.iptobytes();
	err = ssl->secret(c, secret, secret);
	if(err != nil)
		return ("can't set digesting: " + err, nil);
	if(sys->fprint(c.cfd, "alg sha256") < 0)
		return (sys->sprint("can't push alg sha256: %r"), nil);

	# CA->user	CA's public key, SHA(CA's public key + secret)
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get signer's public key: " + err, nil);

	info.spk = kr->strtopk(s);

	# generate a key pair
	info.mysk = kr->genSKfromPK(info.spk, id);
	info.mypk = kr->sktopk(info.mysk);

	# user->CA	user's public key, SHA(user's public key + secret)
	if(kr->putstring(c.dfd, kr->pktostr(info.mypk)) < 0)
		return (sys->sprint("can't send your public: %r"), nil);

	# CA->user	user's public key certificate
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get certificate: " + err, nil);

	info.cert = kr->strtocert(s);
	return(nil, info);
}

# The AEAD key: HKDF-SHA-256 for ChaCha20-Poly1305, HKDF-SHA-384 for
# AES-256-GCM (CNSA admits SHA-384, not SHA-256), 32 bytes either way.
# logind.b has the same function; tests/login_test.b runs the two together.
loginkey(cnsa: int, ikm, salt: array of byte): array of byte
{
	info := "infernode login aead";
	dlen := Keyring->SHA256dlen;
	if(cnsa){
		info = "infernode login aes-256-gcm";
		dlen = Keyring->SHA384dlen;
	}
	prk := array[dlen] of byte;
	t := array[dlen] of byte;
	inf := array of byte info;
	ex := array[len inf + 1] of byte;
	ex[0:] = inf;
	ex[len inf] = byte 1;
	if(cnsa){
		kr->hmac_sha384(ikm, len ikm, salt, prk, nil);
		kr->hmac_sha384(ex, len ex, prk, t, nil);
	}else{
		kr->hmac_sha256(ikm, len ikm, salt, prk, nil);
		kr->hmac_sha256(ex, len ex, prk, t, nil);
	}
	return t[0:32];
}

# CNSA 2.0 strict mode: the /env/cnsamode policy flag, as signer(8) reads it.
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

nomod(mod: string): (string, ref Keyring->Authinfo)
{
	return (sys->sprint("can't load module %s: %r", mod), nil);
}
