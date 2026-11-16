implement PKCS;

#
# What is left of the Public-Key Cryptography Standards here is what
# X.509 and TLS use: the object identifiers of the keys and signatures
# they take, an RSA public key read from a certificate, and RSA
# encryption for TLS 1.2's RSA key exchange.  The rest (PKCS #1
# decryption and MD2/MD5 signing, the DSS stubs, PKCS #3
# Diffie-Hellman, PKCS #5 password-based DES, the PKCS #6 and #8
# shells) served the SSL 3.0 client and went when it did.
#

include "sys.m";
	sys				: Sys;

include "keyring.m";
	keyring				: Keyring;
	IPint				: import keyring;

include "security.m";
	random				: Random;

include "asn1.m";
	asn1				: ASN1;
	Elem, Oid			: import asn1;

include "pkcs.m";

objIdTab = array [] of {
	id_pkcs_rsaEncryption => 	Oid(array [] of {1,2,840,113549,1,1,1}),
	id_sha256WithRSAEncryption =>	Oid(array [] of {1,2,840,113549,1,1,11}),
	id_sha384WithRSAEncryption =>	Oid(array [] of {1,2,840,113549,1,1,12}),
	id_sha512WithRSAEncryption =>	Oid(array [] of {1,2,840,113549,1,1,13}),
	id_ec_publicKey =>		Oid(array [] of {1,2,840,10045,2,1}),
	id_ecdsa_sha256 =>		Oid(array [] of {1,2,840,10045,4,3,2}),
	id_ecdsa_sha384 =>		Oid(array [] of {1,2,840,10045,4,3,3}),
	id_ecdsa_sha512 =>		Oid(array [] of {1,2,840,10045,4,3,4}),
	id_prime256v1 =>		Oid(array [] of {1,2,840,10045,3,1,7}),
	id_secp384r1 =>			Oid(array [] of {1,3,132,0,34}),
};

# [public]

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "load sys module failed";

	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return "load keyring module failed";

	random = load Random Random->PATH;
	if(random == nil)
		return "load random module failed";

	asn1 = load ASN1 ASN1->PATH;
	if(asn1 == nil)
		return "load asn1 module failed";
	asn1->init();

	return "";
}

# [public]
# RSAES-PKCS1-v1_5 encryption (RFC 8017 7.2.1): the block is
# 00 02 PS 00 M, PS at least eight octets, none of them zero.

rsa_encrypt(data: array of byte, key: ref RSAKey): (string, array of byte)
{
	if(key == nil || key.modulus == nil || key.exponent == nil)
		return ("null pkcs#1 key", nil);
	k := key.modlen;
	dlen := len data;
	if(k < 12 || dlen > k-11)
		return ("bad parameters for pkcs#1", nil);
	padlen := k-3-dlen;
	pad := random->randombuf(Random->NotQuiteRandom, padlen);
	if(len pad != padlen)
		return ("no source of random numbers", nil);
	for(i:=0; i < padlen; i++)
		if(pad[i] == byte 0)
			pad[i] = byte 1;
	eb := array[k] of byte;
	eb[0] = byte 0;
	eb[1] = byte 2;
	eb[2:] = pad[0:];
	eb[padlen+2] = byte 0;
	eb[padlen+3:] = data[0:];
	return ("", rsacomp(eb, key));
}

# [private]
# Do RSA computation on block according to key, and pad
# result on left with zeros to make it key.modlen long.

rsacomp(block: array of byte, key: ref RSAKey): array of byte
{
	x := keyring->IPint.bebytestoip(block);
	y := x.expmod(key.exponent, key.modulus);
	ybytes := y.iptobebytes();
	k := key.modlen;
	ylen := len ybytes;
	if(ylen < k) {
		a := array[k] of { * =>  byte 0};
		a[k-ylen:] = ybytes[0:];
		ybytes = a;
	}
	else if(ylen > k) {
		# assume it has leading zeros (mod should make it so)
		a := array[k] of byte;
		a[0:] = ybytes[ylen-k:];
		ybytes = a;
	}
	return ybytes;
}

# [public]

RSAKey.bits(key: self ref RSAKey): int
{
	return key.modulus.bits();
}

# [public]
# Decode an RSAPublicKey ASN1 type, defined as:
#
#	RSAPublickKey :: SEQUENCE {
#		modulus INTEGER,
#		publicExponent INTEGER
#	}

#
# A key is taken only if it can be one.  The numbers come from a
# peer's certificate, and whoever verifies with them does arithmetic
# modulo the first: a modulus of 0 was accepted, and RSA-PSS in a TLS
# handshake then divided by it before the chain had been looked at.
#   - both are positive INTEGERs (a first byte with its top bit set is
#     a negative number in DER, and was read as a large positive one);
#   - the modulus is odd (a product of two odd primes) and of
#     RSAMINBITS to RSAMAXBITS bits.  2048 is the least a CA may
#     certify (CA/Browser Forum Baseline Requirements 6.1.5) and the
#     least SP 800-131A r2 counts as acceptable rather than legacy; no
#     root in /lib/certs is shorter.  The upper bound is what the
#     verifiers already asked for, so that a key cannot be made to
#     cost seconds a signature.
#   - the public exponent is odd and at least 3 (SP 800-56B r2 6.2:
#     an odd integer; 1 makes a signature its own message), and less
#     than the modulus.

RSAMINBITS: con 2048;
RSAMAXBITS: con 8192;

# The bytes asn1 gives for an INTEGER, of a negative number (or none)?
# They are DER's, two's complement in the fewest bytes.
negative(b: array of byte): int
{
	return len b == 0 || (int b[0] & 16r80);
}

decode_rsapubkey(a: array of byte): (string, ref RSAKey)
{
parse:
	for(;;) {
		(err, e) := asn1->decode(a);
		if(err != "" || e == nil)
			break parse;
		(ok, el) := e.is_seq();
		if(!ok || len el != 2)
			break parse;
		modbytes, expbytes: array of byte;
		(ok, modbytes) = (hd el).is_bigint();
		if(!ok || negative(modbytes))
			break parse;
		modulus := IPint.bebytestoip(modbytes);
		# get modlen this way, because sometimes it
		# comes with leading zeros that are to be ignored!
		mbytes := modulus.iptobebytes();
		modlen := len mbytes;
		(ok, expbytes) = (hd tl el).is_bigint();
		if(!ok || negative(expbytes))
			break parse;
		exponent := keyring->IPint.bebytestoip(expbytes);
		bits := modulus.bits();
		if(bits < RSAMINBITS)
			return (sys->sprint("rsa public key: modulus of %d bits, under %d", bits, RSAMINBITS), nil);
		if(bits > RSAMAXBITS)
			return (sys->sprint("rsa public key: modulus of %d bits, over %d", bits, RSAMAXBITS), nil);
		if((int modbytes[len modbytes-1] & 1) == 0)
			return ("rsa public key: even modulus", nil);
		if((int expbytes[len expbytes-1] & 1) == 0 || exponent.bits() < 2)
			return ("rsa public key: public exponent even or under 3", nil);
		if(exponent.cmp(modulus) >= 0)
			return ("rsa public key: public exponent not under the modulus", nil);
		return ("", ref RSAKey(modulus, modlen, exponent));
	}
	return ("rsa public key: syntax error", nil);
}
