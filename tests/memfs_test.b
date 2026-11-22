implement MemfsTest;

#
# memfs(4) spoken to in Styx directly, so that what the kernel's mount
# driver does in a race can be done in order.
#
# Two loops on one board wrote, read and removed the same file in /tmp:
# one's remove found the file gone and failed, and memfs kept that fid.
# The kernel had counted it clunked (a remove clunks the fid whether or
# not it succeeds), reused the number, and was told "fid in use" -- the
# open in the other loop failed and its console session ended.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxlib.m";
	styxlib: Styxlib;
	Styxserver, Chan: import styxlib;

include "testing.m";
	testing: Testing;
	T: import testing;

MemfsTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/memfs_test.b";
MSIZE: con 8192;

passed := 0;
failed := 0;
skipped := 0;

# Cases are called by name, not passed as "ref fn": a module that takes a
# reference to its own function and also loads another module (memfs
# here) links against a garbled import list (#776).
run(name: string)
{
	t := testing->newTsrc(name, SRCFILE);
	{
		case name {
		"RemoveClunksOnError" =>
			testRemoveClunksOnError(t);
		"RemoveRaceThroughMount" =>
			testRemoveRaceThroughMount(t);
		"OversizeStatBecomesError" =>
			testOversizeStatBecomesError(t);
		"WstatLength" =>
			testWstatLength(t);
		"FarOffsetRefused" =>
			testFarOffsetRefused(t);
		"LongWstatServed" =>
			testLongWstatServed(t);
		"HoleReadsZeros" =>
			testHoleReadsZeros(t);
		"WstatOwner" =>
			testWstatOwner(t);
		"OpenMode" =>
			testOpenMode(t);
		"RemovedWhileOpen" =>
			testRemovedWhileOpen(t);
		"WalkAndNames" =>
			testWalkAndNames(t);
		"DirectoriesCharged" =>
			testDirectoriesCharged(t);
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

Cmd: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# memfs -s serves its fd 0: give it one end of a pipe and keep the other
startmemfs(): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return nil;
	sync := chan of int;
	spawn server(p[1], sync);
	<-sync;
	p[1] = nil;
	return p[0];
}

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

user(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "none";
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "none";
	return string b[0:n];
}

tag := 1;

# one message out, its reply back; "" or the error the server gave
rpc(fd: ref Sys->FD, m: ref Tmsg): (ref Rmsg, string)
{
	m.tag = tag++;
	b := m.pack();
	if(sys->write(fd, b, len b) != len b)
		return (nil, sys->sprint("write: %r"));
	r := Rmsg.read(fd, MSIZE);
	if(r == nil)
		return (nil, "eof");
	pick e := r {
	Error =>
		return (r, e.ename);
	Readerror =>
		return (r, e.error);
	}
	return (r, "");
}

testRemoveClunksOnError(t: ref T)
{
	fd := startmemfs();
	if(fd == nil)
		t.fatal(sys->sprint("pipe: %r"));

	(nil, err) := rpc(fd, ref Tmsg.Version(0, MSIZE, "9P2000"));
	t.assertseq(err, "", "version");
	# memfs's root belongs to whoever started it
	(nil, err) = rpc(fd, ref Tmsg.Attach(0, 0, Styx->NOFID, user(), ""));
	t.assertseq(err, "", "attach");

	# a file, made through fid 1 and let go
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 0, 1, nil));
	t.assertseq(err, "", "walk to a second fid on the root");
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 1, "f", 8r666, Sys->OWRITE));
	t.assertseq(err, "", "create f");
	(nil, err) = rpc(fd, ref Tmsg.Clunk(0, 1));
	t.assertseq(err, "", "clunk the creating fid");

	# two removers walk to it; the first wins
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 0, 2, array[] of {"f"}));
	t.assertseq(err, "", "first remover walks to f");
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 0, 3, array[] of {"f"}));
	t.assertseq(err, "", "second remover walks to f");
	(nil, err) = rpc(fd, ref Tmsg.Remove(0, 2));
	t.assertseq(err, "", "the first remove succeeds");
	(nil, err) = rpc(fd, ref Tmsg.Remove(0, 3));
	t.assertsne(err, "", "the second remove fails: the file is gone");

	# the second remove clunked fid 3 all the same, so the number is free
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 0, 3, nil));
	t.assertseq(err, "", "fid 3 can be used again after its failed remove");
	(nil, err) = rpc(fd, ref Tmsg.Clunk(0, 3));
	t.assertseq(err, "", "and clunked");
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 0, 2, nil));
	t.assertseq(err, "", "fid 2 can be used again after its remove");
}

