implement WebsocketTest;

#
# websocket(2): the RFC 6455 client, against a server played by the
# test over a pipe.  No network: the handshake, framing, fragments,
# pings, closing and every protocol error the client must refuse.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "encoding.m";
	base64: Encoding;

include "websocket.m";
	ws: Websocket;
	Conn, Msg, Header: import ws;

include "testing.m";
	testing: Testing;
	T: import testing;

WebsocketTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/websocket_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

GOOD: con "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
	"Connection: Upgrade\r\nSec-WebSocket-Accept: ACCEPT\r\n\r\n";

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

replace(s, old, new: string): string
{
	(a, b) := str->splitstrl(s, old);
	if(b == nil)
		return s;
	return a + new + b[len old:];
}

#
# The server's end
#

dialer(fd: ref Sys->FD, url: string, hdrs: list of ref Header, rc: chan of (ref Conn, string))
{
	rc <-= ws->client(fd, url, hdrs);
}

# The client's request, up to its blank line.
readreq(fd: ref Sys->FD): string
{
	s := "";
	b := array[1] of byte;
	while(sys->read(fd, b, 1) == 1){
		s[len s] = int b[0];
		if(len s >= 4 && s[len s - 4:] == "\r\n\r\n")
			break;
	}
	return s;
}

reqhdr(req, name: string): string
{
	(nil, lines) := sys->tokenize(req, "\r\n");
	for(; lines != nil; lines = tl lines){
		(n, v) := str->splitl(hd lines, ":");
		if(v != nil && str->tolower(n) == str->tolower(name))
			return str->drop(v[1:], " ");
	}
	return nil;
}

# Dial over a pipe; the test answers the upgrade with reply (ACCEPT in
# it replaced by the right key), extra written in the same write.
connect(url: string, hdrs: list of ref Header, reply: string, extra: array of byte): (ref Conn, ref Sys->FD, string, string)
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (nil, nil, nil, sys->sprint("pipe: %r"));
	rc := chan of (ref Conn, string);
	spawn dialer(fds[0], url, hdrs, rc);
	req := readreq(fds[1]);
	reply = replace(reply, "ACCEPT", ws->acceptkey(reqhdr(req, "Sec-WebSocket-Key")));
	b := array of byte reply;
	if(extra != nil)
		b = cat(b, extra);
	sys->write(fds[1], b, len b);
	(c, err) := <-rc;
	return (c, fds[1], req, err);
}

readn(fd: ref Sys->FD, n: int): array of byte
{
	a := array[n] of byte;
	for(got := 0; got < n; ){
		m := sys->read(fd, a[got:], n - got);
		if(m <= 0)
			return nil;
		got += m;
	}
	return a;
}

# A frame from the client, unmasked: (fin, op, masked, payload); op -1 at EOF.
sframe(fd: ref Sys->FD): (int, int, int, array of byte)
{
	h := readn(fd, 2);
	if(h == nil)
		return (0, -1, 0, nil);
	fin := int h[0] >> 7;
	op := int h[0] & 16rF;
	masked := int h[1] >> 7;
	n := int h[1] & 16r7F;
	if(n == 126){
		e := readn(fd, 2);
		n = int e[0]<<8 | int e[1];
	}else if(n == 127){
		e := readn(fd, 8);
		n = 0;
		for(i := 4; i < 8; i++)
			n = n<<8 | int e[i];
	}
	mask := array[4] of {* => byte 0};
	if(masked)
		mask = readn(fd, 4);
	p := readn(fd, n);
	for(i := 0; i < n; i++)
		p[i] ^= mask[i&3];
	return (fin, op, masked, p);
}

swrite(fd: ref Sys->FD, a: array of byte)
{
	sys->write(fd, a, len a);
}

writer(fd: ref Sys->FD, a: array of byte, done: chan of int)
{
	sys->write(fd, a, len a);
	done <-= 1;
}

closecode(p: array of byte): int
{
	if(len p < 2)
		return -1;
	return int p[0]<<8 | int p[1];
}

