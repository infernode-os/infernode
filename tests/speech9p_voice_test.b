implement Speech9pVoiceTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Speech9pSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Speech9pVoiceTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with Speech9pSrv
};

SRCFILE: con "/tests/speech9p_voice_test.b";
SRVPATH: con "/dis/veltro/speech9p.dis";
MNT: con "/tmp/speech9p_voice_test";
PARAKEETMNT: con "/tmp/parakeet_voice_mount";

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

createfile(path, data: string): int
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
	sys->create(PARAKEETMNT, Sys->OREAD, Sys->DMDIR | 8r755);
	srv := load Speech9pSrv SRVPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speech9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speech9p" :: "-m" :: MNT :: "-e" :: "kokoro" :: "-v" :: "af_bella" :: nil);
	sys->sleep(300);
}

testFiles(t: ref T)
{
	files := array[] of {
		"ctl", "say", "sayq", "hear", "listen", "wake", "cancel", "voices"
	};
	for(i := 0; i < len files; i++)
		t.assert(pathexists(MNT + "/" + files[i]), files[i] + " should exist");
}

testConfig(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(ctl != nil, "ctl should be readable");
	t.assert(ctl != nil && len ctl > 0, "ctl should not be empty");
	t.assert(writefile(MNT + "/ctl", "engine kokoro") > 0, "engine kokoro accepted");
	t.assert(writefile(MNT + "/ctl", "voice af_bella") > 0, "voice accepted");
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/echo") > 0, "kokoro helper accepted");
	t.assert(writefile(MNT + "/ctl", "ttsengine piper") > 0, "tts engine accepted");
	t.assert(writefile(MNT + "/ctl", "listenengine whisper") > 0, "listen engine accepted");
	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final test transcript") > 0,
		"streaming helper accepted");
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake score=1.0") > 0,
		"wake helper accepted");
	t.assert(writefile(MNT + "/ctl", "wakeword hey lucia") > 0, "wake word accepted");
	t.assert(writefile(MNT + "/ctl", "wakethreshold 0.7") > 0, "wake threshold accepted");
	t.assert(writefile(MNT + "/ctl", "parakeetmount /n/parakeet") > 0, "parakeet mount accepted");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten /n/parakeet/listen") > 0,
		"parakeet listen mount accepted");
	t.assert(writefile(MNT + "/ctl", "pipersay /n/parakeet/say") > 0,
		"piper say mount accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(ctl != nil && len ctl > 0, "ctl remains readable after config writes");
	t.assert(hassubstr(ctl, "engine kokoro"), "ctl reports kokoro engine");
	t.assert(hassubstr(ctl, "kokorobin /bin/echo"), "ctl reports kokoro helper");
	t.assert(hassubstr(ctl, "ttsengine piper"), "ctl reports tts engine");
	t.assert(hassubstr(ctl, "listenengine whisper"), "ctl reports listen engine");
	t.assert(hassubstr(ctl, "wakeword hey lucia"), "ctl reports wake word");
	t.assert(hassubstr(ctl, "wakethreshold 0.7"), "ctl reports wake threshold");
	t.assert(hassubstr(ctl, "parakeetmount /n/parakeet"), "ctl reports parakeet mount");
	t.assert(hassubstr(ctl, "parakeetlisten /n/parakeet/listen"),
		"ctl reports parakeet listen mount");
	t.assert(hassubstr(ctl, "pipersay /n/parakeet/say"),
		"ctl reports piper say mount");
}

testListenWakeHelpers(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final helper transcript") > 0,
		"configure fake listen helper");
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake helper") > 0,
		"configure fake wake helper");

	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final helper transcript"),
		"listen returns fake helper output");
	wake := readfile(MNT + "/wake");
	t.assert(hassubstr(wake, "wake helper"),
		"wake returns fake helper output");
}

testParakeetListenMount(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "listenengine parakeet") > 0,
		"configure parakeet listen engine");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0,
		"configure parakeet mount prefix");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten " + PARAKEETMNT + "/listen") > 0,
		"configure parakeet listen file");
	t.assert(createfile(PARAKEETMNT + "/listen", "final parakeet transcript\n") > 0,
		"create fake mounted parakeet listen file");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final parakeet transcript"),
		"listen returns mounted parakeet stream output");

	t.assert(writefile(MNT + "/ctl", "listenengine whisper") > 0,
		"restore default listen engine for later tests");
}

testPiperSayMount(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "ttsengine piper") > 0,
		"configure piper tts engine");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0,
		"configure parakeet mount prefix");
	t.assert(createfile(PARAKEETMNT + "/say", "") >= 0,
		"create fake mounted piper say file");
	result := writesayread(MNT + "/say", "mounted piper tts");
	t.assert(hassubstr(result, "mounted piper tts"),
		"say returns mounted piper say status");
	written := readfile(PARAKEETMNT + "/say");
	t.assert(hassubstr(written, "mounted piper tts"),
		"speech9p delegated say write to mounted piper say file");
	t.assert(writefile(MNT + "/ctl", "ttsengine engine") > 0,
		"restore default tts engine for later tests");
}

testCancel(t: ref T)
{
	t.assert(writefile(MNT + "/cancel", "cancel") > 0, "cancel write accepted");
	state := strip(readfile(MNT + "/cancel"));
	t.assert(state == "cancel pending" || state == "idle",
		"cancel state should be readable");
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
	run("ListenWakeHelpers", testListenWakeHelpers);
	run("ParakeetListenMount", testParakeetListenMount);
	run("PiperSayMount", testPiperSayMount);
	run("Cancel", testCancel);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
