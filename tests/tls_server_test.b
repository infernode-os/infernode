implement TLSServerTest;

#
# The TLS 1.3 server (tls->server, appl/lib/crypt/tls.b) against the
# module's own client over a pipe: the handshake completes with the
# client verifying the server's CertificateVerify (its key pinned), data
# both ways past a record, each suite and group the server takes, a
# HelloRetryRequest; the server's key read from PEM, SEC1 and PKCS #8,
# checkserver refusing a key that is not the certificate's; and 3000
# ClientHellos made from a real one by changing, cutting and lengthening
# it, which the server refuses or answers without raising anything (a
# write on a pipe its client closed raised, found under tools/sanemu's
# slower emu) and without waiting for ever.
#
# tests/host/httpd_test.sh takes the server to curl and OpenSSL.
#
# The key here is a test key for a certificate made for this test
# (CN=localhost, 100 years), kept as hex DER, not PEM: a PEM private key
# in a package refuses the release (tools/release-scrub.sh).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "tls.m";
	tls: TLS;
	Conn, Config, ServerConfig: import tls;

include "testing.m";
	testing: Testing;
	T: import testing;

TLSServerTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tls_server_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

CERTPEM: con
	"-----BEGIN CERTIFICATE-----\n" +
	"MIIBmzCCAUGgAwIBAgIUGHGp9gPp2Ui7RZ464BSqpIkXD74wCgYIKoZIzj0EAwIw\n" +
	"FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTExMzE5MDgxMloYDzIxMjYxMDIw\n" +
	"MTkwODEyWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO\n" +
	"PQMBBwNCAAR/LMp8S2ExHcJxi4RdkRvkYVTFwfnG5eJd+xhRn+wXBdWI/fgWeGCy\n" +
	"fhz4gMRha0JXMJ0QWA/QohkNRtdOOyDJo28wbTAdBgNVHQ4EFgQUadLLdkko98Tx\n" +
	"RQaO/ydpvHeI0mQwHwYDVR0jBBgwFoAUadLLdkko98TxRQaO/ydpvHeI0mQwDwYD\n" +
	"VR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZI\n" +
	"zj0EAwIDSAAwRQIgY1VPpMaOX0EaNEzaXA00bnBqYVapgzbE0h+ksP0jCpoCIQDH\n" +
	"pABn3TNwvhhBzdUf+X6B35uAp/SQlc94hTVCIGC8nw==\n" +
	"-----END CERTIFICATE-----\n" +
	"";

# The certificate's key: PKCS #8 (openssl req -newkey) and SEC1 (openssl ec)
KEYPKCS8: con "308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b02010104204b4d2e92e9bad634c7652f359dd8e4d774016aee5ac710c02e375db85023db18a144034200047f2cca7c4b61311dc2718b845d911be46154c5c1f9c6e5e25dfb18519fec1705d588fdf8167860b27e1cf880c4616b4257309d10580fd0a2190d46d74e3b20c9";
KEYSEC1: con "307702010104204b4d2e92e9bad634c7652f359dd8e4d774016aee5ac710c02e375db85023db18a00a06082a8648ce3d030107a144034200047f2cca7c4b61311dc2718b845d911be46154c5c1f9c6e5e25dfb18519fec1705d588fdf8167860b27e1cf880c4616b4257309d10580fd0a2190d46d74e3b20c9";
# Another P-256 key (openssl ecparam -genkey), not the certificate's
OTHERKEY: con "30770201010420c9dec5918b75bb58d5a8b4164ed854dac216f24cb5f8e8bf5e0ce85ebb7c4990a00a06082a8648ce3d030107a1440342000460cb93b10d13a1a81c717a5d4cb5e777678ea84e4efd4a0e471500267ba911b25d6ebf7c790e18dc69d89356df64cadfe4cf757d116b3b87fb84065c3ecc5b47";
# SHA-256 of the certificate's SubjectPublicKeyInfo
PIN: con "9f80a5421aaa2bc1b5ec475a06b1546cf8984c67c2a38501ddc82d1b5aae5aed";

AES128:		con 16r1301;
AES256:		con 16r1302;
CHACHA:		con 16r1303;
MLKEM768:	con 16r11EC;
X25519:		con 16r001D;
P256:		con 16r0017;

hex(s: string): array of byte
{
	b := array[len s / 2] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte ((hv(s[2*i]) << 4) | hv(s[2*i+1]));
	return b;
}

hv(c: int): int
{
	if(c >= 'a')
		return c - 'a' + 10;
	return c - '0';
}

serverconfig(t: ref T): ref ServerConfig
{
	certs := tls->pemblocks(CERTPEM, "CERTIFICATE");
	if(certs == nil)
		t.fatal("pemblocks found no certificate");
	(key, err) := tls->p256key(hex(KEYPKCS8));
	if(err != nil)
		t.fatal("p256key: " + err);
	return ref ServerConfig(certs, key, "http/1.1" :: nil, 0, nil);
}

