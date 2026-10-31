implement TlsChainLive;

# tls_chain_live [host[:port][=expect] ...]
# Handshake with each host (full verification: chain + hostname) and report
# whether the result matches the expectation (ok or fail).
# With no arguments, runs the built-in list of real sites and badssl.com cases.

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "webclient.m";
	wc: Webclient;

TlsChainLive: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

DEFAULT := array[] of {
	# must verify
	"sam.gov=ok", "api.sam.gov=ok", "api.usaspending.gov=ok",
	"www.google.com=ok", "github.com=ok", "api.anthropic.com=ok",
	"www.cloudflare.com=ok", "letsencrypt.org=ok", "www.digicert.com=ok",
	"www.amazon.com=ok", "www.microsoft.com=ok", "en.wikipedia.org=ok",
	"www.apple.com=ok", "tak.gov=ok", "www.af.mil=ok", "login.gov=ok",
	"www.gov.uk=ok", "www.nist.gov=ok",
	"ecc256.badssl.com=ok", "ecc384.badssl.com=ok", "rsa2048.badssl.com=ok",
	"rsa4096.badssl.com=ok", "sha256.badssl.com=ok",
	# must be rejected
	"self-signed.badssl.com=fail", "expired.badssl.com=fail",
	"wrong.host.badssl.com=fail", "untrusted-root.badssl.com=fail",
	"incomplete-chain.badssl.com=fail",
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	wc = load Webclient Webclient->PATH;
	if(wc == nil || (e := wc->init()) != nil)
		fail(sys->sprint("webclient: %r"));
	args = tl args;
	if(args == nil)
		for(i := len DEFAULT - 1; i >= 0; i--)
			args = DEFAULT[i] :: args;
	bad := 0;
	for(; args != nil; args = tl args){
		(target, expect) := str->splitl(hd args, "=");
		if(expect != nil)
			expect = expect[1:];
		(host, port) := str->splitl(target, ":");
		if(port == nil)
			port = "443";
		else
			port = port[1:];
		t0 := sys->millisec();
		(fd, err) := wc->tlsdial("tcp!" + host + "!" + port, host);
		ms := sys->millisec() - t0;
		got := "ok";
		if(fd == nil)
			got = "fail";
		verdict := "PASS";
		if(expect != nil && got != expect){
			verdict = "WRONG";
			bad++;
		}
		sys->print("%-5s %-4s %-32s %5dms %s\n", verdict, got, target, ms, err);
	}
	if(bad)
		raise sys->sprint("fail:%d wrong", bad);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "tls_chain_live: %s\n", s);
	raise "fail:init";
}
