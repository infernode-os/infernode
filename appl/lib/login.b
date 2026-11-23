# Inferno Encrypt Key Exchange Protocol
#
# Copyright © 1995-1999 Lucent Techologies Inc.  All rights reserved.
#
# This code uses methods that are subject to one or more patents
# held by Lucent Technologies Inc.  Its use outside Inferno
# requires a separate licence from Lucent.
#
implement Login;

#
# login(6), version 3: the client's side (login), and what the signer's
# programs share with it -- the rule for account names, the groups, the
# key derivation, and logind(8)'s count of failed attempts -- so that
# there is one of each.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";

include "daytime.m";
	daytime: Daytime;

include "audit.m";
	audit: Audit;

Maxname: con 255;	# bytes of UTF-8 in an account name: a 9P name

#
# RFC 3526's groups 14, 15 and 16: safe primes p with generator 2, which
# is of order q = (p-1)/2 (p is 7 mod 8, so 2 is a square).  They are the
# only groups the exchange uses, known to both ends and never taken from
# the wire: a client that took alpha and p from whoever answered could
# be given p = 2.  The top 64 bits of each prime are ones, which is what
# lets a group element be hidden under a keystream (see mask): a string
# of len(p) bytes is a number below p but for one in 2^64.
# tests/host/login/mkgroups.py makes them from RFC 3526's formulas and
# checks each is a safe prime.
#
P14: con
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"+
	"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"+
	"4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"+
	"98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"+
	"9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
	"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"+
	"3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF";

P15: con
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"+
	"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"+
	"4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"+
	"98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"+
	"9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
	"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"+
	"3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"+
	"A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"+
	"ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"+
	"D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"+
	"08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

P16: con
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"+
	"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"+
	"4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"+
	"98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"+
	"9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
	"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"+
	"3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"+
	"A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"+
	"ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"+
	"D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"+
	"08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7"+
	"88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8"+
	"DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2"+
	"233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9"+
	"93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF";

Group: adt {
	id:	int;
	hex:	string;
	p:	ref IPint;	# made when first asked for
};

groups: array of ref Group;

init(): string
{
	if(sys != nil)
		return nil;
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		err := sys->sprint("can't load module %s: %r", Keyring->PATH);
		sys = nil;
		return err;
	}
	groups = array[] of {
		ref Group(14, P14, nil),
		ref Group(15, P15, nil),
		ref Group(16, P16, nil),
	};
	return nil;
}

# What a login made that is secret, to be zeroed when it is over
# however it ends (arrays of bytes: the exponents and the shared number
# are IPints, which Limbo gives no way to clear, and the password came
# as a string).
Wipe: adt {
	l:	list of array of byte;
};

# see login(6)
login(id, password, dest: string): (string, ref Keyring->Authinfo)
{
	w := ref Wipe;
	r := login1(id, password, dest, w);
	for(l := w.l; l != nil; l = tl l)
		zero(hd l);
	return r;
}

