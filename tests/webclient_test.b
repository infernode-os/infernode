implement WebclientTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;
	Response, Header, Jar: import webclient;

WebclientTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_test.b";

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

testHttpsGet(t: ref T)
{
	(resp, err) := webclient->get("https://example.com");
	if(err != nil) {
		t.skip("network: " + err);
		return;
	}
	t.assert(resp != nil, "response not nil");
	t.asserteq(resp.statuscode, 200, "status code");
	t.assert(resp.body != nil && len resp.body > 0, "body not empty");
	t.log("body length: " + string len resp.body);
}

testRedirect(t: ref T)
{
	# HTTP to HTTPS redirect
	(resp, err) := webclient->requestpublic("GET", "http://example.com", nil, nil);
	if(err != nil) {
		t.skip("network: " + err);
		return;
	}
	t.assert(resp != nil, "response not nil");
	# example.com may or may not redirect; just check we got a response
	t.assert(resp.statuscode == 200 || resp.statuscode == 301 || resp.statuscode == 302,
		"reasonable status: " + string resp.statuscode);
}

testTlsDial(t: ref T)
{
	(fd, err) := webclient->tlsdial("tcp!example.com!443", "example.com");
	if(err != nil) {
		t.skip("network: " + err);
		return;
	}
	t.assert(fd != nil, "fd not nil");

	# Send a minimal HTTP request
	req := array of byte "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
	n := sys->write(fd, req, len req);
	t.assert(n == len req, "write request");

	buf := array [1024] of byte;
	n = sys->read(fd, buf, len buf);
	t.assert(n > 0, "read response");
	respstr := string buf[:n];
	t.log("response start: " + respstr[:80]);
	t.assert(len respstr > 12, "response has content");
}

testPost(t: ref T)
{
	body := array of byte "test=hello";
	(resp, err) := webclient->post("https://httpbin.org/post",
		"application/x-www-form-urlencoded", body);
	if(err != nil) {
		t.skip("network: " + err);
		return;
	}
	t.assert(resp != nil, "response not nil");
	t.asserteq(resp.statuscode, 200, "status code");
	t.assert(resp.body != nil && len resp.body > 0, "body not empty");
}

testHeaderLookup(t: ref T)
{
	hdrs := Header("Content-Type", "text/html") ::
		Header("X-Custom", "hello") :: nil;
	resp := ref Response(200, "HTTP/1.1 200 OK", hdrs, nil, nil);
	t.assertseq(resp.hdrval("Content-Type"), "text/html", "Content-Type");
	t.assertseq(resp.hdrval("content-type"), "text/html", "case insensitive");
	t.assertseq(resp.hdrval("X-Custom"), "hello", "custom header");
	t.assertnil(resp.hdrval("Missing"), "missing header is nil");
}

testCookieJar(t: ref T)
{
	j := Jar.new();
	j.set("http://www.example.org/a/b", "sid=1; Path=/");
	j.set("http://www.example.org/a/b", "here=2");
	j.set("http://www.example.org/", "wide=3; Domain=.example.org");
	j.set("http://www.example.org/", "other=4; Domain=example.com");
	j.set("http://www.example.org/", "sec=5; Secure");
	j.set("https://www.example.org/", "sec=6; Secure; HttpOnly");

	t.assertseq(j.header("http://www.example.org/a/c"), "sid=1; here=2; wide=3", "path, domain");
	t.assertseq(j.header("http://www.example.org/x"), "sid=1; wide=3", "default path");
	t.assertseq(j.header("http://img.example.org/"), "wide=3", "domain cookie on a sibling");
	t.assertseq(j.header("https://www.example.org/"), "sid=1; wide=3; sec=6", "secure");
	t.assertnil(j.header("http://example.com/"), "another site");
	t.assertnil(j.header("http://badexample.org/"), "suffix is not a domain match");

	j.set("http://www.example.org/", "sid=x; Max-Age=0");
	t.assertseq(j.header("http://www.example.org/"), "wide=3", "max-age=0 deletes");

	k := Jar.new();
	for(l := tolines(j.text()); l != nil; l = tl l)
		t.assertnil(k.add(hd l), "add " + hd l);
	t.assertseq(k.text(), j.text(), "text/add round trip");
	t.assertseq(k.header("https://www.example.org/a/"), "here=2; wide=3; sec=6", "restored jar");
	k.clear();
	t.assertnil(k.header("https://www.example.org/"), "cleared");
	t.assertnotnil(k.add("example.org /"), "short line refused");
}

tolines(s: string): list of string
{
	(nil, l) := sys->tokenize(s, "\n");
	return l;
}

testPublicRequestRejectsPrivate(t: ref T)
{
	urls := array[] of {
		"http://127.0.0.1:1/",
		"http://10.1.2.3:1/",
		"http://100.64.0.1:1/",
		"http://169.254.169.254:1/",
		"http://172.16.0.1:1/",
		"http://192.168.1.1:1/",
		"http://192.0.2.1:1/",
		"http://198.51.100.1:1/",
		"http://203.0.113.1:1/",
		"http://2130706433:1/"
	};
	for(i := 0; i < len urls; i++) {
		(resp, err) := webclient->requestpublic("GET", urls[i], nil, nil);
		t.assert(resp == nil, "private destination returned no response: " + urls[i]);
		t.assert(err != nil && contains(err, "destination denied"),
			"private destination rejected by policy: " + urls[i] + " (" + err + ")");
	}
}

