#
#  security routines implemented in limbo
#


Virgil: module
{
	PATH:	con "/dis/lib/virgil.dis";

	virgil:	fn(args: list of string): string;
};

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
	Version:	con 2;
	Chacha:	con 1;	# suites: ChaCha20 and SHA-256
	Aesgcm:	con 2;	# AES-256-GCM and SHA-384 (CNSA)
	Noncelen:	con 32;
	# a group's prime and its length in bytes; nil for none of login(6)'s
	group:	fn(id: int): (ref Keyring->IPint, int);
	exponent:	fn(p: ref Keyring->IPint): ref Keyring->IPint;	# uniform in 1..(p-1)/2-1
	inrange:	fn(x, p: ref Keyring->IPint): int;	# 2 <= x <= p-2
	bebytes:	fn(x: ref Keyring->IPint, n: int): array of byte;	# big-endian in n bytes
	nonce:	fn(): array of byte;
	# x under the password's keystream, and back
	mask:	fn(suite, group: int, name: string, pw, cnonce, snonce, x: array of byte): array of byte;
	# the client's proof, the signer's, and the session's secret
	keys:	fn(suite: int, name: string, pw, hello, reply, share, z: array of byte):
			(array of byte, array of byte, array of byte);
	same:	fn(a, b: array of byte): int;	# equal, in time that does not say where not

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
