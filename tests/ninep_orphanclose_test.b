implement NinepOrphancloseTest;

#
# ninep_orphanclose_test - a 9P connection closed with calls on it that
# killed readers gave up on (devmnt's orphans) closes cleanly.
#
# The server answers a version, an attach, a walk, an open, a clunk and
# (late, so several are out at once) a stat, and never a read or a
# flush.  Readers killed in their reads flush them, wait Mntwaitms for
# the flushes' answers, and go, leaving each read and its flush on the
# mount's queue for replies that never come.  The mount is then
# unmounted and its connection closed: muxclose frees what is queued.
#
# It walked the queue freeing each call where it stood, and freeing a
# read looks along the queue for a flush naming it: the calls before it,
# freed (to the allocator once devmnt's ten spare Mntrpcs are kept), were
# read again with the mount's lock held.  macOS ARM64 CI's
# ninep_disconnect_test faulted there ("PC in mntfree", "fault while
# holding 1 lock(s)"); under tools/sanemu this test is a
# heap-use-after-free.  Round after round, so a run with the fault in it
# meets freed memory reused.
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

NinepOrphancloseTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ninep_orphanclose_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
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

ROOT: con 0;
FILE: con 1;
NREADERS: con 12;	# each leaves a read and a flush queued
NSTATS: con 12;		# out at once: devmnt's spare Mntrpcs filled after
ROUNDS: con 4;

# the server's replies, one write each, from the server and the stats'
# late answers alike
replies(fd: ref Sys->FD, c: chan of array of byte)
{
	while((b := <-c) != nil)
		sys->write(fd, b, len b);
}

latestat(tag: int, c: chan of array of byte)
{
	sys->sleep(300);
	d := sys->zerodir;
	d.name = "f";
	d.uid = d.gid = d.muid = "none";
	d.qid = Sys->Qid(big FILE, 0, Sys->QTFILE);
	d.mode = 8r666;
	c <-= (ref Rmsg.Stat(tag, d)).pack();	# buffered: never waits
}

# until the connection is closed; then says so on gone
serve(fd: ref Sys->FD, pidc: chan of int, gone: chan of int)
{
	sys->pctl(Sys->FORKNS|Sys->NEWPGRP, nil);
	pidc <-= sys->pctl(0, nil);
	c := chan[256] of array of byte;
	spawn replies(fd, c);
	rootqid := Sys->Qid(big ROOT, 0, Sys->QTDIR);
	fileqid := Sys->Qid(big FILE, 0, Sys->QTFILE);
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			break;
		r: ref Rmsg;
		pick x := m {
		Version =>
			r = ref Rmsg.Version(x.tag, x.msize, "9P2000");
		Attach =>
			r = ref Rmsg.Attach(x.tag, rootqid);
		Walk =>
			if(len x.names == 0)
				r = ref Rmsg.Walk(x.tag, nil);
			else if(len x.names == 1 && x.names[0] == "f")
				r = ref Rmsg.Walk(x.tag, array[] of {fileqid});
			else
				r = ref Rmsg.Error(x.tag, "file does not exist");
		Open =>
			r = ref Rmsg.Open(x.tag, fileqid, 0);
		Stat =>
			spawn latestat(x.tag, c);
			continue;
		Clunk =>
			r = ref Rmsg.Clunk(x.tag);
		Read =>
			continue;	# never
		Flush =>
			continue;	# never
		Readerror =>
			break;
		* =>
			r = ref Rmsg.Error(m.tag, "no");
		}
		c <-= r.pack();
	}
	c <-= nil;
	gone <-= 1;
}

# reads the server's file, which is never answered
reader(dir: string)
{
	fd := sys->open(dir + "/f", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[10] of byte;
	sys->read(fd, b, len b);
}

# the readers' group, its pid sent
readers(dir: string, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	for(i := 0; i < NREADERS; i++)
		spawn reader(dir);
	c := chan of int;
	<-c;
}

stater(dir: string, done: chan of int)
{
	(ok, nil) := sys->stat(dir + "/f");
	done <-= ok;
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

# Prog pid's group's Progs, by /prog's pgrp field
ingroup(pgrp: int): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			sfd := sys->open("/prog/" + d[i].name + "/status", Sys->OREAD);
			if(sfd == nil)
				continue;
			b := array[256] of byte;
			k := sys->read(sfd, b, len b);
			if(k <= 0)
				continue;
			(nil, f) := sys->tokenize(string b[0:k], " ");
			if(f != nil && tl f != nil && int hd tl f == pgrp)
				n++;
		}
	}
	return n;
}

round(t: ref T, r: int)
{
	dir := sys->sprint("/tmp/ninep_orphanclose.%d", r);
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	pidc := chan of int;
	gone := chan of int;
	spawn serve(p[1], pidc, gone);
	srvpid := <-pidc;
	p[1] = nil;
	if(sys->mount(p[0], nil, dir, Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	p[0] = nil;

	# readers killed in their reads: each read and its flush left queued
	spawn readers(dir, pidc);
	rgrp := <-pidc;
	sys->sleep(300);	# into the reads
	sys->fprint(sys->open(sys->sprint("/prog/%d/ctl", rgrp), Sys->OWRITE), "killgrp");
	for(i := 0; i < 50 && ingroup(rgrp) > 0; i++)
		sys->sleep(100);
	if(ingroup(rgrp) > 0)
		t.fatal(sys->sprint("round %d: the killed readers were not gone in 5s", r));

	# answered calls out at once, so the spares are full at the close
	done := chan of int;
	for(i = 0; i < NSTATS; i++)
		spawn stater(dir, done);
	for(i = 0; i < NSTATS; i++)
		if(<-done < 0)
			t.error(sys->sprint("round %d: a stat beside the orphans failed", r));

	# the connection closed, the orphans on it
	if(sys->unmount(nil, dir) < 0)
		t.fatal(sys->sprint("round %d: unmount: %r", r));
	tc := chan of int;
	spawn timer(tc, 5000);
	alt {
	<-gone =>
		;
	<-tc =>
		sys->fprint(sys->open(sys->sprint("/prog/%d/ctl", srvpid), Sys->OWRITE), "killgrp");
		t.fatal(sys->sprint("round %d: the connection was not closed in 5s of the unmount", r));
	}
	sys->remove(dir);
}

testCloseWithOrphans(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	for(r := 0; r < ROUNDS; r++)
		round(t, r);
	# and the mount driver still works: one more, with a stat answered
	dir := "/tmp/ninep_orphanclose.after";
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	pidc := chan of int;
	gone := chan of int;
	spawn serve(p[1], pidc, gone);
	<-pidc;
	p[1] = nil;
	t.assert(sys->mount(p[0], nil, dir, Sys->MREPL, nil) >= 0, "a mount after the closes");
	p[0] = nil;
	(ok, nil) := sys->stat(dir + "/f");
	t.asserteq(ok, 0, "a stat through it");
	sys->unmount(nil, dir);
	<-gone;
	sys->remove(dir);
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("CloseWithOrphans", testCloseWithOrphans);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
