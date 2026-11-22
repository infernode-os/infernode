implement WebStatusTest;

#
# web(2) reading the webget service's answers (appl/lib/web.b), against
# a /chan/webget of the test's own.
#
# An answer is a line, "OK length id type url", and then the body.
# web(2) took the line to be exactly what one read of 1000 bytes gave.
# Body bytes that came in that read were dropped: the body was then
# waited for past its end, and a read of nothing was read again for
# ever, so the caller (acme's and Xenith's Jwin) never came back.  A
# line longer than 1000 bytes, as a long URL makes it, was cut, and its
# end was the body's first bytes.  A line with too few fields was hd of
# nil, and a negative length an array of negative size.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web.m";
	web: Web;

WebStatusTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_status_test.b";

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

BODY: con "The body of the page, all forty-two bytes.\n";

longpath(): string
{
	s := "/long/";
	while(len s < 1500)
		s += "abcdefghij";
	return s;
}

# The pieces an answer comes in, by the path asked for.  A read is
# given the next piece, or as much of it as it asked for.
answer(url: string): list of array of byte
{
	path := url;
	for(i := len "http://"; i < len url; i++)
		if(url[i] == '/') {
			path = url[i:];
			break;
		}
	st := sys->sprint("OK %d id1 text/plain %s\n", len BODY, url);
	case path {
	"/together" =>
		return array of byte (st + BODY) :: nil;
	"/apart" =>
		return array of byte st :: array of byte BODY[0:10] :: array of byte BODY[10:] :: nil;
	"/halfline" =>
		return array of byte st[0:7] :: array of byte (st[7:] + BODY[0:5]) :: array of byte BODY[5:] :: nil;
	"/short" =>
		return array of byte sys->sprint("OK 100 id1 text/plain %s\n", url) :: array of byte BODY :: nil;
	"/fewfields" =>
		return array of byte "OK 5 id1\n" :: nil;
	"/negative" =>
		return array of byte sys->sprint("OK -5 id1 text/plain %s\n", url) :: nil;
	"/noline" =>
		return array of byte "no newline here" :: nil;
	"/error" =>
		return array of byte "ERROR id1 no such page\n" :: nil;
	}
	# a long URL: the line alone, as webget gives it
	return array of byte st :: array of byte BODY :: nil;
}

server(fio: ref Sys->FileIO)
{
	pieces: list of array of byte;
	for(;;) alt {
	(nil, count, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		if(pieces == nil) {
			rc <-= (nil, nil);
			continue;
		}
		p := hd pieces;
		if(len p > count) {
			pieces = p[count:] :: tl pieces;
			p = p[0:count];
		} else
			pieces = tl pieces;
		rc <-= (p, nil);
	(nil, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		# "GET∎0∎id1∎url∎types∎cache\n"
		(nil, f) := sys->tokenize(string data, "∎");
		if(len f >= 4)
			pieces = answer(hd tl tl tl f);
		wc <-= (len data, nil);
	}
}

fetcher(url: string, pidc: chan of int, done: chan of (array of byte, string))
{
	pidc <-= sys->pctl(0, nil);
	{
		done <-= (web->readurl(url), nil);
	} exception e {
	"*" =>
		done <-= (nil, e);
	}
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# readurl's result: (bytes, nil), or (nil, why it gave none)
fetch(path: string): (array of byte, string)
{
	pidc := chan of int;
	done := chan[1] of (array of byte, string);
	spawn fetcher("http://web.test" + path, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(5000, tc);
	alt {
	(b, e) := <-done =>
		if(e != nil)
			return (nil, "raised: " + e);
		return (b, nil);
	<-tc =>
		kill(pid);
		return (nil, "did not return in 5 s");
	}
}

body(t: ref T, path, what: string)
{
	(b, e) := fetch(path);
	if(e != nil) {
		t.error(what + ": " + e);
		return;
	}
	t.assertseq(string b, BODY, what);
}

none(t: ref T, path, what: string)
{
	(b, e) := fetch(path);
	if(e != nil) {
		t.error(what + ": " + e);
		return;
	}
	t.asserteq(len b, 0, what);
}

testApart(t: ref T)
{
	body(t, "/apart", "the line alone, then the body in two reads");
}

testTogether(t: ref T)
{
	body(t, "/together", "the line and the body in one read");
	body(t, "/apart", "and the answer after it is its own");
	body(t, "/halfline", "the line in two reads, the body's start with its end");
}

testLongLine(t: ref T)
{
	body(t, longpath(), "a line of 1500 bytes");
	body(t, "/apart", "and the answer after it is its own");
}

testShort(t: ref T)
{
	(b, e) := fetch("/short");
	if(e != nil) {
		t.error("a body shorter than its length: " + e);
		return;
	}
	t.assertseq(string b, BODY, "a body shorter than its length is what came");
}

testNotAnswers(t: ref T)
{
	none(t, "/fewfields", "an OK line of three fields gives nothing");
	none(t, "/negative", "a negative length gives nothing");
	none(t, "/noline", "no line at all gives nothing");
	none(t, "/error", "an error gives nothing");
	body(t, "/apart", "and a page is fetched after them");
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

	# a webget of our own, in a name space of our own
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#swebstatus", "/chan", Sys->MBEFORE) < 0) {
		sys->fprint(sys->fildes(2), "web_status_test: bind #s /chan: %r\n");
		raise "fail:bind";
	}
	fio := sys->file2chan("/chan", "webget");
	if(fio == nil) {
		sys->fprint(sys->fildes(2), "web_status_test: file2chan: %r\n");
		raise "fail:file2chan";
	}
	spawn server(fio);
	web = load Web Web->PATH;
	if(web == nil) {
		sys->fprint(sys->fildes(2), "web_status_test: cannot load %s: %r\n", Web->PATH);
		raise "fail:load";
	}
	web->init0();

	run("Apart", testApart);
	run("Together", testTogether);
	run("LongLine", testLongLine);
	run("Short", testShort);
	run("NotAnswers", testNotAnswers);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