# the board's race through the kernel: two loops that each create, write,
# read and remove the same file. Losing the race to remove is fine; being
# told "fid in use" afterwards is the bug.
testRemoveRaceThroughMount(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of int;
	spawn server(p[1], sync);
	<-sync;
	p[1] = nil;
	if(sys->mount(p[0], nil, "/n", Sys->MREPL | Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	p = nil;

	done := chan of string;
	spawn racer(done);
	spawn racer(done);
	e1 := <-done;
	e2 := <-done;
	t.assertseq(e1, "", "first loop: no fid in use");
	t.assertseq(e2, "", "second loop: no fid in use");
}

racer(done: chan of string)
{
	b := array of byte "hello\n";
	for(i := 0; i < 2000; i++) {
		fd := sys->create("/n/f", Sys->ORDWR, 8r666);
		if(fd == nil) {
			if(fidinuse())
				break;
			continue;
		}
		sys->write(fd, b, len b);
		fd = nil;
		fd = sys->open("/n/f", Sys->OREAD);
		if(fd == nil && fidinuse())
			break;
		fd = nil;
		if(sys->remove("/n/f") < 0 && fidinuse())
			break;
		if(i % 16 == 0)
			sys->sleep(0);
	}
	if(fidinuse())
		done <-= sys->sprint("%r");
	else
		done <-= "";
}

fidinuse(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 6 <= len e; i++)
		if(e[i:i+6] == "fid in")
			return 1;
	return 0;
}

testOversizeStatBecomesError(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	srv := ref Styxserver(p[1], array[32] of list of ref Chan, "none", 128);
	name := array[200] of byte;
	for(i := 0; i < len name; i++)
		name[i] = byte 'a';
	d := sys->zerodir;
	d.name = string name;
	d.uid = d.gid = d.muid = "none";
	t.assert(srv.reply(ref Rmsg.Stat(7, d)) > 0, "write bounded stat reply");
	r := Rmsg.read(p[0], 128);
	pick m := r {
	Error =>
		t.assert(m.tag == 7, "error preserves request tag");
	* =>
		t.error("oversize Rstat was not converted to Rerror");
	}
}

# memfs mounted on /n in a name space of the caller's own
mountmemfs(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of int;
	spawn server(p[1], sync);
	<-sync;
	p[1] = nil;
	if(sys->mount(p[0], nil, "/n", Sys->MREPL | Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
}

# Offsets past an int are refused, and memfs goes on: one was cut to a
# negative int and indexed the block table (array bounds error, the
# server gone and /tmp with it on the native kernel; tools/nativefuzz).
testFarOffsetRefused(t: ref T)
{
	mountmemfs(t);
	fd := sys->create("/n/far", Sys->ORDWR, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	# in a Prog of its own, and timed: a memfs that died never answers
	res := chan of string;
	spawn faroffsets(fd, res);
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	e := <-res =>
		t.assertseq(e, "", "offsets past an int refused");
	<-tc =>
		t.fatal("memfs did not answer in 5s (the server died)");
	}
	(n, d) := sys->stat("/n/far");
	t.asserteq(n, 0, "memfs still answers");
	t.assert(d.length == big 5, "and the file is what was written");
}

faroffsets(fd: ref Sys->FD, res: chan of string)
{
	b := array of byte "hello";
	offs := array[] of {big 16r7FFFFFFC, big 16r80000000, big 16r80000008, big 1<<40, big -2,
		big 16r7FFFFFFFFFFFFFFF, big 16r7FFFFFFFFFFFFFFF - big 3};
	for(i := 0; i < len offs; i++){
		if(sys->pwrite(fd, b, len b, offs[i]) != -1){
			res <-= sys->sprint("pwrite at %bd was not refused", offs[i]);
			return;
		}
		r := array[8] of byte;
		if(sys->pread(fd, r, len r, offs[i]) > 0){
			res <-= sys->sprint("pread at %bd read something", offs[i]);
			return;
		}
	}
	if(sys->pwrite(fd, b, len b, big 0) != len b){
		res <-= sys->sprint("a write at 0: %r");
		return;
	}
	res <-= "";
}

# A Twstat of a stat 256 bytes or more (a long name): Styx refused it,
# memfs's reader ended on the refusal, and memfs waited for ever.
testLongWstatServed(t: ref T)
{
	mountmemfs(t);
	fd := sys->create("/n/short", Sys->ORDWR, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	fd = nil;
	d := sys->nulldir;
	d.name = "";
	for(i := 0; i < 210; i++)
		d.name[i] = 'a' + i%26;
	done := chan of int;
	spawn wstatter("/n/short", d, done);
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	r := <-done =>
		t.asserteq(r, 0, "the rename to a 210-byte name");
	<-tc =>
		t.fatal("the rename was not answered in 5s");
	}
	(n, nil) := sys->stat("/n/" + d.name);
	t.asserteq(n, 0, "the file has its long name");
}

# A write past the end leaves blocks never written; a read of them is
# zeros. They were nil, sliced: an array bounds error, the server gone.
testHoleReadsZeros(t: ref T)
{
	mountmemfs(t);
	fd := sys->create("/n/sparse", Sys->ORDWR, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	res := chan of string;
	spawn holes(fd, res);
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	e := <-res =>
		t.assertseq(e, "", "a file with holes reads");
	<-tc =>
		t.fatal("memfs did not answer in 5s (the server died)");
	}
}

holes(fd: ref Sys->FD, res: chan of string)
{
	b := array of byte "end";
	if(sys->pwrite(fd, b, len b, big 5000) != len b){
		res <-= sys->sprint("pwrite past the end: %r");
		return;
	}
	r := array[5003] of byte;
	n := sys->pread(fd, r, len r, big 0);
	if(n != len r){
		res <-= sys->sprint("read %d of %d: %r", n, len r);
		return;
	}
	for(i := 0; i < 5000; i++)
		if(r[i] != byte 0){
			res <-= sys->sprint("byte %d of the hole is %d", i, int r[i]);
			return;
		}
	if(string r[5000:] != "end"){
		res <-= "the end is not what was written";
		return;
	}
	n = sys->pread(fd, r[0:10], 10, big 1000);
	if(n != 10){
		res <-= sys->sprint("a read inside the hole: %d: %r", n);
		return;
	}
	res <-= "";
}

wstatter(p: string, d: Sys->Dir, done: chan of int)
{
	done <-= sys->wstat(p, d);
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

# memfs -s with arguments of the test's choosing
startmemfsargs(args: list of string): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return nil;
	sync := chan of int;
	spawn serverargs(p[1], args, sync);
	<-sync;
	p[1] = nil;
	return p[0];
}

serverargs(fd: ref Sys->FD, args: list of string, sync: chan of int)
{
	sys->pctl(Sys->NEWFD, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	m := load Cmd "/dis/memfs.dis";
	sync <-= 1;
	if(m != nil)
		m->init(nil, "memfs" :: "-s" :: args);
}

# a memfs, spoken to: fid 0 its root for its owner, fid 100 for another user
OWNER: con 0;
OTHER: con 100;
twousers(t: ref T, args: list of string): ref Sys->FD
{
	fd := startmemfsargs(args);
	if(fd == nil)
		t.fatal(sys->sprint("pipe: %r"));
	(nil, err) := rpc(fd, ref Tmsg.Version(0, MSIZE, "9P2000"));
	t.assertseq(err, "", "version");
	(nil, err) = rpc(fd, ref Tmsg.Attach(0, OWNER, Styx->NOFID, user(), ""));
	t.assertseq(err, "", "attach as its owner");
	(nil, err) = rpc(fd, ref Tmsg.Attach(0, OTHER, Styx->NOFID, "mallory", ""));
	t.assertseq(err, "", "attach as another user");
	return fd;
}

# name made in the directory of fid dir, through fid f, which is then clunked
mk(t: ref T, fd: ref Sys->FD, dir, f: int, name: string, perm: int)
{
	(nil, err) := rpc(fd, ref Tmsg.Walk(0, dir, f, nil));
	t.assertseq(err, "", "a fid for making " + name);
	mode := Sys->OWRITE;
	if(perm & Sys->DMDIR)
		mode = Sys->OREAD;
	(nil, err) = rpc(fd, ref Tmsg.Create(0, f, name, perm, mode));
	t.assertseq(err, "", "create " + name);
	(nil, err) = rpc(fd, ref Tmsg.Clunk(0, f));
	t.assertseq(err, "", "clunk it");
}

statof(t: ref T, fd: ref Sys->FD, f: int): Sys->Dir
{
	(r, err) := rpc(fd, ref Tmsg.Stat(0, f));
	if(err != "")
		t.fatal("stat: " + err);
	pick x := r {
	Stat =>
		return x.stat;
	}
	t.fatal("stat: not a stat reply");
	return sys->zerodir;
}

# how many names of a walk were found
walked(fd: ref Sys->FD, ffid, nfid: int, names: array of string): int
{
	(r, err) := rpc(fd, ref Tmsg.Walk(0, ffid, nfid, names));
	if(err != "")
		return 0;
	pick x := r {
	Walk =>
		if(len x.qids == len names)
			rpc(fd, ref Tmsg.Clunk(0, nfid));
		return len x.qids;
	}
	return 0;
}

# A file's owner is not for wstat to change: a wstat that gave a file's
# own mode and time back, and a new owner, was asked nothing.
testWstatOwner(t: ref T)
{
	fd := twousers(t, nil);
	mk(t, fd, OWNER, 1, "f", 8r600);

	(nil, err) := rpc(fd, ref Tmsg.Walk(0, OTHER, 101, array[] of {"f"}));
	t.assertseq(err, "", "another user walks to the file");
	d := statof(t, fd, 101);
	t.assertseq(d.uid, user(), "it is its maker's");

	d.uid = "mallory";
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 101, d));
	t.assertsne(err, "", "another user's wstat of the owner, mode and time as they are, is refused");
	nd := sys->nulldir;
	nd.uid = "mallory";
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 101, nd));
	t.assertsne(err, "", "and of the owner alone");
	nd = sys->nulldir;
	nd.mode = 8r666;
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 101, nd));
	t.assertsne(err, "", "and of the mode");
	(nil, err) = rpc(fd, ref Tmsg.Open(0, 101, Sys->OREAD));
	t.assertsne(err, "", "and the file is still not theirs to open");
	t.assertseq(statof(t, fd, 101).uid, user(), "it is still its maker's");

	# its owner changes its mode and time, and may not give it away
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 2, array[] of {"f"}));
	t.assertseq(err, "", "its owner walks to it");
	nd = sys->nulldir;
	nd.mode = 8r640;
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 2, nd));
	t.assertseq(err, "", "its owner changes its mode");
	t.asserteq(statof(t, fd, 2).mode & 8r777, 8r640, "the mode set");
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 2, sys->nulldir));
	t.assertseq(err, "", "a wstat that changes nothing");
	nd = sys->nulldir;
	nd.mode = 8r640 | Sys->DMDIR;
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 2, nd));
	t.assert((statof(t, fd, 2).mode & Sys->DMDIR) == 0, "a file is not made a directory");
	nd = sys->nulldir;
	nd.name = "a/b";
	(nil, err) = rpc(fd, ref Tmsg.Wstat(0, 2, nd));
	t.assertsne(err, "", "a file is not renamed to a path");
}