clientconfig(): ref Config
{
	c := tls->defaultconfig();
	c.servername = "localhost";
	c.pinspki = hex(PIN);
	return c;
}

# A server on one end of a pipe; its result, and what it read
Result: adt {
	conn:	ref Conn;
	err:	string;
	exc:	string;
};

serve(fd: ref Sys->FD, cfg: ref ServerConfig, rc: chan of ref Result)
{
	r := ref Result;
	{
		(r.conn, r.err) = tls->server(fd, cfg);
	} exception e {
	"*" =>
		r.exc = e;
	}
	rc <-= r;
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

# Client and server over a pipe: (client conn, server conn)
connect(t: ref T, scfg: ref ServerConfig, ccfg: ref Config): (ref Conn, ref Conn)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	rc := chan of ref Result;
	spawn serve(p[1], scfg, rc);
	(cc, cerr) := tls->client(p[0], ccfg);
	tc := chan of int;
	spawn timer(10000, tc);
	r: ref Result;
	alt {
	r = <-rc =>
		;
	<-tc =>
		t.fatal("server did not finish its handshake");
	}
	if(r.exc != nil)
		t.fatal("server raised " + r.exc);
	if(cerr != nil)
		t.fatal(sys->sprint("client: %s (server: %s)", cerr, r.err));
	if(r.err != nil)
		t.fatal("server: " + r.err);
	return (cc, r.conn);
}

readn(c: ref Conn, n: int): array of byte
{
	b := array[n] of byte;
	for(i := 0; i < n; ) {
		m := c.read(b[i:], n - i);
		if(m <= 0)
			return b[0:i];
		i += m;
	}
	return b;
}

