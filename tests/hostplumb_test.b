implement HostplumbTest;

#
# hostplumb(1) and the plumber's refusal of an undeliverable message.
#
# And (DotDot, Unrooted) host paths that are none: a path through ..
# left the root hostplumb puts host paths under, for this machine's own
# files, and a name with nothing to root it went on as a name of this
# name space.  And the plumber (Garbage, StartFails, RulesInPieces,
# Oversize): bytes that are no message and a control message with no
# meaning were answered as sent; a port whose program could not be
# loaded queued every later message for a start that never came; a rule
# set written in two writes was its first piece, the second refused; a
# message longer than its reader's buffer stayed at the head of the
# port's queue, and nothing after it was ever delivered.
#
# A plumber is run in this test's own namespace with one rule (all
# text to the edit port). Messages in the host plumber's format are fed
# to hostplumb on its standard input, and what reaches the edit port is
# checked: host paths placed under the root, a relative name joined to
# its working directory, an addr attribute folded back into the data.
#
# Before anything listens on edit, the plumber must refuse a message
# rather than drop it silently (there is no start rule), and hostplumb
# must hold such a message until a receiver appears.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "sh.m";
	sh: Sh;

include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;

HostplumbTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/hostplumb_test.b";
RULES: con "/tmp/hostplumb_test.rules";
Waitms: con 5000;

passed := 0;
failed := 0;
skipped := 0;

loaderr: string;
received: chan of ref Msg;

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

# a message in the host plumber's format
hostmsg(dir, attr, data: string): array of byte
{
	return array of byte sys->sprint("plumb\nxenith\n%s\ntext\n%s\n%d\n%s",
		dir, attr, len array of byte data, data);
}

# hostplumb with the given messages on its standard input
hostplumb(args: list of string, msgs: list of array of byte)
{
	sys->pctl(Sys->FORKFD, nil);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return;
	for(; msgs != nil; msgs = tl msgs)
		sys->write(p[1], hd msgs, len hd msgs);
	p[1] = nil;
	sys->dup(p[0].fd, 0);
	p[0] = nil;
	c := "hostplumb";
	for(; args != nil; args = tl args)
		c += " " + hd args;
	sh->system(nil, c);
}

# the plumber's process group, whichever group sh gave it
killplumber()
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			return;
		for(i := 0; i < n; i++){
			b := array[256] of byte;
			sfd := sys->open("/prog/" + d[i].name + "/status", Sys->OREAD);
			if(sfd == nil)
				continue;
			r := sys->read(sfd, b, len b);
			if(r <= 0)
				continue;
			(nf, f) := sys->tokenize(string b[0:r], " \t");
			for(; nf > 1; nf--)
				f = tl f;
			if(f != nil && len hd f >= 7 && (hd f)[0:7] == "Plumber"){
				ctl := sys->open("/prog/" + d[i].name + "/ctl", Sys->OWRITE);
				if(ctl != nil)
					sys->fprint(ctl, "killgrp");
				return;
			}
		}
	}
}

startplumber(sync: chan of int)
{
	loaderr = sh->system(nil, "plumber -n " + RULES);	# -n: stay in this group, for killgrp
	if(loaderr != nil){
		sync <-= 0;
		return;
	}
	sync <-= 1;
}

receiver()
{
	for(;;){
		m := Msg.recv();
		if(m == nil)
			return;
		received <-= m;
	}
}

