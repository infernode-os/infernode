implement KillDeadserverTest;

#
# kill_deadserver_test - a kill is not held by a 9P server that never
# answers, neither the killer nor the killed.
#
# The server here answers a version, an attach, a walk, an open and a
# stat, and never a read, a clunk or a flush.
#
# Killer: a Prog blocked on a channel is destroyed by its killer, there
# and then, and its closes ran in the killer's thread: its mount's clunk
# was waited for, and the killer -- a shell's kill, a group's leader --
# with it, for good (tools/sysfuzz).
#
# Killed: a Prog killed in a read on the server was interrupted, sent a
# flush, and waited for the flush's answer for good, holding whatever it
# held (nativefuzz: an epoch's workers, serving each other, never died).
#
# Exiter: a Prog exiting of itself waited for its mount's clunk without
# end.
#
# All now wait a bounded time, then leave the call on the mount's queue,
# its tag held for an answer, and go (devmnt, mntorphan).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "testing.m";
	testing: Testing;
	T: import testing;

KillDeadserverTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/kill_deadserver_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string)
{
	t := testing->newTsrc(name, SRCFILE);
	{
		case name {
		"KillerNotHeld" =>
			testKillerNotHeld(t);
		"KilledNotHeld" =>
			testKilledNotHeld(t);
		"ExiterNotHeld" =>
			testExiterNotHeld(t);
		}
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

ROOT: con 0;
FILE: con 1;

# the servers' pids, killed at the end: never answering, a server whose
# client was killed waits for ever, and with it what it holds
stalls: list of int;

stall(fd: ref Sys->FD, pidc: chan of int)
{
	serve(fd, pidc, nil);
}

# answers a clunk, and says so on clunked: the second server, behind the
# first in a union
answering(fd: ref Sys->FD, pidc: chan of int, clunked: chan of int)
{
	serve(fd, pidc, clunked);
}

serve(fd: ref Sys->FD, pidc: chan of int, clunked: chan of int)
{
	rootfid := -1;
	# a name space of its own: shared with a victim, it kept the
	# victim's, and so its mount, from being closed by the kill
	sys->pctl(Sys->FORKNS, nil);
	pidc <-= sys->pctl(0, nil);
	rootqid := Sys->Qid(big ROOT, 0, Sys->QTDIR);
	fileqid := Sys->Qid(big FILE, 0, Sys->QTFILE);
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			return;
		r: ref Rmsg;
		pick x := m {
		Version =>
			r = ref Rmsg.Version(x.tag, x.msize, "9P2000");
		Attach =>
			rootfid = x.fid;
			r = ref Rmsg.Attach(x.tag, rootqid);
		Walk =>
			if(len x.names == 0){
				r = ref Rmsg.Walk(x.tag, nil);
			}
			else if(len x.names == 1 && x.names[0] == "f")
				r = ref Rmsg.Walk(x.tag, array[] of {fileqid});
			else
				r = ref Rmsg.Error(x.tag, "file does not exist");
		Open =>
			r = ref Rmsg.Open(x.tag, fileqid, 0);
		Stat =>
			d := sys->zerodir;
			d.name = "f";
			d.uid = d.gid = d.muid = "none";
			d.qid = fileqid;
			d.mode = 8r666;
			r = ref Rmsg.Stat(x.tag, d);
		Read =>
			continue;	# never
		Clunk =>
			if(clunked == nil)
				continue;	# never
			if(x.fid == rootfid)
				alt {
				clunked <-= 1 =>
					;
				* =>
					;
				}
			r = ref Rmsg.Clunk(x.tag);
		Flush =>
			continue;	# never
		Readerror =>
			return;
		* =>
			r = ref Rmsg.Error(m.tag, "no");
		}
		b := r.pack();
		if(sys->write(fd, b, len b) != len b)
			return;
	}
}

# the server's mount, on dir in this name space
mountstall(t: ref T, dir: string)
{
	mountstallas(t, dir, Sys->MREPL);
}

mountstallas(t: ref T, dir: string, flag: int)
{
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	pidc := chan of int;
	spawn stall(p[1], pidc);
	stalls = <-pidc :: stalls;
	p[1] = nil;
	if(sys->mount(p[0], nil, dir, flag, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}

# an answering server's mount on dir, the dead server then mounted
# before it: the union is closed in that order, so the answering one's
# root is clunked once the dead server's clunk is given up on
mountanswering(t: ref T, dir: string, clunked: chan of int)
{
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	pidc := chan of int;
	spawn answering(p[1], pidc, clunked);
	stalls = <-pidc :: stalls;
	p[1] = nil;
	if(sys->mount(p[0], nil, dir, Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount the answering server: %r"));
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

# a Prog with the server mounted in a name space of its own, waiting on
# a channel: killed, its name space's close clunks the mount
mounted(dir: string, pidc: chan of int, mounted: chan of string, clunked: chan of int)
{
	sys->pctl(Sys->FORKNS, nil);
	pidc <-= sys->pctl(0, nil);
	{
		t := testing->newTsrc("mounted", SRCFILE);
		if(clunked != nil){
			mountanswering(t, dir, clunked);
			mountstallas(t, dir, Sys->MBEFORE);
		}else
			mountstall(t, dir);
	} exception e {
	"*" =>
		mounted <-= e;
		return;
	}
	mounted <-= nil;
	if(clunked != nil)
		return;	# exits of itself, its mounts clunked as it goes
	c := chan of int;
	<-c;
}

killwrite(fd: ref Sys->FD, done: chan of int)
{
	sys->fprint(fd, "kill");
	done <-= 1;
}

testKillerNotHeld(t: ref T)
{
	pidc := chan of int;
	ok := chan of string;
	spawn mounted("/tmp/killdead1", pidc, ok, nil);
	pid := <-pidc;
	e := <-ok;
	if(e != nil)
		t.fatal("mount in the victim: " + e);
	ctl := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(ctl == nil)
		t.fatal(sys->sprint("open ctl: %r"));
	done := chan of int;
	spawn killwrite(ctl, done);
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	<-done =>
		;
	<-tc =>
		t.fatal("the kill did not return in 5s: the killer waits for the dead Prog's clunk");
	}
	t.assert(sys->open(sys->sprint("/prog/%d/status", pid), Sys->OREAD) == nil, "the victim is gone");
}

# reads the server's file, which is never answered
reader(dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(dir + "/f", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[10] of byte;
	sys->read(fd, b, len b);
}

testKilledNotHeld(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	dir := "/tmp/killdead2";
	mountstall(t, dir);
	pidc := chan of int;
	spawn reader(dir, pidc);
	pid := <-pidc;
	sys->sleep(300);	# into the read
	st := sys->sprint("/prog/%d/status", pid);
	ctl := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(ctl == nil)
		t.fatal(sys->sprint("open ctl: %r"));
	sys->fprint(ctl, "kill");
	ctl = nil;
	for(i := 0; i < 50; i++){
		if(sys->open(st, Sys->OREAD) == nil)
			break;
		sys->sleep(100);
	}
	t.assert(sys->open(st, Sys->OREAD) == nil, "the killed reader is gone within 5s, its read unanswered");
}

# a Prog exiting of itself, not killed, its name space's close clunking
# the mount: it waited for the clunk without end, and on servers that
# never answer exiting Progs held their kprocs until there were none
# (nativefuzz, "no procs"). Now it waits a few seconds.
testExiterNotHeld(t: ref T)
{
	pidc := chan of int;
	ok := chan of string;
	clunked := chan of int;
	spawn mounted("/tmp/killdead3", pidc, ok, clunked);
	<-pidc;
	e := <-ok;
	if(e != nil)
		t.fatal("mount in the exiter: " + e);
	# its exit closes the dead server's mount, then the answering one's
	tc := chan of int;
	spawn timer(tc, 10000);
	alt {
	<-clunked =>
		;
	<-tc =>
		t.fatal("the exiting Prog's second mount was not closed in 10s: it waits for the dead server's clunk");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || styx == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load";
	}
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("KillerNotHeld");
	run("KilledNotHeld");
	run("ExiterNotHeld");

	for(; stalls != nil; stalls = tl stalls)
		sys->fprint(sys->open(sys->sprint("/prog/%d/ctl", hd stalls), Sys->OWRITE), "kill");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
