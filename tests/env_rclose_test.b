implement EnvRcloseTest;

#
# env_rclose_test - an /env file opened ORCLOSE is removed when its
# Chan is closed, by whoever closes it: here Limbo's collector, which
# frees an FD held only by a cycle, in a kproc with no environment.
#
# envclose took that kproc's environment for the remove, nil, and
# faulted on its lock: "SYS: process released faults: dereference of
# nil", and emu exited (tools/sysfuzz). The remove is from the
# environment the file was opened in.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

EnvRcloseTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/env_rclose_test.b";

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

# a cycle, so the FD in it goes only when the collector finds it
Loop: adt {
	fd:	ref Sys->FD;
	next:	cyclic ref Loop;
};

holdincycle(p: string, mode: int): int
{
	fd := sys->open(p, mode);
	if(fd == nil)
		fd = sys->create(p, mode, 8r666);
	if(fd == nil)
		return -1;
	sys->fprint(fd, "x");
	l := ref Loop(fd, nil);
	l.next = l;
	return 0;
}

gone(p: string, secs: int): int
{
	for(i := 0; i < secs*10; i++){
		if(sys->stat(p).t0 < 0)
			return 1;
		sys->sleep(100);
	}
	return 0;
}

testCollectorCloses(t: ref T)
{
	sys->pctl(Sys->FORKENV, nil);
	p := "/env/rclosetest";
	t.asserteq(holdincycle(p, Sys->ORDWR|Sys->ORCLOSE), 0, "created ORCLOSE");
	t.assert(sys->stat(p).t0 >= 0, "there while the cycle holds it");
	# the collector runs when the VM is idle
	t.assert(gone(p, 20), "removed once the collector closed it");
	# and again, opening one that is there
	fd := sys->create(p, Sys->OWRITE, 8r666);
	fd = nil;
	t.asserteq(holdincycle(p, Sys->OREAD|Sys->ORCLOSE), 0, "opened ORCLOSE");
	t.assert(gone(p, 20), "removed once the collector closed it, opened");
}

testCloserElsewhere(t: ref T)
{
	# opened ORCLOSE in one environment and closed in a Prog of another:
	# the remove is from the first
	sys->pctl(Sys->FORKENV, nil);
	p := "/env/rclosetest2";
	fd := sys->create(p, Sys->ORDWR|Sys->ORCLOSE, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	done := chan of int;
	spawn closer(fd, done);
	fd = nil;
	<-done;
	t.assert(gone(p, 5), "removed from the environment it was opened in");
}

closer(fd: ref Sys->FD, done: chan of int)
{
	sys->pctl(Sys->NEWENV, nil);
	fd = nil;
	done <-= 1;
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

	run("CollectorCloses", testCollectorCloses);
	run("CloserElsewhere", testCloserElsewhere);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
