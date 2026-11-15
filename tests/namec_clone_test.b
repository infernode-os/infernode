implement NamecCloneTest;

#
# Names looked up through a mount whose server refuses to clone a
# channel, or has gone (chan.c: namec, walk; both kernels).
#
# A walk that crosses a mount point takes a copy of the mounted channel
# (a 9P walk of no names), and so does the end of every walk from a
# shared channel.  The copy raises when the server answers with an error,
# when its connection has hung up, or when the caller is interrupted.
# walk() had no handler round either copy, and the handler in namec that
# should have caught what an open's copy held gave back less than it had:
#
#  - a create whose last element exists is retried as an open, and for
#    that second walk namec pointed the process's error string at a
#    buffer in its own frame.  When the walk raised, nothing put the
#    pointer back: the process's error string was namec's dead frame for
#    the rest of its life.  %r read the kernel's stack back, and every
#    later error text was written over the frames of whatever call was
#    then running there: the emulator faulted in a later open;
#
#  - every look-up of a name below such a mount kept the channel it had
#    walked to, its name and the mount's head: 512 bytes of the kernel's
#    main pool each, for good, and a fid on the device below.  A server
#    that has exited while still mounted is enough, and a program asking
#    once a second whether a file of its is there yet;
#
#  - an open of the mount point itself kept the name: 384 bytes each.
#
# The server here is the test's own, on a pipe.
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

NamecCloneTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/namec_clone_test.b";
MNT: con "/tmp/namec_clone_mnt";
NOCLONE: con "no clone today";

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

# what the server is to do; changed by the test while it serves
Srv: adt {
	refuseclone:	int;	# a walk of no names is refused
	armclone:	int;	# the next ".." answered sets refuseclone
	dotdotfail:	int;	# this many walks of ".." are refused first
	openfail:	int;	# opens are refused
	die:	int;	# stop at the next request, answering nothing
};

Fid: adt {
	fid:	int;
	path:	int;
};

setfid(s: array of Fid, fid, path: int): array of Fid
{
	for(i := 0; i < len s; i++)
		if(s[i].fid == fid || s[i].fid == -1){
			s[i] = Fid(fid, path);
			return s;
		}
	n := array[len s + 64] of { * => Fid(-1, 0) };
	n[0:] = s;
	n[len s] = Fid(fid, path);
	return n;
}

getfid(s: array of Fid, fid: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i].fid == fid)
			return s[i].path;
	return 0;
}

delfid(s: array of Fid, fid: int)
{
	for(i := 0; i < len s; i++)
		if(s[i].fid == fid)
			s[i] = Fid(-1, 0);
}

qid(p: int): Sys->Qid
{
	return Sys->Qid(big p, 0, Sys->QTDIR);
}

dirof(p: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = "d";
	if(p == 0)
		d.name = "/";
	d.uid = d.gid = d.muid = "none";
	d.qid = qid(p);
	d.mode = Sys->DMDIR | 8r777;
	return d;
}

# a root directory holding one directory, "d"
serve(fd: ref Sys->FD, sv: ref Srv)
{
	s := array[64] of { * => Fid(-1, 0) };
	for(;;){
		t := Tmsg.read(fd, 8192+24);
		if(t == nil || sv.die)
			return;
		r: ref Rmsg;
		pick m := t {
		Readerror =>
			return;
		Version =>
			r = ref Rmsg.Version(m.tag, 8192+24, "9P2000");
		Attach =>
			s = setfid(s, m.fid, 0);
			r = ref Rmsg.Attach(m.tag, qid(0));
		Walk =>
			p := getfid(s, m.fid);
			if(len m.names == 0){
				if(sv.refuseclone)
					r = ref Rmsg.Error(m.tag, NOCLONE);
				else{
					s = setfid(s, m.newfid, p);
					r = ref Rmsg.Walk(m.tag, array[0] of Sys->Qid);
				}
			}else if(len m.names == 1 && m.names[0] == ".."){
				if(sv.dotdotfail > 0){
					sv.dotdotfail--;
					r = ref Rmsg.Error(m.tag, "no dotdot yet");
				}else{
					s = setfid(s, m.newfid, 0);
					r = ref Rmsg.Walk(m.tag, array[1] of { qid(0) });
					if(sv.armclone){
						sv.armclone = 0;
						sv.refuseclone = 1;
					}
				}
			}else if(len m.names == 1 && m.names[0] == "d"){
				s = setfid(s, m.newfid, 1);
				r = ref Rmsg.Walk(m.tag, array[1] of { qid(1) });
			}else
				r = ref Rmsg.Error(m.tag, "does not exist");
		Open =>
			if(sv.openfail)
				r = ref Rmsg.Error(m.tag, "no open");
			else
				r = ref Rmsg.Open(m.tag, qid(getfid(s, m.fid)), 0);
		Create =>
			r = ref Rmsg.Error(m.tag, "no create");
		Read =>
			r = ref Rmsg.Read(m.tag, array[0] of byte);
		Clunk =>
			delfid(s, m.fid);
			r = ref Rmsg.Clunk(m.tag);
		Stat =>
			r = ref Rmsg.Stat(m.tag, dirof(getfid(s, m.fid)));
		* =>
			r = ref Rmsg.Error(m.tag, "no");
		}
		b := r.pack();
		if(sys->write(fd, b, len b) != len b)
			return;
	}
}

