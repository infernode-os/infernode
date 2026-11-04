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
		"FarOffsetRefused" =>
			testFarOffsetRefused(t);
		"LongWstatServed" =>
			testLongWstatServed(t);
		"HoleReadsZeros" =>
			testHoleReadsZeros(t);
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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
