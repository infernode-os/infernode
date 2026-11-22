implement DialEdgeTest;

#
# dial, announce and listen given strings that are not addresses
# (emu/port/dial.c, os/port/dial.c). The strings are the program's, and
# the connection server asked to translate one is whatever file is at
# netdir/cs, which can be the program's too.
#  - listen copied the conversation's directory into 40 bytes with strcpy
#    once a name made of its first 39 bytes had opened: the rest went
#    over the kernel's stack (the hosted emulator's fortified strcpy
#    ended it; the native kernel's return address is 48 bytes on)
#  - a dial string beginning with # and with no slash before its ! was
#    searched backwards for one, below the buffer
#  - a clone file's name with no slash in it, as a connection server may
#    answer, was cut at a nil
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DialEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dial_edge_test.b";
D: con "/tmp/dial_edge_test";

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

rep(c: int, n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s[i] = c;
	return s;
}

put(name, text: string): int
{
	fd := sys->create(name, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	b := array of byte text;
	return sys->write(fd, b, len b);
}

# listen on a "conversation" whose directory is the string given
listen(dir: string): (int, string)
{
	c: Sys->Connection;
	c.dir = dir;
	{
		(ok, nil) := sys->listen(c);
		return (ok, sys->sprint("%r"));
	} exception e {
	"*" =>
		return (1, "raised: " + e);
	}
}

dial(addr: string): (int, string)
{
	{
		(ok, nil) := sys->dial(addr, nil);
		return (ok, sys->sprint("%r"));
	} exception e {
	"*" =>
		return (1, "raised: " + e);
	}
}

announce(addr: string): (int, string)
{
	{
		(ok, nil) := sys->announce(addr);
		return (ok, sys->sprint("%r"));
	} exception e {
	"*" =>
		return (1, "raised: " + e);
	}
}

testListenDirectory(t: ref T)
{
	# the first 39 bytes name a file that opens; 244 more follow
	long := "/dev" + rep('/', 31) + "null" + rep('A', 200);
	(ok, e) := listen(long);
	t.asserteq(ok, -1, "listen on a directory of 239 bytes is refused: " + e);
	for(n := 30; n <= 60; n++){
		(ok, e) = listen("/dev" + rep('/', n-8) + "null");
		t.asserteq(ok, -1, sys->sprint("listen on a directory of %d bytes: %s", n, e));
	}
	(ok, e) = listen("x");
	t.asserteq(ok, -1, "listen on a directory with no slash in its name is refused: " + e);
	(ok, e) = listen("");
	t.asserteq(ok, -1, "and on one with no name: " + e);
}

testDialStrings(t: ref T)
{
	strs := array[] of {
		"#!x", "#x!y", "#I!tcp!1", "#" + rep('a', 200) + "!x", "!", "!x", "#!", "/!x",
		rep('a', 127), rep('a', 300), rep('a', 126) + "!x",
		"/tmp/" + rep('a', 99) + "!x",
	};
	for(i := 0; i < len strs; i++){
		(ok, e) := dial(strs[i]);
		s := strs[i];
		if(len s > 24)
			s = s[0:24] + "...";
		t.asserteq(ok, -1, sys->sprint("dial %q is refused: %s", s, e));
		(ok, e) = announce(strs[i]);
		t.asserteq(ok, -1, sys->sprint("announce %q is refused: %s", s, e));
	}
}

testConnectionServerAnswer(t: ref T)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(D, Sys->OREAD, Sys->DMDIR | 8r777);
	(ok, d) := sys->stat(D);
	if(ok < 0 || (d.mode & Sys->DMDIR) == 0)
		t.skip(sys->sprint("cannot make %s: %r", D));
	sys->pctl(Sys->FORKNS, nil);
	if(sys->chdir(D) < 0)
		t.fatal(sys->sprint("chdir: %r"));

	# a "connection server" that is a file: its answer names a clone
	# file with no slash in it, which is there to be opened
	if(put(D + "/cs", "a!b z") < 0 || put(D + "/a!b", "") < 0)
		t.fatal(sys->sprint("cannot write the files: %r"));
	e: string;
	(ok, e) = dial(D + "/a!b");
	t.asserteq(ok, -1, "dial through a connection server naming a clone file with no slash is refused: " + e);

	put(D + "/cs", "a!b z");
	(ok, e) = announce(D + "/a!b");
	t.asserteq(ok, -1, "and announce: " + e);

	sys->remove(D + "/cs");
	sys->remove(D + "/a!b");
	sys->remove(D);
}

testStillDials(t: ref T)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("no loopback announce here: %r"));
	t.assert(c.dir != nil, "an announce gives its directory: " + c.dir);
	buf := array[64] of byte;
	lfd := sys->open(c.dir + "/local", Sys->OREAD);
	if(lfd == nil)
		t.fatal(sys->sprint("open local: %r"));
	n := sys->read(lfd, buf, len buf);
	if(n <= 0)
		t.fatal("no local address");
	local := string buf[0:n];
	if(local[len local - 1] == '\n')
		local = local[0:len local - 1];
	(dok, dc) := sys->dial("tcp!" + local, nil);
	t.assert(dok >= 0, sys->sprint("a dial to it connects: %r"));
	(lok, lc) := sys->listen(c);
	t.assert(lok >= 0, sys->sprint("and listen takes the call: %r"));
	t.assert(lc.dir != nil && lc.dir != c.dir, "in a conversation of its own: " + lc.dir);
	dc.dfd = nil;
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

	run("StillDials", testStillDials);
	run("DialStrings", testDialStrings);
	run("ConnectionServerAnswer", testConnectionServerAnswer);
	# last: before the fix this one ended the emulator
	run("ListenDirectory", testListenDirectory);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
