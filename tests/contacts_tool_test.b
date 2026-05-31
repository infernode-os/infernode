implement ContactsToolTest;

#
# contacts_tool_test - Unit tests for /dis/veltro/tools/contacts.dis
# (the Veltro `contacts` agent tool).
#
# Covers the pure body→filtered-rows transform. /phone/contacts is the
# device address book wire (TSV: name\tkind\tnumber per line, with
# optional "# …" bridge status lines). The test gives the tool a
# crafted body and asserts on what the agent will see.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

ToolContacts: module {
	PATH: con "/dis/veltro/tools/contacts.dis";
	init:   fn(): string;
	filter: fn(body: string, query: string): string;
};

ContactsToolTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/contacts_tool_test.b";

passed := 0;
failed := 0;
skipped := 0;

tool: ToolContacts;

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

# Synthetic address book the iOS bridge could plausibly emit. Three
# contacts, one with two numbers (mobile + work), names crafted to
# exercise case-insensitive substring matching including non-ASCII.
sample(): string
{
	return
		"Sarah Connor\tmobile\t+447700900100\n" +
		"Sarah Connor\twork\t+442071234567\n" +
		"John Doe\tmobile\t+15555550199\n" +
		"María García\tmobile\t+34699112233\n";
}

# substring_in_lower
contains(s, needle: string): int
{
	if(len needle == 0)
		return 1;
	for(i := 0; i <= len s - len needle; i++)
		if(s[i:i+len needle] == needle)
			return 1;
	return 0;
}

# Empty query returns the header + every row, with no truncation
# marker (4 rows fit well under MAX_RESULTS = 50).
testEmptyQueryReturnsAll(t: ref T)
{
	out := tool->filter(sample(), "");
	t.assert(contains(out, "name\tkind\tnumber\n"), "header row present");
	t.assert(contains(out, "Sarah Connor\tmobile\t+447700900100"), "first sarah row");
	t.assert(contains(out, "Sarah Connor\twork\t+442071234567"),   "second sarah row");
	t.assert(contains(out, "John Doe\tmobile\t+15555550199"),      "john row");
	t.assert(contains(out, "María García"),              "unicode row");
	t.assert(!contains(out, "# truncated"),                         "no truncation marker");
}

# Substring matches the name column, case-insensitive. "sarah" → both
# Sarah rows; "doe" → just John; nothing → "no matches" string.
testCaseInsensitiveSubstring(t: ref T)
{
	out := tool->filter(sample(), "sarah");
	t.assert(contains(out, "Sarah Connor\tmobile"), "lower-cased query → both Sarah rows");
	t.assert(contains(out, "Sarah Connor\twork"),   "...and the work row");
	t.assert(!contains(out, "John Doe"),            "John not included");

	out2 := tool->filter(sample(), "DOE");
	t.assert(contains(out2, "John Doe"),            "upper-case query matches");
	t.assert(!contains(out2, "Sarah Connor"),       "Sarah excluded for `doe`");
}

# Whitespace and a trailing newline around the query — typical of how
# the chat surface would hand the arg — get trimmed.
testQueryIsTrimmed(t: ref T)
{
	out := tool->filter(sample(), "  garcía  \n");
	t.assert(contains(out, "María García"), "unicode substring after trim");
}

# Nothing matches → a clear "no matches" reply, not an empty TSV.
testNoMatches(t: ref T)
{
	out := tool->filter(sample(), "nobody");
	t.assertseq(out, "contacts: no matches for 'nobody'",
		"no-match response is explicit");
}

# Status / error lines from the bridge ("# permission denied …") are
# passed through verbatim so the agent can tell denied from empty.
testBridgeStatusPassedThrough(t: ref T)
{
	body := "# contacts: permission denied — enable in Settings > InferNode > Contacts\n";
	out := tool->filter(body, "anything");
	t.assert(contains(out, "# contacts: permission denied"),
		"comment lines surface to caller");
}

# Malformed rows (no \t) are silently dropped — better than echoing
# garbage that the agent might try to parse as a contact.
testMalformedRowsDropped(t: ref T)
{
	body :=
		"this-is-not-a-tsv-row\n" +
		"Sarah Connor\tmobile\t+447700900100\n";
	out := tool->filter(body, "sarah");
	t.assert(contains(out, "Sarah Connor\tmobile\t+447700900100"),
		"valid row matched");
	t.assert(!contains(out, "this-is-not-a-tsv-row"),
		"malformed row not emitted");
}

# > MAX_RESULTS matches → truncation marker appended.
testTruncationMarker(t: ref T)
{
	body := "";
	# 55 same-named rows so a "common" query matches > MAX_RESULTS = 50.
	for(i := 0; i < 55; i++)
		body += sys->sprint("Common Name\tmobile\t+1555000%04d\n", i);
	out := tool->filter(body, "common");
	t.assert(contains(out, "# truncated at 50 rows (query='common')"),
		"truncation marker present after 50 matches");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	tool = load ToolContacts ToolContacts->PATH;
	if(tool == nil) {
		sys->fprint(sys->fildes(2),
			"contacts_tool_test: cannot load %s: %r\n", ToolContacts->PATH);
		raise "fail:cannot load ToolContacts";
	}
	# init() populates module-level sys/str refs that filter() uses.
	ierr := tool->init();
	if(ierr != nil) {
		sys->fprint(sys->fildes(2),
			"contacts_tool_test: init failed: %s\n", ierr);
		raise "fail:tool init";
	}

	run("EmptyQueryReturnsAll",      testEmptyQueryReturnsAll);
	run("CaseInsensitiveSubstring",  testCaseInsensitiveSubstring);
	run("QueryIsTrimmed",            testQueryIsTrimmed);
	run("NoMatches",                 testNoMatches);
	run("BridgeStatusPassedThrough", testBridgeStatusPassedThrough);
	run("MalformedRowsDropped",      testMalformedRowsDropped);
	run("TruncationMarker",          testTruncationMarker);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
