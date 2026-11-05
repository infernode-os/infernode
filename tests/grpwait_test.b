implement GrpwaitTest;

#
# /prog/n/grpwait: a read waits until n's process group, as it was when
# the file was opened, has no Prog left.  Lucifer reaps an app by it,
# where it read /prog every half second.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

GrpwaitTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/grpwait_test.b";

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

# A group: its leader makes it, starts a member waiting on release, and
# ends when told (as xenith's main proc returns from init while its
# tasks run on).  pidc is sent the leader's pid once the group is made.
leader(pidc: chan of int, quit, release: chan of int, sub: int)
{
	sys->pctl(Sys->NEWPGRP, nil);
	spawn member(release, sub);
	pidc <-= sys->pctl(0, nil);
	<-quit;
}

member(release: chan of int, sub: int)
{
	if(sub)
		sys->pctl(Sys->NEWPGRP, nil);	# a service of the group's, a group of its own
	<-release;
}

opengrpwait(pid: int): ref Sys->FD
{
	return sys->open(sys->sprint("/prog/%d/grpwait", pid), Sys->OREAD);
}

# The grpwait read, or "waiting" if it has not answered within ms.
waitread(fd: ref Sys->FD, c: chan of string, ms: int): string
{
	tick := chan of int;
	spawn timer(tick, ms);
	alt {
	s := <-c =>
		return s;
	<-tick =>
		return "waiting";
	}
}

reader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		c <-= sys->sprint("error: %r");
	else
		c <-= "gone " + string buf[0:n];
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { c <-= 1 => ; * => ; }
}

testLastProg(t: ref T)
{
	pidc := chan of int;
	quit := chan of int;
	release := chan of int;
	spawn leader(pidc, quit, release, 0);
	pid := <-pidc;
	fd := opengrpwait(pid);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open /prog/%d/grpwait: %r", pid));
		return;
	}
	c := chan[1] of string;
	spawn reader(fd, c);
	t.assertseq(waitread(fd, c, 200), "waiting", "the read waits while the group runs");
	quit <-= 1;
	t.assertseq(waitread(fd, c, 300), "waiting", "the leader gone, its member is still the group");
	release <-= 1;
	t.assertseq(waitread(fd, c, 3000), "gone " + string pid, "the last Prog gone, the read answers with the group");
}

testKilled(t: ref T)
{
	pidc := chan of int;
	quit := chan of int;
	release := chan of int;
	spawn leader(pidc, quit, release, 0);
	pid := <-pidc;
	fd := opengrpwait(pid);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open /prog/%d/grpwait: %r", pid));
		return;
	}
	c := chan[1] of string;
	spawn reader(fd, c);
	ctl := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	t.assert(ctl != nil && sys->fprint(ctl, "killgrp") > 0, "killgrp written");
	t.assertseq(waitread(fd, c, 3000), "gone " + string pid, "a group killed is gone");
}

testSubgroupNotCounted(t: ref T)
{
	pidc := chan of int;
	quit := chan of int;
	release := chan of int;
	spawn leader(pidc, quit, release, 1);
	pid := <-pidc;
	fd := opengrpwait(pid);
	if(fd == nil) {
		t.fatal(sys->sprint("cannot open /prog/%d/grpwait: %r", pid));
		return;
	}
	c := chan[1] of string;
	spawn reader(fd, c);
	quit <-= 1;
	t.assertseq(waitread(fd, c, 3000), "gone " + string pid,
		"a member in a group of its own does not keep the group");
	release <-= 1;
}

testReaders(t: ref T)
{
	pidc := chan of int;
	quit := chan of int;
	release := chan of int;
	spawn leader(pidc, quit, release, 0);
	pid := <-pidc;
	f1 := opengrpwait(pid);
	f2 := opengrpwait(pid);
	if(f1 == nil || f2 == nil) {
		t.fatal("cannot open grpwait twice");
		return;
	}
	c1 := chan[1] of string;
	c2 := chan[1] of string;
	spawn reader(f1, c1);
	spawn reader(f2, c2);
	quit <-= 1;
	release <-= 1;
	t.assertseq(waitread(f1, c1, 3000), "gone " + string pid, "the first reader is told");
	t.assertseq(waitread(f2, c2, 3000), "gone " + string pid, "and the second");
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

	run("LastProg", testLastProg);
	run("Killed", testKilled);
	run("SubgroupNotCounted", testSubgroupNotCounted);
	run("Readers", testReaders);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
