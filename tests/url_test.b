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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
