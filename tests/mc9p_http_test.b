implement Mc9pHttpTest;

#
# mc9p's http endpoints against an HTTP server of the test's own on the
# loopback, which keeps every request as it arrived.
#
# A request is one write. One longer than a 9P message was run as its
# pieces: a POST over 8K went out cut short and the client read "invalid
# URL" for the rest; it is now refused whole, and nothing is sent.
# A URL with a line break in it put header lines and a second request of
# the writer's on the wire; it is refused. A POST's Content-Length was
# its body's characters, not its bytes. A server's refusal (a 404) came
# back as though its page were the answer. The headers file said
# application/json where post sends a form.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Mc9pHttpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mc9p_http_test.b";

passed := 0;
failed := 0;
skipped := 0;

mnt: string;
port: string;
reqc: chan of string;	# each request the server took, whole

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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# The server: one request a connection, kept as bytes turned to Latin-1
# text (a byte a character, so lengths are bytes), answered by its path.
server(ac: Sys->Connection)
{
	for(;;) {
		(ok, nc) := sys->listen(ac);
		if(ok < 0)
			return;
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd == nil)
			continue;
		spawn serve1(dfd);
	}
}

serve1(dfd: ref Sys->FD)
{
	req := "";
	buf := array[8192] of byte;
	need := -1;
	for(;;) {
		e := find(req, "\r\n\r\n");
		if(e >= 0) {
			if(need < 0)
				need = e + 4 + clen(req[0:e]);
			if(len req >= need)
				break;
		}
		n := sys->read(dfd, buf, len buf);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			req[len req] = int buf[i];
	}
	resp := "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nhello";
	if(contains(req, " /missing "))
		resp = "HTTP/1.0 404 Not Found\r\nContent-Type: text/plain\r\n\r\ngone";
	b := array of byte resp;
	sys->write(dfd, b, len b);
	dfd = nil;
	reqc <-= req;
}

find(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

# Content-Length of a request's headers, 0 if none
clen(hdr: string): int
{
	k := "Content-Length: ";
	i := find(hdr, k);
	if(i < 0)
		return 0;
	return int hdr[i + len k:];
}

# the next request the server took, or nil after ms
nextreq(ms: int): string
{
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt {
	r := <-reqc =>
		return r;
	<-tc =>
		return nil;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { c <-= 1 => ; * => ; }
}

# write a request to an endpoint and read its answer on the same fd
request(ep, data: string): (string, string)
{
	fd := sys->open(mnt + "/http/" + ep, Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("open: %r"));
	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return (nil, sys->sprint("write: %r"));
	out := "";
	buf := array[8192] of byte;
	off := big 0;
	while((n := sys->pread(fd, buf, len buf, off)) > 0) {
		out += string buf[0:n];
		off += big n;
	}
	return (out, nil);
}

url(path: string): string
{
	return "http://127.0.0.1:" + port + path;
}

testGet(t: ref T)
{
	(r, err) := request("get", url("/ok"));
	t.assertnil(err, "get written");
	t.assertseq(r, "hello", "the body is the answer");
	q := nextreq(5000);
	t.assert(hasprefix(q, "GET /ok HTTP/1.0\r\n"), "the server got the request");
}

testStatus(t: ref T)
{
	(r, nil) := request("get", url("/missing"));
	t.assert(hasprefix(r, "error: HTTP") && contains(r, "404"),
		"a 404 is an error naming the status: " + r);
	nextreq(5000);
}

testNoLineBreakInURL(t: ref T)
{
	(r, err) := request("get", url("/a") + " HTTP/1.0\r\nHost: other\r\nX-Inj: 1\r\n\r\nGET /y");
	t.assert(err != nil || hasprefix(r, "error: invalid URL"),
		"a URL with a line break in it is refused: " + r + err);
	q := nextreq(1500);
	t.assert(q == nil, "and nothing reaches the server: " + q);
}

testPostLength(t: ref T)
{
	(r, err) := request("post", url("/ok") + "\nééé");
	t.assertnil(err, "post written");
	t.assertseq(r, "hello", "answered");
	q := nextreq(5000);
	t.assert(q != nil, "the server got the post");
	if(q == nil)
		return;
	e := find(q, "\r\n\r\n");
	t.asserteq(clen(q[0:e]), 6, "Content-Length is the body's bytes");
	t.asserteq(len q - (e + 4), 6, "and that many are sent");
	(h, nil) := request("headers", "x");
	t.assert(contains(q, "Content-Type: application/x-www-form-urlencoded") &&
		contains(h, "application/x-www-form-urlencoded"),
		"the headers file says what post sends: " + h);
}

testLongRequest(t: ref T)
{
	body := "";
	for(i := 0; i < 9000; i++)
		body[len body] = 'a' + i % 26;
	(r, err) := request("post", url("/ok") + "\n" + body);
	t.assert(err != nil && contains(err, "longer than one 9P message"),
		"a request longer than a 9P message is refused: " + err + r);
	q := nextreq(1500);
	t.assert(q == nil, sys->sprint("and no part of it is sent (%d bytes were)", len q));
	# a request of ordinary size after it is sent whole
	(r, err) = request("post", url("/ok") + "\n" + body[0:4000]);
	t.assertseq(r, "hello", "a 4000-byte post is answered");
	q = nextreq(5000);
	t.assert(q != nil && clen(q) == 4000 && contains(q, body[0:4000]), "and arrives whole");
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

	# mc9p gives up devices for the name space it is started in: one of
	# the test's own, with the network already in it
	sys->pctl(Sys->FORKNS, nil);
	sys->bind("#I", "/net", Sys->MAFTER);
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0) {
		sys->print("SKIP: no loopback announce here: %r\n");
		raise "skip:no IP stack";
	}
	lfd := sys->open(ac.dir + "/local", Sys->OREAD);
	buf := array[64] of byte;
	n := 0;
	if(lfd != nil)
		n = sys->read(lfd, buf, len buf);
	if(n <= 0)
		raise "fail:no local address";
	local := string buf[0:n];
	for(i := 0; i < len local; i++)
		if(local[i] == '!')
			port = local[i+1:];
	while(len port > 0 && (port[len port - 1] == '\n' || port[len port - 1] == ' '))
		port = port[0:len port - 1];
	reqc = chan[16] of string;
	spawn server(ac);

	mnt = sys->sprint("/tmp/mc9p_http_test.%d", sys->pctl(0, nil));
	sh := load Sh Sh->PATH;
	if(sh == nil)
		raise "fail:cannot load sh";
	if((err := sh->system(nil, "/dis/veltro/mc9p.dis -n -m " + mnt + " http")) != nil)
		raise "fail:mc9p: " + err;
	(sok, nil) := sys->stat(mnt + "/http/get");
	if(sok < 0)
		raise "fail:no mc9p at " + mnt;

	run("Http/Get", testGet);
	run("Http/Status", testStatus);
	run("Http/NoLineBreakInURL", testNoLineBreakInURL);
	run("Http/PostLength", testPostLength);
	run("Http/LongRequest", testLongRequest);

	sys->unmount(nil, mnt);
	sys->remove(mnt);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
