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

include "asn1.m";
include "pkcs.m";
include "x509.m";
	x509: X509;

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
	return ref ServerConfig(certs, key, "http/1.1" :: nil, 0, nil, nil, nil, 0, nil);
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
	t.assertnil(tls->checkserver(ref ServerConfig(certs, k8, nil, 0, nil, nil, nil, 0, nil)), "the key is the certificate's");
	(ko, eo) := tls->p256key(hex(OTHERKEY));
	t.assertnil(eo, "the other key parsed");
	t.assertnotnil(tls->checkserver(ref ServerConfig(certs, ko, nil, 0, nil, nil, nil, 0, nil)), "another key refused for the certificate");
	(nil, eb) := tls->p256key(hex(KEYPKCS8)[0:40]);
	t.assertnotnil(eb, "a cut key refused");
	t.assertnotnil(tls->checkserver(ref ServerConfig(nil, k8, nil, 0, nil, nil, nil, 0, nil)), "no certificate refused");
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

# Client certificates (made by openssl for this test, 100 years, all
# P-256): a CA, an intermediate it issued, and another CA; leaves for
# client authentication from the CA (alice-laptop), from the
# intermediate (bob-phone), from the other CA (alice-laptop again), one
# the CA revoked (mallory, in CRL_CA), and one the CA issued for
# server authentication only (extended key usage serverAuth)
C_CA: con "308201993082013fa0030201020214196a2d61f36e65cc8eff505ce9617478dcefd7b5300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e742043413020170d3236313131343132313830385a180f32313236313032313132313830385a30193117301506035504030c0e5465737420436c69656e742043413059301306072a8648ce3d020106082a8648ce3d03010703420004aa880a5ff981acb64602b3a0eea84400f3f58ac0331e332eeea5ed75cb9b4a8a9e9bd902c0d1d492a213f7151255eecf90c30c84ebe2e596494214550b3f0bd6a3633061301d0603551d0e041604146125065e840393ea604ea639682ba297f960e352301f0603551d230418301680146125065e840393ea604ea639682ba297f960e352300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106300a06082a8648ce3d040302034800304502210097c70c69ddf3ed803c7f23e647129f662b35e4028f05ede14be8c88a9d5b07dc02207c5949d3da81027dc18937a631ab4e03dbfb389a91784a72ad9c85df66bd0165";
C_OTHER: con "3082018d30820133a003020102021408cd17f8f955d5591b2c1a1a3f60d6b854990689300a06082a8648ce3d04030230133111300f06035504030c084f746865722043413020170d3236313131343132313830385a180f32313236313032313132313830385a30133111300f06035504030c084f746865722043413059301306072a8648ce3d020106082a8648ce3d03010703420004b16f72a728a21ca51add28f05396c92425e48b0497eb77473e2bd9fa96d892a8f5bd33935738da08032f61bd4cc1e95360ea88254e5c25e2054865444f57b656a3633061301d0603551d0e04160414e79176ad6228a2cb50ac55622102ddb5cf4033aa301f0603551d23041830168014e79176ad6228a2cb50ac55622102ddb5cf4033aa300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106300a06082a8648ce3d0403020348003045022049a4f3e8a06d70f45a47930cee835aa4cd50a6611074412a76d6ef44f3e979410221008c0145d822b3f8a55bb2206d301e4876a5e737fbda12ce2d6ae78a556f02374e";
C_INT: con "3082019d30820142a003020102021418af9f5c7d4db39bd0727e74465834f543b09292300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e742043413020170d3236313131343132313830385a180f32313236313032313132313830385a301c311a301806035504030c115465737420496e7465726d6564696174653059301306072a8648ce3d020106082a8648ce3d03010703420004e7ee18ab84252d3f5f9db7cf54052236513495787e890455f6b9124923ef547184f3a717959d055448b1793847c2bcabf5951fd1617aeeeb5a0980cdf98b7c9ea3633061300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106301d0603551d0e04160414c8754ffedc8b2197ea7a0f788fdbbf201c6b97a2301f0603551d230418301680146125065e840393ea604ea639682ba297f960e352300a06082a8648ce3d0403020349003046022100d24f6c8338f5fdda36f468d03c0f09e7b0d494006ef5a1a1a7a8af2530d42a52022100e347b6f097256c56112c2ede8b6d812bada07a76df9f9c803e3d7482f09a685d";
C_GOOD: con "308201a53082014ca003020102021418af9f5c7d4db39bd0727e74465834f543b09293300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e742043413020170d3236313131343132313830385a180f32313236313032313132313830385a30173115301306035504030c0c616c6963652d6c6170746f703059301306072a8648ce3d020106082a8648ce3d0301070342000446c8aa13fd7d8e28026e0dbba21adad1d73eccc82d10fcc073920200ec981752c7ef0796f128c04d22085139f071e71bfdcb7cb27481393942015ae50e6e323da372307030090603551d1304023000300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070302301d0603551d0e0416041401c409fc60b89d4e3eccd3f34da452c3f057e1ae301f0603551d230418301680146125065e840393ea604ea639682ba297f960e352300a06082a8648ce3d040302034700304402202a40b50bc594180ca1417668682426f2403d5d3e06aa834c8b1cef9c97697a3a02203d2dd30c043df7b7624711f0062ebc594beda207993b8c5f6a5b37f419fc40eb";
C_SRVONLY: con "308201a230820148a003020102021418af9f5c7d4db39bd0727e74465834f543b09294300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e742043413020170d3236313131343132313830385a180f32313236313032313132313830385a30133111300f06035504030c08612d7365727665723059301306072a8648ce3d020106082a8648ce3d030107034200045d19ec2de7e6bcd4a9f25caedb323b567443fcf24313027ca894bbe3f76f62a6f7b7e0ed98539954638a70a52ff27d0fe2d14dec8da5116a9fa450f4daa43b8ba372307030090603551d1304023000300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070301301d0603551d0e04160414bd5977e8d18ce12917e27c0baa2dc7f4ff325906301f0603551d230418301680146125065e840393ea604ea639682ba297f960e352300a06082a8648ce3d0403020348003045022100e41b6208248c4125a468b6e2b6f912686d7c4d72546ec679168c3ac5c6ec0633022048f0b492d2acb0ecb07cea68624a82172f9b392027678781816698fefbeed313";
C_VIAINT: con "308201a63082014ca00302010202142d7ffd1c76bf2e662dfaed8c82690c59d3c3d2f3300a06082a8648ce3d040302301c311a301806035504030c115465737420496e7465726d6564696174653020170d3236313131343132313830385a180f32313236313032313132313830385a30143112301006035504030c09626f622d70686f6e653059301306072a8648ce3d020106082a8648ce3d03010703420004113706c92660c8f2993e72de96bd7d604a6456e356aa9752428e9de337a2995d355cb0b7bfc6fcda71a002e3186ccb183d769d720337b11c91b1610d64ac90c2a372307030090603551d1304023000300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070302301d0603551d0e04160414852536cdff70c14a9960c334907e09d51a0b7d2c301f0603551d23041830168014c8754ffedc8b2197ea7a0f788fdbbf201c6b97a2300a06082a8648ce3d0403020348003045022100b4199bc468be79a17fe02335a2dd38dfebd583a9381f5fab77ae8b8141f4b6220220162fadcb4257a10c63d20947fc5c7dd80d53fe29f7695b1ec26511cbdc16bb3a";
C_REVOKED: con "308201a130820147a003020102021418af9f5c7d4db39bd0727e74465834f543b09295300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e742043413020170d3236313131343132313830395a180f32313236313032313132313830395a30123110300e06035504030c076d616c6c6f72793059301306072a8648ce3d020106082a8648ce3d03010703420004fff161eb363f613c1f080b96e923ba2e764887bf93e28bf9a1482e2ba2a87834ee572bcdcb290d6f2311f61010844d378447136bfefd3e62d59636356b608800a372307030090603551d1304023000300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070302301d0603551d0e0416041403dd64eff268a2239834bc21ae0d83d50623bcb4301f0603551d230418301680146125065e840393ea604ea639682ba297f960e352300a06082a8648ce3d040302034800304502206b3ddb67d5ccf23c42e9394af0f4945a1c7936ca48f2db4d87fb19d63427d002022100a9046d89a86a2f438afded6c1912f17c12ece819b656069c99095604b207279d";
C_OTHERGOOD: con "308201a030820146a00302010202140f3c69e50c97a2adcde187e2b16b773a2ec70c00300a06082a8648ce3d04030230133111300f06035504030c084f746865722043413020170d3236313131343132313830395a180f32313236313032313132313830395a30173115301306035504030c0c616c6963652d6c6170746f703059301306072a8648ce3d020106082a8648ce3d0301070342000446c8aa13fd7d8e28026e0dbba21adad1d73eccc82d10fcc073920200ec981752c7ef0796f128c04d22085139f071e71bfdcb7cb27481393942015ae50e6e323da372307030090603551d1304023000300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070302301d0603551d0e0416041401c409fc60b89d4e3eccd3f34da452c3f057e1ae301f0603551d23041830168014e79176ad6228a2cb50ac55622102ddb5cf4033aa300a06082a8648ce3d0403020348003045022100bdef6da02656502a9435d1d4f7f4ff99818309b576df37befb8611e6937bf62b02200975cd8882f343440d6288bead77b1f426e1377e3436e19eca4144823306219d";
K_GOOD: con "30770201010420fae7029beb493e7b0ced5ac741ead0941cdd5abdd94ab91b33d725eabff8fba3a00a06082a8648ce3d030107a1440342000446c8aa13fd7d8e28026e0dbba21adad1d73eccc82d10fcc073920200ec981752c7ef0796f128c04d22085139f071e71bfdcb7cb27481393942015ae50e6e323d";
K_SRVONLY: con "307702010104205e667e63570eb3b5bb9f135d28af559d9c2213719e4509da6126e1cbb39b8a81a00a06082a8648ce3d030107a144034200045d19ec2de7e6bcd4a9f25caedb323b567443fcf24313027ca894bbe3f76f62a6f7b7e0ed98539954638a70a52ff27d0fe2d14dec8da5116a9fa450f4daa43b8b";
K_REVOKED: con "30770201010420c4b988ff4e7247936a583e4b2b8502d192219721a2324ec5451bd76cd38d8edca00a06082a8648ce3d030107a14403420004fff161eb363f613c1f080b96e923ba2e764887bf93e28bf9a1482e2ba2a87834ee572bcdcb290d6f2311f61010844d378447136bfefd3e62d59636356b608800";
CRL_CA: con "3081de308184020101300a06082a8648ce3d04030230193117301506035504030c0e5465737420436c69656e74204341170d3236313131343132313830395a180f32313236313032313132313830395a30273025021418af9f5c7d4db39bd0727e74465834f543b09295170d3236313131343132313830395aa00f300d300b0603551d14040402021000300a06082a8648ce3d0403020349003046022100ad21730c73f23433549deb3e9932f9736c04c9a803cfe751f8afd47d31a0d0e9022100a0c950738ae8394bc83e53acff3126f851ad2c50af88f2970a056372682cedcf";
CRL_OTHER: con "3081d6307e020101300a06082a8648ce3d04030230133111300f06035504030c084f74686572204341170d3236313131343132313830395a180f32313236313032313132313830395a30273025021418af9f5c7d4db39bd0727e74465834f543b09295170d3236313131343132313830395aa00f300d300b0603551d14040402021001300a06082a8648ce3d04030203480030450220208ad70ff9103a45c78f1f8263845bb43352b3722971ba6ba6a8f53c47eb4ff702210090a875709936706e94bdba25a82797580010fb514b5ae7c4ec4fbf0bb771d2dd";

