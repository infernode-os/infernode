implement ListenersTest;

#
# listen(1) and styxlisten as they start, admit callers and end.
#
#  - with -A, and no -t, the listener unmounted /mnt/keys in the name
#    space of whoever started it: it hides the key store from its
#    command in a name space of its own only when it authenticates, and
#    with -A it had none.  It forks one either way now.
#  - styxlisten's command held a copy of the listener's end of its own
#    pipe (its fd table was a copy of the listener's), so when the
#    listener had gone the command never saw the end of its input and
#    stayed for good.
#  - when the command exited the listener was killed and the processes
#    serving callers were left, each exporting a mount nothing answered
#    on until its caller went away.
#  - the budget of authentications started in a second was one count for
#    all callers: one address making that many connections had every
#    other caller hung up.  One address has half of it.
#  - a listener that is not the host owner cannot become the callers it
#    authenticates (/dev/user is the host owner's to write) and serves
#    each as itself; it said nothing.  It says so when it starts.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

ListenersTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/listeners_test.b";
D: con "/tmp/listeners_test";

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

testNsKept(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	mkdir(D + "/mnt");
	mkdir(D + "/mnt/keys");
	mkdir(D + "/kd");
	mkfile(D + "/kd/marker", "here");
	if(sys->bind(D + "/mnt", "/mnt", Sys->MREPL) < 0 || sys->bind(D + "/kd", "/mnt/keys", Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind: %r"));
	t.assert(sys->stat("/mnt/keys/marker").t0 >= 0, "something is mounted on /mnt/keys");

	sl := progs("Styxlisten");
	ex := progs("Export");
	# each in a process of its own, as a shell starts a command: it has
	# this name space until it takes another
	c := chan[1] of string;
	spawn callproc("/dis/styxlisten.dis", "styxlisten" :: "-A" :: "tcp!127.0.0.1!" + freeport(t) :: "export" :: D + "/dir" :: nil, c);
	e := <-c;
	t.assert(e == nil, "styxlisten -A starts: " + e);
	t.assert(sys->stat("/mnt/keys/marker").t0 >= 0, "styxlisten -A leaves /mnt/keys mounted for whoever started it");
	killall(fresh(progs("Styxlisten"), sl));
	killall(fresh(progs("Export"), ex));

	ll := progs("Listen");
	spawn callproc("/dis/listen.dis", "listen" :: "-A" :: "tcp!127.0.0.1!" + freeport(t) :: "{echo hi}" :: nil, c);
	e = <-c;
	t.assert(e == nil, "listen -A starts: " + e);
	t.assert(sys->stat("/mnt/keys/marker").t0 >= 0, "listen -A leaves /mnt/keys mounted for whoever started it");
	killall(fresh(progs("Listen"), ll));
}

startstyx(t: ref T, port: string): (list of int, list of int)
{
	sl := progs("Styxlisten");
	ex := progs("Export");
	c := chan[1] of string;
	spawn callproc("/dis/styxlisten.dis", "styxlisten" :: "-A" :: "tcp!127.0.0.1!" + port :: "export" :: D + "/dir" :: nil, c);
	if((e := <-c) != nil)
		t.fatal("styxlisten: " + e);
	if(appear("Export", ex, 5000) == nil)
		t.fatal("styxlisten's command did not start");
	return (sl, ex);
}

testListenerEnd(t: ref T)
{
	(sl, ex) := startstyx(t, freeport(t));
	l := fresh(progs("Styxlisten"), sl);
	t.assert(l != nil, "the listener runs");
	killall(l);
	t.assert(gone("Export", ex, 5000), "the command sees the end of its input once the listener has gone");
	killall(fresh(progs("Export"), ex));
}

mountproc(fd: ref Sys->FD, on: string, c: chan of int)
{
	c <-= sys->mount(fd, nil, on, Sys->MREPL, nil);
}

testCommandEnd(t: ref T)
{
	port := freeport(t);
	(sl, ex) := startstyx(t, port);
	(ok, conn) := sys->dial("tcp!127.0.0.1!" + port, nil);
	if(ok < 0)
		t.fatal(sys->sprint("dial: %r"));
	mc := chan[1] of int;
	spawn mountproc(conn.dfd, D + "/m", mc);
	spawn timer(mc, 10000);
	if(<-mc < 0)
		t.fatal(sys->sprint("mount of the listener: %r"));
	t.assertseq(readfile(D + "/m/file"), "served", "a caller reads the command's file");
	killall(fresh(progs("Export"), ex));
	t.assert(gone("Styxlisten", sl, 5000), "nothing of the listener is left serving a caller once the command has exited");
	killall(fresh(progs("Styxlisten"), sl));
	sys->unmount(nil, D + "/m");
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

# one byte of whatever the far end says first, or how the connection ended
firstread(fd: ref Sys->FD, c: chan of int)
{
	buf := array[64] of byte;
	c <-= sys->read(fd, buf, len buf);
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

testRateShare(t: ref T)
{
	signer := kr->genSK("ed25519", "listeners-signer", 0);
	(alpha, p) := kr->dhparams(2048);
	if(signer == nil || alpha == nil || p == nil)
		t.fatal("cannot make a signer or a group");
	ai := mkauthinfo(signer, kr->sktopk(signer), alpha, p, "listeners-server");
	keyfile := D + "/key";
	if(kr->writeauthinfo(keyfile, ai) < 0)
		t.fatal(sys->sprint("cannot write %s: %r", keyfile));

	port := freeport(t);
	ll := progs("Listen");
	N: con 8;
	# -P 0: only the rate is in question; -T: the silent callers below
	# are hung up within the test
	e := call("/dis/listen.dis", "listen" :: "-k" :: keyfile :: "-R" :: string N :: "-P" :: "0" :: "-T" :: "3000" ::
		"tcp!127.0.0.1!" + port :: "{echo hi}" :: nil);
	if(e != nil)
		t.fatal("listen: " + e);
	conns := array[N] of Sys->Connection;
	rc := chan[N] of int;
	for(i := 0; i < N; i++){
		(ok, c) := sys->dial("tcp!127.0.0.1!" + port, nil);
		if(ok < 0)
			t.fatal(sys->sprint("dial %d: %r", i));
		conns[i] = c;
		spawn firstread(c.dfd, rc);
	}
	# a caller the listener takes is sent the start of the exchange;
	# one over a limit is hung up at once
	spawn timer(rc, 2000);
	taken := 0;
	for(i = 0; i < N; i++){
		n := <-rc;
		if(n > 0)
			taken++;
		else if(n < 0 && i >= N/2)
			break;	# the timer, or hung up: the rest are waiting on the deadline
	}
	t.log(sys->sprint("%d of %d connections in one second from one address were taken", taken, N));
	t.assert(taken >= 1, "the address's first connection is taken");
	t.assert(taken <= N/2, sys->sprint("one address has at most half of a second's %d authentications: %d taken", N, taken));
	for(i = 0; i < N; i++)
		conns[i].dfd = conns[i].cfd = nil;
	killall(fresh(progs("Listen"), ll));
}

asother(c: chan of string)
{
	sys->pctl(Sys->FORKFD, nil);
	fd := sys->create(D + "/err", Sys->OWRITE, 8r666);
	if(fd == nil){
		c <-= sys->sprint("create: %r");
		return;
	}
	sys->dup(fd.fd, 2);
	fd = nil;
	ufd := sys->open("/dev/user", Sys->OWRITE);
	if(ufd == nil || sys->fprint(ufd, "listenersother") < 0){
		c <-= sys->sprint("cannot change user: %r");
		return;
	}
	ufd = nil;
	# a key file that is not there: the listener gets as far as its key
	c <-= "listen: " + call("/dis/listen.dis", "listen" :: "-k" :: D + "/nokey" :: "nonet!nowhere!1" :: "{}" :: nil)
		+ "; styxlisten: " + call("/dis/styxlisten.dis", "styxlisten" :: "-k" :: D + "/nokey" :: "nonet!nowhere!1" :: "{}" :: nil);
}

testNotOwner(t: ref T)
{
	c := chan[1] of string;
	spawn asother(c);
	r := <-c;
	t.log(r);
	said := readfile(D + "/err");
	t.assert(contains(said, "listen: running as listenersother, not the host owner"),
		"listen says it cannot become its callers: " + said);
	t.assert(contains(said, "styxlisten: running as listenersother, not the host owner"),
		"styxlisten says it cannot become its callers: " + said);
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

	run("NsKept", testNsKept);
	run("ListenerEnd", testListenerEnd);
	run("CommandEnd", testCommandEnd);
	run("RateShare", testRateShare);
	run("NotOwner", testNotOwner);

	sys->remove(D + "/dir/file");
	sys->remove(D + "/kd/marker");
	sys->remove(D + "/key");
	sys->remove(D + "/err");
	for(l := "/mnt/keys" :: "/mnt" :: "/kd" :: "/dir" :: "/m" :: "" :: nil; l != nil; l = tl l)
		sys->remove(D + hd l);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
