implement TcpTest;

#
# TCP/IP stack tests
#
# Two classes of test:
#   - Loopback (always runs where any IP stack exists): announce/listen/dial/
#     write/read against 127.0.0.1, fully self-contained. This is the
#     authoritative "the TCP stack works" assertion.
#   - Outbound Internet (opt-in): dial public hosts. These SKIP cleanly when
#     the host is offline. Every outbound dial is bounded by a timeout so the
#     suite never hangs on a network-isolated box (see INFR-262).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

TcpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

# Source file path for clickable error addresses
SRCFILE: con "/tests/tcp_test.b";

# How long to wait for an outbound dial before giving up and skipping.
DIALMS: con 3000;

# Helper to run a test and track results
run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;	# already marked as failed
	"fail:skip" =>
		;	# already marked as skipped
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ── bounded dial ──────────────────────────────────────────────────────────
# sys->dial blocks in the host connect() until the kernel's SYN timeout, which
# on an offline host is tens of seconds -- long enough to look like a hang and
# stall the whole runner. Bound it: dial in a child proc, race it against a
# timer, and report a timeout to the caller so the test can skip.

Dialres: adt {
	ok:	int;
	c:	Sys->Connection;
};

dialer(addr: string, ch: chan of ref Dialres)
{
	r := ref Dialres;
	(r.ok, r.c) = sys->dial(addr, nil);
	ch <-= r;
}

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# returns (ok, connection, timedout). timedout=1 means the dial did not
# complete within DIALMS (treat as "network unavailable", skip).
dialTimeout(addr: string, ms: int): (int, Sys->Connection, int)
{
	dc := chan of ref Dialres;
	tc := chan of int;
	spawn dialer(addr, dc);
	spawn timer(tc, ms);
	alt {
	r := <-dc =>
		return (r.ok, r.c, 0);
	<-tc =>
		return (-1, Sys->Connection(nil, nil, nil), 1);
	}
}

# ── loopback (self-contained, always runs with any IP stack) ────────────────
acceptor(ac: Sys->Connection, res: chan of string)
{
	(lok, nc) := sys->listen(ac);
	if(lok < 0){
		res <-= sys->sprint("listen: %r");
		return;
	}
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		res <-= sys->sprint("accept open data: %r");
		return;
	}
	buf := array[64] of byte;
	n := sys->read(dfd, buf, len buf);	# read request, echo it back
	if(n > 0)
		sys->write(dfd, buf, n);
	res <-= nil;
}

testLoopback(t: ref T)
{
	addr := "tcp!127.0.0.1!18799";
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		# no IP stack at all on this host -> skip, do not fail
		t.skip(sys->sprint("no IP stack (announce failed): %r"));
		return;
	}

	res := chan of string;
	spawn acceptor(ac, res);

	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		t.fatal(sys->sprint("loopback dial failed: %r"));
		return;
	}

	msg := array of byte "ping-over-loopback";
	if(sys->write(dc.dfd, msg, len msg) != len msg){
		t.fatal(sys->sprint("loopback write failed: %r"));
		return;
	}

	buf := array[64] of byte;
	n := sys->read(dc.dfd, buf, len buf);
	if(n < 0){
		t.fatal(sys->sprint("loopback read failed: %r"));
		return;
	}
	t.asserteq(n, len msg, "loopback: echoed byte count matches");
	t.assertseq(string buf[0:n], string msg, "loopback TCP echo round-trips");

	if((e := <-res) != nil)
		t.error("acceptor: " + e);
}

# ── outbound Internet (opt-in; skip cleanly when offline) ───────────────────
testTcpDialIp(t: ref T)
{
	(ok, c, tout) := dialTimeout("tcp!8.8.8.8!53", DIALMS);
	if(tout){ t.skip("dial timed out (offline)"); return; }
	if(ok < 0){ t.skip(sys->sprint("network unavailable: %r")); return; }
	t.assert(c.dfd != nil, "data fd should be valid");
	t.log(sys->sprint("connected to 8.8.8.8:53, fd=%d", c.dfd.fd));
}

testTcpDialHostname(t: ref T)
{
	(ok, c, tout) := dialTimeout("tcp!google.com!80", DIALMS);
	if(tout){ t.skip("dial timed out (offline)"); return; }
	if(ok < 0){ t.skip(sys->sprint("network unavailable or DNS failed: %r")); return; }
	t.assert(c.dfd != nil, "data fd should be valid");
	t.log("connected to google.com:80");
}

testTcpWrite(t: ref T)
{
	(ok, c, tout) := dialTimeout("tcp!8.8.8.8!53", DIALMS);
	if(tout){ t.skip("dial timed out (offline)"); return; }
	if(ok < 0){ t.skip(sys->sprint("network unavailable: %r")); return; }
	buf := array[1] of byte;
	buf[0] = byte 0;
	n := sys->write(c.dfd, buf, 1);
	t.asserteq(n, 1, "write should return 1 byte written");
}

testHttpRequest(t: ref T)
{
	(ok, c, tout) := dialTimeout("tcp!google.com!80", DIALMS);
	if(tout){ t.skip("dial timed out (offline)"); return; }
	if(ok < 0){ t.skip(sys->sprint("network unavailable: %r")); return; }

	request := "GET / HTTP/1.0\r\nHost: google.com\r\n\r\n";
	buf := array of byte request;
	n := sys->write(c.dfd, buf, len buf);
	if(n < 0){
		t.fatal(sys->sprint("write failed: %r"));
		return;
	}
	t.assert(n > 0, "write should succeed");
	t.log(sys->sprint("sent %d bytes", n));

	rbuf := array[512] of byte;
	n = sys->read(c.dfd, rbuf, len rbuf);
	if(n < 0){
		t.fatal(sys->sprint("read failed: %r"));
		return;
	}
	t.assert(n > 0, "should receive response");
	t.log(sys->sprint("received %d bytes", n));

	response := string rbuf[0:n];
	if(len response >= 4 && response[0:4] == "HTTP")
		t.log("response is HTTP");
	else
		t.error("response does not start with HTTP");
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

	# Check for verbose flag
	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Always-on, self-contained assertion first.
	run("Loopback", testLoopback);

	# Opt-in outbound tests; each skips (does not hang) when offline.
	run("TcpDialIp", testTcpDialIp);
	run("TcpDialHostname", testTcpDialHostname);
	run("TcpWrite", testTcpWrite);
	run("HttpRequest", testHttpRequest);

	# Print summary
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
