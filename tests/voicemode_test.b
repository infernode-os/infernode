implement VoicemodeTest;

#
# voicemode daemon state machine (Phase 1.4/1.6), driven against a mock file
# tree instead of live luciuisrv/speech9p. Plain files give always-ready
# reads; the daemon's poll fallback (no /event file in the mock ui) and its
# pacing sleeps make that workable. Covers: idle-until-voice-mode, partial
# records not injected, final transcript injection through conversation/
# voiceinput, spoken "keyboard" control intent, idle return on
# input-mode "k" with a "mic off" ctl write releasing the microphone, and
# LLM-free test mode (-p/-e: finals bypass voiceinput and answer with a
# canned say instead).
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
daemonargs: list of string;

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

runvm(name: string, extra: list of string, testfn: ref fn(t: ref T))
{
	startdaemon(extra);
	run(name, testfn);
	stopdaemon();
	sys->sleep(200);
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

countsubstr(s, sub: string): int
{
	if(s == nil || sub == nil || len sub == 0 || len sub > len s)
		return 0;
	n := 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			n++;
	return n;
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

waitnotfor(path, sub: string, timeout: int): int
{
	for(waited := 0; waited < timeout; waited += 100) {
		if(hassubstr(readfile(path), sub))
			return 0;
		sys->sleep(100);
	}
	return !hassubstr(readfile(path), sub);
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
	createfile(MOCKUI + "/activity/0/status", "working");
	createfile(MOCKUI + "/activity/0/conversation/ctl", "");
	createfile(MOCKUI + "/activity/0/conversation/voiceinput", "");
	createfile(MOCKSPEECH + "/wake", "wake hey_lucia 0.9\n");
	createfile(MOCKSPEECH + "/listen", "partial warming up\n");
	createfile(MOCKSPEECH + "/cancel", "");
	createfile(MOCKSPEECH + "/say", "");
	createfile(MOCKSPEECH + "/ctl", "");
}

rundaemon(pidch: chan of int)
{
	pidch <-= sys->pctl(Sys->NEWPGRP, nil);
	vm := load VoicemodeDaemon VMPATH;
	if(vm == nil) {
		sys->fprint(sys->fildes(2), "cannot load voicemode: %r\n");
		return;
	}
	vm->init(nil, "voicemode" :: "-u" :: MOCKUI :: "-s" :: MOCKSPEECH :: daemonargs);
}

startdaemon(extra: list of string)
{
	daemonargs = extra;
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

testPartialThenFinalInjected(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "partial half\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=listening", 5000),
		"partial record keeps daemon in listening state");
	sys->sleep(300);
	createfile(MOCKSPEECH + "/listen", "partial half\nfinal full transcript\n");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"full transcript", 5000),
		"final after partial is injected");
}

testPartialUpdatesResourceLabel(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "partial half a thou\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl",
		"label=Voice: half a thou type=audio status=listening", 5000),
		"partial transcript updates voice resource label");
	createfile(MOCKSPEECH + "/listen", "final full transcript\n");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl",
		"label=Voice type=audio status=speaking", 5000),
		"final transcript restores voice resource label");
}

testFinalInjected(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final hello from voice\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"hello from voice", 5000),
		"final transcript injected into conversation/voiceinput");
}

testListenTimeoutReturnsToWaiting(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=listening", 5000),
		"daemon enters listening with empty listen stream");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=waiting", 3000),
		"listen timeout returns status to waiting");
}

testWakeDebounce(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final debounce turn\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"debounce turn", 5000),
		"first wake reaches listen and injects final");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=speaking", 3000),
		"completed turn reports speaking before re-arming wake");
	sys->sleep(300);
	t.assert(!hassubstr(readfile(MOCKUI + "/activity/0/context/ctl"), "status=listening"),
		"immediate second wake is debounced instead of starting listen");
}

testJunkFinalNotInjected(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final [BLANK_AUDIO]\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitnotfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"BLANK_AUDIO", 1000),
		"bracketed silence marker is not injected");
	createfile(MOCKSPEECH + "/listen", "final Thank you.\n");
	t.assert(waitnotfor(MOCKUI + "/activity/0/conversation/voiceinput",
		"Thank you", 1200),
		"whisper silence hallucination is not injected");
}

testControlIntentPunctuation(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "partial waiting\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=listening", 5000),
		"daemon is listening before punctuated control intent");
	createfile(MOCKSPEECH + "/cancel", "");
	createfile(MOCKSPEECH + "/listen", "final Stop.\n");
	t.assert(waitfor(MOCKSPEECH + "/cancel", "cancel", 5000),
		"punctuated stop intent cancels speech");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "Stop"), "punctuated control intent is not injected");
}