# A fid reads and writes as it was opened.
testOpenMode(t: ref T)
{
	fd := twousers(t, nil);
	(nil, err) := rpc(fd, ref Tmsg.Walk(0, OWNER, 1, nil));
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 1, "g", 8r644, Sys->OWRITE));
	t.assertseq(err, "", "create g, open to write");
	(nil, err) = rpc(fd, ref Tmsg.Write(0, 1, big 0, array of byte "hello"));
	t.assertseq(err, "", "written");
	(nil, err) = rpc(fd, ref Tmsg.Read(0, 1, big 0, 5));
	t.assertsne(err, "", "a fid open to write is not read");
	rpc(fd, ref Tmsg.Clunk(0, 1));

	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OTHER, 101, array[] of {"g"}));
	t.assertseq(err, "", "another user walks to it");
	(nil, err) = rpc(fd, ref Tmsg.Open(0, 101, Sys->OWRITE));
	t.assertsne(err, "", "and may not open it to write");
	(nil, err) = rpc(fd, ref Tmsg.Open(0, 101, Sys->OREAD));
	t.assertseq(err, "", "and opens it to read");
	(nil, err) = rpc(fd, ref Tmsg.Write(0, 101, big 0, array of byte "HELLO"));
	t.assertsne(err, "", "a fid open to read is not written");
	(r, rerr) := rpc(fd, ref Tmsg.Read(0, 101, big 0, 5));
	t.assertseq(rerr, "", "and is read");
	pick x := r {
	Read =>
		t.assertseq(string x.data, "hello", "what its owner wrote");
	}

	# an open fid is not walked
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 101, 101, array[] of {".."}));
	t.assertsne(err, "", "an open fid is not walked");
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, 101, 102, nil));
	t.assertsne(err, "", "nor walked to a new one");
	(nil, err) = rpc(fd, ref Tmsg.Clunk(0, 101));
	t.assertseq(err, "", "it is clunked where it was");

	# a directory is opened to read only
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 3, nil));
	(nil, err) = rpc(fd, ref Tmsg.Open(0, 3, Sys->ORDWR));
	t.assertsne(err, "", "a directory is not opened to read and write");
}

