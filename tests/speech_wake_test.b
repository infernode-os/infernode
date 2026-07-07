implement SpeechWakeTest;

#
# Wake-word file behavior (Phase 1.3/1.6) through the unified provider
# stack: speech9p consumes /n/speechshim (speechshim9p), which adapts fake
# host helpers configured via the ctl-forwarded wakebin key — no real wake
# model is needed. The central assertion is that a wake read blocked in a
# slow helper does NOT freeze either serveloop: ctl reads and cancel writes
# must still be served while the wake helper runs, because barge-in depends
# on exactly that.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Speech9pSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SpeechWakeTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with Speech9pSrv
};

SRCFILE: con "/tests/speech_wake_test.b";
SRVPATH: con "/dis/veltro/speech9p.dis";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
MNT: con "/tmp/speech_wake_test";
SHIMMNT: con "/tmp/speech_wake_test_shim";

passed := 0;
failed := 0;
skipped := 0;

_marker() {}

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
	"*" =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

strip(s: string): string
{
	if(s == nil)
		return nil;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];
}

hassubstr(s, sub: string): int
{
	if(s == nil || sub == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

reader(path: string, ch: chan of string)
{
	ch <-= readfile(path);
}

startserver()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(SHIMMNT, Sys->OREAD, Sys->DMDIR | 8r755);
	shim := load Speech9pSrv SHIMPATH;
	if(shim == nil) {
		sys->fprint(sys->fildes(2), "cannot load speechshim9p: %r\n");
		raise "fail:load";
	}
	spawn shim->init(nil, "speechshim9p" :: "-m" :: SHIMMNT :: nil);
	srv := load Speech9pSrv SRVPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speech9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speech9p" :: "-m" :: MNT :: "-e" :: "kokoro" :: nil);
	sys->sleep(300);
	writefile(MNT + "/ctl", "provider " + SHIMMNT);
}

testWakeEvent(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake hey_lucia 0.93") > 0,
		"configure fake wake helper");
	wake := readfile(MNT + "/wake");
	t.assert(hassubstr(wake, "wake hey_lucia 0.93"), "wake returns helper event");
}

testWakeHelperEmpty(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/sh -c \"exit 0\"") > 0,
		"configure silent wake helper");
	wake := strip(readfile(MNT + "/wake"));
	t.assert(hassubstr(wake, "error:"), "empty helper output becomes an error record");
}

# The Phase 1 correctness core: while a wake read is blocked in a slow
# helper, the serveloop must keep serving other requests. Before the async
# fix, the ctl read and cancel write below would stall for the full helper
# duration and barge-in was impossible.
testWakeDoesNotBlockServer(t: ref T)
{
	t.assert(writefile(MNT + "/ctl",
		"wakebin /bin/sh -c \"sleep 2; echo wake slow-event\"") > 0,
		"configure slow wake helper");

	ch := chan of string;
	spawn reader(MNT + "/wake", ch);
	sys->sleep(200);	# let the wake read reach the helper

	t0 := sys->millisec();
	ctl := readfile(MNT + "/ctl");
	t1 := sys->millisec();
	t.assert(ctl != nil && len ctl > 0, "ctl readable while wake helper is busy");
	t.assert(t1 - t0 < 1500, "ctl read not stalled behind the wake helper");

	t0 = sys->millisec();
	t.assert(writefile(MNT + "/cancel", "cancel") > 0,
		"cancel write served while wake helper is busy");
	t1 = sys->millisec();
	t.assert(t1 - t0 < 1500, "cancel write not stalled behind the wake helper");

	wake := <-ch;
	t.assert(hassubstr(wake, "wake slow-event"), "slow wake event still delivered");
}

# A second wake read while one is in flight must fail fast instead of
# queueing behind (or corrupting) the running helper.
testWakeBusy(t: ref T)
{
	t.assert(writefile(MNT + "/ctl",
		"wakebin /bin/sh -c \"sleep 2; echo wake busy-event\"") > 0,
		"configure slow wake helper");

	ch := chan of string;
	spawn reader(MNT + "/wake", ch);
	sys->sleep(200);
	second := readfile(MNT + "/wake");
	t.assert(hassubstr(second, "error: wake busy"),
		"concurrent wake read reports busy");
	first := <-ch;
	t.assert(hassubstr(first, "wake busy-event"), "first wake read gets the event");
}

teardown()
{
	# Unmount both servers so their serveloops see EOF and exit —
	# otherwise emu never halts after the tests finish.
	sys->unmount(nil, MNT);
	sys->unmount(nil, SHIMMNT);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil)
		raise "fail:load testing";
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	startserver();
	run("WakeEvent", testWakeEvent);
	run("WakeHelperEmpty", testWakeHelperEmpty);
	run("WakeDoesNotBlockServer", testWakeDoesNotBlockServer);
	run("WakeBusy", testWakeBusy);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
