implement FdcloseTest;

#
# Does dropping the last reference to an fd close it NOW?
#
# Limbo has no close(): a Sys->FD is closed when its last reference
# goes away, by the FD type's destructor (freeFD in inferno.c). That
# is what makes "fd = nil" mean close. It only means that if the code
# that drops the reference actually runs the destructor -- and under
# the JIT that is the MacFRP macro in comp-<arch>.c, not the
# interpreter's destroy() in xec.c. comp-arm64.c's macfrp() branched
# on stale flags and never reached rdestroy, so every dropped fd on
# the AArch64 JIT stayed open until the collector swept it, and
# os/init/etherusb.b grew a sys->dup of #c/null to close its endpoints
# by hand. This test is the one that would have caught it.
#
# The observable is a pipe: hold the read end, drop the write end one
# way or another, and read. EOF (0) within a bounded time means the
# destructor ran at the drop; a timeout means it did not. Each of the
# ways compiled code can drop a reference is a separate case -- movp
# by assignment, the frame destructor on return, a ref adt's own
# destructor, a list cell freed by tl -- because they are separate
# code paths in the compiler.
#
# Run it both ways, on every JIT platform:
#   emu -c0 -r . /dis/tests/fdclose_test.dis	(interpreter, the reference)
#   emu -c1 -r . /dis/tests/fdclose_test.dis	(compiled)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

FdcloseTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/fdclose_test.b";

# How long a close is allowed to take before it is "did not happen".
# Closing is synchronous in the destructor; the reader and the timer
# are separate processes, so this is scheduling latency, not close
# latency. Generous so a busy CI machine does not fail it.
Eofms: con 3000;

# How long to insist a NOT-closed fd stays open before believing it.
Openms: con 300;

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

# A reference-counted holder: dropping the holder must drop the fd.
Holder: adt {
	fd:	ref Sys->FD;
};

#
# Read once from fd and report the count. Runs as its own process so
# the test can time out rather than hang if the write end never closes.
# It holds its own reference to the READ end only, which is fine: that
# is the end we want to stay open.
#
reader(fd: ref Sys->FD, c: chan of int)
{
	buf := array[16] of byte;
	c <-= sys->read(fd, buf, len buf);
}

# What the timer sends. Distinct from anything read() can return.
Timedout: con -2;

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= Timedout;
}

#
# A result channel. Reader and timer both send into it and the test
# receives whichever comes first, so no alt is needed -- the check
# should exercise as little of the VM as possible beyond the thing
# under test. Buffered deep enough that every sender always completes:
# emu does not exit while any process is alive, and a timer left
# blocked on a send nobody receives made the first version of this
# test pass and then hang until the harness killed it.
#
Depth: con 8;

results(): chan of int
{
	return chan[Depth] of int;
}

#
# Wait up to ms for a result; Timedout means none came.
#
await(res: chan of int, ms: int): int
{
	spawn timer(res, ms);
	return <-res;
}

#
# Make a pipe and return its two ends as separate variables, with the
# array that pipe() filled already gone -- so the ONLY references to
# each end are the ones the caller holds.
#
mkpipe(t: ref T): (ref Sys->FD, ref Sys->FD)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	rd := p[0];
	wr := p[1];
	p = nil;
	return (rd, wr);
}

#
# movp: the last reference dropped by assigning nil to the variable
# that holds it. This is the plain "fd = nil" every Limbo program
# writes to mean close.
#
testDropByAssignment(t: ref T)
{
	(rd, wr) := mkpipe(t);
	res := results();
	spawn reader(rd, res);
	wr = nil;
	n := await(res, Eofms);
	t.asserteq(n, 0, sys->sprint("read after wr = nil returned %d; want 0 (EOF) -- the FD destructor did not run at the assignment", n));
}

#
# The frame destructor: the write end lives only in a local of a
# function that has returned. Nothing assigns nil; the compiled
# function's epilogue (macret -> the frame's Type.destroy) drops it.
#
readendonly(t: ref T): ref Sys->FD
{
	(rd, wr) := mkpipe(t);
	if(wr == nil)
		t.fatal("no write end");
	return rd;		# wr goes with the frame
}

testDropOnReturn(t: ref T)
{
	rd := readendonly(t);
	res := results();
	spawn reader(rd, res);
	n := await(res, Eofms);
	t.asserteq(n, 0, sys->sprint("read after the holder returned gave %d; want 0 (EOF) -- the frame destructor did not free the fd", n));
}

#
# A ref adt: the fd is a field of a heap cell. Dropping the cell runs
# its destructor, which drops the field. Two destructors in a row, the
# second reached from C (freeheap) rather than from the macro.
#
testDropRefAdt(t: ref T)
{
	(rd, wr) := mkpipe(t);
	h := ref Holder(wr);
	wr = nil;		# the holder now has the only reference
	res := results();
	spawn reader(rd, res);
	if(await(res, Openms) != Timedout)
		t.error("pipe closed while the adt still held the write end");
	h = nil;
	n := await(res, Eofms);
	t.asserteq(n, 0, sys->sprint("read after h = nil returned %d; want 0 (EOF) -- dropping the adt did not free its fd", n));
}

#
# A list cell: tl frees the cell whose head was the fd. That is the
# MacFRP call blmac'd from the tail instruction, a different call site
# from movp.
#
testDropListCell(t: ref T)
{
	(rd, wr) := mkpipe(t);
	l := wr :: nil;
	wr = nil;
	res := results();
	spawn reader(rd, res);
	if(await(res, Openms) != Timedout)
		t.error("pipe closed while the list still held the write end");
	l = tl l;
	n := await(res, Eofms);
	t.asserteq(n, 0, sys->sprint("read after l = tl l returned %d; want 0 (EOF) -- freeing the list cell did not free its fd", n));
}

#
# The other half of the contract: a reference that is NOT the last one
# must decrement and store, not destroy. If the "ref > 1" path failed
# to store, the second drop would see ref == 2 and never close; if it
# destroyed early, the first drop would close a file still in use.
#
testSecondReferenceKeepsOpen(t: ref T)
{
	(rd, wr) := mkpipe(t);
	other := wr;
	res := results();
	spawn reader(rd, res);

	wr = nil;
	if(await(res, Openms) != Timedout)
		t.fatal("pipe closed while a second reference to the write end was live");

	# Prove the reader is still there and the pipe still works: one
	# byte through the surviving reference.
	if(sys->write(other, array[] of {byte 'x'}, 1) != 1)
		t.fatal(sys->sprint("write through the surviving reference: %r"));
	n := await(res, Eofms);
	t.asserteq(n, 1, sys->sprint("reader got %d after a 1-byte write; want 1", n));

	# Now the genuinely last reference.
	spawn reader(rd, res);
	other = nil;
	n = await(res, Eofms);
	t.asserteq(n, 0, sys->sprint("read after the last reference went returned %d; want 0 (EOF)", n));
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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("DropByAssignment", testDropByAssignment);
	run("DropOnReturn", testDropOnReturn);
	run("DropRefAdt", testDropRefAdt);
	run("DropListCell", testDropListCell);
	run("SecondReferenceKeepsOpen", testSecondReferenceKeepsOpen);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