# A file removed while another fid has it open is in no directory: a
# wstat or a remove through that fid found nil where its directory was,
# and the server went.
testRemovedWhileOpen(t: ref T)
{
	fd := twousers(t, nil);
	(nil, err) := rpc(fd, ref Tmsg.Walk(0, OWNER, 1, nil));
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 1, "h", 8r644, Sys->ORDWR));
	t.assertseq(err, "", "create h and keep it open");
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 2, array[] of {"h"}));
	t.assertseq(err, "", "a second fid on it");
	(nil, err) = rpc(fd, ref Tmsg.Remove(0, 2));
	t.assertseq(err, "", "removed through the second");

	(r, werr) := rpc(fd, ref Tmsg.Wstat(0, 1, sys->nulldir));
	t.assert(r != nil && werr != "eof", "a wstat through the open fid is answered: " + werr);
	nd := sys->nulldir;
	nd.name = "again";
	(r, werr) = rpc(fd, ref Tmsg.Wstat(0, 1, nd));
	t.assert(r != nil && werr != "" && werr != "eof", "a rename of it is refused: " + werr);
	(r, werr) = rpc(fd, ref Tmsg.Write(0, 1, big 0, array of byte "still here"));
	t.assertseq(werr, "", "it is still written through the open fid");
	(r, werr) = rpc(fd, ref Tmsg.Remove(0, 1));
	t.assert(r != nil && werr != "" && werr != "eof", "a second remove of it is refused: " + werr);
	(nil, err) = rpc(fd, ref Tmsg.Stat(0, OWNER));
	t.assertseq(err, "", "and the server still answers");
	t.asserteq(walked(fd, OWNER, 5, array[] of {"h"}), 0, "the file is gone");

	# a directory removed is no place to make a file
	mk(t, fd, OWNER, 6, "d", Sys->DMDIR | 8r777);
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 7, array[] of {"d"}));
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 8, array[] of {"d"}));
	t.assertseq(err, "", "two fids on a directory");
	(nil, err) = rpc(fd, ref Tmsg.Remove(0, 7));
	t.assertseq(err, "", "removed through one");
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 8, "x", 8r644, Sys->OWRITE));
	t.assertsne(err, "", "nothing is made in it through the other");
}

