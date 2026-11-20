implement ImapHostileTest;

#
# imap(2)'s parsers and arguments given what a server, a sender or a
# caller may give them (appl/lib/imap.b).
#
# The parsers are fed a server's lines, which hold a sender's text: a
# quoted string ending in a backslash ran the index past the line (an
# exception in whoever had asked for the mailbox, which in mail9p was the
# loop serving every account); a literal's count of twenty digits was
# the largest int, and its array was made before a byte of it came; a
# UID past 2^31 was read as the largest int, so all such were one
# message; a quoted string kept its backslashes.  A caller's string went
# into a command's line as it was: a line break in a search's criteria or
# a mailbox's name was the commands after it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;
include "imap.m";
	imap: Imap;

ImapHostileTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/imap_hostile_test.b";

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

# parsefetchline, saying whether it raised
parse(line: string): (ref Imap->Msg, string)
{
	m: ref Imap->Msg;
	{
		m = imap->parsefetchline(line);
	} exception e {
	"*" =>
		return (nil, e);
	}
	return (m, nil);
}

GOOD: con "* 3 FETCH (FLAGS (\\Seen) UID 77 RFC822.SIZE 4096 ENVELOPE (\"Mon, 1 Jan 2026 00:00:00 +0000\" \"Test Subject\" ((\"John Doe\" NIL \"john\" \"example.com\")) ((\"John Doe\" NIL \"john\" \"example.com\")) ((\"Reply\" NIL \"reply\" \"example.net\")) ((\"Jane Smith\" NIL \"jane\" \"example.com\")) NIL NIL NIL \"<msg001@example.com>\"))";

testBackslash(t: ref T)
{
	lines := array[] of {
		"* 2 FETCH (FLAGS () UID 102 RFC822.SIZE 9 ENVELOPE (\"x\\",
		"* 2 FETCH (ENVELOPE (\"d\" \"s\\",
		"* 2 FETCH (ENVELOPE (\"d\" \"s\" ((\"n\\",
		"* 2 FETCH (UID 5 X (a \"b\\",
		"* 2 FETCH (UID 5 X \"b\\",
		"* 2 FETCH (ENVELOPE (\"d\" \"s\" (\"unclosed",
		"* 2 FETCH (ENVELOPE (\"d\" {",
		"* 2 FETCH (ENVELOPE (\"d\" {7",
		"* 2 FETCH (ENVELOPE (\"d\" {7}",
		"* 2 FETCH (((((((",
		"* 2 FETCH )))))",
		"* 2 FETCH (UID",
		"* 2 FETCH (ENVELOPE",
		"* 2 FETCH (ENVELOPE (",
	};
	for(i := 0; i < len lines; i++) {
		(m, e) := parse(lines[i]);
		t.assert(e == nil, sys->sprint("line %d parsed with no exception (%s)", i, e));
		t.assert(e != nil || m != nil, sys->sprint("line %d is a FETCH of message 2", i));
	}
	(m, e) := parse("* 2 FETCH (FLAGS () UID 102 RFC822.SIZE 9 ENVELOPE (\"x\\");
	if(e == nil && m != nil)
		t.asserteq(m.uid, 102, "the UID before the broken string is read");

	name: string;
	{
		name = imap->parselistname("* LIST (\\HasNoChildren) \"/\" \"box\\");
	} exception x {
	"*" =>
		t.error("parselistname raised " + x);
	}
	t.assertseq(name, "box", "a mailbox's name ending in a backslash is what precedes it");
}

testQuoted(t: ref T)
{
	(m, e) := parse("* 1 FETCH (UID 9 ENVELOPE (\"d\" \"say \\\"hi\\\" \\\\ there\" NIL NIL NIL NIL NIL NIL NIL \"<i@d>\"))");
	t.assert(e == nil && m != nil && m.envelope != nil, "a subject with escapes parses");
	if(m != nil && m.envelope != nil) {
		t.assertseq(m.envelope.subject, "say \"hi\" \\ there", "a quoted string's escapes are undone");
		t.assertseq(m.envelope.messageid, "<i@d>", "and what follows it is where it was");
	}
	t.assertseq(imap->parselistname("* LIST () \"/\" \"a\\\"b\""), "a\"b", "a mailbox's name with a quote in it");
	t.assertseq(imap->parselistname("* LIST (\\Noselect \\HasChildren) \"/\" \"[Gmail]\""), "[Gmail]", "a quoted name after two attributes");
	t.assertseq(imap->parselistname("* LIST () NIL INBOX"), "INBOX", "an atom after a NIL delimiter");
}

testAddresses(t: ref T)
{
	(m, e) := parse(GOOD);
	t.assert(e == nil && m != nil && m.envelope != nil, "an ordinary line parses");
	if(m == nil || m.envelope == nil)
		return;
	env := m.envelope;
	t.assertseq(env.sender, "John Doe <john@example.com>", "From, as shown");
	t.assert(env.fromaddrs != nil && hd env.fromaddrs == "john@example.com" && tl env.fromaddrs == nil,
		"From's address by itself");
	t.assertseq(env.replyto, "Reply <reply@example.net>", "Reply-To, as shown");
	t.assert(env.replytoaddrs != nil && hd env.replytoaddrs == "reply@example.net", "Reply-To's address by itself");

	# a display name is the sender's text: it is not the address
	(m, e) = parse("* 1 FETCH (UID 9 ENVELOPE (\"d\" \"s\" ((\"ceo@corp.example>, <x\" NIL \"mallory\" \"evil.example\")) NIL NIL NIL NIL NIL NIL NIL))");
	t.assert(e == nil && m != nil && m.envelope != nil, "a From with an address for a name parses");
	if(m != nil && m.envelope != nil)
		t.assert(m.envelope.fromaddrs != nil && hd m.envelope.fromaddrs == "mallory@evil.example" &&
			tl m.envelope.fromaddrs == nil, "the address is the mailbox and host, whatever the name says");
}