up(t: ref T): (ref Conn, ref Sys->FD)
{
	(c, sfd, nil, err) := connect("ws://example.com/", nil, GOOD, nil);
	if(c == nil)
		t.fatal("upgrade: " + err);
	return (c, sfd);
}

#
# Pieces
#

testAcceptKey(t: ref T)
{
	# RFC 6455 section 1.3
	t.assertseq(ws->acceptkey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "the RFC's key");
}

testFrames(t: ref T)
{
	hello := array of byte "Hello";
	# RFC 6455 section 5.7
	t.assertseq(hex(ws->frame(1, ws->Otext, hello, nil)), "810548656c6c6f", "unmasked Hello");
	mask := array[] of {byte 16r37, byte 16rfa, byte 16r21, byte 16r3d};
	t.assertseq(hex(ws->frame(1, ws->Otext, hello, mask)), "818537fa213d7f9f4d5158", "masked Hello");
	t.assertseq(hex(ws->frame(0, ws->Otext, array of byte "Hel", nil)), "010348656c", "first fragment");
	t.assertseq(hex(ws->frame(1, ws->Ocont, array of byte "lo", nil)), "80026c6f", "last fragment");
	t.assertseq(hex(ws->frame(1, ws->Oping, hello, nil)), "890548656c6c6f", "ping");
	t.assertseq(hex(ws->frame(1, ws->Obinary, array[125] of byte, nil)[0:2]), "827d", "125 bytes: length in the header");
	t.assertseq(hex(ws->frame(1, ws->Obinary, array[256] of byte, nil)[0:4]), "827e0100", "256 bytes: 16-bit length");
	t.assertseq(hex(ws->frame(1, ws->Obinary, array[65535] of byte, nil)[0:4]), "827effff", "65535 bytes: 16-bit length");
	t.assertseq(hex(ws->frame(1, ws->Obinary, array[65536] of byte, nil)[0:10]), "827f0000000000010000", "65536 bytes: 64-bit length");
	t.asserteq(len ws->frame(1, ws->Obinary, array[65536] of byte, mask), 65536 + 14, "masked 64K frame's size");
}

testUtf8(t: ref T)
{
	good := array[] of {
		array[0] of byte,
		array of byte "plain",
		array of byte "κόσμε",
		array of byte "\u0080߿ࠀ￿",
		array[] of {byte 16rf0, byte 16r9f, byte 16r9a, byte 16r80},	# U+1F680
		array[] of {byte 16rf4, byte 16r8f, byte 16rbf, byte 16rbf},	# U+10FFFF
	};
	for(i := 0; i < len good; i++)
		t.assert(ws->utf8ok(good[i]), sys->sprint("good %d: %s", i, hex(good[i])));
	bad := array[] of {
		array[] of {byte 16r80},	# a lone continuation
		array[] of {byte 16rc0, byte 16raf},	# overlong /
		array[] of {byte 16re0, byte 16r80, byte 16raf},	# overlong /
		array[] of {byte 16red, byte 16ra0, byte 16r80},	# U+D800
		array[] of {byte 16rf4, byte 16r90, byte 16r80, byte 16r80},	# past U+10FFFF
		array[] of {byte 16re2, byte 16r82},	# cut short
		array[] of {byte 16rff},
		array[] of {byte 'a', byte 16rce, byte 'b'},
	};
	for(i = 0; i < len bad; i++)
		t.assert(!ws->utf8ok(bad[i]), sys->sprint("bad %d: %s", i, hex(bad[i])));
}

testURLs(t: ref T)
{
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	bad := array[] of {
		"http://example.com/",
		"example.com",
		"ws://",
		"ws://example.com:80x/",
		"ws://user:pw@example.com/",
		"ws://example.com/#frag",
		"ws://example.com/a b",
		"ws://[::1/",
	};
	for(i := 0; i < len bad; i++){
		(c, err) := ws->client(fds[0], bad[i], nil);
		t.assert(c == nil && err != nil, "refused: " + bad[i]);
	}
}