# A directory is searched by those its mode lets, and names are names.
testWalkAndNames(t: ref T)
{
	fd := twousers(t, nil);
	mk(t, fd, OWNER, 1, "p", Sys->DMDIR | 8r700);
	(nil, err) := rpc(fd, ref Tmsg.Walk(0, OWNER, 2, array[] of {"p"}));
	t.assertseq(err, "", "its owner walks into p");
	mk(t, fd, 2, 3, "f", 8r644);
	mk(t, fd, OWNER, 4, "plain", 8r644);

	t.asserteq(walked(fd, OWNER, 10, array[] of {"p", "f"}), 2, "its owner walks to p/f");
	t.asserteq(walked(fd, OTHER, 110, array[] of {"p", "f"}), 1, "another user gets as far as p, of mode 0700");
	t.asserteq(walked(fd, OTHER, 111, array[] of {"plain"}), 1, "and reaches a file in the root");
	t.asserteq(walked(fd, OWNER, 11, array[] of {"plain", ".."}), 1, "a file has no ..");
	t.asserteq(walked(fd, OWNER, 12, array[] of {"plain", "x"}), 1, "nor anything in it");

	bad := array[] of {"", "a/b", "/", ".", ".."};
	for(i := 0; i < len bad; i++){
		(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 20, nil));
		(nil, err) = rpc(fd, ref Tmsg.Create(0, 20, bad[i], 8r644, Sys->OWRITE));
		t.assertsne(err, "", sys->sprint("a file named %q is not made", bad[i]));
		rpc(fd, ref Tmsg.Clunk(0, 20));
	}
	long := "";
	for(i = 0; i < 300; i++)
		long[len long] = 'n';
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 20, nil));
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 20, long, 8r644, Sys->OWRITE));
	t.assertsne(err, "", "nor one with a name of 300 bytes");
	rpc(fd, ref Tmsg.Clunk(0, 20));
	mk(t, fd, OWNER, 21, long[0:210], 8r644);
}

