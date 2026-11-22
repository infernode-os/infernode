implement WebHyphenTest;

#
# hyphen(2) (appl/lib/web/hyphen.b): Liang's algorithm over TeX's
# American English patterns, as Charon hyphenates text with
# hyphens: auto.  Known answers (TeX's own, and where Chromium broke
# Python's documentation: "pro-vide", "sub-scripting"), the exceptions
# file, three letters after a break at least (Chromium's), and what is
# not hyphenated: short words, capitalized ones, words
# joined to digits or with soft hyphens of their own, languages with
# no patterns.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/hyphen.m";
	hyphen: Hyphen;

WebHyphenTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_hyphen_test.b";

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

# the word with its breaks shown as hyphens
shown(w: string): string
{
	brk := hyphen->points(w, "en");
	s := "";
	for(i := 0; i < len w; i++) {
		if(brk != nil && int brk[i])
			s[len s] = '-';
		s[len s] = w[i];
	}
	return s;
}

testWords(t: ref T)
{
	if(!hyphen->known("en"))
		t.skip("no patterns at " + Hyphen->DIR);
	words := array[] of {
		("hyphenation", "hy-phen-ation"),
		("provide", "pro-vide"),
		("subscripting", "sub-script-ing"),
		("programming", "pro-gram-ming"),
		("documentation", "doc-u-men-ta-tion"),
		("associate", "as-so-ciate"),	# the exceptions file's
		("table", "ta-ble"),
		("dynamic", "dy-namic"),	# three letters after a break at least: not -ic
	};
	for(i := 0; i < len words; i++)
		t.assertseq(shown(words[i].t0), words[i].t1, words[i].t0);
}

testNot(t: ref T)
{
	if(!hyphen->known("en"))
		t.skip("no patterns at " + Hyphen->DIR);
	t.assertseq(shown("cat"), "cat", "a short word");
	t.assertseq(shown("four"), "four", "four letters");
	t.assertseq(shown("classes"), "classes", "not class-es: Chromium lets it overflow a column first");
	t.assertseq(hyphen->hyphenate("Hyphenation", "en"), "Hyphenation", "capitalized");
	t.assertseq(hyphen->hyphenate("x86hyphenation", "en"), "x86hyphenation", "joined to digits");
	t.assertseq(hyphen->hyphenate("hyphen­ation", "en"), "hyphen­ation", "its own soft hyphens");
	t.assertseq(hyphen->hyphenate("hyphenation", "fr"), "hyphenation", "no French patterns");
	t.assertseq(hyphen->hyphenate("hyphenation", ""), "hyphenation", "no language");
	t.assert(!hyphen->known("eng"), "eng is not en");
	t.assert(hyphen->known("en-GB"), "en-GB takes en's");
}

testText(t: ref T)
{
	if(!hyphen->known("en"))
		t.skip("no patterns at " + Hyphen->DIR);
	t.assertseq(hyphen->hyphenate("Python classes provide subscripting.", "en-US"),
		"Python classes pro­vide sub­script­ing.", "a sentence");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	hyphen = load Hyphen Hyphen->PATH;
	if(hyphen == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Hyphen->PATH);
		raise "fail:load";
	}
	run("Words", testWords);
	run("Not", testNot);
	run("Text", testText);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
