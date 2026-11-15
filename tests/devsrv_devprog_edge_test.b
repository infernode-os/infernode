implement DevsrvDevprogEdgeTest;

#
# Two devices a program keeps after pctl(NODEVS) or has in most name
# spaces, asked for what the kernel did not expect:
#  - #s (devsrv.c): a walk to ".." is answered with the directory itself,
#    which srvwalk then looked for among the directory's files and, not
#    finding it, panicked: stat("#s/..") ended the emulator, and would
#    the native kernel
#  - /prog/n/exception (devprog.c): the text of the exception a Prog
#    raised was given to snprint as its format. A program that raises
#    "%lux %lux ..." and reads its own file got the kernel's stack back;
#    "%s" or "%n" followed and wrote through whatever was there
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

DevsrvDevprogEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devsrv_devprog_edge_test.b";

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

# raise s and catch it: the Prog's exception file then has it
raisecaught(s: string)
{
	{
		raise s;
	} exception {
	"*" =>
		;
	}
}

exceptionof(pid: int): string
{
	fd := sys->open(sys->sprint("/prog/%d/exception", pid), Sys->OREAD);
	if(fd == nil)
		return sys->sprint("<open: %r>");
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("<read: %r>");
	return string buf[0:n];
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testExceptionText(t: ref T)
{
	(ok, nil) := sys->stat("/prog");
	if(ok < 0)
		t.skip("no /prog here");
	texts := array[] of {
		"plain text",
		"x%lux.%lux.%lux.%lux.%lux.%lux.%lux.%lux",
		"y%d%d%d%d%d%d%d%d%d%d%d%d",
		"z%%percent",
	};
	pid := sys->pctl(0, nil);
	for(i := 0; i < len texts; i++){
		raisecaught(texts[i]);
		e := exceptionof(pid);
		t.assert(contains(e, texts[i]), sys->sprint("the exception file has the text raised, as raised: %q in %q", texts[i], e));
	}
}

testSrvDotDot(t: ref T)
{
	(ok, nil) := sys->stat("#s");
	if(ok < 0)
		t.skip(sys->sprint("no #s here: %r"));
	d: Sys->Dir;
	(ok, d) = sys->stat("#s/..");
	t.assert(ok >= 0, sys->sprint("stat of #s/.. is answered: %r"));
	t.assert((d.mode & Sys->DMDIR) != 0, "and is a directory");
	fd := sys->open("#s/..", Sys->OREAD);
	t.assert(fd != nil, sys->sprint("it opens: %r"));
	fd = nil;
	(ok, nil) = sys->stat("#s/../..");
	t.assert(ok >= 0, sys->sprint("and #s/../..: %r"));
	(ok, nil) = sys->stat("#s/../nothere");
	t.assert(ok < 0, "a name that is not there, after .., is not found");

	# a file2chan file is still found through it
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#s", "/chan", Sys->MBEFORE) < 0)
		t.fatal(sys->sprint("bind #s: %r"));
	fio := sys->file2chan("/chan", "edgefile");
	if(fio == nil)
		t.fatal(sys->sprint("file2chan: %r"));
	(ok, nil) = sys->stat("/chan/../chan/edgefile");
	t.assert(ok >= 0, sys->sprint("a file2chan file is found after a walk through ..: %r"));
	fio = nil;
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

	run("ExceptionText", testExceptionText);
	# last: before the fix this one ended the emulator
	run("SrvDotDot", testSrvDotDot);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