# Directories count against the size memfs was given.
testDirectoriesCharged(t: ref T)
{
	fd := twousers(t, "-m" :: "8192" :: nil);
	made := 0;
	err := "";
	for(i := 0; i < 200 && err == ""; i++){
		(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 1, nil));
		if(err != "")
			break;
		(nil, err) = rpc(fd, ref Tmsg.Create(0, 1, sys->sprint("d%d", i), Sys->DMDIR | 8r777, Sys->OREAD));
		rpc(fd, ref Tmsg.Clunk(0, 1));
		if(err == "")
			made++;
	}
	t.assert(made > 0 && made <= 16, sys->sprint("directories made in 8192 bytes: %d (%s)", made, err));
	# and given back
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 2, array[] of {"d0"}));
	t.assertseq(err, "", "walk to the first");
	(nil, err) = rpc(fd, ref Tmsg.Remove(0, 2));
	t.assertseq(err, "", "remove it");
	(nil, err) = rpc(fd, ref Tmsg.Walk(0, OWNER, 3, nil));
	(nil, err) = rpc(fd, ref Tmsg.Create(0, 3, "again", Sys->DMDIR | 8r777, Sys->OREAD));
	t.assertseq(err, "", "and there is room for another");
}

# A wstat that gives a length sets it: the file is cut, or lengthened
# with zeros.  The length was not looked at and the wstat answered as
# done, so a file "truncated" was as long as before.
testWstatLength(t: ref T)
{
	mountmemfs(t);
	fd := sys->create("/n/len", Sys->ORDWR, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create: %r"));
	b := array of byte "0123456789";
	t.asserteq(sys->write(fd, b, len b), len b, "ten bytes written");
	res := chan[1] of string;
	spawn lengths(fd, res);
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	e := <-res =>
		t.assertseq(e, "", "a file's length set by wstat");
	<-tc =>
		t.fatal("memfs did not answer in 5s");
	}

	# what a cut gives back can be written again
	fd = nil;
	mfd := twousers(t, "-m" :: "8192" :: nil);
	mk(t, mfd, OWNER, 1, "full", 8r666);
	(nil, err) := rpc(mfd, ref Tmsg.Walk(0, OWNER, 2, array[] of {"full"}));
	(nil, err) = rpc(mfd, ref Tmsg.Open(0, 2, Sys->ORDWR));
	t.assertseq(err, "", "open a file in a store of 8192 bytes");
	d := sys->nulldir;
	d.length = big 7000;
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, 2, d));
	t.assertseq(err, "", "its length set to 7000");
	mk(t, mfd, OWNER, 3, "other", 8r666);
	(nil, err) = rpc(mfd, ref Tmsg.Walk(0, OWNER, 4, array[] of {"other"}));
	(nil, err) = rpc(mfd, ref Tmsg.Open(0, 4, Sys->ORDWR));
	d.length = big 7000;
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, 4, d));
	t.assertseq(err, "filesystem full", "a second file of 7000 does not fit");
	d.length = big 0;
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, 2, d));
	t.assertseq(err, "", "the first cut to nothing");
	d.length = big 7000;
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, 4, d));
	t.assertseq(err, "", "and the second then fits");
	(nil, err) = rpc(mfd, ref Tmsg.Walk(0, OTHER, 5, array[] of {"other"}));
	d.length = big 1;
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, 5, d));
	t.assertseq(err, "permission denied", "a user who may not write the file may not set its length");
	(nil, err) = rpc(mfd, ref Tmsg.Wstat(0, OWNER, d));
	t.assert(err != "", "a directory's length is not set: " + err);
}

