implement WebclientDeadlineTest;

#
# webclient->requestbounded: a request with a deadline and a limit on
# the body it keeps.  A caller with thirty seconds for a fetch (the
# agent's fetch tools) timed it with a timer of its own and walked
# away, and the request went on behind it: its process in its read, its
# connection open, its buffer as large as the header had said.  The
# request now keeps the time: at the deadline it answers "request timed
# out", its connection is hung up, and its process is gone.
#
# Loopback servers written here say nothing, promise 64 MB and send
# none of it, or send a byte now and then for ever.  After the deadline
# the server sees its connection closed, no process is left, and the
# heap is where it was.  A body longer than the limit is cut there and
# said to be.
#
# That was requestbounded alone: request, requestjar, requesttypes, get
# and post had no deadline at all, and a server that said nothing, or
# "100 Continue" for ever, kept their caller for ever (a page's fetch
# in webfs, git, stripe); tlsdial waited as long for a TLS handshake
# (imap, smtp).  They have the module's limits now (setdeadline: the
# whole exchange, and the longest with no byte moving), set short here,
# and end the same way: an answer, the connection hung up, nothing left.
# Interim responses are counted.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "webclient.m";
	webclient: Webclient;
	Jar: import webclient;

WebclientDeadlineTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/webclient_deadline_test.b";

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

HUGE: con 64*1024*1024;
MB: con 1024*1024;
DEADLINE: con 1000;	# ms the requests here are given
Etimeout: con "request timed out";

announce(t: ref T): (Sys->Connection, string)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	if(port == "")
		t.fatal("no local port: " + readfile(c.dir + "/local"));
	return (c, "http://127.0.0.1:" + port + "/");
}

