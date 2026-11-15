implement DevenvEdgeTest;

#
# The environment device (#e, devenv.c) used by a process that has no
# environment, and its open modes:
#  - sys->export serves a name space on a connection from a kernel
#    process, which has no environment group. The connection can be a
#    file of #e, which any program can make (a confined one too: #e is
#    kept after NODEVS). Reading it took the lock of an environment that
#    was nil: the kernel process faulted, and that ends the emulator
#  - a variable opened ORDWR|OTRUNC kept its old value (only
#    OWRITE|OTRUNC, exactly, truncated)
#  - a variable made or opened ORCLOSE could not be read or written: the
#    mode kept on the channel had ORCLOSE in it, which no read or write's
#    mode matches
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevenvEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devenv_edge_test.b";

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

value(name: string): string
{
	fd := sys->open("#e/" + name, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("<open: %r>");
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("<read: %r>");
	return string buf[0:n];
}

testModes(t: ref T)
{
	sys->pctl(Sys->FORKENV, nil);
	fd := sys->create("#e/edgevar", Sys->OWRITE, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create #e/edgevar: %r"));
	t.asserteq(sys->fprint(fd, "a long old value"), 16, "a variable is written");
	fd = nil;
	t.assertseq(value("edgevar"), "a long old value", "and read back");

	fd = sys->open("#e/edgevar", Sys->ORDWR | Sys->OTRUNC);
	t.assert(fd != nil, sys->sprint("open ORDWR|OTRUNC: %r"));
	t.asserteq(sys->fprint(fd, "new"), 3, "it is written through that");
	fd = nil;
	t.assertseq(value("edgevar"), "new", "and holds the new value alone");

	fd = sys->create("#e/edgerc", Sys->ORDWR | Sys->ORCLOSE, 8r666);
	t.assert(fd != nil, sys->sprint("create ORDWR|ORCLOSE: %r"));
	t.asserteq(sys->fprint(fd, "kept while open"), 15, sys->sprint("a variable made ORCLOSE is written: %r"));
	t.assertseq(value("edgerc"), "kept while open", "and read");
	buf := array[64] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	t.asserteq(n, 15, sys->sprint("through its own descriptor too: %r"));
	fd = nil;
	(ok, nil) := sys->stat("#e/edgerc");
	t.assert(ok < 0, "and it is gone when closed");
}

testExportOverVariable(t: ref T)
{
	sys->pctl(Sys->FORKENV, nil);
	fd := sys->create("#e/edgeconn", Sys->ORDWR, 8r666);
	if(fd == nil)
		t.fatal(sys->sprint("create #e/edgeconn: %r"));
	sys->fprint(fd, "some bytes that are no 9P message");
	sys->seek(fd, big 0, Sys->SEEKSTART);
	r := sys->export(fd, "/", Sys->EXPASYNC);
	t.log(sys->sprint("export returned %d: %r", r));
	fd = nil;
	# the kernel process serving it reads the variable; give it the time
	sys->sleep(500);
	t.assertseq(value("edgeconn"), "some bytes that are no 9P message", "the emulator is still here, and the variable");
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

	run("Modes", testModes);
	# last: before the fix this one ended the emulator
	run("ExportOverVariable", testExportOverVariable);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
