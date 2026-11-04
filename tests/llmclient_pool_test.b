implement LlmclientPoolTest;

#
# llmclient_pool_test - llmclient keeps its connections to an API open
# between requests, and uses one only when that is safe.
#
# Run by tests/host/llmclient_pool_test.sh, against its fake API
# (tests/host/llmclient/fake_llm.py) over TLS the client verifies, the
# test's own CA bound over /lib/certs.  Every reply says which of the
# server's connections carried it, and what the server has counted
# (connections accepted, requests it closed on unanswered, replies it
# cut short), so what is checked is what reached the server:
#
#   - N sequential requests (buffered and streamed, OpenAI and
#     Anthropic, Content-Length and chunked, a GET of the models) use
#     one connection
#   - a kept connection the server closed while idle is replaced, the
#     request answered on a new one, no error
#   - a streamed reply whose terminating chunk comes late is read to it
#     before the connection is used again, and the next reply is whole
#   - a stream cancelled (its process group killed, as llmsrv cancels)
#     does not return its connection
#   - two requests at once are on two connections, both kept after
#   - a request on a kept connection answered with nothing is sent
#     again once on a new one, not again; one on a new connection is
#     not sent again; one answered in part is not sent again
#   - a reply with Connection: close is not followed on its connection
#   - through an HTTP proxy (this test's own, counting CONNECTs): the
#     tunnel is kept, and not used for the host dialled directly
#
# With -b, it times sequential requests instead (the before/after of
# keeping connections), against the fake API's delaying relay.
#
# usage: llmclient_pool_test.dis -p port [-b relayport n] [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "llmclient.m";
	llmclient: Llmclient;
	AskRequest, AskResponse: import llmclient;

include "testing.m";
	testing: Testing;
	T: import testing;

LlmclientPoolTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_pool_test.b";

passed := 0;
failed := 0;
skipped := 0;
port := "";
proxyport := 19790;

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

