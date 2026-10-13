implement LlmclientProxyTest;

#
# llmclient_proxy_test - llmclient reaches an HTTPS API through an
# HTTP proxy (INFR-307).
#
# The test is the proxy: it announces on loopback, sets $https_proxy
# to itself, and drives llmclient->listmodels at an https:// URL.  It
# checks what llmclient sends: a CONNECT for the API's host and port,
# the proxy's credentials when the URL names them, and then a TLS
# ClientHello naming the API's host inside the tunnel.  The test hangs
# up there, so listmodels itself fails; what matters is the tunnel.
#
# Also: a proxy that refuses CONNECT is reported as such, and a host
# in $no_proxy is dialled directly, the proxy never hearing of it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "llmclient.m";
	llmclient: Llmclient;

include "encoding.m";
	base64: Encoding;

include "testing.m";
	testing: Testing;
	T: import testing;

LlmclientProxyTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/llmclient_proxy_test.b";

CLOSEDPORT: con 19739;	# nothing listens here
proxyport := 19740;	# each proxy has a port of its own

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

# What the proxy saw of one connection.
Seen: adt {
	header:	string;	# the request header, up to the blank line
	tunnel:	array of byte;	# what came through the tunnel
};

# The proxy: accept one connection, read the request header, answer
# with reply, and if it is a 200 read what comes through the tunnel.
proxy(ac: Sys->Connection, reply: string, seen: chan of ref Seen)
{
	(ok, nc) := sys->listen(ac);
	if(ok < 0){
		seen <-= nil;
		return;
	}
	dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		seen <-= nil;
		return;
	}
	s := ref Seen("", nil);
	buf := array[1] of byte;
	while(sys->read(dfd, buf, 1) == 1){
		s.header[len s.header] = int buf[0];
		n := len s.header;
		if(n >= 4 && s.header[n-4:] == "\r\n\r\n")
			break;
	}
	b := array of byte reply;
	sys->write(dfd, b, len b);
	if(len reply >= 12 && reply[9:12] == "200"){
		t := array[4096] of byte;
		n := sys->read(dfd, t, len t);
		if(n > 0)
			s.tunnel = t[0:n];
	}
	seen <-= s;
	sys->fprint(sys->open(nc.dir + "/ctl", Sys->OWRITE), "hangup");
}

# listmodels on its own proc, so the test can time it out.
call(url: string, res: chan of string)
{
	(nil, err) := llmclient->listmodels(url, "test-key");
	res <-= err;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# Run listmodels(url) against a proxy answering reply.
# Returns what the proxy saw (nil if no connection came) and listmodels' error.
viaproxy(t: ref T, url, reply: string): (ref Seen, string)
{
	(aok, ac) := sys->announce(sys->sprint("tcp!127.0.0.1!%d", proxyport));
	if(aok < 0)
		t.skip(sys->sprint("cannot announce on loopback: %r"));
	seen := chan[1] of ref Seen;
	spawn proxy(ac, reply, seen);
	res := chan[1] of string;
	spawn call(url, res);
	tmo := chan of int;
	spawn timer(tmo, 15000);
	err := "";
	alt {
	err = <-res =>
		;
	<-tmo =>
		t.fatal("listmodels did not return");
	}
	# The proxy reports once it has answered.  If no connection came
	# in 2s, none is coming: say so without waiting on the proxy, whose
	# listen a hangup does not end on every host (macOS's accept goes on
	# blocking), and dial it once so that its listen returns and it goes.
	tmo = chan of int;
	spawn timer(tmo, 2000);
	s: ref Seen;
	alt {
	s = <-seen =>
		;
	<-tmo =>
		s = nil;
		(nil, d) := sys->dial(sys->sprint("tcp!127.0.0.1!%d", proxyport), nil);
		d.dfd = nil;
	}
	return (s, err);
}

# The URL of the next proxy, on a port no earlier proxy used.
proxyurl(pre, post: string): string
{
	proxyport++;
	return pre + sys->sprint("127.0.0.1:%d", proxyport) + post;
}

contains(a: array of byte, s: string): int
{
	b := array of byte s;
	for(i := 0; i + len b <= len a; i++){
		j := 0;
		while(j < len b && a[i+j] == b[j])
			j++;
		if(j == len b)
			return 1;
	}
	return 0;
}

firstline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\r' || s[i] == '\n')
			return s[0:i];
	return s;
}

testtunnel(t: ref T)
{
	clearenv();
	setenv("https_proxy", proxyurl("http://", ""));
	(s, err) := viaproxy(t, "https://api.example.test/v1", "HTTP/1.1 200 Connection established\r\n\r\n");
	if(s == nil)
		t.fatal("the proxy saw no connection; listmodels said: " + err);
	t.assertseq(firstline(s.header), "CONNECT api.example.test:443 HTTP/1.1", "CONNECT names the API's host and port");
	t.assert(contains(array of byte s.header, "\r\nHost: api.example.test:443\r\n"), "CONNECT carries Host");
	t.assert(!contains(array of byte s.header, "Proxy-Authorization"), "no credentials when the proxy URL has none");
	t.assert(len s.tunnel > 5 && s.tunnel[0] == byte 16r16 && s.tunnel[5] == byte 1,
		"a TLS ClientHello comes through the tunnel");
	t.assert(contains(s.tunnel, "api.example.test"), "the ClientHello names the API's host (SNI)");
	t.log("listmodels: " + err);
}

