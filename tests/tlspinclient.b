implement TlsPinClient;

#
# TLS 1.3 client-certificate and key-pinning driver for interop tests
# against an external server (tests/host/tls_clientauth_test.sh):
#
#   tlspinclient [-d keydir] [-c cert.der] [-p pinhex] tcp!127.0.0.1!PORT
#   tlspinclient -V cert.der -p pinhex
#
# -d selects brick's purpose=tls bundle from a running factotum using the
# public hash of keydir; no private scalar is read from the namespace.  -c
# overrides the public certificate for the wrong-key regression.  pinhex is
# the SHA-256 of the server's SubjectPublicKeyInfo.  Prints HANDSHAKE-OK or
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
include "keyring.m";
	keyring: Keyring;
include "factotum.m";
	factotum: Factotum;

TlsPinClient: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	tls = load TLS TLS->PATH;
	keyring = load Keyring Keyring->PATH;
	factotum = load Factotum Factotum->PATH;
	if(tls == nil || keyring == nil || factotum == nil){ sys->print("FAIL: cannot load TLS/keyring/factotum\n"); return; }
	if((e := tls->init()) != nil){ sys->print("FAIL: tls init: %s\n", e); return; }
	factotum->init();

	config := tls->defaultconfig();
	config.minver = TLS->TLS13;
	config.maxver = TLS->TLS13;
	certoverride: string;
	verifycert: string;
	for(argv = tl argv; argv != nil && len hd argv > 1 && (hd argv)[0] == '-'; argv = tl tl argv){
		if(tl argv == nil){ sys->print("FAIL: usage\n"); return; }
		v := hd tl argv;
		case hd argv {
		"-d" =>
			(config.clientkey, config.clientcert) = brickcredential(v);
			if(config.clientkey == nil || config.clientcert == nil){
				sys->print("FAIL: no valid brick TLS credential in factotum for %s\n", v);
				return;
			}
		"-c" =>
			certoverride = v;
		"-p" =>
			config.pinspki = unhex(v);
		"-V" =>
			verifycert = v;
		* =>
			sys->print("FAIL: usage\n");
			return;
		}
	}
	if(certoverride != nil){
		config.clientcert = readbin(certoverride);
		if(config.clientcert == nil){
			sys->print("FAIL: bad certificate %s\n", certoverride);
			return;
		}
	}
	if(verifycert != nil){
		cert := readbin(verifycert);
		if(cert == nil || len config.pinspki != Keyring->SHA256dlen){
			sys->print("PIN-FAIL: bad certificate or pin input\n");
			return;
		}
		e = tls->verifyspkipin(config.pinspki, cert);
		if(e == nil)
			sys->print("PIN-OK\n");
		else
			sys->print("PIN-FAIL: %s\n", e);
		return;
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

brickcredential(keydir: string): (array of byte, array of byte)
{
	b := array of byte keydir;
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(b, len b, d, nil);
	attrs := "proto=pass service=brick role=client slot=" + hex(d) +
		" purpose=tls";
	(nil, bundle) := factotum->getuserpasswd(attrs);
	for(i := 0; i < len bundle && bundle[i] != ':'; i++)
		;
	if(i == len bundle)
		return (nil, nil);
	key := unhex(bundle[0:i]);
	cert := unhex(bundle[i+1:]);
	if(len key != 32 || cert == nil)
		return (nil, nil);
	return (key, cert);
}

hex(a: array of byte): string
{
	digits := "0123456789abcdef";
	s := array[2*len a] of byte;
	for(i := 0; i < len a; i++){
		s[2*i] = byte digits[int a[i] >> 4 & 16rf];
		s[2*i+1] = byte digits[int a[i] & 16rf];
	}
	return string s;
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
