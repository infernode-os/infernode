implement JitKillcallTest;

#
# jit_killcall_test - an exception that arrives while a Prog is blocked
# in a call to a builtin module (Sys->sleep) is raised at that call, from
# compiled code as from the interpreter. tests/host/jit_killcall_test.sh
# runs this under -c0 and -c1.
#
# The JITs' rmcall raised a kill pending after the call with R.PC as it
# last was: compiled code keeps the pc in a register, and only an
# instruction handed to the interpreter writes R.PC. The handler matched
# that pc with the caller's frame: a handler around code that had run
# before the call took the exception, and a Prog that should have died
# went on, or another function's handler was taken for the frame and
# what would be its locals freed (sysfuzz: destroy of nil, emu killed by
# SIGSEGV, with kill and "exceptions propagate" while Progs exported and
# mounted their name spaces).
#
# And Sys->sleep, interrupted for it, raised "" in its place: the Prog
# went as though killed, under the interpreter too, its handler never
# seeing the exception.
#
# Here a Prog sends on a channel inside a guarded block (the send is the
# interpreter's, and writes R.PC there), leaves the block, and sleeps in
# Sys->sleep; another of its group raises, and the group's exceptions
# propagate. The sleep must end in the exception, caught by the handler
# around the call, not by that block's.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

JitKillcallTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/jit_killcall_test.b";

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

# blocks in a call, after a guarded block whose handler must not see
# the exception that ends the call
victim(said: chan of string)
{
	c := chan[1] of int;
	{
		c <-= 1;	# send: punted, R.PC written inside this block
		<-c;
	} exception {
	"*" =>
		said <-= "the earlier block's handler";
		return;
	}
	# nothing from here to the call is the interpreter's: R.PC stays
	# in the block above. Sys->sleep releases the VM and sleeps on the
	# host; the exception's interrupt ends the sleep, and the call
	# returns, the exception pending, to be raised in rmcall.
	{
		sys->sleep(3000);
		said <-= "the call returned";
	} exception e {
	"fail:propagated*" =>
		said <-= "the call's handler: " + e;
	}
}

raiser(go: chan of int)
{
	<-go;
	raise "fail:propagated from the raiser";
}

leader(said: chan of string, pidc: chan of int)
{
	sys->pctl(Sys->NEWPGRP, nil);
	pidc <-= sys->pctl(0, nil);
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "exceptions propagate") < 0){
		said <-= sys->sprint("cannot set exceptions propagate: %r");
		return;
	}
	go := chan of int;
	spawn victim(said);
	spawn raiser(go);
	sys->sleep(300);	# the victim into its sleep
	go <-= 1;
	for(;;)
		sys->sleep(1000);
}

testKillDuringCall(t: ref T)
{
	said := chan of string;
	pidc := chan of int;
	spawn leader(said, pidc);
	lpid := <-pidc;
	tc := chan of int;
	spawn timer(tc, 5000);
	got := "";
	alt {
	got = <-said =>
		;
	<-tc =>
		got = "nothing in 5s";
	}
	fd := sys->open("/prog/" + string lpid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	t.assertseq(got, "the call's handler: fail:propagated from the raiser", "what ended the call");
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("KillDuringCall", testKillDuringCall);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
