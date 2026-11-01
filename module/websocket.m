#
# WebSocket client (RFC 6455)
#
# A WebSocket is a message stream over one HTTP connection, upgraded:
# what services such as Slack's Socket Mode, Discord's gateway and
# Matrix's sliding sync send live events over.  This is the client end,
# as a mechanism: it dials, upgrades, and moves whole messages; what the
# messages mean, and what is served from them, is the caller's.
#
#	(c, err) := websocket->dial("wss://host/path", nil);
#	c.writetext("hello");
#	(m, err) := c.read();		# whole messages; pings answered here
#	c.close(Websocket->Cnormal, nil);
#
# Pings are answered inside read, so a connection stays up only while
# something reads it.  Reads and writes may be made from different
# threads; writes are made one at a time.  No extension is offered
# (no compression), so none is accepted.
#
Websocket: module
{
	PATH:	con "/dis/lib/websocket.dis";

	# opcodes (RFC 6455 section 5.2)
	Ocont:	con 16r0;
	Otext:	con 16r1;
	Obinary:	con 16r2;
	Oclose:	con 16r8;
	Oping:	con 16r9;
	Opong:	con 16rA;

	# close codes (section 7.4.1)
	Cnormal:	con 1000;
	Caway:	con 1001;
	Cprotocol:	con 1002;
	Cunsupported:	con 1003;
	Cnostatus:	con 1005;	# received with no code; never sent
	Cbaddata:	con 1007;	# a text message that is not UTF-8
	Cpolicy:	con 1008;
	Ctoobig:	con 1009;
	Cinternal:	con 1011;

	MAXMSG:	con 16*1024*1024;	# a message larger is refused (Ctoobig)
	MAXHDR:	con 16*1024;	# the server's handshake reply

	# A message: Otext or Obinary with its data, or Oclose with the
	# server's code and reason (data is then the reason's bytes).
	Msg: adt {
		op:	int;
		data:	array of byte;
		code:	int;

		text:	fn(m: self ref Msg): string;
	};

	Header: adt {
		name:	string;
		value:	string;
	};

	Conn: adt {
		fd:	ref Sys->FD;
		url:	string;
		protocol:	string;	# Sec-WebSocket-Protocol the server chose, or nil
		headers:	list of ref Header;	# the server's handshake reply

		# private
		rbuf:	array of byte;
		rn, rp:	int;
		wlock:	chan of int;
		closesent:	int;
		closed:	int;

		# The next message (Otext, Obinary or Oclose).  After an Oclose,
		# or an error, the connection is finished: read returns
		# (nil, "closed").  A server breaking the protocol is sent the
		# close code that says how, and the error names it.
		read:	fn(c: self ref Conn): (ref Msg, string);
		write:	fn(c: self ref Conn, op: int, data: array of byte): string;
		writetext:	fn(c: self ref Conn, s: string): string;
		ping:	fn(c: self ref Conn, data: array of byte): string;
		# Send a close frame.  The server's own close comes back from read.
		close:	fn(c: self ref Conn, code: int, reason: string): string;
	};

	init:	fn(): string;

	# Dial a ws:// or wss:// URL and upgrade.  hdrs are sent with the
	# upgrade (Authorization, Origin, Sec-WebSocket-Protocol, ...).
	dial:	fn(url: string, hdrs: list of ref Header): (ref Conn, string);

	# Upgrade a connection already open to the URL's host: one through
	# a proxy's CONNECT tunnel, a TLS connection made by the caller, or
	# a pipe in a test.  The URL gives the request's Host and path.
	client:	fn(fd: ref Sys->FD, url: string, hdrs: list of ref Header): (ref Conn, string);

	# The pieces, for tests and for servers built on this.
	# acceptkey: the Sec-WebSocket-Accept a server answers key with.
	acceptkey:	fn(key: string): string;
	# frame: one frame; mask nil for unmasked (a server's), else four bytes.
	frame:	fn(fin, op: int, data, mask: array of byte): array of byte;
	# utf8ok: data is well-formed UTF-8 (no overlongs, surrogates, or
	# runes past U+10FFFF), as a text message must be.
	utf8ok:	fn(data: array of byte): int;
};
