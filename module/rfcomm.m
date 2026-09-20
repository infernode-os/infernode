#
#	RFCOMM, the serial port emulation over L2CAP (PSM 3): Bluetooth
#	SIG RFCOMM specification, itself TS 07.10 with the changes
#	listed. One Mux per L2CAP channel between two devices, carrying
#	up to 30 data link connections (DLCs), each a byte stream that
#	presents at both ends as a serial port. Nothing here does I/O:
#	recv() takes one L2CAP SDU and returns what the caller must now
#	do, exactly as l2cap(2) does, so tests/rfcomm_test.b drives two
#	Muxes against each other and btmock(2) is a peer with a port.
#
#	What is here: SABM/UA/DM/DISC/UIH framing with FCS, the control
#	channel (DLCI 0) with PN, MSC and their responses, credit-based
#	flow control (the only kind RFCOMM 1.1 permits), and DISC for
#	both a DLC and the multiplexer. Not here: RPN, RLS, FCon/FCoff
#	(aggregate flow control is not used with credits), TEST.
#

Rfcomm: module
{
	PATH:	con "/dis/lib/rfcomm.dis";

	init:	fn(b: Bthci);

	# DLC states
	Closed, Waitpn, Waitua, Open, Waitdisc:	con iota;

	Maxframe:	con 1013;	# what we offer in PN: L2CAP's 1024 less RFCOMM's 6 (spec 5.5.3 allows less; peers take the smaller)
	Defframe:	con 127;	# TS 07.10's default N1, if the peer never negotiates
	Initcredits:	con 7;		# credits granted at PN, the most the field allows

	Dlc: adt {
		dlci:	int;		# 2*channel + direction bit
		channel: int;		# the server channel, 1..30
		state:	int;
		framesize: int;		# the most either side sends in one UIH
		txcredits: int;		# frames we may still send
		rxcredits: int;		# frames the peer may still send; replenished as we consume
		initiator: int;		# we asked for it
		msc:	int;		# our MSC command answered
		peermsc: int;		# the peer's MSC command received
		txq:	array of byte;	# waiting for credits
	};

	Ev: adt {
		pick {
		Send =>
			sdu:	array of byte;	# one L2CAP SDU for the RFCOMM channel
		Opened =>
			d:	ref Dlc;
		Incoming =>
			d:	ref Dlc;	# a peer opened a DLC on a channel we accept; Opened follows
		Closed =>
			d:	ref Dlc;
			reason:	string;
		Data =>
			d:	ref Dlc;
			data:	array of byte;
		Muxdown =>
			reason:	string;		# the multiplexer is gone; the L2CAP channel should follow
		Refused =>
			dlci:	int;		# a peer's SABM or PN answered with DM: the channel is not offered, or the multiplexer is not up
			reason:	string;
		}
	};

	Mux: adt {
		initiator: int;		# we opened the L2CAP channel: our DLCIs have direction bit 1
		up:	int;		# DLCI 0 established
		starting: int;		# our SABM for DLCI 0 is out
		dlcs:	list of ref Dlc;
		accept:	list of int;	# server channels we answer for
		pending: list of ref Dlc;	# connects asked for before DLCI 0 was up
		mtu:	int;		# the L2CAP channel's MTU, bounding the frame size

		new:	fn(initiator: int, mtu: int): ref Mux;
		# bring the multiplexer up (the initiator's SABM on DLCI 0)
		start:	fn(m: self ref Mux): list of ref Ev;
		# open a DLC to the peer's server channel
		connect: fn(m: self ref Mux, channel: int): (ref Dlc, list of ref Ev);
		# an L2CAP SDU arrived on the RFCOMM channel
		recv:	fn(m: self ref Mux, sdu: array of byte): list of ref Ev;
		# send bytes on an open DLC; as many frames as credits allow, the
		# rest queued until credits return
		send:	fn(m: self ref Mux, d: ref Dlc, data: array of byte): list of ref Ev;
		# the receiver has consumed n bytes: grant credits back as needed
		consumed: fn(m: self ref Mux, d: ref Dlc): list of ref Ev;
		disconnect: fn(m: self ref Mux, d: ref Dlc): list of ref Ev;
		# take the multiplexer down (DISC on DLCI 0)
		shutdown: fn(m: self ref Mux): list of ref Ev;
		find:	fn(m: self ref Mux, dlci: int): ref Dlc;
		bychannel: fn(m: self ref Mux, channel: int): ref Dlc;
	};

	fcs:	fn(a: array of byte, n: int): byte;	# the frame check sequence over n bytes
};
