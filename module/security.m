#
#  security routines implemented in limbo
#


Random: module
{
	PATH:	con "/dis/lib/random.dis";

	ReallyRandom:	con 0;
	NotQuiteRandom:	con 1;

	randomint: fn(which: int): int;
	randombuf: fn(which, n: int): array of byte;
};

#
#  secure socket layer emulator
#
SSL: module
{
	PATH:	con "/dis/lib/ssl.dis";

	connect: fn(fd: ref Sys->FD): (string, ref Sys->Connection);
	secret: fn(c: ref Sys->Connection, secretin, secretout: array of byte): string;
	# one secret both ends share, as each way's own: (secretin, secretout)
	secrets: fn(shared: array of byte, client: int): (array of byte, array of byte);
};


#
#  Encrypted Key Exchange protocol: login(6)
#
Login: module 
{
	PATH:	con "/dis/lib/login.dis";

	# the client's side: a certificate for id from the signer at dest
	login:	fn(id, password, dest: string): (string, ref Keyring->Authinfo);

	# The rest is what the signer's programs (logind(8), keysrv(4),
	# signer(8), changelogin(8)) share with it, so there is one of each.

	# nil, or why name is not one account name
	okname:	fn(name: string): string;

	# login(6)'s exchange
	Version:	con 3;
	Chacha:	con 1;	# suites: ChaCha20, SHA-256 and ML-KEM-768
	Aesgcm:	con 2;	# AES-256-GCM, SHA-384 and ML-KEM-1024 (CNSA)
	Noncelen:	con 32;
	Rholen:	con 32;	# the seed at an ML-KEM encapsulation key's end (FIPS 203)
	# a group's prime and its length in bytes; nil for none of login(6)'s
	group:	fn(id: int): (ref Keyring->IPint, int);
	exponent:	fn(p: ref Keyring->IPint): ref Keyring->IPint;	# uniform in 1..(p-1)/2-1
	inrange:	fn(x, p: ref Keyring->IPint): int;	# 2 <= x <= p-2
	bebytes:	fn(x: ref Keyring->IPint, n: int): array of byte;	# big-endian in n bytes
	nonce:	fn(): array of byte;
	# x under the password's keystream, and back
	mask:	fn(suite, group: int, name: string, pw, cnonce, snonce, x: array of byte): array of byte;
	# the suite's ML-KEM: its encapsulation key's and ciphertext's lengths,
	# and its three operations (nil where Keyring refuses a key or
	# ciphertext, as it does an encapsulation key that is not one)
	kemsizes:	fn(suite: int): (int, int);
	kemkeygen:	fn(suite: int): (array of byte, array of byte);	# (ek, dk)
	kemencaps:	fn(suite: int, ek: array of byte): (array of byte, array of byte);	# (ct, k)
	kemdecaps:	fn(suite: int, dk, ct: array of byte): array of byte;	# k
	# the encapsulation key's seed under a keystream of the password and
	# the Diffie-Hellman secret, and back
	kemmask:	fn(suite, group: int, name: string, pw, cnonce, snonce, z, rho: array of byte): array of byte;
	# the client's proof, the signer's, and the session's secret
	keys:	fn(suite: int, name: string, pw, hello, reply, share, ct, z, k: array of byte):
			(array of byte, array of byte, array of byte);
	same:	fn(a, b: array of byte): int;	# equal, in time that does not say where not

	# CNSA 2.0 mode (/env/cnsamode) and what it takes, for every
	# program that makes or takes a key in it: each gives nil, or why not.
	CNSAsig:	con "mldsa87";	# signatures: ML-DSA-87 alone (FIPS 204)
	CNSAdhbits:	con 3072;	# the least Diffie-Hellman modulus
	CNSAgroup:	con 15;	# RFC 3526's 3072-bit group, for a new key file
	cnsamode:	fn(): int;
	cnsaalg:	fn(alg: string): string;	# a signature algorithm's name
	cnsahash:	fn(ha: string): string;	# a certificate's hash
	cnsakey:	fn(info: ref Keyring->Authinfo): string;	# a key file, all of it
	# a string as one of Keyring's messages, whole or not at all
	putstring:	fn(fd: ref Sys->FD, s: string): string;

	# A secret typed on io with the console's echo off: its bytes (the
	# line edited as typed: backspace, ^U; no \r), or nil and why.  It
	# is never a string, which cannot be cleared: the caller zeroes it.
	Maxsecret:	con 1024;
	readsecret:	fn(io: ref Sys->FD): (array of byte, string);
	zero:	fn(a: array of byte);
	runes:	fn(a: array of byte): int;	# characters in UTF-8

	# logind(8)'s count, by name, of attempts that did not prove a
	# password: the seconds name is still refused for, or 0 and this
	# attempt counted until cleared
	charge:	fn(prog, name: string): (int, string);
	cleared:	fn(prog, name: string);
};

#
#  Station To Station protocol
#
Auth: module
{
	PATH:	con "/dis/lib/auth.dis";

	init: fn(): string;
	server: fn(algs: list of string, ai: ref Keyring->Authinfo, fd: ref Sys->FD, setid: int): (ref Sys->FD, string);
	client: fn(alg: string, ai: ref Keyring->Authinfo, fd: ref Sys->FD): (ref Sys->FD, string);
	auth:	fn(ai: ref Keyring->Authinfo, keyspec: string, alg: string, dfd: ref Sys->FD): (ref Sys->FD, ref Keyring->Authinfo, string);
	keyfile:	fn(keyspec: string): string;
	key:	fn(keyspec: string): ref Keyring->Authinfo;
};
