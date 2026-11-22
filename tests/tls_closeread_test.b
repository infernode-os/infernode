implement TLSCloseReadTest;

#
# A TLS connection closed by one process while another is in a read on
# it (appl/lib/crypt/tls.b: Conn.close against Conn.read), as llmclient
# and webclient do when a request runs out of time: the socket is hung
# up, the connection closed, and the reader, which was waiting for a
# record that will not come, is left to find out.
#
# Close sends its alert through the connection's writing half (its key
# and its sequence number) and takes the state from the Conn; a
# client's read uses the reading half alone (it does not answer a
# KeyUpdate with one of its own, for the sake of a writer in another
# process) and holds the state it began with.  So neither can raise in
# the other, and the reader ends as soon as the socket does.  This runs
# it: a server on the loopback finishes a handshake, sends one record
# and says no more; the client's reader is hung up on and closed at
# moments spread over its read, 60 times, and each time comes back with
# no bytes and no exception; a close with no hangup ends the read when
# the server goes.
#
# The key is tls_server_test.b's test key, as hex DER (a PEM private key
# in a package refuses the release).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tls.m";
	tls: TLS;
	Conn, Config, ServerConfig: import tls;

include "testing.m";
	testing: Testing;
	T: import testing;

TLSCloseReadTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tls_closeread_test.b";

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
KEYPKCS8: con "308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b02010104204b4d2e92e9bad634c7652f359dd8e4d774016aee5ac710c02e375db85023db18a144034200047f2cca7c4b61311dc2718b845d911be46154c5c1f9c6e5e25dfb18519fec1705d588fdf8167860b27e1cf880c4616b4257309d10580fd0a2190d46d74e3b20c9";
PIN: con "9f80a5421aaa2bc1b5ec475a06b1546cf8984c67c2a38501ddc82d1b5aae5aed";

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

scfg: ref ServerConfig;

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# Answer one client: a handshake, one record, and then nothing until
# told to go (hold) or for stay ms.
serve(c: Sys->Connection, stay: int, gone: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		gone <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		gone <-= -1;
		return;
	}
	{
		(sc, err) := tls->server(fd, scfg);
		if(err == nil) {
			hello := array of byte "hello";
			sc.write(hello, len hello);
			if(stay > 0)
				sys->sleep(stay);
			else {
				buf := array[64] of byte;
				sc.read(buf, len buf);	# until the client has gone
			}
		}
	} exception {
	"*" =>
		;
	}
	fd = nil;
	gone <-= 0;
}

# (bytes read, exception): the read the reader is left in
reader(c: ref Conn, rc: chan of (int, string))
{
	buf := array[1024] of byte;
	{
		n := c.read(buf, len buf);
		rc <-= (n, nil);
	} exception x {
	"*" =>
		rc <-= (-99, x);
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# A client with the server's one record read and a reader waiting for
# the next; closed after wait ms, with a hangup first if hang is set.
# What the reader came back with, or (-98, why) if it did not.
round(t: ref T, wait, hang, stay: int): (int, string)
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(ac.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	gone := chan[1] of int;
	spawn serve(ac, stay, gone);
	(dok, dc) := sys->dial("tcp!127.0.0.1!" + port, nil);
	if(dok < 0)
		t.fatal(sys->sprint("dial: %r"));
	cfg := tls->defaultconfig();
	cfg.servername = "localhost";
	cfg.pinspki = hex(PIN);
	(conn, err) := tls->client(dc.dfd, cfg);
	if(err != nil)
		t.fatal("handshake: " + err);
	buf := array[16] of byte;
	n := conn.read(buf, len buf);
	if(n != 5)
		t.fatal(sys->sprint("the server's record: %d bytes", n));
	rc := chan[1] of (int, string);
	spawn reader(conn, rc);
	if(wait > 0)
		sys->sleep(wait);
	if(hang)
		sys->fprint(dc.cfd, "hangup");
	cerr: string;
	{
		conn.close();
	} exception x {
	"*" =>
		cerr = "close raised " + x;
	}
	tmo := chan[1] of int;
	spawn timer(tmo, 10000);
	got := -98;
	why := "the reader did not come back in 10 s";
	alt {
	(got, why) = <-rc =>
		;
	<-tmo =>
		;
	}
	if(cerr != nil)
		why = cerr;
	dc.dfd = nil;
	dc.cfd = nil;
	<-gone;
	return (got, why);
}

testHangupAndClose(t: ref T)
{
	bad := 0;
	for(i := 0; i < 60 && bad < 3; i++) {
		(n, why) := round(t, i % 4, 1, 0);
		if(why != nil || n > 0) {
			bad++;
			t.error(sys->sprint("round %d: the reader had %d: %s", i, n, why));
		}
	}
	t.asserteq(bad, 0, "readers that did not end with no bytes and no exception");
}

testCloseAlone(t: ref T)
{
	# no hangup: the read ends when the server does, 300 ms on
	t0 := sys->millisec();
	(n, why) := round(t, 5, 0, 300);
	t.assert(why == nil && n <= 0, sys->sprint("the reader had %d: %s", n, why));
	t.assert(sys->millisec() - t0 < 8000, "in time");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	tls = load TLS TLS->PATH;
	if(tls == nil) {
		sys->fprint(sys->fildes(2), "cannot load tls: %r\n");
		raise "fail:cannot load tls";
	}
	if((err := tls->init()) != nil) {
		sys->fprint(sys->fildes(2), "tls init: %s\n", err);
		raise "fail:tls init";
	}
	certs := tls->pemblocks(CERTPEM, "CERTIFICATE");
	(key, kerr) := tls->p256key(hex(KEYPKCS8));
	if(certs == nil || kerr != nil) {
		sys->fprint(sys->fildes(2), "the test's certificate: %s\n", kerr);
		raise "fail:certificate";
	}
	scfg = ref ServerConfig(certs, key, nil, 0, nil, nil, nil, 0, nil);

	run("HangupAndClose", testHangupAndClose);
	run("CloseAlone", testCloseAlone);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
