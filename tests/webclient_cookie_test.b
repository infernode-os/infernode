implement WebclientCookieTest;

#
# webclient's cookie jar: what a response may put in it (RFC 6265 §5.3,
# as RFC 6265bis tightens it).
#
# A Set-Cookie was taken if its Domain was the tail of the host's name
# and for no other reason.  So a page at evil.com set "sid=attacker;
# Domain=com", and the jar sent it to every .com site from then on (one
# site choosing the session another is given); with a control character
# in the value, every request that cookie matched was refused before it
# was sent ("invalid HTTP header value"), for as long as the cookie
# lived; and a response over plain http replaced, or with Max-Age=0
# deleted, a cookie the site had set Secure over https.  A jar's text()
# read back by add() turned a host's cookie whose value had a blank in
# it into one for every name under the host.
#
# The jar's functions need no network; the last test runs a request
# against a server on the loopback and looks at the Cookie header it
# was sent.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;
	Jar, Header: import webclient;

WebclientCookieTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_cookie_test.b";

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

# A cookie for a name sites are registered under is not taken.
testPublicSuffix(t: ref T)
{
	j := Jar.new();
	j.set("http://evil.com/", "sid=attacker; Domain=com; Path=/");
	t.assertnil(j.header("https://bank.com/login"), "Domain=com from evil.com, at bank.com");
	t.assertnil(j.header("http://evil.com/"), "and not kept for evil.com either");
	j.set("http://a.evil.co.uk/", "t=1; Domain=co.uk");
	t.assertnil(j.header("https://other.co.uk/"), "Domain=co.uk");
	j.set("http://a.evil.com.au/", "t=1; Domain=.com.au");
	t.assertnil(j.header("https://other.com.au/"), "Domain=.com.au");
	j.set("http://mallory.github.io/", "t=1; Domain=github.io");
	t.assertnil(j.header("https://alice.github.io/"), "Domain=github.io");
	j.set("http://a.b.me.uk/", "t=1; Domain=me.uk");
	t.assertnil(j.header("https://c.me.uk/"), "Domain=me.uk");
	t.assertnil(j.text(), "nothing kept: " + j.text());

	# the last Domain attribute is the one that counts
	j.set("http://www.example.org/", "t=1; Domain=example.org; Domain=org");
	t.assertnil(j.header("http://www.example.org/"), "a second Domain of org");

	# not names
	j.set("http://www.example.org/", "t=1; Domain=example..org");
	j.set("http://www.example.org/", "t=2; Domain=..");
	j.set("http://www.example.org/", "t=3; Domain=example.org.");
	t.assertnil(j.text(), "domains with an empty label: " + j.text());

	# the host of that very name: a cookie for it alone
	j = Jar.new();
	j.set("http://localhost/", "a=1; Domain=localhost");
	t.assertseq(j.header("http://localhost/x"), "a=1", "Domain=localhost from localhost");
	t.assertnil(j.header("http://x.localhost/"), "host only");
	j.set("http://127.0.0.1/", "b=2; Domain=127.0.0.1");
	t.assertseq(j.header("http://127.0.0.1/"), "b=2", "an address's own cookie");
	j.set("http://10.0.0.1/", "c=3; Domain=0.0.1");
	t.assertnil(j.header("http://10.0.0.1/"), "the tail of an address is no domain");

	# what sites do is still taken
	j = Jar.new();
	j.set("http://www.example.org/", "wide=3; Domain=.example.org");
	t.assertseq(j.header("http://img.example.org/"), "wide=3", "a site's own domain");
	j.set("https://www.example.co.uk/", "uk=4; Domain=example.co.uk");
	t.assertseq(j.header("https://shop.example.co.uk/"), "uk=4", "a site under co.uk");
	t.assertnil(j.header("https://other.co.uk/"), "and not its neighbour");
	j.set("https://alice.github.io/", "own=5; Domain=alice.github.io");
	t.assertseq(j.header("https://alice.github.io/"), "own=5", "a hosted site's own name");
	j.set("http://www.example.org/", "other=4; Domain=example.com");
	t.assertnil(j.header("http://example.com/"), "another site's domain");
}

