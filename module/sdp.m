#
#	The Service Discovery Protocol, Core Specification Vol 3 Part B,
#	as data: elements, records, and the four PDUs a client and a
#	server exchange over L2CAP PSM 1. Nothing here does I/O. A Server
#	holds records and turns a request PDU into a response PDU; a
#	client builds a request and parses the response. bt9p(4) moves
#	the bytes, and btmock(2) answers with the same Server, which is
#	what lets a contract test find a serial port on a fake peer.
#
#	Enough of the protocol for what the profiles here need: a peer
#	asking which services we offer and on which RFCOMM channel, and
#	us asking the same of it. Continuation state is one byte, an
#	offset into a response the peer's MaxAttributeByteCount cut.
#

Sdp: module
{
	PATH:	con "/dis/lib/sdp.dis";

	init:	fn(b: Bthci);

	# PDU ids, 4.2
	Perror:			con 16r01;
	Psearchreq:		con 16r02;
	Psearchrsp:		con 16r03;
	Pattrreq:		con 16r04;
	Pattrrsp:		con 16r05;
	Psearchattrreq:		con 16r06;
	Psearchattrrsp:		con 16r07;

	# error codes, 4.4.1
	Ebadversion:		con 16r0001;
	Ebadhandle:		con 16r0002;
	Ebadsyntax:		con 16r0003;
	Ebadpdusize:		con 16r0004;
	Ebadcont:		con 16r0005;
	Enoresources:		con 16r0006;

	# universal attribute ids, 5.1
	Arecordhandle:		con 16r0000;
	Aclassidlist:		con 16r0001;
	Aprotocols:		con 16r0004;
	Abrowsegroups:		con 16r0005;
	Alanguages:		con 16r0006;
	Aprofiles:		con 16r0009;
	Aservicename:		con 16r0100;	# with the primary language base

	# 16-bit UUIDs this tree uses
	Usdp:			con 16r0001;
	Urfcomm:		con 16r0003;
	Ul2cap:			con 16r0100;
	Userialport:		con 16r1101;
	Upublicbrowse:		con 16r1002;
	Uhid:			con 16r1124;

	# a data element, 3.1: what a record is made of
	Elem: adt {
		pick {
		Nil =>
		Uint =>	v: big; size: int;		# size in bytes: 1, 2, 4, 8
		Int =>	v: big; size: int;
		Uuid =>	v: array of byte;		# 2, 4 or 16 bytes, big-endian
		Str =>	s: string;
		Bool =>	v: int;
		Seq =>	l: list of ref Elem;
		Alt =>	l: list of ref Elem;
		Url =>	s: string;
		}
		pack:	fn(e: self ref Elem): array of byte;
		text:	fn(e: self ref Elem): string;		# for debugging and the event stream
		uuid16:	fn(e: self ref Elem): int;		# -1 if not a 16-bit-expressible UUID
	};
	unpack:	fn(a: array of byte, i: int): (ref Elem, int);	# element at i; (nil, i) if malformed
	uuid:	fn(u16: int): ref Elem;
	uint8:	fn(v: int): ref Elem;
	uint16:	fn(v: int): ref Elem;
	uint32:	fn(v: int): ref Elem;
	seq:	fn(l: list of ref Elem): ref Elem;
	str:	fn(s: string): ref Elem;

	# a service record: attributes by id, ascending
	Record: adt {
		handle:	int;
		attrs:	list of (int, ref Elem);
		attr:	fn(r: self ref Record, id: int): ref Elem;
		classes: fn(r: self ref Record): list of int;	# 16-bit class UUIDs
		rfcommchan: fn(r: self ref Record): int;	# from the protocol descriptor list, -1 if none
		name:	fn(r: self ref Record): string;
	};
	# a Serial Port Profile record for an RFCOMM channel
	spprecord: fn(handle: int, channel: int, name: string): ref Record;

	# the server side: records and the request/response exchange
	Server: adt {
		recs:	list of ref Record;
		nexthandle: int;
		new:	fn(): ref Server;
		add:	fn(s: self ref Server, r: ref Record): int;	# assigns the handle; returns it
		remove:	fn(s: self ref Server, handle: int);
		request: fn(s: self ref Server, pdu: array of byte, mtu: int): array of byte;
	};

	# the client side
	searchattrreq: fn(tid: int, uuids: list of int, attrs: list of (int, int), maxbytes: int, cont: array of byte): array of byte;
	# a response to that: its piece of the attribute lists, and the
	# continuation state to send with the next request -- nil when this
	# was the last piece; err names a fault. The pieces concatenated are
	# one element, which records() turns into Records.
	searchattrrsp: fn(pdu: array of byte): (array of byte, array of byte, string);
	records: fn(body: array of byte): list of ref Record;
	# any PDU's header
	pduhdr: fn(pdu: array of byte): (int, int, int);	# (id, tid, paramlen), id -1 if malformed
	errorrsp: fn(pdu: array of byte): int;		# the error code of a Perror, -1 otherwise
};
