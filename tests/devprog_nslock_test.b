implement DevprogNslockTest;

#
# devprog_nslock_test - a read of a Prog's ns or fd file does not stop
# the VM while its name space is locked.
#
# A union directory's read holds its mount point's lock across a 9P
# read; a mount on that point waits for the lock holding the name
# space's; and ns and fd took the name space's lock holding the VM. With
# the server not answering the read, the VM stopped for good: in emu,
# every Prog (tools/nativefuzz, sysfuzz). Here the server is ours and
# answers everything but that read; while the ns and fd reads wait, a
# timer in this VM must still fire. Then the reader is killed (the
# server answers its flush) and everything goes on.
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

DevprogNslockTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devprog_nslock_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string)
{
	t := testing->newTsrc(name, SRCFILE);
	{
		case name {
		"NsReadLeavesVM" =>
			testNsReadLeavesVM(t);
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

# answers all but a read of its root, which it never answers; a flush
# it answers, so the reader can be killed
stall(fd: ref Sys->FD)
{
	rootqid := Sys->Qid(big 0, 0, Sys->QTDIR);
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			return;
		r: ref Rmsg;
		pick x := m {
		Version =>
			r = ref Rmsg.Version(x.tag, x.msize, "9P2000");
		Attach =>
			r = ref Rmsg.Attach(x.tag, rootqid);
		Walk =>
			if(len x.names > 0)
				r = ref Rmsg.Error(x.tag, "file does not exist");
			else
				r = ref Rmsg.Walk(x.tag, nil);
		Open =>
			r = ref Rmsg.Open(x.tag, rootqid, 0);
		Read =>
			continue;	# never
		Flush =>
			r = ref Rmsg.Flush(x.tag);
		Clunk =>
			r = ref Rmsg.Clunk(x.tag);
		Stat =>
			d := sys->zerodir;
			d.name = "stall";
			d.uid = d.gid = d.muid = "none";
			d.qid = rootqid;
			d.mode = Sys->DMDIR|8r555;
			r = ref Rmsg.Stat(x.tag, d);
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

# reads the union until it reaches the server, where it waits
reader(dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, nil) := sys->dirread(fd);
		if(n <= 0)
			break;
	}
}

# a mount on the union's mount point: waits for its lock
mounter(dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->bind("#e", dir, Sys->MAFTER);
}

nsread(fd: ref Sys->FD, done: chan of string)
{
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	done <-= sys->sprint("read %d", n);
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

testNsReadLeavesVM(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	dir := "/tmp/nslocktest";
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	if(sys->bind("#e", dir, Sys->MREPL) < 0)
		t.skip(sys->sprint("no #e to bind: %r"));
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	spawn stall(p[1]);
	p[1] = nil;
	if(sys->mount(p[0], nil, dir, Sys->MAFTER, nil) < 0)
		t.fatal(sys->sprint("mount the server: %r"));
	p = nil;

	pidc := chan of int;
	spawn reader(dir, pidc);
	rpid := <-pidc;
	# opened now: once the name space is locked, no name can be looked up
	rctl := sys->open(sys->sprint("/prog/%d/ctl", rpid), Sys->OWRITE);
	if(rctl == nil)
		t.fatal(sys->sprint("open the reader's ctl: %r"));
	me := sys->pctl(0, nil);
	nsfd := sys->open(sys->sprint("/prog/%d/ns", me), Sys->OREAD);
	fdfd := sys->open(sys->sprint("/prog/%d/fd", me), Sys->OREAD);
	if(nsfd == nil || fdfd == nil)
		t.fatal(sys->sprint("open ns and fd: %r"));
	sys->sleep(300);	# into the server's read, holding the mount point
	spawn mounter(dir, pidc);
	<-pidc;
	sys->sleep(300);	# waiting for it, holding the name space

	done := chan of string;
	spawn nsread(nsfd, done);
	spawn nsread(fdfd, done);
	tc := chan of int;
	spawn timer(tc, 1000);
	got := 0;
	ticked := 0;
	while(!ticked) alt {
	<-done =>
		got++;
	<-tc =>
		ticked = 1;
	}
	t.assert(ticked, "a timer in this VM fires while ns and fd wait on the name space");

	# let it all go: the reader killed (its read flushed), the mount
	# done, the ns and fd reads answered
	sys->fprint(rctl, "kill");
	tc = chan of int;
	spawn timer(tc, 5000);
	while(got < 2) alt {
	<-done =>
		got++;
	<-tc =>
		t.error(sys->sprint("%d of the ns and fd reads answered 5s after the reader was killed", got));
		got = 2;
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

	run("NsReadLeavesVM");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