setenv(name, val: string)
{
	if(val == nil){
		sys->remove("/env/" + name);
		return;
	}
	fd := sys->create("/env/" + name, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", val);
}

clearenv()
{
	for(l := "https_proxy" :: "HTTPS_PROXY" :: "no_proxy" :: "NO_PROXY" :: nil; l != nil; l = tl l)
		setenv(hd l, nil);
}

newreq(model: string, stream: chan of string): ref AskRequest
{
	return ref AskRequest(nil, "hello", model, 0.0, 0, "", 0, "", "", nil, nil, stream);
}

# What the server said of a reply: (conn, conns, slams, midfails), conn -1 if none.
Said: adt {
	conn, conns, slams, midfails: int;
};

said(s: string): ref Said
{
	(nil, w) := sys->tokenize(s, " \n.");
	r := ref Said(-1, -1, -1, -1);
	for(; w != nil && tl w != nil; w = tl w) {
		v := int hd tl w;
		case hd w {
		"conn" => r.conn = v;
		"conns" => r.conns = v;
		"slams" => r.slams = v;
		"midfails" => r.midfails = v;
		}
	}
	return r;
}

url(): string
{
	return "https://127.0.0.1:" + port + "/v1";
}

# askopenai, buffered or streamed; the reply's text.
openai(model: string, stream: int): (string, string)
{
	sc: chan of string;
	if(stream)
		sc = chan[1000] of string;
	(r, err) := llmclient->askopenai(url(), "test-key", newreq(model, sc));
	if(r == nil)
		return (nil, err);
	return (r.response, err);
}

anthropic(model: string, stream: int): (string, string)
{
	sc: chan of string;
	if(stream)
		sc = chan[1000] of string;
	(r, err) := llmclient->askanthropic("test-key", "127.0.0.1:" + port, newreq(model, sc));
	if(r == nil)
		return (nil, err);
	return (r.response, err);
}

# A request that must succeed; what the server said of it.
must(t: ref T, what: string, r: string, err: string): ref Said
{
	if(err != nil)
		t.fatal(what + ": " + err);
	s := said(r);
	if(s.conn < 0)
		t.fatal(what + ": no connection in the reply: " + r);
	t.log(what + ": " + r);
	return s;
}

# A request on a connection the pool is known to hold, to start from.
warm(t: ref T): ref Said
{
	(r, err) := openai("plain", 0);
	return must(t, "warm", r, err);
}

testsequential(t: ref T)
{
	first := warm(t);
	for(i := 0; i < 5; i++){
		(r, err) := openai("plain", 0);
		s := must(t, "plain", r, err);
		t.asserteq(s.conn, first.conn, "buffered request on the same connection");
	}
	cases := array[] of {
		("chunked", 0, 0), ("plain", 1, 0), ("chunked", 1, 0),
		("plain", 0, 1), ("plain", 1, 1), ("chunked", 0, 1),
	};
	for(i = 0; i < len cases; i++){
		(model, stream, anth) := cases[i];
		r, err: string;
		if(anth)
			(r, err) = anthropic(model, stream);
		else
			(r, err) = openai(model, stream);
		what := sys->sprint("%s stream=%d anthropic=%d", model, stream, anth);
		s := must(t, what, r, err);
		t.asserteq(s.conn, first.conn, what + " on the same connection");
	}
	(m, merr) := llmclient->listmodels(url(), "test-key");
	s := must(t, "models", m, merr);
	t.asserteq(s.conn, first.conn, "GET of the models on the same connection");
	(r, err) := openai("plain", 0);
	s = must(t, "last", r, err);
	t.asserteq(s.conns, first.conns, "no connection made after the first");
}

testidleclosed(t: ref T)
{
	warm(t);
	(r, err) := openai("idle", 0);
	a := must(t, "idle", r, err);
	sys->sleep(1000);	# the server closes it after 300ms
	(r, err) = openai("plain", 0);
	b := must(t, "after the server closed it", r, err);
	t.assertne(b.conn, a.conn, "a new connection replaces the closed one");
	t.asserteq(b.slams, a.slams, "nothing else lost");
	(r, err) = openai("plain", 1);
	c := must(t, "streamed after", r, err);
	t.asserteq(c.conn, b.conn, "and is kept in its turn");
}

testlateend(t: ref T)
{
	warm(t);
	t0 := sys->millisec();
	(r, err) := openai("lateend", 1);
	a := must(t, "late end", r, err);
	ms := sys->millisec() - t0;
	t.assert(ms >= 1300, sys->sprint("the stream is read to its terminating chunk (%d ms)", ms));
	(r, err) = openai("plain", 0);
	b := must(t, "after", r, err);
	t.asserteq(b.conn, a.conn, "the connection is kept after the terminating chunk");
	(r, err) = anthropic("lateend", 1);
	c := must(t, "anthropic late end", r, err);
	t.asserteq(c.conn, a.conn, "and after an Anthropic stream's");
	(r, err) = anthropic("plain", 0);
	d := must(t, "after", r, err);
	t.asserteq(d.conn, a.conn, "the next reply on it whole");
}

streamer(model: string, pid: chan of int, sc: chan of string, res: chan of (string, string))
{
	sys->pctl(Sys->NEWPGRP, nil);
	pid <-= sys->pctl(0, nil);
	(r, err) := llmclient->askopenai(url(), "test-key", newreq(model, sc));
	if(r == nil)
		res <-= (nil, err);
	else
		res <-= (r.response, err);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testcancel(t: ref T)
{
	warm(t);
	pid := chan of int;
	sc := chan[1000] of string;
	res := chan[1] of (string, string);
	spawn streamer("slow", pid, sc, res);
	p := <-pid;
	tmo := chan of int;
	spawn timer(tmo, 5000);
	first := "";
	alt {
	first = <-sc =>
		;
	<-tmo =>
		t.fatal("no delta from the stream");
	}
	a := said(first);
	t.log("cancelled stream: " + first);
	fd := sys->open(sys->sprint("/prog/%d/ctl", p), Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "killgrp") < 0)
		t.fatal(sys->sprint("cannot kill the stream: %r"));
	sys->sleep(200);
	for(i := 0; i < 3; i++){
		(r, err) := openai("plain", 0);
		b := must(t, "after the cancel", r, err);
		t.assertne(b.conn, a.conn, "a cancelled stream's connection is not used again");
	}
}

# The heap in use, from /dev/memory.
heapused(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines) {
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 8 && hd tl tl tl tl tl tl tl f == "heap")
			return int hd f;
	}
	return -1;
}

