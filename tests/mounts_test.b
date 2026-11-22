implement MountsTest;

#
# mount(1), import(4), 9export and export(4) as they start and end.
#
#  - mount {command} gave the command a copy of mount's fd table, the
#    mount's own end of the command's pipe in it: the command never saw
#    the end of its input when it was unmounted, and stayed for good.
#  - mount takes whoever answers with a certificate of its signer; -u
#    names who it must be.
#  - with no user name (no /dev/user) mount's key directory was
#    /usr//keyring/, whatever is there.
#  - import, 9export and mount -9 without -A asked factotum for Plan 9's
#    p9any, which is gone: they say so first, and import -A (which there
#    was not) is the far end of 9export -A.  It was:
#  - import, and 9export without -A, run Plan 9's p9sk1, whose DES no
#    kernel is built with now: they got as far as factotum, which ended
#    in an exception.  They say so before anything is dialled or said.
#  - 9export did not read what its caller asked for after "impo": one
#    that said ssl was exported to in clear.
#  - export took a lone - for an option.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

MountsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mounts_test.b";
D: con "/tmp/mounts_test";

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

mkdir(d: string)
{
	sys->create(d, Sys->OREAD, Sys->DMDIR | 8r777);
}

mkfile(f, s: string)
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# a port nothing has, by asking for one
freeport(t: ref T): string
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("no loopback tcp: %r"));
	(nil, f) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(len f < 2)
		t.fatal("no local address");
	return hd tl f;
}

# the Progs running in module mod: (pid, ...)
progs(mod: string): list of int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of int;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			(nf, f) := sys->tokenize(readfile("/prog/" + d[i].name + "/status"), " \t\n");
			if(nf < 1)
				continue;
			last := "";
			for(; f != nil; f = tl f)
				last = hd f;
			# "Export[$Sys]" while it is in a system call
			for(j := 0; j < len last; j++)
				if(last[j] == '['){
					last = last[0:j];
					break;
				}
			if(last == mod)
				l = int d[i].name :: l;
		}
	}
	return l;
}

among(p: int, l: list of int): int
{
	for(; l != nil; l = tl l)
		if(hd l == p)
			return 1;
	return 0;
}

# those of now that were not there before
fresh(now, before: list of int): list of int
{
	l: list of int;
	for(; now != nil; now = tl now)
		if(!among(hd now, before))
			l = hd now :: l;
	return l;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

killall(l: list of int)
{
	for(; l != nil; l = tl l)
		kill(hd l);
}

# wait until none of the Progs in mod that were not there before is left
gone(mod: string, before: list of int, ms: int): int
{
	for(e := 0; e < ms; e += 100){
		if(fresh(progs(mod), before) == nil)
			return 1;
		sys->sleep(100);
	}
	return fresh(progs(mod), before) == nil;
}

appear(mod: string, before: list of int, ms: int): list of int
{
	for(e := 0; e < ms; e += 50){
		if((l := fresh(progs(mod), before)) != nil)
			return l;
		sys->sleep(50);
	}
	return nil;
}

# a command's init in this process: what it raised, or nil
call(path: string, args: list of string): string
{
	m := load Cmd path;
	if(m == nil)
		return sys->sprint("cannot load %s: %r", path);
	{
		m->init(nil, args);
	}exception e{
	"*" =>
		return e;
	}
	return nil;
}

callproc(path: string, args: list of string, c: chan of string)
{
	c <-= call(path, args);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= -1 =>
		;
	* =>
		;
	}
}

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");
	ai := ref Keyring->Authinfo;
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}


# a command's init with a deadline: what it raised, nil, or "TIMEOUT"
start(path: string, args: list of string, ms: int): string
{
	c := chan[1] of string;
	spawn callproc(path, args, c);
	spawn stimer(c, ms);
	return <-c;
}

stimer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

testCommandEnd(t: ref T)
{
	ex := progs("Export");
	e := start("/dis/mount.dis", "mount" :: "{export " + D + "/dir}" :: D + "/m" :: nil, 10000);
	t.assert(e == nil, "mount {export dir}: " + e);
	t.assertseq(readfile(D + "/m/file"), "served", "the command's file is read through the mount");
	t.assert(fresh(progs("Export"), ex) != nil, "the command runs");
	sys->unmount(nil, D + "/m");
	t.assert(gone("Export", ex, 5000), "the command sees the end of its input when it is unmounted");
	killall(fresh(progs("Export"), ex));
}

