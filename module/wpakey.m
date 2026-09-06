#
#	WPA2-PSK key derivation and the EAPOL four-way handshake.
#
#	Everything here is mechanism.  No file is opened, nothing is
#	timed, no key is installed: Supp.recv takes one received EAPOL
#	frame and returns the list of things its caller must then do --
#	frames to send, ctl lines to write, a pause to observe -- and
#	ip/wpa(8) is the program that does them.  The split is what lets
#	tests/wpa_test.b drive a whole handshake with no radio.
#
#	The cryptography is published and every piece of it has published
#	test vectors: PBKDF2-HMAC-SHA1 (RFC 2898, vectors in RFC 6070 and
#	IEEE 802.11i Annex H.4), the IEEE 802.11 PRF (Annex H.3), and AES
#	key unwrap (RFC 3394).  tests/wpa_test.b checks each against them.
#

Wpakey: module
{
	PATH:	con "/dis/lib/wpakey.dis";

	PMKlen:		con 32;		# pairwise master key
	PTKlen:		con 64;		# pairwise transient key: KCK|KEK|TK|MIC keys
	KCKlen:		con 16;		# key confirmation key, ptk[0:16]
	KEKlen:		con 16;		# key encryption key, ptk[16:32]
	TKlen:		con 16;		# CCMP temporal key, ptk[32:48]
	GTKlen:		con 32;
	MIClen:		con 16;
	Noncelen:	con 32;
	Eaddrlen:	con 6;

	#
	# The fixed part of an EAPOL-Key descriptor, IEEE 802.11 8.5.2:
	# type 1, key information 2, key length 2, replay counter 8,
	# nonce 32, EAPOL IV 16, RSC 8, reserved 8, MIC 16, data length 2.
	# The key data follows.
	#
	Keydescrlen:	con 95;

	# Key Information bits.
	Fptk:	con 1<<3;	# this is a pairwise key
	Fins:	con 1<<6;	# install
	Fack:	con 1<<7;	# a reply is expected
	Fmic:	con 1<<8;	# the MIC field is meaningful
	Fsec:	con 1<<9;	# secure
	Ferr:	con 1<<10;
	Freq:	con 1<<11;
	Fenc:	con 1<<12;	# the key data is encrypted

	# Ethernet type carrying EAPOL, and the EAPOL packet type of a key frame.
	Eapoltype:	con 16r888e;
	Eapolkey:	con 3;

	init:	fn();

	#
	# Key derivation.  pbkdf2_sha1 and prf take and return byte arrays
	# because their test vectors contain NUL bytes and lengths that a
	# string cannot carry.
	#
	pbkdf2_sha1:	fn(pass, salt: array of byte, rounds, dklen: int): array of byte;
	psk:		fn(passphrase, essid: string): array of byte;
	prf:		fn(key: array of byte, label: string, seed: array of byte, nbits: int): array of byte;
	ptk:		fn(pmk, smac, amac, snonce, anonce: array of byte): array of byte;
	mic:		fn(vers: int, kck, frame: array of byte): array of byte;
	aesunwrap:	fn(kek, data: array of byte): array of byte;

	# The RSN information element this supplicant offers: WPA2, CCMP
	# for both the group and the pairwise cipher, PSK authentication.
	rsnie:	fn(): array of byte;

	#
	# What recv asks of its caller, in the order returned.
	#
	Asend, Actl, Adelay: con iota;

	Action: adt {
		kind:	int;
		frame:	array of byte;	# Asend: write this to the conversation's data file
		text:	string;		# Actl: write this to its ctl file
		ms:	int;		# Adelay: wait this long first
	};

	#
	# One association's worth of supplicant state.  reset it whenever
	# the link drops: the replay counter and the key-installation gate
	# are only meaningful within a single association.
	#
	Supp: adt {
		pmk:	array of byte;
		smac:	array of byte;		# ours
		amac:	array of byte;		# the access point's, learnt from the frames
		rsne:	array of byte;		# what we claimed when we associated
		ptk:	array of byte;
		lastrepc:	big;
		newptk:	int;			# a PTK is derived and not yet installed

		mk:	fn(pmk, smac, rsne: array of byte): ref Supp;
		reset:	fn(s: self ref Supp);
		recv:	fn(s: self ref Supp, frame, snonce: array of byte): (list of ref Action, string);
	};

	hex:	fn(a: array of byte): string;
	unhex:	fn(s: string): array of byte;
	eaddr:	fn(a: array of byte): string;
};