lengths(fd: ref Sys->FD, res: chan of string)
{
	d := sys->nulldir;
	d.length = big 4;
	if(sys->fwstat(fd, d) < 0){
		res <-= sys->sprint("wstat to 4: %r");
		return;
	}
	(ok, st) := sys->fstat(fd);
	if(ok < 0 || st.length != big 4){
		res <-= sys->sprint("after a wstat to 4 the length is %bd", st.length);
		return;
	}
	buf := array[64] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	if(n != 4 || string buf[0:n] != "0123"){
		res <-= sys->sprint("after a wstat to 4 the file reads %d bytes: %q", n, string buf[0:n]);
		return;
	}
	d.length = big 8;
	if(sys->fwstat(fd, d) < 0){
		res <-= sys->sprint("wstat to 8: %r");
		return;
	}
	n = sys->pread(fd, buf, len buf, big 0);
	if(n != 8 || string buf[0:4] != "0123"){
		res <-= sys->sprint("after a wstat to 8 the file reads %d bytes", n);
		return;
	}
	for(i := 4; i < 8; i++)
		if(buf[i] != byte 0){
			res <-= sys->sprint("lengthened, byte %d is %d, not 0 (what was cut came back)", i, int buf[i]);
			return;
		}
	d.length = big 3000;
	if(sys->fwstat(fd, d) < 0){
		res <-= sys->sprint("wstat to 3000: %r");
		return;
	}
	big3 := array[4000] of byte;
	n = sys->pread(fd, big3, len big3, big 0);
	if(n != 3000){
		res <-= sys->sprint("after a wstat to 3000 the file reads %d bytes", n);
		return;
	}
	for(i = 4; i < 3000; i++)
		if(big3[i] != byte 0){
			res <-= sys->sprint("lengthened to 3000, byte %d is not 0", i);
			return;
		}
	d.length = big 1 << 31;
	if(sys->fwstat(fd, d) >= 0){
		res <-= "a length of 2^31 was taken";
		return;
	}
	res <-= "";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxlib = load Styxlib Styxlib->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil || styx == nil || styxlib == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load";
	}
	styx->init();
	styxlib->init(styx);
	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("RemoveClunksOnError");
	run("RemoveRaceThroughMount");
	run("OversizeStatBecomesError");
	run("FarOffsetRefused");
	run("LongWstatServed");
	run("HoleReadsZeros");
	run("WstatOwner");
	run("OpenMode");
	run("RemovedWhileOpen");
	run("WalkAndNames");
	run("DirectoriesCharged");
	run("WstatLength");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
