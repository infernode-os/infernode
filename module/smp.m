#
#	The Security Manager Protocol, Core Specification Vol 3 Part H,
#	as the LE central's side of legacy pairing: Just Works, and the
#	key distribution that follows. On the LE link's fixed L2CAP
#	channel 6. No I/O: a Pairing is fed the PDUs that arrive and the
#	fact of the link having been encrypted, and hands back the PDUs
#	to send, the key to encrypt with, and the keys the peer gave.
#
#	LE Secure Connections (2.3.5.6) is offered on every request and
#	used when the peer offers it too: P-256 keys exchanged, the
#	peer's confirm checked against its nonce, the six digits of
#	numeric comparison shown when both ends can show and answer
#	(Ev.Confirm, answered with Pairing.confirm), the DHKey checks
#	exchanged, and the link encrypted with the LTK f5 made, which
#	both ends now hold and neither sent. A peer that does not offer
#	it gets legacy pairing as before.
#
#	Not here: passkey entry, OOB, and the responder's side.
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
	Fdhkeycheck:	con 16r0b;
	Fnumcmp:	con 16r0c;

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
		sc:	int;			# made by Secure Connections: EDIV 0 and Rand 0, and still one to store
	};

	Ev: adt {
		pick {
		Send =>
			pdu:	array of byte;
		Encrypt =>
			key:	array of byte;		# the STK: LE_Start_Encryption with EDIV 0, Rand 0
		Paired =>
			keys:	ref Keys;		# distribution done; keys.ltk is what to store
		Confirm =>
			value:	int;			# numeric comparison: show these six digits, then Pairing.confirm
		Failed =>
			reason:	int;
			text:	string;
		}
	};

	# states
	Idle, Waitrsp, Waitconfirm, Waitrandom, Waitencrypt, Waitkeys, Done, Failed,
	Waitpubkey, Waitscconfirm, Waitscrandom, Waituser, Waitdhcheck: con iota;

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
		# Secure Connections. io and offersc may be set before start();
		# priv, pkx and pky too, by a test that wants the debug keys.
		io:	int;			# our IO capability: IOnone, or IOdisplayyesno for numeric comparison
		offersc: int;
		sc:	int;			# both ends offered it: this pairing is one
		priv, pkx, pky:	array of byte;	# our P-256 key pair
		peerx, peery:	array of byte;	# the peer's public key
		dh:	array of byte;		# the shared secret
		mackey:	array of byte;
		numeric: int;			# numeric comparison, not Just Works

		# begin as the central: mrand is 16 random bytes from the caller
		new:	fn(iat: int, ia: array of byte, rat: int, ra: array of byte, mrand: array of byte): ref Pairing;
		start:	fn(p: self ref Pairing): list of ref Ev;
		recv:	fn(p: self ref Pairing, pdu: array of byte): list of ref Ev;
		# the link is now encrypted with the STK: key distribution follows
		encrypted: fn(p: self ref Pairing): list of ref Ev;
		# the answer to Ev.Confirm: do both ends show the same digits?
		confirm: fn(p: self ref Pairing, yes: int): list of ref Ev;
	};

	# the cryptographic functions, on 16-byte little-endian values as
	# they travel; exported for the test vectors
	c1:	fn(k, r, preq, pres: array of byte, iat: int, ia: array of byte, rat: int, ra: array of byte): array of byte;
	s1:	fn(k, r1, r2: array of byte): array of byte;
	e:	fn(k, p: array of byte): array of byte;		# AES-128, little-endian in and out
	# does the resolvable private address (little-endian, as on the
	# wire) belong to the holder of irk? Vol 6 Part B 1.3.2.3: the
	# address is hash || prand and hash is ah(irk, prand)
	resolves: fn(irk, addr: array of byte): int;

	#
	# LE Secure Connections, 2.2.6-2.2.9. Values are little-endian
	# arrays as they travel, like the rest: a P-256 coordinate or the
	# DHKey is 32 bytes, a nonce or check 16, an address 7 with its
	# type last (so the specification's A1 = type || address reads
	# most significant first), iocap 3 as IO capability, OOB flag,
	# AuthReq.
	#
	cmac:	fn(k, m: array of byte): array of byte;	# AES-CMAC, RFC 4493: big-endian in and out
	f4:	fn(u, v, x: array of byte, z: int): array of byte;	# the confirm value
	f5:	fn(w, n1, n2, a1, a2: array of byte): (array of byte, array of byte);	# (MacKey, LTK)
	f6:	fn(w, n1, n2, r, iocap, a1, a2: array of byte): array of byte;	# the DHKey check
	g2:	fn(u, v, x, y: array of byte): int;	# the six digits both sides show
	# a fresh P-256 key pair: (private, public X, public Y)
	sckeys:	fn(): (array of byte, array of byte, array of byte);
	# the shared secret from our private key and the peer's public one;
	# nil if the peer's point is not on the curve, which must end the pairing
	dhkey:	fn(priv, x, y: array of byte): array of byte;

	failtext: fn(reason: int): string;
};
