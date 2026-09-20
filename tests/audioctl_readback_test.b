implement AudioctlReadbackTest;

#
# audioctl_readback_test.
#
# audioctl accepted play_buffer_ms / rec_buffer_ms but ctlsummary only
# printed capability ranges, so a write across a 9P mount could not be
# confirmed. Inferno sh does not put write errors in $status, which made
# the missing readback expensive to notice.
#
# This test writes the caps through an export/mount of #A and reads them
# back from the mounted audioctl. It also pins the existing capability
# lines so the additive format does not break consumers.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

AudioctlReadbackTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/audioctl_readback_test.b";

passed := 0;
failed := 0;
skipped := 0;

MNT: con "/n/phone";



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

contains(haystack, needle: string): int
{
	if(len needle == 0)
		return 1;
	for(i := 0; i + len needle <= len haystack; i++)
		if(haystack[i:i + len needle] == needle)
			return 1;
	return 0;
}

# Value of `key value` on its own line, or "".
extract(s, key: string): string
{
	i := 0;
	while(i < len s) {
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		line := s[i:j];
		if(len line > len key && line[:len key] == key && line[len key] == ' ')
			return line[len key + 1:];
		i = j + 1;
	}
	return "";
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[:n];
}

writefile(path, content: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte content;
	return sys->write(fd, b, len b);
}

exporter(fd: ref Sys->FD)
{
	sys->export(fd, "/dev", Sys->EXPWAIT);
}

mkdir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

# Bind #A onto /dev, export it over a pipe, mount at /n/phone.
# Same shape as voice/listen: a 9P view of the device tree.
mountadev(t: ref T)
{
	if(sys->bind("#A", "/dev", Sys->MAFTER) < 0)
		t.fatal(sys->sprint("bind #A: %r"));

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));

	mkdir("/n");
	sys->unmount(nil, MNT);
	mkdir(MNT);

	spawn exporter(p[0]);
	if(sys->mount(p[1], nil, MNT, Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}


unmountadev()
{
	sys->unmount(nil, MNT);
}

testCapsRoundTripOver9P(t: ref T)
{
	caught := 0;
	{
		mountadev(t);

		# Skip on absence of the mechanism, not a wrong value.
		# Linux/OSS never registers, so the line is omitted.
		# A present line with the wrong number is a FAIL.
		s0 := readfile(MNT + "/audioctl");
		if(!contains(s0, "play_buffer_ms")) {
			t.skip("this audio backend registers no buffer-cap accessor");
			return;
		}




		n := writefile(MNT + "/audioctl", "play_buffer_ms 80\n");
		t.assert(n > 0, "write play_buffer_ms across 9P");
		n = writefile(MNT + "/audioctl", "rec_buffer_ms 120\n");
		t.assert(n > 0, "write rec_buffer_ms across 9P");

		s := readfile(MNT + "/audioctl");
		t.assertnotnil(s, "read audioctl across 9P");
		t.log(s);

		t.assertseq(extract(s, "play_buffer_ms"), "80",
			"play_buffer_ms read back across 9P");
		t.assertseq(extract(s, "rec_buffer_ms"), "120",
			"rec_buffer_ms read back across 9P");

		# Existing capability-range lines stay, first value current.
		t.assert(contains(s, "rate 8000 11025 16000 22050 44100"),
			"capability rate line unchanged");
		t.assert(contains(s, "bits 16 8") || contains(s, "bits 16"),
			"capability bits line still present");
		t.assert(contains(s, "chans 2 1") || contains(s, "chans 2"),
			"capability chans line still present");
		t.assert(contains(s, "in buf"),
			"capability in buf line still present");
		t.assert(contains(s, "out buf"),
			"capability out buf line still present");

		t.assertseq(extract(s, "in rate"), "8000 chans 2 bits 16",
			"live in format reported");
		t.assertseq(extract(s, "out rate"), "8000 chans 2 bits 16",
			"live out format reported");

		n = writefile(MNT + "/audioctl", "play_buffer_ms 40\n");
		t.assert(n > 0, "overwrite play_buffer_ms");
		s = readfile(MNT + "/audioctl");
		t.assertseq(extract(s, "play_buffer_ms"), "40",
			"second write is the live value, not a stale first write");
		t.assertseq(extract(s, "rec_buffer_ms"), "120",
			"unrelated cap is unchanged");
	} exception {
		"fail:fatal" =>
			caught = 1;
		"fail:skip" =>
			caught = 2;
		* =>
			caught = 3;
	}
	unmountadev();
	if(caught == 1)
		raise "fail:fatal";
	if(caught == 2)
		raise "fail:skip";
	if(caught == 3)
		t.failed = 1;
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

	run("CapsRoundTripOver9P", testCapsRoundTripOver9P);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