# the server mounted at MNT, in the caller's name space; nil and why if not
mountsrv(): (ref Srv, string)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return (nil, sys->sprint("pipe: %r"));
	sv := ref Srv(0, 0, 0, 0, 0);
	spawn serve(p[0], sv);
	p[0] = nil;
	if(sys->mount(p[1], nil, MNT, Sys->MREPL, nil) < 0)
		return (nil, sys->sprint("mount %s: %r", MNT));
	return (sv, nil);
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

marker(): string
{
	s := "";
	for(i := 0; i < 100; i++)
		s[len s] = 'A' + i%26;
	return s;
}

#
# In a Prog and a name space of its own (the name space is replaced):
# the server's tree made the root, then a create of "/d/.." that the
# server refuses, whose second walk of ".." comes back to the root, which
# the server will not clone.  Answers on c: "" or what was wrong.
#
createretry(c: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	(sv, err) := mountsrv();
	if(sv == nil){
		c <-= "skip: " + err;
		return;
	}
	if(sys->chdir(MNT + "/d") < 0){
		c <-= sys->sprint("skip: chdir: %r");
		return;
	}
	sys->pctl(Sys->NEWNS, nil);	# the root is now the server's "d"
	(ok, nil) := sys->stat("/d");
	if(ok < 0){
		c <-= sys->sprint("skip: stat /d in the new name space: %r");
		return;
	}

	sv.dotdotfail = 1;	# the create's first walk of its last element fails
	sv.armclone = 1;	# and the walk after the refused create cannot clone
	fd := sys->create("/d/..", Sys->OREAD, Sys->DMDIR | 8r777);
	e := sys->sprint("%r");
	sv.refuseclone = 0;
	if(fd != nil){
		c <-= "the create was not refused";
		return;
	}
	# the create's own reason, or the clone's: whole, and nothing else
	if(e != "no create" && !(len e < 64 && contains(e, NOCLONE))){
		c <-= sys->sprint("the refused create's error is %q", e);
		return;
	}

	# the error string is the Prog's: calls that succeed leave it alone
	m := marker();
	sys->werrstr(m);
	for(i := 0; i < 5; i++){
		sys->stat("/d");
		sys->millisec();
	}
	e = sys->sprint("%r");
	if(e != m){
		c <-= sys->sprint("the error string changed under calls that succeeded: %d bytes, %q", len e, e);
		return;
	}

	# and calls that fail write their reasons into it, not over the kernel
	for(i = 0; i < 2000; i++){
		sys->open("/nonesuch/at/all", Sys->OREAD);
		sys->werrstr(m);
		sys->stat("/d/x/y");
	}
	e = sys->sprint("%r");
	if(!contains(e, "does not exist")){
		c <-= sys->sprint("after 2000 failing opens and stats the error is %q", e);
		return;
	}
	c <-= "";
}

testCreateRetryErrstr(t: ref T)
{
	c := chan of string;
	spawn createretry(c);
	r := <-c;
	if(len r > 6 && r[0:6] == "skip: ")
		t.skip(r[6:]);
	t.assertseq(r, "", "a create retried as an open whose walk cannot clone leaves the error string the Prog's");
	(ok, nil) := sys->stat("/dev/null");
	t.asserteq(ok, 0, "the kernel answers afterwards");
}

N: con 5000;
KEEP: con 128*1024;	# a leak is 384 or 512 bytes a call

# calls of f, and the main pool's growth over them
grow(f: ref fn(), n: int): int
{
	for(i := 0; i < 200; i++)
		f();
	before := mainused();
	for(i = 0; i < n; i++)
		f();
	return mainused() - before;
}

