implement TlsVerify;

#
# tls->client with verification on, as webclient, llmclient, mc9p and
# mail9p call it, for tests/host/x509_chain_test.sh:
#
#	tlsverify label tcp!127.0.0.1!port servername
#
# with the test's roots bound over /lib/certs by the caller.  Prints
#
#	label: OK
#	label: FAIL the client's error
#	label: EXCEPTION text
#
# The last is a handshake that ended its caller: tls->client is given
# a peer's bytes, and answers with a connection or an error.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tls.m";
	tls: TLS;
	Conn: import tls;

TlsVerify: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(len args != 4) {
		sys->print("usage: tlsverify label addr servername\n");
		return;
	}
	label := hd tl args;
	addr := hd tl tl args;
	name := hd tl tl tl args;
	tls = load TLS TLS->PATH;
	if(tls == nil || (e := tls->init()) != nil) {
		sys->print("%s: cannot load TLS: %s\n", label, e);
		return;
	}
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0) {
		sys->print("%s: cannot dial %s: %r\n", label, addr);
		return;
	}
	config := tls->defaultconfig();
	config.servername = name;
	{
		(tc, err) := tls->client(c.dfd, config);
		if(tc == nil)
			sys->print("%s: FAIL %s\n", label, err);
		else {
			sys->print("%s: OK\n", label);
			tc.close();
		}
	} exception x {
	"*" =>
		sys->print("%s: EXCEPTION %s\n", label, x);
	}
}
