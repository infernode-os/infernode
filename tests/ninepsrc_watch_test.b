implement NinepsrcWatchTest;

#
# ninepsrc, the message source that reads a 9P service's events file,
# loaded here as msg9p loads it, with an events file of the test's own
# (file2chan).
#
# A source told to stop while it waits in a read of the events file
# stops: it looked at its stop channel only between reads, so an
# unregistered source stayed in its read for good, with the file open
# (and its mount), and whoever sent the stop waited with it.
#
# A source that cannot read says so in status and tells of it once: an
# events file it could not open was printed twice a second on stderr and
# nowhere else, status still describing the source as though it read.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "msgsrc.m";

include "testing.m";
	testing: Testing;
	T: import testing;

NinepsrcWatchTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Notification: import MsgSrc;

SRCFILE: con "/tests/ninepsrc_watch_test.b";
SRC: con "/dis/veltro/ninepsrc.dis";

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

closed: chan of int;	# the events file was closed by its reader
nreads := 0;

# The events file: the first read is two events, the second is never
# answered (nothing more has happened).
server(fio: ref Sys->FileIO)
{
	held: Sys->Rread;
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc == nil) {
			alt { closed <-= 1 => ; * => ; }
			continue;
		}
		if(nreads++ == 0)
			rc <-= (array of byte "one\ntwo\n", nil);
		else
			held = rc;
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	}
}

watcher(src: MsgSrc, updates: chan of ref Notification, stop: chan of int, done: chan of int)
{
	src->watch(updates, stop);
	alt { done <-= 1 => ; * => ; }
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { c <-= 0 => ; * => ; }
}

# the next notification, or nil after ms
next(updates: chan of ref Notification, ms: int): ref Notification
{
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt {
	n := <-updates =>
		return n;
	<-tc =>
		return nil;
	}
}

testStopWhileReading(t: ref T)
{
	src := load MsgSrc SRC;
	if(src == nil) {
		t.fatal(sys->sprint("cannot load %s: %r", SRC));
		return;
	}
	t.assertnil(src->init("name=probe mounted=1 mountpt=/n file=events"), "configured");
	updates := chan of ref Notification;
	stop := chan of int;
	done := chan[1] of int;
	spawn watcher(src, updates, stop, done);

	n := next(updates, 5000);
	t.assert(n != nil && n.kind == "new" && n.msg != nil && n.msg.body == "one",
		"the first event is a message");
	n = next(updates, 5000);
	t.assert(n != nil && n.msg != nil && n.msg.body == "two", "and the second");
	t.assert(!contains(src->status(), "not reading"), "status: reading: " + src->status());

	# it is now in a read that nothing answers
	sys->sleep(300);
	tc := chan[1] of int;
	spawn timer(tc, 5000);
	took := 0;
	alt {
	stop <-= 1 =>
		took = 1;
	<-tc =>
		;
	}
	t.assert(took, "a source waiting in its read takes the stop");
	tc = chan[1] of int;
	spawn timer(tc, 5000);
	alt {
	<-done =>
		t.log("watch returned");
	<-tc =>
		t.error("watch did not return after the stop");
	}
	tc = chan[1] of int;
	spawn timer(tc, 5000);
	alt {
	<-closed =>
		t.log("events file closed");
	<-tc =>
		t.error("the events file was left open by the stopped source");
	}
	t.assertnil(src->close(), "closed");
}

testSaysWhenNotReading(t: ref T)
{
	src := load MsgSrc SRC;
	if(src == nil) {
		t.fatal(sys->sprint("cannot load %s: %r", SRC));
		return;
	}
	t.assertnil(src->init("name=absent mounted=1 mountpt=/n file=nosuchfile"), "configured");
	updates := chan of ref Notification;
	stop := chan[1] of int;
	done := chan[1] of int;
	spawn watcher(src, updates, stop, done);

	n := next(updates, 5000);
	t.assert(n != nil && n.kind == "error" && contains(n.detail, "cannot open"),
		"an events file that cannot be opened is an error notification");
	n = next(updates, 2500);
	t.assert(n == nil, "told once, not again while nothing changes");
	st := src->status();
	t.assert(contains(st, "not reading") && contains(st, "cannot open"),
		"status says it is not reading, and why: " + st);
	stop <-= 1;
	tc := chan[1] of int;
	spawn timer(tc, 8000);
	alt {
	<-done =>
		;
	<-tc =>
		t.error("watch did not return after the stop");
	}
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

	# /n is the source's only place for a mount point: here, a
	# directory of files of the test's own
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#s", "/n", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind #s /n: %r");
	fio := sys->file2chan("/n", "events");
	if(fio == nil)
		raise sys->sprint("fail:file2chan: %r");
	closed = chan[1] of int;
	spawn server(fio);

	run("Watch/StopWhileReading", testStopWhileReading);
	run("Watch/SaysWhenNotReading", testSaysWhenNotReading);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
