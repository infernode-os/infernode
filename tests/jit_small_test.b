implement JitSmallTest;

#
# A module of fewer than 128 Dis instructions is compiled.
#
# comp-amd64.c's compile() rounded its scratch size up to 8192 bytes
# (64 a Dis instruction) and then checked that size/64 was the module's
# instruction count, an overflow check: for any module of fewer than 128
# instructions it was not, compile() returned 0, and under -c1 the module
# ran interpreted without a word.  One module in eight in dis/ was that
# small (crc, the base16/base32 encoders, the UTF-8 and UTF-16 converters,
# arg, cat, echo).
#
# A module that must be compiled (MUSTCOMPILE in its header, limbo -c)
# fails to load, "compiler required", when compile() declines it, but
# only while the JIT is off: with it on, a module compile() declines
# loads interpreted.  So the test sets the flag in a copy of the module
# itself, turns the JIT off (/dev/jit) for the one load, and puts it back.
# It does not depend on how the helper was compiled, and runs the same
# under -c0 and -c1 (tests/host/jit_small_test.sh runs both).
#
# The test's own module, which is large, is the control: if it cannot be
# compiled either there is no JIT here, and the test skips.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dis.m";
	dis: Dis;

include "testing.m";
	testing: Testing;
	T: import testing;

JitSmallTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

JitSmallHelper: module
{
	PATH:	con "/dis/tests/jit_small_helper.dis";
	add:	fn(a, b: int): int;
};

# Any module: load checks no functions against it.
Anymod: module
{
};

SRCFILE: con "/tests/jit_small_test.b";

# Where the modules are: beside this test in /tests, where the runner
# and CI's per-file compile put them, or in /dis/tests (tests/mkfile).
HELPERS := array[] of {"/tests/jit_small_helper.dis", JitSmallHelper->PATH};
SELVES := array[] of {"/tests/jit_small_test.dis", "/dis/tests/jit_small_test.dis"};

SMALL: con 128;		# compile() refused anything shorter

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

findmod(paths: array of string): string
{
	for(i := 0; i < len paths; i++)
		if(sys->open(paths[i], Sys->OREAD) != nil)
			return paths[i];
	return nil;
}

readjit(): string
{
	fd := sys->open("/dev/jit", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

writejit(v: string): int
{
	fd := sys->open("/dev/jit", Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte v;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

# A copy of the module at path that must be compiled, written to /tmp.
# Returns (copy, its instruction count, error).
mustcopy(path, tag: string): (string, int, string)
{
	(m, err) := dis->loadobj(path);
	if(m == nil)
		return (nil, 0, sys->sprint("loadobj %s: %s", path, err));
	m.rt = (m.rt | Dis->MUSTCOMPILE) & ~Dis->DONTCOMPILE;
	b := dis->writeobj(m);
	out := sys->sprint("/tmp/jit_small_%s_%d.dis", tag, sys->pctl(0, nil));
	fd := sys->create(out, Sys->OWRITE, 8r644);
	if(fd == nil)
		return (nil, 0, sys->sprint("create %s: %r", out));
	if(sys->write(fd, b, len b) != len b)
		return (nil, 0, sys->sprint("write %s: %r", out));
	return (out, m.isize, nil);
}

# Load path with the JIT off, so that a module compile() declines is
# refused rather than run interpreted; the JIT's setting is put back.
# Returns the load's error, nil when it loaded.
loadjitoff(path: string, small: int): string
{
	was := readjit();
	if(was == nil)
		return sys->sprint("cannot read /dev/jit: %r");
	if(writejit("0") < 0)
		return sys->sprint("cannot write /dev/jit: %r");
	err: string;
	{
		if(small){
			h := load JitSmallHelper path;
			if(h == nil)
				err = sys->sprint("%r");
			else if(h->add(2, 3) != 5)
				err = "compiled add(2, 3) is not 5";
		}else{
			a := load Anymod path;
			if(a == nil)
				err = sys->sprint("%r");
		}
	} exception e {
	"*" =>
		err = "exception: " + e;
	}
	writejit(was);
	return err;
}

testSmallModuleCompiled(t: ref T)
{
	mine := findmod(SELVES);
	helper := findmod(HELPERS);
	if(mine == nil || helper == nil)
		t.skip("jit_small_test.dis or jit_small_helper.dis not found");

	# The control: this module, much larger than SMALL.
	(ctl, nctl, err) := mustcopy(mine, "ctl");
	if(err != nil)
		t.fatal(err);
	t.assert(nctl >= SMALL, sys->sprint("the control has %d instructions, not %d or more", nctl, SMALL));
	err = loadjitoff(ctl, 0);
	sys->remove(ctl);
	if(err != nil)
		t.skip("no JIT here: the control could not be compiled either: " + err);

	(small, nsmall, err2) := mustcopy(helper, "small");
	if(err2 != nil)
		t.fatal(err2);
	t.log(sys->sprint("helper %d instructions, control %d", nsmall, nctl));
	t.assert(nsmall < SMALL, sys->sprint("the helper has %d instructions; it must have fewer than %d to test anything", nsmall, SMALL));
	err = loadjitoff(small, 1);
	sys->remove(small);
	if(err != nil)
		t.error(sys->sprint("a module of %d instructions was not compiled: %s", nsmall, err));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	dis = load Dis Dis->PATH;
	if(dis == nil) {
		sys->fprint(sys->fildes(2), "cannot load dis module: %r\n");
		raise "fail:cannot load dis";
	}
	dis->init();
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("SmallModuleCompiled", testSmallModuleCompiled);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
