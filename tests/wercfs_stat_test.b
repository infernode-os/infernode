implement WercfsStatTest;

#
# wercfs(4): the stat of a file it serves as it is (pub/), while the
# file is open.
#
# Such a file is read from the host as it is at each read, but its stat
# through the open fid was the one taken when it was opened.  A file
# that grew or was cut while a client had it open was said to be one
# length and read as another: httpd(8), which takes a response's
# Content-Length from that stat, sent less than there was or ended the
# connection short.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "testing.m";
	testing: Testing;
	T: import testing;

WercfsStatTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wercfs_stat_test.b";

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

mkdir(d: string): int
{
	return sys->create(d, Sys->OREAD, Sys->DMDIR|8r777) != nil;
}

putfile(f, s: string)
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->write(fd, array of byte s, len array of byte s);
}

rmrf(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd != nil)
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				if(d[i].mode & Sys->DMDIR)
					rmrf(dir + "/" + d[i].name);
				else
					sys->remove(dir + "/" + d[i].name);
		}
	fd = nil;
	sys->remove(dir);
}

wercfs(fd: ref Sys->FD, werc, site: string, sync: chan of string)
{
	sys->pctl(Sys->NEWFD|Sys->FORKNS, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	c := load Command "/dis/wercfs.dis";
	if(c == nil){
		sync <-= sys->sprint("cannot load /dis/wercfs.dis: %r");
		return;
	}
	sync <-= nil;
	c->init(nil, "wercfs" :: "-w" :: werc :: site :: nil);
}

readall(fd: ref Sys->FD): string
{
	s := "";
	buf := array[8192] of byte;
	off := big 0;
	while((n := sys->pread(fd, buf, len buf, off)) > 0){
		s += string buf[0:n];
		off += big n;
	}
	return s;
}

testOpenStat(t: ref T)
{
	top := sys->sprint("/tmp/wercfs_stat_test.%d", sys->pctl(0, nil));
	rmrf(top);
	site := top + "/werc/sites/s.test";
	if(!(mkdir(top) && mkdir(top + "/werc") && mkdir(top + "/werc/lib") && mkdir(top + "/werc/sites") &&
	     mkdir(site) && mkdir(site + "/pub") && mkdir(top + "/mnt")))
		t.fatal(sys->sprint("cannot make %s: %r", top));
	f := site + "/pub/data.txt";
	putfile(f, "0123456789");

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of string;
	spawn wercfs(p[1], top + "/werc", site, sync);
	p[1] = nil;
	if((e := <-sync) != nil)
		t.fatal(e);
	if(sys->mount(p[0], nil, top + "/mnt", Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));

	fd := sys->open(top + "/mnt/pub/data.txt", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open pub/data.txt: %r"));
	(ok, d) := sys->fstat(fd);
	t.assert(ok >= 0 && d.length == big 10, sys->sprint("opened: its length is 10 (%bd)", d.length));

	# it grows while it is open
	afd := sys->open(f, Sys->OWRITE);
	sys->seek(afd, big 0, Sys->SEEKEND);
	sys->fprint(afd, "abcde");
	afd = nil;
	(ok, d) = sys->fstat(fd);
	t.assert(ok >= 0 && d.length == big 15, sys->sprint("grown by five bytes: the open file's stat says 15 (%bd)", d.length));
	t.assertseq(readall(fd), "0123456789abcde", "and its reads give them");

	# and is cut
	putfile(f, "xyz");
	(ok, d) = sys->fstat(fd);
	t.assert(ok >= 0 && d.length == big 3, sys->sprint("cut to three: the open file's stat says 3 (%bd)", d.length));
	t.assertseq(readall(fd), "xyz", "and its reads give three");

	# a file opened afresh is as it is, as before
	(ok, d) = sys->stat(top + "/mnt/pub/data.txt");
	t.assert(ok >= 0 && d.length == big 3, sys->sprint("by name: 3 (%bd)", d.length));

	fd = nil;
	sys->unmount(nil, top + "/mnt");
	rmrf(top);
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
	sys->pctl(Sys->FORKNS, nil);

	run("OpenStat", testOpenStat);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
