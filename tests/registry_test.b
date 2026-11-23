implement RegistryTest;

#
# ndb/registry (registry(4)) on a pipe, reached by two attaches in two
# users' names, by an export of one of them, and in raw Styx.
#
# A remove of the registry's root, through a mount or through an export of
# one, ended the registry (the fid canremove refused was nil, and was
# clunked all the same); so did a remove that lost a race with the close
# of the fid that made the service (the owner of a service that had gone),
# and a clunk of a fid not in use.  The fid that made a service was known
# by its number, which a client uses again once it is free: any user
# opening a persistent service ORCLOSE, for reading, removed it at the
# close.  A first write of a name and an odd number of words was refused
# and the service listed under the name all the same.  "." and ".." were
# service names, and a newline in an attribute was another service's line
# in index.
#
# Ownership is by the name of the attach: a second attach cannot rewrite
# or remove what the first registered.
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

RegistryTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Registry: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

SRCFILE: con "/tests/registry_test.b";
DIR: con "/tmp/registry_test";
A: con DIR + "/a";	# the test's own attach
B: con DIR + "/b";	# another user's
X: con DIR + "/x";	# an export of A

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
	sys->unmount(nil, X);
	sys->unmount(nil, A);
	sys->unmount(nil, B);
}

regargs: list of string;	# options for the next registry started

regproc(fd: ref Sys->FD, sync: chan of string)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	reg := load Registry "/dis/ndb/registry.dis";
	if(reg == nil){
		sync <-= sys->sprint("cannot load ndb/registry: %r");
		return;
	}
	sync <-= nil;
	args := "registry" :: regargs;
	regargs = nil;
	reg->init(nil, args);	# returns when its connection ends
}

# a registry on a pipe; the end to mount or to speak Styx on
startreg(t: ref T): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	sync := chan of string;
	spawn regproc(p[0], sync);
	if((e := <-sync) != nil)
		t.fatal(e);
	return p[1];
}

asbob(fd: ref Sys->FD, c: chan of string)
{
	ufd := sys->open("/dev/user", Sys->OWRITE);
	if(ufd == nil || sys->fprint(ufd, "regbob") < 0){
		c <-= sys->sprint("cannot become another user: %r");
		return;
	}
	ufd = nil;
	if(sys->mount(fd, nil, B, Sys->MREPL|Sys->MCREATE, nil) < 0){
		c <-= sys->sprint("mount as another user: %r");
		return;
	}
	c <-= nil;
}

# the registry mounted twice: at A in the test's name, at B in another's
twomounts(t: ref T): ref Sys->FD
{
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	c := chan of string;
	spawn asbob(fd, c);
	if((e := <-c) != nil)
		t.fatal(e);
	return fd;
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

readproc(file: string, c: chan of string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		c <-= sys->sprint("ERR open: %r");
		return;
	}
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	if(n < 0)
		s = sys->sprint("ERR read: %r");
	c <-= s;
}

# a file's text; "TIMEOUT" if the registry no longer answers
readfile(file: string): string
{
	c := chan[1] of string;
	spawn readproc(file, c);
	spawn timer(c, 5000);
	return <-c;
}

removeproc(file: string, c: chan of string)
{
	if(sys->remove(file) < 0)
		c <-= sys->sprint("%r");
	else
		c <-= "removed";
}

tremove(file: string): string
{
	c := chan[1] of string;
	spawn removeproc(file, c);
	spawn timer(c, 5000);
	return <-c;
}

# register through dir; the fd that made the service, and the write's error
register(dir: string, words: string): (ref Sys->FD, string)
{
	fd := sys->open(dir + "/new", Sys->ORDWR);
	if(fd == nil)
		return (nil, sys->sprint("open new: %r"));
	b := array of byte words;
	if(sys->write(fd, b, len b) < 0)
		return (fd, sys->sprint("%r"));
	return (fd, nil);
}

listed(dir: string, name: string): int
{
	(n, lines) := sys->tokenize(readfile(dir + "/index"), "\n");
	for(; n > 0; n--){
		(nil, f) := sys->tokenize(hd lines, " ");
		if(f != nil && hd f == name)
			return 1;
		lines = tl lines;
	}
	return 0;
}

