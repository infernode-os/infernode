#
# What X.509 and TLS use of the Public-Key Cryptography Standards:
# object identifiers, an RSA public key, PKCS #1 v1.5 encryption
#	RFC 8017 (PKCS #1), RFC 5480 (EC keys), RFC 5758, RFC 4055
#

PKCS: module {

	PATH: con "/dis/lib/crypt/pkcs.dis";

	init: fn(): string;

	# Object identifiers of keys, curves and signature algorithms,
	# for ASN1->oid_lookup
	objIdTab			: array of ASN1->Oid;

	id_pkcs_rsaEncryption,
	id_sha256WithRSAEncryption,
	id_sha384WithRSAEncryption,
	id_sha512WithRSAEncryption,
	id_ec_publicKey,
	id_ecdsa_sha256,
	id_ecdsa_sha384,
	id_ecdsa_sha512,
	id_prime256v1,
	id_secp384r1			: con iota;

	# An RSA public key
	RSAKey: adt {
		modulus			: ref Keyring->IPint;
		modlen			: int;	# its length in bytes
		exponent		: ref Keyring->IPint;

		bits: fn(k: self ref RSAKey): int;
	};

	# RSAES-PKCS1-v1_5 (RFC 8017 7.2.1) under a public key
	rsa_encrypt: fn(data: array of byte, key: ref RSAKey): (string, array of byte);

	# An RSAPublicKey's DER as a key that can be one, or an error:
	# an odd modulus of 2048 to 8192 bits, an odd public exponent
	# of 3 or more below it.
	decode_rsapubkey: fn(a: array of byte): (string, ref RSAKey);
};
