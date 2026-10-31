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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("RemoveClunksOnError");
	run("RemoveRaceThroughMount");

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
