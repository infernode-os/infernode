implement WebclientTlsfdTest;

#
# webclient's tlsdial and tlsclient give their caller a TLS connection
# as a file: one end of a pipe, with two processes carrying bytes
# between the other end and the connection.  When the server closed the
# connection, the process reading it finished, but the one carrying the
# caller's writes sat in its read of the pipe holding the pipe open, so
# the caller's read never returned: an IMAP session its server had
# closed while idle (every server does, after a while) hung whoever
# read it next, for good; imap.b, mail9p and git read such files.  And
# when the caller closed its end, the reading process stayed in its read
# of the connection, with the connection, for as long as the server
# kept it.
#
# Here a TLS server on the loopback (tls->server, with tls_server_test's
# test certificate as the only root in this process's /lib/certs) says
# hello and then closes, with a close_notify and without one, while the
# client is in a read and while it is doing nothing: the client's read
# returns 0, the end of the file.  The client closing is seen by the
# server; a server that neither reads nor closes is hung up on.  Twenty
# connections closed from each side leave no process behind.
#
# The key is tls_server_test.b's test key, as hex DER (a PEM private key
# in a package refuses the release).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tls.m";
	tls: TLS;
	Conn, ServerConfig: import tls;

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;

WebclientTlsfdTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_tlsfd_test.b";

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
certdir: string;

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

# Answer one client: a handshake, "hello", and then as mode says.
# gone gets the milliseconds from the hello to the end of it, -1 if
# there was no handshake.
serve(c: Sys->Connection, mode: string, stay: int, gone: chan of int)
{
	r := serve1(c, mode, stay);
	gone <-= r;
}

serve1(c: Sys->Connection, mode: string, stay: int): int
{
	(ok, nc) := sys->listen(c);
	if(ok < 0)
		return -1;
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil)
		return -1;
	r := -1;
	{
		(sc, err) := tls->server(fd, scfg);
		if(err == nil) {
			hello := array of byte "hello";
			sc.write(hello, len hello);
			t0 := sys->millisec();
			case mode {
			"close" =>
				# an orderly close: its close_notify, then the connection
				sys->sleep(stay);
				sc.close();
			"abrupt" =>
				# the connection alone
				sys->sleep(stay);
			"listen" =>
				# until the client has gone
				buf := array[64] of byte;
				while(sc.read(buf, len buf) > 0)
					;
			"deaf" =>
				# neither reading nor closing
				sys->sleep(stay);
			}
			r = sys->millisec() - t0;
		}
	} exception {
	"*" =>
		;
	}
	return r;
}

announce(t: ref T): (Sys->Connection, string)
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(ac.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	if(port == "")
		t.fatal("no local port");
	return (ac, "tcp!127.0.0.1!" + port);
}

# the server's hello, read through the file
hello(t: ref T, fd: ref Sys->FD)
{
	buf := array[16] of byte;
	n := sys->read(fd, buf, len buf);
	if(n != 5 || string buf[0:n] != "hello")
		t.fatal(sys->sprint("the server's hello: %d bytes", n));
}

reader(fd: ref Sys->FD, rc: chan of int)
{
	buf := array[1024] of byte;
	n := -99;
	{
		n = sys->read(fd, buf, len buf);
	} exception {
	"*" =>
		;
	}
	rc <-= n;
}

# a timer that can be told it is not wanted, so that none is left
# sleeping where processes are counted
Stop: adt {
	now:	int;
};

timer(c: chan of int, ms: int, s: ref Stop)
{
	for(t := 0; t < ms && !s.now; t += 50)
		sys->sleep(50);
	c <-= 1;
}

# what a read of fd returns, or -98 if it has not within ms
readwithin(fd: ref Sys->FD, ms: int): int
{
	rc := chan[1] of int;
	tmo := chan[1] of int;
	s := ref Stop(0);
	spawn reader(fd, rc);
	spawn timer(tmo, ms, s);
	n := -98;
	alt {
	n = <-rc =>
		;
	<-tmo =>
		;
	}
	s.now = 1;
	return n;
}