testHeadersRefused(t: ref T)
{
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	bad := array[] of {
		ref Header("X-A", "one\r\nX-Injected: two"),
		ref Header("Host", "elsewhere"),
		ref Header("Sec-WebSocket-Key", "x"),
		ref Header("Sec-WebSocket-Extensions", "permessage-deflate"),
		ref Header("Bad:Name", "v"),
	};
	for(i := 0; i < len bad; i++){
		(c, err) := ws->client(fds[0], "ws://example.com/", bad[i] :: nil);
		t.assert(c == nil && err != nil, "refused: " + bad[i].name);
	}
}

#
# The upgrade
#

testHandshake(t: ref T)
{
	hdrs := ref Header("Authorization", "Bearer xapp-test") ::
		ref Header("Sec-WebSocket-Protocol", "chat, superchat") :: nil;
	reply := replace(GOOD, "\r\n\r\n", "\r\nSec-WebSocket-Protocol: chat\r\n\r\n");
	# a frame in the same write as the reply must not be lost
	(c, nil, req, err) := connect("wss://Example.com:8443/socket?ticket=1", hdrs, reply,
		ws->frame(1, ws->Otext, array of byte "first", nil));
	if(c == nil)
		t.fatal("upgrade: " + err);
	(line, nil) := str->splitstrl(req, "\r\n");
	t.assertseq(line, "GET /socket?ticket=1 HTTP/1.1", "request line");
	t.assertseq(reqhdr(req, "Host"), "Example.com:8443", "Host");
	t.assertseq(str->tolower(reqhdr(req, "Upgrade")), "websocket", "Upgrade");
	t.assertseq(reqhdr(req, "Connection"), "Upgrade", "Connection");
	t.assertseq(reqhdr(req, "Sec-WebSocket-Version"), "13", "version");
	t.assertseq(reqhdr(req, "Authorization"), "Bearer xapp-test", "caller's header sent");
	t.asserteq(len base64->dec(reqhdr(req, "Sec-WebSocket-Key")), 16, "key is 16 bytes");
	t.assertseq(c.protocol, "chat", "protocol chosen");
	(m, rerr) := c.read();
	if(m == nil)
		t.fatal("read: " + rerr);
	t.asserteq(m.op, ws->Otext, "text");
	t.assertseq(m.text(), "first", "frame sent with the reply");
}

