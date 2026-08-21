implement PublicnetHostTest;

#
# publicnet URL-host extraction and SSRF blocking.
#
# These two functions are the single definition used by every fetch
# tool (webfetch, payfetch, http). They previously existed as three
# hand-copied pairs which drifted apart, and both had parsing holes:
#   - userinfo was stripped AFTER the port, so "user:pass@127.0.0.1"
#     parsed as host "user" and passed the blocklist
#   - only decimal-dotted and bare-integer IPv4 forms were recognised,
#     so 0177.0.0.1 (octal) and 0x7f.0.0.1 (hex) reached loopback
#
# Pure functions; no network access.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "publicnet.m";
	publicnet: Publicnet;

include "testing.m";
	testing: Testing;
	T: import testing;

PublicnetHostTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/publicnet_host_test.b";

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

testUrlhost(t: ref T)
{
	t.assertseq(publicnet->urlhost("https://example.com/a/b"), "example.com",
		"plain host");
	t.assertseq(publicnet->urlhost("https://example.com:8443/a"), "example.com",
		"port stripped");
	t.assertseq(publicnet->urlhost("https://EXAMPLE.com"), "example.com",
		"lowercased");
	t.assertseq(publicnet->urlhost("https://example.com?q=1"), "example.com",
		"query stripped");

	# the userinfo-before-port ordering bug
	t.assertseq(publicnet->urlhost("http://user:pass@127.0.0.1/x"), "127.0.0.1",
		"userinfo with colon does not become the host");
	t.assertseq(publicnet->urlhost("http://user@example.com/x"), "example.com",
		"plain userinfo stripped");
	t.assertseq(publicnet->urlhost("http://a@b@example.com/x"), "example.com",
		"rightmost @ wins");

	# bracketed IPv6 survives extraction
	t.assertseq(publicnet->urlhost("http://[::1]/x"), "[::1]", "IPv6 literal kept");
	t.assertseq(publicnet->urlhost("http://[::1]:8080/x"), "[::1]",
		"IPv6 literal keeps brackets, drops port");
}

testBlockedNames(t: ref T)
{
	t.assert(publicnet->hostblocked("localhost"), "localhost blocked");
	t.assert(publicnet->hostblocked("LOCALHOST"), "case-insensitive");
	t.assert(publicnet->hostblocked("metadata.google.internal"), "cloud metadata blocked");
	t.assert(publicnet->hostblocked(""), "empty host blocked");
	t.assert(!publicnet->hostblocked("example.com"), "public name allowed");
	t.assert(!publicnet->hostblocked("sepolia.base.org"), "RPC endpoint allowed");
}

testBlockedIPv4(t: ref T)
{
	t.assert(publicnet->hostblocked("127.0.0.1"), "loopback blocked");
	t.assert(publicnet->hostblocked("10.0.0.5"), "10/8 blocked");
	t.assert(publicnet->hostblocked("192.168.1.1"), "192.168/16 blocked");
	t.assert(publicnet->hostblocked("169.254.169.254"), "link-local metadata blocked");
	t.assert(publicnet->hostblocked("172.16.0.1"), "172.16/12 low blocked");
	t.assert(publicnet->hostblocked("172.31.255.254"), "172.16/12 high blocked");
	t.assert(!publicnet->hostblocked("172.32.0.1"), "172.32 is public");
	t.assert(!publicnet->hostblocked("8.8.8.8"), "public IP allowed");

	# alternate radix encodings of 127.0.0.1 — the bypass class
	t.assert(publicnet->hostblocked("0177.0.0.1"), "octal-dotted loopback blocked");
	t.assert(publicnet->hostblocked("0x7f.0.0.1"), "hex-dotted loopback blocked");
	t.assert(publicnet->hostblocked("2130706433"), "packed-integer loopback blocked");
	t.assert(publicnet->hostblocked("0x7f000001"), "packed-hex loopback blocked");
	t.assert(publicnet->hostblocked("127.1"), "short-form loopback blocked");
	t.assert(publicnet->hostblocked("0300.0250.0.1"), "octal 192.168.0.1 blocked");
}

testBlockedIPv6(t: ref T)
{
	t.assert(publicnet->hostblocked("::1"), "IPv6 loopback blocked");
	t.assert(publicnet->hostblocked("[::1]"), "bracketed IPv6 loopback blocked");
	t.assert(publicnet->hostblocked("fe80::1"), "link-local blocked");
	t.assert(publicnet->hostblocked("fd00::1"), "unique-local blocked");
	t.assert(publicnet->hostblocked("fc00::1"), "fc00::/7 blocked");
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

	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet == nil) {
		sys->fprint(sys->fildes(2), "cannot load publicnet: %r\n");
		raise "fail:cannot load publicnet";
	}
	publicnet->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Urlhost", testUrlhost);
	run("Blocked/Names", testBlockedNames);
	run("Blocked/IPv4", testBlockedIPv4);
	run("Blocked/IPv6", testBlockedIPv6);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
