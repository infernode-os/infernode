implement VoicemodeTest;

#
# voicemode daemon state machine (Phase 1.4/1.6), driven against a mock file
# tree instead of live luciuisrv/speech9p. Plain files give always-ready
# reads; the daemon's poll fallback (no /event file in the mock ui) and its
# pacing sleeps make that workable. Covers: idle-until-voice-mode, partial
# records not injected, final transcript injection through conversation/
# voiceinput, spoken "keyboard" control intent, and idle return on
# input-mode "k".
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

VoicemodeDaemon: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

VoicemodeTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with VoicemodeDaemon
};

SRCFILE: con "/tests/voicemode_test.b";
VMPATH: con "/dis/voicemode.dis";
MOCKUI: con "/tmp/voicemode_test_ui";
MOCKSPEECH: con "/tmp/voicemode_test_speech";

passed := 0;
failed := 0;
skipped := 0;

daemonpid := -1;

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

# Truncating write — mock state changes must not leave residue from longer
# previous contents (a stale tail would corrupt the next parsed record).
createfile(path, data: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	b := array of byte data;
	if(len b == 0)
		return 0;
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

# Poll until path's content contains sub, or timeout (ms). Returns 1 on hit.
waitfor(path, sub: string, timeout: int): int
{
	for(waited := 0; waited < timeout; waited += 100) {
		if(hassubstr(readfile(path), sub))
			return 1;
		sys->sleep(100);
	}
	return hassubstr(readfile(path), sub);
}

mkmock()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MOCKUI, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(MOCKUI + "/activity", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(MOCKUI + "/activity/0", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(MOCKUI + "/activity/0/context", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(MOCKUI + "/activity/0/conversation", Sys->OREAD, Sys->DMDIR | 8r755);
	createfile(MOCKUI + "/input-mode", "k");
	createfile(MOCKUI + "/activity/current", "0");
	createfile(MOCKUI + "/activity/0/context/ctl", "");
	createfile(MOCKUI + "/activity/0/conversation/voiceinput", "");
	createfile(MOCKSPEECH + "/wake", "wake hey_lucia 0.9\n");
	createfile(MOCKSPEECH + "/listen", "partial warming up\n");
	createfile(MOCKSPEECH + "/cancel", "");
}

rundaemon(pidch: chan of int)
{
	pidch <-= sys->pctl(Sys->NEWPGRP, nil);
	vm := load VoicemodeDaemon VMPATH;
	if(vm == nil) {
		sys->fprint(sys->fildes(2), "cannot load voicemode: %r\n");
		return;
	}
	vm->init(nil, "voicemode" :: "-u" :: MOCKUI :: "-s" :: MOCKSPEECH :: nil);
}

startdaemon()
{
	sys->create(MOCKSPEECH, Sys->OREAD, Sys->DMDIR | 8r755);
	mkmock();
	pidch := chan of int;
	spawn rundaemon(pidch);
	daemonpid = <-pidch;
	sys->sleep(300);
}

stopdaemon()
{
	if(daemonpid < 0)
		return;
	fd := sys->open("/prog/" + string daemonpid + "/ctl", Sys->OWRITE);
	if(fd != nil) {
		b := array of byte "killgrp";
		sys->write(fd, b, len b);
	}
	daemonpid = -1;
}

testIdleUntilVoiceMode(t: ref T)
{
	# input-mode is "k": the pre-spawned daemon must not touch the speech
	# or ui files.
	sys->sleep(700);
	ctx := readfile(MOCKUI + "/activity/0/context/ctl");
	t.assert(!hassubstr(ctx, "via=voice-mode"), "daemon idle while input-mode is k");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "warming"), "no injection while idle");
}

testActivatesOnVoiceMode(t: ref T)
{
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "via=voice-mode", 5000),
		"daemon activates and reports voice status after input-mode v");
	# Wake fires (mock is always ready) which must cut any active TTS.
	t.assert(waitfor(MOCKSPEECH + "/cancel", "cancel", 3000),
		"wake event writes speech cancel (barge-in path)");
}

testPartialNotInjected(t: ref T)
{
	# listen still returns a partial record; the daemon must keep waiting
	# rather than submitting the hypothesis as a user turn.
	sys->sleep(1000);
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "warming"), "partial record is not injected");
}

testFinalInjected(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final hello from voice\n");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"hello from voice", 5000),
		"final transcript injected into conversation/voiceinput");
}

testSpokenKeyboardIntent(t: ref T)
{
	# "keyboard" is a control intent: it returns input to keyboard mode
	# instead of becoming a chat turn.
	createfile(MOCKSPEECH + "/listen", "final keyboard\n");
	t.assert(waitfor(MOCKUI + "/input-mode", "k", 5000),
		"spoken keyboard intent flips input-mode back to k");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=idle", 5000),
		"voice status returns to idle after exit");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "keyboard"), "control intent was not injected as a turn");
}

testReentryAndInputModeExit(t: ref T)
{
	# Re-enter voice mode, then exit via an external input-mode write (the
	# path Esc in lucifer and "/voice mode off" in lucibridge use).
	createfile(MOCKSPEECH + "/listen", "partial nothing yet\n");
	createfile(MOCKUI + "/activity/0/context/ctl", "");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "via=voice-mode", 5000),
		"daemon re-activates on second input-mode v");
	createfile(MOCKSPEECH + "/cancel", "");
	createfile(MOCKUI + "/input-mode", "k");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=idle", 5000),
		"external input-mode k returns daemon to idle");
	t.assert(waitfor(MOCKSPEECH + "/cancel", "cancel", 3000),
		"exit cancels any in-flight speech");
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

	startdaemon();
	run("IdleUntilVoiceMode", testIdleUntilVoiceMode);
	run("ActivatesOnVoiceMode", testActivatesOnVoiceMode);
	run("PartialNotInjected", testPartialNotInjected);
	run("FinalInjected", testFinalInjected);
	run("SpokenKeyboardIntent", testSpokenKeyboardIntent);
	run("ReentryAndInputModeExit", testReentryAndInputModeExit);
	stopdaemon();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
