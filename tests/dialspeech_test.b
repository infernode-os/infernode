implement DialspeechTest;

#
# Tests for Dialspeech (module/dialspeech.m): what was said to a
# telephone, as a number to dial -- numbers said as digits and words
# and written as numbers, a name with the kind of number wanted, a
# leading call or dial, and a name found in an address book.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dialspeech.m";
	ds: Dialspeech;
	Said: import ds;

include "testing.m";
	testing: Testing;
	T: import testing;

DialspeechTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dialspeech_test.b";

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

# what was said, as one line: "number 5551234 call" / "name sarah work"
show(s: ref Said): string
{
	r: string;
	case s.what {
	Dialspeech->Number =>
		r = "number " + s.number;
	Dialspeech->Name =>
		r = "name " + s.name;
		if(s.kind != nil)
			r += " " + s.kind;
	* =>
		r = "nothing";
	}
	if(s.call)
		r += " call";
	return r;
}

said(t: ref T, text, want: string)
{
	t.assertseq(show(ds->parse(text)), want, "\"" + text + "\"");
}

testDigitsSaid(t: ref T)
{
	said(t, "five five five one two three four", "number 5551234");
	said(t, "Five, five, five. One two three four.", "number 5551234");
	said(t, "nine one one", "number 911");
	said(t, "oh one two", "number 012");
	said(t, "zero zero four four", "number 0044");
	said(t, "five five five double two", "number 55522");
	said(t, "triple seven", "number 777");
	said(t, "nine eleven", "number 911");
	said(t, "eight hundred five five five", "number 800555");
	said(t, "one eight hundred", "number 1800");
	said(t, "twenty five", "number 25");
	said(t, "forty", "number 40");
	said(t, "plus four four seven", "number +447");
	said(t, "star six seven", "number *67");
	said(t, "star six seven pound", "number *67#");
	said(t, "asterisk hash", "number *#");
	said(t, "one two and three", "number 123");
}

testDigitsWritten(t: ref T)
{
	said(t, "555-1234", "number 5551234");
	said(t, "(555) 123-4567", "number 5551234567");
	said(t, "+1 555 123 4567", "number +15551234567");
	said(t, "555.123.4567", "number 5551234567");
	said(t, "five five five 1234", "number 5551234");
	said(t, "*67#", "number *67#");
}

testNotNumbers(t: ref T)
{
	said(t, "", "nothing");
	said(t, "   ", "nothing");
	said(t, "call", "nothing call");
	said(t, "five plus five", "name five plus five");
	said(t, "hundred", "name hundred");
	said(t, "thousand", "name thousand");
	said(t, "5 + 5", "name 5 + 5");
}

testCall(t: ref T)
{
	said(t, "call five five five one two one two", "number 5551212 call");
	said(t, "Dial 911.", "number 911 call");
	said(t, "phone mom", "name mom call");
	said(t, "ring Sarah", "name sarah call");
	said(t, "Call up Mom please", "name mom call");
	said(t, "mom", "name mom");
}

testNames(t: ref T)
{
	said(t, "call Sarah at work", "name sarah work call");
	said(t, "call Sarah's mobile", "name sarah mobile call");
	said(t, "call mom on her cell", "name mom mobile call");
	said(t, "call Sarah Smith at home", "name sarah smith home call");
	said(t, "call the office", "name office call");
	said(t, "call work", "name work call");
	said(t, "dial Mary Ann", "name mary ann call");
	said(t, "call Sarah-Jane", "name sarah jane call");
	said(t, "call José", "name josé call");
}

BOOK: con
	"Mom\tmobile\t+15551230001\n" +
	"Mom\twork\t+15551230002\n" +
	"Sarah Smith\twork\t+15551230004\n" +
	"Sarah Smith\tmobile\t+15551230003\n" +
	"Sam\thome\t+15551230005\n" +
	"Tom Momson\tmobile\t+15551230006\n" +
	"Ann Lee\tmobile\t+15551230007\n" +
	"Ann Kim\tmobile\t+15551230008\n" +
	"# contacts: 8 numbers\n";

found(t: ref T, name, kind, want: string)
{
	(num, cname, ckind, err) := ds->lookup(BOOK, name, kind);
	got: string;
	if(err != nil)
		got = "error " + err;
	else
		got = num + " " + cname + " " + ckind;
	t.assertseq(got, want, sys->sprint("lookup %q %q", name, kind));
}

testLookup(t: ref T)
{
	found(t, "mom", nil, "+15551230001 Mom mobile");
	found(t, "mom", "work", "+15551230002 Mom work");
	found(t, "MOM", nil, "+15551230001 Mom mobile");
	found(t, "sarah", nil, "+15551230003 Sarah Smith mobile");
	found(t, "sarah", "work", "+15551230004 Sarah Smith work");
	found(t, "sarah smith", "work", "+15551230004 Sarah Smith work");
	found(t, "smith", nil, "+15551230003 Sarah Smith mobile");
	found(t, "sam", nil, "+15551230005 Sam home");
	found(t, "sam", "work", "error no work number for Sam");
	found(t, "nobody", nil, "error no contact called nobody");
	found(t, "ann", nil, "error which: Ann Lee, Ann Kim?");
	found(t, "ann kim", nil, "+15551230008 Ann Kim mobile");
	# "mom" is Mom's whole name; Tom Momson only has it inside a word
	found(t, "mom", "home", "error no home number for Mom");
	# a part of a word, when nothing else answers
	found(t, "momso", nil, "+15551230006 Tom Momson mobile");
	found(t, "anyone", nil, "error no contact called anyone");
	# a book with no one in it says why, rather than "no contact"
	(nil, nil, nil, err) := ds->lookup("# contacts: permission denied\n", "mom", nil);
	t.assertseq(err, "contacts: permission denied", "a book denied says so");
	(nil, nil, nil, err) = ds->lookup("# contacts: Android bridge not wired (INFR-182)\n", "mom", nil);
	t.assertseq(err, "contacts: Android bridge not wired (INFR-182)", "a book not wired says so");
	(nil, nil, nil, err) = ds->lookup("", "mom", nil);
	t.assertseq(err, "no contact called mom", "an empty book");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	ds = load Dialspeech Dialspeech->PATH;
	if(testing == nil || ds == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	ds->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DigitsSaid", testDigitsSaid);
	run("DigitsWritten", testDigitsWritten);
	run("NotNumbers", testNotNumbers);
	run("Call", testCall);
	run("Names", testNames);
	run("Lookup", testLookup);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
