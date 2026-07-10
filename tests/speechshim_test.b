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
PCMFILE: con "/tmp/speechshim_test_pcm";

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

filesize(path: string): int
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return -1;
	return int d.length;
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

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

readproc(path: string, ch: chan of string)
{
	ch <-= readfile(path);
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
	files := array[] of {"ctl", "listen", "wake", "say", "cancel", "chime", "voices"};
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
testAudioRouting(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev /dev/audio"), "default playback device");
	t.assert(hassubstr(ctl, "micmode helper"), "default capture mode");
	t.assert(hassubstr(ctl, "capturerate 16000"), "default capture rate");

	t.assert(writefile(MNT + "/ctl", "audiodev /n/phone/audio") > 0, "audiodev accepted");
	t.assert(writefile(MNT + "/ctl", "capturerate 24000") > 0, "capturerate accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev /n/phone/audio"), "ctl reports audiodev");
	t.assert(hassubstr(ctl, "capturerate 24000"), "ctl reports capturerate");

	# Invalid values are logged, not applied (ctl writes always succeed).
	writefile(MNT + "/ctl", "micmode banana");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "micmode helper"), "invalid micmode not applied");

	writefile(MNT + "/ctl", "audiodev /dev/audio");
	writefile(MNT + "/ctl", "capturerate 16000");
}

testDuplexConfig(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex full"), "default duplex is full");
	t.assert(writefile(MNT + "/ctl", "duplex half") > 0, "duplex half accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex half"), "ctl reports duplex half");
	t.assert(writefile(MNT + "/ctl", "duplex full") > 0, "duplex full accepted");
	writefile(MNT + "/ctl", "duplex banana");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex full"), "invalid duplex not applied");
}

testChimeAccepted(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;
	t.assert(writefile(MNT + "/ctl", "audiodev " + PCMFILE) > 0, "audiodev scratch accepted");
	t.assert(writefile(MNT + "/chime", "wake") > 0, "wake chime write accepted");
	sys->sleep(500);
	t.assert(filesize(PCMFILE) > 0, "chime wrote PCM bytes");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

# micmode device: the shim itself reads PCM from the capture device and
# feeds the listen helper's stdin — the property that makes a 9P-imported
# microphone (remote instance, Android phone) work like the local one. A
# plain file stands in for the device; the fake helper consumes 8 bytes of
# stdin before emitting its record, so the record proves audio actually
# flowed capture-device → pump → helper stdin.
testDeviceCapture(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake capture device");
	if(fd == nil)
		return;
	b := array of byte "0123456789abcdef";
	sys->write(fd, b, len b);
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "capturedev " + PCMFILE) > 0, "capturedev accepted");
	t.assert(writefile(MNT + "/ctl", "micmode device") > 0, "micmode device accepted");
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"head -c 8 > /dev/null; echo final device audio heard\"") > 0,
		"configure stdin-consuming fake listen helper");

	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final device audio heard"),
		"helper fed from the capture device produced its record");

	# Restore defaults for the remaining tests.
	writefile(MNT + "/ctl", "micmode helper");
	writefile(MNT + "/ctl", "capturedev default");
}

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

testHalfDuplexSwallowsWakeDuringSay(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "audiodev " + PCMFILE) > 0, "audiodev scratch accepted");
	t.assert(writefile(MNT + "/ctl", "duplex half") > 0, "duplex half accepted");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"printf 0123456789; sleep 2; printf abcdef\"") > 0,
		"configure slow fake synthesizer");
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake fake-model 0.92") > 0,
		"configure immediate fake wake helper");

	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens");
	if(sayfd == nil)
		return;
	b := array of byte "hello";
	t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
	sys->sleep(300);	# let dosay enter its playback loop

	wakech := chan of string;
	spawn readproc(MNT + "/wake", wakech);
	tmo := chan[1] of int;
	spawn timer(tmo, 900);
	early := "";
	alt {
	early = <-wakech =>
		;
	<-tmo =>
		;
	}
	t.assert(early == "", "wake read suppressed during half-duplex playback");

	tmo2 := chan[1] of int;
	spawn timer(tmo2, 5000);
	got := "";
	alt {
	got = <-wakech =>
		;
	<-tmo2 =>
		;
	}
	t.assert(hassubstr(got, "wake fake-model 0.92"),
		"wake read completes after playback");

	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	sys->read(sayfd, buf, len buf);
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
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
	run("AudioRouting", testAudioRouting);
	run("DuplexConfig", testDuplexConfig);
	run("ChimeAccepted", testChimeAccepted);
	run("WakeRestarts", testWakeRestarts);
	run("ListenRecords", testListenRecords);
	run("DeviceCapture", testDeviceCapture);
	run("CancelKillsSay", testCancelKillsSay);
	run("HalfDuplexSwallowsWakeDuringSay", testHalfDuplexSwallowsWakeDuringSay);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
