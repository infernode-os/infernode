implement DestructorTest;

#
# Does dropping the last reference free the cell NOW, or only when the
# collector gets round to it?
#
# Dis is reference counted; the mark-and-sweep collector exists for
# cycles. A heap cell whose last reference goes away is supposed to be
# freed by the code that drops it -- destroy() in xec.c under the
# interpreter, the MacFRP macro in comp-<arch>.c under the JIT. If the
# JIT's macro never reaches rdestroy, everything still gets freed
# eventually, because the collector sweeps unreachable cells whether
# or not their count says so. That is exactly what made the bug hard
# to see: comp-arm64.c's macfrp() branched on stale flags and never
# ran a destructor, and a test that dropped a pipe's write end and
# waited for EOF still passed, because the collector closed the fd
# within the wait.
#
# So this test does not wait. It churns: allocate an array larger than
# a quantum's worth of collector opportunities, drop it, repeat, until
# the total is far past any heap the emulator could have been given.
# The collector runs between scheduling rounds, every 256 of them or
# when memory is low; a tight loop of a few thousand iterations is a
# handful of rounds. Either each drop frees the previous array at
# once and the heap stays flat, or the heap fills and the allocation
# raises "out of memory: heap" -- which run() below records as a
# failure. Run under both: emu -c0 and emu -c1.
#
# The second observable is /dev/memory: the heap pool's in-use size
# after the churn must be about where it started, not one array high
# per iteration.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

DestructorTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/destructor_test.b";

# 4000 x 8MB is 32GB through the heap, sixty times its default cap.
Chunk: con 8*1024*1024;
Iters: con 4000;

# Growth tolerated across the churn: one chunk, plus slack for the
# collector's own bookkeeping.
Slack: con Chunk + 1024*1024;

passed := 0;
failed := 0;
skipped := 0;

# The array is dropped by overwriting a module-level slot, so the
# store is a movp whose old value is exactly one array with exactly one
# reference -- the plainest path through MacFRP there is.
sink: array of byte;

# A ref adt with a destructor of its own: freed through the frame
# destructor when the local goes out of scope on return.
Cell: adt {
	data: array of byte;
};

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("raised: " + e);
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# In-use bytes of the heap pool, from /dev/memory: eight fields per
# line, the first is cursize and the last is the pool name.
heapinuse(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines) {
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 2) {
			a := array[nf] of string;
			i := 0;
			for(l := f; l != nil; l = tl l)
				a[i++] = hd l;
			if(a[nf-1] == "heap")
				return int a[0];
		}
	}
	return -1;
}

fillcell(i: int): ref Cell
{
	c := ref Cell(array[Chunk] of byte);
	c.data[0] = byte i;
	return c;
}

churnframe(i: int): int
{
	c := fillcell(i);
	return int c.data[0];
}

testDropByAssignment(t: ref T)
{
	before := heapinuse();
	for(i := 0; i < Iters; i++) {
		a := array[Chunk] of byte;
		a[0] = byte i;
		sink = a;
	}
	sink = nil;
	after := heapinuse();
	t.log(sys->sprint("heap in use: before %d after %d", before, after));
	if(before >= 0 && after >= 0)
		t.assert(after - before < Slack, sys->sprint("heap grew by %d across %d drops", after - before, Iters));
}

testDropOnReturn(t: ref T)
{
	before := heapinuse();
	n := 0;
	for(i := 0; i < Iters; i++)
		n += churnframe(i);
	t.log(sys->sprint("checksum %d", n));
	after := heapinuse();
	t.log(sys->sprint("heap in use: before %d after %d", before, after));
	if(before >= 0 && after >= 0)
		t.assert(after - before < Slack, sys->sprint("heap grew by %d across %d returns", after - before, Iters));
}

testDropListCell(t: ref T)
{
	before := heapinuse();
	l: list of array of byte;
	for(i := 0; i < Iters; i++) {
		a := array[Chunk] of byte;
		a[0] = byte i;
		l = a :: l;
		l = tl l;
	}
	after := heapinuse();
	t.log(sys->sprint("heap in use: before %d after %d", before, after));
	if(before >= 0 && after >= 0)
		t.assert(after - before < Slack, sys->sprint("heap grew by %d across %d tl drops", after - before, Iters));
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

	run("DropByAssignment", testDropByAssignment);
	run("DropOnReturn", testDropOnReturn);
	run("DropListCell", testDropListCell);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
