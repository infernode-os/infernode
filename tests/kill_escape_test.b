implement KillEscapeTest;

#
# Ways a program outlived the kill of its group (emu/port/dis.c,
# exception.c, libinterp/load.c, and os/port's):
#  - killtree takes the pids of a group's tree once and lets the VM go
#    as each Prog dies. A Prog of the tree run in one of those moments
#    did pctl(NEWPGRP), leaving its marked group for one of its own, and
#    spawned: the child was in nobody's list. Forty chains of
#    "pctl(NEWPGRP); spawn the next; exit" left about 36 running
#  - an exception handler frees the frames it unwinds; freeing a file
#    descriptor lets the VM go to close it, a kill that came then was
#    only marked, and the handler cleared the mark as it finished: the
#    Prog ran on, its killer told it had gone
#  - the JIT raises for an instruction it does not know, and did so
#    holding the lock compiles are made under: the next module to be
#    compiled waited for it holding the VM, and every Limbo program
#    stopped. One .dis file with one bad opcode
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

KillEscapeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/kill_escape_test.b";

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

# so that what a failing run leaves behind ends
stop := 0;

links := big 0;

link()
{
	if(stop)
		return;
	links++;
	sys->pctl(Sys->NEWPGRP, nil);
	spawn link();
}

chainleader(pidc: chan of int, n: int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	for(i := 0; i < n; i++)
		spawn link();
	c := chan of int;
	<-c;
}

ctl(pid: int, msg: string): int
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		return -1;
	return sys->fprint(fd, "%s", msg);
}

testNewpgrpChains(t: ref T)
{
	(ok, nil) := sys->stat("/prog");
	if(ok < 0)
		t.skip("no /prog here");
	worst := big 0;
	for(round := 0; round < 3; round++){
		pidc := chan of int;
		spawn chainleader(pidc, 40);
		pid := <-pidc;
		sys->sleep(200);
		r := ctl(pid, "killtree");
		t.assert(r > 0, sys->sprint("killtree is taken: %d %r", r));
		sys->sleep(300);
		l0 := links;
		sys->sleep(300);
		moved := links - l0;
		if(moved > worst)
			worst = moved;
	}
	stop = 1;
	sys->sleep(100);
	stop = 0;
	t.assert(worst == big 0, sys->sprint("no chain goes on after its tree is killed: %bd links made in 300 ms after", worst));
}

spins := big 0;

victim(gate: chan of int)
{
	{
		fd := sys->open("/dev/null", Sys->OREAD);
		<-gate;
		if(fd != nil)	# (held to here: the handler's unwinding is what closes it)
			raise "x";
	} exception {
	"*" =>
		;
	}
	while(!stop)
		spins++;
}

victimleader(pidc: chan of int, gate: chan of int, n: int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	for(i := 0; i < n; i++)
		spawn victim(gate);
	c := chan of int;
	<-c;
}

testKilledInHandler(t: ref T)
{
	(ok, nil) := sys->stat("/prog");
	if(ok < 0)
		t.skip("no /prog here");
	n := 30;
	outlived := 0;
	for(round := 0; round < 10; round++){
		pidc := chan of int;
		gate := chan of int;
		spawn victimleader(pidc, gate, n);
		pid := <-pidc;
		sys->sleep(100);
		# opened first: the kill is to come while the handlers run
		kfd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
		if(kfd == nil)
			t.fatal(sys->sprint("open ctl: %r"));
		for(i := 0; i < n; i++)
			gate <-= 1;
		sys->fprint(kfd, "killgrp");
		sys->sleep(200);
		s0 := spins;
		sys->sleep(100);
		if(spins != s0)
			outlived++;
		# whatever is left is taken by a second kill, or by stop
		ctl(pid, "killgrp");
		stop = 1;
		sys->sleep(50);
		stop = 0;
	}
	t.asserteq(outlived, 0, "rounds of ten in which a Prog killed in its handler went on running");
}

loader(path: string, c: chan of string)
{
	{
		m := load Cmd path;
		if(m == nil)
			c <-= sys->sprint("nil: %r");
		else
			c <-= "loaded";
	} exception e {
	"*" =>
		c <-= "raised: " + e;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# where a Dis file's operand ends: 1, 2 or 4 bytes
operand(d: array of byte, p: int): int
{
	case int d[p] & 16rC0 {
	16r00 or 16r40 =>
		return p+1;
	16r80 =>
		return p+2;
	}
	return p+4;
}

testBadOpcode(t: ref T)
{
	fd := sys->open("/dis/echo.dis", Sys->OREAD);
	if(fd == nil)
		t.skip(sys->sprint("no /dis/echo.dis: %r"));
	d := array[65536] of byte;
	n := sys->readn(fd, d, len d);
	if(n <= 0)
		t.fatal("cannot read /dis/echo.dis");
	d = d[0:n];
	# the header's nine numbers, then the first instruction's opcode
	p := 0;
	for(i := 0; i < 9; i++)
		p = operand(d, p);
	d[p] = byte 16rEE;	# no instruction
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	evil := "/tmp/kill_escape_badop.dis";
	wfd := sys->create(evil, Sys->OWRITE, 8r666);
	if(wfd == nil || sys->write(wfd, d, len d) != len d)
		t.skip(sys->sprint("cannot write %s: %r", evil));
	wfd = nil;

	c := chan[1] of string;
	tc := chan[1] of int;
	spawn loader(evil, c);
	spawn timer(tc, 10000);
	alt{
	r := <-c =>
		t.log("a module with an instruction that is none: " + r);
	<-tc =>
		t.fatal("the load of it never came back");
	}

	# and a module not loaded before still loads: under the JIT this is
	# compiled, under the lock the bad one's compile was made under
	c2 := chan[1] of string;
	tc2 := chan[1] of int;
	spawn loader("/dis/basename.dis", c2);
	spawn timer(tc2, 10000);
	alt{
	r := <-c2 =>
		t.assert(r == "loaded", "a module not loaded before loads after it: " + r);
	<-tc2 =>
		t.fatal("the next module's load never came back");
	}
	sys->remove(evil);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("NewpgrpChains", testNewpgrpChains);
	run("KilledInHandler", testKilledInHandler);
	# last: before the fix, under the JIT, nothing ran after this
	run("BadOpcode", testBadOpcode);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
