#
#	The Attribute Protocol, Core Specification Vol 3 Part F, and the
#	part of GATT (Part G) a client needs to find a service and use
#	its characteristics: as data and as a state machine, no I/O. ATT
#	runs on the LE link's fixed L2CAP channel 4, one request out at a
#	time. A Client is handed the PDUs that arrive and hands back the
#	PDUs to send and what it learned; bt9p(4) moves them.
#
#	And a small GATT server, for being an LE peripheral: a table of
#	attributes built from services and read-only characteristics, and
#	the requests a central uses to find a service and read a value.
#	It answers one PDU with one PDU. Nothing in it can be written, and
#	it notifies nothing: what the board serves over GATT is the little
#	a phone needs to find it and learn which L2CAP channel to open
#	(#647), and the data goes over that.
#
#	Both can be on one link: requests and commands go to the Gattsrv (the server),
#	everything else to the Client; isrequest() says which.
#

Att: module
{
	PATH:	con "/dis/lib/att.dis";

	init:	fn(b: Bthci);

	Cid:		con 4;		# the fixed L2CAP channel
	Defmtu:		con 23;

	# opcodes, 3.4.8
	Oerror:		con 16r01;
	Omtureq:	con 16r02;
	Omtursp:	con 16r03;
	Ofindinforeq:	con 16r04;
	Ofindinforsp:	con 16r05;
	Oreadbytypereq:	con 16r08;
	Oreadbytypersp:	con 16r09;
	Ofindbytypereq:	con 16r06;
	Ofindbytypersp:	con 16r07;
	Oreadreq:	con 16r0a;
	Oreadrsp:	con 16r0b;
	Oreadblobreq:	con 16r0c;
	Oreadblobrsp:	con 16r0d;
	Oreadbygroupreq: con 16r10;
	Oreadbygrouprsp: con 16r11;
	Owritereq:	con 16r12;
	Owritersp:	con 16r13;
	Owritecmd:	con 16r52;
	Onotify:	con 16r1b;
	Oindicate:	con 16r1d;
	Oconfirm:	con 16r1e;

	# error codes, 3.4.1.1
	Einvalidhandle:	con 16r01;
	Ereadnotpermitted: con 16r02;
	Ewritenotpermitted: con 16r03;
	Einvalidpdu:	con 16r04;
	Einsufauthn:	con 16r05;
	Enotsupported:	con 16r06;
	Einvalidoffset:	con 16r07;
	Eunsupportedgroup: con 16r10;
	Einsufauthz:	con 16r08;
	Eattrnotfound:	con 16r0a;
	Einsufencrypt:	con 16r0f;

	# GATT UUIDs, Part G 3 and the assigned numbers
	Uprimary:	con 16r2800;
	Usecondary:	con 16r2801;
	Uinclude:	con 16r2802;
	Ucharacteristic: con 16r2803;
	Ucccd:		con 16r2902;
	Ugap:		con 16r1800;
	Ugatt:		con 16r1801;
	Udevname:	con 16r2a00;
	Uappearance:	con 16r2a01;
	Ureportref:	con 16r2908;
	Uhidservice:	con 16r1812;
	Uhidinfo:	con 16r2a4a;
	Ureportmap:	con 16r2a4b;
	Uhidcontrol:	con 16r2a4c;
	Ureport:	con 16r2a4d;
	Uprotocolmode:	con 16r2a4e;
	Ubootkbdin:	con 16r2a22;
	Ubootkbdout:	con 16r2a32;
	Ubootmousein:	con 16r2a33;

	# characteristic properties
	Pbroadcast, Pread, Pwritenorsp, Pwrite, Pnotify, Pindicate, Pauthwrite, Pext: con 1 << iota;

	Service: adt {
		start:	int;
		end:	int;
		uuid:	int;		# 16-bit, or -1 for a 128-bit one not on the base
		uuid128: array of byte;
	};
	Characteristic: adt {
		handle:	int;		# the declaration
		props:	int;
		value:	int;		# the value handle
		uuid:	int;
		uuid128: array of byte;
		descs:	list of (int, int);	# (handle, uuid16) of its descriptors
		cccd:	fn(c: self ref Characteristic): int;		# the CCCD handle, -1 if none
		reportref: fn(c: self ref Characteristic): int;	# the Report Reference handle, -1 if none
	};

	Ev: adt {
		pick {
		Send =>
			pdu:	array of byte;
		Mtu =>
			mtu:	int;
		Found =>
			s:	ref Service;			# a service, with its characteristics, fully discovered
			chars:	list of ref Characteristic;
		Nosuch =>
			uuid:	int;				# the service asked for is not there
		Value =>
			handle:	int;				# a Read answered
			value:	array of byte;
		Written =>
			handle:	int;
		Notified =>
			handle:	int;
			value:	array of byte;
		Failed =>
			op:	int;				# the request that failed
			handle:	int;
			code:	int;				# the ATT error code
			text:	string;
		}
	};

	Client: adt {
		mtu:	int;
		pending: int;		# the opcode of the request out, 0 if none
		phandle: int;		# the handle it was about
		q:	list of array of byte;	# requests waiting their turn
		# discovery in progress
		want:	int;		# the service UUID being looked for
		svc:	ref Service;
		chars:	list of ref Characteristic;
		dstart:	int;		# where the next Read By Group Type / Read By Type / Find Information starts
		dchar:	list of ref Characteristic;	# characteristics whose descriptors are still to be found
		offer:	int;		# the MTU we offered in an exchange still to be answered

		new:	fn(): ref Client;
		exchangemtu: fn(c: self ref Client, mtu: int): list of ref Ev;
		# find one primary service and everything in it
		discover: fn(c: self ref Client, uuid16: int): list of ref Ev;
		read:	fn(c: self ref Client, handle: int): list of ref Ev;
		write:	fn(c: self ref Client, handle: int, value: array of byte): list of ref Ev;	# a Write Request, answered
		writecmd: fn(c: self ref Client, handle: int, value: array of byte): list of ref Ev;	# a Write Command, not answered
		subscribe: fn(c: self ref Client, cccd: int, indications: int): list of ref Ev;
		# an ATT PDU arrived on channel 4
		recv:	fn(c: self ref Client, pdu: array of byte): list of ref Ev;
	};

	# One attribute of a server's table. A service declaration's end is
	# the last handle of its group; everything else's is its own handle.
	Attr: adt {
		handle:	int;
		uuid:	array of byte;	# 2 or 16 bytes, little-endian
		value:	array of byte;
		end:	int;
		needenc: int;		# readable only on an encrypted link
	};

	Srvmtu:		con 185;	# what the Gattsrv offers in an MTU exchange

	# InferNode's own service (#647): a board that will be mounted over an
	# LE L2CAP channel advertises Uinfernode, and the one characteristic in
	# it, readable once the link is encrypted, is the channel's PSM as two
	# bytes. Both were drawn at random on 2026-09-19 and mean nothing.
	Uinfernode:	con "8fb227af-9790-4a44-a7fd-fc8b6c54aafc";
	Uinfernodepsm:	con "56209656-5cc7-4d77-a283-34cddf937d75";

	Gattsrv: adt {
		mtu:	int;
		attrs:	list of ref Attr;	# ascending by handle
		next:	int;			# the next free handle
		encrypted: int;			# the caller says when the link is

		new:	fn(): ref Gattsrv;
		# a primary service begins; returns its handle. The characteristics
		# that follow belong to it until the next service.
		service: fn(s: self ref Gattsrv, uuid: array of byte): int;
		# a read-only characteristic of the service in progress; returns
		# its value handle. needenc: refuse the read, with insufficient
		# authentication, on a link that is not encrypted -- which is
		# also how a phone is made to pair, since its apps cannot ask.
		characteristic: fn(s: self ref Gattsrv, uuid: array of byte, value: array of byte, needenc: int): int;
		set:	fn(s: self ref Gattsrv, handle: int, value: array of byte);
		# a request or command arrived on channel 4: the PDU to send back, nil for none
		recv:	fn(s: self ref Gattsrv, pdu: array of byte): array of byte;
	};

	# is this PDU one a server answers (a request or a command), and
	# not one a client is waiting for?
	isrequest:	fn(pdu: array of byte): int;
	uuidbytes:	fn(uuid16: int): array of byte;
	# "0000fe59-0000-1000-8000-00805f9b34fb" as ATT carries it; nil if malformed
	parseuuid:	fn(s: string): array of byte;

	errtext:	fn(code: int): string;
	uuid16:		fn(a: array of byte, i: int, n: int): int;	# a 2- or 16-byte little-endian UUID at a[i]: its 16-bit form or -1
};
