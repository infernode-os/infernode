implement SpeechKokoroTest;

#
# Kokoro TTS engine plumbing (Phase 1.1/1.6) through the unified provider
# stack: engine kokoro delegates say/voices to the speechshim9p provider
# mount, which runs the helper. The real kokoro helper is an external host
# install and is never vendored, so this exercises engine selection, voice
# configuration, provider voices listing, and the say path's status
# reporting with a fake helper — the smoke contract that survives on a
# machine with no speech stack installed.
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

SpeechKokoroTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with Speech9pSrv
};

SRCFILE: con "/tests/speech_kokoro_test.b";
SRVPATH: con "/dis/veltro/speech9p.dis";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
MNT: con "/tmp/speech_kokoro_test";
SHIMMNT: con "/tmp/speech_kokoro_test_shim";

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

writesayread(path, data: string): string
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return nil;
	b := array of byte data;
	if(sys->write(fd, b, len b) < 0)
		return nil;
	sys->seek(fd, big 0, Sys->SEEKSTART);
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
	spawn srv->init(nil, "speech9p" :: "-m" :: MNT :: "-e" :: "kokoro" :: "-v" :: "af_bella" :: nil);
	sys->sleep(300);
	writefile(MNT + "/ctl", "provider " + SHIMMNT);
}

testEngineSelection(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "engine kokoro"), "ctl reports kokoro engine");
	t.assert(hassubstr(ctl, "voice af_bella"), "ctl reports kokoro default voice");
	t.assert(writefile(MNT + "/ctl", "voice am_adam") > 0, "kokoro voice id passes through");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "voice am_adam"), "ctl reports updated voice");
	t.assert(writefile(MNT + "/ctl", "voice af_bella") > 0, "restore default voice");
}

testVoicesListing(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/echo af_bella am_adam") > 0,
		"configure fake kokoro helper");
	voices := readfile(MNT + "/voices");
	t.assert(voices != nil && len voices > 0, "voices readable with kokoro engine");
	t.assert(hassubstr(voices, "af_bella"), "voices includes helper output");
}

testSayStatus(t: ref T)
{
	# The fake helper emits text instead of PCM; the say path must still
	# produce a readable status (playback succeeds or reports an error —
	# either way the write-then-read contract holds and nothing hangs).
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/echo") > 0,
		"configure fake kokoro helper");
	status := writesayread(MNT + "/say", "hello from kokoro test");
	t.assert(status != nil, "say status readable after kokoro synthesis");
}

testEngineSwitchRoundTrip(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "engine cmd") > 0, "switch to cmd engine");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "engine cmd"), "ctl reports cmd engine");
	t.assert(writefile(MNT + "/ctl", "engine kokoro") > 0, "switch back to kokoro");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "engine kokoro"), "ctl reports kokoro engine again");
}

killmodule(name: string)
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			pid := dirs[i].name;
			status := readfile("/prog/" + pid + "/status");
			if(!hassubstr(status, name))
				continue;
			ctl := sys->open("/prog/" + pid + "/ctl", Sys->OWRITE);
			if(ctl != nil)
				sys->fprint(ctl, "killgrp");
		}
	}
}

teardown()
{
	# Unmount both servers so their serveloops see EOF and exit —
	# otherwise emu never halts after the tests finish.
	sys->unmount(nil, MNT);
	sys->sleep(100);
	sys->unmount(nil, SHIMMNT);
	sys->sleep(100);
	# The provider say path can leave the shim's released process group
	# referenced after its mount is gone; do not let test cleanup hang emu.
	killmodule("Speechshim9p");
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
	run("EngineSelection", testEngineSelection);
	run("VoicesListing", testVoicesListing);
	run("SayStatus", testSayStatus);
	run("EngineSwitchRoundTrip", testEngineSwitchRoundTrip);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