testRejectsControlRequestText(t: ref T)
{
	(resp, err) := webclient->requestpublic("GET", "http://example.com/\r\nX-Evil:%20yes", nil, nil);
	t.assert(resp == nil, "URL control characters returned no response");
	t.assert(err != nil && contains(err, "invalid URL text"),
		"URL control characters rejected before dial");

	(resp, err) = webclient->requestpublic("GET\r\nX-Evil: yes", "http://example.com/", nil, nil);
	t.assert(resp == nil, "method control characters returned no response");
	t.assert(err != nil && contains(err, "invalid HTTP method"),
		"method control characters rejected before dial");

	badhdrs := Header("X-Test", "ok\r\nX-Evil: yes") :: nil;
	(resp, err) = webclient->requestpublic("GET", "http://example.com/", badhdrs, nil);
	t.assert(resp == nil, "header value control characters returned no response");
	t.assert(err != nil && contains(err, "invalid HTTP header value"),
		"header value control characters rejected before dial");

	badhdrs = Header("X-Test: evil", "ok") :: nil;
	(resp, err) = webclient->requestpublic("GET", "http://example.com/", badhdrs, nil);
	t.assert(resp == nil, "header name separator returned no response");
	t.assert(err != nil && contains(err, "invalid HTTP header name"),
		"header name separator rejected before dial");
}

# A URL with a space or characters outside ASCII is sent percent-encoded,
# as a browser sends it, not refused (pantip.com's Thai tag links): the
# request gets as far as dialling (port 1 on the loopback, refused)
testEncodesURLText(t: ref T)
{
	for(l := "http://127.0.0.1:1/a b" :: "http://127.0.0.1:1/tag/\u0e14\u0e39" :: "http://127.0.0.1:1/?q=\"x\"" :: nil; l != nil; l = tl l) {
		(resp, err) := webclient->request("GET", hd l, nil, nil);
		t.assert(resp == nil, hd l + ": no response");
		t.assert(!contains(err, "invalid URL text"), hd l + ": not refused as text: " + err);
	}
}

contains(s, needle: string): int
{
	if(needle == nil || len needle == 0)
		return 1;
	for(i := 0; i + len needle <= len s; i++)
		if(s[i:i + len needle] == needle)
			return 1;
	return 0;
}

# A response whose type is not among those asked for is not read past
# its header: a loopback server offering 32 MB of audio/mpeg sees the
# connection go before it has sent it; one offering text/html sends it
# all, and its body comes back.
testTypes(t: ref T)
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
	url := "http://127.0.0.1:" + port + "/";
	sent := chan of int;
	huge := 32 * 1024 * 1024;
	spawn serve1(c, sent, "audio/mpeg", huge);
	(r, err) := webclient->requesttypes("GET", url + "a.mp3", nil, nil, nil, "text/" :: "+xml" :: nil);
	t.assert(err == nil, "request: " + err);
	n := <-sent;
	if(r != nil) {
		t.asserteq(r.statuscode, 200, "status as answered");
		t.assertseq(r.hdrval("Content-Type"), "audio/mpeg", "its type");
		t.asserteq(len r.body, 0, "no body");
	}
	t.assert(n < huge, sys->sprint("not read whole: %d of %d sent", n, huge));
	spawn serve1(c, sent, "text/html; charset=utf-8", 100000);
	(r, err) = webclient->requesttypes("GET", url + "p.html", nil, nil, nil, "text/" :: "+xml" :: nil);
	n = <-sent;
	t.assert(err == nil && r != nil, "request: " + err);
	if(r != nil)
		t.asserteq(len r.body, 100000, "a type asked for is read");
	spawn serve1(c, sent, "image/svg+xml", 1000);
	(r, err) = webclient->requesttypes("GET", url + "i.svg", nil, nil, nil, "text/" :: "+xml" :: nil);
	n = <-sent;
	if(r != nil)
		t.asserteq(len r.body, 1000, "a suffix (+xml) matches");
}

serve1(c: Sys->Connection, sent: chan of int, ctype: string, size: int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		sent <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		sent <-= -1;
		return;
	}
	req := "";
	buf := array[4096] of byte;
	while(!hasend(req)) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		req += string buf[0:n];
	}
	hdr := array of byte sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", ctype, size);
	sys->write(fd, hdr, len hdr);
	chunk := array[65536] of {* => byte 16rFF};
	total := 0;
	while(total < size) {
		k := len chunk;
		if(size - total < k)
			k = size - total;
		if(sys->write(fd, chunk, k) != k)
			break;
		total += k;
	}
	fd = nil;
	sent <-= total;
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
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load webclient: %r\n");
		raise "fail:cannot load webclient";
	}
	err := webclient->init();
	if(err != nil) {
		sys->fprint(sys->fildes(2), "webclient init: %s\n", err);
		raise "fail:webclient init";
	}

	# Non-network tests first
	run("HeaderLookup", testHeaderLookup);
	run("CookieJar", testCookieJar);
	run("PublicRequestRejectsPrivate", testPublicRequestRejectsPrivate);
	run("RejectsControlRequestText", testRejectsControlRequestText);
	run("EncodesURLText", testEncodesURLText);
	run("Types", testTypes);

	# Network tests (may skip if no connectivity)
	run("HttpsGet", testHttpsGet);
	run("Redirect", testRedirect);
	run("TlsDial", testTlsDial);
	run("Post", testPost);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
