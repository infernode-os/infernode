implement SpeechtestTest;

#
# Tests for appl/cmd/speechtest.b — the LLM-free STT/TTS test loop.
#
# The speech tree is mocked with plain files (same technique as
# voicemode_test): a plain-file "listen" returns its content on every
# read, "say" is a writable scratch file, and there is no chime file
# (speechtest's chime writes are best-effort). speechtest is run
# without -b, so the mock tree is never mistaken for a missing stack.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

SpeechtestTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with SpeechtestCmd
};

SpeechtestCmd: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

_marker() {}

SRCFILE: con "/tests/speechtest_test.b";
STPATH: con "/dis/speechtest.dis";
MOCK: con "/tmp/speechtest_test_speech";
PHRASE: con "canned reply";

passed := 0;
failed := 0;
skipped := 0;

testpid := -1;

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

# Truncating write — mock state changes must not leave residue from
# longer previous contents.
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

waitfor(path, sub: string, timeout: int): int
{
	for(waited := 0; waited < timeout; waited += 100) {
		if(hassubstr(readfile(path), sub))
			return 1;
		sys->sleep(100);
	}
	return hassubstr(readfile(path), sub);
}

mkmock(listenrec: string)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MOCK, Sys->OREAD, Sys->DMDIR | 8r755);
	createfile(MOCK + "/ctl", "");
	createfile(MOCK + "/listen", listenrec);
	createfile(MOCK + "/say", "");
}

runcmd(pidch: chan of int, extra: list of string)
{
	pidch <-= sys->pctl(Sys->NEWPGRP, nil);
	st := load SpeechtestCmd STPATH;
	if(st == nil) {
		sys->fprint(sys->fildes(2), "cannot load speechtest: %r\n");
		return;
	}
	st->init(nil, "speechtest" :: "-s" :: MOCK :: "-n" :: "1" ::
		"-p" :: PHRASE :: extra);
}

startcmd(listenrec: string, extra: list of string)
{
	mkmock(listenrec);
	pidch := chan of int;
	spawn runcmd(pidch, extra);
	testpid = <-pidch;
}

stopcmd()
{
	if(testpid < 0)
		return;
	fd := sys->open("/prog/" + string testpid + "/ctl", Sys->OWRITE);
	if(fd != nil) {
		b := array of byte "killgrp";
		sys->write(fd, b, len b);
	}
	testpid = -1;
}

runst(name: string, listenrec: string, extra: list of string, testfn: ref fn(t: ref T))
{
	startcmd(listenrec, extra);
	run(name, testfn);
	stopcmd();
	sys->sleep(200);
}

testFinalSpeaksPhrase(t: ref T)
{
	t.assert(waitfor(MOCK + "/say", PHRASE, 5000),
		"final transcript should trigger the canned phrase in say");
}

testEchoFinal(t: ref T)
{
	t.assert(waitfor(MOCK + "/say", "hello world", 5000),
		"-e should speak the transcript itself");
}

testPartialDoesNotSpeak(t: ref T)
{
	sys->sleep(600);
	t.assertseq(strip(readfile(MOCK + "/say")), "",
		"a partial alone must not trigger say");
	createfile(MOCK + "/listen", "final all done\n");
	t.assert(waitfor(MOCK + "/say", PHRASE, 5000),
		"the final after partials should trigger say");
}

testJunkFinalNotSpoken(t: ref T)
{
	sys->sleep(600);
	t.assertseq(strip(readfile(MOCK + "/say")), "",
		"a junk final ([BLANK_AUDIO]) must not trigger say");
	createfile(MOCK + "/listen", "final real words\n");
	t.assert(waitfor(MOCK + "/say", PHRASE, 5000),
		"a real final after junk should trigger say");
}

testErrorDoesNotSpeak(t: ref T)
{
	sys->sleep(600);
	t.assertseq(strip(readfile(MOCK + "/say")), "",
		"an error record must not trigger say");
}

testCtlFileApplied(t: ref T)
{
	t.assert(waitfor(MOCK + "/ctl", "engine kokoro", 5000),
		"-C applies the installer-selected speech ctl file before listening");
	t.assert(waitfor(MOCK + "/say", PHRASE, 5000),
		"speech test continues after applying the ctl file");
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

	runst("FinalSpeaksPhrase", "final hello world\n", nil, testFinalSpeaksPhrase);
	runst("EchoFinal", "final hello world\n", "-e" :: nil, testEchoFinal);
	runst("PartialDoesNotSpeak", "partial hel\n", nil, testPartialDoesNotSpeak);
	runst("JunkFinalNotSpoken", "final [BLANK_AUDIO]\n", nil, testJunkFinalNotSpoken);
	runst("ErrorDoesNotSpeak", "error: helper missing\n", nil, testErrorDoesNotSpeak);
	ctlfile := "/tmp/speechtest_test.ctl.sh";
	createfile(ctlfile, "echo 'engine kokoro' > " + MOCK + "/ctl\n");
	runst("CtlFileApplied", "final configured helper\n",
		"-C" :: ctlfile :: nil, testCtlFileApplied);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
