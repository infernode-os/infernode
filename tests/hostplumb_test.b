implement HostplumbTest;

#
# hostplumb(1) and the plumber's refusal of an undeliverable message.
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
	rules := "kind is text\ndata matches '.*'\nplumb to edit\n";
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

	# the plumber's processes would keep the emulator up
	killplumber();
	sys->remove(RULES);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
