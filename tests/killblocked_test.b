implement KillblockedTest;

#
# Does a kill reach a Prog blocked in the host?
#
# A Prog killed while its proc waits in a host system call is pulled
# out by swiproc (emu/port/proc.c): it sets swipend and sends the
# thread SIGUSR1, the call fails with EINTR, and osleave raises Eintr.
# Three ways that was lost, each leaving the Prog "exiting" in
# /prog for as long as the call took -- for a listen, for ever:
#
#  - so_accept (emu/port/ipif6-posix.c) and devcmd's write retried
#    on every EINTR, the one sent by swiproc included.  (devcmd's read
#    did too, but its retry asked for -1 bytes and failed at once.)
#  - The signal could come after osenter but before the call was
#    entered, be handled there, and leave the call blocked.
#  - The kill could come while the proc was between Sleeps and system
#    calls, released from the VM: swiproc found it in neither and did
#    nothing (intpend now keeps it for the next one).
#
# Each case blocks a Prog in the host, kills it through /prog/n/ctl,
# and requires it gone from /prog within Gonems. The last kills a few
# hundred listeners as they start, at no particular point.
#
#   emu -c0 -r . /dis/tests/killblocked_test.dis
#   emu -c1 -r . /dis/tests/killblocked_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

KillblockedTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/killblocked_test.b";

# How long a killed Prog may take to leave /prog. It leaves in
# microseconds; this is for a busy CI machine.
Gonems: con 5000;

# How long to let a Prog get into its system call before killing it.
Settlems: con 200;

Nraces: con 300;

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

alive(pid: int): int
{
	return sys->open(sys->sprint("/prog/%d/status", pid), Sys->OREAD) != nil;
}

kill(pid: int): int
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		return -1;
	return sys->fprint(fd, "kill");
}

# Let pid get into its system call; it must still be there.
blocked(t: ref T, pid: int)
{
	sys->sleep(Settlems);
	if(!alive(pid))
		t.fatal("the Prog did not block, so there is nothing to kill");
}

# Kill pid; 1 if it has left /prog within Gonems.
killgone(pid: int): int
{
	if(kill(pid) < 0)
		return !alive(pid);
	for(w := 0; w < Gonems; w += 5){
		if(!alive(pid))
			return 1;
		sys->sleep(5);
	}
	return 0;
}

announce(t: ref T): Sys->Connection
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("cannot announce on loopback: %r"));
	return c;
}

port(c: Sys->Connection): string
{
	fd := sys->open(c.dir+"/local", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	for(i := 0; i < len s; i++)
		if(s[i] == '!')
			s = s[i+1:];
	while(s != nil && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

listener(c: Sys->Connection, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->listen(c);
}

accepter(c: Sys->Connection, got: chan of int)
{
	(ok, nil) := sys->listen(c);
	got <-= ok;
}

sleeper(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

reader(fd: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[1] of byte;
	sys->read(fd, buf, len buf);
}

# A Prog blocked in a listen (the host's accept) is killed.
testListen(t: ref T)
{
	c := announce(t);
	pidc := chan of int;
	spawn listener(c, pidc);
	pid := <-pidc;
	blocked(t, pid);
	t.assert(killgone(pid), "a Prog killed in listen leaves /prog");

	# Nothing of it is left in the host to take the next connection.
	got := chan of int;
	spawn accepter(c, got);
	(ok, d) := sys->dial("tcp!127.0.0.1!"+port(c), nil);
	if(ok < 0)
		t.fatal(sys->sprint("dial the announced port: %r"));
	timer := chan[1] of int;	# buffered: the sleeper must not outlive the test
	spawn sleeper(timer, Gonems);
	alt {
	<-got =>
		;
	<-timer =>
		t.error("the next connection did not reach the next listener");
	}
	d.dfd = nil;
}

# A Prog blocked reading a connection with nothing to read is killed.
testRead(t: ref T)
{
	c := announce(t);
	(ok, d) := sys->dial("tcp!127.0.0.1!"+port(c), nil);
	if(ok < 0)
		t.fatal(sys->sprint("dial: %r"));
	(lok, l) := sys->listen(c);
	if(lok < 0)
		t.fatal(sys->sprint("listen: %r"));
	pidc := chan of int;
	spawn reader(d.dfd, pidc);
	pid := <-pidc;
	blocked(t, pid);
	t.assert(killgone(pid), "a Prog killed in a read of a connection leaves /prog");
	l.dfd = nil;
}

# Start "sleep 30" on the host, which neither reads nor writes; its
# data file and ctl, killed when ctl is closed.
sleepcmd(t: ref T): (ref Sys->FD, string)
{
	if(sys->stat("/cmd/clone").t0 == -1 && sys->bind("#C", "/", Sys->MBEFORE) < 0)
		t.skip(sys->sprint("no cmd device: %r"));
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		t.skip(sys->sprint("cannot open /cmd/clone: %r"));
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		t.fatal(sys->sprint("read /cmd/clone: %r"));
	sys->fprint(cfd, "killonclose");
	if(sys->fprint(cfd, "exec sleep 30") < 0)
		t.skip(sys->sprint("cannot run a host command: %r"));
	return (cfd, "/cmd/"+string b[0:n]+"/data");
}

# A Prog blocked reading a host command's output (devcmd) is killed.
testCmdRead(t: ref T)
{
	(cfd, data) := sleepcmd(t);
	out := sys->open(data, Sys->OREAD);
	if(out == nil)
		t.fatal(sys->sprint("open %s: %r", data));
	pidc := chan of int;
	spawn reader(out, pidc);
	pid := <-pidc;
	blocked(t, pid);
	t.assert(killgone(pid), "a Prog killed reading a host command's output leaves /prog");
	cfd = nil;
}

writer(fd: ref Sys->FD, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[8192] of {* => byte 'x'};
	while(sys->write(fd, buf, len buf) == len buf)
		;
}

# A Prog blocked writing to a host command that does not read (the
# pipe full) is killed.
testCmdWrite(t: ref T)
{
	(cfd, data) := sleepcmd(t);
	in := sys->open(data, Sys->OWRITE);
	if(in == nil)
		t.fatal(sys->sprint("open %s: %r", data));
	pidc := chan of int;
	spawn writer(in, pidc);
	pid := <-pidc;
	blocked(t, pid);
	t.assert(killgone(pid), "a Prog killed writing to a host command leaves /prog");
	cfd = nil;
}

# Listeners killed as they start, wherever each has got to.
testRace(t: ref T)
{
	c := announce(t);
	pidc := chan of int;
	stuck := 0;
	for(i := 0; i < Nraces; i++){
		spawn listener(c, pidc);
		pid := <-pidc;
		if(i % 3 == 1)
			sys->sleep(0);
		else if(i % 3 == 2)
			sys->sleep(1);
		if(!killgone(pid)){
			t.error(sys->sprint("listener %d of %d still in /prog %dms after its kill", i, Nraces, Gonems));
			if(++stuck == 3)
				break;
		}
	}
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

	sys->bind("#p", "/prog", Sys->MREPL);

	run("Listen", testListen);
	run("Read", testRead);
	run("CmdRead", testCmdRead);
	run("CmdWrite", testCmdWrite);
	run("Race", testRace);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
