implement Websocket;

#
# WebSocket client (RFC 6455).  See module/websocket.m and websocket(2).
#
# The client's side of the protocol only: frames it sends are masked,
# frames it receives must not be; it offers no extension and accepts
# none.  A server breaking the protocol is sent the close code that
# says how (section 7.4.1) and the connection is finished.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;

include "encoding.m";
	base64: Encoding;

include "security.m";
	random: Random;

include "string.m";
	str: String;

include "webclient.m";
	webclient: Webclient;

include "websocket.m";

# section 1.3: appended to the key, hashed, to prove the server read it
GUID: con "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

RBUFSIZE: con 16*1024;
MAXCTL: con 125;	# a control frame's payload (section 5.5)

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("cannot load %s: %r", Keyring->PATH);
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		return sys->sprint("cannot load %s: %r", Encoding->BASE64PATH);
	random = load Random Random->PATH;
	if(random == nil)
		return sys->sprint("cannot load %s: %r", Random->PATH);
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load %s: %r", String->PATH);
	return nil;
}

Msg.text(m: self ref Msg): string
{
	return string m.data;
}

#
# Dialling and the upgrade
#

dial(url: string, hdrs: list of ref Header): (ref Conn, string)
{
	(tls, host, port, nil, nil, err) := parseurl(url);
	if(err != nil)
		return (nil, err);
	addr := "tcp!" + host + "!" + port;
	fd: ref Sys->FD;
	if(tls){
		if(webclient == nil){
			webclient = load Webclient Webclient->PATH;
			if(webclient == nil)
				return (nil, sys->sprint("cannot load %s: %r", Webclient->PATH));
			if((err = webclient->init()) != nil){
				webclient = nil;
				return (nil, err);
			}
		}
		(fd, err) = webclient->tlsdial(addr, host);
		if(err != nil)
			return (nil, err);
	}else{
		(ok, c) := sys->dial(addr, nil);
		if(ok < 0)
			return (nil, sys->sprint("dial %s: %r", addr));
		fd = c.dfd;
	}
	return client(fd, url, hdrs);
}

client(fd: ref Sys->FD, url: string, hdrs: list of ref Header): (ref Conn, string)
{
	(nil, nil, nil, hosthdr, resource, err) := parseurl(url);
	if(err != nil)
		return (nil, err);

	key := base64->enc(random->randombuf(Random->NotQuiteRandom, 16));
	req := "GET " + resource + " HTTP/1.1\r\n" +
		"Host: " + hosthdr + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n";
	offered: list of string;
	for(h := hdrs; h != nil; h = tl h){
		(n, v) := ((hd h).name, (hd h).value);
		if(n == nil || hasctl(n) || hasctl(v) || str->in(':', n))
			return (nil, "websocket: bad header " + n);
		case str->tolower(n) {
		"host" or "upgrade" or "connection" or "sec-websocket-key" or
		"sec-websocket-version" or "sec-websocket-extensions" =>
			return (nil, "websocket: " + n + " is the handshake's own header");
		"sec-websocket-protocol" =>
			offered = commalist(v);
		}
		req += n + ": " + v + "\r\n";
	}
	req += "\r\n";
	b := array of byte req;
	if(sys->write(fd, b, len b) != len b)
		return (nil, sys->sprint("websocket: write: %r"));

	c := ref Conn(fd, url, nil, nil, array[RBUFSIZE] of byte, 0, 0, chan[1] of int, 0, 0);
	(status, headers, herr) := readhdr(c);
	if(herr != nil)
		return (nil, herr);
	c.headers = headers;

	(nil, w) := sys->tokenize(status, " ");
	if(len w < 2 || !str->prefix("HTTP/", hd w))
		return (nil, "websocket: not an HTTP reply: " + status);
	if(hd tl w != "101")
		return (nil, "websocket: upgrade refused: " + status);
	if(str->tolower(hdrval(headers, "upgrade")) != "websocket")
		return (nil, "websocket: reply does not upgrade to websocket");
	if(!inlist("upgrade", commalist(str->tolower(hdrval(headers, "connection")))))
		return (nil, "websocket: reply's Connection is not Upgrade");
	if(hdrval(headers, "sec-websocket-accept") != acceptkey(key))
		return (nil, "websocket: wrong Sec-WebSocket-Accept");
	if(hdrval(headers, "sec-websocket-extensions") != nil)
		return (nil, "websocket: server chose an extension none was offered");
	p := hdrval(headers, "sec-websocket-protocol");
	if(p != nil && !inlist(p, offered))
		return (nil, "websocket: server chose a protocol not offered: " + p);
	c.protocol = p;
	return (c, nil);
}

