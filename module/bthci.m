#
#	The Bluetooth Host Controller Interface, as a Limbo library:
#	H4 framing over a byte stream, and a host that issues commands
#	and delivers events. Core Specification Vol 4 Part A (UART
#	transport) and Part E (HCI). docs/BLUETOOTH.md is the design.
#
#	The split is wpakey.m's: the framing and the packet decoders are
#	mechanism with no file behind them, so tests/bthci_test.b can
#	drive them against a mock controller with no radio anywhere. The
#	transport is an fd, and nothing here knows whether that fd is the
#	board's /dev/eia0, a socket to a host bridge, or one end of a
#	pipe with a fake on the other -- which is the portability
#	argument in the design doc, made concrete.
#
#	bt9p(4) is the program that puts this behind /net/bt.
#

Bthci: module
{
	PATH:	con "/dis/lib/bthci.dis";

	init:	fn();

	#
	# H4 packet indicators: the first byte on the wire says what
	# follows. Vol 4 Part A 2.
	#
	Hcmd, Hacl, Hsco, Hevt, Hiso:	con 1 + iota;

	Pkt: adt {
		kind:	int;			# one of the indicators above
		data:	array of byte;		# the packet, without the indicator
	};

	#
	# The wire format, in both directions. frame() prepends the
	# indicator. Deframer takes bytes as they arrive -- one at a time
	# from a UART, a burst from a socket -- and yields whole packets;
	# it knows each kind's header and how its length is encoded, and
	# nothing else. A byte that is not an indicator is dropped and
	# counted, which is what resynchronising a UART stream after
	# noise looks like.
	#
	frame:	fn(p: ref Pkt): array of byte;

	Deframer: adt {
		buf:	array of byte;
		n:	int;
		junk:	int;			# bytes discarded looking for an indicator

		new:	fn(): ref Deframer;
		feed:	fn(d: self ref Deframer, b: array of byte): list of ref Pkt;
	};

	#
	# Little-endian, as HCI is throughout.
	#
	get2:	fn(a: array of byte, i: int): int;
	get4:	fn(a: array of byte, i: int): int;
	put2:	fn(a: array of byte, i, v: int);
	put4:	fn(a: array of byte, i, v: int);

	#
	# Opcodes: OGF in the top six bits, OCF in the low ten.
	#
	opcode:	fn(ogf, ocf: int): int;
	ogf:	fn(op: int): int;
	ocf:	fn(op: int): int;

	OGFlink, OGFpolicy, OGFbaseband, OGFinfo, OGFstatus, OGFtest:	con 1 + iota;
	OGFle:		con 8;
	OGFvendor:	con 16r3f;

	# the commands this library and bt9p use, by name
	Inquiry:		con (1<<10) | 16r01;
	InquiryCancel:		con (1<<10) | 16r02;
	CreateConnection:	con (1<<10) | 16r05;
	Disconnect:		con (1<<10) | 16r06;
	AuthRequested:		con (1<<10) | 16r11;
	SetConnEncryption:	con (1<<10) | 16r13;
	AcceptConnection:	con (1<<10) | 16r09;
	RejectConnection:	con (1<<10) | 16r0a;
	LinkKeyReply:		con (1<<10) | 16r0b;
	LinkKeyNegative:	con (1<<10) | 16r0c;
	PinCodeReply:		con (1<<10) | 16r0d;
	PinCodeNegative:	con (1<<10) | 16r0e;
	RemoteNameRequest:	con (1<<10) | 16r19;
	IoCapabilityReply:	con (1<<10) | 16r2b;
	UserConfirmReply:	con (1<<10) | 16r2c;
	UserConfirmNegative:	con (1<<10) | 16r2d;
	UserPasskeyReply:	con (1<<10) | 16r2e;
	UserPasskeyNegative:	con (1<<10) | 16r2f;
	IoCapabilityNegative:	con (1<<10) | 16r34;
	SetEventMask:		con (3<<10) | 16r01;
	Reset:			con (3<<10) | 16r03;
	WriteLocalName:		con (3<<10) | 16r13;
	ReadLocalName:		con (3<<10) | 16r14;
	WriteScanEnable:	con (3<<10) | 16r1a;
	ReadScanEnable:		con (3<<10) | 16r19;
	WriteClassOfDevice:	con (3<<10) | 16r24;
	WriteInquiryMode:	con (3<<10) | 16r45;
	WriteSimplePairingMode:	con (3<<10) | 16r56;
	WriteLeHostSupported:	con (3<<10) | 16r6d;
	ReadLocalVersion:	con (4<<10) | 16r01;
	ReadLocalCommands:	con (4<<10) | 16r02;
	ReadLocalFeatures:	con (4<<10) | 16r03;
	ReadBufferSize:		con (4<<10) | 16r05;
	ReadBdaddr:		con (4<<10) | 16r09;
	LeReadBufferSize:	con (8<<10) | 16r02;
	LeSetScanParameters:	con (8<<10) | 16r0b;
	LeCreateConnection:	con (8<<10) | 16r0d;
	LeCreateConnCancel:	con (8<<10) | 16r0e;
	LeConnectionUpdate:	con (8<<10) | 16r13;
	LeStartEncryption:	con (8<<10) | 16r19;
	LeSetScanEnable:	con (8<<10) | 16r0c;

	# Broadcom vendor commands, for the CYW43455's patch upload (bt9p M3)
	BcmDownloadMinidriver:	con (16r3f<<10) | 16r2e;
	BcmWriteRam:		con (16r3f<<10) | 16r4c;
	BcmLaunchRam:		con (16r3f<<10) | 16r4e;
	BcmUpdateBaudrate:	con (16r3f<<10) | 16r18;
	BcmWriteBdaddr:		con (16r3f<<10) | 16r01;

	#
	# Event codes.
	#
	EvInquiryComplete:	con 16r01;
	EvInquiryResult:	con 16r02;
	EvConnComplete:		con 16r03;
	EvConnRequest:		con 16r04;
	EvDisconnComplete:	con 16r05;
	EvAuthComplete:		con 16r06;	# status, handle
	EvEncryptChange:	con 16r08;	# status, handle, enabled
	EvRemoteName:		con 16r07;
	EvCmdComplete:		con 16r0e;
	EvCmdStatus:		con 16r0f;
	EvHwError:		con 16r10;
	EvRoleChange:		con 16r12;
	EvNumCompleted:		con 16r13;
	EvModeChange:		con 16r14;
	EvPinRequest:		con 16r16;
	EvLinkKeyRequest:	con 16r17;
	EvLinkKeyNotify:	con 16r18;
	EvMaxSlots:		con 16r1b;
	EvIoCapRequest:		con 16r31;
	EvIoCapResponse:	con 16r32;
	EvUserConfirmRequest:	con 16r33;
	EvUserPasskeyRequest:	con 16r34;
	EvSimplePairingComplete: con 16r36;
	EvUserPasskeyNotify:	con 16r3b;

	# IO capabilities, for IO_Capability_Request_Reply
	IOdisplayonly, IOdisplayyesno, IOkeyboardonly, IOnone:	con iota;
	# authentication requirements: general bonding, MITM not/required
	AUTHbond, AUTHbondmitm:	con 16r04 + iota;
	# link key types worth naming
	LKcombination:		con 0;
	LKunauthenticated:	con 4;
	LKauthenticated:	con 5;
	EvInquiryResultRssi:	con 16r22;
	EvExtInquiryResult:	con 16r2f;
	EvLeMeta:		con 16r3e;
	LeAdvReport:		con 16r02;	# LE Meta subevent: Advertising Report
	LeConnComplete:		con 16r01;	# LE Meta subevent: status, handle, role, peer type, peer, interval...
	LeConnUpdate:		con 16r03;
	LeEnhConnComplete:	con 16r0a;

	# HCI status codes worth naming
	Sok:			con 16r00;
	Sunknowncmd:		con 16r01;
	Sunknownconn:		con 16r02;
	Shwfail:		con 16r03;
	Spagetimeout:		con 16r04;
	Sauthfail:		con 16r05;
	Snokey:			con 16r06;
	Smemory:		con 16r07;
	Sconntimeout:		con 16r08;
	Sconnexists:		con 16r0b;
	Scmddisallowed:		con 16r0c;
	Sinvalidparams:		con 16r12;
	Sremoteterm:		con 16r13;
	Slocalterm:		con 16r16;
	Sunsupported:		con 16r11;
	statusname:	fn(s: int): string;

	# an event, decoded one level
	Event: adt {
		code:	int;
		params:	array of byte;

		parse:	fn(p: ref Pkt): ref Event;
	};

	# a Command Complete's fields: credits, the opcode answered, its return parameters
	cmdcomplete:	fn(e: ref Event): (int, int, array of byte);
	# a Command Status's fields: status, credits, opcode
	cmdstatus:	fn(e: ref Event): (int, int, int);

	# a command packet from opcode and parameters
	command:	fn(op: int, params: array of byte): ref Pkt;

	#
	# BD_ADDRs are six bytes little-endian on the wire and written
	# most-significant first, as everyone prints them.
	#
	bdaddr:		fn(a: array of byte, i: int): string;
	parsebdaddr:	fn(s: string): array of byte;

	# Read_Local_Version_Information's return, decoded
	Version: adt {
		hci:	int;
		hcirev:	int;
		lmp:	int;
		manuf:	int;
		lmpsub:	int;

		parse:	fn(ret: array of byte): ref Version;
		text:	fn(v: self ref Version): string;	# "hci 4.2 lmp 4.2 manufacturer 15 (Broadcom)"
	};
	vername:	fn(v: int): string;
	manufacturer:	fn(m: int): string;

	# a device found: by an Inquiry Result (with or without RSSI, or
	# extended with an EIR) or by an LE Advertising Report
	Found: adt {
		addr:	string;
		class:	int;		# BR/EDR class of device; 0 for LE
		rssi:	int;		# 0 when the event carried none
		name:	string;		# from the EIR or advertising data, or a Remote Name event
		letype:	int;		# -1 BR/EDR; else the LE address type, 0 public 1 random
	};
	inquiryresults:	fn(e: ref Event): list of ref Found;
	leadvreports:	fn(e: ref Event): list of ref Found;
	# a Remote Name Request Complete: status, address, name
	remotename:	fn(e: ref Event): (int, string, string);
	# a Connection Complete: status, handle, address, link type (1 ACL)
	conncomplete:	fn(e: ref Event): (int, int, string, int);
	# a Connection Request: address, class, link type
	connrequest:	fn(e: ref Event): (string, int, int);
	# a Disconnection Complete: status, handle, reason
	disconncomplete: fn(e: ref Event): (int, int, int);
	# a Number Of Completed Packets: (handle, count) per entry
	numcompleted:	fn(e: ref Event): list of (int, int);
	# ACL packet header: handle, flags (start/continue in bits 12-13)
	aclheader:	fn(p: ref Pkt): (int, int);
	# the address most pairing events begin with
	evaddr:		fn(e: ref Event): string;
	# a Link Key Notification: address, the 16-byte key, its type
	linkkeynotify:	fn(e: ref Event): (string, array of byte, int);
	# a User Confirmation Request or Passkey Notification: address, the six-digit number
	usernumber:	fn(e: ref Event): (string, int);
	# 32 hex digits <-> 16 bytes
	keytext:	fn(k: array of byte): string;
	parsekey:	fn(s: string): array of byte;

	#
	# The transport: an fd and a reader process turning its bytes into
	# packets. h4() takes any fd. in carries packets until the reader
	# dies, then nil once; err then says why.
	#
	Transport: adt {
		fd:	ref Sys->FD;
		in:	chan of ref Pkt;
		err:	string;
		pid:	int;

		h4:	fn(fd: ref Sys->FD): ref Transport;
		send:	fn(t: self ref Transport, p: ref Pkt): int;
		stop:	fn(t: self ref Transport);
	};

	#
	# The host. One process owns the transport, issues commands under
	# the controller's flow control (Num_HCI_Command_Packets), matches
	# Command Complete and Command Status to the request by opcode,
	# and passes every other event out on events. cmd() blocks the
	# caller until the answer or the timeout. Requests are queued in
	# order; the controller says how many may be in flight.
	#
	Hci: adt {
		t:	ref Transport;
		events:	chan of ref Event;	# nil once the transport has died
		data:	chan of ref Pkt;	# ACL, SCO and ISO packets, for whoever owns the links
		reqs:	chan of ref Req;
		ctl:	chan of int;
		pid:	int;
		dead:	int;
		dropped:	int;		# events nobody was reading

		new:	fn(t: ref Transport): ref Hci;
		# returns (status, return parameters, error); error is nil on an answer
		cmd:	fn(h: self ref Hci, op: int, params: array of byte, ms: int): (int, array of byte, string);
		send:	fn(h: self ref Hci, p: ref Pkt): int;	# raw, for ACL data and the hci file
		stop:	fn(h: self ref Hci);
	};

	Req: adt {
		op:	int;
		p:	ref Pkt;
		deadline:	int;		# sys->millisec() at which it has failed
		reply:	chan of (int, array of byte, string);
	};

	hex:	fn(a: array of byte): string;	# "01 03 0c 00", for the event file

	#
	# A Broadcom .hcd patch file is HCI command packets laid end to
	# end without indicators -- opcode, length, parameters -- almost
	# all of them Write_RAM, the last a Launch_RAM. Returns them in
	# file order, or nil with the byte offset of the first malformed
	# record.
	#
	hcdrecords:	fn(hcd: array of byte): (list of (int, array of byte), int);
};
