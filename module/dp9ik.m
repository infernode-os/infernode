#
# dp9ik(2): 9front's dp9ik authentication, as a client speaks it.
#
# The pieces of 9front's libauthsrv a client needs (authsrv(6) on 9front):
# the AES key a password gives (passtokey), the PAK hash of a user's key
# (authpak_hash: HKDF-SHA256, then Elligator2 onto Ed448-Goldilocks), the
# SPAKE2-EE key exchange with the auth server (authpak_new and _finish),
# the form1 tickets and authenticators sealed with ChaCha20-Poly1305, the
# ticket request, and the session secret (HKDF-SHA256, 256 bytes) that
# rcpu(1)'s TLS takes as its pre-shared key.
#
# Classical cryptography only, interoperability with 9front its purpose:
# not CNSA 2.0, refused in CNSA mode by everything that uses it, and off
# unless a dp9ik key is given to factotum (factotum(4)).
#
Dp9ik: module
{
	PATH:	con "/dis/lib/dp9ik.dis";

	init:	fn(): string;

	# authsrv.h
	ANAMELEN:	con 28;
	DOMLEN:	con 48;
	AESKEYLEN:	con 16;
	CHALLEN:	con 8;
	NONCELEN:	con 32;
	PAKKEYLEN:	con 32;
	PAKSLEN:	con 56;		# an Ed448 scalar or coordinate
	PAKPLEN:	con 4*PAKSLEN;	# a point, X Y Z T
	PAKHASHLEN:	con 2*PAKPLEN;	# the points PM and PN
	PAKYLEN:	con PAKSLEN;	# a public key, decaf encoded
	TICKREQLEN:	con 3*ANAMELEN+CHALLEN+DOMLEN+1;
	TICKETLEN:	con 12+CHALLEN+2*ANAMELEN+NONCELEN+16;	# form1
	AUTHENTLEN:	con 12+CHALLEN+NONCELEN+16;	# form1
	SECRETLEN:	con 256;	# dp9ik's session secret

	# message types
	AuthTreq:	con 1;
	AuthOK:	con 4;
	AuthErr:	con 5;
	AuthOKvar:	con 9;
	AuthPAK:	con 19;
	AuthTs:	con 64;
	AuthTc:	con 65;
	AuthAs:	con 66;
	AuthAc:	con 67;

	Ticketreq: adt {
		rtype:	int;
		authid:	string;
		authdom:	string;
		chal:	array of byte;	# CHALLEN
		hostid:	string;
		uid:	string;

		pack:	fn(t: self ref Ticketreq): array of byte;
		unpack:	fn(a: array of byte): (ref Ticketreq, string);
	};

	Ticket: adt {
		num:	int;
		chal:	array of byte;	# CHALLEN
		cuid:	string;
		suid:	string;
		key:	array of byte;	# NONCELEN
	};

	Authenticator: adt {
		num:	int;
		chal:	array of byte;	# CHALLEN
		rand:	array of byte;	# NONCELEN
	};

	# passtokey's AES half: PBKDF2-HMAC-SHA1, 9001 iterations
	passtoaeskey:	fn(password: array of byte): array of byte;
	# the PAK hash of a user's AES key: PM then PN, PAKHASHLEN bytes
	authpakhash:	fn(aeskey: array of byte, user: string): array of byte;

	# One side of the SPAKE2-EE exchange.  new makes the private scalar
	# (given, for known answers, or random) and the public key y;
	# finish takes the other side's y and gives the shared pakkey, or nil
	# for a public key that is none (a malformed one).
	Pak: adt {
		x:	ref Keyring->IPint;
		y:	array of byte;
		isclient:	int;
		pakhash:	array of byte;

		new:	fn(pakhash: array of byte, isclient: int, x: array of byte): ref Pak;
		finish:	fn(p: self ref Pak, y: array of byte): array of byte;
	};

	# form1: sealed under key (32 bytes) with ChaCha20-Poly1305, the
	# nonce the message type's signature and a counter
	sealticket:	fn(t: ref Ticket, key: array of byte): array of byte;
	openticket:	fn(a: array of byte, key: array of byte): (ref Ticket, string);
	sealauth:	fn(a: ref Authenticator, key: array of byte): array of byte;
	openauth:	fn(b: array of byte, key: array of byte): (ref Authenticator, string);

	# the 256-byte session secret from the two nonces and the ticket key
	sessionsecret:	fn(rand: array of byte, tkey: array of byte): array of byte;

	# n bytes from the system's generator (IPint.random's)
	randombytes:	fn(n: int): array of byte;
	hkdf:	fn(salt, info, ikm: array of byte, n: int): array of byte;
	zero:	fn(a: array of byte);
};