# A control character in a cookie is not kept, so cannot be sent.
testControl(t: ref T)
{
	j := Jar.new();
	j.set("http://www.example.org/", "a=\u0001; Domain=example.org; Max-Age=1000");
	j.set("http://www.example.org/", "b=x\u007fy");
	j.set("http://www.example.org/", "c=x\ty");
	j.set("http://www.example.org/", "d\u0002=1");
	j.set("http://www.example.org/", "e=1; Path=/\u0003");
	t.assertnil(j.header("http://www.example.org/"), "cookies with control characters");
	t.assertnil(j.text(), "none kept");
	t.assertnotnil(j.add("example.org / f=\u0001 0 0 0 0"), "nor added");
	t.assertnil(j.text(), "none added");

	lng := "";
	for(i := 0; i < 5000; i++)
		lng[len lng] = 'x';
	j.set("http://www.example.org/", "g=" + lng);
	t.assertnil(j.header("http://www.example.org/"), "a value of 5000 characters");
	j.set("http://www.example.org/", "g=" + lng[0:4000]);
	t.assertseq(j.header("http://www.example.org/"), "g=" + lng[0:4000], "one of 4000");
}

# A response over plain http leaves a Secure cookie alone.
testSecureAlone(t: ref T)
{
	j := Jar.new();
	j.set("https://bank.example/", "session=good; Secure; Path=/");
	t.assertseq(j.header("https://bank.example/"), "session=good", "set over https");
	t.assertnil(j.header("http://bank.example/"), "a Secure cookie is not sent in clear");

	j.set("http://bank.example/", "session=attacker; Path=/");
	t.assertseq(j.header("https://bank.example/"), "session=good", "after an http set of its name");
	t.assertnil(j.header("http://bank.example/"), "which was not kept at all");
	j.set("http://bank.example/", "session=x; Path=/; Max-Age=0");
	t.assertseq(j.header("https://bank.example/"), "session=good", "after an http Max-Age=0");
	j.set("http://bank.example/", "session=x; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT");
	t.assertseq(j.header("https://bank.example/"), "session=good", "after an http Expires in the past");
	j.set("http://bank.example/a/b", "session=deeper");
	t.assertseq(j.header("https://bank.example/a/b"), "session=good", "one for a path below it");
	j.set("http://www.bank.example/", "session=wide; Domain=bank.example");
	t.assertseq(j.header("https://bank.example/"), "session=good", "one from a name under it, for the domain");
	j.set("http://bank.example/", "session=sec; Secure");
	t.assertseq(j.header("https://bank.example/"), "session=good", "a Secure one from http");

	# what http may still do
	j.set("http://bank.example/", "theme=dark");
	t.assertseq(j.header("http://bank.example/"), "theme=dark", "another name, from http");
	# and https may change its own
	j.set("https://bank.example/", "session=new; Secure; Path=/");
	t.assertseq(j.header("https://bank.example/"), "theme=dark; session=new", "replaced over https");
	j.set("https://bank.example/", "session=; Secure; Path=/; Max-Age=0");
	t.assertseq(j.header("https://bank.example/"), "theme=dark", "deleted over https");

	# a Secure cookie for /admin does not stop http setting the name for a path beside it
	j = Jar.new();
	j.set("https://bank.example/admin/", "k=s; Secure; Path=/admin");
	j.set("http://bank.example/pub/x", "k=p; Path=/pub");
	t.assertseq(j.header("http://bank.example/pub/x"), "k=p", "a path the Secure one is not sent to");
	t.assertseq(j.header("https://bank.example/admin/x"), "k=s", "the Secure one as it was");
}

# __Secure- and __Host- names are what they say.
testPrefixes(t: ref T)
{
	j := Jar.new();
	j.set("https://www.example.org/", "__Secure-a=1");
	j.set("https://www.example.org/", "__Host-b=1; Secure");
	j.set("https://www.example.org/", "__Host-c=1; Secure; Path=/; Domain=example.org");
	j.set("https://www.example.org/x/y", "__Host-d=1; Secure; Path=/x");
	j.set("https://www.example.org/", "__HOST-e=1; Path=/");
	t.assertnil(j.text(), "prefixed names without what they promise: " + j.text());
	j.set("https://www.example.org/", "__Secure-a=1; Secure");
	j.set("https://www.example.org/", "__Host-b=2; Secure; Path=/");
	t.assertseq(j.header("https://www.example.org/"), "__Secure-a=1; __Host-b=2", "and with it");
}

