implement Msg9pStreamTest;

#
# msg9p's notify file and its sources, with a source of the test's own
# (tests/msg_probesrc.b).
#
# notify is a stream: each read is the next notification, whatever the
# offset. It answered by offset, so a second read on one descriptor (as
# cat makes) got the last byte of the next notification, or nothing, and
# that notification was gone.
#
# A notification is bounded. One with a subject of 20000 characters,
# sent to a reader waiting in its read, was larger than a 9P message:
# the reader was told "Styx reply didn't fit" and the notification was
# lost.
#
# A source unregistered while it is notifying does not stop the server.
# Unregister sent its stop from the serve loop to a wrapper that was
# itself waiting for the serve loop to take a notification: neither
# moved again, and nothing under /mnt/msg answered until msg9p was
# restarted. Notifications dropped because nobody reads are counted in
# status.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Msg9pStreamTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/msg9p_stream_test.b";
M: con "/mnt/msg";
PROBE: con "/tests/msg_probesrc.dis";

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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# One read of fd, or "timeout" after ms; an error as "error: ...".
readone(fd: ref Sys->FD, ms: int): string
{
	c := chan[1] of string;
	spawn reader(fd, c);
	spawn timer(c, ms);
	return <-c;
}

reader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	s: string;
	if(n < 0)
		s = sys->sprint("error: %r");
	else
		s = string buf[0:n];
	alt { c <-= s => ; * => ; }
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt { c <-= "timeout" => ; * => ; }
}

# A write to a file of /mnt/msg, or "timeout".
writeone(path, data: string, ms: int): string
{
	c := chan[1] of string;
	spawn writer(path, data, c);
	spawn timer(c, ms);
	return <-c;
}

writer(path, data: string, c: chan of string)
{
	s := "ok";
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		s = sys->sprint("error: open: %r");
	else {
		b := array of byte data;
		if(sys->write(fd, b, len b) < 0)
			s = sys->sprint("error: %r");
	}
	alt { c <-= s => ; * => ; }
}

readfile(path: string, ms: int): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: open: %r");
	return readone(fd, ms);
}

testStream(t: ref T)
{
	t.assertseq(writeone(M + "/ctl", "register three " + PROBE + " mode=three", 5000), "ok",
		"source registered");
	sys->sleep(300);
	fd := sys->open(M + "/notify", Sys->OREAD);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open notify: %r"));
		return;
	}
	a := readone(fd, 5000);
	t.assert(contains(a, "Message ID: A\n"), "the first read is the first notification");
	b := readone(fd, 5000);
	t.assert(hasprefix(b, "[Message notification") && contains(b, "Message ID: B\n"),
		sys->sprint("the second read on the same descriptor is the second, whole (%d bytes: %s)",
			len b, b));
	fd2 := sys->open(M + "/notify", Sys->OREAD);
	c := readone(fd2, 5000);
	t.assert(contains(c, "Message ID: C\n"), "and a fresh descriptor gets the third");
	t.assertseq(writeone(M + "/ctl", "unregister three", 5000), "ok", "unregistered");
}

testBig(t: ref T)
{
	fd := sys->open(M + "/notify", Sys->OREAD);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open notify: %r"));
		return;
	}
	t.assertseq(writeone(M + "/ctl", "register big " + PROBE + " mode=big", 5000), "ok",
		"source registered");
	# waiting in the read when the notification comes
	bn := readone(fd, 10000);
	t.assert(hasprefix(bn, "[Message notification"),
		"a notification with a 20000-character subject is read: " + bn[0:min(len bn, 60)]);
	t.assert(contains(bn, "Subject: SSSS") && contains(bn, "Message ID: BIG\n"),
		"with the start of its subject and its id");
	t.assert(len bn < 4096, sys->sprint("bounded (%d characters)", len bn));
	after := readone(fd, 5000);
	t.assert(contains(after, "Message ID: AFTERBIG\n"), "the next notification follows it");
	t.assertseq(writeone(M + "/ctl", "unregister big", 5000), "ok", "unregistered");
}

testUnregisterWhileNotifying(t: ref T)
{
	t.assertseq(writeone(M + "/ctl", "register flood " + PROBE + " mode=flood", 5000), "ok",
		"flooding source registered");
	sys->sleep(500);
	t.assertseq(writeone(M + "/ctl", "unregister flood", 10000), "ok",
		"unregister returns while the source is notifying");
	st := readfile(M + "/status", 10000);
	t.assert(st != "timeout" && !hasprefix(st, "error:"), "status answers afterwards: " + st);
	t.assert(contains(st, "dropped"), "and says notifications were dropped: " + st);
	t.assert(!contains(st, "flood:"), "the source is gone from status");
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
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

	# a msg9p of the test's own, in a name space of its own (started
	# through Sh: see wallet_policy_test.b's startserver)
	sys->pctl(Sys->FORKNS, nil);
	sh := load Sh Sh->PATH;
	if(sh == nil)
		raise "fail:cannot load sh";
	if((err := sh->system(nil, "/dis/veltro/msg9p.dis >[2] /dev/null")) != nil)
		raise "fail:msg9p: " + err;
	(ok, nil) := sys->stat(M + "/notify");
	if(ok < 0)
		raise "fail:no msg9p at " + M;

	run("Notify/Stream", testStream);
	run("Notify/Bounded", testBig);
	run("Source/UnregisterWhileNotifying", testUnregisterWhileNotifying);

	sys->unmount(nil, M);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