# Take one connection, read its request, answer as mode says, and then
# wait for the client to go: done gets the milliseconds from the request
# to the connection's end (-1 if it never came).
serve(c: Sys->Connection, mode: string, n: int, done: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		done <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		done <-= -1;
		return;
	}
	req := "";
	buf := array[4096] of byte;
	while(!hasend(req)) {
		k := sys->read(fd, buf, len buf);
		if(k <= 0)
			break;
		req += string buf[0:k];
	}
	t0 := sys->millisec();
	case mode {
	"silent" =>
		;
	"continues" =>
		# 100 Continue, for as long as the client will have it
		{
			for(i := 0; i < 400; i++) {
				b := array of byte "HTTP/1.1 100 Continue\r\n\r\n";
				if(sys->write(fd, b, len b) != len b)
					break;
				sys->sleep(20);
			}
		} exception {
		"*" =>
			;
		}
		fd = nil;
		done <-= sys->millisec() - t0;
		return;
	"continued" =>
		# two interim responses and then the answer
		say(fd, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\n" +
			"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
		fd = nil;
		done <-= 0;
		return;
	"promise" =>
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", HUGE));
	"chunkpromise" =>
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n", HUGE));
	"drip" =>
		# a byte every 50 ms, until the client will have no more
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n", MB));
		one := array[1] of {byte 'x'};
		{
			for(i := 0; i < 400; i++) {
				if(sys->write(fd, one, 1) != 1)
					break;
				sys->sleep(50);
			}
		} exception {
		"*" =>
			;
		}
		fd = nil;
		done <-= sys->millisec() - t0;
		return;
	"length" =>
		say(fd, sys->sprint("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", n));
		sys->write(fd, array[n] of {* => byte 'b'}, n);
		fd = nil;
		done <-= 0;
		return;
	"chunked" =>
		say(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
		say(fd, sys->sprint("%x\r\n", n));
		{
			sys->write(fd, array[n] of {* => byte 'b'}, n);
			say(fd, "\r\n0\r\n\r\n");
		} exception {
		"*" =>
			;	# the client had what it wanted and went
		}
		fd = nil;
		done <-= 0;
		return;
	}
	# the client's end of it: reads that end when it hangs up
	while(sys->read(fd, buf, len buf) > 0)
		;
	fd = nil;
	done <-= sys->millisec() - t0;
}

say(fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	sys->write(fd, b, len b);
}

hasend(s: string): int
{
	for(i := 0; i + 3 < len s; i++)
		if(s[i:i+4] == "\r\n\r\n")
			return 1;
	return 0;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

heapsize(): int
{
	(nil, lines) := sys->tokenize(readfile("/dev/memory"), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " \t");
		if(n >= 8 && hd tl tl tl tl tl tl tl f == "heap")
			return int hd f;
	}
	return -1;
}

watchheap(stop: chan of int, most: chan of int)
{
	m := heapsize();
	for(;;) {
		alt {
		<-stop =>
			most <-= m;
			return;
		* =>
			;
		}
		h := heapsize();
		if(h > m)
			m = h;
		sys->sleep(10);
	}
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

# The request made by one of the module's ways of making one.  The
# ways with no deadline of their own have the module's, set by the
# caller of this.
call(how, url: string): (ref Webclient->Response, string)
{
	case how {
	"request" =>
		return webclient->request("GET", url, nil, nil);
	"get" =>
		return webclient->get(url);
	"post" =>
		return webclient->post(url, "text/plain", array of byte "x");
	"jar" =>
		return webclient->requestjar("GET", url, nil, nil, Jar.new());
	"types" =>
		return webclient->requesttypes("GET", url, nil, nil, nil, "text/" :: nil);
	}
	return webclient->requestbounded("GET", url, nil, nil, 0, DEADLINE, 0);
}

caller(how, url: string, res: chan of (ref Webclient->Response, string))
{
	res <-= call(how, url);
}

# call, given up on after ms (a request that never returns must not be
# this test's end too)
callwithin(t: ref T, how, url: string, ms: int): (ref Webclient->Response, string)
{
	res := chan[1] of (ref Webclient->Response, string);
	tmo := chan[1] of int;
	s := ref Stop(0);
	spawn caller(how, url, res);
	spawn ctimer(tmo, ms, s);
	alt {
	(r, e) := <-res =>
		s.now = 1;
		sys->sleep(120);	# the timer, gone before processes are counted
		return (r, e);
	<-tmo =>
		t.fatal(sys->sprint("%s: not returned after %d ms", how, ms));
	}
	return (nil, nil);
}

# a timer that can be told it is not wanted
Stop: adt {
	now:	int;
};

ctimer(c: chan of int, ms: int, s: ref Stop)
{
	for(t := 0; t < ms && !s.now; t += 50)
		sys->sleep(50);
	c <-= 1;
}

# A request the server never finishes answering: it is over at the
# deadline, the server's connection ends then, no process is left and
# the heap never held what the header promised.
gaveup(t: ref T, mode: string)
{
	gaveupby(t, mode, "bounded");
}

gaveupby(t: ref T, mode, how: string)
{
	(c, url) := announce(t);
	procs := nprocs();
	done := chan[1] of int;
	spawn serve(c, mode, 0, done);
	before := heapsize();
	stop := chan of int;
	most := chan of int;
	spawn watchheap(stop, most);
	t0 := sys->millisec();
	r: ref Webclient->Response;
	err: string;
	if(how == "bounded")
		(r, err) = call(how, url);
	else {
		mode = how + ", " + mode;
		(r, err) = callwithin(t, how, url, DEADLINE + 6000);
	}
	took := sys->millisec() - t0;
	if(how != "bounded")
		took -= 120;
	stop <-= 1;
	grew := <-most - before;
	t.assert(r == nil, mode + ": no response");
	t.assertseq(err, Etimeout, mode + ": the error");
	t.assert(took >= DEADLINE - 50 && took < DEADLINE + 4000, sys->sprint("%s: answered after %d ms (the deadline is %d)", mode, took, DEADLINE));
	# the server is told: its connection ends
	ended := -1;
	tmo := chan[1] of int;
	spawn timer(tmo, 5000);
	alt {
	ended = <-done =>
		;
	<-tmo =>
		;
	}
	t.assert(ended >= 0, mode + ": the connection was not hung up within 5 s of the deadline");
	if(ended >= 0)
		t.assert(ended < DEADLINE + 4000, sys->sprint("%s: the connection ended %d ms after the request", mode, ended));
	left := settle(procs + 1, 3000);	# (the timer above may still sleep)
	t.assert(left <= procs + 1, sys->sprint("%s: %d processes left where there were %d", mode, left, procs));
	if(before >= 0)
		t.assert(grew < 8*MB, sys->sprint("%s: the heap grew by %d bytes", mode, grew));
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testSilent(t: ref T)
{
	gaveup(t, "silent");
}

testPromised(t: ref T)
{
	gaveup(t, "promise");
}

testChunkPromised(t: ref T)
{
	gaveup(t, "chunkpromise");
}

testDrip(t: ref T)
{
	gaveup(t, "drip");
}

# Three in a row leave nothing behind: what three fetch-tool calls of a
# stalled 64 MB response pinned was 201 MB and three processes.
testRepeated(t: ref T)
{
	procs := nprocs();
	before := heapsize();
	for(i := 0; i < 3; i++) {
		(c, url) := announce(t);
		done := chan[1] of int;
		spawn serve(c, "promise", 0, done);
		(nil, err) := webclient->requestbounded("GET", url, nil, nil, 0, 300, 0);
		t.assertseq(err, Etimeout, "the error");
		c.dfd = nil;
		c.cfd = nil;
	}
	left := settle(procs, 5000);
	t.assert(left <= procs, sys->sprint("%d processes left where there were %d", left, procs));
	if(before >= 0)
		t.assert(heapsize() - before < 2*MB, sys->sprint("%d bytes of heap kept", heapsize() - before));
}

limited(t: ref T, mode: string, n, max, wantlen, wanttrunc: int)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, mode, n, done);
	(r, err) := webclient->requestbounded("GET", url, nil, nil, 0, 10000, max);
	<-done;
	what := sys->sprint("%s, %d bytes, limit %d", mode, n, max);
	t.assert(err == nil && r != nil, what + ": request: " + err);
	if(r == nil)
		return;
	t.asserteq(len r.body, wantlen, what + ": bytes kept");
	t.asserteq(r.truncated, wanttrunc, what + ": said to be cut");
}

# No more than the limit is kept, and the response says when it was more.
testLimit(t: ref T)
{
	limited(t, "length", 300000, 100000, 100000, 1);
	limited(t, "length", 100000, 100000, 100000, 0);
	limited(t, "length", 50000, 100000, 50000, 0);
	limited(t, "chunked", 300000, 100000, 100000, 1);
	limited(t, "chunked", 50000, 100000, 50000, 0);
	limited(t, "length", 300000, 0, 300000, 0);	# no limit asked for
}

# The ways of making a request that take no deadline have the
# module's: each is over then, with nothing left behind.
testUnbounded(t: ref T)
{
	webclient->setdeadline(DEADLINE, 0);
	hows := array[] of {"request", "get", "post", "jar", "types"};
	for(i := 0; i < len hows; i++)
		gaveupby(t, "silent", hows[i]);
	gaveupby(t, "promise", "request");
	webclient->setdeadline(Webclient->DEADLINE, Webclient->STALL);
}

# A server that says nothing is given up on when nothing has moved for
# the stall time; one whose bytes keep coming has until the deadline.
testStall(t: ref T)
{
	webclient->setdeadline(3000, 700);
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "silent", 0, done);
	t0 := sys->millisec();
	(r, err) := callwithin(t, "request", url, 8000);
	took := sys->millisec() - t0;
	t.assert(r == nil && err == Etimeout, "a silent server: " + err);
	t.assert(took >= 600 && took < 2500, sys->sprint("given up on after %d ms (nothing moving for 700; the deadline is 3000)", took));
	<-done;

	(c, url) = announce(t);
	spawn serve(c, "drip", 0, done);
	t0 = sys->millisec();
	(r, err) = callwithin(t, "request", url, 9000);
	took = sys->millisec() - t0;
	t.assert(r == nil && err == Etimeout, "a server sending a byte every 50 ms: " + err);
	t.assert(took >= 2900 && took < 7000, sys->sprint("given up on after %d ms (the deadline is 3000)", took));
	<-done;
	webclient->setdeadline(Webclient->DEADLINE, Webclient->STALL);
}

