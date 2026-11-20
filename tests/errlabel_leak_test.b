implement ErrlabelLeakTest;

#
# What a kernel error handler gives back when the call it guards is
# refused (chan.c, exportfs.c, sysfile.c, qio.c; both kernels).
#
# The handlers below each close a channel that the function made after
# its waserror(): namec's create (cnew), the export server's open and
# stat (the channel exmount made), pipe (its two ends).  A local changed
# between setjmp and longjmp, and not volatile, is indeterminate in the
# handler, and clang (which builds the macOS, iOS and Android emulators
# and every native kernel) took each for the value it had at waserror():
# nil, so the handler closed nothing, or in the native pipe the channel
# walk had already released, closed a second time.
#
#  - a create a device refuses kept a channel: 384 bytes of the main
#    pool each, from any program (and a fid on a 9P server);
#  - an open or a stat refused through an exported tree kept the channel
#    made for it, from whoever the tree is exported to;
#  - a pipe() refused for want of a descriptor kept both ends.
#
# gcc reads such a local from memory, so the Linux emulator did not leak;
# there these are guards.  Thousands of refusals of each kind must not
# grow the kernel's main pool, and the kernel must go on working.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

ErrlabelLeakTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/errlabel_leak_test.b";
FILE: con "/tmp/errlabel_leak_test";

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

# bytes in use in the kernel's main pool, from /dev/memory
mainused(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 8 && hd tl tl tl tl tl tl tl f == "main")
			return int hd f;
	}
	return -1;
}

N: con 20000;

testCreateOfExisting(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	fd := sys->create(FILE, Sys->OWRITE, 8r666);
	if(fd == nil)
		t.skip(sys->sprint("cannot create %s: %r", FILE));
	fd = nil;

	# once round first: whatever the first use allocates and keeps
	for(i := 0; i < 200; i++)
		fd = sys->create(FILE, Sys->OWRITE, 8r666);
	fd = nil;
	before := mainused();
	made := 0;
	for(i = 0; i < N; i++){
		fd = sys->create(FILE, Sys->OWRITE, 8r666);
		if(fd != nil)
			made++;
		fd = nil;
	}
	after := mainused();
	t.log(sys->sprint("main pool %d before, %d after %d creates of a file that exists", before, after, N));
	t.asserteq(made, N, "a create of a file that exists opens it");
	t.assert(after - before < 256*1024,
		sys->sprint("%d creates of a file that exists keep %d bytes of the main pool (%d each)", N, after - before, (after - before)/N));
	sys->remove(FILE);
}

testCreateRefused(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	# /dev/null is there; a file in it can be neither made nor opened
	name := "/dev/null/x";
	fd: ref Sys->FD;
	for(i := 0; i < 200; i++)
		fd = sys->create(name, Sys->OWRITE, 8r666);
	before := mainused();
	made := 0;
	for(i = 0; i < N; i++){
		fd = sys->create(name, Sys->OWRITE, 8r666);
		if(fd != nil)
			made++;
	}
	# and in a directory of the console device, which makes no files
	for(i = 0; i < N; i++){
		fd = sys->create("/dev/errlabel_leak_test", Sys->OWRITE, 8r666);
		if(fd != nil)
			made++;
	}
	after := mainused();
	t.log(sys->sprint("main pool %d before, %d after %d refused creates", before, after, 2*N));
	t.asserteq(made, 0, "creates where nothing can be made are refused");
	t.assert(after - before < 256*1024,
		sys->sprint("%d refused creates keep %d bytes of the main pool", 2*N, after - before));
}

