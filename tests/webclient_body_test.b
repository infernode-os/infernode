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
	}
	fd = nil;
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
	t.assert(err == nil && r != nil, "request: " + err);
	if(r != nil) {
		t.asserteq(len r.body, 1000, "the bytes that came");
		t.assert(len r.body == 1000 && r.body[999] == pat(999), "as they were sent");
	}
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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
