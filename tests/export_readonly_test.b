implement ExportReadonlyTest;

#
# Sys->EXPREADONLY: an export through which nothing is changed.
#
# export(2)'s server (emu/port/exportfs.c, os/port/exportfs.c) had a
# read-only mode that nothing could ask for: sys->export took its flag's
# low bit for EXPASYNC and dropped the rest.  A program that serves a
# directory to others (post(1)) could only give them all its own rights
# to it.  The flag now reaches the server, which refuses, with "file
# system read only", every request that would change the tree.
#
#  - spoken to in raw Styx: walk, stat, open for reading, read and a
#    directory read are served; Twrite, Tcreate, Twstat, and Topen for
#    OWRITE, ORDWR, OTRUNC or ORCLOSE are refused, the fid of a refused
#    open still good for an open to read; a refused Tremove leaves the
#    file and clunks its fid, as a remove must
#  - through a mount: read served; open to write, create, remove and
#    wstat refused, the files as they were
#  - the same export without the flag does all of them
#  - EXPWAIT with the flag is read-only too
#  - a flag with a bit no flag has is refused (it was taken for EXPWAIT
#    or EXPASYNC by its low bit)
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

ExportReadonlyTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/export_readonly_test.b";
DIR: con "/tmp/export_readonly_test";
MNT: con "/tmp/export_readonly_mnt";
TEXT: con "what the file holds\n";
RO: con "file system read only";

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

# DIR exported on one end of a pipe with flag; the other end
exported(t: ref T, flag: int): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	if(sys->export(p[0], DIR, flag) < 0)
		t.fatal(sys->sprint("export: %r"));
	return p[1];
}

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	b := m.pack();
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("write %s: %r", m.text()));
	r := Rmsg.read(fd, 64*1024);
	if(r == nil)
		t.fatal("no reply (connection closed): " + m.text());
	pick e := r {
	Readerror =>
		t.fatal("reply unreadable: " + m.text() + ": " + e.error);
	}
	return r;
}

ename(r: ref Rmsg): string
{
	pick e := r {
	Error =>
		return e.ename;
	}
	return nil;
}

want(t: ref T, r: ref Rmsg, kind: int, what: string)
{
	if(r == nil || tagof r != kind)
		t.fatal(what + ": got " + r.text());
}

refused(t: ref T, r: ref Rmsg, why: string, what: string)
{
	e := ename(r);
	if(e == nil){
		t.error(what + ": not refused: " + r.text());
		return;
	}
	if(!contains(e, why))
		t.error(what + ": refused with \"" + e + "\", want \"" + why + "\"");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open: %r");
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return sys->sprint("read: %r");
	return string b[0:n];
}

exists(f: string): int
{
	(ok, nil) := sys->stat(f);
	return ok >= 0;
}

mode(f: string): int
{
	(ok, d) := sys->stat(f);
	if(ok < 0)
		return -1;
	return d.mode & 8r777;
}

