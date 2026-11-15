implement NsunionRaceTest;

#
# A union directory unmounted by one Prog while others of the same name
# space use it (emu/port/chan.c, os/port/chan.c):
#  - a walk of a name the union's first directory has not looks in the
#    rest, after the first has answered.  The first here is a 9P mount,
#    so the answer is waited for, and an unmount in that time left no
#    mounts where the walk went on to look: a nil dereference in the
#    kernel
#  - a bind of the union onto another directory copies its mounts, which
#    it read with no lock of the union's held: nil, or a mount the
#    unmount had freed
#  - an open of the union asked, with no lock, whether it had more than
#    one mount
# Each ended the emulator (or the native kernel).  Four Progs do these at
# once for a few seconds; the test is that they finish and the name space
# still answers.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

NsunionRaceTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/nsunion_race_test.b";
D: con "/tmp/nsunion_race_test";

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

mkdir(d: string)
{
	sys->create(d, Sys->OREAD, Sys->DMDIR | 8r777);
}

# memfs, serving its fd 0
server(fd: ref Sys->FD, sync: chan of int)
{
	sys->pctl(Sys->NEWFD, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	m := load Cmd "/dis/memfs.dis";
	sync <-= 1;
	if(m != nil)
		m->init(nil, "memfs" :: "-s" :: nil);
}

stop := 0;

# makes the union and takes it apart
changer(done: chan of int)
{
	n := 0;
	while(!stop){
		sys->unmount(nil, D + "/u");
		sys->bind(D + "/m", D + "/u", Sys->MREPL);
		sys->bind(D + "/a", D + "/u", Sys->MAFTER);
		sys->bind(D + "/b", D + "/u", Sys->MAFTER);
		n++;
	}
	done <-= n;
}

# looks in the union for what its first directory has not
looker(done: chan of int)
{
	n := 0;
	while(!stop){
		sys->stat(D + "/u/missing");
		sys->stat(D + "/u/inb");
		fd := sys->open(D + "/u/ina", Sys->OREAD);
		fd = nil;
		n++;
	}
	done <-= n;
}

# binds the union onto another directory, which copies it
binder(done: chan of int)
{
	n := 0;
	while(!stop){
		sys->bind(D + "/u", D + "/t", Sys->MREPL);
		sys->bind(D + "/u", D + "/t", Sys->MAFTER);
		sys->unmount(nil, D + "/t");
		n++;
	}
	done <-= n;
}

# opens the union and reads it
opener(done: chan of int)
{
	n := 0;
	while(!stop){
		fd := sys->open(D + "/u", Sys->OREAD);
		if(fd != nil)
			sys->dirread(fd);
		fd = nil;
		n++;
	}
	done <-= n;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

testUnmountedUnderUse(t: ref T)
{
	mkdir("/tmp");
	mkdir(D);
	dirs := array[] of {"m", "u", "a", "b", "t"};
	for(i := 0; i < len dirs; i++)
		mkdir(D + "/" + dirs[i]);
	sys->create(D + "/a/ina", Sys->OWRITE, 8r666);
	sys->create(D + "/b/inb", Sys->OWRITE, 8r666);

	# the union's first directory is a 9P server's
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of int;
	spawn server(p[1], sync);
	<-sync;
	p[1] = nil;
	if(sys->mount(p[0], nil, D + "/m", Sys->MREPL | Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount memfs: %r"));
	p[0] = nil;

	done := chan of int;
	spawn changer(done);
	spawn looker(done);
	spawn binder(done);
	spawn opener(done);

	sys->sleep(4000);
	stop = 1;
	tc := chan[1] of int;
	spawn timer(tc, 60000);
	total := 0;
	for(i = 0; i < 4; i++){
		alt{
		n := <-done =>
			t.assert(n > 0, sys->sprint("a Prog went round %d times", n));
			total += n;
		<-tc =>
			t.fatal("a Prog using the union never came back");
		}
	}
	t.log(sys->sprint("%d rounds in all", total));

	# and the name space still answers
	sys->unmount(nil, D + "/u");
	t.assert(sys->bind(D + "/a", D + "/u", Sys->MREPL) >= 0, sys->sprint("a bind afterwards: %r"));
	(ok, nil) := sys->stat(D + "/u/ina");
	t.asserteq(ok, 0, "and a file found through it");
	sys->unmount(nil, D + "/u");
	sys->unmount(nil, D + "/m");
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
	sys->pctl(Sys->FORKNS, nil);

	run("UnmountedUnderUse", testUnmountedUnderUse);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
