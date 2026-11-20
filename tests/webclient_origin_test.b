implement WebclientOriginTest;

#
# webclient: what a request sends where, and what it makes of an
# encoded body.
#
# An origin is a scheme, a host and a port.  Ports 80 and 443 were left
# out of it under either scheme, so http://h/ and http://h:443/ were
# one origin: the Authorization header of a request to the first
# followed a redirect to the second (another server on the same host),
# and a relative redirect from http://h:443/ went to port 80.  A
# caller's Host, Content-Length or Transfer-Encoding header was sent
# beside the request's own.  A gzip body that did not decode was handed
# on as it came, compressed, with no error; one that decoded to more
# than the 64 MB a body may be was too, and left its inflater's process
# behind, one for each such body.
#
# Servers on the loopback stand at ports 80 and 443 of a name through a
# connection server of the test's own (in a name space of its own),
# which knows that name and nothing else.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;
	Header, Response: import webclient;

WebclientOriginTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_origin_test.b";

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
	* =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ---- a connection server ----

NAME: con "origin.test";
port80, port443: string;	# where the name's ports 80 and 443 are
csup := 0;

# "tcp!origin.test!80" is the loopback at port80, "!443" at port443;
# an address is itself; nothing else is known
translate(q: string): (string, string)
{
	(n, f) := sys->tokenize(q, "!");
	if(n != 3)
		return (nil, "cs: can't translate address");
	name := hd tl f;
	port := hd tl tl f;
	if(name == NAME) {
		case port {
		"80" =>
			return ("/net/tcp/clone 127.0.0.1!" + port80, nil);
		"443" =>
			return ("/net/tcp/clone 127.0.0.1!" + port443, nil);
		}
		return (nil, "cs: can't translate address");
	}
	if(len name > 0 && name[0] >= '0' && name[0] <= '9')
		return ("/net/tcp/clone " + name + "!" + port, nil);
	return (nil, "cs: can't translate address");
}