testport(t: ref T)
{
	clearenv();
	# the upper-case spelling, and the API on a port of its own
	setenv("HTTPS_PROXY", proxyurl("http://", "/"));
	(s, err) := viaproxy(t, "https://llm.example.test:8443/v1", "HTTP/1.1 200 OK\r\n\r\n");
	if(s == nil)
		t.fatal("the proxy saw no connection; listmodels said: " + err);
	t.assertseq(firstline(s.header), "CONNECT llm.example.test:8443 HTTP/1.1", "CONNECT names the API's port");
}

testcredentials(t: ref T)
{
	clearenv();
	setenv("https_proxy", proxyurl("http://us%40er:pa%3Ass@", ""));
	(s, err) := viaproxy(t, "https://api.example.test/v1", "HTTP/1.1 200 OK\r\n\r\n");
	if(s == nil)
		t.fatal("the proxy saw no connection; listmodels said: " + err);
	want := "Proxy-Authorization: Basic " + base64->enc(array of byte "us@er:pa:ss");
	t.assert(contains(array of byte s.header, "\r\n" + want + "\r\n"), "credentials sent, decoded, as Basic: " + want);
}

testrefused(t: ref T)
{
	clearenv();
	setenv("https_proxy", proxyurl("http://", ""));
	(s, err) := viaproxy(t, "https://api.example.test/v1", "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n");
	if(s == nil)
		t.fatal("the proxy saw no connection; listmodels said: " + err);
	t.assert(contains(array of byte err, "refused CONNECT api.example.test:443"), "the refusal is reported: " + err);
	t.assert(contains(array of byte err, "407"), "with the proxy's status: " + err);
}

testnoproxy(t: ref T)
{
	url := sys->sprint("https://127.0.0.1:%d/v1", CLOSEDPORT);
	for(l := "127.0.0.1" :: "localhost, 127.0.0.1" :: "*" :: nil; l != nil; l = tl l){
		clearenv();
		setenv("https_proxy", proxyurl("http://", ""));
		setenv("no_proxy", hd l);
		(s, err) := viaproxy(t, url, "HTTP/1.1 200 OK\r\n\r\n");
		t.assert(s == nil, "no_proxy=" + hd l + ": the proxy is not used");
		t.assert(contains(array of byte err, "cannot connect to 127.0.0.1"), "no_proxy=" + hd l + ": dialled directly: " + err);
	}
}

testnoproxydomain(t: ref T)
{
	# a domain covers its subdomains, with or without the dot;
	# a mere suffix of a name does not
	for(l := ("example.test", 0) :: (".example.test", 0) :: ("NO_PROXY=example.test", 0) ::
			("xample.test", 1) :: ("other.test", 1) :: nil; l != nil; l = tl l){
		(np, proxied) := hd l;
		clearenv();
		setenv("https_proxy", proxyurl("http://", ""));
		if(len np > 9 && np[0:9] == "NO_PROXY=")
			setenv("NO_PROXY", np[9:]);
		else
			setenv("no_proxy", np);
		# when proxied the proxy refuses, so nothing is dialled directly
		(s, nil) := viaproxy(t, "https://api.example.test/v1", "HTTP/1.1 403 Forbidden\r\n\r\n");
		if(proxied)
			t.assert(s != nil, np + ": api.example.test goes through the proxy");
		else
			t.assert(s == nil, np + ": api.example.test is dialled directly");
	}
}

testbadproxy(t: ref T)
{
	clearenv();
	setenv("https_proxy", "https://user:secret@127.0.0.1:3128");
	(nil, err) := llmclient->listmodels("https://api.example.test/v1", "k");
	t.assert(contains(array of byte err, "only an http:// proxy is supported"), "an https:// proxy is refused: " + err);
	t.assert(!contains(array of byte err, "secret"), "the refusal does not repeat the proxy's password: " + err);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	llmclient = load Llmclient Llmclient->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(llmclient == nil || base64 == nil){
		sys->fprint(sys->fildes(2), "cannot load llmclient or base64: %r\n");
		raise "fail:cannot load modules";
	}
	llmclient->init();

	# the proxy variables set here stay in this test
	sys->pctl(Sys->FORKENV, nil);

	run("Tunnel", testtunnel);
	run("ApiPort", testport);
	run("Credentials", testcredentials);
	run("Refused", testrefused);
	run("NoProxy", testnoproxy);
	run("NoProxyDomain", testnoproxydomain);
	run("HttpsProxyRefused", testbadproxy);
	clearenv();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
