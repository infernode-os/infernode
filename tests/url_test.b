implement UrlTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "url.m";
	url: Url;
	ParsedUrl: import url;

include "testing.m";
	testing: Testing;
	T: import testing;

UrlTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/url_test.b";

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

# makeurl(s) has these host, port, path, query and fragment
parts(t: ref T, s, host, port, path, query, frag: string)
{
	u := url->makeurl(s);
	t.assertseq(u.host, host, s + ": host");
	t.assertseq(u.port, port, s + ": port");
	t.assertseq(u.path, path, s + ": path");
	t.assertseq(u.query, query, s + ": query");
	t.assertseq(u.frag, frag, s + ": fragment");
}

# The authority ends at the first / ? or # (RFC 3986 §3.2): a link
# to a site's top with a query and no path (CNN's edition picker) was
# dialled as the host "us.cnn.com?hpt=..."
testAuthorityEnds(t: ref T)
{
	parts(t, "https://us.cnn.com?hpt=header", "us.cnn.com", "", "", "hpt=header", "");
	parts(t, "https://example.com#top", "example.com", "", "", "", "top");
	parts(t, "https://example.com:8443?a=1#b", "example.com", "8443", "", "a=1", "b");
	parts(t, "https://example.com/p/q?a=1#b", "example.com", "", "p/q", "a=1", "b");
	parts(t, "http://example.com", "example.com", "", "", "", "");
	parts(t, "http://u:pw@example.com:81/x", "example.com", "81", "x", "", "");
}

# an IPv6 address is in brackets, for its colons
testIPv6(t: ref T)
{
	parts(t, "http://[::1]:8080/x", "::1", "8080", "x", "", "");
	parts(t, "http://[2001:db8::1]/x?q#f", "2001:db8::1", "", "x", "q", "f");
	parts(t, "https://[::ffff:192.0.2.1]", "::ffff:192.0.2.1", "", "", "", "");
	u := url->makeurl("http://u:pw@[fe80::1]:81/p");
	if(u == nil)
		t.fatal("http://u:pw@[fe80::1]:81/p is not read");
	t.assertseq(u.user, "u", "the user before an IPv6 host");
	t.assertseq(u.host, "fe80::1", "its host");
	t.assertseq(u.port, "81", "its port");
	t.assertseq(u.tostring(), "http://u:pw@[fe80::1]:81/p", "written with its brackets");
	t.assertseq(url->makeurl("http://[::1]/").tostring(), "http://[::1]/", "written with its brackets, no port");
	no := array[] of {"http://[::1/x", "http://[::1]x/", "http://[]/", "http://[::1]:80x/", "http://[zz::1]/", "http://[::1%eth0]/"};
	for(i := 0; i < len no; i++)
		t.assert(url->makeurl(no[i]) == nil, no[i] + " is no URL");
}

# What is between // and the path goes to a dial string, a Host header
# and the connection server: a host or port that is none is refused.
testAuthorityChars(t: ref T)
{
	no := array[] of {
		"http://evil!80/",
		"http://127.0.0.1!80/x",
		"http://h:80abc/",
		"http://h:80!x/",
		"http://h:123456/",
		"http://h:-1/",
		"http://h o/",
		"http://h\to/",
		"http://h\r\nX-Injected: y/",
		"http://h:80\r\n/",
		"http://good.example\\@evil.example/",
		"http://good.example\\.evil.example/",
		"http://a]b/",
	};
	for(i := 0; i < len no; i++)
		t.assert(url->makeurl(no[i]) == nil, sys->sprint("%q is no URL", no[i]));

	# the user's name ends at the last @
	u := url->makeurl("http://a@b@c/p");
	if(u == nil)
		t.fatal("http://a@b@c/p is not read");
	t.assertseq(u.host, "c", "http://a@b@c/p: host");
	u = url->makeurl("http://user:pw@127.0.0.1@public.example/");
	t.assert(u != nil && u.host == "public.example", "the host after the last @");
	# and what was a URL is one
	parts(t, "http://h:/x", "h", "", "x", "", "");
	parts(t, "http://h:65535/x", "h", "65535", "x", "", "");
	parts(t, "http://xn--bcher-kva.example/", "xn--bcher-kva.example", "", "", "", "");
	parts(t, "http://a_b.example-1.com/", "a_b.example-1.com", "", "", "", "");
	u = url->makeurl("/a b/c d?e f");
	t.assert(u != nil && u.path == "a b/c d", "a path with blanks in it, as before");
}

abs(t: ref T, base, rel, want: string)
{
	u := url->makeurl(rel);
	b := url->makeurl(base);
	if(u == nil || b == nil){
		t.error(base + " or " + rel + " is not read");
		return;
	}
	u.makeabsolute(b);
	t.assertseq(u.tostring(), want, rel + " from " + base);
}

# . and .. as the last part of a relative URL are parts like any other
testDotSegments(t: ref T)
{
	base := "http://h/a/b/c";
	abs(t, base, "..", "http://h/a/");
	abs(t, base, "../..", "http://h/");
	abs(t, base, "../../..", "http://h/");
	abs(t, base, "../../../..", "http://h/");
	abs(t, base, ".", "http://h/a/b/");
	abs(t, base, "x/..", "http://h/a/b/");
	abs(t, base, "x/.", "http://h/a/b/x/");
	abs(t, base, "../x", "http://h/a/x");
	abs(t, base, "./x", "http://h/a/b/x");
	abs(t, base, "x", "http://h/a/b/x");
	abs(t, base, "x/y/../z", "http://h/a/b/x/z");
	abs(t, base, "..x", "http://h/a/b/..x");
	abs(t, base, "/..", "http://h/..");	# not made relative: its path is its own
}

# "http:page" is relative only to a base that is http
testSchemeRelative(t: ref T)
{
	abs(t, "http://h:81/d/x", "http:foo", "http://h:81/d/foo");
	u := url->makeurl("http:foo");
	b := url->makeurl("https://user:pw@h:8443/d/x");
	u.makeabsolute(b);
	t.assertseq(u.host, "", "http:foo takes no host from an https base");
	t.assertseq(u.user + u.passwd + u.port, "", "nor its name, password or port");
	abs(t, "https://user:pw@h:8443/d/x", "foo", "https://user:pw@h:8443/d/foo");
	# nothing to resolve against
	u = url->makeurl("foo");
	u.makeabsolute(nil);
	t.assertseq(u.tostring(), "foo", "made absolute against no base");
}

# what is sent for a URL with no path is /, with its query
testNoPathRequest(t: ref T)
{
	u := url->makeurl("https://us.cnn.com?hpt=header");
	t.assertseq(u.pstart + u.path, "/", "the path asked for");
	t.assertseq(u.tostring(), "https://us.cnn.com/?hpt=header", "as a string");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	url = load Url Url->PATH;
	if(testing == nil || url == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load modules";
	}
	testing->init();
	url->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("AuthorityEnds", testAuthorityEnds);
	run("NoPathRequest", testNoPathRequest);
	run("IPv6", testIPv6);
	run("AuthorityChars", testAuthorityChars);
	run("DotSegments", testDotSegments);
	run("SchemeRelative", testSchemeRelative);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
