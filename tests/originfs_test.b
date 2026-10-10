implement OriginfsTest;

#
# originfs_test - the origin filter a page's realm sees as /mnt/web
# (appl/lib/web/originfs.b), in front of a real webfs.
#
#	originfs_test [-v] pageurl otherurl
#
# Both URLs are a test server's (tests/host/originfs_test.sh starts it,
# on two ports: two origins).  Without them the test skips, so the
# runner's plain run of every *_test.dis passes it by.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/originfs.m";
	originfs: Originfs;

OriginfsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/originfs_test.b";
Mnt: con "/tmp/originfs.mnt";

passed := 0;
failed := 0;
skipped := 0;
page, other, pageorigin: string;

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

# a request through the filter: (status, body, header), or the ctl
# write's error as the status
req(lines: list of string, post: string): (string, string, string)
{
	cfd := sys->open(Mnt + "/clone", Sys->OREAD);
	if(cfd == nil)
		return (sys->sprint("no clone: %r"), nil, nil);
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return (sys->sprint("clone: %r"), nil, nil);
	d := Mnt + "/" + string buf[0:n];
	ctl := sys->open(d + "/ctl", Sys->OWRITE);
	for(; lines != nil; lines = tl lines)
		if(sys->fprint(ctl, "%s", hd lines) < 0)
			return (sys->sprint("ctl: %r"), nil, nil);
	if(post != nil) {
		pfd := sys->open(d + "/postbody", Sys->OWRITE);
		b := array of byte post;
		sys->write(pfd, b, len b);
	}
	body := readfile(d + "/body");
	return (readfile(d + "/status"), body, readfile(d + "/header"));
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

writefile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

ok(status: string): int
{
	return len status >= 3 && status[0:3] == "200";
}

testSchemes(t: ref T)
{
	(st, nil, nil) := req("url file:///dev/sysctl" :: nil, nil);
	t.assert(has(st, "not an http or https URL"), "a file: URL is refused: " + st);
	(st, nil, nil) = req("url " + page + "echo" :: "method TRACE" :: nil, nil);
	t.assert(has(st, "method not allowed"), "TRACE is refused: " + st);
}

testSameOrigin(t: ref T)
{
	(st, body, nil) := req("url " + page + "echo" :: "header X-Test: yes" :: "header Cookie: stolen=1" ::
		"header Origin: http://evil.example" :: "header Host: evil.example" :: nil, nil);
	t.assert(ok(st), "same-origin GET: " + st);
	t.assert(has(body, "X-Test: yes"), "an ordinary header goes");
	t.assert(!has(body, "stolen=1"), "a Cookie header of the script's does not");
	t.assert(!has(body, "evil.example"), "nor its Origin or Host");
}

testCors(t: ref T)
{
	(st, body, nil) := req("url " + other + "echo" :: nil, nil);
	t.assert(has(st, "blocked by CORS"), "another origin's response, not offered: " + st);
	t.assert(body == "", "and its body is not given");
	(st, body, nil) = req("url " + other + "echo?acao=" + pageorigin :: nil, nil);
	t.assert(ok(st), "offered to this origin: " + st);
	t.assert(has(body, "Origin: " + pageorigin), "the request carried this origin");
	(st, nil, nil) = req("url " + other + "echo?acao=*" :: "credentials include" :: nil, nil);
	t.assert(has(st, "blocked by CORS"), "* does not do for a request with credentials: " + st);
	(st, nil, nil) = req("url " + other + "echo?acao=" + pageorigin + "&cred=1" :: "credentials include" :: nil, nil);
	t.assert(ok(st), "with Allow-Credentials it does: " + st);
	(st, nil, nil) = req("url " + other + "echo" :: "mode same-origin" :: nil, nil);
	t.assert(has(st, "same-origin mode"), "same-origin mode refuses another origin: " + st);
}

testPreflight(t: ref T)
{
	(st, nil, nil) := req("url " + other + "echo?acao=" + pageorigin :: "method PUT" :: "header X-Custom: 1" :: nil, "x");
	t.assert(has(st, "preflight"), "a PUT the server's preflight does not allow: " + st);
	(st, nil, nil) = req("url " + other + "echo?acao=" + pageorigin + "&pre=ok" :: "method PUT" :: "header X-Custom: 1" :: nil, "x");
	t.assert(ok(st), "one it allows: " + st);
}

testNoCors(t: ref T)
{
	(st, body, nil) := req("url " + other + "script.js" :: "mode no-cors" :: nil, nil);
	t.assert(ok(st) && has(body, "ran"), "another origin's script, no-cors: " + st);
	(st, body, nil) = req("url " + other + "data.json" :: "mode no-cors" :: nil, nil);
	t.assert(has(st, "blocked"), "another origin's JSON, no-cors: " + st);
	t.assert(body == "", "is not given");
	(st, body, nil) = req("url " + other + "page.html" :: "mode no-cors" :: nil, nil);
	t.assert(has(st, "blocked"), "nor its HTML: " + st);
}

testCookies(t: ref T)
{
	(st, nil, nil) := req("url " + page + "setcookie" :: nil, nil);
	t.assert(ok(st), "the server sets cookies: " + st);
	jar := readfile("/mnt/web/cookies");
	t.assert(has(jar, "hid=2"), "webfs's jar has the HttpOnly one");
	mine := readfile(Mnt + "/cookies");
	t.assert(has(mine, "vis=1"), "the page sees its cookie: " + mine);
	t.assert(!has(mine, "hid=2"), "not the HttpOnly one");
	t.assert(writefile(Mnt + "/cookies", "example.com / z=1 0 0 0 0\n") != nil, "nor sets another site's");
	t.assert(writefile(Mnt + "/cookies", "127.0.0.1 / h=1 0 0 1 1\n") != nil, "nor an HttpOnly one");
	e := writefile(Mnt + "/cookies", "127.0.0.1 / w=3 0 0 0 1\n");
	t.assert(e == nil, "it sets its own: " + e);
	t.assert(has(readfile("/mnt/web/cookies"), "w=3"), "which goes into the jar");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	args = tl args;
	if(args != nil && hd args == "-v") {
		testing->verbose(1);
		args = tl args;
	}
	if(len args != 2) {
		sys->print("originfs_test: SKIP (no test server given)\n");
		return;
	}
	page = hd args;
	other = hd tl args;
	originfs = load Originfs Originfs->PATH;
	if(originfs == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Originfs->PATH);
		raise "fail:load";
	}
	pageorigin = originfs->origin(page);
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	ready := chan of string;
	spawn originfs->serve(p[1], pageorigin, "/mnt/web", ready);
	if((e := <-ready) != nil) {
		sys->fprint(sys->fildes(2), "originfs: %s\n", e);
		raise "fail:serve";
	}
	p[1] = nil;
	sys->create(Mnt, Sys->OREAD, Sys->DMDIR|8r755);
	if(sys->mount(p[0], nil, Mnt, Sys->MREPL, nil) < 0) {
		sys->fprint(sys->fildes(2), "mount: %r\n");
		raise "fail:mount";
	}
	run("Schemes", testSchemes);
	run("SameOrigin", testSameOrigin);
	run("Cors", testCors);
	run("Preflight", testPreflight);
	run("NoCors", testNoCors);
	run("Cookies", testCookies);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
