implement WebclientBodyTest;

#
# webclient reads a body into a buffer that grows as the body's bytes
# come.  It allocated the whole of what the header promised before a
# byte of it had arrived: a response saying "Content-Length: 67108864"
# and then nothing (or a chunk whose size line said as much) cost 64 MB
# of the Dis heap, which every program of the emulator shares, for as
# long as the server kept the connection open; and a short body kept the
# 64 MB after, as a slice of it.  Any server a fetch tool was pointed at
# could say so.
#
# Loopback servers written here send such headers with a thousand bytes
# after them, and the heap is watched while the request is out.  Bodies
# of every framing still arrive whole.  A redirect to an address that is
# not http is refused (file:///x was a request to localhost, port 80).
#
# A body that ends before its framing says it does is an error that
# says so.  It was a response like any other: 50 bytes of a promised
# 100, or a connection gone in the middle of a chunk, came back as
# status 200 with no error and `truncated' 0, through requestbounded
# too, so whoever could cut the connection of a download chose where
# the file ended.  `truncated' keeps its one meaning: the body was
# longer than the caller's limit.  And what is not a response is not
# one: a Content-Length of -1 (read as no body, the connection kept,
# and whatever followed taken as the next request's answer), two
# lengths that differ, a chunk size that is no number, a header with
# no end, a greeting that is not HTTP (status 0, no error).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;

WebclientBodyTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_body_test.b";

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

HUGE: con 64*1024*1024;
MB: con 1024*1024;

# ---- a loopback server ----

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
		t.fatal("no local port: " + readfile(c.dir + "/local"));
	return (c, "http://127.0.0.1:" + port + "/");
}

# byte i of a body the tests can check
pat(i: int): byte
{
	return byte ('a' + i % 23);
}

body(n: int): array of byte
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = pat(i);
	return a;
}

# Take one connection, read its request, and answer as mode says.
serve(c: Sys->Connection, mode: string, n: int, done: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		done <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		done <-= -1;
		return;
	}
	req := "";
	buf := array[4096] of byte;
	while(!hasend(req)) {
		k := sys->read(fd, buf, len buf);
		if(k <= 0)
			break;
		req += string buf[0:k];
	}
	case mode {
	"promise" =>
		# a length promised, n bytes of it sent, then nothing for a while
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", HUGE));
		sys->write(fd, body(n), n);
		sys->sleep(600);
	"chunkpromise" =>
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n", HUGE));
		sys->write(fd, body(n), n);
		sys->sleep(600);
	"length" =>
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", n));
		sys->write(fd, body(n), n);
	"chunked" =>
		# the body in chunks of 1, 70000, then the rest
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
		b := body(n);
		o := 0;
		sizes := array[] of {1, 70000, n};
		for(i := 0; i < len sizes && o < n; i++) {
			k := sizes[i];
			if(k > n - o)
				k = n - o;
			say(fd, sys->sprint("%x\r\n", k));
			sys->write(fd, b[o:o+k], k);
			say(fd, "\r\n");
			o += k;
		}
		say(fd, "0\r\n\r\n");
	"toend" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n");
		sys->write(fd, body(n), n);
	"tofile" =>
		say(fd, "HTTP/1.1 302 Found\r\nLocation: file:///lib/ndb/local\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
	"short" =>
		# n promised, half of it sent, and the connection closed
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", n));
		sys->write(fd, body(n/2), n/2);
	"chunkcut" =>
		# cut inside its second chunk
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n32\r\n");
		sys->write(fd, body(50), 50);
		say(fd, "\r\n400\r\nzzzz");
	"chunknolast" =>
		# every chunk whole, and no last one
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n32\r\n");
		sys->write(fd, body(50), 50);
		say(fd, "\r\n");
	"badchunk" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n");
	"chunknocrlf" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX\r\n0\r\n\r\n");
	"clneg" =>
		# a length that is none, and then what a kept connection
		# would take for the next request's answer
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n" +
			"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nSet-Cookie: planted=1\r\n\r\nPOISON");
		sys->sleep(300);
	"cltext" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 5x\r\nConnection: close\r\n\r\nhello");
	"cldiffer" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 3\r\nConnection: close\r\n\r\nhello");
	"clsame" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");
	"nothttp" =>
		say(fd, "220 mail.example ESMTP ready\r\n\r\n");
	"badcode" =>
		say(fd, "HTTP/1.1 OK 200\r\nContent-Length: 0\r\n\r\n");
	"hdrcut" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n");
	"real" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nREAL");
	"kept" =>
		# a response that leaves the connection open, then: how long
		# until the client closes it (told on done, in milliseconds;
		# -2 if it had not by n)
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nKEPT");
		t0 := sys->millisec();
		got := chan[1] of int;
		spawn eofwait(fd, got);
		tmo := chan[1] of int;
		spawn timer(tmo, n);
		alt {
		<-got =>
			done <-= sys->millisec() - t0;
		<-tmo =>
			sys->fprint(sys->open(nc.dir + "/ctl", Sys->OWRITE), "hangup");
			done <-= -2;
		}
		return;
	"br" =>
		# a Brotli body from a file of the tests' (n: which)
		f := "/tests/web/brotli/hello.br";
		if(n == 1)
			f = "/tests/web/brotli/zeros-1m.br";
		if(n == 96)
			f = "/tests/web/brotli/zeros-96m.br";
		b := array[256] of byte;
		bfd := sys->open(f, Sys->OREAD);
		bn := 0;
		if(bfd != nil)
			bn = sys->read(bfd, b, len b);
		if(bn < 0)
			bn = 0;
		b = b[0:bn];
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: br\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len b));
		sys->write(fd, b, len b);
	}
	fd = nil;
	done <-= 0;
}

