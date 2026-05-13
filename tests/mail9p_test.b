implement Mail9pTest;

#
# mail9p_test - Unit tests for mail9p parsers (via the mailparse lib)
# and a smoke check that the mail9p daemon mounts and exposes the
# expected namespace shape.
#
# Pure parser tests: no network required.
# Mount test: spawns mail9p in a separate process and stats /n/mail.
#
# Run: emu -r. /tests/mail9p_test.dis [-v]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

include "imap.m";

include "mailparse.m";
	mailparse: Mailparse;

Mail9pTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/mail9p_test.b";

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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	str = load String String->PATH;
	if(str == nil) {
		sys->fprint(sys->fildes(2), "cannot load String\n");
		raise "fail:load";
	}

	mailparse = load Mailparse Mailparse->PATH;
	if(mailparse == nil) {
		sys->fprint(sys->fildes(2), "cannot load Mailparse from %s\n",
			Mailparse->PATH);
		raise "fail:load";
	}
	mailparse->init();

	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load Testing\n");
		raise "fail:load";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	# Parser tests. Integration coverage (mount, namespace shape, ctl
	# round-trip) lives in tests/inferno/mail9p_test.sh.
	run("ParseFlagsReplace",    testParseFlagsReplace);
	run("ParseFlagsDiff",       testParseFlagsDiff);
	run("ParseFlagsMixed",      testParseFlagsMixed);
	run("ParseFlagsUnknown",    testParseFlagsUnknown);
	run("ParseFlagsEmpty",      testParseFlagsEmpty);
	run("SplitBodyLF",          testSplitBodyLF);
	run("SplitBodyCRLF",        testSplitBodyCRLF);
	run("SplitBodyNoSeparator", testSplitBodyNoSeparator);
	run("HasHeaderField",       testHasHeaderField);
	run("BodyHasBlankLine",     testBodyHasBlankLine);
	run("ExtractHeader",        testExtractHeader);
	run("TrimAddr",             testTrimAddr);
	run("ParseAddrList",        testParseAddrList);
	run("StrtoBig",             testStrtoBig);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}

# --- Parser tests ---

testParseFlagsReplace(t: ref T)
{
	# Bare flag names: replace mode.
	(add, remove, replace, err) := mailparse->parseflagswrite("\\Seen \\Flagged");
	t.assertnil(err, "no err for bare flags");
	t.asserteq(add, 0, "add bits zero in replace mode");
	t.asserteq(remove, 0, "remove bits zero in replace mode");
	t.asserteq(replace, Imap->FSEEN | Imap->FFLAGGED, "replace bits set");

	# Aliases without backslash.
	(nil, nil, replace, err) = mailparse->parseflagswrite("Seen Answered");
	t.assertnil(err, "alias forms accepted");
	t.asserteq(replace, Imap->FSEEN | Imap->FANSWERED, "alias bits set");
}

testParseFlagsDiff(t: ref T)
{
	(add, remove, replace, err) := mailparse->parseflagswrite("+\\Seen -\\Flagged");
	t.assertnil(err, "no err for diff mode");
	t.asserteq(replace, -1, "replace sentinel for diff mode");
	t.asserteq(add, Imap->FSEEN, "add bits");
	t.asserteq(remove, Imap->FFLAGGED, "remove bits");

	# Combined +/+ stays in diff mode.
	(add, remove, replace, err) = mailparse->parseflagswrite("+\\Seen +\\Answered");
	t.assertnil(err, "no err for ++");
	t.asserteq(add, Imap->FSEEN | Imap->FANSWERED, "++ combined");
	t.asserteq(remove, 0, "no remove bits");
}

testParseFlagsMixed(t: ref T)
{
	(nil, nil, nil, err) := mailparse->parseflagswrite("+\\Seen \\Flagged");
	t.assertnotnil(err, "mixing signed and bare must error");
}

testParseFlagsUnknown(t: ref T)
{
	(nil, nil, nil, err) := mailparse->parseflagswrite("\\Bogus");
	t.assertnotnil(err, "unknown flag must error");
}

testParseFlagsEmpty(t: ref T)
{
	(nil, nil, nil, err) := mailparse->parseflagswrite("");
	t.assertnotnil(err, "empty input must error");
}

testSplitBodyLF(t: ref T)
{
	body := mailparse->splitbody("From: a@b\nTo: c@d\n\nhello\n");
	t.assertseq(body, "hello\n", "LF separator");
}

testSplitBodyCRLF(t: ref T)
{
	body := mailparse->splitbody("From: a@b\r\nTo: c@d\r\n\r\nhello\r\n");
	t.assertseq(body, "hello\r\n", "CRLF separator");
}

testSplitBodyNoSeparator(t: ref T)
{
	body := mailparse->splitbody("From: a@b\nTo: c@d\n");
	t.assertseq(body, "", "no separator yields empty body");
}

testHasHeaderField(t: ref T)
{
	t.asserteq(mailparse->hasheaderfield("From: a@b\nSubject: hi\n\nbody", "Subject:"),
		1, "Subject: present");
	t.asserteq(mailparse->hasheaderfield("From: a@b\nSubject: hi\n\nbody", "subject:"),
		1, "case-insensitive");
	t.asserteq(mailparse->hasheaderfield("From: a@b\n\nSubject: hi", "Subject:"),
		0, "Subject in body section is not a header");
	t.asserteq(mailparse->hasheaderfield("From: a@b\n", "To:"),
		0, "absent header");
}

testBodyHasBlankLine(t: ref T)
{
	t.asserteq(mailparse->bodyhasblankline("a\n\nb"), 1, "LF blank line");
	t.asserteq(mailparse->bodyhasblankline("a\r\n\r\nb"), 1, "CRLF blank line");
	t.asserteq(mailparse->bodyhasblankline("a\nb\n"), 0, "no blank line");
}

testExtractHeader(t: ref T)
{
	hdr := "From: alice@example.com\r\nSubject:   Re: hi\r\n\r\nbody\r\n";
	t.assertseq(mailparse->extractheader(hdr, "From:"), "alice@example.com", "From");
	t.assertseq(mailparse->extractheader(hdr, "Subject:"), "Re: hi", "trimmed value");
	t.assertseq(mailparse->extractheader(hdr, "Date:"), "", "missing → empty");
}

testTrimAddr(t: ref T)
{
	t.assertseq(mailparse->trimaddr("alice@example.com"),
		"alice@example.com", "bare");
	t.assertseq(mailparse->trimaddr("  Alice <alice@example.com>  "),
		"alice@example.com", "Name <addr> with surrounding ws");
	t.assertseq(mailparse->trimaddr("\"Alice O.\" <alice@example.com>"),
		"alice@example.com", "quoted display name");
}

testParseAddrList(t: ref T)
{
	addrs := mailparse->parseaddrlist("a@x.com, Bob <b@x.com>, c@x.com");
	t.assertnotnil(hd addrs, "head non-nil");
	t.asserteq(listlen(addrs), 3, "three entries");
	t.assertseq(hd addrs, "a@x.com", "first");
	t.assertseq(hd tl addrs, "b@x.com", "second extracted from <>");
	t.assertseq(hd tl tl addrs, "c@x.com", "third");
}

testStrtoBig(t: ref T)
{
	t.assertseq(string mailparse->strtobig("12345"), "12345", "digits parse");
	t.assertseq(string mailparse->strtobig(""), "-1", "empty → -1");
	t.assertseq(string mailparse->strtobig("12x"), "-1", "non-digit → -1");
	t.assertseq(string mailparse->strtobig("9999999999"), "9999999999",
		"value larger than int but fits big");
}

# --- Helpers ---

listlen(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}