testRaw(t: ref T)
{
	fd := exported(t, Sys->EXPASYNC|Sys->EXPREADONLY);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8192+24, "9P2000")), tagof Rmsg.Version, "version");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach");

	# what reads is served
	want(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"file"})), tagof Rmsg.Walk, "walk to the file");
	want(t, rpc(t, fd, ref Tmsg.Stat(3, 2)), tagof Rmsg.Stat, "stat");
	want(t, rpc(t, fd, ref Tmsg.Open(4, 2, Sys->OREAD)), tagof Rmsg.Open, "open to read");
	r := rpc(t, fd, ref Tmsg.Read(5, 2, big 0, 100));
	pick d := r {
	Read =>
		t.assertseq(string d.data, TEXT, "a read gives the file");
	* =>
		t.error("read: " + r.text());
	}
	want(t, rpc(t, fd, ref Tmsg.Walk(6, 1, 3, nil)), tagof Rmsg.Walk, "clone the root");
	want(t, rpc(t, fd, ref Tmsg.Open(7, 3, Sys->OREAD)), tagof Rmsg.Open, "open the root");
	r = rpc(t, fd, ref Tmsg.Read(8, 3, big 0, 4096));
	pick d := r {
	Read =>
		t.assert(len d.data > 0, "the directory is read");
	* =>
		t.error("directory read: " + r.text());
	}

	# what changes is refused
	refused(t, rpc(t, fd, ref Tmsg.Write(10, 2, big 0, array of byte "changed")), RO, "a write");
	want(t, rpc(t, fd, ref Tmsg.Walk(11, 1, 4, array[] of {"file"})), tagof Rmsg.Walk, "walk to the file again");
	refused(t, rpc(t, fd, ref Tmsg.Open(12, 4, Sys->OWRITE)), RO, "an open to write");
	refused(t, rpc(t, fd, ref Tmsg.Open(13, 4, Sys->ORDWR)), RO, "an open to read and write");
	refused(t, rpc(t, fd, ref Tmsg.Open(14, 4, Sys->OREAD|Sys->OTRUNC)), RO, "an open that truncates");
	refused(t, rpc(t, fd, ref Tmsg.Open(15, 4, Sys->OREAD|Sys->ORCLOSE)), RO, "an open that removes on close");
	want(t, rpc(t, fd, ref Tmsg.Open(16, 4, Sys->OREAD)), tagof Rmsg.Open, "the fid of the refused opens, opened to read");
	t.assertseq(readfile(DIR + "/file"), TEXT, "the file is as it was");

	want(t, rpc(t, fd, ref Tmsg.Walk(20, 1, 5, nil)), tagof Rmsg.Walk, "clone the root");
	refused(t, rpc(t, fd, ref Tmsg.Create(21, 5, "made", 8r664, Sys->OWRITE)), RO, "a create");
	refused(t, rpc(t, fd, ref Tmsg.Create(22, 5, "madedir", Sys->DMDIR|8r775, Sys->OREAD)), RO, "a create of a directory");
	t.assert(!exists(DIR + "/made") && !exists(DIR + "/madedir"), "and nothing is made");

	d := sys->nulldir;
	d.mode = 8r600;
	want(t, rpc(t, fd, ref Tmsg.Walk(30, 1, 6, array[] of {"file"})), tagof Rmsg.Walk, "walk to the file");
	refused(t, rpc(t, fd, ref Tmsg.Wstat(31, 6, d)), RO, "a wstat");
	d = sys->nulldir;
	d.name = "renamed";
	refused(t, rpc(t, fd, ref Tmsg.Wstat(32, 6, d)), RO, "a rename");
	t.asserteq(mode(DIR + "/file"), 8r664, "the file's mode is as it was");
	t.assert(exists(DIR + "/file") && !exists(DIR + "/renamed"), "and its name");

	want(t, rpc(t, fd, ref Tmsg.Walk(40, 1, 7, array[] of {"victim"})), tagof Rmsg.Walk, "walk to the victim");
	refused(t, rpc(t, fd, ref Tmsg.Remove(41, 7)), RO, "a remove");
	t.assert(exists(DIR + "/victim"), "the file is still there");
	refused(t, rpc(t, fd, ref Tmsg.Stat(42, 7)), "no such fid", "the fid of the refused remove");

	# and the connection goes on
	want(t, rpc(t, fd, ref Tmsg.Walk(50, 1, 7, array[] of {"victim"})), tagof Rmsg.Walk, "the fid again");
	want(t, rpc(t, fd, ref Tmsg.Stat(51, 7)), tagof Rmsg.Stat, "stat after");
	want(t, rpc(t, fd, ref Tmsg.Clunk(52, 7)), tagof Rmsg.Clunk, "clunk after");
}

# what a mount of the export may do: the count of changes that were made
changes(t: ref T, m: string, ro: int): int
{
	n := 0;
	t.assertseq(readfile(m + "/file"), TEXT, "a mount reads the file");
	(ok, nil) := sys->stat(m + "/sub/inside");
	t.assert(ok >= 0, "and walks below");

	fd := sys->open(m + "/file", Sys->OWRITE);
	err := sys->sprint("%r");
	if(fd != nil){
		if(sys->write(fd, array of byte "W", 1) == 1)
			n++;
		fd = nil;
	}else if(ro)
		t.assert(contains(err, RO), "an open to write is refused, saying why: " + err);

	fd = sys->open(m + "/file", Sys->OREAD|Sys->OTRUNC);
	if(fd != nil)
		n++;
	fd = sys->create(m + "/made", Sys->OWRITE, 8r664);
	err = sys->sprint("%r");
	if(fd != nil)
		n++;
	else if(ro)
		t.assert(contains(err, RO), "a create is refused, saying why: " + err);
	fd = nil;

	d := sys->nulldir;
	d.mode = 8r600;
	if(sys->wstat(m + "/file", d) >= 0)
		n++;
	if(sys->remove(m + "/victim") >= 0)
		n++;
	else if(ro)
		t.assert(contains(sys->sprint("%r"), RO), "a remove is refused, saying why");
	return n;
}

