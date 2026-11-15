implement DevfsLongpathTest;

#
# The host file system (#U, emu/port/devfs-posix.c) with a directory
# whose host name is longer than 1024 bytes, which any program that can
# make directories can make: a read of it built the name in a buffer of
# 1024 on the kernel's stack and, finding it too long, panicked ("fspath:
# name too long"), ending the emulator and every program in it; a name of
# exactly 1023 wrote a byte past the buffer first.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevfsLongpathTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devfs_longpath_test.b";
BASE: con "/tmp/devfs_longpath_test";

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

# a name of n bytes
elem(n: int, c: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s[i] = c;
	return s;
}

mkdir(d: string): int
{
	fd := sys->create(d, Sys->OREAD, Sys->DMDIR | 8r777);
	return fd != nil;
}

# remove the directories made, deepest first
cleanup(dirs: list of string)
{
	for(; dirs != nil; dirs = tl dirs)
		sys->remove(hd dirs);
}

count(d: string): (int, string)
{
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil)
		return (-1, sys->sprint("open: %r"));
	n := 0;
	for(;;){
		(nr, nil) := sys->dirread(fd);
		if(nr < 0)
			return (-1, sys->sprint("dirread: %r"));
		if(nr == 0)
			break;
		n += nr;
	}
	return (n, nil);
}

testLongDirectory(t: ref T)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	made: list of string;

	# what a run that did not finish left (the emulator ended in the read)
	old: list of string;
	od := BASE;
	for(o := 0; o < 7; o++){
		od += "/" + elem(200, 'a' + o);
		old = od :: old;
	}
	for(; old != nil; old = tl old){
		sys->remove(hd old + "/file");
		sys->remove(hd old);
	}
	sys->remove(BASE);

	if(!mkdir(BASE)){
		# left by a run that did not finish
		(ok, nil) := sys->stat(BASE);
		if(ok < 0)
			t.skip(sys->sprint("cannot make %s: %r", BASE));
	}
	made = BASE :: made;
	(ok, dir) := sys->stat(BASE);
	if(ok < 0 || dir.dtype != 'U'){
		cleanup(made);
		t.skip("/tmp is not the host's file system here");
	}

	# seven levels of 200 bytes: past 1024 at the sixth whatever the root's
	# name is, and a read of each level on the way down
	d := BASE;
	for(i := 0; i < 7; i++){
		d += "/" + elem(200, 'a' + i);
		if(!mkdir(d)){
			(sok, nil) := sys->stat(d);
			if(sok < 0){
				cleanup(made);
				t.fatal(sys->sprint("mkdir at level %d: %r", i));
			}
		}
		made = d :: made;
		ffd := sys->create(d + "/file", Sys->OWRITE, 8r666);
		ffd = nil;
		(n, e) := count(d);
		t.asserteq(n, 1, sys->sprint("level %d (a name of %d bytes below the root) lists its file%s", i, len d, e));
	}

	# every length from short to long, across 1023 and 1024: the last
	# element grows a byte at a time
	parent := BASE + "/" + elem(200, 'a') + "/" + elem(200, 'b') + "/" + elem(200, 'c');
	bad := 0;
	for(k := 1; k <= 250; k++){
		e := parent + "/" + elem(k, 'z');
		if(!mkdir(e))
			continue;
		(n, nil) := count(e);
		if(n != 0)
			bad++;
		sys->remove(e);
	}
	t.asserteq(bad, 0, "directories of every length across the old limit read as empty");

	for(l := made; l != nil; l = tl l)
		sys->remove(hd l + "/file");
	cleanup(made);
	(ok, nil) = sys->stat(BASE);
	t.assert(ok < 0, "and they are removed");
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

	run("LongDirectory", testLongDirectory);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
