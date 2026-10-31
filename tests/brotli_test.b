implement BrotliTest;

#
# Brotli decompression against the reference encoder: each
# tests/web/brotli/NAME.br must decode to NAME.out.  The vectors cover
# qualities 1 to 11, windows of 2^10 to 2^22 bytes, the static
# dictionary and its transforms (english), stored meta-blocks (random)
# and a font (ahem).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "brotli.m";
	brotli: Brotli;

BrotliTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/brotli_test.b";
DIR: con "/tests/web/brotli/";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" or "fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

readfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	n := 0;
	while(n < len b && (k := sys->read(fd, b[n:], len b - n)) > 0)
		n += k;
	return b[0:n];
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return -1;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return i;
	return len a;
}

vector(t: ref T, name: string, sized: int)
{
	br := readfile(DIR + name + ".br");
	want := readfile(DIR + name + ".out");
	if(br == nil) {
		t.fatal("no " + DIR + name + ".br");
		return;
	}
	size := -1;
	if(sized)
		size = len want;
	t0 := sys->millisec();
	(got, err) := brotli->decompress(br, size);
	t.assertnil(err, name + ": no error");
	k := same(got, want);
	if(k != len want)
		t.error(sys->sprint("%s: %d bytes, want %d; first difference at %d", name, len got, len want, k));
	t.log(sys->sprint("%s: %d -> %d bytes in %dms", name, len br, len got, sys->millisec() - t0));
}

names := array[] of {"empty", "hello", "english", "doc-q11", "doc-q5", "doc-q1", "doc-w10", "random", "ahem", "ahem-q4"};

testVectors(t: ref T)
{
	for(i := 0; i < len names; i++)
		vector(t, names[i], 0);
}

testSized(t: ref T)
{
	for(i := 0; i < len names; i++)
		vector(t, names[i], 1);
}

testCorrupt(t: ref T)
{
	br := readfile(DIR + "doc-q11.br");
	# truncated, and damaged: errors, never a crash or a hang
	(nil, err) := brotli->decompress(br[0:len br/2], -1);
	t.assertnotnil(err, "truncated");
	bad := array[len br] of byte;
	bad[0:] = br;
	for(i := 10; i < len bad; i += 97)
		bad[i] ^= byte 16r5a;
	(nil, err) = brotli->decompress(bad, -1);
	t.assertnotnil(err, "damaged");
	(nil, err) = brotli->decompress(readfile(DIR + "hello.br"), 3);
	t.assertnotnil(err, "longer than the size given");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	brotli = load Brotli Brotli->PATH;
	if(brotli == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Brotli->PATH);
		raise "fail:load";
	}
	run("Vectors", testVectors);
	run("Sized", testSized);
	run("Corrupt", testCorrupt);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
