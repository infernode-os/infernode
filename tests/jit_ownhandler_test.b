implement JitOwnhandlerTest;

#
# A fault in compiled code, caught by a handler in the faulting
# function's own frame.
#
# The JITs keep the Dis frame pointer in a register (RFP in
# comp-<arch>.c: RBX, X21, s2) and do not store it in R.FP at a call.
# A fault the hardware raises (a nil load, x86's zero divide) reaches
# jitfault from the host's signal handler with R.PC set from the
# faulting instruction but R.FP still the caller's, unless the handler
# passes the register on (jitfaultfp). Then handler() looks for the
# callee's pc in the caller's frame, unwinds to the wrong handler and
# frees the wrong frames: "alloc:D2B" or a SEGV under -c1. -c0 is right.
#
# Apart from jit_fault_test.b because the bare-metal kernels run that
# one and their trap paths (os/) do not pass the register yet.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitOwnhandlerTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_ownhandler_test.b";

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

Rec: adt {
	a: int;
	b: int;
};

nilrec: ref Rec;

# set at run time, so limbo cannot fold the division away
zerov := -1;
onev := -1;

zero(): int
{
	return zerov;
}

one(): int
{
	return onev;
}

# Callees with a handler of their own: not inlined, so the fault is in
# their own frame.
owndivw(a, b: int): string
{
	{
		a = a / b;
	} exception e {
	"*" =>
		return e;
	}
	return string a;
}

owndivl(a, b: big): string
{
	{
		a = a % b;
	} exception e {
	"*" =>
		return e;
	}
	return string a;
}

ownnil(r: ref Rec): string
{
	{
		r.a++;
	} exception e {
	"*" =>
		return e;
	}
	return string r.a;
}

testOwnHandler(t: ref T)
{
	for(k := 0; k < 3; k++) {
		t.assertseq(owndivw(7, zero()), "zero divide", "int / in a callee with its own handler");
		t.assertseq(owndivw(7, 2 * one()), "3", "and the one that does not fault");
		t.assertseq(owndivl(big 7, big zero()), "zero divide", "big % in a callee with its own handler");
		t.assertseq(ownnil(nilrec), "dereference of nil", "nil load in a callee with its own handler");
	}
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
	zerov = int "0";
	onev = int "1";
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("OwnHandler", testOwnHandler);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
