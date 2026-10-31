implement PgrpRaceTest;

#
# Can one process read another's /prog files while that process
# replaces its name space, fd group and current directory?
#
# pctl(FORKNS) and pctl(NEWFD) build the new group with the VM
# released, since the copy can wait on Limbo file servers, and then
# swap it into the Prog's Osenv and close the old one. chdir replaces
# the current directory the same way. devprog reads another Prog's
# groups holding the VM lock (the ns, fd and status files), so the
# swap and the close raced with it: a reader could hold the old Pgrp,
# Fgrp or dot while its owner freed it (INFR-373). Fixed, the reader
# sees the old group or the new one, whole.
#
# The failure is a fault in emu, so the test is that the run
# finishes: a changer process swaps as fast as it can while readers
# read its /prog files the whole time.
#
# ChdirWhileResolve is the same kind of race inside one name space:
# processes sharing it, one changing dot while the others resolve
# relative names from it (formal-verification races 1 and 3, INFR-59).
# Without the pg->ns lock in kchdir and namec, every run of it panics
# emu ("cclose": a freed dot closed again).
#
#   emu -c0 -r . /dis/tests/pgrp_race_test.dis
#   emu -c1 -r . /dis/tests/pgrp_race_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

PgrpRaceTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/pgrp_race_test.b";

# How long the changer keeps swapping.
Runms: con 3000;

# Readers of the changer's /prog files.
Nreaders: con 4;

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

# Swap the name space, the fd group and dot until told to stop,
# then report how many rounds it made.
changer(pidc: chan of int, stop: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	dirs := array[] of {"/dis", "/tmp", "/dev", "/"};
	n := 0;
	for(;;) {
		alt {
		<-stop =>
			done <-= n;
			return;
		* =>
			;
		}
		sys->pctl(Sys->FORKNS, nil);
		sys->bind("#c", "/dev", Sys->MREPL);
		sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
		sys->chdir(dirs[n % len dirs]);
		n++;
	}
}

# Read the changer's ns, fd and status files whole, over and over,
# until told to stop; then report how many reads succeeded.
reader(pid: int, stop: chan of int, done: chan of int)
{
	files := array[] of {"ns", "fd", "status", "wd"};
	buf := array[8192] of byte;
	n := 0;
	for(i := 0; ; i++) {
		alt {
		<-stop =>
			done <-= n;
			return;
		* =>
			;
		}
		fd := sys->open(sys->sprint("#p/%d/%s", pid, files[i % len files]), Sys->OREAD);
		if(fd == nil)
			continue;
		while(sys->read(fd, buf, len buf) > 0)
			;
		n++;
	}
}

testSwapWhileRead(t: ref T)
{
	pidc := chan of int;
	cstop := chan of int;
	cdone := chan of int;
	spawn changer(pidc, cstop, cdone);
	pid := <-pidc;

	rstop := chan of int;
	rdone := chan of int;
	for(i := 0; i < Nreaders; i++)
		spawn reader(pid, rstop, rdone);

	sys->sleep(Runms);

	cstop <-= 1;
	rounds := <-cdone;
	reads := 0;
	for(i = 0; i < Nreaders; i++) {
		rstop <-= 1;
		reads += <-rdone;
	}
	t.log(sys->sprint("%d swaps, %d reads", rounds, reads));
	t.assert(rounds > 0, "changer made no swaps");
	t.assert(reads > 0, "readers read nothing");
}

# Change the shared current directory until told to stop.
chdirer(stop: chan of int, done: chan of int)
{
	dirs := array[] of {"/dis", "/dev", "/lib", "/"};
	n := 0;
	for(;;) {
		alt {
		<-stop =>
			done <-= n;
			return;
		* =>
			;
		}
		sys->chdir(dirs[n % len dirs]);
		n++;
	}
}

# Resolve names relative to the shared current directory until told
# to stop; then report how many resolved.
resolver(stop: chan of int, done: chan of int)
{
	names := array[] of {".", "..", "lib", "sh.dis", "cons", "ndb"};
	n := 0;
	for(i := 0; ; i++) {
		alt {
		<-stop =>
			done <-= n;
			return;
		* =>
			;
		}
		(ok, nil) := sys->stat(names[i % len names]);
		if(ok == 0)
			n++;
	}
}

# Processes sharing a name space: one changes dot while the others
# resolve names from it. namec takes a reference to pg->dot while
# kchdir replaces and closes it, both with the VM released, so
# without the pg->ns lock around both a resolver could take a
# reference to a Chan already freed (formal-verification races 1
# and 3; INFR-59).
testChdirWhileResolve(t: ref T)
{
	cstop := chan of int;
	cdone := chan of int;
	spawn chdirer(cstop, cdone);

	rstop := chan of int;
	rdone := chan of int;
	for(i := 0; i < Nreaders; i++)
		spawn resolver(rstop, rdone);

	sys->sleep(Runms);

	cstop <-= 1;
	rounds := <-cdone;
	resolved := 0;
	for(i = 0; i < Nreaders; i++) {
		rstop <-= 1;
		resolved += <-rdone;
	}
	t.log(sys->sprint("%d chdirs, %d names resolved", rounds, resolved));
	t.assert(rounds > 0, "chdirer made no changes");
	t.assert(resolved > 0, "resolvers resolved nothing");
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

	run("SwapWhileRead", testSwapWhileRead);
	run("ChdirWhileResolve", testChdirWhileResolve);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
