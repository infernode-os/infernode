#
#	A fake Bluetooth controller: the other end of an H4 stream.
#
#	Bytes in, bytes out, no process and no fd: feed() takes what the
#	host wrote and returns what the controller says back, so a test
#	can put one on the far end of a pipe (tests/bthci_test.b) and
#	btmock(4) can serve one as a file for bt9p to open. It answers
#	the commands bt9p issues -- Reset, the Read_Local_* set, the scan
#	and name writes, Inquiry with results, and the Broadcom vendor
#	commands the CYW43455's patch upload uses -- with what a real
#	controller answers, and an unknown opcode with Command Status
#	"unknown HCI command", as the specification says.
#
#	It is deliberately a little difficult where a real controller
#	can be: stingy withholds command credits so the host's flow
#	control is exercised, and Inquiry results arrive one per tick()
#	rather than all at once, so a streaming reader sees them stream.
#

Btmock: module
{
	PATH:	con "/dis/lib/btmock.dis";

	init:	fn(b: Bthci, l: L2cap);

	Echopsm:	con 16r1001;	# the L2CAP service every mock offers: it echoes
	Echochan:	con 1;		# and the RFCOMM channel it echoes on, which its SDP record names
	# an LE device's GATT table: a mouse with a HID service in boot
	# protocol, whose boot report is at this handle and its CCCD next
	Hidreport:	con 16r14;
	Hidcccd:	con 16r15;

	Ctlr: adt {
		addr:	array of byte;		# little-endian, as on the wire
		name:	string;
		hci, lmp, manuf:	int;
		scanenable:	int;
		class:	int;
		nearby:	list of ref Bthci->Found;	# what an Inquiry finds
		stingy:	int;			# answer with no credit; tick() refunds it
		owed:	int;			# a credit refund is pending
		inquiring:	list of ref Bthci->Found;	# results not yet emitted
		inquirydone:	int;		# Inquiry Complete not yet emitted
		naming:	list of string;		# Remote Name Requests to answer, by address
		lescanning:	int;		# LE scan enabled
		lemeta:		int;		# LE Meta Event unmasked (Set_Event_Mask bit 61)
		lehost:		int;		# Write_LE_Host_Supported
		leadv:	list of ref Bthci->Found;	# advertising reports not yet emitted
		log:	list of string;		# "cmd 0x0c03 <hex params>", newest first
		d:	ref Bthci->Deframer;
		links:	list of ref Peer;	# ACL links to the devices nearby
		pendconn:	list of ref Peer;	# Connection Completes to emit
		nexthandle:	int;
		received:	list of string;	# what peers were sent on their channels, newest first
		auth:	list of (string, string);	# devices that demand pairing: addr, "pin=NNNN", "ssp" or "le"
		lekeys:	list of (string, array of byte);	# LTKs given out, by address, for the next encryption
		keys:	list of (string, array of byte);	# link keys issued, by address
		pairings:	int;		# how many pairings completed

		new:	fn(addr: string): ref Ctlr;
		feed:	fn(c: self ref Ctlr, b: array of byte): array of byte;
		tick:	fn(c: self ref Ctlr): array of byte;
		seen:	fn(c: self ref Ctlr, op: int): int;	# how many times this opcode arrived
		# a nearby device calls us: a Connection Request, then once the
		# link is up an L2CAP connection to psm carrying text
		call:	fn(c: self ref Ctlr, addr: string, psm: int, text: string): string;
		callrf:	fn(c: self ref Ctlr, addr: string, channel: int, text: string): string;
		notify:	fn(c: self ref Ctlr, addr: string, report: array of byte): string;	# an LE device's boot report
	};

	#
	# The far end of an ACL link: a device nearby with an L2CAP peer on
	# it. It answers Connection Requests to Echopsm and echoes every
	# SDU back; a call() it makes carries text and records what comes
	# back in received.
	#
	Peer: adt {
		addr:	string;
		handle:	int;
		state:	int;			# 0 connecting, 1 up, 2 requested (incoming to the host),
					# 3 waiting for the host's link key, 4 for its PIN,
					# 5 for its IO capability, 6 for its confirmation
		l2:	ref L2cap->Link;
		calling:	int;		# an L2CAP connect to make once the link is up
		callpsm:	int;
		calltext:	string;
		acks:	int;			# ACL packets received, owed as Number Of Completed Packets
		rf:	ref Rfcomm->Mux;	# the RFCOMM multiplexer, once PSM 3 is open
		rfch:	ref L2cap->Chan;
		callchan: int;			# a call() on an RFCOMM channel rather than a PSM
		# an LE peripheral
		le:	int;
		attrs:	list of ref Attr;	# its GATT table
		sstate:	int;			# SMP responder: 0 idle, 1 sent response, 2 sent confirm, 3 waiting for encryption, 4 keys given
		preq, pres, mconfirm, mrand, srand, stk: array of byte;
		encrypted: int;
		penc:	int;			# an Encryption Change to emit on the tick: 0 none, else the status + 1
		notifyq: list of array of byte;	# boot reports to notify, once subscribed
	};

	Attr: adt {
		handle:	int;
		uuid:	int;
		value:	array of byte;
	};
};
