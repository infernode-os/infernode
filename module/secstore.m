Secstore: module
{
	PATH:	con "/dis/lib/secstore.dis";

	Maxfilesize: con 128*1024;	# default
	Maxmsg:	con 4096;

	init:		fn();
	privacy:	fn(): int;
	cansecstore:	fn(addr: string, user: string): int;
	mkseckey:	fn(pass: string): array of byte;
	mkseckey2:	fn(pass: string): array of byte;
	connect:		fn(addr: string, user: string, pwhash: array of byte): (ref Dial->Connection, string, string);
	connect2:	fn(addr: string, user: string, pwhash: array of byte, pwhash2: array of byte): (ref Dial->Connection, string, string);
	# Version 4 first (pwhash4 = mkseckey4(mkfilekey3(user, pass))); an
	# account at an older version is logged in to with the older
	# hashes, moved to version 4, and logged in to again.  A version 4
	# session's putfile and remove are answered by the server.
	mkseckey4:	fn(rootkey: array of byte): array of byte;
	connect4:	fn(addr: string, user: string, pwhash, pwhash2, pwhash4: array of byte): (ref Dial->Connection, string, string);
	setverifier:	fn(conn: ref Dial->Connection, version, hexHi: string): string;
	# The second factor's lock on the account's files: once the vault
	# key (made from the data key) is enrolled, the server stores and
	# removes only in a session that has shown it.
	vaultkey:	fn(dk: array of byte): array of byte;
	vaultstate:	fn(conn: ref Dial->Connection): (int, string);	# 1 enrolled, 0 not, -1 and why
	showvault:	fn(conn: ref Dial->Connection, wk: array of byte): (int, string);	# 1 shown, 0 none enrolled, -1 and why
	enrolvault:	fn(conn: ref Dial->Connection, wk: array of byte): string;
	unenrolvault:	fn(conn: ref Dial->Connection): string;
	dial:		fn(addr: string): ref Dial->Connection;
	auth:		fn(conn: ref Dial->Connection, user: string, pwhash: array of byte): (string, string);
	sendpin:	fn(conn: ref Dial->Connection, pin: string): int;
	# (name, size, date, hash as text, hash) of each file, or why not
	files:		fn(conn: ref Dial->Connection): (list of (string, int, string, string, array of byte), string);
	getfile:	fn(conn: ref Dial->Connection, filename: string, maxsize: int): array of byte;
	# (file, 0, nil); (nil, 1, nil) if the server has no such file;
	# (nil, 0, why) if it could not be read.  getfile is nil for both.
	fetch:		fn(conn: ref Dial->Connection, filename: string, maxsize: int): (array of byte, int, string);
	remove:	fn(conn: ref Dial->Connection, filename: string): int;
	putfile:	fn(conn: ref Dial->Connection, filename: string, data: array of byte): int;
	bye:		fn(conn: ref Dial->Connection);
	mkverifier:	fn(user, version: string, passhash: array of byte): string;
	formatverifier:	fn(version, hexHi: string): string;
	parseverifier:	fn(s: string): (string, string);

	# the keys of the two formats no longer written, for decrypt3 by
	# whoever moves an old file (auth/secstore m)
	mkfilekey:	fn(pass: string): array of byte;
	erasekey:	fn(a: array of byte);

	# Modern crypto (AES-256-GCM, HMAC-SHA256 key derivation)
	mkfilekey2:	fn(pass: string): array of byte;
	mkfilekey3:	fn(user, pass: string): array of byte;
	# Mix a hardware second-factor secret R into an already-stretched root key
	# to form a key-encryption key for a 2FA slot (see docs/second-factor-auth.md).
	mkkek2fa:	fn(rootkey, R: array of byte): array of byte;
	# SGCM2, the one format written.  decrypt3 reads an older format
	# only when given its key (gcm1key: mkfilekey2; legacykey: mkfilekey);
	# iscurrent says whether a file is SGCM2.
	encrypt3:	fn(a: array of byte, rootkey: array of byte): array of byte;
	decrypt3:	fn(a: array of byte, rootkey: array of byte, gcm1key: array of byte, legacykey: array of byte): array of byte;
	iscurrent:	fn(a: array of byte): int;

	lines:	fn(file: array of byte): list of array of byte;

	# version 5's exchange (secstore(2)'s PAK5), for the server: the
	# ML-KEM key's seed under sigma and the verifier (and back), and the
	# server's proof, the client's and the session's secret
	pak5mask:	fn(C, S, m, mu, sigma, Hi: string, rho: array of byte): array of byte;
	pak5keys:	fn(C, S, m, mu, sigma, Hi: string, ek, ct, k: array of byte): (array of byte, array of byte, array of byte);
	samebytes:	fn(a, b: array of byte): int;
};