testRootRemove(t: ref T)
{
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	(sfd, err) := register(A, "tcp!keep!1 persist 1");
	t.assertnil(err, "a service is registered");
	sfd = nil;

	r := tremove(A);
	t.assert(r != "removed" && r != "TIMEOUT", "a remove of the registry's root is refused: " + r);
	t.assert(listed(A, "tcp!keep!1"), "and the registry still answers, with its services");

	# the same from the far side of an export of the mount
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	if(sys->export(p[0], A, Sys->EXPASYNC) < 0)
		t.fatal(sys->sprint("export: %r"));
	p[0] = nil;
	if(sys->mount(p[1], nil, X, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount of the export: %r"));
	t.assert(listed(X, "tcp!keep!1"), "the registry through an export of its mount");
	r = tremove(X);
	t.assert(r != "removed" && r != "TIMEOUT", "a remove of the export's root is refused: " + r);
	t.assert(listed(X, "tcp!keep!1"), "and the registry still answers through the export");
	t.assert(listed(A, "tcp!keep!1"), "and through the mount");
	sys->unmount(nil, X);
}

racer(dir: string, stop: chan of int, done: chan of int)
{
	for(;;){
		alt{
		<-stop =>
			done <-= 1;
			return;
		* =>
			;
		}
		(fd, nil) := register(dir, "racer");
		fd = nil;
	}
}

remover(dir: string, stop: chan of int, done: chan of int)
{
	for(;;){
		alt{
		<-stop =>
			done <-= 1;
			return;
		* =>
			;
		}
		sys->remove(dir + "/racer");
	}
}

testRemoveRace(t: ref T)
{
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	stop := chan[2] of int;
	done := chan[2] of int;
	spawn racer(A, stop, done);
	spawn remover(A, stop, done);
	sys->sleep(1500);
	stop <-= 1;
	stop <-= 1;
	tc := chan[1] of string;
	spawn timer(tc, 5000);
	for(i := 0; i < 2; i++)
		alt{
		<-done =>
			;
		<-tc =>
			t.error("a registration or a remove never returned");
			i = 2;
		}
	r := readfile(A + "/index");
	t.assert(r != "TIMEOUT" && (len r < 3 || r[0:3] != "ERR"),
		"after a service was registered, closed and removed at once for 1.5 s the registry answers: " + r);
}

testOrclose(t: ref T)
{
	twomounts(t);
	(fd, err) := register(A, "tcp!alice!1 persist 1");
	t.assertnil(err, "a persistent service is registered");
	fd = nil;	# its creator's fid is closed; the number is free

	# another user opens it for reading, to be removed at close: at
	# once, so that the first fid it is given has the creator's number
	opened := 0;
	for(i := 0; i < 50; i++){
		ofd := sys->open(B + "/tcp!alice!1", Sys->OREAD|Sys->ORCLOSE);
		if(ofd != nil)
			opened++;
		ofd = nil;
	}
	t.asserteq(opened, 0, "another user cannot open a service to be removed at close");
	t.assert(listed(A, "tcp!alice!1"), "and the service outlives its creator's close and the fifty tries");
	ofd := sys->open(B + "/tcp!alice!1", Sys->OREAD);
	t.assert(ofd != nil, "another user can open it to read");
	ofd = nil;
	t.assert(listed(A, "tcp!alice!1"), "and closing that leaves it");

	# its owner can
	ofd = sys->open(A + "/tcp!alice!1", Sys->OREAD|Sys->ORCLOSE);
	t.assert(ofd != nil, sys->sprint("its owner can open it to be removed at close: %r"));
	ofd = nil;
	t.assert(!listed(A, "tcp!alice!1"), "and it goes at the close");

	# one that is not to persist goes with the fid that made it, and only then
	(fd, err) = register(A, "tcp!alice!2");
	t.assertnil(err, "a service that is not to persist");
	ofd = sys->open(A + "/tcp!alice!2", Sys->OREAD);
	ofd = nil;
	t.assert(listed(A, "tcp!alice!2"), "is still there when another fid on it is closed");
	fd = nil;
	t.assert(!listed(A, "tcp!alice!2"), "and gone when the fid that made it is");
}

testOwner(t: ref T)
{
	twomounts(t);
	(fd, err) := register(A, "tcp!alice!1 persist 1 addr 10.0.0.1");
	t.assertnil(err, "the first user registers a service");
	fd = nil;
	(d0, nil) := sys->stat(B + "/tcp!alice!1");
	t.asserteq(d0, 0, "the second user sees it");

	wfd := sys->open(B + "/tcp!alice!1", Sys->OWRITE);
	t.assert(wfd == nil, "another user cannot open it to write");
	r := tremove(B + "/tcp!alice!1");
	t.assert(r != "removed" && r != "TIMEOUT", "another user cannot remove it: " + r);
	t.assertseq(readfile(A + "/tcp!alice!1"), "tcp!alice!1 addr 10.0.0.1 persist 1\n", "it is as its owner wrote it");

	(bfd, berr) := register(B, "tcp!bob!1 persist 1");
	t.assertnil(berr, "the second user registers a service of its own");
	bfd = nil;
	r = tremove(A + "/tcp!bob!1");
	t.assert(r != "removed" && r != "TIMEOUT", "which the first cannot remove: " + r);

	wfd = sys->open(A + "/tcp!alice!1", Sys->OWRITE);
	t.assert(wfd != nil, sys->sprint("the owner opens its service to write: %r"));
	if(wfd != nil)
		t.assert(sys->fprint(wfd, "addr 10.0.0.2") > 0, sys->sprint("and changes it: %r"));
	wfd = nil;
	t.assertseq(readfile(A + "/tcp!alice!1"), "tcp!alice!1 addr 10.0.0.2 persist 1\n", "the change is made");
	t.assertseq(tremove(A + "/tcp!alice!1"), "removed", "the owner removes it");
	t.assert(!listed(A, "tcp!alice!1") && listed(A, "tcp!bob!1"), "it has gone and the other's has not");
}

testWrites(t: ref T)
{
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	(hfd, err) := register(A, "half a");
	t.assertseq(err, "odd attribute/value pairs", "a name and one word is refused");
	t.assert(!listed(A, "half"), "and no service is listed under the name");
	(ok, nil) := sys->stat(A + "/half");
	t.assert(ok < 0, "nor is there a file of the name");
	t.assert(hfd != nil && sys->fprint(hfd, "half a b") > 0, sys->sprint("the same fid then names it properly: %r"));
	t.assertseq(readfile(A + "/half"), "half a b\n", "and it is as written");
	hfd = nil;

	names := array[] of {"..", ".", "new", "index", "a/b"};
	for(i := 0; i < len names; i++){
		(nfd, nerr) := register(A, names[i]);
		t.assert(nerr != nil, sys->sprint("%q is not a service name", names[i]));
		nfd = nil;
	}
	(vfd, verr) := register(A, "'tcp!x!1' descr 'one\ntcp!forged!1 addr 6.6.6.6'");
	t.assertseq(verr, "bad character in attribute", "a newline in a value is refused");
	t.assert(!listed(A, "tcp!forged!1") && !listed(A, "tcp!x!1"), "and adds no line to index");
	vfd = nil;
	(vfd, verr) = register(A, "'tcp!y!1' 'na\nme' v");
	t.assert(verr != nil, "a newline in an attribute's name is refused");
	vfd = nil;
	(vfd, verr) = register(A, "'tcp!z!1' descr 'two words' empty ''");
	t.assertnil(verr, "blanks and an empty value are taken");
	t.assertseq(readfile(A + "/tcp!z!1"), "tcp!z!1 empty '' descr 'two words'\n", "and read back quoted");
}

# What the registry holds is counted: services in all and by one owner,
# a service's attributes and their bytes.  Nothing was.
testLimits(t: ref T)
{
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	N: con 128;	# registry.b's Maxperowner
	fds := array[N] of ref Sys->FD;
	ok := 0;
	for(i := 0; i < N; i++){
		err: string;
		(fds[i], err) = register(A, sys->sprint("tcp!many!%d", i));
		if(err == nil)
			ok++;
	}
	t.asserteq(ok, N, "services registered by one user");
	xfd := sys->open(A + "/new", Sys->ORDWR);
	e := sys->sprint("%r");
	t.assert(xfd == nil, "one more is refused");
	if(xfd == nil)
		t.assert(e != nil && len e >= 8, "and says why: " + e);
	fds[0] = nil;
	(rfd, rerr) := register(A, "tcp!room!1");
	t.assertnil(rerr, "one closed makes room for one");

	long := "";
	for(i = 0; i < 5000; i++)
		long[len long] = 'v';
	t.assertseq(string sys->fprint(rfd, "descr %s", long) + " " + sys->sprint("%r"), "-1 service description too long",
		"a description of 5000 bytes is refused");
	many := "";
	for(i = 0; i < 65; i++)
		many += sys->sprint(" a%d v", i);
	t.assert(sys->fprint(rfd, "%s", many[1:]) < 0, "sixty-five attributes are refused");
	t.assertseq(readfile(A + "/tcp!room!1"), "tcp!room!1\n", "and nothing of either write was taken");
	t.assert(sys->fprint(rfd, "addr 10.0.0.1") > 0, "an ordinary attribute is still taken");
	rfd = nil;
	for(i = 0; i < N; i++)
		fds[i] = nil;
}

# A service registered to persist stayed for good when its owner had
# gone.  It lasts -t seconds (a day) from its owner's last write.
testExpiry(t: ref T)
{
	# times are whole seconds: a life of 4 and waits of 2 leave a second
	# to spare each way
	regargs = "-t" :: "4" :: nil;
	fd := startreg(t);
	if(sys->mount(fd, nil, A, Sys->MREPL|Sys->MCREATE, nil) < 0)
		t.fatal(sys->sprint("mount: %r"));
	(pfd, err) := register(A, "tcp!stays!1 persist 1");
	t.assertnil(err, "a persistent service is registered");
	pfd = nil;
	(hfd, herr) := register(A, "tcp!held!1");
	t.assertnil(herr, "and one whose file is kept open");
	t.assert(listed(A, "tcp!stays!1"), "the persistent one is listed after its creator closed");
	sys->sleep(2000);
	wfd := sys->open(A + "/tcp!stays!1", Sys->OWRITE);
	t.assert(wfd != nil && sys->fprint(wfd, "addr 10.0.0.2") > 0, sys->sprint("its owner writes it again: %r"));
	wfd = nil;
	sys->sleep(2100);
	t.assert(listed(A, "tcp!stays!1"), "and it lasts from that write");
	sys->sleep(4200);
	t.assert(!listed(A, "tcp!stays!1"), "a persistent service not written for its life is removed");
	t.assert(listed(A, "tcp!held!1"), "one whose creator still has it open is not");
	hfd = nil;
}

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	p := m.pack();
	if(sys->write(fd, p, len p) != len p)
		t.fatal(sys->sprint("write of a request: %r"));
	c := chan[1] of ref Rmsg;
	spawn rmsgproc(fd, c);
	tc := chan[1] of string;
	spawn timer(tc, 5000);
	alt{
	r := <-c =>
		if(r == nil)
			t.fatal("the registry hung up");
		return r;
	<-tc =>
		t.fatal("the registry did not answer " + m.text());
	}
	return nil;
}

rmsgproc(fd: ref Sys->FD, c: chan of ref Rmsg)
{
	c <-= Rmsg.read(fd, 64*1024);
}

iserror(r: ref Rmsg): int
{
	return tagof r == tagof Rmsg.Error;
}

testRawStyx(t: ref T)
{
	fd := startreg(t);
	r := rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000"));
	t.assert(tagof r == tagof Rmsg.Version, "version");
	t.assert(iserror(rpc(t, fd, ref Tmsg.Clunk(1, 77))), "a clunk of a fid not in use is an error");
	t.assert(iserror(rpc(t, fd, ref Tmsg.Remove(2, 78))), "a remove of a fid not in use is an error");
	r = rpc(t, fd, ref Tmsg.Attach(3, 1, Styx->NOFID, "raw", ""));
	t.assert(tagof r == tagof Rmsg.Attach, "and the registry still attaches");
	t.assert(iserror(rpc(t, fd, ref Tmsg.Remove(4, 1))), "a remove of the root fid is an error");
	r = rpc(t, fd, ref Tmsg.Attach(5, 1, Styx->NOFID, "raw", ""));
	t.assert(tagof r == tagof Rmsg.Attach, "which clunks the fid, as a remove does");

	# an event fid given up by a remove leaves nothing behind for the
	# next fid of its number
	r = rpc(t, fd, ref Tmsg.Walk(6, 1, 2, array[] of {"event"}));
	t.assert(tagof r == tagof Rmsg.Walk, "walk to event");
	r = rpc(t, fd, ref Tmsg.Open(7, 2, Sys->OREAD));
	t.assert(tagof r == tagof Rmsg.Open, "open event");
	t.assert(iserror(rpc(t, fd, ref Tmsg.Remove(8, 2))), "event cannot be removed");
	r = rpc(t, fd, ref Tmsg.Walk(9, 1, 2, array[] of {"index"}));
	t.assert(tagof r == tagof Rmsg.Walk, "the fid's number is free again");
	r = rpc(t, fd, ref Tmsg.Open(10, 2, Sys->OREAD));
	t.assert(tagof r == tagof Rmsg.Open, "open index");
	r = rpc(t, fd, ref Tmsg.Read(11, 2, big 0, 100));
	t.assert(tagof r == tagof Rmsg.Read, "and index reads");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	styx = load Styx Styx->PATH;
	if(styx == nil){
		sys->fprint(sys->fildes(2), "cannot load styx: %r\n");
		raise "fail:cannot load styx";
	}
	styx->init();

	sys->pctl(Sys->FORKNS, nil);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(A, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(B, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(X, Sys->OREAD, Sys->DMDIR|8r755);

	run("RootRemove", testRootRemove);
	run("RemoveRace", testRemoveRace);
	run("Orclose", testOrclose);
	run("Owner", testOwner);
	run("Writes", testWrites);
	run("RawStyx", testRawStyx);
	run("Limits", testLimits);
	run("Expiry", testExpiry);

	sys->remove(A);
	sys->remove(B);
	sys->remove(X);
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