testHandshakeRefused(t: ref T)
{
	cases := array[] of {
		("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "not upgraded"),
		(replace(GOOD, "ACCEPT", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="), "wrong accept"),
		(replace(GOOD, "Upgrade: websocket", "Upgrade: h2c"), "wrong Upgrade"),
		(replace(GOOD, "Connection: Upgrade", "Connection: keep-alive"), "wrong Connection"),
		(replace(GOOD, "\r\n\r\n", "\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"), "extension not offered"),
		(replace(GOOD, "\r\n\r\n", "\r\nSec-WebSocket-Protocol: chat\r\n\r\n"), "protocol not offered"),
		("SSH-2.0-OpenSSH\r\n\r\n", "not HTTP"),
	};
	for(i := 0; i < len cases; i++){
		(reply, what) := cases[i];
		(c, nil, nil, err) := connect("ws://example.com/", nil, reply, nil);
		t.assert(c == nil && err != nil, "refused: " + what);
		t.log(what + ": " + err);
	}
}

#
# Messages
#

testFragmentsAndPing(t: ref T)
{
	(c, sfd) := up(t);
	swrite(sfd, ws->frame(0, ws->Otext, array of byte "Hel", nil));
	swrite(sfd, ws->frame(1, ws->Oping, array of byte "p1", nil));
	swrite(sfd, ws->frame(0, ws->Ocont, array of byte "lo, ", nil));
	swrite(sfd, ws->frame(1, ws->Opong, array of byte "unasked", nil));
	swrite(sfd, ws->frame(1, ws->Ocont, array of byte "κόσμε", nil));
	(m, err) := c.read();
	if(m == nil)
		t.fatal("read: " + err);
	t.asserteq(m.op, ws->Otext, "text");
	t.assertseq(m.text(), "Hello, κόσμε", "fragments joined round a ping and a pong");
	(fin, op, masked, p) := sframe(sfd);
	t.asserteq(op, ws->Opong, "ping answered with a pong");
	t.asserteq(fin, 1, "pong is one frame");
	t.asserteq(masked, 1, "client's frames are masked");
	t.assertseq(string p, "p1", "pong carries the ping's data");
}

testBigBinary(t: ref T)
{
	(c, sfd) := up(t);
	data := array[70000] of byte;
	for(i := 0; i < len data; i++)
		data[i] = byte (i * 7);
	done := chan of int;
	spawn writer(sfd, ws->frame(1, ws->Obinary, data, nil), done);
	(m, err) := c.read();
	<-done;
	if(m == nil)
		t.fatal("read: " + err);
	t.asserteq(m.op, ws->Obinary, "binary");
	t.asserteq(len m.data, len data, "length");
	same := 1;
	for(i = 0; i < len data && same; i++)
		same = m.data[i] == data[i];
	t.assert(same, "bytes as sent");
}

testClientWrites(t: ref T)
{
	(c, sfd) := up(t);
	t.assertnil(c.writetext("héllo"), "writetext");
	(fin, op, masked, p) := sframe(sfd);
	t.asserteq(op, ws->Otext, "text frame");
	t.asserteq(fin, 1, "whole");
	t.asserteq(masked, 1, "masked");
	t.assertseq(string p, "héllo", "payload");

	bin := array[300] of {* => byte 16rAB};
	t.assertnil(c.write(ws->Obinary, bin), "write binary");
	(nil, op, nil, p) = sframe(sfd);
	t.asserteq(op, ws->Obinary, "binary frame");
	t.asserteq(len p, 300, "16-bit length");
	t.asserteq(int p[299], 16rAB, "payload");

	t.assertnil(c.ping(array of byte "are you there"), "ping");
	(nil, op, nil, p) = sframe(sfd);
	t.asserteq(op, ws->Oping, "ping frame");
	t.assertseq(string p, "are you there", "ping data");

	t.assertnotnil(c.write(ws->Otext, array[] of {byte 16rff}), "text that is not UTF-8 refused");
	t.assertnotnil(c.write(ws->Oclose, nil), "close by write refused");
	t.assertnotnil(c.ping(array[126] of byte), "ping over 125 bytes refused");
	t.assertnotnil(c.close(1005, nil), "1005 may not be sent");
	t.assertnotnil(c.close(ws->Cnormal, string array[124] of {* => byte 'x'}), "close reason over 123 bytes refused");
}

testServerCloses(t: ref T)
{
	(c, sfd) := up(t);
	swrite(sfd, ws->frame(1, ws->Oclose, cat(array[] of {byte 16r03, byte 16re8}, array of byte "bye"), nil));
	(m, err) := c.read();
	if(m == nil)
		t.fatal("read: " + err);
	t.asserteq(m.op, ws->Oclose, "close");
	t.asserteq(m.code, ws->Cnormal, "code");
	t.assertseq(m.text(), "bye", "reason");
	(nil, op, nil, p) := sframe(sfd);
	t.asserteq(op, ws->Oclose, "close answered");
	t.asserteq(closecode(p), ws->Cnormal, "with the server's code");
	(m, err) = c.read();
	t.assert(m == nil, "nothing after close");
	t.assertseq(err, "closed", "read after close");
	t.assertseq(c.writetext("late"), "closed", "write after close");
}

testServerClosesBare(t: ref T)
{
	(c, sfd) := up(t);
	swrite(sfd, ws->frame(1, ws->Oclose, nil, nil));
	(m, err) := c.read();
	if(m == nil)
		t.fatal("read: " + err);
	t.asserteq(m.code, ws->Cnostatus, "no code is 1005");
	(nil, op, nil, p) := sframe(sfd);
	t.asserteq(op, ws->Oclose, "close answered");
	t.asserteq(len p, 0, "with no code (1005 is never sent)");
}

testClientCloses(t: ref T)
{
	(c, sfd) := up(t);
	t.assertnil(c.close(ws->Caway, "going"), "close");
	(nil, op, nil, p) := sframe(sfd);
	t.asserteq(op, ws->Oclose, "close sent");
	t.asserteq(closecode(p), ws->Caway, "code");
	t.assertseq(string p[2:], "going", "reason");
	t.assertseq(c.writetext("late"), "closed", "no data after our close");
	# the server's answer, after a message it had in flight
	swrite(sfd, ws->frame(1, ws->Otext, array of byte "in flight", nil));
	swrite(sfd, ws->frame(1, ws->Oclose, array[] of {byte 16r03, byte 16re9}, nil));
	(m, err) := c.read();
	if(m == nil)
		t.fatal("read: " + err);
	t.assertseq(m.text(), "in flight", "a message sent before the server's close");
	(m, err) = c.read();
	if(m == nil)
		t.fatal("read: " + err);
	t.asserteq(m.op, ws->Oclose, "server's close");
	t.asserteq(m.code, ws->Caway, "its code");
}

#
# A server breaking the protocol
#

testProtocolErrors(t: ref T)
{
	maskit := array[] of {byte 1, byte 2, byte 3, byte 4};
	longping := ws->frame(1, ws->Oping, array[126] of byte, nil);
	rsv := ws->frame(1, ws->Otext, array of byte "x", nil);
	rsv[0] |= byte 16r40;
	fragping := ws->frame(0, ws->Oping, array of byte "x", nil);
	cases := array[] of {
		(ws->frame(1, ws->Otext, array of byte "x", maskit), ws->Cprotocol, "masked by the server"),
		(rsv, ws->Cprotocol, "reserved bit"),
		(longping, ws->Cprotocol, "control frame over 125 bytes"),
		(fragping, ws->Cprotocol, "control frame fragmented"),
		(ws->frame(1, ws->Ocont, array of byte "x", nil), ws->Cprotocol, "continuation of nothing"),
		(cat(ws->frame(0, ws->Otext, array of byte "a", nil), ws->frame(1, ws->Otext, array of byte "b", nil)),
			ws->Cprotocol, "message inside a fragmented message"),
		(ws->frame(1, 3, array of byte "x", nil), ws->Cprotocol, "unknown opcode"),
		(ws->frame(1, ws->Otext, array[] of {byte 16rce}, nil), ws->Cbaddata, "text not UTF-8"),
		(ws->frame(1, ws->Oclose, array[] of {byte 16r03}, nil), ws->Cprotocol, "close of one byte"),
		(ws->frame(1, ws->Oclose, array[] of {byte 16r03, byte 16red}, nil), ws->Cprotocol, "close code 1005"),
		(ws->frame(1, ws->Oclose, array[] of {byte 16r03, byte 16re8, byte 16rff}, nil), ws->Cbaddata, "close reason not UTF-8"),
		(array[] of {byte 16r82, byte 16r7f, byte 16r80, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 1},
			ws->Cprotocol, "length with its top bit"),
		(array[] of {byte 16r82, byte 16r7f, byte 0, byte 0, byte 0, byte 1, byte 0, byte 0, byte 0, byte 0},
			ws->Ctoobig, "frame past MAXMSG"),
	};
	for(i := 0; i < len cases; i++){
		(bytes, code, what) := cases[i];
		(c, sfd) := up(t);
		swrite(sfd, bytes);
		(m, err) := c.read();
		t.assert(m == nil && err != nil, what + ": refused");
		t.log(what + ": " + err);
		(nil, op, nil, p) := sframe(sfd);
		t.asserteq(op, ws->Oclose, what + ": close sent");
		t.asserteq(closecode(p), code, what + ": close code");
		(m, err) = c.read();
		t.assertseq(err, "closed", what + ": finished");
	}
}

testServerGone(t: ref T)
{
	(c, sfd) := up(t);
	swrite(sfd, ws->frame(0, ws->Otext, array of byte "half", nil));
	sfd = nil;	# the server hangs up mid-message
	(m, err) := c.read();
	t.assert(m == nil && err != nil, "connection gone reported");
	(m, err) = c.read();
	t.assertseq(err, "closed", "finished");
}

#
# Over the network, against tests/host/websocket/fake_ws.py: run by
# tests/host/websocket_test.sh, which sets $wsurl (and $wsrefused, a URL
# whose server's certificate is not trusted).  Skipped without them.
#

getenv(name: string): string
{
	fd := sys->open("/env/" + name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	# sh writes a variable to /env quoted, as a list
	l := str->unquoted(string b[0:n]);
	if(l == nil)
		return nil;
	return hd l;
}

testLive(t: ref T)
{
	url := getenv("wsurl");
	if(url == nil)
		t.skip("no $wsurl: run by tests/host/websocket_test.sh");
	t.log("dialling " + url);
	(c, err) := ws->dial(url, ref Header("Authorization", "Bearer xapp-live") :: nil);
	if(c == nil)
		t.fatal("dial: " + err);
	(m, rerr) := c.read();
	if(m == nil)
		t.fatal("read: " + rerr);
	t.assertseq(m.text(), "hello Bearer xapp-live", "fragmented greeting, a ping inside it");
	t.assertnil(c.writetext("echo κόσμε"), "writetext");
	(m, rerr) = c.read();
	if(m == nil)
		t.fatal("read echo: " + rerr);
	t.assertseq(m.text(), "echo κόσμε", "text echoed");
	data := array[100000] of byte;
	for(i := 0; i < len data; i++)
		data[i] = byte (i * 31 + i / 256);
	t.assertnil(c.write(ws->Obinary, data), "write 100000 bytes");
	(m, rerr) = c.read();
	if(m == nil)
		t.fatal("read binary echo: " + rerr);
	same := m.op == ws->Obinary && len m.data == len data;
	for(i = 0; i < len data && same; i++)
		same = m.data[i] == data[i];
	t.assert(same, "binary echoed whole");
	t.assertnil(c.close(ws->Cnormal, "done"), "close");
	(m, rerr) = c.read();
	if(m == nil)
		t.fatal("read close: " + rerr);
	t.asserteq(m.op, ws->Oclose, "server's close");
	t.asserteq(m.code, ws->Cnormal, "its code");

	bad := getenv("wsrefused");
	if(bad != nil){
		(c, err) = ws->dial(bad, nil);
		t.assert(c == nil && err != nil, "untrusted certificate refused");
		t.log("untrusted: " + err);
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	ws = load Websocket Websocket->PATH;
	if(ws == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Websocket->PATH);
		raise "fail:cannot load websocket";
	}
	if((err := ws->init()) != nil){
		sys->fprint(sys->fildes(2), "websocket init: %s\n", err);
		raise "fail:websocket init";
	}
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("AcceptKey", testAcceptKey);
	run("Frames", testFrames);
	run("Utf8", testUtf8);
	run("URLs", testURLs);
	run("HeadersRefused", testHeadersRefused);
	run("Handshake", testHandshake);
	run("HandshakeRefused", testHandshakeRefused);
	run("FragmentsAndPing", testFragmentsAndPing);
	run("BigBinary", testBigBinary);
	run("ClientWrites", testClientWrites);
	run("ServerCloses", testServerCloses);
	run("ServerClosesBare", testServerClosesBare);
	run("ClientCloses", testClientCloses);
	run("ProtocolErrors", testProtocolErrors);
	run("ServerGone", testServerGone);
	run("Live", testLive);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
