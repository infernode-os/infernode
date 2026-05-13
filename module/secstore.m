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
	dial:		fn(addr: string): ref Dial->Connection;
	auth:		fn(conn: ref Dial->Connection, user: string, pwhash: array of byte): (string, string);
	sendpin:	fn(conn: ref Dial->Connection, pin: string): int;
	files:		fn(conn: ref Dial->Connection): list of (string, int, string, string, array of byte);
	getfile:	fn(conn: ref Dial->Connection, filename: string, maxsize: int): array of byte;
	remove:	fn(conn: ref Dial->Connection, filename: string): int;
	putfile:	fn(conn: ref Dial->Connection, filename: string, data: array of byte): int;
	bye:		fn(conn: ref Dial->Connection);
	mkverifier:	fn(user, version: string, passhash: array of byte): string;
	formatverifier:	fn(version, hexHi: string): string;
	parseverifier:	fn(s: string): (string, string);

	mkfilekey:	fn(pass: string): array of byte;
	decrypt:	fn(a: array of byte, key: array of byte): array of byte;
	encrypt:	fn(a: array of byte, key: array of byte): array of byte;
	erasekey:	fn(a: array of byte);

	# Modern crypto (AES-256-GCM, HMAC-SHA256 key derivation)
	mkfilekey2:	fn(pass: string): array of byte;
	mkfilekey3:	fn(user, pass: string): array of byte;
	encrypt2:	fn(a: array of byte, key: array of byte): array of byte;
	decrypt2:	fn(a: array of byte, key: array of byte, legacykey: array of byte): array of byte;
	encrypt3:	fn(a: array of byte, rootkey: array of byte): array of byte;
	decrypt3:	fn(a: array of byte, rootkey: array of byte, gcm1key: array of byte, legacykey: array of byte): array of byte;

	lines:	fn(file: array of byte): list of array of byte;
};