# a tree exported on one end of a pipe and mounted from the other
exported(t: ref T, dir: string, mtpt: string)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	if(sys->export(p[0], dir, Sys->EXPASYNC) < 0)
		t.fatal(sys->sprint("export: %r"));
	if(sys->mount(p[1], nil, mtpt, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}

EXDIR: con "/tmp/errlabel_leak_export";
EXMNT: con "/tmp/errlabel_leak_mnt";

testExportRefused(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	sys->pctl(Sys->FORKNS, nil);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->remove(EXDIR + "/sub/gone");
	sys->remove(EXDIR + "/sub");
	sys->remove(EXDIR);
	if(sys->create(EXDIR, Sys->OREAD, Sys->DMDIR | 8r777) == nil ||
	   sys->create(EXDIR + "/sub", Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		t.skip(sys->sprint("cannot make %s: %r", EXDIR));
	if(sys->create(EXDIR + "/sub/gone", Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		t.skip(sys->sprint("cannot make a directory: %r"));
	sys->create(EXMNT, Sys->OREAD, Sys->DMDIR | 8r777);
	exported(t, EXDIR, EXMNT);

	# an open the device refuses: a directory, for writing
	fd: ref Sys->FD;
	for(i := 0; i < 200; i++)
		fd = sys->open(EXMNT + "/sub", Sys->OWRITE);
	before := mainused();
	opened := 0;
	for(i = 0; i < N; i++){
		fd = sys->open(EXMNT + "/sub", Sys->OWRITE);
		if(fd != nil)
			opened++;
	}
	after := mainused();
	t.log(sys->sprint("main pool %d before, %d after %d opens refused through an export", before, after, N));
	t.asserteq(opened, 0, "a directory is not opened for writing through an export");
	t.assert(after - before < 256*1024,
		sys->sprint("%d opens refused through an export keep %d bytes of the main pool (%d each)", N, after - before, (after - before)/N));

	# a stat the device refuses: of a directory removed behind its descriptor
	# (the host file system stats a directory by its name)
	gfd := sys->open(EXMNT + "/sub/gone", Sys->OREAD);
	if(gfd == nil)
		t.fatal(sys->sprint("open through the export: %r"));
	if(sys->remove(EXDIR + "/sub/gone") < 0)
		t.fatal(sys->sprint("remove behind the export: %r"));
	(ok, nil) := sys->fstat(gfd);
	if(ok >= 0){
		# this host stats an open directory that has no name; nothing to refuse
		t.log("a removed directory is still stat'ed through its descriptor here");
	}else{
		for(i = 0; i < 200; i++)
			sys->fstat(gfd);
		before = mainused();
		for(i = 0; i < N; i++)
			sys->fstat(gfd);
		after = mainused();
		t.log(sys->sprint("main pool %d before, %d after %d stats refused through an export", before, after, N));
		t.assert(after - before < 256*1024,
			sys->sprint("%d stats refused through an export keep %d bytes of the main pool (%d each)", N, after - before, (after - before)/N));
	}
	gfd = nil;
	sys->unmount(nil, EXMNT);
	sys->remove(EXDIR + "/sub");
	sys->remove(EXDIR);
	sys->remove(EXMNT);
}

testPipeRefused(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	# a descriptor table of its own, filled
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	held: list of ref Sys->FD;
	nheld := 0;
	for(;;){
		fd := sys->open("/dev/null", Sys->OREAD);
		if(fd == nil)
			break;
		held = fd :: held;
		if(++nheld > 100000)
			break;
	}
	if(nheld > 100000)
		t.skip("the descriptor table has no limit here");
	# room for one: the first end is given a descriptor, the second refused
	held = tl held;
	# (few of them: the kernel says "no free file descriptors" for each)
	p := array[2] of ref Sys->FD;
	for(i := 0; i < 8; i++)
		sys->pipe(p);
	before := mainused();
	made := 0;
	R: con 64;
	for(i = 0; i < R; i++)
		if(sys->pipe(p) >= 0){
			made++;
			p[0] = nil;
			p[1] = nil;
		}
	after := mainused();
	t.log(sys->sprint("%d descriptors held; main pool %d before, %d after %d pipes refused", nheld, before, after, R));
	t.asserteq(made, 0, "a pipe with one descriptor left is refused");
	t.assert(after - before < 16*1024,
		sys->sprint("%d refused pipes keep %d bytes of the main pool (%d each)", R, after - before, (after - before)/R));
	held = nil;
	t.assert(sys->pipe(p) >= 0, "and a pipe is made once there is room");
	if(p[0] != nil){
		buf := array[4] of byte;
		t.asserteq(sys->write(p[0], array of byte "ping", 4), 4, "written");
		t.asserteq(sys->read(p[1], buf, 4), 4, "and read");
	}
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

	run("CreateOfExisting", testCreateOfExisting);
	run("CreateRefused", testCreateRefused);
	run("ExportRefused", testExportRefused);
	run("PipeRefused", testPipeRefused);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
