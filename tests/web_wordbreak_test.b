implement WebWordbreakTest;

#
# Where a line may break inside Thai, which has no spaces between its
# words.  The expected words are ICU's (Intl.Segmenter), over text
# from the Thai Wikipedia.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "web/wordbreak.m";
	wordbreak: Wordbreak;

WebWordbreakTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_wordbreak_test.b";

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

# s with its breaks shown as |, the words between them
marked(s: string): string
{
	b := wordbreak->breaks(s);
	r := "";
	for(i := 0; i < len s; i++) {
		if(b != nil && int b[i])
			r[len r] = '|';
		r[len r] = s[i];
	}
	return r;
}

unmarked(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] != '|')
			r[len r] = s[i];
	return r;
}

testWords(t: ref T)
{
	words := array[] of {
		"ย้าย|เมนู|ไป|ที่|แถบ|ด้าน|ข้าง",
		"กรุง|รัตนโกสินทร์|ตอน|ต้น|และ|สมัย|อาณานิคม",
		"รา|ชา|ธิป|ไตย|ภาย|ใต้|รัฐธรรมนูญ",
		"วิกิ|พี|เดีย",
		"ประเทศไทย",
	};
	for(i := 0; i < len words; i++)
		t.assertseq(marked(unmarked(words[i])), words[i], "words");
}

# the elision and repetition marks end the word before them
testMarks(t: ref T)
{
	words := array[] of {
		"ทวี|ความ|รุนแรง|ขึ้น|เรื่อยๆ",
		"เทียบ|กัน|ชัดๆ",
		"พระบาท|สมเด็จ|พระ|มหา|ภูมิพล|อดุลย|เดชฯ",
	};
	for(i := 0; i < len words; i++)
		t.assertseq(marked(unmarked(words[i])), words[i], "marks");
}

# only Thai: none in other text, and none at a Thai run's edges
testOther(t: ref T)
{
	t.assert(wordbreak->breaks("no Thai here") == nil, "no Thai, no breaks");
	t.assertseq(marked("abcไป|ที่|แถบdef 12"), "abcไป|ที่|แถบdef 12", "the run's edges");
	t.assertseq(marked("แถบ ด้าน|ข้าง"), "แถบ ด้าน|ข้าง", "runs either side of a space");
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
	wordbreak = load Wordbreak Wordbreak->PATH;
	if(wordbreak == nil) {
		sys->fprint(sys->fildes(2), "cannot load wordbreak: %r\n");
		raise "fail:cannot load wordbreak";
	}

	run("Words", testWords);
	run("Marks", testMarks);
	run("Other", testOther);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