clientcfg(cert, key: string): ref Config
{
	c := clientconfig();
	c.suites = AES128 :: nil;
	c.minver = TLS->TLS13;
	if(cert != nil) {
		c.clientcert = hex(cert);
		(k, err) := tls->p256key(hex(key));
		if(err != nil)
			raise "fail:key: " + err;
		c.clientkey = k;
	}
	return c;
}

# A handshake that should be refused: (server's error, client's error)
refusedhs(scfg: ref ServerConfig, ccfg: ref Config): (string, string)
{
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	rc := chan of ref Result;
	spawn serve(p[1], scfg, rc);
	(cc, cerr) := tls->client(p[0], ccfg);
	r := <-rc;
	# a TLS 1.3 client finishes its side of the handshake before the
	# server judges its certificate: it hears the alert on its first read
	if(cerr == nil && cc != nil) {
		b := array[16] of byte;
		if(cc.read(b, len b) > 0)
			cerr = nil;
		else
			cerr = "refused on its first read";
	}
	p[0] = nil;
	if(r.exc != nil)
		return ("raised " + r.exc, cerr);
	return (r.err, cerr);
}

testClientCerts(t: ref T)
{
	roots := hex(C_CA) :: nil;
	scfg := serverconfig(t);
	scfg.clientroots = roots;

	(nil, sc) := connect(t, scfg, clientcfg(C_GOOD, K_GOOD));
	t.assert(sc.peercerts != nil && same(hd sc.peercerts, hex(C_GOOD)), "the client's certificate, verified, on the server's Conn");
	t.assertseq(tls->certcn(hd sc.peercerts), "alice-laptop", "its common name");
	fp := tls->certfingerprint(hd sc.peercerts);
	t.assert(len fp == 7 + 64 && fp[0:7] == "sha256:", "its fingerprint: " + fp);

	(nil, sc) = connect(t, scfg, clientcfg(nil, nil));
	t.assert(sc.peercerts == nil, "asked, not required: a client with none goes on without");

	scfg.clientneed = 1;
	(serr, cerr) := refusedhs(scfg, clientcfg(nil, nil));
	t.assert(contains(serr, "no certificate"), "required: a client with none refused: " + serr);
	t.assertnotnil(cerr, "and the client told");
	scfg.clientneed = 0;

	(serr, nil) = refusedhs(scfg, clientcfg(C_SRVONLY, K_SRVONLY));
	t.assert(contains(serr, "client authentication"), "a certificate for server authentication refused: " + serr);
	(serr, nil) = refusedhs(scfg, clientcfg(C_OTHERGOOD, K_GOOD));
	t.assert(contains(serr, "refused"), "a certificate from another CA refused: " + serr);
	(serr, nil) = refusedhs(scfg, clientcfg(C_GOOD, K_SRVONLY));
	t.assert(contains(serr, "does not verify"), "a certificate with another's key refused (CertificateVerify): " + serr);

	# revocation: the CA's CRL names mallory
	(nil, sc) = connect(t, scfg, clientcfg(C_REVOKED, K_REVOKED));
	t.assert(sc.peercerts != nil, "no CRL given: mallory taken");
	scfg.clientcrls = hex(CRL_CA) :: nil;
	(serr, nil) = refusedhs(scfg, clientcfg(C_REVOKED, K_REVOKED));
	t.assert(contains(serr, "revoked"), "the CA's CRL given: mallory refused: " + serr);
	(nil, sc) = connect(t, scfg, clientcfg(C_GOOD, K_GOOD));
	t.assert(sc.peercerts != nil, "and alice still taken");
	scfg.clientcrls = hex(CRL_OTHER) :: nil;
	(serr, nil) = refusedhs(scfg, clientcfg(C_GOOD, K_GOOD));
	t.assert(contains(serr, "CRL not signed"), "a CRL no root signed: every client refused (the configuration is wrong): " + serr);
	scfg.clientcrls = nil;

	# the clock: 2200 is past every certificate's end, 1970 before its start
	for(l := "7258118400000000" :: "1000000" :: nil; l != nil; l = tl l) {
		f := "/tmp/tls_server_clock." + string sys->pctl(0, nil);
		fd := sys->create(f, Sys->ORDWR, 8r600);
		sys->fprint(fd, "%s", hd l);
		scfg.clock = fd;
		(serr, nil) = refusedhs(scfg, clientcfg(C_GOOD, K_GOOD));
		t.assert(contains(serr, "expired or not yet valid"), "the clock at " + hd l + " us: refused: " + serr);
		sys->remove(f);
	}
	scfg.clock = nil;

	# chains, through x509 itself (this client sends one certificate)
	(ok, err) := x509->verify_certchain_roots(hex(C_VIAINT) :: hex(C_INT) :: nil, roots, nil, 1800000000);
	t.assert(ok, "a leaf with its intermediate, to the root: " + err);
	(ok, err) = x509->verify_certchain_roots(hex(C_VIAINT) :: nil, roots, nil, 1800000000);
	t.assert(!ok, "without its intermediate refused: " + err);
	(ok, err) = x509->verify_certchain_roots(hex(C_GOOD) :: nil, hex(C_OTHER) :: nil, nil, 1800000000);
	t.assert(!ok, "a root that did not issue it refused: " + err);
	(ok, err) = x509->verify_certchain_roots(hex(C_GOOD) :: nil, nil, nil, 1800000000);
	t.assert(!ok, "no roots: refused: " + err);
	(ok, err) = x509->verify_certchain_roots(hex(C_GOOD) :: nil, roots, nil, 1800000000);
	t.assert(ok, "the same leaf to its root: " + err);
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
	x509 = load X509 X509->PATH;
	if(x509 == nil || x509->init() != nil)
		raise "fail:cannot load x509";

	run("Keys", testKeys);
	run("Handshake", testHandshake);
	run("Suites", testSuites);
	run("Preference", testPreference);
	run("ClientCerts", testClientCerts);
	run("CNSAClientRefused", testHRR);
	run("MutatedHellos", testMutatedHellos);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