# tell when fd's other end has closed it
eofwait(fd: ref Sys->FD, got: chan of int)
{
	buf := array[64] of byte;
	while(sys->read(fd, buf, len buf) > 0)
		;
	got <-= 1;
}

# two connections, one after the other
serve2(c: Sys->Connection, mode1, mode2: string, done: chan of int)
{
	d := chan[1] of int;
	serve(c, mode1, 0, d);
	<-d;
	serve(c, mode2, 0, d);
	<-d;
	done <-= 0;
}

say(fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	sys->write(fd, b, len b);
}

hasend(s: string): int
{
	for(i := 0; i + 3 < len s; i++)
		if(s[i:i+4] == "\r\n\r\n")
			return 1;
	return 0;
}

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

# ---- the heap ----

# bytes of the Dis heap in use (/dev/memory: cursize maxsize hw ... name)
heapsize(): int
{
	(nil, lines) := sys->tokenize(readfile("/dev/memory"), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " \t");
		if(n >= 8 && hd tl tl tl tl tl tl tl f == "heap")
			return int hd f;
	}
	return -1;
}

# the most the heap holds while it runs: sampled until stop
watchheap(stop: chan of int, most: chan of int)
{
	m := heapsize();
	for(;;) {
		alt {
		<-stop =>
			most <-= m;
			return;
		* =>
			;
		}
		h := heapsize();
		if(h > m)
			m = h;
		sys->sleep(10);
	}
}

# A request of a response that promises 64 MB and sends 1000 bytes:
# the 1000 come back, and the heap never held the 64 MB.
promised(t: ref T, mode: string)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, mode, 1000, done);
	before := heapsize();
	if(before < 0)
		t.skip("no /dev/memory");
	stop := chan of int;
	most := chan of int;
	spawn watchheap(stop, most);
	(r, err) := webclient->request("GET", url, nil, nil);
	stop <-= 1;
	grew := <-most - before;
	<-done;
	# (the server then closes: the body was cut short, and is no response)
	t.assert(r == nil && contains(err, "cut short"), "a body of 1000 bytes where 64 MB were promised: " + err);
	t.assert(grew < 8*MB, sys->sprint("the heap grew by %d bytes for a body of 1000 (the header promised %d)", grew, HUGE));
	r = nil;
	t.assert(heapsize() - before < 8*MB, sys->sprint("%d bytes kept after it", heapsize() - before));
}

testLengthPromised(t: ref T)
{
	promised(t, "promise");
}

testChunkPromised(t: ref T)
{
	promised(t, "chunkpromise");
}

whole(t: ref T, mode: string, n: int)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, mode, n, done);
	(r, err) := webclient->request("GET", url, nil, nil);
	<-done;
	t.assert(err == nil && r != nil, mode + ": request: " + err);
	if(r == nil)
		return;
	t.asserteq(len r.body, n, sys->sprint("%s: a body of %d bytes", mode, n));
	bad := -1;
	for(i := 0; i < len r.body && i < n; i++)
		if(r.body[i] != pat(i)) {
			bad = i;
			break;
		}
	t.asserteq(bad, -1, mode + ": the first byte that is not the one sent");
}