mounted(t: ref T, flag: int): string
{
	fd := exported(t, flag);
	sys->unmount(nil, MNT);
	if(sys->mount(fd, nil, MNT, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	return MNT;
}

testMount(t: ref T)
{
	m := mounted(t, Sys->EXPASYNC|Sys->EXPREADONLY);
	t.asserteq(changes(t, m, 1), 0, "nothing is changed through a mount of a read-only export");
	t.assertseq(readfile(DIR + "/file"), TEXT, "the file is as it was");
	t.asserteq(mode(DIR + "/file"), 8r664, "and its mode");
	t.assert(exists(DIR + "/victim") && !exists(DIR + "/made"), "nothing removed and nothing made");
	# a second remove: the first's fid was clunked, not left in use
	t.assert(sys->remove(m + "/victim") < 0 && exists(DIR + "/victim"), "refused again");
	sys->unmount(nil, MNT);
}

waiter(fd: ref Sys->FD, flag: int, c: chan of int)
{
	c <-= sys->export(fd, DIR, flag);
}

testWait(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	c := chan[1] of int;
	spawn waiter(p[0], Sys->EXPWAIT|Sys->EXPREADONLY, c);
	p[0] = nil;
	sys->unmount(nil, MNT);
	if(sys->mount(p[1], nil, MNT, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	p[1] = nil;
	t.asserteq(changes(t, MNT, 1), 0, "nothing is changed through a read-only export that is waited for");
	sys->unmount(nil, MNT);
	t.asserteq(<-c, 0, "and it returns when its client has gone");
}

testBadFlag(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	t.asserteq(sys->export(p[0], DIR, 4), -1, "a flag that is none is refused");
	t.assert(contains(sys->sprint("%r"), "bad arg"), "saying so");
	t.asserteq(sys->export(p[0], DIR, 16r100|Sys->EXPASYNC), -1, "and with EXPASYNC");
	t.asserteq(sys->export(p[0], DIR, int 16r80000000|Sys->EXPREADONLY), -1, "and the top bit");
	# the connection was not taken by the refused calls
	t.asserteq(sys->export(p[0], DIR, Sys->EXPASYNC|Sys->EXPREADONLY), 0, "the flags there are, on the same connection");
}

# last, since it changes the tree: the refusals above are the flag's
testWritable(t: ref T)
{
	m := mounted(t, Sys->EXPASYNC);
	t.asserteq(changes(t, m, 0), 5, "an export without the flag writes, truncates, creates, wstats and removes");
	t.assert(!exists(DIR + "/victim") && exists(DIR + "/made"), "the tree is changed");
	sys->unmount(nil, MNT);
}

setup(): string
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	cleanup();
	if(sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s: %r", DIR);
	if(sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s: %r", MNT);
	if(sys->create(DIR + "/sub", Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		return sys->sprint("create %s/sub: %r", DIR);
	for(l := "file" :: "victim" :: "sub/inside" :: nil; l != nil; l = tl l){
		fd := sys->create(DIR + "/" + hd l, Sys->OWRITE, 8r664);
		if(fd == nil || sys->fprint(fd, "%s", TEXT) < 0)
			return sys->sprint("create %s/%s: %r", DIR, hd l);
	}
	# whatever the host's umask made of it
	d := sys->nulldir;
	d.mode = 8r664;
	if(sys->wstat(DIR + "/file", d) < 0)
		return sys->sprint("wstat %s/file: %r", DIR);
	return nil;
}

cleanup()
{
	sys->unmount(nil, MNT);
	for(l := "made" :: "madedir" :: "renamed" :: "victim" :: "file" :: "sub/inside" :: "sub" :: nil; l != nil; l = tl l)
		sys->remove(DIR + "/" + hd l);
	sys->remove(DIR);
	sys->remove(MNT);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(styx == nil){
		sys->fprint(sys->fildes(2), "cannot load styx: %r\n");
		raise "fail:cannot load styx";
	}
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	sys->pctl(Sys->FORKNS, nil);
	if((e := setup()) != nil){
		sys->fprint(sys->fildes(2), "export_readonly_test: %s\n", e);
		raise "fail:setup";
	}

	run("Raw", testRaw);
	run("Mount", testMount);
	run("Wait", testWait);
	run("BadFlag", testBadFlag);
	run("Writable", testWritable);

	cleanup();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