csserve(fio: ref Sys->FileIO)
{
	answers: list of (int, string);
	for(;;) alt {
	(off, count, fid, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		a: array of byte;
		for(l := answers; l != nil; l = tl l)
			if((hd l).t0 == fid) {
				a = array of byte (hd l).t1;
				break;
			}
		if(off >= len a)
			rc <-= (nil, nil);
		else {
			if(off + count > len a)
				count = len a - off;
			rc <-= (a[off:off+count], nil);
		}
	(nil, data, fid, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		(r, err) := translate(string data);
		if(err != nil)
			wc <-= (0, err);
		else {
			answers = (fid, r) :: answers;
			wc <-= (len data, nil);
		}
	}
}

startcs(t: ref T)
{
	if(csup)
		return;
	if(sys->bind("#sorigintest", "/net", Sys->MBEFORE) < 0)
		t.skip(sys->sprint("bind #s /net: %r"));
	fio := sys->file2chan("/net", "cs");
	if(fio == nil)
		t.skip(sys->sprint("file2chan /net/cs: %r"));
	spawn csserve(fio);
	csup = 1;
}

# ---- servers ----

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

announce(t: ref T): (Sys->Connection, string)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	if(port == "")
		t.fatal("no local port");
	return (c, port);
}

hasend(s: string): int
{
	for(i := 0; i + 3 < len s; i++)
		if(s[i:i+4] == "\r\n\r\n")
			return 1;
	return 0;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# Take n connections in turn; answer each with its entry of answers
# (the last again when they run out), and give each request to got.
serve(c: Sys->Connection, n: int, answers: array of array of byte, got: chan of string)
{
	for(i := 0; i < n; i++) {
		(ok, nc) := sys->listen(c);
		if(ok < 0) {
			got <-= "";
			continue;
		}
		fd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(fd == nil) {
			got <-= "";
			continue;
		}
		req := "";
		buf := array[4096] of byte;
		while(!hasend(req)) {
			k := sys->read(fd, buf, len buf);
			if(k <= 0)
				break;
			req += string buf[0:k];
		}
		a := answers[len answers - 1];
		if(i < len answers)
			a = answers[i];
		{
			for(o := 0; o < len a; ) {
				m := len a - o;
				if(m > 32768)
					m = 32768;
				if(sys->write(fd, a[o:o+m], m) != m)
					break;
				o += m;
			}
		} exception {
		"*" =>
			;
		}
		fd = nil;
		got <-= req;
	}
}

answer(s: string): array of array of byte
{
	return array[] of {array of byte s};
}

OK: con "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";

# what came on got within ms: (the request, whether one came)
within(got: chan of string, ms: int): (string, int)
{
	tmo := chan[1] of int;
	s := ref Stop(0);
	spawn timer(tmo, ms, s);
	alt {
	r := <-got =>
		s.now = 1;
		return (r, 1);
	<-tmo =>
		return (nil, 0);
	}
}

# a timer that can be told it is not wanted, so that none is left
# sleeping where processes are counted
Stop: adt {
	now:	int;
};

timer(c: chan of int, ms: int, s: ref Stop)
{
	for(t := 0; t < ms && !s.now; t += 50)
		sys->sleep(50);
	c <-= 1;
}

# Credentials stop at a redirect to another port of the same host, 80
# and 443 as any other.
testPortIsOrigin(t: ref T)
{
	(c80, p80) := announce(t);
	(c443, p443) := announce(t);
	port80 = p80;
	port443 = p443;
	startcs(t);
	got80 := chan[4] of string;
	got443 := chan[4] of string;
	spawn serve(c80, 1, answer("HTTP/1.1 302 Found\r\nLocation: http://" + NAME + ":443/x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), got80);
	spawn serve(c443, 1, answer(OK), got443);
	hdrs := Header("Authorization", "Bearer secret") :: Header("Accept", "text/plain") :: nil;
	(r, err) := webclient->request("GET", "http://" + NAME + "/", hdrs, nil);
	t.assert(r != nil && err == nil, "the request: " + err);
	(req, ok) := within(got80, 3000);
	t.assert(ok && contains(req, "Authorization: Bearer secret"), "sent where the caller sent it");
	(req, ok) = within(got443, 3000);
	t.assert(ok, "the redirect was followed to port 443");
	t.assert(!contains(req, "Authorization"), "and the credentials did not follow it");
	t.assert(contains(req, "Accept: text/plain"), "what describes the request did");
	if(r != nil)
		t.assertseq(r.url, "http://" + NAME + ":443/x", "the URL that answered");
}

# A relative redirect stays at the port it came from.
testRelativeKeepsPort(t: ref T)
{
	(c80, p80) := announce(t);
	(c443, p443) := announce(t);
	port80 = p80;
	port443 = p443;
	startcs(t);
	got80 := chan[4] of string;
	got443 := chan[4] of string;
	spawn serve(c80, 1, answer(OK), got80);
	a := array[] of {
		array of byte "HTTP/1.1 302 Found\r\nLocation: /b\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		array of byte OK,
	};
	spawn serve(c443, 2, a, got443);
	hdrs := Header("Authorization", "Bearer secret") :: nil;
	(r, err) := webclient->request("GET", "http://" + NAME + ":443/a", hdrs, nil);
	t.assert(r != nil && err == nil, "the request: " + err);
	if(r != nil)
		t.assertseq(r.url, "http://" + NAME + ":443/b", "the URL that answered");
	(nil, ok) := within(got443, 3000);
	t.assert(ok, "the first request, at port 443");
	(req, ok2) := within(got443, 3000);
	t.assert(ok2 && contains(req, "GET /b "), "the second, at port 443 too");
	t.assert(contains(req, "Authorization: Bearer secret"), "with its credentials: the same origin");
}

# The request's own headers are the only ones of their names.
testOwnHeaders(t: ref T)
{
	(c, port) := announce(t);
	got := chan[4] of string;
	spawn serve(c, 1, answer(OK), got);
	hdrs := Header("Host", "evil.example") :: Header("content-length", "999") ::
		Header("Transfer-Encoding", "chunked") :: Header("X-Kept", "yes") :: nil;
	(r, err) := webclient->request("POST", "http://127.0.0.1:" + port + "/", hdrs, array of byte "body");
	t.assert(r != nil && err == nil, "the request: " + err);
	(req, ok) := within(got, 3000);
	t.assert(ok, "the server's request");
	t.assert(contains(req, "Host: 127.0.0.1:" + port + "\r\n") || contains(req, "Host: 127.0.0.1\r\n"), "its Host is the URL's");
	t.assert(!contains(req, "evil.example"), "and not the caller's too");
	t.assert(contains(req, "Content-Length: 4\r\n") && !contains(req, "999"), "its length is the body's");
	t.assert(!contains(req, "chunked"), "no Transfer-Encoding");
	t.assert(contains(req, "X-Kept: yes"), "other headers are sent");
}

# ---- encoded bodies ----

Bits: adt {
	a:	array of byte;
	n:	int;	# bits written

	put:	fn(b: self ref Bits, v, nb: int);	# nb bits of v, low bit first
	code:	fn(b: self ref Bits, v, nb: int);	# a Huffman code: high bit first
};

Bits.put(b: self ref Bits, v, nb: int)
{
	for(i := 0; i < nb; i++) {
		if(v & (1 << i))
			b.a[b.n >> 3] |= byte (1 << (b.n & 7));
		b.n++;
	}
}

Bits.code(b: self ref Bits, v, nb: int)
{
	for(i := nb - 1; i >= 0; i--) {
		if(v & (1 << i))
			b.a[b.n >> 3] |= byte (1 << (b.n & 7));
		b.n++;
	}
}

# A gzip stream of n zero bytes, by hand (RFC 1951, one block of the
# fixed codes: a literal 0, then copies of 258 from one byte back).
# ends: whether the block and the stream are finished.
gzipzeros(n: int, ends: int): array of byte
{
	b := ref Bits(array[n / 150 + 400] of {* => byte 0}, 0);
	hdr := array[] of {byte 16r1f, byte 16r8b, byte 8, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 3};
	b.a[0:] = hdr;
	b.n = 8 * len hdr;
	b.put(1, 1);	# the last block
	b.put(1, 2);	# fixed codes
	b.code(16r30, 8);	# literal 0
	left := n - 1;
	while(left >= 258) {
		b.code(16rc5, 8);	# length 258 (code 285)
		b.code(0, 5);	# distance 1
		left -= 258;
	}
	while(left > 0) {
		b.code(16r30, 8);
		left--;
	}
	if(!ends)
		return b.a[0:(b.n + 7) / 8];
	b.code(0, 7);	# end of block
	o := (b.n + 7) / 8;
	# CRC-32 of n zeros, and n (the stream's trailer)
	crc := crczeros(n);
	for(i := 0; i < 4; i++) {
		b.a[o + i] = byte (crc >> (8 * i));
		b.a[o + 4 + i] = byte (n >> (8 * i));
	}
	return b.a[0:o + 8];
}

crczeros(n: int): int
{
	tab := array[256] of int;
	for(i := 0; i < 256; i++) {
		c := i;
		for(k := 0; k < 8; k++)
			if(c & 1)
				c = -306674912 ^ ((c >> 1) & 16r7fffffff);	# edb88320
			else
				c = (c >> 1) & 16r7fffffff;
		tab[i] = c;
	}
	crc := ~0;
	for(i = 0; i < n; i++)
		crc = tab[crc & 16rff] ^ ((crc >> 8) & 16r00ffffff);
	return ~crc;
}

gzanswer(z: array of byte): array of array of byte
{
	h := array of byte sys->sprint("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len z);
	a := array[len h + len z] of byte;
	a[0:] = h;
	a[len h:] = z;
	return array[] of {a};
}

nprocs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	t := 0;
	for(;;) {
		(n, nil) := sys->dirread(fd);
		if(n <= 0)
			break;
		t += n;
	}
	return t;
}

settle(n, ms: int): int
{
	for(t := 0; t < ms; t += 50) {
		if(nprocs() <= n)
			break;
		sys->sleep(50);
	}
	return nprocs();
}

fetchgz(t: ref T, z: array of byte): (ref Webclient->Response, string)
{
	(c, port) := announce(t);
	got := chan[4] of string;
	spawn serve(c, 1, gzanswer(z), got);
	(r, err) := webclient->requesttypes("GET", "http://127.0.0.1:" + port + "/", Header("Accept-Encoding", "gzip") :: nil, nil, nil, nil);
	<-got;
	return (r, err);
}

# A gzip body is decoded; one that is not gzip, or is cut, is an error
# and not the bytes as they came.
testEncoded(t: ref T)
{
	(r, err) := fetchgz(t, gzipzeros(100000, 1));
	t.assert(r != nil && err == nil, "a gzip body of 100000 zeros: " + err);
	if(r != nil) {
		t.asserteq(len r.body, 100000, "decoded");
		nz := 0;
		for(i := 0; i < len r.body; i++)
			if(r.body[i] != byte 0)
				nz++;
		t.asserteq(nz, 0, "bytes that are not zero");
	}

	(r, err) = fetchgz(t, array of byte "this is not gzip at all, whatever its header says");
	t.assert(r == nil && contains(err, "gzip"), "a body that is not gzip: " + err);

	(r, err) = fetchgz(t, gzipzeros(100000, 0));
	t.assert(r == nil && contains(err, "gzip"), "a gzip body with no end: " + err);
}

# A body that decodes to more than a body may be is an error, and
# leaves no process behind.
testTooLarge(t: ref T)
{
	z := gzipzeros(Webclient->MAXBODY + 3000000, 0);
	sys->sleep(300);
	procs := nprocs();
	(r, err) := fetchgz(t, z);
	what := "";
	if(r != nil)
		what = sys->sprint(" (a body of %d bytes, Content-Encoding %s)", len r.body, r.hdrval("Content-Encoding"));
	t.assert(r == nil, "no response" + what);
	t.assert(contains(err, "too large"), "the error: " + err);
	r = nil;
	left := settle(procs, 3000);
	t.assert(left <= procs, sys->sprint("%d processes where there were %d", left, procs));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	# the connection server is this test's alone
	sys->pctl(Sys->FORKNS, nil);

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load webclient: %r\n");
		raise "fail:cannot load webclient";
	}
	if((err := webclient->init()) != nil) {
		sys->fprint(sys->fildes(2), "webclient init: %s\n", err);
		raise "fail:webclient init";
	}
	# (a request that goes to a port nobody serves ends the test, not
	# the suite)
	webclient->setdeadline(6000, 0);

	run("OwnHeaders", testOwnHeaders);
	run("Encoded", testEncoded);
	run("TooLarge", testTooLarge);
	run("PortIsOrigin", testPortIsOrigin);
	run("RelativeKeepsPort", testRelativeKeepsPort);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
