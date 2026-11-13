implement MntSmallMsizeTest;

#
# The mount driver (emu/port/devmnt.c, os/port/devmnt.c) against a 9P
# server that chooses the smallest message size it may, 256: a request
# that does not fit it (a walk of sixteen long names) is refused at once,
# saying so.  convS2M gives 0 for such a request and mountio tested for
# less than 0: it wrote no bytes and queued the call.  A pipe's reader
# takes a write of nothing for the end of the file, so the server went and
# the mount with it ("i/o on hungup channel", for every user of it); over
# a connection that carries no empty write, the caller waited for the
# answer to a request never sent.  A request that fits is still sent, and
# the mount goes on working after the one refused.
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

MntSmallMsizeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mnt_smallmsize_test.b";
MNT: con "/tmp/mnt_smallmsize_test";
MSIZE: con 256;

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

rootdir(): Sys->Dir
{
	d := sys->zerodir;
	d.name = "/";
	d.uid = "none";
	d.gid = "none";
	d.muid = "none";
	d.qid = Sys->Qid(big 1, 0, Sys->QTDIR);
	d.mode = Sys->DMDIR | 8r555;
	return d;
}

# a server of one empty directory; each walk it is sent is counted
server(fd: ref Sys->FD, walks: chan of int)
{
	n := 0;
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			break;
		r: ref Rmsg;
		pick x := m {
		Readerror =>
			walks <-= -1;
			return;
		Version =>
			r = ref Rmsg.Version(x.tag, MSIZE, "9P2000");
		Attach =>
			r = ref Rmsg.Attach(x.tag, Sys->Qid(big 1, 0, Sys->QTDIR));
		Walk =>
			if(len x.names == 0)
				r = ref Rmsg.Walk(x.tag, nil);
			else{
				n++;
				r = ref Rmsg.Error(x.tag, "not here");
			}
		Stat =>
			r = ref Rmsg.Stat(x.tag, rootdir());
		Clunk =>
			r = ref Rmsg.Clunk(x.tag);
		Flush =>
			r = ref Rmsg.Flush(x.tag);
		* =>
			r = ref Rmsg.Error(x.tag, "not served");
		}
		b := r.pack();
		if(sys->write(fd, b, len b) != len b)
			break;
	}
	walks <-= n;
}

statter(path: string, pidc: chan of int, done: chan of string)
{
	pidc <-= sys->pctl(0, nil);
	(ok, nil) := sys->stat(path);
	if(ok < 0)
		done <-= sys->sprint("%r");
	else
		done <-= "";
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# stat(path), given 5 seconds: its error, "" for none, nil if it never returned
statin(path: string): string
{
	pidc := chan of int;
	done := chan[1] of string;
	spawn statter(path, pidc, done);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 5000);
	alt{
	e := <-done =>
		return e;
	<-tc =>
		kill(pid);
		return nil;
	}
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testSmallMsize(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	walks := chan[1] of int;
	spawn server(p[1], walks);
	p[1] = nil;
	if(sys->mount(p[0], nil, MNT, Sys->MREPL, "") < 0)
		t.fatal(sys->sprint("mount: %r"));
	p[0] = nil;

	# a request that fits is sent, and answered by the server
	e := statin(MNT + "/short");
	if(e == nil)
		t.fatal("a stat of a short name never returned");
	t.assert(contains(e, "not here"), "a walk that fits reaches the server: " + e);

	# sixteen names of twenty bytes: 369 bytes of Twalk for 256
	path := MNT;
	for(i := 0; i < 16; i++)
		path += sys->sprint("/name%.2d-of-twenty-byt", i);
	e = statin(path);
	if(e == nil){
		t.error("a walk that does not fit the server's message size was waited for, never sent");
	}else
		t.assert(contains(e, "does not fit"), "a walk that does not fit the server's message size is refused saying so: " + e);

	# and the mount goes on working
	e = statin(MNT + "/again");
	if(e == nil)
		t.fatal("a stat after the refused walk never returned");
	t.assert(contains(e, "not here"), "the mount works after the refused walk: " + e);

	sys->unmount(nil, MNT);
	tc := chan[1] of int;
	spawn timer(tc, 5000);
	alt{
	n := <-walks =>
		t.asserteq(n, 2, "walks the server was sent");
	<-tc =>
		t.error("the server did not end with its mount");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || styx == nil){
		sys->fprint(sys->fildes(2), "cannot load testing or styx: %r\n");
		raise "fail:load";
	}
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	sys->pctl(Sys->FORKNS, nil);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);

	run("SmallMsize", testSmallMsize);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