# ws://host[:port]/path?query, as
# (tls, host, port, Host header, request target, error)
parseurl(url: string): (int, string, string, string, string, string)
{
	(scheme, rest) := str->splitstrl(url, "://");
	if(rest == nil)
		return (0, nil, nil, nil, nil, "websocket: not a URL: " + url);
	tls: int;
	port: string;
	case str->tolower(scheme) {
	"ws" =>
		(tls, port) = (0, "80");
	"wss" =>
		(tls, port) = (1, "443");
	* =>
		return (0, nil, nil, nil, nil, "websocket: scheme is not ws or wss: " + url);
	}
	rest = rest[len "://":];
	for(i := 0; i < len rest; i++)
		if(rest[i] == '/' || rest[i] == '?' || rest[i] == '#')
			break;
	(auth, resource) := (rest[0:i], rest[i:]);
	if(str->in('#', resource))
		return (0, nil, nil, nil, nil, "websocket: a URL with a fragment: " + url);
	if(resource == nil || resource[0] == '?')
		resource = "/" + resource;
	if(str->in('@', auth))
		return (0, nil, nil, nil, nil, "websocket: credentials in the URL; send them as a header");
	host := auth;
	if(auth != nil && auth[0] == '['){
		(a, b) := str->splitl(auth, "]");
		if(b == nil)
			return (0, nil, nil, nil, nil, "websocket: bad host in " + url);
		host = a[1:];
		if(len b > 1){
			if(b[1] != ':')
				return (0, nil, nil, nil, nil, "websocket: bad host in " + url);
			port = b[2:];
		}
	}else{
		(a, b) := str->splitl(auth, ":");
		host = a;
		if(b != nil)
			port = b[1:];
	}
	if(host == nil || port == nil || hasctl(auth) || str->in(' ', auth))
		return (0, nil, nil, nil, nil, "websocket: bad host in " + url);
	for(i = 0; i < len port; i++)
		if(port[i] < '0' || port[i] > '9')
			return (0, nil, nil, nil, nil, "websocket: bad port in " + url);
	if(hasctl(resource) || str->in(' ', resource))
		return (0, nil, nil, nil, nil, "websocket: bad path in " + url);
	return (tls, host, port, auth, resource, nil);
}

# The server's reply up to its blank line; what follows stays buffered,
# as the first frames may come with it.
readhdr(c: ref Conn): (string, list of ref Header, string)
{
	lines: list of string;
	line := "";
	for(total := 0;; total++){
		if(total >= MAXHDR)
			return (nil, nil, "websocket: reply header too long");
		ch := getc(c);
		if(ch < 0)
			return (nil, nil, "websocket: connection closed during the upgrade");
		if(ch != '\n'){
			line[len line] = ch;
			continue;
		}
		if(line != nil && line[len line - 1] == '\r')
			line = line[0:len line - 1];
		if(line == nil)
			break;
		lines = line :: lines;
		line = "";
	}
	if(lines == nil)
		return (nil, nil, "websocket: empty reply");
	hs: list of ref Header;
	for(; tl lines != nil; lines = tl lines){
		(n, v) := str->splitl(hd lines, ":");
		if(v == nil)
			continue;
		hs = ref Header(trim(n), trim(v[1:])) :: hs;
	}
	return (hd lines, hs, nil);
}

hdrval(hs: list of ref Header, name: string): string
{
	for(; hs != nil; hs = tl hs)
		if(str->tolower((hd hs).name) == name)
			return (hd hs).value;
	return nil;
}

acceptkey(key: string): string
{
	s := array of byte (key + GUID);
	d := array[Keyring->SHA1dlen] of byte;
	kr->sha1(s, len s, d, nil);
	return base64->enc(d);
}

#
# Reading
#

getc(c: ref Conn): int
{
	if(c.rp >= c.rn){
		n := sys->read(c.fd, c.rbuf, len c.rbuf);
		if(n <= 0)
			return -1;
		(c.rn, c.rp) = (n, 0);
	}
	return int c.rbuf[c.rp++];
}

readn(c: ref Conn, n: int): array of byte
{
	a := array[n] of byte;
	got := 0;
	while(got < n){
		if(c.rp < c.rn){
			m := c.rn - c.rp;
			if(m > n - got)
				m = n - got;
			a[got:] = c.rbuf[c.rp:c.rp+m];
			c.rp += m;
			got += m;
		}else if(n - got >= len c.rbuf){
			m := sys->read(c.fd, a[got:], n - got);
			if(m <= 0)
				return nil;
			got += m;
		}else{
			m := sys->read(c.fd, c.rbuf, len c.rbuf);
			if(m <= 0)
				return nil;
			(c.rn, c.rp) = (m, 0);
		}
	}
	return a;
}

