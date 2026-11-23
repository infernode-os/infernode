implement Mail9pTest;

#
# mail9p_test - Unit tests for mail9p parsers (via the mailparse lib)
# and a smoke check that the mail9p daemon mounts and exposes the
# expected namespace shape.
#
# Pure parser tests: no network required.
# Mount test: spawns mail9p in a separate process and stats /mnt/mail.
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
	run("AddrListQuoted",       testAddrListQuoted);
	run("HeaderAll",            testHeaderAll);
	run("DropHeader",           testDropHeader);
	run("SmtpKeys",             testSmtpKeys);

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

# A comma inside a quoted name, angle brackets or a comment separates
# nothing: split at every comma, "Doe, John" <j@x> was two recipients,
# the first of them `"Doe`.
testAddrListQuoted(t: ref T)
{
	addrs := mailparse->parseaddrlist("\"Doe, John\" <j@x.com>, b@x.com (Bob, the builder), , <c@x.com>");
	t.asserteq(listlen(addrs), 3, "three addresses");
	if(listlen(addrs) != 3)
		return;
	t.assertseq(hd addrs, "j@x.com", "a quoted name with a comma is one address");
	t.assertseq(hd tl addrs, "b@x.com (Bob, the builder)", "a comment with a comma is not split");
	t.assertseq(hd tl tl addrs, "c@x.com", "an empty entry is left out");
	t.asserteq(listlen(mailparse->parseaddrlist("")), 0, "nothing gives nobody");
	t.asserteq(listlen(mailparse->parseaddrlist(" , ")), 0, "nor do blanks and commas");
}

MSG: con "From: a@x\r\nTo: b@x,\r\n\tc@x\r\nBcc: d@x\r\nSubject: s\r\nbcc: e@x,\r\n f@x\r\nCc: g@x\r\n\r\nBcc: not a header\r\n";

# compose took its recipients from the first To: line: a Cc got
# nothing, a folded line's addresses neither.
testHeaderAll(t: ref T)
{
	t.assertseq(mailparse->headerall(MSG, "To:"), " b@x,\tc@x", "To: with its continuation line");
	t.assertseq(mailparse->headerall(MSG, "Bcc:"), " d@x,  e@x, f@x", "every Bcc:, whatever its case");
	t.assertseq(mailparse->headerall(MSG, "Cc:"), " g@x", "Cc: is not Bcc:");
	t.assertseq(mailparse->headerall(MSG, "Reply-To:"), "", "a field that is not there");
	t.assertseq(mailparse->headerall("To: a@x\nCc: b@x\n\nCc: c@x\n", "Cc:"), " b@x", "LF lines; the body is not searched");
}

# A Bcc: left in the message is read by every recipient.
testDropHeader(t: ref T)
{
	t.assertseq(mailparse->dropheader(MSG, "Bcc:"),
		"From: a@x\r\nTo: b@x,\r\n\tc@x\r\nSubject: s\r\nCc: g@x\r\n\r\nBcc: not a header\r\n",
		"both Bcc: headers gone with their continuation lines, the body as it was");
	t.assertseq(mailparse->dropheader(MSG, "X-None:"), MSG, "a field that is not there changes nothing");
	t.assertseq(mailparse->dropheader("Bcc: a@x", "Bcc:"), "", "a header with no newline");
}

# The IMAP server's key goes to the SMTP host only if that is the same
# host or one the user named: it was offered to smtp.X, a name made up
# from imap.X.
testSmtpKeys(t: ref T)
{
	k := mailparse->smtpkeys("imap.example.com", "smtp.example.com", 0);
	t.asserteq(listlen(k), 1, "a made-up SMTP host: one key");
	t.assertseq(hd k, "proto=pass service=smtp dom=smtp.example.com", "its own");
	k = mailparse->smtpkeys("imap.example.com", "smtp.example.com", 1);
	t.asserteq(listlen(k), 2, "a named SMTP host: two keys");
	t.assertseq(hd k, "proto=pass service=smtp dom=smtp.example.com", "its own first");
	t.assertseq(hd tl k, "proto=pass service=imap dom=imap.example.com", "then the IMAP server's");
	k = mailparse->smtpkeys("mail.example.com", "mail.example.com", 0);
	t.asserteq(listlen(k), 2, "the IMAP host itself: two keys");
	t.assertseq(hd tl k, "proto=pass service=imap dom=mail.example.com", "the IMAP server's second");
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
