implement Speech9pSayTest;

#
# speech9p's say and ctl files, with the API engine pointed at a server
# of the test's own on the loopback (no host program is run, nothing is
# spoken).
#
# An utterance's status is kept for whoever reads it, and the process
# that made it ends whether or not anyone does: the say tool never reads
# the status, and every utterance left a process waiting for good to
# hand it over (thirty says, thirty processes). Only so many utterances
# are in progress at once (each is a host process or a connection);
# there was no limit. A ctl command that is refused is an error to its
# writer: the write succeeded whatever happened. A failed API request
# says why.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Speech9pSayTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/speech9p_say_test.b";

passed := 0;
failed := 0;
skipped := 0;

mnt: string;
hold := 0;	# the server keeps a connection this many ms before closing it

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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# The API: takes a connection and closes it, at once or after hold ms,
# with no answer.
server(ac: Sys->Connection)
{
	for(;;) {
		(ok, nc) := sys->listen(ac);
		if(ok < 0)
			return;
		dfd := sys->open(nc.dir + "/data", Sys->ORDWR);
		if(dfd != nil)
			spawn serve1(dfd, hold);
	}
}

serve1(dfd: ref Sys->FD, ms: int)
{
	if(ms > 0)
		sys->sleep(ms);
	dfd = nil;
}

# speech9p's processes waiting to send
sending(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	count := 0;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			sfd := sys->open("/prog/" + dirs[i].name + "/status", Sys->OREAD);
			if(sfd == nil)
				continue;
			buf := array[256] of byte;
			m := sys->read(sfd, buf, len buf);
			if(m <= 0)
				continue;
			st := string buf[0:m];
			if(contains(st, "Speech9p") && contains(st, " send "))
				count++;
		}
	}
	return count;
}

# write text to say on a descriptor of its own; nil, or the error
say(text: string): string
{
	fd := sys->open(mnt + "/say", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open: %r");
	b := array of byte text;
	if(sys->write(fd, b, len b) < 0)
		return sys->sprint("%r");
	return nil;
}

testNoProcsLeft(t: ref T)
{
	if(sending() < 0) {
		t.skip("no /prog here");
		return;
	}
	hold = 0;
	for(i := 0; i < 12; i++) {
		err := say("hello " + string i);
		if(err != nil)
			sys->sleep(200);	# the cap: wait for some to finish
	}
	sys->sleep(1500);
	t.asserteq(sending(), 0, "no process of speech9p is left waiting to send");
}

testStatusSaysWhy(t: ref T)
{
	hold = 0;
	fd := sys->open(mnt + "/say", Sys->ORDWR);
	if(fd == nil) {
		t.fatal(sys->sprint("open say: %r"));
		return;
	}
	b := array of byte "hello";
	t.assert(sys->write(fd, b, len b) > 0, "say written");
	buf := array[512] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	st := "";
	if(n > 0)
		st = string buf[0:n];
	t.assert(contains(st, "error: API request failed: ") && contains(st, "no answer"),
		"the status of a failed request says why: " + st);
}

testCap(t: ref T)
{
	sys->sleep(500);
	hold = 3000;
	ok := 0;
	refused := 0;
	why := "";
	for(i := 0; i < 10; i++) {
		err := say("held " + string i);
		if(err == nil)
			ok++;
		else {
			refused++;
			why = err;
		}
	}
	t.asserteq(ok, 4, "four utterances are in progress at once");
	t.asserteq(refused, 6, "the rest are refused");
	t.assert(contains(why, "too many utterances"), "saying why: " + why);
	sys->sleep(4000);
	hold = 0;
	t.assertnil(say("after"), "and another is taken once they are done");
}

testCtlRefusals(t: ref T)
{
	wr := array[] of {"engine api", "rate 1", "cmdtts touch /tmp/x", "voice ../x", "nosuchkey 1"};
	for(i := 0; i < len wr; i++) {
		fd := sys->open(mnt + "/ctl", Sys->OWRITE);
		b := array of byte wr[i];
		t.assert(fd != nil && sys->write(fd, b, len b) < 0,
			"a refused ctl command is an error to its writer: " + wr[i]);
	}
	fd := sys->open(mnt + "/ctl", Sys->OWRITE);
	b := array of byte "voice okvoice";
	t.assert(fd != nil && sys->write(fd, b, len b) > 0, "a command that is taken succeeds");
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

	sys->pctl(Sys->FORKNS, nil);
	sys->bind("#I", "/net", Sys->MAFTER);
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0) {
		sys->print("SKIP: no loopback announce here: %r\n");
		raise "skip:no IP stack";
	}
	lfd := sys->open(ac.dir + "/local", Sys->OREAD);
	buf := array[64] of byte;
	n := 0;
	if(lfd != nil)
		n = sys->read(lfd, buf, len buf);
	if(n <= 0)
		raise "fail:no local address";
	local := string buf[0:n];
	port := "";
	for(i := 0; i < len local; i++)
		if(local[i] == '!')
			port = local[i+1:];
	while(len port > 0 && (port[len port - 1] == '\n' || port[len port - 1] == ' '))
		port = port[0:len port - 1];
	spawn server(ac);

	mnt = sys->sprint("/tmp/speech9p_say_test.%d", sys->pctl(0, nil));
	sh := load Sh Sh->PATH;
	if(sh == nil)
		raise "fail:cannot load sh";
	cmd := "/dis/veltro/speech9p.dis -e api -k test-key-not-real -u http://127.0.0.1:" +
		port + " -m " + mnt + " >[2] /dev/null";
	if((err := sh->system(nil, cmd)) != nil)
		raise "fail:speech9p: " + err;
	(sok, nil) := sys->stat(mnt + "/say");
	if(sok < 0)
		raise "fail:no speech9p at " + mnt;

	run("Say/NoProcsLeft", testNoProcsLeft);
	run("Say/StatusSaysWhy", testStatusSaysWhy);
	run("Say/Cap", testCap);
	run("Ctl/Refusals", testCtlRefusals);

	sys->unmount(nil, mnt);
	sys->remove(mnt);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