# One frame, as (fin, op, payload, close code, error).  A close code of
# 0 with an error is the connection gone, with nothing to send.
readframe(c: ref Conn): (int, int, array of byte, int, string)
{
	h := readn(c, 2);
	if(h == nil)
		return (0, 0, nil, 0, "websocket: connection closed");
	(b0, b1) := (int h[0], int h[1]);
	fin := (b0>>7) & 1;
	op := b0 & 16rF;
	if(b0 & 16r70)
		return (0, 0, nil, Cprotocol, "websocket: reserved bits set, no extension agreed");
	if(b1 & 16r80)
		return (0, 0, nil, Cprotocol, "websocket: the server masked a frame");
	case op {
	Ocont or Otext or Obinary =>
		;
	Oclose or Oping or Opong =>
		if(!fin)
			return (0, 0, nil, Cprotocol, "websocket: a control frame fragmented");
	* =>
		return (0, 0, nil, Cprotocol, sys->sprint("websocket: unknown opcode %#x", op));
	}
	n := big (b1 & 16r7F);
	if(n == big 126){
		e := readn(c, 2);
		if(e == nil)
			return (0, 0, nil, 0, "websocket: connection closed");
		n = big ((int e[0]<<8) | int e[1]);
	}else if(n == big 127){
		e := readn(c, 8);
		if(e == nil)
			return (0, 0, nil, 0, "websocket: connection closed");
		if(int e[0] & 16r80)
			return (0, 0, nil, Cprotocol, "websocket: a frame's length has its top bit set");
		n = big 0;
		for(i := 0; i < 8; i++)
			n = (n<<8) | big e[i];
	}
	if(op >= Oclose && n > big MAXCTL)
		return (0, 0, nil, Cprotocol, "websocket: a control frame longer than 125 bytes");
	if(n > big MAXMSG)
		return (0, 0, nil, Ctoobig, sys->sprint("websocket: a frame of %bd bytes, more than %d", n, MAXMSG));
	data := readn(c, int n);
	if(data == nil)
		return (0, 0, nil, 0, "websocket: connection closed");
	return (fin, op, data, 0, nil);
}

Conn.read(c: self ref Conn): (ref Msg, string)
{
	if(c.closed)
		return (nil, "closed");
	msgop := -1;
	parts: list of array of byte;
	total := 0;
	for(;;){
		(fin, op, data, code, err) := readframe(c);
		if(err != nil){
			if(code != 0)
				return fail(c, code, err);
			c.closed = 1;
			return (nil, err);
		}
		case op {
		Oping =>
			if(!c.closesent && (err = sendframe(c, Opong, data)) != nil){
				c.closed = 1;
				return (nil, err);
			}
			continue;
		Opong =>
			continue;
		Oclose =>
			return closed(c, data);
		Otext or Obinary =>
			if(msgop >= 0)
				return fail(c, Cprotocol, "websocket: a new message inside a fragmented one");
			msgop = op;
		Ocont =>
			if(msgop < 0)
				return fail(c, Cprotocol, "websocket: a continuation with no message to continue");
		}
		total += len data;
		if(total > MAXMSG)
			return fail(c, Ctoobig, sys->sprint("websocket: a message longer than %d bytes", MAXMSG));
		parts = data :: parts;
		if(fin){
			m := array[total] of byte;
			for(; parts != nil; parts = tl parts){
				total -= len hd parts;
				m[total:] = hd parts;
			}
			if(msgop == Otext && !utf8ok(m))
				return fail(c, Cbaddata, "websocket: a text message that is not UTF-8");
			return (ref Msg(msgop, m, 0), nil);
		}
	}
}

# The server's close: answered with its own code (section 5.5.1), unless
# ours was sent first, and the connection finished.
closed(c: ref Conn, data: array of byte): (ref Msg, string)
{
	code := Cnostatus;
	reason := array[0] of byte;
	if(len data == 1)
		return fail(c, Cprotocol, "websocket: a close frame of one byte");
	if(len data >= 2){
		code = (int data[0]<<8) | int data[1];
		reason = data[2:];
		if(!sendable(code))
			return fail(c, Cprotocol, sys->sprint("websocket: close code %d is not one a server may send", code));
		if(!utf8ok(reason))
			return fail(c, Cbaddata, "websocket: a close reason that is not UTF-8");
	}
	if(!c.closesent){
		c.closesent = 1;
		echo := array[0] of byte;
		if(code != Cnostatus)
			echo = data[0:2];
		sendframe(c, Oclose, echo);
	}
	c.closed = 1;
	return (ref Msg(Oclose, reason, code), nil);
}

fail(c: ref Conn, code: int, err: string): (ref Msg, string)
{
	if(!c.closesent){
		c.closesent = 1;
		sendframe(c, Oclose, closepayload(code, nil));
	}
	c.closed = 1;
	return (nil, sys->sprint("%s (closed %d)", err, code));
}

