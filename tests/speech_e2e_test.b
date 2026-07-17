implement SpeechE2ETest;

#
# Composed voice-mode integration test. The real Lucia, LLM, speech9p,
# speechshim9p, lucibridge, and voicemode services run together. External
# speech models are replaced by tests/host/speech_e2e_helper.sh, and the
# OpenAI-compatible endpoint is supplied by speech_e2e_test.sh.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";
	arg: Arg;

include "testing.m";
	testing: Testing;
	T: import testing;

Command: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SpeechE2ETest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE: con "/tests/speech_e2e_test.b";

passed := 0;
failed := 0;
skipped := 0;

apiurl: string;
hoststate: string;
infernostate: string;
helper: string;

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

createfile(path: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	return 0;
}

createwithdata(path, data: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
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
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

contains(s, sub: string): int
{
	if(s == nil || sub == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

pathexists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

waitpath(path: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(pathexists(path))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

waitcontains(path, sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(contains(readfile(path), sub))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

conversationrolecount(role, sub: string): int
{
	n := 0;
	for(i := 0; i < 12; i++) {
		msg := readfile("/mnt/ui/activity/0/conversation/" + string i);
		if(contains(msg, "role=" + role) && contains(msg, sub))
			n++;
	}
	return n;
}

waitconversationrole(role, sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(conversationrolecount(role, sub) > 0)
			return 1;
		sys->sleep(50);
	}
	return 0;
}

resourcecontains(sub: string): int
{
	for(i := 0; i < 20; i++) {
		resource := readfile("/mnt/ui/activity/0/context/resources/" + string i);
		if(resource == nil)
			break;
		if(contains(resource, sub))
			return 1;
	}
	return 0;
}

waitresource(sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(resourcecontains(sub))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

startmodule(t: ref T, path, name: string, args: list of string)
{
	cmd := load Command path;
	if(cmd == nil)
		t.fatal("cannot load " + path + ": " + sys->sprint("%r"));
	spawn cmd->init(nil, name :: args);
}

preparemounts()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create("/mnt", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/n", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/ui", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/llm", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/n/speechshim", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/n/speech", Sys->OREAD, Sys->DMDIR | 8r755);
}

startstack(t: ref T)
{
	preparemounts();

	startmodule(t, "/dis/luciuisrv.dis", "luciuisrv", "-m" :: "/mnt/ui" :: nil);
	t.assert(waitpath("/mnt/ui/ctl", 3000), "luciuisrv mounted");

	startmodule(t, "/dis/veltro/speechshim9p.dis", "speechshim9p",
		"-m" :: "/n/speechshim" :: nil);
	t.assert(waitpath("/n/speechshim/ctl", 3000), "speechshim9p mounted");

	cmd := "/bin/sh " + helper;
	t.assert(writefile("/n/speechshim/ctl",
		"wakebin " + cmd + " wake " + hoststate) > 0, "fake wake helper configured");
	t.assert(writefile("/n/speechshim/ctl",
		"whisperstreambin " + cmd + " listen " + hoststate) > 0,
		"fake listen helper configured");
	t.assert(writefile("/n/speechshim/ctl",
		"kokorobin " + cmd + " say " + hoststate) > 0, "fake TTS helper configured");
	t.assert(createfile(infernostate + "/audio.pcm") >= 0, "fake audio sink created");
	t.assert(writefile("/n/speechshim/ctl", "audiodev " + infernostate + "/audio.pcm") > 0,
		"fake audio sink configured");
	t.assert(writefile("/n/speechshim/ctl", "duplex half") > 0,
		"half-duplex provider configured");

	startmodule(t, "/dis/veltro/speech9p.dis", "speech9p",
		"-m" :: "/n/speech" :: "-e" :: "kokoro" :: nil);
	t.assert(waitpath("/n/speech/ctl", 3000), "speech9p mounted");
	t.assert(writefile("/n/speech/ctl", "provider /n/speechshim") > 0,
		"speechshim selected as provider");

	startmodule(t, "/dis/llmsrv.dis", "llmsrv",
		"-m" :: "/mnt/llm" :: "-b" :: "openai" :: "-u" :: apiurl ::
		"-M" :: "ci-voice-e2e" :: "-r" :: "low" :: nil);
	t.assert(waitpath("/mnt/llm/new", 3000), "llmsrv mounted");

	# lucibridge deliberately validates deployment configuration before it
	# trusts /mnt/llm. Overlay a private OpenAI configuration in this test
	# namespace; never read or modify the host user's real configuration.
	config := "mode=local\nbackend=openai\nurl=" + apiurl +
		"\nmodel=ci-voice-e2e\ntemperature=0.2\n";
	t.assert(createwithdata(infernostate + "/llm.ndb", config) > 0,
		"private LLM configuration created");
	t.assert(sys->bind(infernostate + "/llm.ndb", "/lib/ndb/llm", Sys->MREPL) >= 0,
		"private LLM configuration bound");

	t.assert(writefile("/mnt/ui/ctl", "activity create VoiceE2E") > 0,
		"Lucia activity created");
	t.assert(waitpath("/mnt/ui/activity/0/conversation/voiceinput", 3000),
		"voice input endpoint created");

	startmodule(t, "/dis/lucibridge.dis", "lucibridge",
		"-s" :: "-n" :: "3" :: "-a" :: "0" :: nil);
	t.assert(waitresource("label=Voice", 8000),
		"lucibridge initialized its LLM session and speech resource");

	startmodule(t, "/dis/voicemode.dis", "voicemode",
		"-g" :: "300" :: "-q" :: "650" :: "-t" :: "5000" ::
		"-w" :: "50" :: "-u" :: "/mnt/ui" :: "-s" :: "/n/speech" :: nil);
	sys->sleep(300);
}

testComposedTurn(t: ref T)
{
	startstack(t);

	t.assert(writefile(infernostate + "/wake.next", "wake e2e 0.99\n") > 0,
		"wake event scripted");
	t.assert(writefile(infernostate + "/listen.next",
		"partial confidence=940 Reply with exactly local LLM working\n" +
		"final confidence=940 Reply with exactly: local LLM working.\n") > 0,
		"streaming transcript scripted");
	t.assert(writefile("/mnt/ui/input-mode", "v") > 0, "voice mode re-entered");

	t.assert(waitcontains("/mnt/ui/activity/0/conversation/draft",
		"local LLM working", 5000), "live or final transcript reached Lucia draft");
	t.assert(waitconversationrole("human", "local LLM working", 8000),
		"final transcript submitted to lucibridge");
	t.assert(waitconversationrole("veltro", "local LLM working", 12000),
		"local OpenAI response returned to Lucia");
	t.assert(waitcontains(infernostate + "/say.log", "local LLM working", 8000),
		"assistant response reached speech provider");
	t.asserteq(conversationrolecount("human", "local LLM working"), 1,
		"final transcript submitted exactly once");
	t.assert(waitresource("label=Voice", 3000),
		"Voice lifecycle resource is present");

	t.assert(writefile("/mnt/ui/input-mode", "k") > 0, "keyboard mode restored");
	t.assert(waitcontains("/n/speechshim/ctl", "mic off", 3000),
		"microphone released after composed turn");
}

testNeedsWrapper(t: ref T)
{
	t.skip("requires tests/host/speech_e2e_test.sh");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();

	arg = load Arg Arg->PATH;
	if(arg == nil) {
		sys->fprint(sys->fildes(2), "cannot load arg: %r\n");
		raise "fail:load";
	}
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		'u' => apiurl = arg->earg();
		'H' => hoststate = arg->earg();
		'I' => infernostate = arg->earg();
		'X' => helper = arg->earg();
		'v' => testing->verbose(1);
		* => ;
		}

	if(apiurl == nil || hoststate == nil || infernostate == nil || helper == nil)
		run("HostWrapperRequired", testNeedsWrapper);
	else
		run("ComposedVoiceTurn", testComposedTurn);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
