#
# The password exchange of login(6): PAK (Boyko, MacKenzie and Patel,
# as Plan 9's secstore has it) with an ML-KEM exchange mixed into its
# confirmations and session key. Neither a transcript nor a session
# run against either side lets a password guess be checked off line;
# a recorded transcript stays sealed unless both the discrete log and
# ML-KEM are broken. login(2) and logind(8) are its two sides.
#
# Include keyring.m before this.
#
Loginpak: module
{
	PATH:	con "/dis/lib/loginpak.dis";

	Version:	con "inflogin2";	# the protocol's first line, and its hashes' label
	Sessionlen:	con Keyring->SHA384dlen;
	Proglen:	con Keyring->SHA384dlen;	# k and k'

	init:	fn(): string;

	# "mlkem1024" in CNSA mode, else "mlkem768"
	kemname:	fn(cnsa: int): string;

	# H, the password's element of the group: SHA-384 expanded over
	# user and pw (the password's SHA-256, as changelogin(8) keeps it),
	# raised to (p-1)/q.
	pwelem:	fn(user: string, pw: array of byte): ref Keyring->IPint;

	Client: adt {
		kem:	string;
		user:	string;
		x:	ref Keyring->IPint;
		H:	ref Keyring->IPint;
		m:	string;		# g**x * H, base 64
		ek:	array of byte;	# ML-KEM encapsulation key
		dk:	array of byte;
		session:	array of byte;

		new:	fn(kem, user: string, pw: array of byte): (ref Client, string);
		# the server's mu, ct and k; k' to send, or an error
		respond:	fn(c: self ref Client, mu: string, ct, k: array of byte): (array of byte, string);
	};

	Server: adt {
		kem:	string;
		kprime:	array of byte;
		session:	array of byte;

		# H nil (no such user): an element of nobody's, so the exchange
		# runs as for a user and fails at k'. Returns mu, ct, k to send.
		new:	fn(kem, user: string, H: ref Keyring->IPint, m: string, ek: array of byte):
			(ref Server, string, array of byte, array of byte, string);
		# 1 if the client's k' proves it has the password
		check:	fn(s: self ref Server, kprime: array of byte): int;
	};
};
