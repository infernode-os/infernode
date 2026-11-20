implement SyscallEdgeTest;

#
# Sys builtins given what a program may pass and no file is
# (emu/port/inferno.c, sysfile.c, and os/port's):
#  - pipe(nil): the array was read, nil or not: a fault in the kernel's
#    own code (the hosted emulator made an exception of it; the native
#    kernel has no such net)
#  - stream with a buffer size of none or less: it went to the allocator
#    and to read as it was
#  - bind with a flag of bits no flag has (16r80000001): taken, since the
#    test was "greater than all of them" on a signed int, and kept in the
#    mount
#  - a file's offset past the largest: seek to it on a file that takes any
#    offset, write or read a byte, and the offset was added to with no
#    check: undefined in C, negative in practice, and the descriptor then
#    refused everything
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

SyscallEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/syscall_edge_test.b";

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

MAXOFF: con big 16r7FFFFFFFFFFFFFFF;

testPipeNil(t: ref T)
{
	r := -2;
	{
		r = sys->pipe(nil);
	} exception e {
	"*" =>
		t.fatal("pipe(nil) raised: " + e);
	}
	t.asserteq(r, -1, "pipe(nil) is refused");
	one := array[1] of ref Sys->FD;
	t.asserteq(sys->pipe(one), -1, "pipe of an array of one is refused");
	p := array[2] of ref Sys->FD;
	t.asserteq(sys->pipe(p), 0, "and a pipe is still made");
}

testStreamSize(t: ref T)
{
	p := array[2] of ref Sys->FD;
	q := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0 || sys->pipe(q) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	t.asserteq(sys->stream(p[0], q[1], -1), -1, "stream with a buffer of -1 bytes is refused");
	t.asserteq(sys->stream(p[0], q[1], 0), -1, "and of none");
	t.asserteq(sys->stream(p[0], q[1], int 16r80000000), -1, "and of the most negative int");

	# and it still streams
	msg := array of byte "streamed";
	sys->write(p[1], msg, len msg);
	p[1] = nil;
	t.asserteq(sys->stream(p[0], q[1], 64), len msg, "a stream with a buffer of 64 copies the bytes");
	buf := array[64] of byte;
	n := sys->read(q[0], buf, len buf);
	t.assertseq(string buf[0:n], "streamed", "the bytes arrive");
}

testBindFlag(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	t.asserteq(sys->bind("/dis", "/n", int 16r80000001), -1, "bind with bit 31 set in its flag is refused");
	t.asserteq(sys->bind("/dis", "/n", 16r100), -1, "and with a bit no flag has");
	t.asserteq(sys->bind("/dis", "/n", 16r20), -1, "and another");
	t.assert(sys->bind("/dis", "/n", Sys->MREPL) >= 0, sys->sprint("a plain bind works: %r"));
	sys->unmount(nil, "/n");
	t.assert(sys->bind("/dis", "/n", Sys->MAFTER|Sys->MCREATE) >= 0, sys->sprint("and one with flags there are: %r"));
	sys->unmount(nil, "/n");
}

testOffsetAtMost(t: ref T)
{
	# a write at the largest offset
	fd := sys->open("/dev/null", Sys->OWRITE);
	if(fd == nil)
		t.fatal(sys->sprint("open /dev/null: %r"));
	t.assert(sys->seek(fd, MAXOFF, Sys->SEEKSTART) == MAXOFF, "seek to the largest offset");
	b := array[1] of {byte 'x'};
	t.asserteq(sys->write(fd, b, 1), -1, "a write that would pass the largest offset is refused");
	t.assert(sys->seek(fd, big 0, Sys->SEEKRELA) == MAXOFF, "and the offset is where it was");
	t.assert(sys->seek(fd, big 0, Sys->SEEKSTART) == big 0, "the descriptor still seeks");
	t.asserteq(sys->write(fd, b, 1), 1, "and writes");

	# one short of it: the last byte there is
	t.assert(sys->seek(fd, MAXOFF - big 1, Sys->SEEKSTART) == MAXOFF - big 1, "seek to one short of it");
	t.asserteq(sys->write(fd, b, 1), 1, "a write of the last byte is taken");
	t.assert(sys->seek(fd, big 0, Sys->SEEKRELA) == MAXOFF, "and leaves the offset at the largest");

	# a read at the largest offset, of a file that takes any
	rfd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(rfd == nil){
		t.log(sys->sprint("no /dev/notquiterandom: %r"));
		return;
	}
	t.assert(sys->seek(rfd, MAXOFF - big 3, Sys->SEEKSTART) == MAXOFF - big 3, "seek to three short of the largest offset");
	rb := array[8] of byte;
	n := sys->read(rfd, rb, len rb);
	t.assert(n >= 0 && n <= 3, sys->sprint("a read of eight bytes there gets no more than three: %d", n));
	off := sys->seek(rfd, big 0, Sys->SEEKRELA);
	t.assert(off >= big 0 && off <= MAXOFF, sys->sprint("and leaves an offset that is one: %bd", off));
	n = sys->read(rfd, rb, len rb);
	off = sys->seek(rfd, big 0, Sys->SEEKRELA);
	t.assert(off >= big 0, sys->sprint("a second read too: %d, offset %bd", n, off));
	t.assert(sys->seek(rfd, big 0, Sys->SEEKSTART) == big 0, "the descriptor still seeks");
	t.asserteq(sys->read(rfd, rb, len rb), len rb, "and reads");
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

	run("PipeNil", testPipeNil);
	run("BindFlag", testBindFlag);
	run("OffsetAtMost", testOffsetAtMost);
	# last: before the fix a stream with no buffer waited for ever
	run("StreamSize", testStreamSize);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