# Start a slow stream in a group of its own and kill the group once
# its first delta has come: llmsrv's cancel.
cancelone(t: ref T): ref Said
{
	pid := chan of int;
	sc := chan[1000] of string;
	res := chan[1] of (string, string);
	spawn streamer("slow", pid, sc, res);
	p := <-pid;
	tmo := chan of int;
	spawn timer(tmo, 5000);
	first := "";
	alt {
	first = <-sc =>
		;
	<-tmo =>
		t.fatal("no delta from the stream");
	}
	fd := sys->open(sys->sprint("/prog/%d/ctl", p), Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "killgrp") < 0)
		t.fatal(sys->sprint("cannot kill the stream: %r"));
	return said(first);
}

# A stream cancelled mid-read leaves nothing behind: its TLS state was
# kept in a table of the TLS module's, emptied only by close, which a
# killed reader never reaches.
testcancelfrees(t: ref T)
{
	warm(t);
	cancelone(t);	# whatever a first cancel loads or makes once
	sys->sleep(300);
	warm(t);
	before := heapused();
	if(before < 0)
		t.skip("no /dev/memory");
	N: con 20;
	for(i := 0; i < N; i++) {
		cancelone(t);
		sys->sleep(100);
	}
	sys->sleep(500);
	warm(t);
	after := heapused();
	t.log(sys->sprint("heap %d before, %d after %d cancelled streams", before, after, N));
	t.assert(after - before < 32*1024,
		sys->sprint("%d cancelled streams keep %d bytes of heap", N, after - before));
}

