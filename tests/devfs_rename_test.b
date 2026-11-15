implement DevfsRenameTest;

#
# The host file system (#U, emu/port/devfs-posix.c) keeps each channel's
# host name, and a rename through an open file (fwstat) replaces it.
#
# A directory open in several processes, one renaming it back and forth
# while the others read and stat it through the same descriptor: the
# rename freed the name the readers were using (they held no reference to
# it), so a read built its path from freed memory and the emulator ended,
# or read whatever had been put there since.
#
# And #U*, the host's whole tree: its root was given the qid, owner and
# mode of the emulator's root directory, so ".." from that directory inside
# #U* stayed where it was, and the host's / was checked by another
# directory's permissions.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevfsRenameTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devfs_rename_test.b";
BASE: con "/tmp/devfs_rename_test";

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

stopped := 0;

reader(fd: ref Sys->FD, done: chan of int)
{
	n := 0;
	while(!stopped){
		sys->seek(fd, big 0, Sys->SEEKSTART);
		sys->dirread(fd);
		sys->fstat(fd);
		n++;
	}
	done <-= n;
}

renamer(fd: ref Sys->FD, done: chan of int)
{
	n := 0;
	names := array[] of {"b", "a"};
	while(!stopped){
		d := sys->nulldir;
		d.name = names[n & 1];
		if(sys->fwstat(fd, d) >= 0)
			n++;
	}
	# leave it as "a"
	d := sys->nulldir;
	d.name = "a";
	sys->fwstat(fd, d);
	done <-= n;
}

scrub()
{
	for(i := 0; i < 8; i++){
		sys->remove(BASE + "/a/f" + string i);
		sys->remove(BASE + "/b/f" + string i);
	}
	sys->remove(BASE + "/a");
	sys->remove(BASE + "/b");
	sys->remove(BASE);
}

testRenameUnderReaders(t: ref T)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	scrub();
	if(sys->create(BASE, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		t.skip(sys->sprint("cannot make %s: %r", BASE));
	(ok, dir) := sys->stat(BASE);
	if(ok < 0 || dir.dtype != 'U'){
		scrub();
		t.skip("/tmp is not the host's file system here");
	}
	if(sys->create(BASE + "/a", Sys->OREAD, Sys->DMDIR | 8r777) == nil){
		scrub();
		t.fatal(sys->sprint("cannot make the directory: %r"));
	}
	for(i := 0; i < 8; i++)
		sys->create(BASE + "/a/f" + string i, Sys->OWRITE, 8r666);

	fd := sys->open(BASE + "/a", Sys->OREAD);
	if(fd == nil){
		scrub();
		t.fatal(sys->sprint("open: %r"));
	}

	NR: con 4;
	stopped = 0;
	rdone := chan of int;
	wdone := chan of int;
	for(i = 0; i < NR; i++)
		spawn reader(fd, rdone);
	spawn renamer(fd, wdone);
	sys->sleep(3000);
	stopped = 1;
	reads := 0;
	for(i = 0; i < NR; i++)
		reads += <-rdone;
	renames := <-wdone;
	t.log(sys->sprint("%d reads beside %d renames", reads, renames));
	t.assert(renames > 0, "the directory was renamed through its descriptor");
	t.assert(reads > 0, "and read through it meanwhile");

	# the descriptor still names the directory, wherever it is now
	sys->seek(fd, big 0, Sys->SEEKSTART);
	n := 0;
	for(;;){
		(nr, nil) := sys->dirread(fd);
		if(nr <= 0)
			break;
		n += nr;
	}
	t.asserteq(n, 8, "the directory lists its eight files after it all");
	(ok, dir) = sys->fstat(fd);
	t.assert(ok >= 0, "and is stat'ed through its descriptor");
	if(ok >= 0)
		t.assertseq(dir.name, "a", "under the name it was left with");
	fd = nil;
	scrub();
	(ok, nil) = sys->stat(BASE);
	t.assert(ok < 0, "and it is removed");
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

testStarRoot(t: ref T)
{
	root := readfile("/env/emuroot");
	if(root == nil || root[0] != '/' || root == "/")
		t.skip("no emulator root below the host's /");
	# putenvq quotes a name with blanks; not worth undoing here
	if(root[0] == '\'')
		t.skip("the emulator root's name is quoted");
	(ok, top) := sys->stat("#U*");
	if(ok < 0)
		t.skip(sys->sprint("no #U* here: %r"));
	(rok, rd) := sys->stat("#U*" + root);
	if(rok < 0)
		t.skip(sys->sprint("cannot stat the emulator root in #U*: %r"));
	t.assert(top.qid.path != rd.qid.path,
		"the root of #U* is the host's /, not the emulator's root directory");
	(pok, pd) := sys->stat("#U*" + root + "/..");
	t.assert(pok >= 0, "the emulator root's parent is reached in #U*");
	if(pok >= 0)
		t.assert(pd.qid.path != rd.qid.path,
			".. from the emulator's root directory inside #U* leaves it");
	# and the plain #U is still rooted there
	(uok, ud) := sys->stat("#U");
	t.assert(uok >= 0, "#U is stat'ed");
	if(uok >= 0){
		t.assert(ud.qid.path == rd.qid.path, "#U is the emulator's root directory");
		(dok, dd) := sys->stat("#U/..");
		t.assert(dok >= 0 && dd.qid.path == ud.qid.path, ".. at the root of #U stays there");
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

	run("StarRoot", testStarRoot);
	run("RenameUnderReaders", testRenameUnderReaders);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
