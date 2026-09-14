#
#	The Security Manager Protocol, Core Specification Vol 3 Part H,
#	as the LE central's side of legacy pairing: Just Works, and the
#	key distribution that follows. On the LE link's fixed L2CAP
#	channel 6. No I/O: a Pairing is fed the PDUs that arrive and the
#	fact of the link having been encrypted, and hands back the PDUs
#	to send, the key to encrypt with, and the keys the peer gave.
#
#	Not here: LE Secure Connections (ECDH, f4/f5/f6), passkey entry,
#	OOB, and the responder's side. A peer that will only do Secure
#	Connections is refused with "pairing not supported" and says so.
#

Smp: module
{
	PATH:	con "/dis/lib/smp.dis";

	init:	fn(b: Bthci, k: Keyring);

	Cid:		con 6;

	# codes, 3.3
	Cpairreq:	con 16r01;
	Cpairrsp:	con 16r02;
	Cconfirm:	con 16r03;
	Crandom:	con 16r04;
	Cfailed:	con 16r05;
	Cencinfo:	con 16r06;
	Cmasterid:	con 16r07;
	Cidinfo:	con 16r08;
	Cidaddr:	con 16r09;
	Csigninfo:	con 16r0a;
	Csecreq:	con 16r0b;
	Cpublickey:	con 16r0c;
	Cdhkeycheck:	con 16r0d;

	# failure reasons, 3.5.5
	Fpasskeyfailed:	con 16r01;
	Foobnotavail:	con 16r02;
	Fauthreq:	con 16r03;
	Fconfirmfailed:	con 16r04;
	Fnotsupported:	con 16r05;
	Fenckeysize:	con 16r06;
	Fcmdnotsupported: con 16r07;
	Funspecified:	con 16r08;
	Frepeated:	con 16r09;
	Finvalidparams:	con 16r0a;

	# IO capabilities, 2.3.2
	IOdisplayonly, IOdisplayyesno, IOkeyboardonly, IOnone, IOkeyboarddisplay: con iota;

	# AuthReq bits
	Abonding:	con 16r01;
	Amitm:		con 16r04;
	Asc:		con 16r08;

	# key distribution bits
	Kenc:		con 16r01;
	Kid:		con 16r02;
	Ksign:		con 16r04;

	Keys: adt {
		ltk:	array of byte;		# 16, little-endian as distributed
		ediv:	int;
		rand:	array of byte;		# 8
		irk:	array of byte;		# 16, nil if not given
		idtype:	int;			# the identity address type
		idaddr:	string;			# and address, nil if not given
	};

	Ev: adt {
		pick {
		Send =>
			pdu:	array of byte;
		Encrypt =>
			key:	array of byte;		# the STK: LE_Start_Encryption with EDIV 0, Rand 0
		Paired =>
			keys:	ref Keys;		# distribution done; keys.ltk is what to store
		Failed =>
			reason:	int;
			text:	string;
		}
	};

	# states
	Idle, Waitrsp, Waitconfirm, Waitrandom, Waitencrypt, Waitkeys, Done, Failed: con iota;

	Pairing: adt {
		state:	int;
		iat:	int;			# our (initiator) address type, 0 public 1 random
		ia:	array of byte;		# our address, little-endian
		rat:	int;
		ra:	array of byte;
		preq:	array of byte;		# the 7 bytes of our Pairing Request
		pres:	array of byte;		# and the peer's Response
		mrand:	array of byte;		# our random, 16 bytes little-endian
		srand:	array of byte;
		sconfirm: array of byte;
		tk:	array of byte;		# 16 zero bytes for Just Works
		stk:	array of byte;
		keys:	ref Keys;
		want:	int;			# key distribution bits still to come from the peer

		# begin as the central: mrand is 16 random bytes from the caller
		new:	fn(iat: int, ia: array of byte, rat: int, ra: array of byte, mrand: array of byte): ref Pairing;
		start:	fn(p: self ref Pairing): list of ref Ev;
		recv:	fn(p: self ref Pairing, pdu: array of byte): list of ref Ev;
		# the link is now encrypted with the STK: key distribution follows
		encrypted: fn(p: self ref Pairing): list of ref Ev;
	};

	# the cryptographic functions, on 16-byte little-endian values as
	# they travel; exported for the test vectors
	c1:	fn(k, r, preq, pres: array of byte, iat: int, ia: array of byte, rat: int, ra: array of byte): array of byte;
	s1:	fn(k, r1, r2: array of byte): array of byte;
	e:	fn(k, p: array of byte): array of byte;		# AES-128, little-endian in and out

	failtext: fn(reason: int): string;
};