# Bodies of each framing arrive whole, at sizes either side of where
# the buffer grows.
testWholeBodies(t: ref T)
{
	sizes := array[] of {1, 1000, 65535, 65536, 65537, 131072, 300000};
	for(i := 0; i < len sizes; i++) {
		whole(t, "length", sizes[i]);
		whole(t, "chunked", sizes[i]);
		whole(t, "toend", sizes[i]);
	}
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# what a request of a server in mode gives: (response, error)
ask(t: ref T, mode: string, n: int): (ref Webclient->Response, string)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, mode, n, done);
	(r, err) := webclient->request("GET", url, nil, nil);
	<-done;
	return (r, err);
}

refused(t: ref T, mode, why: string)
{
	(r, err) := ask(t, mode, 100);
	what := "";
	if(r != nil)
		what = sys->sprint("status %d, %d bytes of body, truncated %d", r.statuscode, len r.body, r.truncated);
	t.assert(r == nil, mode + ": no response (" + what + ")");
	t.assert(contains(err, why), mode + ": the error says \"" + why + "\": " + err);
}

# A body the connection's end cut short is an error, by every framing
# that says where a body ends.
testCutShort(t: ref T)
{
	refused(t, "short", "cut short");
	refused(t, "chunkcut", "cut short");
	refused(t, "chunknolast", "cut short");

	# through requestbounded too; and it is not `truncated', which is
	# the caller's limit reached
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "short", 100, done);
	(r, err) := webclient->requestbounded("GET", url, nil, nil, 0, 5000, 0);
	<-done;
	t.assert(r == nil && contains(err, "cut short"), "requestbounded: " + err);

	# cut before the caller's limit: an error still
	(c, url) = announce(t);
	spawn serve(c, "short", 300, done);
	(r, err) = webclient->requestbounded("GET", url, nil, nil, 0, 5000, 200);
	<-done;
	t.assert(r == nil && contains(err, "cut short"), "150 bytes of 300 with a limit of 200: " + err);

	# the caller's limit reached first: truncated, and no error
	(c, url) = announce(t);
	spawn serve(c, "length", 300, done);
	(r, err) = webclient->requestbounded("GET", url, nil, nil, 0, 5000, 100);
	<-done;
	t.assert(r != nil && err == nil, "a body of 300 with a limit of 100: " + err);
	if(r != nil) {
		t.asserteq(len r.body, 100, "bytes kept");
		t.asserteq(r.truncated, 1, "said to be longer");
	}
}

# A body in Brotli decodes to no more than a body may be.  The decoder
# had no ceiling for a stream of no stated length: 77 bytes from a
# server were 96MB in the client (tests/web/brotli/mkzeros.py), and a
# few kilobytes would be gigabytes.
testBrotliCeiling(t: ref T)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "br", 1, done);
	(r, err) := webclient->requestjar("GET", url, nil, nil, nil);
	<-done;
	t.assert(r != nil && err == nil && len r.body == 1000000, "a megabyte of zeros from 13 bytes of Brotli: " + err);

	(c, url) = announce(t);
	spawn serve(c, "br", 96, done);
	t0 := sys->millisec();
	(r, err) = webclient->requestjar("GET", url, nil, nil, nil);
	<-done;
	t.assert(r == nil && contains(err, "too large"), sys->sprint("96MB from 77 bytes is refused as too large (it was a response of 96MB): %s (%dms)", err, sys->millisec() - t0));
}

# A kept connection is closed when it has been idle long enough,
# whether or not another request is ever made.  It was dropped only
# when the next request went looking for one, and closed when the
# collector found it: a program that made one request kept the
# connection, and the server its end, until the program ended.  The
# Prog that closes them is there only while something is kept.
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