# Max-Age that is no number is not Max-Age=0.
testMaxAge(t: ref T)
{
	j := Jar.new();
	j.set("http://www.example.org/", "a=1");
	j.set("http://www.example.org/", "a=2; Max-Age=soon");
	t.assertseq(j.header("http://www.example.org/"), "a=2", "Max-Age=soon sets, and does not delete");
	j.set("http://www.example.org/", "a=3; Max-Age=99999999999999");
	t.assertseq(j.header("http://www.example.org/"), "a=3", "a Max-Age past an int");
	j.set("http://www.example.org/", "a=4; Max-Age=-5");
	t.assertnil(j.header("http://www.example.org/"), "a negative Max-Age deletes");
}

# A jar holds so many cookies for a domain, and the oldest go.
testLimit(t: ref T)
{
	j := Jar.new();
	for(i := 0; i < 400; i++)
		j.set("http://www.example.org/", sys->sprint("c%d=%d", i, i));
	(n, nil) := sys->tokenize(j.text(), "\n");
	t.assert(n <= 180, sys->sprint("%d cookies kept for one host", n));
	h := j.header("http://www.example.org/");
	t.assert(contains(h, "c399=399"), "the newest is among them");
	t.assert(!contains(h, "c0=0;"), "the oldest is not");
}

# text() and add() agree, blanks in a value included.
testText(t: ref T)
{
	j := Jar.new();
	j.set("http://www.example.org/", "x=y 0 0 0 0");
	j.set("http://www.example.org/", "said=hello there, world; Path=/a");
	j.set("http://www.example.org/", "p=1; Path=/with blank");
	k := Jar.new();
	for(l := tolines(j.text()); l != nil; l = tl l)
		t.assertnil(k.add(hd l), "add " + hd l);
	t.assertseq(k.text(), j.text(), "text/add round trip");
	t.assertseq(k.header("http://www.example.org/a/"), "x=y 0 0 0 0; said=hello there, world; p=1", "the restored jar's cookies");
	t.assertnil(k.header("http://sub.www.example.org/"), "a host's cookie is still the host's alone");

	# a line for a name sites are registered under is that host's alone
	k = Jar.new();
	t.assertnil(k.add("com / sid=attacker 0 0 0 0"), "add");
	t.assertnil(k.header("https://bank.com/"), "a line for com, at bank.com");
	t.assertnotnil(k.add("example..org / a=b"), "not a domain");
}

tolines(s: string): list of string
{
	(nil, l) := sys->tokenize(s, "\n");
	return l;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# ---- over a connection ----

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

hasend(s: string): int
{
	for(i := 0; i + 3 < len s; i++)
		if(s[i:i+4] == "\r\n\r\n")
			return 1;
	return 0;
}

# Take one connection, give back its request, and answer with setcookie.
serve(c: Sys->Connection, setcookie: string, got: chan of string)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		got <-= "";
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		got <-= "";
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
	b := array of byte ("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n" + setcookie + "\r\nok");
	sys->write(fd, b, len b);
	fd = nil;
	got <-= req;
}

# A request with a jar: a Secure cookie stays out of a request in
# clear, a poisonous one does not stop the request, and what the
# response sets is held to the same rules.
testRequest(t: ref T)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	url := "http://127.0.0.1:" + port + "/";

	j := Jar.new();
	t.assertnil(j.add("127.0.0.1 / plain=1 0 0 0 1"), "add");
	t.assertnil(j.add("127.0.0.1 / secret=2 0 1 0 1"), "add");
	j.set(url, "bad=\u0001; Max-Age=1000");
	got := chan[1] of string;
	spawn serve(c, "Set-Cookie: s=1; Secure\r\nSet-Cookie: w=2; Domain=1\r\nSet-Cookie: fine=3\r\n", got);
	(r, err) := webclient->requestjar("GET", url, nil, nil, j);
	t.assert(r != nil && err == nil, "the request is made: " + err);
	if(r == nil)
		return;
	req := <-got;
	t.assert(contains(req, "Cookie: plain=1\r\n"), "the Cookie header sent in clear: " + cookieline(req));
	t.assertseq(j.header(url), "plain=1; fine=3", "what the response set");
}

cookieline(req: string): string
{
	(nil, l) := sys->tokenize(req, "\r\n");
	for(; l != nil; l = tl l)
		if(len hd l >= 7 && (hd l)[0:7] == "Cookie:")
			return hd l;
	return "(none)";
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

	run("PublicSuffix", testPublicSuffix);
	run("Control", testControl);
	run("SecureAlone", testSecureAlone);
	run("Prefixes", testPrefixes);
	run("MaxAge", testMaxAge);
	run("Limit", testLimit);
	run("Text", testText);
	run("Request", testRequest);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