pattern(n, seed: int): array of byte
{
	b := array[n] of byte;
	for(i := 0; i < n; i++)
		b[i] = byte (i * 7 + seed + (i >> 8));
	return b;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testKeys(t: ref T)
{
	certs := tls->pemblocks(CERTPEM, "CERTIFICATE");
	t.asserteq(len certs, 1, "one certificate in the PEM");
	t.asserteq(len tls->pemblocks(CERTPEM, "PRIVATE KEY"), 0, "no key block in a certificate's PEM");
	(k8, e8) := tls->p256key(hex(KEYPKCS8));
	t.assertnil(e8, "PKCS #8 key parsed");
	(k1, e1) := tls->p256key(hex(KEYSEC1));
	t.assertnil(e1, "SEC1 key parsed");
	t.assert(k8 != nil && k1 != nil && same(k8, k1), "PKCS #8 and SEC1 give the same scalar");
	t.assertnil(tls->checkserver(ref ServerConfig(certs, k8, nil, 0, nil)), "the key is the certificate's");
	(ko, eo) := tls->p256key(hex(OTHERKEY));
	t.assertnil(eo, "the other key parsed");
	t.assertnotnil(tls->checkserver(ref ServerConfig(certs, ko, nil, 0, nil)), "another key refused for the certificate");
	(nil, eb) := tls->p256key(hex(KEYPKCS8)[0:40]);
	t.assertnotnil(eb, "a cut key refused");
	t.assertnotnil(tls->checkserver(ref ServerConfig(nil, k8, nil, 0, nil)), "no certificate refused");
}

testHandshake(t: ref T)
{
	(cc, sc) := connect(t, serverconfig(t), clientconfig());
	t.asserteq(cc.version, TLS->TLS13, "TLS 1.3");
	t.asserteq(cc.group, MLKEM768, "the hybrid chosen by default");
	t.assertseq(sc.servername, "localhost", "the server has the client's SNI");

	# both ways, past a record (16K) each
	msg := pattern(70000, 1);
	done := chan of int;
	spawn writer(cc, msg, done);
	got := readn(sc, len msg);
	<-done;
	t.assert(same(got, msg), "70000 bytes client to server");
	msg = pattern(50001, 3);
	spawn writer(sc, msg, done);
	got = readn(cc, len msg);
	<-done;
	t.assert(same(got, msg), "50001 bytes server to client");

	sc.close();
	b := array[10] of byte;
	t.asserteq(cc.read(b, len b), 0, "close_notify read as end of file");
}

writer(c: ref Conn, b: array of byte, done: chan of int)
{
	c.write(b, len b);
	done <-= 1;
}

testSuites(t: ref T)
{
	for(s := AES128 :: AES256 :: CHACHA :: nil; s != nil; s = tl s) {
		cfg := clientconfig();
		cfg.suites = hd s :: nil;
		cfg.minver = TLS->TLS13;
		(cc, sc) := connect(t, serverconfig(t), cfg);
		t.asserteq(cc.suite, hd s, sys->sprint("suite %04x agreed", hd s));
		m := pattern(1000, hd s);
		sc.write(m, len m);
		t.assert(same(readn(cc, len m), m), sys->sprint("data under suite %04x", hd s));
	}
}

testPreference(t: ref T)
{
	# the client puts AES-128-GCM first (defaultconfig); a server
	# preferring ChaCha20 gets it, one preferring nothing takes AES
	scfg := serverconfig(t);
	scfg.suites = CHACHA :: AES128 :: nil;
	(cc, nil) := connect(t, scfg, clientconfig());
	t.asserteq(cc.suite, CHACHA, "the server's preference taken");
	scfg.suites = AES256 :: nil;
	(cc, nil) = connect(t, scfg, clientconfig());
	t.asserteq(cc.suite, AES256, "a preference the client offers further down");
	scfg.suites = nil;
	(cc, nil) = connect(t, scfg, clientconfig());
	t.asserteq(cc.suite, AES128, "no preference: the client's first");
	cfg := clientconfig();
	cfg.suites = AES256 :: nil;
	cfg.minver = TLS->TLS13;
	scfg.suites = CHACHA :: nil;
	(cc, nil) = connect(t, scfg, cfg);
	t.asserteq(cc.suite, AES256, "a preference the client does not offer: the client's");

	f := tls->fastsuites();
	t.asserteq(len f, 3, "fastsuites names the three suites");
	s := "";
	for(; f != nil; f = tl f)
		s += sys->sprint(" %04x", hd f);
	t.log("fastest first:" + s);
	t.assert(contains(s, "1301") && contains(s, "1302") && contains(s, "1303"), "each once");
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

testHRR(t: ref T)
{
	# /env/cnsatls makes the client offer SecP384r1MLKEM1024 alone,
	# which this server does not take: refused, saying so
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	rc := chan of ref Result;
	fd := sys->create("/env/cnsatls", Sys->OWRITE, 8r600);
	if(fd == nil)
		t.skip("no /env");
	sys->fprint(fd, "1");
	fd = nil;
	spawn serve(p[1], serverconfig(t), rc);
	(nil, cerr) := tls->client(p[0], clientconfig());
	sys->remove("/env/cnsatls");
	r := <-rc;
	t.assertnotnil(r.err, "a CNSA-only client refused");
	t.assert(cerr != nil, "the client told");
	t.log("server: " + r.err);
}

# A ClientHello as the client sends it
capture(t: ref T): array of byte
{
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	pidc := chan of int;
	spawn hello(p[0], pidc);
	pid := <-pidc;
	hdr := array[5] of byte;
	if(sys->readn(p[1], hdr, 5) != 5)
		t.fatal("no record");
	n := (int hdr[3] << 8) | int hdr[4];
	rec := array[5 + n] of byte;
	rec[0:] = hdr;
	if(sys->readn(p[1], rec[5:], n) != n)
		t.fatal("short record");
	kill(pid);
	return rec;
}

hello(fd: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	tls->client(fd, clientconfig());
}

kill(pid: int)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

seed := 1;
rand(n: int): int
{
	seed = seed * 1103515245 + 12345;
	return ((seed >> 8) & 16r7FFFFF) % n;
}

testMutatedHellos(t: ref T)
{
	ch := capture(t);
	t.log(sys->sprint("ClientHello record of %d bytes", len ch));
	cfg := serverconfig(t);
	ok := 0;
	refused := 0;
	for(i := 0; i < 3000; i++) {
		m := array[len ch] of byte;
		m[0:] = ch;
		case i % 4 {
		0 or 1 =>
			# a few bytes changed, past the record header mostly
			for(k := 1 + rand(4); k > 0; k--)
				m[rand(len m)] = byte rand(256);
		2 =>
			m = m[0:rand(len m)];
		3 =>
			# a length made larger or smaller
			o := 5 + rand(len m - 6);
			m[o] = byte (int m[o] + 1 - 2 * rand(2));
		}
		p := array[2] of ref Sys->FD;
		sys->pipe(p);
		rc := chan of ref Result;
		spawn serve(p[1], cfg, rc);
		sys->write(p[0], m, len m);
		# the server must give up once the client has gone
		spawn drain(p[0]);
		p[0] = nil;
		tc := chan of int;
		spawn timer(5000, tc);
		r: ref Result;
		alt {
		r = <-rc =>
			;
		<-tc =>
			t.fatal(sys->sprint("mutation %d: the server waited for ever", i));
		}
		if(r.exc != nil)
			t.fatal(sys->sprint("mutation %d: the server raised %s", i, r.exc));
		if(r.err != nil)
			refused++;
		else
			ok++;
	}
	t.log(sys->sprint("%d refused, %d not (waiting for a client gone)", refused, ok));
	t.assert(refused > 2000, "most mutations refused");
}

# Read what the server sends until it is done, then close: the server's
# reads then see end of file
drain(fd: ref Sys->FD)
{
	sys->sleep(20);
	fd = nil;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	tls = load TLS TLS->PATH;
	if(tls == nil) {
		sys->fprint(sys->fildes(2), "cannot load tls: %r\n");
		raise "fail:cannot load tls";
	}
	err := tls->init();
	if(err != nil)
		raise "fail:" + err;

	run("Keys", testKeys);
	run("Handshake", testHandshake);
	run("Suites", testSuites);
	run("Preference", testPreference);
	run("CNSAClientRefused", testHRR);
	run("MutatedHellos", testMutatedHellos);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
