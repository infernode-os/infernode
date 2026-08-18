implement VoiceScriptsTest;

#
# voice_scripts_test — pin the shape of the voice/* rc scripts so a
# refactor doesn't silently drop the audioctl buffer-cap writes
# (INFR-194) or change the mount/cat structure (INFR-195's prewarm
# lives inside the listen block; if someone moves it out the bridge
# regresses to "phone-mic-can't-reach-Mac-speaker").
#
# These are not full integration tests — those need real audio
# hardware + TCC permission on macOS and a connected phone, which is
# tracked separately. What this test catches: someone edits one of
# the rc scripts and accidentally removes a load-bearing line.
#
# What's verified:
#   - lib/voice/listen exists, loads std, binds devaudio, writes
#     both buffer-cap verbs to /dev/audioctl, calls listen.
#   - lib/voice/dial exists, binds devaudio, writes buffer-cap
#     verbs, calls mount.
#   - lib/voice/test-tone exists (single-shell loopback recipe).
#   - speech-terminal / speech-engine / speech-capture automate the documented
#     remote speech namespace topologies without embedding host policy.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

VoiceScriptsTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/voice_scripts_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip"  => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Read the whole script file into a single string. Bails the test with
# fail:fatal if the file is missing — that's a stronger signal than
# "well, this assertion would have passed if the file had existed."
script_contents(t: ref T, path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		t.fatal(sys->sprint("%s not present", path));
		raise "fail:fatal";
	}
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) break;
		out += string buf[:n];
	}
	return out;
}

contains(haystack, needle: string): int
{
	if(len needle == 0) return 1;
	for(i := 0; i + len needle <= len haystack; i++)
		if(haystack[i:i+len needle] == needle)
			return 1;
	return 0;
}

testListenShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/listen");
	t.assert(contains(s, "load std"),
		"voice/listen loads the std sh module");
	t.assert(contains(s, "bind -a '#A' /dev"),
		"voice/listen binds devaudio onto /dev");
	t.assert(contains(s, "play_buffer_ms 100"),
		"voice/listen writes INFR-194 playback buffer cap");
	t.assert(contains(s, "rec_buffer_ms 100"),
		"voice/listen writes INFR-194 capture buffer cap");
	t.assert(contains(s, "listen "),
		"voice/listen calls listen builtin");
	t.assert(contains(s, "export /dev"),
		"voice/listen exports /dev");
}

testDialShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/dial");
	t.assert(contains(s, "load std"),
		"voice/dial loads the std sh module");
	t.assert(contains(s, "bind -a '#A' /dev"),
		"voice/dial binds devaudio onto /dev");
	t.assert(contains(s, "play_buffer_ms 100"),
		"voice/dial writes INFR-194 playback buffer cap");
	t.assert(contains(s, "rec_buffer_ms 100"),
		"voice/dial writes INFR-194 capture buffer cap");
	t.assert(contains(s, "mount "),
		"voice/dial calls mount");
	t.assert(contains(s, "/n/voice/audio"),
		"voice/dial references the mounted /n/voice/audio file");
	t.assert(contains(s, "/dev/audio"),
		"voice/dial references the local /dev/audio file");
}

testTestToneShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/test-tone");
	t.assert(contains(s, "audiotone"),
		"voice/test-tone invokes audiotone");
	t.assert(contains(s, "tcp!127.0.0.1!"),
		"voice/test-tone targets the loopback");
}

testSpeechTerminalShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-terminal");
	t.assert(contains(s, "sh /lib/voice/listen"),
		"speech-terminal exports local audio through voice/listen");
	t.assert(contains(s, "mount -A $engine $provider"),
		"speech-terminal mounts the remote provider");
	t.assert(contains(s, "echo 'provider '$provider > /n/speech/ctl"),
		"speech-terminal selects the mounted provider");
	t.assert(contains(s, "echo 'duplex half' > /n/speech/ctl"),
		"speech-terminal preserves the half-duplex default");
}

testSpeechEngineShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-engine");
	t.assert(contains(s, "mount -A $terminal $termmnt"),
		"speech-engine imports terminal audio");
	t.assert(contains(s, "speechshim9p -m $provider"),
		"speech-engine starts a provider at an isolated mount");
	t.assert(contains(s, "echo 'audiodev '$termmnt'/audio' > $provider/ctl"),
		"speech-engine routes playback and default capture through imported audio");
	t.assert(contains(s, "echo 'micmode device' > $provider/ctl"),
		"speech-engine enables namespace-backed PCM capture");
	t.assert(contains(s, "export $provider"),
		"speech-engine exports the provider contract");
}

testSpeechCaptureShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-capture");
	t.assert(contains(s, "mount -A $capture $capturemnt"),
		"speech-capture imports a remote device tree");
	t.assert(contains(s, "echo 'capturedev '$capturemnt'/audio' > /n/speech/ctl"),
		"speech-capture changes capture without changing playback");
	t.assert(contains(s, "echo 'micmode device' > /n/speech/ctl"),
		"speech-capture enables device-fed helpers");
}

testSpeechTestUsesInstalledCtl(t: ref T)
{
	launcher := script_contents(t, "/tools/speech-test.sh");
	t.assert(contains(launcher, "speech.ctl.sh"),
		"headless speech test discovers the installer-selected ctl file");
	t.assert(contains(launcher, "-C"),
		"headless speech test passes the selected ctl file to speechtest");

	boot := script_contents(t, "/lib/lucifer/boot.sh");
	t.assert(contains(boot, "$speechhelperbin^/../speech.ctl.sh"),
		"GUI speech test prefers the ctl file adjacent to its helper bin");
}

testVoiceDraftPresentation(t: ref T)
{
	conv := script_contents(t, "/appl/cmd/luciconv.b");
	t.assert(contains(conv, "draft-status"),
		"conversation reads the voice draft status");
	t.assert(contains(conv, "voice-draft"),
		"voice hypotheses render as a conversation turn");
	t.assert(contains(conv, "not sent"),
		"the pending voice turn is explicitly marked unsent");
	t.assert(contains(conv, "voiceactive() && k != 0"),
		"keyboard compose edits are locked while voice owns the turn");

	boot := script_contents(t, "/appl/cmd/lucifer.b");
	t.assert(contains(boot, "convEvCh <-= ev"),
		"global input-mode changes reach the conversation UI");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2),
			"cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ListenShape", testListenShape);
	run("DialShape", testDialShape);
	run("TestToneShape", testTestToneShape);
	run("SpeechTerminalShape", testSpeechTerminalShape);
	run("SpeechEngineShape", testSpeechEngineShape);
	run("SpeechCaptureShape", testSpeechCaptureShape);
	run("SpeechTestUsesInstalledCtl", testSpeechTestUsesInstalledCtl);
	run("VoiceDraftPresentation", testVoiceDraftPresentation);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
