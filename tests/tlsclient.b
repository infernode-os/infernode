implement TlsClient;

#
# Minimal TLS client driver for interop testing the CNSA hybrid key exchange
# (SecP384r1MLKEM1024) against an external server (e.g. OpenSSL s_server).
# Run with CNSAMODE=1 to offer the hybrid group.
#
#   tlsclient tcp!127.0.0.1!PORT
#
# Prints HANDSHAKE-OK (with negotiated version/suite) or HANDSHAKE-FAIL.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tls.m";
	tls: TLS;
	Conn: import tls;

TlsClient: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	tls = load TLS TLS->PATH;
	if(tls == nil){ sys->print("FAIL: cannot load TLS\n"); return; }
	if((e := tls->init()) != nil){ sys->print("FAIL: tls init: %s\n", e); return; }

	argv = tl argv;
	if(argv == nil){ sys->print("usage: tlsclient tcp!host!port\n"); return; }
	addr := hd argv;

	(ok, c) := sys->dial(addr, nil);
	if(ok < 0){ sys->print("FAIL: dial %s: %r\n", addr); return; }

	config := tls->defaultconfig();
	config.insecure = 1;		# exercising the key exchange, not the PKI
	config.servername = "localhost";

	(tc, err) := tls->client(c.dfd, config);
	if(tc == nil){
		sys->print("HANDSHAKE-FAIL: %s\n", err);
		return;
	}
	sys->print("HANDSHAKE-OK version=%4.4x suite=%4.4x\n", tc.version, tc.suite);

	req := array of byte "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
	if(tc.write(req, len req) < 0){
		sys->print("WRITE-FAIL: %r\n");
		return;
	}
	buf := array[1024] of byte;
	n := tc.read(buf, len buf);
	if(n > 0){
		m := n;
		if(m > 48)
			m = 48;
		sys->print("DATA-OK %d bytes; first line: %s\n", n, string buf[0:m]);
	}else
		sys->print("DATA-NONE (read returned %d)\n", n);
	tc.close();
}