statbelow()
{
	sys->stat(MNT + "/x");
}

openmnt()
{
	sys->open(MNT, Sys->OREAD);
}

testWalkCloneRefused(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	sys->pctl(Sys->FORKNS, nil);
	(sv, err) := mountsrv();
	if(sv == nil)
		t.skip(err);

	# the clone answered, the name not there
	d := grow(statbelow, N);
	t.log(sys->sprint("%d stats of a name that is not there: %d bytes of the main pool", N, d));
	t.assert(d < KEEP, sys->sprint("%d stats of a name that is not there keep %d bytes of the main pool", N, d));

	sv.refuseclone = 1;
	(ok, nil) := sys->stat(MNT + "/x");
	e := sys->sprint("%r");
	t.assert(ok < 0, "a name below a mount that cannot be cloned is not found");
	t.assert(contains(e, "clone failed") && contains(e, NOCLONE),
		sys->sprint("the error says the clone failed and why: %q", e));
	d = grow(statbelow, N);
	t.log(sys->sprint("%d stats below a mount whose clone is refused: %d bytes of the main pool", N, d));
	t.assert(d < KEEP,
		sys->sprint("%d stats below a mount whose clone is refused keep %d bytes of the main pool (%d each)", N, d, d/N));

	# and the mount works once the server clones again
	sv.refuseclone = 0;
	(ok, nil) = sys->stat(MNT + "/d");
	t.asserteq(ok, 0, sys->sprint("the mount is walked once its server clones again: %r"));
	sys->unmount(nil, MNT);
}

testWalkServerGone(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	sys->pctl(Sys->FORKNS, nil);
	(sv, err) := mountsrv();
	if(sv == nil)
		t.skip(err);

	sv.die = 1;
	sys->stat(MNT + "/x");	# the server reads this and goes
	sys->sleep(100);
	(ok, nil) := sys->stat(MNT + "/x");
	t.assert(ok < 0, "a name below a mount whose server has gone is not found");
	t.log(sys->sprint("a stat below a mount whose server has gone: %r"));
	d := grow(statbelow, N);
	t.log(sys->sprint("%d stats below a mount whose server has gone: %d bytes of the main pool", N, d));
	t.assert(d < KEEP,
		sys->sprint("%d stats below a mount whose server has gone keep %d bytes of the main pool (%d each)", N, d, d/N));
	sys->unmount(nil, MNT);
}

testOpenCloneRefused(t: ref T)
{
	if(mainused() < 0)
		t.skip("no /dev/memory");
	sys->pctl(Sys->FORKNS, nil);
	(sv, err) := mountsrv();
	if(sv == nil)
		t.skip(err);

	# the clone answered, the open refused
	sv.openfail = 1;
	d := grow(openmnt, N);
	t.log(sys->sprint("%d opens the server refuses: %d bytes of the main pool", N, d));
	t.assert(d < KEEP, sys->sprint("%d opens the server refuses keep %d bytes of the main pool", N, d));

	sv.openfail = 0;
	sv.refuseclone = 1;
	fd := sys->open(MNT, Sys->OREAD);
	e := sys->sprint("%r");
	t.assert(fd == nil, "a mount point that cannot be cloned is not opened");
	t.assert(contains(e, "clone failed") && contains(e, NOCLONE),
		sys->sprint("the error says the clone failed and why: %q", e));
	d = grow(openmnt, N);
	t.log(sys->sprint("%d opens of a mount point whose clone is refused: %d bytes of the main pool", N, d));
	t.assert(d < KEEP,
		sys->sprint("%d opens of a mount point whose clone is refused keep %d bytes of the main pool (%d each)", N, d, d/N));

	sv.refuseclone = 0;
	fd = sys->open(MNT, Sys->OREAD);
	t.assert(fd != nil, sys->sprint("the mount point opens once its server clones again: %r"));
	fd = nil;
	sys->unmount(nil, MNT);
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
	testing->init();
	if(styx == nil){
		sys->fprint(sys->fildes(2), "cannot load styx: %r\n");
		raise "fail:cannot load styx";
	}
	styx->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("CreateRetryErrstr", testCreateRetryErrstr);
	run("WalkCloneRefused", testWalkCloneRefused);
	run("WalkServerGone", testWalkServerGone);
	run("OpenCloneRefused", testOpenCloneRefused);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