testPeerName(t: ref T)
{
	signer := kr->genSK("ed25519", "mounts-signer", 0);
	(alpha, p) := kr->dhparams(2048);
	if(signer == nil || alpha == nil || p == nil)
		t.fatal("cannot make a signer or a group");
	ai := mkauthinfo(signer, kr->sktopk(signer), alpha, p, "mounts-server");
	keyfile := D + "/key";
	if(kr->writeauthinfo(keyfile, ai) < 0)
		t.fatal(sys->sprint("cannot write %s: %r", keyfile));
	port := freeport(t);
	addr := "tcp!127.0.0.1!" + port;
	ll := progs("Listen");
	e := start("/dis/listen.dis", "listen" :: "-k" :: keyfile :: addr :: "{export " + D + "/dir}" :: nil, 10000);
	if(e != nil)
		t.fatal("listen: " + e);

	e = start("/dis/mount.dis", "mount" :: "-k" :: keyfile :: "-u" :: "someone-else" :: addr :: D + "/m" :: nil, 20000);
	t.assertseq(e, "fail:error", "mount -u refuses a server that authenticates under another name");
	t.assert(readfile(D + "/m/file") == nil, "and mounts nothing");
	e = start("/dis/mount.dis", "mount" :: "-k" :: keyfile :: "-u" :: "mounts-server" :: addr :: D + "/m" :: nil, 20000);
	t.assert(e == nil, "mount -u takes the server it names: " + e);
	t.assertseq(readfile(D + "/m/file"), "served", "and its file is read");
	sys->unmount(nil, D + "/m");
	e = start("/dis/mount.dis", "mount" :: "-A" :: "-u" :: "mounts-server" :: addr :: D + "/m" :: nil, 20000);
	t.assertseq(e, "fail:usage", "mount -A -u: nobody is authenticated to be named");
	killall(fresh(progs("Listen"), ll));
	killall(fresh(progs("Export"), nil));
}

nouser(addr: string, c: chan of string)
{
	sys->pctl(Sys->FORKFD|Sys->FORKNS, nil);
	fd := sys->create(D + "/err", Sys->OWRITE, 8r666);
	if(fd == nil){
		c <-= sys->sprint("create: %r");
		return;
	}
	sys->dup(fd.fd, 2);
	fd = nil;
	if(sys->bind(D + "/empty", "/dev/user", Sys->MREPL) < 0){
		c <-= sys->sprint("bind: %r");
		return;
	}
	c <-= call("/dis/mount.dis", "mount" :: addr :: D + "/m" :: nil);
}

testNoUser(t: ref T)
{
	(ok, conn) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("no loopback tcp: %r"));
	(nil, f) := sys->tokenize(readfile(conn.dir + "/local"), "!\n");
	mkfile(D + "/empty", "");
	c := chan[1] of string;
	spawn nouser("tcp!127.0.0.1!" + hd tl f, c);
	t.assertseq(<-c, "fail:error", "mount with no user name fails");
	said := readfile(D + "/err");
	t.assert(contains(said, "cannot read /dev/user"), "and says it cannot tell whose keys to use: " + said);
	t.assert(!contains(said, "/usr//keyring"), "and names no key directory of nobody's: " + said);
}

# 9export -A on a pipe: what the caller is told, and how 9export ended
export9(c: chan of string, fd: ref Sys->FD, done: chan of string)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	c <-= "ready";
	done <-= call("/dis/9export.dis", "9export" :: "-A" :: nil);
}