testIdleReaped(t: ref T)
{
	webclient->setidle(400);
	sys->sleep(100);
	before := nprocs();
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "kept", 1500, done);
	(r, err) := webclient->request("GET", url, nil, nil);
	t.assert(r != nil && err == nil && string r.body == "KEPT", "the response: " + err);
	ms := <-done;
	t.assert(ms >= 300 && ms < 1400, sys->sprint("a connection kept and not used again is closed after its 400ms (it never was): %dms", ms));
	# the reaper has gone with the last connection (and the server's own timer)
	for(i := 0; i < 60 && nprocs() > before; i++)
		sys->sleep(50);
	t.asserteq(nprocs(), before, "and no Prog is left once nothing is kept");

	# one that is used again within its time is the same connection, and is closed after its last use
	(c, url) = announce(t);
	spawn serve2kept(c, done);
	(r, err) = webclient->request("GET", url, nil, nil);
	sys->sleep(200);
	(r, err) = webclient->request("GET", url, nil, nil);
	t.assert(r != nil && err == nil && string r.body == "KEPT", "a second request within the time: " + err);
	ms = <-done;
	t.assert(ms >= 300 && ms < 1400, sys->sprint("on the same connection, closed 400ms after its last use: %dms", ms));
	for(i = 0; i < 60 && nprocs() > before; i++)
		sys->sleep(50);
	t.asserteq(nprocs(), before, "and again no Prog is left");
	webclient->setidle(Webclient->IDLEMS);
}

# one connection, two requests on it, then how long until it is closed
serve2kept(c: Sys->Connection, done: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		done <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	buf := array[4096] of byte;
	for(i := 0; i < 2; i++) {
		req := "";
		while(!hasend(req)) {
			k := sys->read(fd, buf, len buf);
			if(k <= 0) {
				done <-= -3;
				return;
			}
			req += string buf[0:k];
		}
		say(fd, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nKEPT");
	}
	t0 := sys->millisec();
	got := chan[1] of int;
	spawn eofwait(fd, got);
	tmo := chan[1] of int;
	spawn timer(tmo, 1500);
	alt {
	<-got =>
		done <-= sys->millisec() - t0;
	<-tmo =>
		sys->fprint(sys->open(nc.dir + "/ctl", Sys->OWRITE), "hangup");
		done <-= -2;
	}
}

# What is not a response is refused as what it is.
testNotAResponse(t: ref T)
{
	refused(t, "cltext", "Content-Length");
	refused(t, "cldiffer", "Content-Length");
	refused(t, "badchunk", "chunk");
	refused(t, "chunknocrlf", "chunk");
	refused(t, "nothttp", "not an HTTP response");
	refused(t, "badcode", "status line");
	refused(t, "hdrcut", "header cut short");

	# lengths that agree are one length
	(r, err) := ask(t, "clsame", 0);
	t.assert(r != nil && err == nil && string r.body == "hello", "Content-Length: 5, 5: " + err);
}

# A Content-Length of -1 is no length: the response is refused and its
# connection is not kept, so the next request is answered by the server
# and not by what was left on the old connection.
testNegativeLength(t: ref T)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve2(c, "clneg", "real", done);
	(r, err) := webclient->request("GET", url, nil, nil);
	t.assert(r == nil && contains(err, "Content-Length"), "Content-Length: -1: " + err);
	(r, err) = webclient->request("GET", url, nil, nil);
	t.assert(r != nil && err == nil, "the request after it: " + err);
	if(r != nil)
		t.assertseq(string r.body, "REAL", "is answered on a connection of its own");
	tmo := chan[1] of int;
	spawn timer(tmo, 3000);
	alt {
	<-done =>
		;
	<-tmo =>
		t.error("the second request was not made on a new connection");
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# A redirect to a file: address is refused as what it is.
testRedirectToFile(t: ref T)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "tofile", 0, done);
	(r, err) := webclient->request("GET", url, nil, nil);
	<-done;
	t.assert(r == nil, "no response");
	t.assert(contains(err, "not an http"), "refused as no http address: " + err);
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

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load webclient: %r\n");
		raise "fail:cannot load webclient";
	}
	if((err := webclient->init()) != nil) {
		sys->fprint(sys->fildes(2), "webclient init: %s\n", err);
		raise "fail:webclient init";
	}

	run("LengthPromised", testLengthPromised);
	run("ChunkPromised", testChunkPromised);
	run("WholeBodies", testWholeBodies);
	run("RedirectToFile", testRedirectToFile);
	run("CutShort", testCutShort);
	run("BrotliCeiling", testBrotliCeiling);
	run("IdleReaped", testIdleReaped);
	run("NotAResponse", testNotAResponse);
	run("NegativeLength", testNegativeLength);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
