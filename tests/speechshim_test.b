implement SpeechshimTest;

#
# speechshim9p provider contract test. Fake host helpers stand in for the
# external installs. The load-bearing case is CancelKillsSay: cancel must
# kill the synthesizing helper process (devcmd "kill"), so a blocked say
# completes promptly instead of running out the helper — that bound is what
# makes barge-in silence fast with real TTS.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

ShimSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SpeechshimTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with ShimSrv
};

SRCFILE: con "/tests/speechshim_test.b";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
MNT: con "/tmp/speechshim_test";

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

pathexists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
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

startserver()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	srv := load ShimSrv SHIMPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speechshim9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speechshim9p" :: "-m" :: MNT :: nil);
	sys->sleep(300);
}

testFiles(t: ref T)
{
	files := array[] of {"ctl", "listen", "wake", "say", "cancel", "voices"};
	for(i := 0; i < len files; i++)
		t.assert(pathexists(MNT + "/" + files[i]), files[i] + " should exist");
}

testConfig(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakeword hey lucia") > 0, "wakeword accepted");
	t.assert(writefile(MNT + "/ctl", "wakethreshold 0.7") > 0, "wakethreshold accepted");
	t.assert(writefile(MNT + "/ctl", "voice am_adam") > 0, "voice accepted");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "wakeword hey lucia"), "ctl reports wakeword");
	t.assert(hassubstr(ctl, "wakethreshold 0.7"), "ctl reports wakethreshold");
	t.assert(hassubstr(ctl, "voice am_adam"), "ctl reports voice");
}

# A one-shot helper exits after printing its event; the shim must restart
# it on the next read so wake stays armed across events.
testWakeRestarts(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake fake-model 0.91") > 0,
		"configure fake wake helper");
	first := readfile(MNT + "/wake");
	t.assert(hassubstr(first, "wake fake-model 0.91"), "first wake event delivered");
	second := readfile(MNT + "/wake");
	t.assert(hassubstr(second, "wake fake-model 0.91"),
		"helper restarted for second wake event");
}

testListenRecords(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final shim transcript") > 0,
		"configure fake listen helper");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final shim transcript"), "listen record delivered");
}

# Cancel must kill the helper process: with a fake synthesizer that would
# block for 8 seconds, the pending say read has to complete within a couple
# of seconds of the cancel write.
testCancelKillsSay(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/sh -c \"sleep 8\"") > 0,
		"configure blocking fake synthesizer");

	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens");
	if(sayfd == nil)
		return;
	b := array of byte "hello";
	t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
	sys->sleep(500);	# let the helper start

	t0 := sys->millisec();
	t.assert(writefile(MNT + "/cancel", "cancel") > 0,
		"cancel write served while synthesizing");
	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	n := sys->read(sayfd, buf, len buf);
	t1 := sys->millisec();
	t.assert(n >= 0, "say status readable after cancel");
	t.assert(t1 - t0 < 4000, "cancel killed the helper (no 8s run-out)");
}

teardown()
{
	sys->unmount(nil, MNT);
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
	run("Files", testFiles);
	run("Config", testConfig);
	run("WakeRestarts", testWakeRestarts);
	run("ListenRecords", testListenRecords);
	run("CancelKillsSay", testCancelKillsSay);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