# Interim responses: a couple before the answer are passed over; a
# server sending them for ever is refused after a few, not listened to.
testInterim(t: ref T)
{
	webclient->setdeadline(5000, 0);
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "continued", 0, done);
	(r, err) := callwithin(t, "request", url, 8000);
	t.assert(r != nil && err == nil && string r.body == "ok", "100, 103, then 200: " + err);
	<-done;

	(c, url) = announce(t);
	spawn serve(c, "continues", 0, done);
	t0 := sys->millisec();
	(r, err) = callwithin(t, "request", url, 8000);
	took := sys->millisec() - t0;
	t.assert(r == nil && contains(err, "interim"), "100 Continue for ever: " + err);
	t.assert(took < 2000, sys->sprint("refused after %d ms", took));
	<-done;
	webclient->setdeadline(Webclient->DEADLINE, Webclient->STALL);
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

dialer(addr: string, res: chan of (ref Sys->FD, string))
{
	res <-= webclient->tlsdial(addr, "localhost");
}

# tlsdial to a server that takes the connection and never speaks TLS:
# an error when the handshake's time is up, the connection hung up, no
# process left.
testHandshake(t: ref T)
{
	webclient->setdeadline(0, 800);
	(c, url) := announce(t);
	addr := "tcp!" + url[len "http://":len url - 1];
	for(i := 0; i < len addr; i++)
		if(addr[i] == ':')
			addr[i] = '!';
	procs := nprocs();
	done := chan[1] of int;
	spawn hold(c, done);
	res := chan[1] of (ref Sys->FD, string);
	tmo := chan[1] of int;
	s := ref Stop(0);
	spawn dialer(addr, res);
	spawn ctimer(tmo, 6000, s);
	t0 := sys->millisec();
	fd: ref Sys->FD;
	err := "not returned after 6 s";
	alt {
	(fd, err) = <-res =>
		;
	<-tmo =>
		;
	}
	took := sys->millisec() - t0;
	s.now = 1;
	t.assert(fd == nil && contains(err, "timed out"), "tlsdial: " + err);
	t.assert(took >= 700 && took < 4000, sys->sprint("answered after %d ms (the handshake has 800)", took));
	ended := -1;
	tmo2 := chan[1] of int;
	s2 := ref Stop(0);
	spawn ctimer(tmo2, 4000, s2);
	alt {
	ended = <-done =>
		;
	<-tmo2 =>
		;
	}
	s2.now = 1;
	t.assert(ended >= 0, "the connection was not hung up within 4 s of the deadline");
	left := settle(procs, 3000);
	t.assert(left <= procs, sys->sprint("%d processes left where there were %d", left, procs));
	webclient->setdeadline(Webclient->DEADLINE, Webclient->STALL);
}

