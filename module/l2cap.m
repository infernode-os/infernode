#
#	L2CAP, basic mode, as a state machine: Core Specification Vol 3
#	Part A. One Link per ACL connection; channels on it, each a
#	protocol/service multiplexer (PSM) at both ends. Nothing here does
#	I/O: recv() takes one ACL packet and returns what the caller must
#	now do -- frames to send, channels that opened or closed, data
#	that arrived -- and bt9p(4) is the program that does it, which is
#	what lets tests/l2cap_test.b drive both ends with no radio.
#
#	Basic mode only: no retransmission or flow-control modes, no
#	enhanced configuration. That is what a keyboard, a serial port
#	(RFCOMM) and SDP need; audio would want more and is out of scope.
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

		statename:	fn(c: self ref Chan): string;
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

		new:	fn(handle: int): ref Link;
		connect:	fn(l: self ref Link, psm: int): (ref Chan, list of ref Ev);
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