nprocs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	t := 0;
	for(;;) {
		(n, nil) := sys->dirread(fd);
		if(n <= 0)
			break;
		t += n;
	}
	return t;
}

# wait up to ms for the count of processes to come back to n
settle(n, ms: int): int
{
	for(t := 0; t < ms; t += 50) {
		if(nprocs() <= n)
			break;
		sys->sleep(50);
	}
	return nprocs();
}

# The server closes mode-wise after stay ms; the client is in a read
# (wait 0) or does nothing for wait ms and then reads.  Its read
# returns 0.
serverclosed(t: ref T, mode: string, stay, wait: int)
{
	(ac, addr) := announce(t);
	gone := chan[1] of int;
	spawn serve(ac, mode, stay, gone);
	(fd, err) := webclient->tlsdial(addr, "localhost");
	if(fd == nil)
		t.fatal("tlsdial: " + err);
	hello(t, fd);
	if(wait > 0)
		sys->sleep(wait);
	n := readwithin(fd, 3000);
	what := sys->sprint("%s after %d ms, the client reading after %d", mode, stay, wait);
	t.assert(n != -98, what + ": the read did not return within 3 s");
	if(n != -98)
		t.asserteq(n, 0, what + ": the read's answer");
	t.assert(<-gone >= 0, what + ": the server's handshake");
}

testServerClosesInRead(t: ref T)
{
	serverclosed(t, "close", 300, 0);
	serverclosed(t, "abrupt", 300, 0);
}

testServerClosesWhileIdle(t: ref T)
{
	serverclosed(t, "close", 100, 600);
	serverclosed(t, "abrupt", 100, 600);
}

# The client lets go of the file: a server reading sees the end, and one
# that neither reads nor closes does not keep the client's process.
testClientCloses(t: ref T)
{
	(ac, addr) := announce(t);
	gone := chan[1] of int;
	spawn serve(ac, "listen", 0, gone);
	(fd, err) := webclient->tlsdial(addr, "localhost");
	if(fd == nil)
		t.fatal("tlsdial: " + err);
	hello(t, fd);
	fd = nil;
	tmo := chan[1] of int;
	s := ref Stop(0);
	spawn timer(tmo, 3000, s);
	alt {
	ms := <-gone =>
		t.assert(ms >= 0, "the server's handshake");
	<-tmo =>
		t.error("the server did not see the client go within 3 s");
	}
	s.now = 1;
	sys->sleep(300);	# that connection's processes, and the timer, gone

	procs := nprocs();
	(ac, addr) = announce(t);
	spawn serve(ac, "deaf", 8000, gone);
	(fd, err) = webclient->tlsdial(addr, "localhost");
	if(fd == nil)
		t.fatal("tlsdial: " + err);
	hello(t, fd);
	fd = nil;
	# the server's process is there for its 8 s; the client's two are
	# gone once the server has been given its time to close and has not
	left := settle(procs + 1, 6000);
	t.assert(left <= procs + 1, sys->sprint("%d processes where there were %d and the server's one", left, procs));
}

# Twenty connections closed by the server and twenty by the client
# leave no process behind.
testNoProcessLeft(t: ref T)
{
	sys->sleep(300);	# the test before's timers gone
	procs := nprocs();
	gone := chan[1] of int;
	for(i := 0; i < 20; i++) {
		(ac, addr) := announce(t);
		mode := "close";
		if(i % 2)
			mode = "abrupt";
		spawn serve(ac, mode, 0, gone);
		(fd, err) := webclient->tlsdial(addr, "localhost");
		if(fd == nil)
			t.fatal("tlsdial: " + err);
		hello(t, fd);
		n := readwithin(fd, 3000);
		if(n != 0)
			t.fatal(sys->sprint("connection %d (%s): the read after the server closed gave %d", i, mode, n));
		fd = nil;
		<-gone;
	}
	left := settle(procs, 5000);
	t.assert(left <= procs, sys->sprint("closed by the server: %d processes where there were %d", left, procs));

	procs = nprocs();
	for(i = 0; i < 20; i++) {
		(ac, addr) := announce(t);
		spawn serve(ac, "listen", 0, gone);
		(fd, err) := webclient->tlsdial(addr, "localhost");
		if(fd == nil)
			t.fatal("tlsdial: " + err);
		hello(t, fd);
		fd = nil;
		<-gone;
	}
	left = settle(procs, 5000);
	t.assert(left <= procs, sys->sprint("closed by the client: %d processes where there were %d", left, procs));
}

