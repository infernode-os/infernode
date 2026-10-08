implement WstatNulldirTest;

#
# A wstat that leaves a field at its "don't change" value (~0, as in
# Sys->nulldir) must not change that field.
#
# The value travels as 32 bits in the stat message. On 64-bit hosts the
# C Dir's mode, atime and mtime are 64-bit ulongs, and the decoder used
# to store the 32-bit ~0 as 0xFFFFFFFF, which no device's ~0 or ~0UL
# comparison matched: a wstat that changed nothing made a pipe mode 777,
# and (tests/host/wstat_nulldir_test.sh) a rename of a host file made it
# world-writable with a modification time in 2106.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

WstatNulldirTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wstat_nulldir_test.b";

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

pipemode(t: ref T, fd: ref Sys->FD): int
{
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		t.fatal(sys->sprint("fstat pipe: %r"));
	return d.mode & 8r777;
}

# nulldir changes nothing
testPipeNulldir(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	before := pipemode(t, p[0]);
	if(sys->fwstat(p[0], sys->nulldir) < 0)
		t.fatal(sys->sprint("fwstat nulldir: %r"));
	t.asserteq(pipemode(t, p[0]), before, "mode after a nulldir wstat");
}

# a wstat of the mode alone sets the mode: the fix must not stop that
testPipeMode(t: ref T)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	d := sys->nulldir;
	d.mode = 8r640;
	if(sys->fwstat(p[0], d) < 0)
		t.fatal(sys->sprint("fwstat mode: %r"));
	t.asserteq(pipemode(t, p[0]), 8r640, "mode after setting it");
	if(sys->fwstat(p[0], sys->nulldir) < 0)
		t.fatal(sys->sprint("fwstat nulldir: %r"));
	t.asserteq(pipemode(t, p[0]), 8r640, "mode kept by a nulldir wstat");
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

	run("PipeNulldir", testPipeNulldir);
	run("PipeMode", testPipeMode);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
