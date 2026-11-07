implement StrcatTest;

#
# String concatenation where both operands are the same string:
# s += s and s = s + s, ASCII and runes, many times over.
#
# addstring (libinterp/string.c) appends in place when the left string
# has room past its length, which a new string often has (its room is
# its block's, rounded up).  It set the new length before copying the
# right operand, so when the right was the left it copied the new
# length's worth, twice what it should, past the end of the block: the
# heap was corrupt, and the emulator died later somewhere else (in CI,
# after docengine_test's long Markdown, built by doubling a paragraph).
#
# Each test reads #%/memstate, which audits the pools: a corrupt heap
# stops the emulator there, not in a later test.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

StrcatTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/strcat_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Audit the pools; a corrupt one panics the emulator here
audit(t: ref T)
{
	fd := sys->open("#%/memstate", Sys->OREAD);
	if(fd == nil) {
		t.log(sys->sprint("no #%%/memstate: %r"));
		return;
	}
	buf := array[8192] of byte;
	t.assert(sys->read(fd, buf, len buf) > 0, "memstate read");
}

# s is base repeated n times
repeated(t: ref T, s, base: string, n: int, what: string)
{
	if(len s != n*len base) {
		t.error(sys->sprint("%s: length %d, want %d", what, len s, n*len base));
		return;
	}
	for(i := 0; i < len s; i++)
		if(s[i] != base[i%len base]) {
			t.error(sys->sprint("%s: character %d is %d, want %d", what, i, s[i], base[i%len base]));
			return;
		}
}

testSelfAppend(t: ref T)
{
	base := "A paragraph of a long document.\n\n";
	s := base;
	n := 1;
	for(i := 0; i < 12; i++) {
		s += s;
		n *= 2;
		audit(t);
		repeated(t, s, base, n, sys->sprint("after %d s += s", i+1));
	}
}

testSelfPlus(t: ref T)
{
	base := "A paragraph of a long document.\n\n";
	s := base;
	n := 1;
	for(i := 0; i < 12; i++) {
		s = s + s;
		n *= 2;
		audit(t);
		repeated(t, s, base, n, sys->sprint("after %d s = s + s", i+1));
	}
}

# Every short length, so some string has room to append in place
testSelfAppendLengths(t: ref T)
{
	for(l := 1; l < 80; l++) {
		base := "";
		for(i := 0; i < l; i++)
			base[i] = 'a' + i%26;
		s := base;
		s += s;
		s += s;
		repeated(t, s, base, 4, sys->sprint("length %d", l));
	}
	audit(t);
}

testSelfAppendRunes(t: ref T)
{
	base := "Ωμέγα, a paragraph.\n";
	s := base;
	n := 1;
	for(i := 0; i < 10; i++) {
		s += s;
		n *= 2;
		audit(t);
		repeated(t, s, base, n, sys->sprint("after %d s += s", i+1));
	}
	for(l := 1; l < 40; l++) {
		b := "";
		for(j := 0; j < l; j++)
			b[j] = 'α' + j%20;
		s = b;
		s += s;
		s += s;
		repeated(t, s, b, 4, sys->sprint("runes, length %d", l));
	}
	audit(t);
}

# The other operand, as before: appended once, the left unchanged
testOtherAppend(t: ref T)
{
	s := "A paragraph";
	u := s;
	s += " of a long document.";
	t.assertseq(s, "A paragraph of a long document.", "appended");
	t.assertseq(u, "A paragraph", "the shared left unchanged");
	r := "Ωμέγα";
	r += "abc";
	t.assertseq(r, "Ωμέγαabc", "ASCII onto runes");
	a := "abc";
	a += "Ωμέγα";
	t.assertseq(a, "abcΩμέγα", "runes onto ASCII");
	audit(t);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("SelfAppend", testSelfAppend);
	run("SelfPlus", testSelfPlus);
	run("SelfAppendLengths", testSelfAppendLengths);
	run("SelfAppendRunes", testSelfAppendRunes);
	run("OtherAppend", testOtherAppend);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
