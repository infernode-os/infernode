#
#	L2CAP, basic mode, as a state machine: Core Specification Vol 3
#	Part A. One Link per ACL connection; channels on it, each a
#	protocol/service multiplexer (PSM) at both ends. Nothing here does
#	I/O: recv() takes one ACL packet and returns what the caller must
#	now do -- frames to send, channels that opened or closed, data
#	that arrived -- and bt9p(4) is the program that does it, which is
#	what lets tests/l2cap_test.b drive both ends with no radio.
#
#	Basic mode only on a classic link: no retransmission or
#	flow-control modes, no enhanced configuration. That is what a
#	keyboard, a serial port (RFCOMM), SDP and A2DP need.
#
#	On an LE link, credit-based channels (Part A 4.22-4.24, 10.1):
#	the one kind of L2CAP channel both phone platforms hand to an
#	ordinary app, and so what 9P to a phone rides on (#647). There
#	is no configuration phase: MTU, MPS and credits travel in the
#	connection request and response and the channel is open when
#	the response arrives. An SDU goes as K-frames of at most the
#	peer's MPS, the first carrying the SDU's length, each costing a
#	credit; what the peer has not yet paid for waits in the channel's
#	queue, and Ev.Sendable says when it has drained.
#

L2cap: module
{
	PATH:	con "/dis/lib/l2cap.dis";

	init:	fn(b: Bthci);

	# channel identifiers
	Cidnull, Cidsig, Cidconnless:	con iota;
	Cidatt:		con 4;		# LE fixed channels: the Attribute Protocol,
	Cidlesig:	con 5;		# LE signalling,
	Cidsmp:		con 6;		# and the Security Manager
	Ciddyn:		con 16r40;	# first dynamically allocated CID

	# signalling command codes, 4.1
	Creject:	con 16r01;
	Cconnreq:	con 16r02;
	Cconnrsp:	con 16r03;
	Cconfreq:	con 16r04;
	Cconfrsp:	con 16r05;
	Cdiscreq:	con 16r06;
	Cdiscrsp:	con 16r07;
	Cechoreq:	con 16r08;
	Cechorsp:	con 16r09;
	Cinforeq:	con 16r0a;
	Cinforsp:	con 16r0b;
	Clecreq:	con 16r14;	# LE credit based connection request
	Clecrsp:	con 16r15;	# ... response
	Clecredit:	con 16r16;	# LE flow control credit

	# LE credit based connection results, 4.23
	LRok:		con 0;
	LRnopsm:	con 2;
	LRnoresources:	con 4;
	LRauthen:	con 5;		# the link is not encrypted and the PSM wants it: pair, then ask again
	LRauthor:	con 6;
	LRkeysize:	con 7;
	LRencrypt:	con 8;
	LRbadscid:	con 9;
	LRscidinuse:	con 10;
	LRparams:	con 11;

	Cidledyn:	con 16r40;	# an LE link's dynamic CIDs end at 0x7f
	Cidlemax:	con 16r7f;
	Lemtu:		con 2048;	# the largest SDU we take on an LE channel
	Lemps:		con 512;	# the largest K-frame payload we take
	Lecredits:	con 16;		# K-frames the peer may have in flight; topped up at half
	Leminmtu:	con 23;		# the least either number may be

	# connection response results
	Rok, Rpending, Rnopsm, Rsecurity, Rnoresources:	con iota;

	# channel states
	Closed, Waitconn, Config, Open, Waitdisc:	con iota;

	Defmtu:		con 672;	# the specification's default
	Ourmtu:		con 1024;	# what we tell peers they may send

	# well-known PSMs
	Psmsdp:		con 16r0001;
	Psmrfcomm:	con 16r0003;
	Psmhidctl:	con 16r0011;
	Psmhidint:	con 16r0013;

	Chan: adt {
		scid:	int;		# our CID for it
		dcid:	int;		# the peer's
		psm:	int;
		state:	int;
		mtu:	int;		# the most the peer will take in one frame
		ident:	int;		# the signalling id of our outstanding request
		initiator: int;		# we asked
		confsent, confdone, peerconf:	int;

		# an LE credit-based channel
		le:	int;
		mps:	int;		# the most the peer takes in one K-frame
		txcredits:	int;	# K-frames we may still send
		rxcredits:	int;	# K-frames the peer may still send
		rxsdu:	array of byte;	# an SDU being put together from K-frames
		rxn:	int;
		rxwant:	int;		# -1 between SDUs
		txq:	list of array of byte;	# K-frames waiting for credit, in order

		statename:	fn(c: self ref Chan): string;
		queued:		fn(c: self ref Chan): int;	# K-frames waiting for credit
	};

	# what recv() and the others hand back
	Ev: adt {
		pick {
		Send =>
			frame:	array of byte;	# a whole L2CAP frame for the link; fragment() splits it
		Opened =>
			c:	ref Chan;
		Incoming =>
			c:	ref Chan;	# a peer connected to an announced PSM; Opened follows
		Closed =>
			c:	ref Chan;
			reason:	string;
		Data =>
			c:	ref Chan;
			sdu:	array of byte;
		Fixed =>
			cid:	int;		# an LE fixed channel: ATT or SMP, one SDU
			sdu:	array of byte;
		Params =>
			min, max, latency, timeout: int;	# an LE peer asks for these connection parameters; accepted
		Sendable =>
			c:	ref Chan;	# an LE channel's queue has drained: the writer may go on
		}
	};

	Link: adt {
		handle:	int;
		chans:	list of ref Chan;
		accept:	list of int;	# PSMs we answer Connection Requests for
		nextcid:	int;
		nextident:	int;
		rx:	array of byte;	# a frame being reassembled from fragments
		rxn:	int;
		rxwant:	int;
		# LE channels are refused (LRauthen) on a link that is not
		# encrypted, unless the caller says otherwise: radio range
		# is a weaker boundary than a wire. bt9p sets encrypted
		# when the controller says the link is.
		encrypted:	int;
		needenc:	int;

		new:	fn(handle: int): ref Link;
		connect:	fn(l: self ref Link, psm: int): (ref Chan, list of ref Ev);
		leconnect:	fn(l: self ref Link, psm: int): (ref Chan, list of ref Ev);
		disconnect:	fn(l: self ref Link, c: ref Chan): list of ref Ev;
		send:	fn(l: self ref Link, c: ref Chan, sdu: array of byte): list of ref Ev;
		sendfixed: fn(l: self ref Link, cid: int, sdu: array of byte): list of ref Ev;
		recv:	fn(l: self ref Link, p: ref Bthci->Pkt): list of ref Ev;
		down:	fn(l: self ref Link, reason: string): list of ref Ev;
		find:	fn(l: self ref Link, scid: int): ref Chan;
	};

	# an L2CAP frame as ACL packets for the controller, each at most
	# aclmtu bytes of data: the first flagged start, the rest continue
	fragment:	fn(handle: int, frame: array of byte, aclmtu: int): list of ref Bthci->Pkt;

	# the pieces, for tests and for the mock peer
	frame:		fn(cid: int, payload: array of byte): array of byte;
	sigcmd:		fn(code, ident: int, data: array of byte): array of byte;
};
