implement DiswriteTest;

#
# diswrite_test - Dis->writeobj, loadobj's inverse: object files read and
# written again are the same bytes; a module made at run time loads,
# the JIT (or the interpreter) takes it, and it runs.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "dis.m";
	dis: Dis;
	Mod, Inst, Type: import dis;

DiswriteTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# what the module made at run time is: tests/gentmpl.b's type
Gentmpl: module
{
	add: fn(a, b: int): int;
};

SRCFILE: con "/tests/diswrite_test.b";

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

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	if(sys->read(fd, b, len b) != len b)
		return nil;
	return b;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

testRoundTrip(t: ref T)
{
	for(l := "/dis/sh.dis" :: "/dis/lib/dis.dis" :: "/dis/lib/js/js.dis" :: "/dis/lib/web/originfs.dis" ::
	    "/dis/lib/bufio.dis" :: "/dis/tests/gentmpl.dis" :: nil; l != nil; l = tl l) {
		f := hd l;
		b := readfile(f);
		if(b == nil) {
			t.log(f + ": not there");
			continue;
		}
		(m, err) := dis->loadobj(f);
		if(m == nil) {
			t.error(f + ": " + err);
			continue;
		}
		w := dis->writeobj(m);
		t.assert(same(b, w), sys->sprint("%s: %d bytes read, %d written, the same", f, len b, len w));
	}
}

# fp(n): a frame operand
FP: con Dis->AFP;

inst(op, src, smode, mid, mmode, dst, dmode: int): ref Inst
{
	return ref Inst(op, (smode << 3) | dmode | mmode, mid, src, dst);
}

testGenerated(t: ref T)
{
	(tm, err) := dis->loadobj("/dis/tests/gentmpl.dis");
	if(tm == nil)
		t.fatal("the template: " + err);
	# add(a, b) = a*b + 1, made here: a at 64(fp), b at 72(fp), the
	# result through 32(fp), a temporary at 80(fp)
	m := ref *tm;
	m.inst = array[] of {
		inst(Dis->IMULW, 64, FP, 72, Dis->AXINF, 80, FP),
		inst(Dis->IADDW, 1, Dis->AIMM, 80, Dis->AXINF, (32 << 16) | 0, Dis->AIND|FP),
		inst(Dis->IRET, 0, Dis->AXXX, 0, Dis->AXNON, 0, Dis->AXXX),
	};
	m.types = array[] of {ref Type(0, 0, nil), ref Type(88, 0, nil)};
	m.links[0].pc = 0;
	m.links[0].desc = 1;
	m.srcpath = "generated";
	path := "/tmp/diswrite_test.dis";
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		t.fatal(sys->sprint("%s: %r", path));
	b := dis->writeobj(m);
	sys->write(fd, b, len b);
	fd = nil;
	g := load Gentmpl path;
	sys->remove(path);
	if(g == nil)
		t.fatal(sys->sprint("load the generated module: %r"));
	t.asserteq(g->add(6, 7), 43, "the generated add is a*b + 1");
	t.asserteq(g->add(-3, 5), -14, "and again");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	dis = load Dis Dis->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	dis->init();
	run("RoundTrip", testRoundTrip);
	run("Generated", testGenerated);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