# take a connection and say nothing until the client has gone
hold(c: Sys->Connection, done: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0) {
		done <-= -1;
		return;
	}
	fd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(fd == nil) {
		done <-= -1;
		return;
	}
	t0 := sys->millisec();
	buf := array[4096] of byte;
	while(sys->read(fd, buf, len buf) > 0)
		;
	done <-= sys->millisec() - t0;
}

# With no deadline asked for the request is made as before.
testNoDeadline(t: ref T)
{
	(c, url) := announce(t);
	done := chan[1] of int;
	spawn serve(c, "length", 1234, done);
	(r, err) := webclient->requestbounded("GET", url, nil, nil, 0, 0, 0);
	<-done;
	t.assert(err == nil && r != nil, "request: " + err);
	if(r != nil)
		t.asserteq(len r.body, 1234, "its body");
}

# A public request still refuses the loopback, deadline or not.
testPublicStillRefuses(t: ref T)
{
	(nil, url) := announce(t);
	(r, err) := webclient->requestbounded("GET", url, nil, nil, 1, 2000, 0);
	t.assert(r == nil && err != nil && err != Etimeout, "refused, not timed out: " + err);
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

	webclient = load Webclient Webclient->PATH;
	if(webclient == nil) {
		sys->fprint(sys->fildes(2), "cannot load webclient: %r\n");
		raise "fail:cannot load webclient";
	}
	if((err := webclient->init()) != nil) {
		sys->fprint(sys->fildes(2), "webclient init: %s\n", err);
		raise "fail:webclient init";
	}

	run("Silent", testSilent);
	run("Promised", testPromised);
	run("ChunkPromised", testChunkPromised);
	run("Drip", testDrip);
	run("Repeated", testRepeated);
	run("Limit", testLimit);
	run("NoDeadline", testNoDeadline);
	run("PublicStillRefuses", testPublicStillRefuses);
	run("Interim", testInterim);
	run("Stall", testStall);
	run("Handshake", testHandshake);
	run("Unbounded", testUnbounded);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