# Codes that may be in a close frame (section 7.4): 1005, 1006 and 1015
# are for reporting, never sent; 1004 is reserved.
sendable(code: int): int
{
	return code >= 1000 && code <= 1003 ||
		code >= 1007 && code <= 1014 ||
		code >= 3000 && code <= 4999;
}

#
# Writing
#

sendframe(c: ref Conn, op: int, data: array of byte): string
{
	f := frame(1, op, data, random->randombuf(Random->NotQuiteRandom, 4));
	c.wlock <-= 1;
	n := sys->write(c.fd, f, len f);
	<-c.wlock;
	if(n != len f)
		return sys->sprint("websocket: write: %r");
	return nil;
}

Conn.write(c: self ref Conn, op: int, data: array of byte): string
{
	if(c.closesent || c.closed)
		return "closed";
	if(op != Otext && op != Obinary)
		return sys->sprint("websocket: write of opcode %#x; ping and close have their own", op);
	if(op == Otext && !utf8ok(data))
		return "websocket: text that is not UTF-8";
	return sendframe(c, op, data);
}

Conn.writetext(c: self ref Conn, s: string): string
{
	return c.write(Otext, array of byte s);
}

Conn.ping(c: self ref Conn, data: array of byte): string
{
	if(c.closesent || c.closed)
		return "closed";
	if(len data > MAXCTL)
		return "websocket: a ping longer than 125 bytes";
	return sendframe(c, Oping, data);
}

Conn.close(c: self ref Conn, code: int, reason: string): string
{
	if(c.closesent || c.closed)
		return nil;
	if(code != 0 && !sendable(code))
		return sys->sprint("websocket: close code %d may not be sent", code);
	p := closepayload(code, reason);
	if(len p > MAXCTL)
		return "websocket: a close reason longer than 123 bytes";
	c.closesent = 1;
	return sendframe(c, Oclose, p);
}

closepayload(code: int, reason: string): array of byte
{
	if(code == 0)
		return array[0] of byte;
	r := array of byte reason;
	p := array[2 + len r] of byte;
	p[0] = byte (code>>8);
	p[1] = byte code;
	p[2:] = r;
	return p;
}

frame(fin, op: int, data, mask: array of byte): array of byte
{
	n := len data;
	hl := 2;
	if(n > 65535)
		hl += 8;
	else if(n > 125)
		hl += 2;
	if(mask != nil)
		hl += 4;
	f := array[hl + n] of byte;
	f[0] = byte ((fin&1)<<7 | op&16rF);
	mbit := 0;
	if(mask != nil)
		mbit = 16r80;
	i := 2;
	if(n > 65535){
		f[1] = byte (mbit|127);
		bn := big n;
		for(j := 7; j >= 0; j--){
			f[i+j] = byte bn;
			bn >>= 8;
		}
		i += 8;
	}else if(n > 125){
		f[1] = byte (mbit|126);
		f[2] = byte (n>>8);
		f[3] = byte n;
		i += 2;
	}else
		f[1] = byte (mbit|n);
	if(mask == nil){
		f[i:] = data;
		return f;
	}
	f[i:] = mask[0:4];
	i += 4;
	for(j := 0; j < n; j++)
		f[i+j] = data[j] ^ mask[j&3];
	return f;
}

utf8ok(a: array of byte): int
{
	n := len a;
	for(i := 0; i < n; ){
		b := int a[i];
		if(b < 16r80){
			i++;
			continue;
		}
		need, r, min: int;
		if((b & 16rE0) == 16rC0)
			(need, r, min) = (1, b & 16r1F, 16r80);
		else if((b & 16rF0) == 16rE0)
			(need, r, min) = (2, b & 16rF, 16r800);
		else if((b & 16rF8) == 16rF0)
			(need, r, min) = (3, b & 16r7, 16r10000);
		else
			return 0;
		if(i + need >= n)
			return 0;
		for(k := 1; k <= need; k++){
			cb := int a[i+k];
			if((cb & 16rC0) != 16r80)
				return 0;
			r = (r<<6) | (cb & 16r3F);
		}
		if(r < min || r > 16r10FFFF || r >= 16rD800 && r <= 16rDFFF)
			return 0;
		i += need + 1;
	}
	return 1;
}

#
# Little helpers
#

hasctl(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] == 16r7F)
			return 1;
	return 0;
}

trim(s: string): string
{
	while(s != nil && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	while(s != nil && (s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

commalist(s: string): list of string
{
	(nil, l) := sys->tokenize(s, ",");
	r: list of string;
	for(; l != nil; l = tl l)
		if((t := trim(hd l)) != nil)
			r = t :: r;
	return r;
}

inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}
