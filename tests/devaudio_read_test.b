implement DevaudioReadTest;

#
# audio(3)'s audioctl (emu/port/devaudio.c, os/port/devaudio.c) read with
# buffers shorter than its text: the read gave readstr the text's length
# where the reader's count belongs, so a read of one byte copied all of
# it (165 bytes by default) into a buffer of one: 164 bytes past a
# program's array in the Dis heap, or past a 9P request's buffer when the
# device is exported, as lib/voice/listen exports it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevaudioReadTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devaudio_read_test.b";

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

GUARD: con byte 16rA5;

openctl(): ref Sys->FD
{
	fd := sys->open("/dev/audioctl", Sys->OREAD);
	if(fd == nil)
		fd = sys->open("#A/audioctl", Sys->OREAD);
	return fd;
}

testShortReads(t: ref T)
{
	fd := openctl();
	if(fd == nil)
		t.skip(sys->sprint("no audioctl here: %r"));

	# the whole text, for comparison
	whole := array[4096] of byte;
	total := sys->pread(fd, whole, len whole, big 0);
	if(total <= 0)
		t.skip(sys->sprint("audioctl reads as nothing: %d %r", total));
	t.log(sys->sprint("audioctl is %d bytes", total));

	# reads of 0 to 40 bytes at several offsets, each into the front of
	# a larger array whose other bytes must be left alone
	offs := array[] of {0, 1, 7, total/2, total-1, total, total+5};
	over := 0;
	wrongcount := 0;
	wrongbytes := 0;
	for(o := 0; o < len offs; o++){
		for(n := 0; n <= 40; n++){
			buf := array[1024] of { * => GUARD };
			r := sys->pread(fd, buf[0:n], n, big offs[o]);
			want := total - offs[o];
			if(want < 0)
				want = 0;
			if(want > n)
				want = n;
			if(r != want)
				wrongcount++;
			for(i := 0; i < r && i < n; i++)
				if(buf[i] != whole[offs[o]+i])
					wrongbytes++;
			for(i = n; i < len buf; i++)
				if(buf[i] != GUARD){
					over++;
					break;
				}
		}
	}
	t.asserteq(over, 0, "reads that wrote past the bytes asked for");
	t.asserteq(wrongcount, 0, "reads that returned a count other than what fits");
	t.asserteq(wrongbytes, 0, "bytes that differ from the whole text's");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ShortReads", testShortReads);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