testYesRequiresBlocked(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final yes\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput", "yes", 5000),
		"bare yes is injected when no approval is blocked");
	createfile(MOCKUI + "/input-mode", "k");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=idle", 5000),
		"daemon exits before blocked approval case");
	createfile(MOCKUI + "/activity/0/status", "blocked");
	createfile(MOCKUI + "/activity/0/conversation/voiceinput", "");
	createfile(MOCKUI + "/activity/0/context/ctl", "");
	createfile(MOCKSPEECH + "/listen", "final yes\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/voiceinput", "Allow", 5000),
		"bare yes maps to Allow only while activity is blocked");
}

testHelperErrorSurfacedOnce(t: ref T)
{
	createfile(MOCKSPEECH + "/wake", "error: wake helper missing\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/activity/0/conversation/ctl", "title=Voice", 6000),
		"third consecutive helper error posts a voice notice");
	msg := readfile(MOCKUI + "/activity/0/conversation/ctl");
	t.assert(countsubstr(msg, "title=Voice") == 1,
		"voice helper notice is written once in the mock conversation ctl");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=error", 1000),
		"helper error surfaces in context status");
}

testSpokenKeyboardIntent(t: ref T)
{
	# "keyboard" is a control intent: it returns input to keyboard mode
	# instead of becoming a chat turn.
	createfile(MOCKSPEECH + "/listen", "final keyboard\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/input-mode", "k", 5000),
		"spoken keyboard intent flips input-mode back to k");
	t.assert(waitfor(MOCKUI + "/activity/0/context/ctl", "status=idle", 5000),
		"voice status returns to idle after exit");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "keyboard"), "control intent was not injected as a turn");
}

testTestModeSpeaksPhrase(t: ref T)
{
	# -p puts the daemon in LLM-free test mode: the final transcript is
	# shown as a "Heard" dialogue line and answered by saying the canned
	# phrase; conversation/voiceinput (the LLM path) is never written.
	createfile(MOCKSPEECH + "/listen", "final hello there\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKSPEECH + "/say", "canned reply", 5000),
		"test-mode final answers with the canned phrase in say");
	t.assert(hassubstr(readfile(MOCKUI + "/activity/0/conversation/ctl"),
		"title=Heard text=hello there"),
		"test-mode final posts the transcript as a Heard dialogue line");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "hello there"),
		"test-mode final is not injected as an LLM turn");
}

testTestModeEchoesTranscript(t: ref T)
{
	createfile(MOCKSPEECH + "/listen", "final echo me back\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKSPEECH + "/say", "echo me back", 5000),
		"-e answers with the transcript itself");
	vi := readfile(MOCKUI + "/activity/0/conversation/voiceinput");
	t.assert(!hassubstr(vi, "echo me back"),
		"-e final is not injected as an LLM turn");
}

testTestModeControlIntentStillWorks(t: ref T)
{
	# Control intents must keep acting on the session in test mode
	# instead of being spoken back.
	createfile(MOCKSPEECH + "/listen", "final keyboard\n");
	createfile(MOCKUI + "/input-mode", "v");
	t.assert(waitfor(MOCKUI + "/input-mode", "k", 5000),
		"spoken keyboard intent exits voice mode in test mode");
	say := readfile(MOCKSPEECH + "/say");
	t.assert(!hassubstr(say, "canned reply"),
		"control intent does not trigger the canned phrase");
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
	t.assert(waitfor(MOCKSPEECH + "/ctl", "mic off", 3000),
		"exit releases the microphone (mic off ctl write)");
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

	runvm("IdleUntilVoiceMode", nil, testIdleUntilVoiceMode);
	runvm("ActivatesOnVoiceMode", nil, testActivatesOnVoiceMode);
	runvm("PartialNotInjected", nil, testPartialNotInjected);
	runvm("PartialThenFinalInjected", nil, testPartialThenFinalInjected);
	runvm("PartialUpdatesResourceLabel", nil, testPartialUpdatesResourceLabel);
	runvm("FinalInjected", nil, testFinalInjected);
	runvm("ListenTimeoutReturnsToWaiting", "-t" :: "500" :: "-w" :: "2000" :: nil,
		testListenTimeoutReturnsToWaiting);
	runvm("WakeDebounce", "-w" :: "1000" :: nil, testWakeDebounce);
	runvm("JunkFinalNotInjected", "-w" :: "200" :: nil, testJunkFinalNotInjected);
	runvm("ControlIntentPunctuation", nil, testControlIntentPunctuation);
	runvm("YesRequiresBlocked", "-w" :: "200" :: nil, testYesRequiresBlocked);
	runvm("HelperErrorSurfacedOnce", nil, testHelperErrorSurfacedOnce);
	runvm("SpokenKeyboardIntent", nil, testSpokenKeyboardIntent);
	runvm("TestModeSpeaksPhrase", "-p" :: "canned reply" :: nil,
		testTestModeSpeaksPhrase);
	runvm("TestModeEchoesTranscript", "-e" :: nil, testTestModeEchoesTranscript);
	runvm("TestModeControlIntentStillWorks", "-p" :: "canned reply" :: nil,
		testTestModeControlIntentStillWorks);
	runvm("ReentryAndInputModeExit", nil, testReentryAndInputModeExit);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