# A request in a group of its own, killed after ms: anywhere, a pool
# operation included.
killat(ms: int, model: string, stream: int)
{
	pid := chan of int;
	sc: chan of string;
	if(stream)
		sc = chan[1000] of string;
	spawn streamer(model, pid, sc, chan[1] of (string, string));
	p := <-pid;
	sys->sleep(ms);
	fd := sys->open(sys->sprint("/prog/%d/ctl", p), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

asker(model: string, res: chan of (string, string))
{
	res <-= openai(model, 0);
}

# Requests killed at every moment of their life (taking a connection,
# writing, reading, putting it back) leave the pool working: the next
# ones answer, and two at once still get two connections.  A request
# killed while it held a lock on the pool wedged every request after.
testkillstorm(t: ref T)
{
	warm(t);
	seed := sys->millisec();
	for(i := 0; i < 60; i++) {
		seed = seed * 1103515245 + 12345;
		ms := (seed >> 8) & 16r1f;
		if(i & 1)
			spawn killat(ms, "plain", i & 2);
		else
			killat(ms, "plain", i & 2);
	}
	sys->sleep(500);
	for(i = 0; i < 3; i++) {
		res := chan[1] of (string, string);
		spawn asker("plain", res);
		tmo := chan of int;
		spawn timer(tmo, 10000);
		alt {
		(r, err) := <-res =>
			must(t, "after the storm", r, err);
		<-tmo =>
			t.fatal("a request after the storm did not return: the pool is wedged");
		}
	}
	pid := chan[2] of int;
	res := chan[2] of (string, string);
	spawn streamer("slow2", pid, chan[100] of string, res);
	spawn streamer("slow2", pid, chan[100] of string, res);
	(r, err) := <-res;
	a := must(t, "at once after the storm", r, err);
	(r, err) = <-res;
	b := must(t, "at once after the storm", r, err);
	t.assertne(a.conn, b.conn, "two at once still on two connections");
}

testconcurrent(t: ref T)
{
	before := warm(t);
	pid := chan[2] of int;
	res := chan[2] of (string, string);
	spawn streamer("slow2", pid, chan[100] of string, res);
	spawn streamer("slow2", pid, chan[100] of string, res);
	<-pid;
	<-pid;
	conns: list of int;
	for(i := 0; i < 2; i++){
		(r, err) := <-res;
		conns = must(t, "at once", r, err).conn :: conns;
	}
	t.assertne(hd conns, hd tl conns, "two requests at once on two connections");
	t.assert(hd conns == before.conn || hd tl conns == before.conn, "one of them the kept one");
	(r, err) := openai("plain", 0);
	s := must(t, "after", r, err);
	t.assert(s.conn == hd conns || s.conn == hd tl conns, "both kept after");
	t.asserteq(s.conns, before.conns + 1, "one connection made for the second");
	pid = chan[2] of int;
	spawn streamer("slow2", pid, chan[100] of string, res);
	spawn streamer("slow2", pid, chan[100] of string, res);
	for(i = 0; i < 2; i++){
		(r, err) = <-res;
		must(t, "at once again", r, err);
	}
	(r, err) = openai("plain", 0);
	s2 := must(t, "after again", r, err);
	t.asserteq(s2.conns, s.conns, "the two kept used again, none made");
}

testretryonce(t: ref T)
{
	w := warm(t);
	(nil, err) := openai("slam", 0);
	t.assert(err != nil, "a request the server closes on is an error: " + err);
	(r, err2) := openai("plain", 0);
	a := must(t, "after", r, err2);
	t.asserteq(a.slams - w.slams, 2, "on a kept connection: sent again once on a new one");
	t.assertne(a.conn, w.conn, "the dead connection not used again");

	# none kept now: the pool's last went with the slam
	(nil, err) = openai("slam", 0);
	(nil, err) = openai("slam", 0);
	(r, err2) = openai("plain", 0);
	b := must(t, "after", r, err2);
	t.asserteq(b.slams - a.slams, 3, "kept once, then new: sent 2 + 1 times");

	(nil, err) = openai("midfail", 0);
	t.assert(err != nil, "a reply cut short is an error: " + err);
	(r, err2) = openai("plain", 0);
	c := must(t, "after", r, err2);
	t.asserteq(c.midfails - b.midfails, 1, "a request answered in part is not sent again");
	t.assertne(c.conn, b.conn, "its connection not used again");

	(nil, err) = openai("midfail", 1);
	t.assert(err != nil, "a stream cut short is an error: " + err);
	(r, err2) = openai("plain", 0);
	d := must(t, "after", r, err2);
	t.asserteq(d.midfails - c.midfails, 1, "a stream answered in part is not sent again");
}

testconnclose(t: ref T)
{
	warm(t);
	(r, err) := openai("close", 0);
	a := must(t, "Connection: close", r, err);
	(r, err) = openai("plain", 0);
	b := must(t, "after", r, err);
	t.assertne(b.conn, a.conn, "a connection the server closes is not used again");
	(r, err) = openai("close", 1);
	c := must(t, "streamed, Connection: close", r, err);
	(r, err) = openai("plain", 1);
	d := must(t, "after", r, err);
	t.assertne(d.conn, c.conn, "nor after a stream");
}

# The proxy: a CONNECT to 127.0.0.1:port tunnelled there; each one
# counted on connects.
proxy(ac: Sys->Connection, connects: chan of int)
{
	for(;;){
		(ok, nc) := sys->listen(ac);
		if(ok < 0)
			return;
		spawn tunnel(nc, connects);
	}
}

tunnel(nc: Sys->Connection, connects: chan of int)
{
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil)
		return;
	h := "";
	buf := array[1] of byte;
	while(sys->read(dfd, buf, 1) == 1){
		h[len h] = int buf[0];
		if(len h >= 4 && h[len h - 4:] == "\r\n\r\n")
			break;
	}
	(nil, w) := sys->tokenize(h, " ");
	if(len w < 2 || hd w != "CONNECT" || hd tl w != "127.0.0.1:" + port){
		sys->fprint(dfd, "HTTP/1.1 403 Forbidden\r\n\r\n");
		return;
	}
	(ok, up) := sys->dial("tcp!127.0.0.1!" + port, nil);
	if(ok < 0){
		sys->fprint(dfd, "HTTP/1.1 502 Bad Gateway\r\n\r\n");
		return;
	}
	connects <-= 1;
	sys->fprint(dfd, "HTTP/1.1 200 Connection established\r\n\r\n");
	spawn copy(up.dfd, dfd);
	copy(dfd, up.dfd);
}

copy(src, dst: ref Sys->FD)
{
	buf := array[8192] of byte;
	while((n := sys->read(src, buf, len buf)) > 0)
		if(sys->write(dst, buf, n) != n)
			break;
}

ncount(c: chan of int): int
{
	n := 0;
	for(;;) alt {
	<-c =>
		n++;
	* =>
		return n;
	}
}

testproxy(t: ref T)
{
	(aok, ac) := sys->announce(sys->sprint("tcp!127.0.0.1!%d", proxyport));
	if(aok < 0)
		t.skip(sys->sprint("cannot announce on loopback: %r"));
	connects := chan[100] of int;
	spawn proxy(ac, connects);

	setenv("https_proxy", sys->sprint("http://127.0.0.1:%d", proxyport));
	(r, err) := openai("plain", 0);
	a := must(t, "through the proxy", r, err);
	for(i := 0; i < 3; i++){
		(r, err) = openai("plain", i & 1);
		s := must(t, "through the proxy again", r, err);
		t.asserteq(s.conn, a.conn, "the tunnel is kept");
	}
	(r, err) = anthropic("plain", 1);
	s := must(t, "Anthropic through the proxy", r, err);
	t.asserteq(s.conn, a.conn, "the tunnel is kept for the API's host, whatever the API");
	t.asserteq(ncount(connects), 1, "one CONNECT for five requests");

	clearenv();
	(r, err) = openai("plain", 0);
	d := must(t, "direct", r, err);
	t.assertne(d.conn, a.conn, "a host dialled directly does not use the tunnel");
	t.asserteq(ncount(connects), 0, "nor ask the proxy");

	setenv("https_proxy", sys->sprint("http://127.0.0.1:%d", proxyport));
	(r, err) = openai("plain", 0);
	e := must(t, "through the proxy once more", r, err);
	t.asserteq(e.conn, a.conn, "the tunnel is still kept");
	t.asserteq(ncount(connects), 0, "with no CONNECT");

	setenv("https_proxy", sys->sprint("http://u:p@127.0.0.1:%d", proxyport));
	(r, err) = openai("plain", 0);
	f := must(t, "through the proxy with credentials", r, err);
	t.assertne(f.conn, a.conn, "a tunnel opened with other credentials is not shared");
	t.asserteq(ncount(connects), 1, "a CONNECT of its own");

	setenv("no_proxy", "127.0.0.1");
	(r, err) = openai("plain", 0);
	g := must(t, "no_proxy", r, err);
	t.asserteq(g.conn, d.conn, "no_proxy: the direct connection");
	clearenv();
}

bench(relay: string, n: int)
{
	for(l := 0 :: 1 :: nil; l != nil; l = tl l){
		stream := hd l;
		times := "";
		total := 0;
		for(i := 0; i < n; i++){
			sc: chan of string;
			if(stream)
				sc = chan[1000] of string;
			t0 := sys->millisec();
			(r, err) := llmclient->askopenai("https://127.0.0.1:" + relay + "/v1", "k", newreq("plain", sc));
			ms := sys->millisec() - t0;
			if(r == nil || err != nil){
				sys->print("bench: %s\n", err);
				raise "fail:bench";
			}
			total += ms;
			times += sys->sprint(" %d", ms);
		}
		s := "buffered";
		if(stream)
			s = "streamed";
		sys->print("bench %s: %d calls %d ms, %d ms each; first %s\n", s, n, total, total/n, times);
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	relay := "";
	nbench := 0;
	for(a := tl args; a != nil; a = tl a){
		case hd a {
		"-v" =>
			testing->verbose(1);
		"-p" =>
			a = tl a;
			port = hd a;
		"-b" =>
			relay = hd tl a;
			nbench = int hd tl tl a;
			a = tl tl a;
		}
	}
	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil){
		sys->fprint(sys->fildes(2), "cannot load llmclient: %r\n");
		raise "fail:cannot load llmclient";
	}
	llmclient->init();
	sys->pctl(Sys->FORKENV, nil);
	clearenv();

	if(relay != nil){
		bench(relay, nbench);
		return;
	}
	if(port == nil)
		raise "skip:needs its fake API: run tests/host/llmclient_pool_test.sh";

	run("Sequential", testsequential);
	run("IdleClosed", testidleclosed);
	run("LateEnd", testlateend);
	run("Cancel", testcancel);
	run("Concurrent", testconcurrent);
	run("RetryOnce", testretryonce);
	run("ConnectionClose", testconnclose);
	run("Proxy", testproxy);
	# these two leave more than one connection kept: after the rest
	run("CancelFreesState", testcancelfrees);
	run("KillStorm", testkillstorm);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