login1(id, password, dest: string, w: ref Wipe): (string, ref Keyring->Authinfo)
{
	err := init();
	if(err != nil)
		return (err, nil);

	ssl := load SSL SSL->PATH;
	if(ssl == nil)
		return nomod(SSL->PATH);

	# one account name, before it is sent anywhere
	err = okname(id);
	if(err != nil)
		return ("bad user name: " + err, nil);

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
	c: ref Sys->Connection;
	(err, c) = ssl->connect(lc.dfd);
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

	# user->CA	hello: the version, the suite, the client's nonce.
	# A client in CNSA mode (/env/cnsamode) offers only AES-256-GCM
	# with SHA-384 and ML-KEM-1024, and then takes only a group of 3072
	# bits or more.
	suite := Chacha;
	if(cnsamode())
		suite = Aesgcm;
	hello := array[2+Noncelen] of byte;
	hello[0] = byte Version;
	hello[1] = byte suite;
	hello[2:] = nonce();
	if(kr->putbytearray(c.dfd, hello, len hello) < 0)
		return (sys->sprint("can't send hello: %r"), nil);

	# CA->user	reply: version, suite, group, the signer's nonce, and
	# the signer's Diffie-Hellman value under the password's keystream
	reply: array of byte;
	(reply, err) = kr->getbytearray(c.dfd);
	if(err != nil){
		# what logind said to a third message that was no ivec, before
		# version 2: there is no going back to that exchange
		if(err == "bad initialization vector length")
			return ("signer speaks the old login exchange, which is refused: see login(6)", nil);
		return ("remote: " + err, nil);
	}
	if(len reply < 3 || int reply[0] != Version){
		if(len reply >= 1 && int reply[0] == 2)
			return ("signer speaks login version 2, which has no ML-KEM and is refused: update the signer (login(6))", nil);
		return ("signer's reply is not login version 3: see login(6)", nil);
	}
	if(len reply < 3+Noncelen)
		return ("signer's reply is too short", nil);
	if(int reply[1] != suite){
		if(suite == Aesgcm)
			return ("CNSA mode: signer did not answer with AES-256-GCM and SHA-384", nil);
		return ("signer answered with a suite not offered", nil);
	}
	gid := int reply[2];
	(p, n) := group(gid);
	if(p == nil)
		return (sys->sprint("signer's group %d is not one of login(6)'s", gid), nil);
	if(suite == Aesgcm && n*8 < 3072)
		return (sys->sprint("CNSA mode: signer's group %d has %d bits; 3072 at least are required", gid, n*8), nil);
	if(len reply != 3+Noncelen+n)
		return ("signer's reply is not the length of its group", nil);

	# The stored form of the password (changelogin(8)): its SHA-256.
	pwbuf := array of byte password;
	pw := array[Keyring->SHA256dlen] of byte;
	w.l = pwbuf :: pw :: w.l;
	kr->sha256(pwbuf, len pwbuf, pw, nil);

	# The signer's value, +-2**r0 mod p.  With another password this
	# is some other number, and nothing here says which: there is no
	# tag to check.  It must be an element the secret can be made
	# from: 0, 1 and p-1 would make the secret one anybody knows.
	x := IPint.bytestoip(mask(suite, gid, id, pw, hello[2:], reply[3:3+Noncelen], reply[3+Noncelen:]));
	if(!inrange(x, p))
		return ("name or secret incorrect", nil);

	# user->CA	2**r1 mod p, and an ML-KEM encapsulation key of this
	# login's whose seed is under a keystream of the password and the
	# Diffie-Hellman secret x**(2*r1) mod p.  The seed alone is masked:
	# with any password it unmasks to 32 bytes that make a key of the
	# right form (the rest of the key, which has a form, is in clear;
	# whether it goes with a given seed is ML-KEM's own hard problem),
	# and a ciphertext the signer made under a guess opens only to
	# whoever had the guess right.  So a party that can
	# take logarithms (a quantum computer) and reads or takes the
	# signer's part in a login still has only one guess at the password
	# in each, and the session's secret needs the KEM's as well.
	r1 := exponent(p);
	y := bebytes(IPint.inttoip(2).expmod(r1, p), n);
	z := bebytes(x.expmod(r1.shl(1), p), n);
	w.l = z :: w.l;
	(eklen, ctlen) := kemsizes(suite);
	(ek, dk) := kemkeygen(suite);
	if(ek == nil || dk == nil || len ek != eklen)
		return ("can't make an ML-KEM key", nil);
	w.l = dk :: w.l;
	rho := ek[eklen-Rholen:];
	msg := array[n + eklen] of byte;
	msg[0:] = y;
	msg[n:] = ek[0:eklen-Rholen];
	msg[n+eklen-Rholen:] = kemmask(suite, gid, id, pw, hello[2:], reply[3:3+Noncelen], z, rho);
	if(kr->putbytearray(c.dfd, msg, len msg) < 0)
		return (sys->sprint("can't send (2**r1 mod p): %r"), nil);

	# CA->user	an ML-KEM ciphertext for that key, as the signer
	# unmasked it.  With another password it was another key, and what
	# opens here is ML-KEM's implicit rejection, which nobody knows: the
	# proofs then differ.
	ct: array of byte;
	(ct, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return ("remote: " + err, nil);
	if(len ct != ctlen)
		return ("signer's ML-KEM ciphertext is not the length of its suite's", nil);
	k := kemdecaps(suite, dk, ct);
	if(k == nil)
		return ("signer's ML-KEM ciphertext is refused", nil);
	w.l = k :: w.l;

	# user->CA	the proof that the client has both secrets: the
	# signer says nothing made from them before it has this.
	(cproof, sproof, sk) := keys(suite, id, pw, hello, reply, msg, ct, z, k);
	w.l = sproof :: sk :: w.l;
	if(kr->putbytearray(c.dfd, cproof, len cproof) < 0)
		return (sys->sprint("can't send proof: %r"), nil);

	# CA->user	the signer's proof: it had the password too
	proof: array of byte;
	(proof, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return ("remote: " + err, nil);
	if(!same(proof, sproof))
		return ("signer did not prove it has the secret", nil);

	# protect the rest: aes_256_gcm, each way under its own secret
	(secretin, secretout) := ssl->secrets(sk, 1);
	w.l = secretin :: secretout :: w.l;
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return ("can't set secrets: " + err, nil);
	if(sys->fprint(c.cfd, "alg aes_256_gcm") < 0)
		return (sys->sprint("can't push alg aes_256_gcm: %r"), nil);

	# CA->user	CA's public key, and the alpha and p of its key file,
	# which auth(2) uses between the holders of its certificates.
	# They come from the signer the password has just authenticated.
	info := ref Keyring->Authinfo;
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get signer's public key: " + err, nil);
	info.spk = kr->strtopk(s);
	if(info.spk == nil)
		return ("signer's public key is not a key", nil);
	# In CNSA mode the signer's key is ML-DSA-87 or it is not taken
	# (and the key made below, which is like it, is then one too): the
	# suite alone was checked, so a client in the mode took a
	# certificate from an Ed25519 or a 512-bit RSA signer.
	cnsa := suite == Aesgcm;
	if(cnsa && (err = cnsaalg(info.spk.sa.name)) != nil)
		return ("signer's key: " + err, nil);
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get signer's alpha: " + err, nil);
	info.alpha = IPint.b64toip(s);
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get signer's p: " + err, nil);
	info.p = IPint.b64toip(s);
	if(info.alpha == nil || info.p == nil)
		return ("signer's Diffie-Hellman constants are not numbers", nil);
	bits := info.p.bits();
	if(bits < Minrealm || bits > Maxrealm)
		return (sys->sprint("signer's Diffie-Hellman modulus has %d bits: %d to %d are taken", bits, Minrealm, Maxrealm), nil);
	if(cnsa && bits < CNSAdhbits)
		return (sys->sprint("CNSA mode: signer's Diffie-Hellman modulus has %d bits; %d at least are required", bits, CNSAdhbits), nil);
	pb := info.p.iptobytes();
	if(!inrange(info.alpha, info.p) || (int pb[len pb-1] & 1) == 0)
		return ("bogus diffie hellman constants", nil);

	# generate a key pair
	{
		info.mysk = kr->genSKfromPK(info.spk, id);
	} exception {
	"*" =>
		info.mysk = nil;
	}
	if(info.mysk == nil)
		return ("can't make a key like the signer's", nil);
	info.mypk = kr->sktopk(info.mysk);

	# user->CA	user's public key
	mypk := kr->pktostr(info.mypk);
	if((err = putstring(c.dfd, mypk)) != nil)
		return ("can't send your public key: " + err, nil);

	# CA->user	user's public key certificate
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get certificate: " + err, nil);

	# It was success with whatever came: a string that was no
	# certificate was returned as one, and a caller writing it died.
	info.cert = kr->strtocert(s);
	if(info.cert == nil)
		return ("signer's certificate is not one", nil);
	if(cnsa && ((err = cnsaalg(info.cert.sa.name)) != nil || (err = cnsahash(info.cert.ha)) != nil))
		return ("signer's certificate: " + err, nil);
	b := array of byte mypk;
	state: ref Keyring->DigestState;
	case info.cert.ha {
	"sha384" =>
		state = kr->sha384(b, len b, nil, nil);
	"sha512" =>
		state = kr->sha512(b, len b, nil, nil);
	* =>
		state = kr->sha256(b, len b, nil, nil);
	}
	if(kr->verify(info.spk, info.cert, state) == 0)
		return ("signer's certificate does not verify with its key", nil);
	return(nil, info);
}

# what auth(2) takes for the realm's own modulus (keyring.c's Maxdhbits)
Minrealm: con 2048;
Maxrealm: con 8192;

#
# An account name is one name: it is looked up as a directory of
# keyfs(4), counted by the throttle, written into a certificate and, by
# signer(8), made a file of the host's.  So it has no slash (nor the
# backslash a Windows host takes for one), is not . or .., has no
# control character, and is not what bytes that were no UTF-8 turn
# into.  "carol/." was carol to keyfs and another name to the throttle,
# and "../signerkey" was the signer's key file.
#
okname(name: string): string
{
	if(name == nil)
		return "empty name";
	if(name == "." || name == "..")
		return "a directory's name";
	if(len array of byte name > Maxname)
		return "name too long";
	for(i := 0; i < len name; i++){
		c := name[i];
		if(c < ' ' || c == 16r7F)
			return "control character in name";
		if(c == '/' || c == '\\')
			return "path separator in name";
		if(c == 16rFFFD)
			return "name is not UTF-8";
	}
	if(name[0] == ' ' || name[len name-1] == ' ')
		return "name begins or ends with a blank";
	return nil;
}

# A group's prime and its length in bytes; (nil, 0) for an id that is
# none of login(6)'s.
group(id: int): (ref IPint, int)
{
	if(init() != nil)
		return (nil, 0);
	for(i := 0; i < len groups; i++){
		g := groups[i];
		if(g.id == id){
			if(g.p == nil)
				g.p = IPint.strtoip(g.hex, 16);
			return (g.p, len g.hex/2);
		}
	}
	return (nil, 0);
}

#
# A private exponent for the group of p: uniform in 1..q-1, q = (p-1)/2
# the order of 2, made from 64 bits more than q has and reduced (FIPS
# 186-5 A.2.1's extra random bits), so that 2**r is uniform over the
# subgroup but for 1.
#
exponent(p: ref IPint): ref IPint
{
	init();
	one := IPint.inttoip(1);
	q := p.shr(1);
	return IPint.random(0, p.bits()+64).mod(q.sub(one)).add(one);
}

# 2 <= x <= p-2: an element whose square is of order q.  0, 1 and p-1
# are the values whose powers anybody knows (SP 800-56A 5.6.2.3.1 for
# the range; the order is seen to by the 2 in the exponent, see keys).
inrange(x, p: ref IPint): int
{
	if(x == nil || p == nil)
		return 0;
	init();
	return x.cmp(IPint.inttoip(1)) > 0 && x.cmp(p.sub(IPint.inttoip(1))) < 0;
}

# x, big-endian, in exactly n bytes (nil if it has more)
bebytes(x: ref IPint, n: int): array of byte
{
	init();
	b := x.iptobytes();
	while(len b > 0 && b[0] == byte 0)
		b = b[1:];
	if(len b > n)
		return nil;
	a := array[n] of {* => byte 0};
	a[n - len b:] = b;
	return a;
}

# Noncelen bytes from the system's generator (HMAC_DRBG, SP 800-90A)
nonce(): array of byte
{
	init();
	return bebytes(IPint.random(0, 8*Noncelen), Noncelen);
}

# equal, without saying by the time taken where they differ
same(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int (a[i] ^ b[i]);
	return d == 0;
}

hmac(suite: int, data, key: array of byte): array of byte
{
	if(suite == Aesgcm){
		d := array[Keyring->SHA384dlen] of byte;
		kr->hmac_sha384(data, len data, key, d, nil);
		return d;
	}
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

# HKDF-Expand (RFC 5869 2.3): n bytes from prk and info
expand(suite: int, prk, info: array of byte, n: int): array of byte
{
	out := array[0] of byte;
	t := array[0] of byte;
	for(i := 1; len out < n; i++){
		t = hmac(suite, cat(cat(t, info), array[] of {byte i}), prk);
		old := out;
		out = cat(out, t);
		zero(old);
	}
	# a copy, so that zeroing the result leaves nothing of it behind
	r := array[n] of byte;
	r[0:] = out[0:n];
	zero(out);
	zero(t);
	return r;
}

#
# x under the password's keystream, and back (the same operation).
# The key and nonce are by HKDF (RFC 5869) from pw, the SHA-256 of the
# password, with both ends' nonces as the salt and the suite, group and
# name in the info, so a keystream is of one conversation: the signer's
# nonce is fresh whatever the client sends.  The stream is the AEAD's
# own (ChaCha20's, or AES-256 in counter mode as GCM runs it) with its
# tag thrown away.  That is the point: sealed, the tag told a guesser
# which password was right, from one message to anybody who asked.
#
mask(suite, gid: int, name: string, pw, cnonce, snonce, x: array of byte): array of byte
{
	init();
	prk := hmac(suite, pw, cat(cnonce, snonce));
	info := cat(array of byte "infernode login 3 mask", array[] of {byte 0, byte suite, byte gid});
	okm := expand(suite, prk, cat(info, array of byte name), 32+12);
	out := stream(suite, okm, x);
	zero(prk);
	zero(okm);
	return out;
}

# x under the suite's AEAD's keystream (key || nonce in okm), its tag
# thrown away: the same operation encrypts and decrypts
stream(suite: int, okm, x: array of byte): array of byte
{
	out: array of byte;
	if(suite == Aesgcm)
		(out, nil) = kr->aesgcmencrypt(kr->aesgcmsetup(okm[0:32], okm[32:]), x, nil);
	else
		(out, nil) = kr->ccpolyencrypt(x, nil, okm[0:32], okm[32:]);
	return out;
}

#
# The ML-KEM encapsulation key's seed rho under a keystream of pw and
# the Diffie-Hellman secret z, and back.  z is in it so that the mask
# holds while either problem does: a party that can take logarithms
# finds z for each password it guesses, unmasks a seed, and is left
# with ML-KEM's question of whether the key's other half goes with it;
# one that can answer that question but not take logarithms has no z,
# and so no seed to ask about.
#
kemmask(suite, gid: int, name: string, pw, cnonce, snonce, z, rho: array of byte): array of byte
{
	init();
	ikm := cat(z, pw);
	prk := hmac(suite, ikm, cat(cnonce, snonce));
	zero(ikm);
	info := cat(array of byte "infernode login 3 kem mask", array[] of {byte 0, byte suite, byte gid});
	okm := expand(suite, prk, cat(info, array of byte name), 32+12);
	out := stream(suite, okm, rho);
	zero(prk);
	zero(okm);
	return out;
}

# ML-KEM-768 for suite 1, ML-KEM-1024 (CNSA 2.0) for suite 2
kemsizes(suite: int): (int, int)
{
	if(suite == Aesgcm)
		return (Keyring->MLKEM1024_PKLEN, Keyring->MLKEM1024_CTLEN);
	return (Keyring->MLKEM768_PKLEN, Keyring->MLKEM768_CTLEN);
}

kemkeygen(suite: int): (array of byte, array of byte)
{
	init();
	{
		if(suite == Aesgcm)
			return kr->mlkem1024_keygen();
		return kr->mlkem768_keygen();
	} exception {
	"*" =>
		return (nil, nil);
	}
}

kemencaps(suite: int, ek: array of byte): (array of byte, array of byte)
{
	init();
	(eklen, nil) := kemsizes(suite);
	if(ek == nil || len ek != eklen)
		return (nil, nil);
	{
		if(suite == Aesgcm)
			return kr->mlkem1024_encaps(ek);
		return kr->mlkem768_encaps(ek);
	} exception {
	"*" =>
		return (nil, nil);
	}
}

kemdecaps(suite: int, dk, ct: array of byte): array of byte
{
	init();
	(nil, ctlen) := kemsizes(suite);
	if(dk == nil || ct == nil || len ct != ctlen)
		return nil;
	{
		if(suite == Aesgcm)
			return kr->mlkem1024_decaps(dk, ct);
		return kr->mlkem768_decaps(dk, ct);
	} exception {
	"*" =>
		return nil;
	}
}

lenpfx(a: array of byte): array of byte
{
	return cat(array[] of {byte (len a>>8), byte len a}, a);
}

#
# From the secret z = 2**(2*r0*r1) mod p, the ML-KEM secret k, the
# password and everything said so far: the client's proof, the
# signer's, and the secret the rest is sealed under.  HKDF again: the
# salt is the hash of the conversation (so both ends agree on the name,
# the suite, the group, the nonces, both values, the masked key and the
# ciphertext, or on nothing), the key material k, z and pw.  Both
# secrets are there so that the session holds while either problem
# does: SP 800-56C rev. 2's Z || T, the ML-KEM secret (SP 800-227) the
# Z and the rest the T, so the approved one is first whatever the
# group; pw so that a secret somebody contrived to know is still not
# enough.
#
keys(suite: int, name: string, pw, hello, reply, share, ct, z, k: array of byte): (array of byte, array of byte, array of byte)
{
	init();
	tr := array of byte "infernode login 3 transcript";
	tr = cat(tr, lenpfx(array of byte name));
	tr = cat(tr, lenpfx(hello));
	tr = cat(tr, lenpfx(reply));
	tr = cat(tr, lenpfx(share));
	tr = cat(tr, lenpfx(ct));
	th: array of byte;
	if(suite == Aesgcm){
		th = array[Keyring->SHA384dlen] of byte;
		kr->sha384(tr, len tr, th, nil);
	}else{
		th = array[Keyring->SHA256dlen] of byte;
		kr->sha256(tr, len tr, th, nil);
	}
	kz := cat(k, z);
	ikm := cat(kz, pw);
	zero(kz);
	prk := hmac(suite, ikm, th);
	zero(ikm);
	n := len th;
	cproof := expand(suite, prk, array of byte "infernode login 3 client proof", n);
	sproof := expand(suite, prk, array of byte "infernode login 3 signer proof", n);
	sk := expand(suite, prk, array of byte "infernode login 3 session", n);
	zero(prk);
	return (cproof, sproof, sk);
}

#
# CNSA 2.0 mode: the /env/cnsamode policy flag (the emulator sets it
# from the host's CNSAMODE).  Anything in it but 0, n or N as its first
# byte is on, so a word nobody expected errs to the stricter side.
#
# The mode is a rule, not a default: what it takes is ML-DSA-87 for
# signatures (FIPS 204, category 5), SHA-384 or SHA-512 under them, and
# a Diffie-Hellman modulus of 3072 bits or more
# (docs/compliance/CNSA-2.0.md).  It used to choose only what a program
# made when nothing was asked for: createsignerkey -a rsa -b 512 gave a
# 512-bit RSA signer in the mode, and logind signed with whatever key
# its file held.  Every program that makes or takes a key asks here, so
# there is one statement of the rule.
#
cnsamode(): int
{
	if(init() != nil)
		return 1;	# cannot tell: the stricter side
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

cnsaalg(alg: string): string
{
	if(alg == CNSAsig)
		return nil;
	if(alg == nil)
		alg = "a key of no algorithm";
	return "CNSA mode takes ML-DSA-87 (mldsa87) signature keys alone, not " + alg;
}

cnsahash(ha: string): string
{
	if(ha == "sha384" || ha == "sha512")
		return nil;
	if(ha == nil)
		ha = "no hash";
	return "CNSA mode takes SHA-384 or SHA-512 under a signature, not " + ha;
}

# A key file as readauthinfo gives it: the holder's key, the signer's
# key, the certificate's algorithm and hash, and the realm's modulus.
cnsakey(info: ref Keyring->Authinfo): string
{
	if(init() != nil)
		return "cannot load Keyring";
	if(info == nil)
		return "no key";
	err: string;
	if(info.mysk != nil && info.mysk.sa != nil && (err = cnsaalg(info.mysk.sa.name)) != nil)
		return "its secret key: " + err;
	if(info.mypk == nil || info.mypk.sa == nil)
		return "it has no public key";
	if((err = cnsaalg(info.mypk.sa.name)) != nil)
		return "its public key: " + err;
	if(info.spk == nil || info.spk.sa == nil)
		return "it has no signer's key";
	if((err = cnsaalg(info.spk.sa.name)) != nil)
		return "its signer's key: " + err;
	if(info.cert == nil || info.cert.sa == nil)
		return "it has no certificate";
	if((err = cnsaalg(info.cert.sa.name)) != nil)
		return "its certificate: " + err;
	if((err = cnsahash(info.cert.ha)) != nil)
		return "its certificate: " + err;
	if(info.p == nil || info.alpha == nil)
		return "it has no Diffie-Hellman modulus";
	bits := info.p.bits();
	if(bits < CNSAdhbits)
		return sys->sprint("its Diffie-Hellman modulus has %d bits: CNSA mode takes %d or more", bits, CNSAdhbits);
	return nil;
}

# Keyring's putstring refuses what does not fit one of its messages
# (it cut it once and said it had sent it: a certificate cut short was
# "not a certificate" at the far end, with nothing to say why).  What
# it returns is the bytes written, the message's header among them.
putstring(fd: ref Sys->FD, s: string): string
{
	if(init() != nil)
		return "cannot load Keyring";
	n := len array of byte s;
	m := kr->putstring(fd, s);
	if(m < 0)
		return sys->sprint("%d bytes: %r", n);
	if(m <= n)
		return sys->sprint("%d bytes are more than was sent (%d)", n, m);
	return nil;
}

#
# A secret as it is typed.  Limbo cannot clear a string (a store into
# one copies it, and the copy is what is changed), nor an IPint or a
# digest's state: so a secret is kept as an array of bytes from the
# read that brought it, and zeroed by whoever is done with it.  The
# programs that asked for one each read a line into a string in raw
# mode, where the console does no editing: a backspace typed to
# correct a slip was a character of the password, and so was a \r.
#
readsecret(io: ref Sys->FD): (array of byte, string)
{
	if(init() != nil)
		return (nil, "cannot load Keyring");
	ctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "rawon") < 0)
		return (nil, sys->sprint("cannot turn the console's echo off: %r"));
	line := array[Maxsecret] of byte;
	n := 0;
	buf := array[256] of byte;
	err: string;
	done := 0;
	while(!done){
		r := sys->read(io, buf, len buf);
		if(r <= 0){
			err = "end of input";
			break;
		}
		for(i := 0; i < r && !done; i++){
			case int buf[i] {
			'\n' =>
				done = 1;
			'\r' =>
				;
			'\b' or 16r7f =>
				# one character: its continuation bytes, then its first
				while(n > 0 && (int line[n-1] & 16rC0) == 16r80)
					line[--n] = byte 0;
				if(n > 0)
					line[--n] = byte 0;
			16r15 =>	# ^U
				zero(line);
				n = 0;
			* =>
				if(n >= len line){
					err = "secret too long";
					done = 1;
				}else
					line[n++] = buf[i];
			}
		}
	}
	zero(buf);
	sys->fprint(ctl, "rawoff");
	sys->fprint(sys->fildes(1), "\n");
	if(err != nil){
		zero(line);
		return (nil, err);
	}
	out := array[n] of byte;
	out[0:] = line[0:n];
	zero(line);
	return (out, nil);
}

zero(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

runes(a: array of byte): int
{
	n := 0;
	for(i := 0; i < len a; i++)
		if((int a[i] & 16rC0) != 16r80)
			n++;
	return n;
}

nomod(mod: string): (string, ref Keyring->Authinfo)
{
	return (sys->sprint("can't load module %s: %r", mod), nil);
}

#
# Failed-attempt throttle (NIST SP 800-53 AC-7; CC FIA_AFL.1), as
# secstored(8) has: Maxfail attempts in a row that do not prove the
# password lock the name for Locksecs, refused before any key exchange.
# A name that is no account is counted and locked the same way, and
# refused in the same words, so the throttle says nothing of who has an
# account.  It is here, and not in logind, because keysrv(4) takes
# proofs of the same passwords and they are counted in the one place.
#
# Each connection is a logind of its own (svc/auth: listen ...
# {auth/logind&}), so the counts cannot be in memory as secstored's
# are: they are in Failfile, read and written whole under Failfile.lock,
# made exclusively and removed on close, so a logind that dies holding
# it leaves nothing behind. An attempt is counted when it begins (the
# lock taken for it, before the exchange), and the count cleared only
# when the client has proved it has the session's secret, which only the
# password gives; so every other end -- a wrong password, a client that
# hangs up after the server's message, a value refused, a time out, a
# logind killed -- stays counted, and many connections opened at once
# for one name are counted as they start, not after they fail.
#
# Names are kept as the SHA-256 of the name, so the file holds no names
# and a name cannot break its lines; a name is one name (okname) before
# it comes here, so there is one count for an account. A count not added
# to for Forgetsecs is forgotten (AC-7's "during a time period"); past
# Maxentries the oldest unlocked counts are dropped, so names made up by
# the million do not make the file, which every login reads, grow
# without end. The file cannot be read or written, or its lock cannot be
# had: the attempt is refused (closed, not open).
#
Maxfail: con 10;	# attempts in a row not proving the password
Locksecs: con 60;	# then refused for this long
Forgetsecs: con 15*60;	# a count left this long is forgotten
Maxentries: con 4096;	# unlocked counts kept
Lockwait: con 8000;	# ms to wait for Failfile.lock
Lockstale: con 2000;	# ms a lock's word is unchanged before it is taken for abandoned
Stalepolls: con 100;	# and looks at it, 10 ms apart
failfile := "/keydb/loginfail";

Fail: adt {
	key:	string;	# hex SHA-256 of the name
	fails:	int;	# attempts in a row not proving the password
	last:	int;	# when the last began
	until:	int;	# refused until then; 0, not yet set
};

cons: ref Sys->FD;

tinit(): string
{
	err := init();
	if(err != nil)
		return err;
	if(daytime == nil){
		daytime = load Daytime Daytime->PATH;
		if(daytime == nil)
			return sys->sprint("can't load %s: %r", Daytime->PATH);
		cons = sys->open("/dev/cons", Sys->OWRITE);
		if(cons == nil)
			cons = sys->fildes(2);
		audit = load Audit Audit->PATH;	# optional: the audit log
		if(audit != nil)
			audit->init();
	}
	return nil;
}

failkey(name: string): string
{
	b := array of byte name;
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(b, len b, d, nil);
	h := "";
	for(i := 0; i < len d; i++)
		h += sys->sprint("%.2ux", int d[i]);
	return h;
}

auditlog(prog, event, msg: string)
{
	if(audit != nil)
		audit->log(prog, event, msg);
}

# a name the client sent, as one value of a record: quoted, it still read
# as more fields when it held a blank and a key of its own
auditval(s: string): string
{
	if(audit == nil)
		return "";
	return audit->value(s);
}

# Count an attempt for name, by prog: the seconds it is still refused
# for (and then it is not counted), or 0 and the attempt counted. Counts
# reach Maxfail at most, and only one at Maxfail is refused.
charge(prog, name: string): (int, string)
{
	err := tinit();
	if(err != nil)
		return (0, err);
	key := failkey(name);
	lk: ref Sys->FD;
	(lk, err) = failock();
	if(lk == nil)
		return (0, err);
	now := daytime->now();
	fl := prune(loadfails(), now);
	e: ref Fail;
	for(l := fl; l != nil; l = tl l)
		if((hd l).key == key){
			e = hd l;
			break;
		}
	if(e != nil && e.fails >= Maxfail){
		# Maxfail attempts in a row, none proving the password: refused
		# for Locksecs from the last of them. The lock is set here, by
		# the attempt after them, so a last that worked locks nothing.
		if(e.until == 0){
			e.until = e.last + Locksecs;
			if(e.until > now){
				sys->fprint(cons, "%s: %q locked after %d attempts not proving the password (%ds)\n", prog, name, e.fails, Locksecs);
				auditlog(prog, "authlock", sys->sprint("user=%s fails=%d locksecs=%d", auditval(name), e.fails, Locksecs));
				err = storefails(fl);
				if(err != nil)
					return (0, err);
			}
		}
		if(e.until > now)
			return (e.until - now, nil);	# lk let go as it goes
		e.fails = 0;	# the cooldown is over: a fresh count
		e.until = 0;
	}
	if(e == nil){
		e = ref Fail(key, 0, 0, 0);
		fl = e :: fl;
	}
	e.fails++;
	e.last = now;
	err = storefails(fl);
	lk = nil;
	if(err != nil)
		return (0, err);
	return (0, nil);
}

# The password proved: name's count gone.
cleared(prog, name: string)
{
	err := tinit();
	if(err != nil)
		return;
	key := failkey(name);
	lk: ref Sys->FD;
	(lk, err) = failock();
	if(lk == nil){
		sys->fprint(cons, "%s: can't clear a count: %s\n", prog, err);
		return;
	}
	fl := loadfails();
	nl: list of ref Fail;
	found := 0;
	for(; fl != nil; fl = tl fl)
		if((hd fl).key == key)
			found = 1;
		else
			nl = hd fl :: nl;
	if(found){
		err = storefails(nl);
		if(err != nil)
			sys->fprint(cons, "%s: can't clear a count: %s\n", prog, err);
	}
	lk = nil;
}
# The counts still to keep at now: a lock run out and a count left
# Forgetsecs gone; past Maxentries unlocked, the oldest of those gone.
prune(fl: list of ref Fail, now: int): list of ref Fail
{
	locked, open: list of ref Fail;
	nopen := 0;
	for(; fl != nil; fl = tl fl){
		e := hd fl;
		if(e.fails >= Maxfail){
			until := e.until;
			if(until == 0)
				until = e.last + Locksecs;
			if(until > now)
				locked = e :: locked;
		}else if(now - e.last < Forgetsecs){
			open = e :: open;
			nopen++;
		}
	}
	if(nopen > Maxentries){
		a := array[nopen] of ref Fail;
		i := 0;
		for(; open != nil; open = tl open)
			a[i++] = hd open;
		sortlast(a);
		for(i = nopen - Maxentries; i < nopen; i++)
			open = a[i] :: open;
	}
	for(; open != nil; open = tl open)
		locked = hd open :: locked;
	return locked;
}

# oldest first, by last (Shell's sort)
sortlast(a: array of ref Fail)
{
	for(gap := len a / 2; gap > 0; gap /= 2)
		for(i := gap; i < len a; i++)
			for(j := i - gap; j >= 0 && a[j].last > a[j+gap].last; j -= gap)
				(a[j], a[j+gap]) = (a[j+gap], a[j]);
}

# Failfile's counts; a line that is not one (a torn write) is left out.
loadfails(): list of ref Fail
{
	fd := sys->open(failfile, Sys->OREAD);
	if(fd == nil)
		return nil;
	data := "";
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		data += string buf[0:n];
	fl: list of ref Fail;
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " ");
		if(nf != 4 || len hd f != 2*Keyring->SHA256dlen)
			continue;
		e := ref Fail(hd f, int hd tl f, int hd tl tl f, int hd tl tl tl f);
		if(e.fails <= 0)
			continue;
		fl = e :: fl;
	}
	return fl;
}

storefails(fl: list of ref Fail): string
{
	fd := sys->create(failfile, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't write %s: %r", failfile);
	s := "";
	for(; fl != nil; fl = tl fl){
		e := hd fl;
		s += sys->sprint("%s %d %d %d\n", e.key, e.fails, e.last, e.until);
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("can't write %s: %r", failfile);
	return nil;
}

#
# Failfile.lock, made exclusively and removed when its fd goes; its
# holder writes a word of its own into it.  A lock is held for a read
# and a write of a small file, so one whose word has not changed for
# Lockstale ms of this waiter's own clock, through Stalepolls looks,
# was left by a holder that is gone (a host that went down), and is
# removed: if it still has that word, so that a lock taken since by
# somebody else is not the one removed.  The time is the waiter's
# millisecond clock and not the file's: staleness was "older than a
# minute by the time of day", so a lock left with the clock ahead (and
# then stepped back, as timesync does) refused every login until the
# clock caught up, and a clock stepped forward made a live lock look
# abandoned; and the remove was by name, after a stat, of whatever was
# there by then.
#
failock(): (ref Sys->FD, string)
{
	lf := failfile + ".lock";
	t0 := sys->millisec();
	seen := "";
	seenat := t0;
	polls := 0;
	for(;;){
		fd := sys->create(lf, Sys->OWRITE|Sys->OEXCL|Sys->ORCLOSE, 8r600);
		if(fd != nil){
			sys->fprint(fd, "%d %d %s\n", sys->pctl(0, nil), t0, IPint.random(0, 64).iptostr(16));
			return (fd, nil);
		}
		err := sys->sprint("%r");
		(ok, nil) := sys->stat(lf);
		if(ok < 0){
			# not made and not there: the directory refuses it, unless
			# a holder let go between the two
			fd = sys->create(lf, Sys->OWRITE|Sys->OEXCL|Sys->ORCLOSE, 8r600);
			if(fd != nil){
				sys->fprint(fd, "%d %d %s\n", sys->pctl(0, nil), t0, IPint.random(0, 64).iptostr(16));
				return (fd, nil);
			}
			(ok, nil) = sys->stat(lf);
			if(ok < 0)
				return (nil, sys->sprint("can't make %s: %s", lf, err));
		}
		now := sys->millisec();
		word := lockword(lf);
		if(word != seen || polls == 0){
			seen = word;
			seenat = now;
			polls = 1;
		}else if(++polls >= Stalepolls && now - seenat > Lockstale){
			if(lockword(lf) == seen){
				sys->fprint(cons, "login: removing %s, left by a holder that is gone\n", lf);
				sys->remove(lf);
			}
			polls = 0;
		}
		if(now - t0 > Lockwait)
			return (nil, sys->sprint("%s held for %d ms", lf, Lockwait));
		sys->sleep(10);
	}
}

# what a lock file holds: its holder's word ("" before it is written,
# and for a lock of the form before, which held nothing)
lockword(lf: string): string
{
	fd := sys->open(lf, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

