implement BidiTest;

#
# The Unicode Bidirectional Algorithm against Unicode's own
# BidiCharacterTest.txt (a sample: every 25th case), and the
# reordering and mirroring on known strings.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "bidi.m";
	bidi: Bidi;
include "testing.m";
	testing: Testing;
	T: import testing;

BidiTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/bidi_test.b";
CASES: con "/tests/bidi/cases.txt";

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

hexlist(s: string): array of int
{
	(n, l) := sys->tokenize(s, " ");
	a := array[n] of int;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hex(hd l);
	return a;
}

hex(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= '0' && c <= '9')
			v = v*16 + c - '0';
		else if(c >= 'A' && c <= 'F')
			v = v*16 + c - 'A' + 10;
		else if(c >= 'a' && c <= 'f')
			v = v*16 + c - 'a' + 10;
	}
	return v;
}

join(a: array of int): string
{
	s := "";
	for(i := 0; i < len a; i++) {
		if(i > 0)
			s += " ";
		s += string a[i];
	}
	return s;
}

# BidiCharacterTest.txt: codepoints; dir; paragraph level; levels; order
testConformance(t: ref T)
{
	f := bufio->open(CASES, Bufio->OREAD);
	if(f == nil)
		t.fatal(sys->sprint("open %s: %r", CASES));
	ncase := 0;
	nbad := 0;
	while((l := f.gets('\n')) != nil) {
		if(l[0] == '#' || l[0] == '\n')
			continue;
		(nf, fl) := sys->tokenize(l, ";\n");
		if(nf < 5)
			continue;
		cps := hexlist(hd fl);
		dir := int hd tl fl;
		if(dir == 2)
			dir = -1;
		wantlev := hd tl tl tl fl;
		wantord := hd tl tl tl tl fl;
		ncase++;
		lev := bidi->levels(cps, dir);
		# levels, with 'x' where the character is removed (we give those a level too)
		(nl, wl) := sys->tokenize(wantlev, " ");
		got := "";
		keep: list of int;	# reversed
		i := 0;
		for(k := wl; k != nil; k = tl k) {
			if(i > 0)
				got += " ";
			if(hd k == "x")
				got += "x";
			else {
				got += string lev[i];
				keep = i :: keep;
			}
			i++;
		}
		if(nl != len cps || got != wantlev) {
			if(nbad++ < 5)
				t.error(sys->sprint("case %d levels: %s: got %s, want %s", ncase, hd fl, got, wantlev));
			continue;
		}
		# the visual order of the characters not removed
		ka := array[len keep] of int;
		for(i = len ka - 1; keep != nil; keep = tl keep)
			ka[i--] = hd keep;
		kl := array[len ka] of int;
		for(i = 0; i < len ka; i++)
			kl[i] = lev[ka[i]];
		ord := bidi->reorder(kl);
		gs := "";
		for(i = 0; i < len ord; i++) {
			if(i > 0)
				gs += " ";
			gs += string ka[ord[i]];
		}
		if(gs != wantord) {
			if(nbad++ < 5)
				t.error(sys->sprint("case %d order: %s: got %s, want %s", ncase, hd fl, gs, wantord));
		}
	}
	t.log(sys->sprint("%d cases, %d wrong", ncase, nbad));
	t.assert(ncase > 3000, "the sample was read");
	t.asserteq(nbad, 0, "all cases agree");
}

testClasses(t: ref T)
{
	t.asserteq(bidi->class('a'), Bidi->L, "a is L");
	t.asserteq(bidi->class(16r5D0), Bidi->R, "alef is R");
	t.asserteq(bidi->class(16r627), Bidi->AL, "arabic alef is AL");
	t.asserteq(bidi->class('1'), Bidi->EN, "1 is EN");
	t.asserteq(bidi->class(' '), Bidi->WS, "space is WS");
	t.asserteq(bidi->class(16r2067), Bidi->RLI, "RLI");
	t.asserteq(bidi->class(16r10FFFF), Bidi->BN, "noncharacter is BN");
	t.asserteq(bidi->mirror('('), ')', "( mirrors to )");
	t.asserteq(bidi->mirror('a'), 'a', "a has no mirror");
}

testBase(t: ref T)
{
	t.asserteq(bidi->basedir(array[] of {'a', 'b'}), 0, "ltr");
	t.asserteq(bidi->basedir(array[] of {' ', 16r5D0}), 1, "rtl");
	t.asserteq(bidi->basedir(array[] of {'1', ' '}), -1, "no strong");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	bidi = load Bidi Bidi->PATH;
	if(testing == nil || bidi == nil) {
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if((err := bidi->init()) != nil) {
		sys->fprint(sys->fildes(2), "bidi init: %s\n", err);
		raise "fail:init";
	}
	run("Classes", testClasses);
	run("Base", testBase);
	run("Conformance", testConformance);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