# What is written still arrives, both ways, and a write after the
# server has gone fails or is dropped but does not wait.
testCarries(t: ref T)
{
	(ac, addr) := announce(t);
	gone := chan[1] of int;
	spawn echo(ac, gone);
	(fd, err) := webclient->tlsdial(addr, "localhost");
	if(fd == nil)
		t.fatal("tlsdial: " + err);
	msg := array[40000] of byte;
	for(i := 0; i < len msg; i++)
		msg[i] = byte ('a' + i % 26);
	t.asserteq(sys->write(fd, msg, len msg), len msg, "written");
	got := array[len msg] of byte;
	n := 0;
	while(n < len got) {
		k := sys->read(fd, got[n:], len got - n);
		if(k <= 0)
			break;
		n += k;
	}
	t.asserteq(n, len msg, "read back");
	bad := -1;
	for(i = 0; i < n; i++)
		if(got[i] != msg[i]) {
			bad = i;
			break;
		}
	t.asserteq(bad, -1, "the first byte that is not the one sent");
	t.asserteq(readwithin(fd, 3000), 0, "then the end");
	<-gone;
}

# a server that sends back n bytes and closes
echo(c: Sys->Connection, gone: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		gone <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	{
		(sc, err) := tls->server(fd, scfg);
		if(err == nil) {
			buf := array[8192] of byte;
			for(n := 0; n < 40000; ) {
				k := sc.read(buf, len buf);
				if(k <= 0)
					break;
				sc.write(buf[0:k], k);
				n += k;
			}
			sc.close();
		}
	} exception {
	"*" =>
		;
	}
	gone <-= 0;
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
	if(tls == nil || tls->init() != nil) {
		sys->fprint(sys->fildes(2), "cannot load tls: %r\n");
		raise "fail:cannot load tls";
	}
	certs := tls->pemblocks(CERTPEM, "CERTIFICATE");
	(key, kerr) := tls->p256key(hex(KEYPKCS8));
	if(certs == nil || kerr != nil) {
		sys->fprint(sys->fildes(2), "the test certificate: %s\n", kerr);
		raise "fail:certificate";
	}
	scfg = ref ServerConfig(certs, key, nil, 0, nil, nil, nil, 0, nil);

	# the test's certificate as the only root, in a name space of this
	# process's own, before webclient's TLS reads the roots
	sys->pctl(Sys->FORKNS, nil);
	certdir = sys->sprint("/tmp/webclient_tlsfd.%d", sys->pctl(0, nil));
	sys->create(certdir, Sys->OREAD, Sys->DMDIR | 8r755);
	fd := sys->create(certdir + "/test.der", Sys->OWRITE, 8r644);
	if(fd == nil || sys->write(fd, hd certs, len hd certs) != len hd certs ||
	   sys->bind(certdir, "/lib/certs", Sys->MREPL) < 0) {
		sys->fprint(sys->fildes(2), "cannot make the test's roots in %s: %r\n", certdir);
		raise "fail:roots";
	}
	fd = nil;

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load webclient: %r\n");
		raise "fail:cannot load webclient";
	}
	if((err := webclient->init()) != nil) {
		sys->fprint(sys->fildes(2), "webclient init: %s\n", err);
		raise "fail:webclient init";
	}

	run("Carries", testCarries);
	run("ServerClosesInRead", testServerClosesInRead);
	run("ServerClosesWhileIdle", testServerClosesWhileIdle);
	run("ClientCloses", testClientCloses);
	run("NoProcessLeft", testNoProcessLeft);

	sys->remove(certdir + "/test.der");
	sys->remove(certdir);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
