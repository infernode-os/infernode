implement TlsPinClient;

#
# TLS 1.3 client-certificate and key-pinning driver for interop tests
# against an external server (tests/tls_clientauth_test.sh):
#
#   tlspinclient [-d keydir] [-p pinhex] tcp!127.0.0.1!PORT
#
# keydir holds client.key (64 hex digits, a P-256 private scalar) and
# client.crt (DER), as brick(1) writes them; pinhex is the SHA-256 of
# the server's SubjectPublicKeyInfo.  Prints HANDSHAKE-OK or
# HANDSHAKE-FAIL, then sends an HTTP request and prints DATA-OK if the
# server answers: under TLS 1.3 a server that refuses our certificate
# says so only after the client's handshake has finished.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tls.m";
	tls: TLS;
	Conn: import tls;

TlsPinClient: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	tls = load TLS TLS->PATH;
	if(tls == nil){ sys->print("FAIL: cannot load TLS\n"); return; }
	if((e := tls->init()) != nil){ sys->print("FAIL: tls init: %s\n", e); return; }

	config := tls->defaultconfig();
	config.minver = TLS->TLS13;
	config.maxver = TLS->TLS13;
	for(argv = tl argv; argv != nil && len hd argv > 1 && (hd argv)[0] == '-'; argv = tl tl argv){
		if(tl argv == nil){ sys->print("FAIL: usage\n"); return; }
		v := hd tl argv;
		case hd argv {
		"-d" =>
			config.clientkey = unhex(readfile(v + "/client.key"));
			config.clientcert = readbin(v + "/client.crt");
			if(config.clientkey == nil || config.clientcert == nil){
				sys->print("FAIL: bad keys in %s\n", v);
				return;
			}
		"-p" =>
			config.pinspki = unhex(v);
		* =>
			sys->print("FAIL: usage\n");
			return;
		}
	}
	if(argv == nil){ sys->print("FAIL: usage\n"); return; }
	addr := hd argv;

	(ok, c) := sys->dial(addr, nil);
	if(ok < 0){ sys->print("FAIL: dial %s: %r\n", addr); return; }

	(tc, err) := tls->client(c.dfd, config);
	if(tc == nil){
		sys->print("HANDSHAKE-FAIL: %s\n", err);
		return;
	}
	sys->print("HANDSHAKE-OK version=%4.4x suite=%4.4x group=%4.4x\n", tc.version, tc.suite, tc.group);

	req := array of byte "GET / HTTP/1.0\r\n\r\n";
	if(tc.write(req, len req) < 0){
		sys->print("WRITE-FAIL: %r\n");
		return;
	}
	buf := array[1024] of byte;
	n := tc.read(buf, len buf);
	if(n > 0)
		sys->print("DATA-OK %d\n", n);
	else
		sys->print("DATA-FAIL: %r\n");
	tc.close();
}

readfile(f: string): string
{
	b := readbin(f);
	s := string b;
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

readbin(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return buf[0:n];
}

unhex(s: string): array of byte
{
	if(len s == 0 || len s % 2)
		return nil;
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		hi := hexval(s[2*i]);
		lo := hexval(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[i] = byte (hi << 4 | lo);
	}
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}