testLiteral(t: ref T)
{
	t.asserteq(imap->checkliteral("* 1 FETCH (BODY[] {1234}"), 1234, "a literal's count");
	t.asserteq(imap->checkliteral("* OK {99999999999999999999}"), 0, "a count of twenty digits is no literal to take");
	t.asserteq(imap->checkliteral("* OK {1500000000}"), 0, "nor is one of 1.5GB");
	t.asserteq(imap->checkliteral("* OK {-5}"), 0, "nor a negative one");
	t.asserteq(imap->checkliteral("* OK {12x}"), 0, "nor one that is not digits");
	t.asserteq(imap->checkliteral("{}"), 0, "nor none");

	# a literal's place with no literal there is no string, and what
	# follows is read where it is
	(m, e) := parse("* 1 FETCH (UID 9 ENVELOPE (\"d\" {0} ((\"A\" NIL \"a\" \"x.example\")) NIL NIL NIL NIL NIL NIL \"<i@d>\"))");
	t.assert(e == nil && m != nil && m.envelope != nil, "a line naming a literal it has not parses");
	if(m != nil && m.envelope != nil) {
		t.assertnil(m.envelope.subject, "the literal's place is empty");
		t.assertseq(m.envelope.sender, "A <a@x.example>", "and the From after it is the From");
	}
}

testUid(t: ref T)
{
	(a, nil) := parse("* 1 FETCH (UID 4000000000)");
	(b, nil) := parse("* 2 FETCH (UID 4000000001)");
	(c, nil) := parse("* 3 FETCH (UID 2147483648)");
	t.assert(a != nil && b != nil && c != nil, "UIDs past 2^31 parse");
	if(a == nil || b == nil || c == nil)
		return;
	t.assert(a.uid != b.uid && a.uid != c.uid && b.uid != c.uid, "and are different messages");
	t.assertseq(imap->uidstr(a.uid), "4000000000", "a UID past 2^31 is printed as it was sent");
	t.assertseq(imap->uidstr(c.uid), "2147483648", "2^31 too");
	t.assertseq(imap->uidstr(77), "77", "and a small one");
	(d, nil) := parse("* 1 FETCH (UID 99999999999)");
	t.assert(d != nil && d.uid == 0, "a UID of more than 32 bits is none");
	(x, nil) := parse("* 99999999999 FETCH (UID 5)");
	t.assert(x != nil && x.seq > 0, "a sequence number past an int is the largest, not a wrapped one");
}

testArguments(t: ref T)
{
	(nil, e) := imap->search("ALL\r\nX1 DELETE Archive");
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "a search with a line break in it is refused: " + e);
	(nil, e) = imap->uidsearch("ALL\nX1 NOOP");
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "by UID too: " + e);
	(nil, e) = imap->select("INBOX\r\nX2 DELETE Sent");
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "a mailbox's name with a line break is refused: " + e);
	e = imap->copy("1", "Nowhere\r\nX3 DELETE Sent");
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "a copy's destination with a line break is refused: " + e);
	e = imap->copy("1 X4 NOOP", "Archive");
	t.assert(e != nil && imap->strindex(e, "sequence set") >= 0, "a copy of what is no sequence set is refused: " + e);
	e = imap->uidcopy(5, "A\0B");
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "a NUL is refused as a line break is: " + e);
	e = imap->open("alice", "pass\r\nX5 LOGOUT", "127.0.0.1!1", Imap->IMPLICIT_TLS);
	t.assert(e != nil && imap->strindex(e, "line break") >= 0, "a password with a line break is refused before anything is dialled: " + e);
	t.assert(imap->strindex(e, "X5") < 0, "and is not in the error");
}

# A FETCH line changed at random, 3000 times: every one parses or is
# refused, and none raises.
testMutations(t: ref T)
{
	seed := 12345;
	junk := "\"\\(){} \r\n*0";
	raised := 0;
	first := "";
	for(n := 0; n < 3000; n++) {
		line := GOOD;
		k := 1 + (seed >> 8) % 4;
		for(j := 0; j < k; j++) {
			seed = seed * 1103515245 + 12345;
			pos := ((seed >> 8) & 16r7FFFFF) % len line;
			seed = seed * 1103515245 + 12345;
			what := ((seed >> 8) & 16r7FFFFF) % 3;
			seed = seed * 1103515245 + 12345;
			ch := junk[((seed >> 8) & 16r7FFFFF) % len junk];
			case what {
			0 =>	line = line[0:pos];
			1 =>	line[pos] = ch;
			2 =>	line = line[0:pos] + line[pos:pos+1] + line[pos:];
			}
			if(len line == 0)
				line = "*";
		}
		(nil, e) := parse(line);
		if(e != nil) {
			raised++;
			if(first == "")
				first = e + ": " + line;
		}
	}
	t.assert(raised == 0, sys->sprint("%d of 3000 changed lines raised (%s)", raised, first));
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
	imap = load Imap Imap->PATH;
	if(imap == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Imap->PATH);
		raise "fail:cannot load imap";
	}

	run("Backslash", testBackslash);
	run("Quoted", testQuoted);
	run("Addresses", testAddresses);
	run("Literal", testLiteral);
	run("Uid", testUid);
	run("Arguments", testArguments);
	run("Mutations", testMutations);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