impo(t: ref T, words: string): (string, int)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	c := chan[1] of string;
	done := chan[1] of string;
	spawn export9(c, p[1], done);
	<-c;
	p[1] = nil;
	buf := array[256] of byte;
	n := 0;
	{
		sys->fprint(p[0], "%s", D + "/dir");
		n = sys->read(p[0], buf, len buf);
		if(n != 2)
			return (sys->sprint("tree not taken: %d %s", n, string buf[0:n]), 0);
		sys->fprint(p[0], "%s\n", words);
		# a Tversion: answered if the export is running
		v := array[] of {byte 19, byte 0, byte 0, byte 0, byte 100, byte 16rff, byte 16rff,
			byte 0, byte 16r20, byte 0, byte 0, byte 6, byte 0,
			byte '9', byte 'P', byte '2', byte '0', byte '0', byte '0'};
		sys->write(p[0], v, len v);
	}exception{
	"*" =>
		;	# 9export has gone: a write on a closed pipe
	}
	rc := chan[1] of int;
	spawn firstread(p[0], rc);
	spawn timer(rc, 3000);
	n = <-rc;
	spawn stimer(done, 100);
	return (<-done, n);
}

firstread(fd: ref Sys->FD, c: chan of int)
{
	buf := array[64] of byte;
	c <-= sys->read(fd, buf, len buf);
}

# one caller of a loopback address given to 9export -A
serve9(c: chan of string, done: chan of string)
{
	(ok, a) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		c <-= nil;
		return;
	}
	(nil, f) := sys->tokenize(readfile(a.dir + "/local"), "!\n");
	c <-= hd tl f;
	(lok, l) := sys->listen(a);
	if(lok < 0)
		return;
	fd := sys->open(l.dir + "/data", Sys->ORDWR);
	if(fd == nil)
		return;
	export9(chan[1] of string, fd, done);
}

testPlan9(t: ref T)
{
	t.assertseq(start("/dis/import.dis", "import" :: "tcp!127.0.0.1!1" :: "/n/nosuch" :: nil, 10000),
		"fail:p9sk1", "import without -A says Plan 9 authentication is not here, before it dials");
	t.assertseq(start("/dis/9export.dis", "9export" :: nil, 10000),
		"fail:p9sk1", "9export without -A says the same, before its caller is spoken to");
	# mount -9 asked factotum for p9any when the server took Tauth, and
	# so could only fail there: it is refused, before it dials
	t.assertseq(start("/dis/mount.dis", "mount" :: "-9" :: "tcp!127.0.0.1!1" :: D + "/m" :: nil, 10000),
		"fail:p9sk1", "mount -9 says the same, before it dials");

	# import -A and 9export -A are each other's far end
	c := chan[1] of string;
	done := chan[1] of string;
	spawn serve9(c, done);
	port := <-c;
	if(port == nil)
		t.skip(sys->sprint("no loopback tcp: %r"));
	r := start("/dis/import.dis", "import" :: "-A" :: "tcp!127.0.0.1!" + port :: D + "/dir" :: D + "/m" :: nil, 10000);
	t.assertseq(r, nil, "import -A from a 9export -A mounts");
	t.assertseq(readfile(D + "/m/file"), "served", "and the tree named is what is mounted");
	sys->unmount(nil, D + "/m");

	(e, n) := impo(t, "impo nofilter clear");
	t.assert(n > 0, sys->sprint("a caller asking for clear is exported to: %d bytes of a version answered (%s)", n, e));
	(e, n) = impo(t, "impo nofilter ssl");
	t.assertseq(e, "fail:impo", "a caller asking for ssl is refused");
	t.assert(n <= 0, "and is not exported to in clear");
	(e, n) = impo(t, "impo aan clear");
	t.assertseq(e, "fail:impo", "a caller asking for a filter is refused");
	killall(fresh(progs("P9export"), nil));
}

testExportDash(t: ref T)
{
	t.assertseq(start("/dis/export.dis", "export" :: "-" :: "/nonexistent/dir" :: "/nonexistent/file" :: nil, 5000),
		"fail:usage", "export - is a usage error");
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
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(sys->fildes(2), "cannot load keyring: %r\n");
		raise "fail:cannot load";
	}
	sys->pctl(Sys->FORKNS, nil);
	mkdir(D);
	mkdir(D + "/dir");
	mkdir(D + "/m");
	mkfile(D + "/dir/file", "served");

	run("CommandEnd", testCommandEnd);
	run("PeerName", testPeerName);
	run("NoUser", testNoUser);
	run("Plan9", testPlan9);
	run("ExportDash", testExportDash);

	for(l := "/dir/file" :: "/key" :: "/err" :: "/empty" :: "/dir" :: "/m" :: "" :: nil; l != nil; l = tl l)
		sys->remove(D + hd l);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
