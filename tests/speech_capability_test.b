implement SpeechCapabilityTest;

#
# The say and hear tools' grant of speech(4) (nsconstruct): an agent
# given say sees /mnt/speech's say and voices, one given hear its ask,
# and neither sees listen (everything the user says), talk (the
# microphone's switch), ctl (the engine, and so where the microphone
# goes) or hear (which opens the microphone); a path grant of
# /mnt/speech gives nothing.  The hear tool, waiting, has talk read
# "off asked" and does not open the microphone: the engine is never
# started and talk stays off.  speech9p runs in the test, over the fake
# engine (tests/speechfake.b), with no audio device needed.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "nsconstruct.m";
	nsc: NsConstruct;

Tool: module {
	init:	fn(): string;
	exec:	fn(args: string): string;
};

SpeechCapabilityTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/speech_capability_test.b";
ENGINE: con "/tmp/speechcap.engine";
SETTINGS: con "/tmp/speechcap.settings";

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

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

caps(tools, paths: list of string): ref NsConstruct->Capabilities
{
	return ref NsConstruct->Capabilities(tools, paths,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
}

# what an agent with these capabilities sees of /mnt/speech, and the
# tool's answer to args if a tool is given
agentview(c: ref NsConstruct->Capabilities, tool: Tool, args: string, rc: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	if((err := nsc->restrictns(c)) != nil) {
		rc <-= "restrictns: " + err;
		return;
	}
	s := "";
	if(exists("/mnt/speech"))
		s = "dir ";
	for(l := "ask" :: "cancel" :: "chime" :: "ctl" :: "hear" :: "listen" :: "say" :: "talk" :: "voices" :: nil;
			l != nil; l = tl l)
		if(exists("/mnt/speech/" + hd l))
			s += hd l + " ";
	if(tool != nil)
		s += "| " + tool->exec(args);
	rc <-= s;
}

loadtool(t: ref T, name: string): Tool
{
	tool := load Tool "/dis/veltro/tools/" + name + ".dis";
	if(tool == nil)
		t.fatal(sys->sprint("cannot load the %s tool: %r", name));
	if((err := tool->init()) != nil)
		t.fatal(name + " init: " + err);
	return tool;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

has(s, line: string): int
{
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l)
		if(hd l == line)
			return 1;
	return 0;
}

testSayGrant(t: ref T)
{
	rc := chan of string;
	spawn agentview(caps("say" :: nil, nil), nil, nil, rc);
	t.assertseq(<-rc, "dir say voices ", "say and voices only");
}

testHearGrant(t: ref T)
{
	tool := loadtool(t, "hear");
	rc := chan of string;
	spawn agentview(caps("hear" :: nil, nil), tool, "1500", rc);
	# while it waits: asked, and the microphone not opened
	sys->sleep(500);
	fd := sys->open("/mnt/speech/talk", Sys->OREAD);
	b := array[64] of byte;
	n := 0;
	if(fd != nil)
		n = sys->read(fd, b, len b);
	talk := "";
	if(n > 0)
		talk = string b[0:n];
	t.assertseq(talk, "off asked\n", "talk reads off asked while the tool waits");
	t.assertseq(<-rc, "dir ask | (the user said nothing)", "ask only, and nothing heard unless the user speaks");
	eng := readfile(ENGINE + "/ctl");
	t.assert(has(eng, "starts 0"), "the engine was never started: " + eng);
	ctl := readfile("/mnt/speech/ctl");
	t.assert(has(ctl, "talk off") && has(ctl, "asked 0"), "talk off, nothing asked, after: " + ctl);
}

testBothGrant(t: ref T)
{
	rc := chan of string;
	spawn agentview(caps("say" :: "hear" :: nil, nil), nil, nil, rc);
	t.assertseq(<-rc, "dir ask say voices ", "both tools: ask, say and voices");
}

testPathGrant(t: ref T)
{
	rc := chan of string;
	spawn agentview(caps("read" :: nil, "/mnt/speech" :: nil), nil, nil, rc);
	s := <-rc;
	t.assert(s == "" || len s > 10 && s[0:10] == "restrictns",
		"a generic grant of /mnt/speech gives nothing: '" + s + "'");
}

mkdir(d: string)
{
	if(!exists(d))
		sys->create(d, Sys->OREAD, Sys->DMDIR | 8r755);
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
	nsc = load NsConstruct NsConstruct->PATH;
	fake := load Command "/dis/tests/speechfake.dis";
	speech := load Command "/dis/veltro/speech9p.dis";
	if(nsc == nil || fake == nil || speech == nil)
		raise "skip:nsconstruct, speechfake or speech9p not built";
	nsc->init();

	sys->pctl(Sys->FORKNS, nil);
	mkdir("/mnt/speech");
	mkdir(ENGINE);
	sys->remove(SETTINGS);
	fake->init(nil, "speechfake" :: ENGINE :: nil);
	speech->init(nil, "speech9p" :: "-E" :: ENGINE :: "-s" :: SETTINGS :: nil);
	if(!exists("/mnt/speech/ask"))
		raise "fail:speech9p did not start";

	run("SayGrant", testSayGrant);
	run("HearGrant", testHearGrant);
	run("BothGrant", testBothGrant);
	run("PathGrant", testPathGrant);
	sys->unmount(nil, "/mnt/speech");
	sys->unmount(nil, ENGINE);
	sys->remove(ENGINE);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