next(t: ref T): ref Msg
{
	timeout := chan[1] of int;
	spawn timer(timeout, Waitms);
	alt {
	m := <-received =>
		return m;
	<-timeout =>
		t.fatal("nothing reached the edit port");
	}
	return nil;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testRefused(t: ref T)
{
	fd := sys->open("/chan/plumb.input", Sys->OWRITE);
	if(fd == nil)
		t.fatal(sys->sprint("open /chan/plumb.input: %r"));
	b := array of byte "plumb\n\n/\ntext\n\n4\nnone";
	t.assert(sys->write(fd, b, len b) < 0,
		"a message with no receiver and no start rule is refused");
}

testHeld(t: ref T)
{
	# sent before anything listens: hostplumb must keep trying
	spawn hostplumb(nil, hostmsg("/Users/me", "", "/Users/me/early.c") :: nil);
	sys->sleep(1000);
	if(plumbmsg->init(0, "edit", 8192) < 0)
		t.fatal(sys->sprint("cannot open the edit port: %r"));
	spawn receiver();
	m := next(t);
	t.assertseq(string m.data, "/n/local/Users/me/early.c", "held message delivered");
}

testAbsolute(t: ref T)
{
	spawn hostplumb(nil, hostmsg("/Users/me", "addr=42", "/Users/me/f.c") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/Users/me/f.c:42", "path under /n/local, address folded in");
	t.assertseq(m.dir, "/n/local/Users/me", "working directory under /n/local");
	t.assertseq(m.dst, "edit", "routed by this namespace's rules");
}

testRelative(t: ref T)
{
	spawn hostplumb(nil, hostmsg("/Users/me/src", "", "lib/g.b:/main/") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/Users/me/src/lib/g.b:/main/", "relative name joined to its directory");
}

testRoot(t: ref T)
{
	spawn hostplumb("-r" :: "/n/host" :: nil, hostmsg("/home/u", "", "/home/u/a") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/host/home/u/a", "-r sets the root");
}

testOtherHost(t: ref T)
{
	# from another host (tools/rplumb): its own name, its own paths
	spawn hostplumb(nil, hostmsg("/home/u/src", "host=hephaestus addr=12", "/home/u/src/f.c") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/hephaestus/home/u/src/f.c:12", "under /n/<host>, not /n/local");
	t.assertseq(m.dir, "/n/hephaestus/home/u/src", "its directory too");
}

testBadHost(t: ref T)
{
	# a host name that is not one is dropped, not turned into a path
	spawn hostplumb(nil, hostmsg("/", "host=../etc", "/x") :: hostmsg("/a", "", "/a/after") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/a/after", "the bad message is skipped, the next delivered");
}

testPlain(t: ref T)
{
	# -p: plain host paths, as the emulator's /dev/hostopen gives them;
	# a line that is not an absolute path is skipped
	spawn hostplumb("-p" :: nil, array of byte "/Users/me/my file.c\nrelative\n/Users/me/dir\n" :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/Users/me/my file.c", "a path, spaces and all, under /n/local");
	t.assertseq(m.src, "hostopen", "from hostopen, so rules can take the whole data");
	t.assertseq(m.dst, "edit", "routed by this namespace's rules");
	m = next(t);
	t.assertseq(string m.data, "/n/local/Users/me/dir", "the relative line skipped, the next delivered");
}

testPlainWindows(t: ref T)
{
	# a file dropped on the window on Windows: C: is /n/local; another
	# drive is not mounted, so it is skipped
	spawn hostplumb("-p" :: nil, array of byte "C:\\Users\\me\\f.c\r\nD:\\x.c\nc:/a/b\n" :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/Users/me/f.c", "C:\\ made /n/local/");
	m = next(t);
	t.assertseq(string m.data, "/n/local/a/b", "D: skipped; c:/ taken too");
}

testDotDot(t: ref T)
{
	# a path through .. left the root for this machine's own files
	spawn hostplumb(nil, hostmsg("/Users/me", "", "/Users/me/../../../usr/inferno/secret") ::
		hostmsg("/Users/me/../..", "", "x.c") ::
		hostmsg("/Users/me", "", "../../../etc/y") ::
		hostmsg("/a", "addr=/a..b/", "/a/dots..in/a.name") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/a/dots..in/a.name:/a..b/", "three paths through .. dropped; dots in a name or an address are not ..");
	spawn hostplumb("-p" :: nil, array of byte "/Users/me/../../x\n/Users/me/ok..c\n" :: nil);
	m = next(t);
	t.assertseq(string m.data, "/n/local/Users/me/ok..c", "-p: a path through .. dropped too");
}

testUnrooted(t: ref T)
{
	# a name that is not absolute, with no directory or one that is not:
	# it went on as it came, a name of this name space
	spawn hostplumb(nil, hostmsg("", "", "lib/keyring") ::
		hostmsg("usr/inferno", "", "keyring") ::
		hostmsg("/a", "", "/a/rooted") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/a/rooted", "two names with nothing to root them dropped");
}

# a message as plumbmsg packs one, written to the plumber's input
plumbin(dst, data: string): int
{
	fd := sys->open("/chan/plumb.input", Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte sys->sprint("test\n%s\n/\ntext\n\n%d\n%s", dst, len array of byte data, data);
	return sys->write(fd, b, len b);
}

testGarbage(t: ref T)
{
	fd := sys->open("/chan/plumb.input", Sys->OWRITE);
	b := array of byte "garbage\n";
	t.assert(fd != nil && sys->write(fd, b, len b) < 0, "bytes that are no message are refused");
	t.assert(plumbin("plumb", "frobnicate") < 0, "a control message with no meaning is refused");
	t.assert(plumbin("", "/a/still") > 0, "and a message is still taken");
	m := next(t);
	t.assertseq(string m.data, "/a/still", "and delivered");
}

testStartFails(t: ref T)
{
	# a port whose program cannot be loaded: each message is refused,
	# none queued for a start that will not come
	t.assert(plumbin("", "startme one") < 0, "a message whose program cannot be loaded is refused");
	t.assert(plumbin("", "startme two") < 0, "and the next (it was queued for good)");
}

testOversize(t: ref T)
{
	# more than the edit port's reader has room for (8192 and a header)
	long := "/a/";
	while(len long < 20000)
		long += "0123456789";
	t.assert(plumbin("", long) > 0, "a message of 20000 bytes is taken");
	sys->sleep(500);	# its reader is told it does not fit, and goes
	spawn receiver();
	t.assert(plumbin("", "/a/after") > 0, "and one after it");
	m := next(t);
	t.assertseq(string m.data, "/a/after", "which is delivered: the long one does not stay at the head of the queue");
}

testRulesInPieces(t: ref T)
{
	r1 := "kind is text\ndata matches 'startme.*'\nplumb to nostart\nplumb start /dis/nonexistent.dis $0\n\n";
	r2 := "kind is text\ndata matches '.*'\nplumb to edit\n";
	fd := sys->open("/chan/plumb.rules", Sys->OWRITE);
	if(fd == nil)
		t.fatal(sys->sprint("open /chan/plumb.rules: %r"));
	b1 := array of byte r1;
	b2 := array of byte r2;
	t.assert(sys->write(fd, b1, len b1) == len b1, "the first piece of a rule set is taken");
	t.assert(sys->write(fd, b2, len b2) == len b2, sys->sprint("and the second: %r"));
	fd = nil;
	rfd := sys->open("/chan/plumb.rules", Sys->OREAD);
	buf := array[8192] of byte;
	n := sys->read(rfd, buf, len buf);
	rules := "";
	if(n > 0)
		rules = string buf[0:n];
	t.assert(has(rules, "plumb to nostart") && has(rules, "plumb to edit"), "the rules are both pieces: " + rules);
	b3 := array of byte "kind is text\nthis is not a rule\n";
	wfd := sys->open("/chan/plumb.rules", Sys->OWRITE);
	t.assert(sys->write(wfd, b3, len b3) < 0, "rules that are none are refused");
	t.assert(plumbin("", "/a/routed") > 0, "a message is routed by them");
	m := next(t);
	t.assertseq(string m.data, "/a/routed", "to edit");
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testSeveral(t: ref T)
{
	spawn hostplumb(nil, hostmsg("/a", "", "/a/one") :: hostmsg("/a", "addr=3", "/a/two") :: nil);
	m := next(t);
	t.assertseq(string m.data, "/n/local/a/one", "first of a stream");
	m = next(t);
	t.assertseq(string m.data, "/n/local/a/two:3", "second of a stream");
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

	sh = load Sh Sh->PATH;
	if(sh == nil)
		raise "fail:cannot load sh";
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	if(plumbmsg == nil)
		raise "fail:cannot load plumbmsg";
	received = chan of ref Msg;

	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#splumber", "/chan", Sys->MBEFORE|Sys->MCREATE) < 0)
		raise sys->sprint("skip:cannot bind #splumber: %r");
	fd := sys->create(RULES, Sys->OWRITE, 8r644);
	if(fd == nil)
		raise sys->sprint("skip:cannot create %s: %r", RULES);
	rules := "kind is text\ndata matches 'startme.*'\nplumb to nostart\nplumb start /dis/nonexistent.dis $0\n\n" +
		"kind is text\ndata matches '.*'\nplumb to edit\n";
	sys->write(fd, array of byte rules, len array of byte rules);
	fd = nil;
	sync := chan of int;
	spawn startplumber(sync);
	if(<-sync == 0)
		raise "skip:" + loaderr;

	run("Refused", testRefused);
	run("Held", testHeld);
	run("Absolute", testAbsolute);
	run("Relative", testRelative);
	run("Root", testRoot);
	run("OtherHost", testOtherHost);
	run("BadHost", testBadHost);
	run("Several", testSeveral);
	run("Plain", testPlain);
	run("PlainWindows", testPlainWindows);
	run("DotDot", testDotDot);
	run("Unrooted", testUnrooted);
	run("Garbage", testGarbage);
	run("StartFails", testStartFails);
	run("RulesInPieces", testRulesInPieces);
	run("Oversize", testOversize);

	# the plumber's processes would keep the emulator up
	killplumber();
	sys->remove(RULES);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
