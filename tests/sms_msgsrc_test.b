implement SmsMsgSrcTest;

#
# sms_msgsrc_test - Unit tests for /dis/veltro/sources/sms.dis.
#
# Covers the bit of the SMS source that runs on the agent host and
# decides what the agent stack sees from each incoming /phone/sms
# record: parserecord(). Test loads SmsSrc as a module (so we don't
# need /phone bound during the test), calls parserecord with crafted
# inputs, and asserts on the Message fields.
#
# Why not exercise watch() directly? watch() spawns a reader kproc
# that blocks on sys->open("/phone/sms"). On the test host /phone is
# not bound (no #f device), so the open fails immediately and the
# kproc exits — by design, but uninteresting. The parsing logic is
# the algorithmic content of this source; that's what we cover here.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "msgsrc.m";

include "testing.m";
	testing: Testing;
	T: import testing;

SmsSrc: module {
	PATH: con "/dis/veltro/sources/sms.dis";
	# parserecord uses module-level sys/str references that init()
	# populates; the test calls init() with an empty config before
	# any parserecord invocation.
	init:        fn(config: string): string;
	parserecord: fn(rec: string): ref MsgSrc->Message;
};

SmsMsgSrcTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/sms_msgsrc_test.b";

passed := 0;
failed := 0;
skipped := 0;

smssrc: SmsSrc;

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

# Canonical record from devphone (the Hellaphone wire):
#   from <number> <iso-timestamp>\n
#   <body...>\n
# parserecord must surface number → sender, ts → timestamp, body → body,
# and synthesise a stable id of "<ts>:<number>" so the agent's dedup
# layer can key on it without round-tripping the bridge.
testCanonical(t: ref T)
{
	rec := "from +447700900100 2026-05-29T12:34:56Z\nhello from inferno\n";
	m := smssrc->parserecord(rec);
	t.assert(m != nil, "parserecord should return a Message");
	if(m == nil) return;
	t.assertseq(m.source,    "sms",                    "source = sms");
	t.assertseq(m.channel,   "inbox",                  "channel = inbox");
	t.assertseq(m.sender,    "+447700900100",          "sender from header");
	t.assertseq(m.timestamp, "2026-05-29T12:34:56Z",   "timestamp from header");
	t.assertseq(m.body,      "hello from inferno",     "body trimmed of trailing NL");
	t.assertseq(m.threadid,  "+447700900100",          "thread keyed by remote party");
	t.assertseq(m.id,        "2026-05-29T12:34:56Z:+447700900100",
	                                                   "id = ts:number");
	t.asserteq(m.flags, MsgSrc->FUNREAD,                "inbound is unread");
	t.assertseq(m.headers, "from +447700900100 2026-05-29T12:34:56Z",
	                                                   "raw header preserved");
}

# Bodies legitimately contain spaces, punctuation, even shell-special
# characters — the wire is just bytes after the header line.
testBodyWithSpacesAndPunct(t: ref T)
{
	rec := "from +15555550100 2026-05-29T01:00:00Z\nOn my way, ETA 10 min!\n";
	m := smssrc->parserecord(rec);
	if(m == nil) {
		t.fatal("parserecord returned nil for a valid multi-word body");
		return;
	}
	t.assertseq(m.body, "On my way, ETA 10 min!", "body preserved verbatim");
}

testBodyMissingTrailingNewline(t: ref T)
{
	# devphone's qproduce uses exact byte counts; a producer that
	# omits the final \n must still parse cleanly so we don't drop
	# the last record of a bridge flush.
	rec := "from +15555550100 2026-05-29T01:00:00Z\nno trailing nl";
	m := smssrc->parserecord(rec);
	if(m == nil) {
		t.fatal("parserecord returned nil without trailing NL");
		return;
	}
	t.assertseq(m.body, "no trailing nl", "body kept when wire has no trailing NL");
}

testBodyWithEmbeddedNewline(t: ref T)
{
	# Multi-line bodies (rare but valid) must round-trip — the parser
	# only splits the FIRST newline as header/body boundary.
	rec := "from +15555550100 2026-05-29T01:00:00Z\nline one\nline two\n";
	m := smssrc->parserecord(rec);
	if(m == nil) {
		t.fatal("parserecord returned nil for multi-line body");
		return;
	}
	t.assertseq(m.body, "line one\nline two",
		"body preserves embedded NL between header and trailing NL");
}

# Anything that isn't the canonical shape returns nil; the caller
# (handlerecord in watch()) turns that into an "error" Notification
# so the agent at least sees that something went wrong.
testNoHeader(t: ref T)
{
	m := smssrc->parserecord("hello with no header");
	t.assert(m == nil, "no \\n → nil");
}

testWrongVerb(t: ref T)
{
	# Only "from" is accepted as the verb. A bridge writing "received "
	# or "msg " or anything else is a protocol error.
	m := smssrc->parserecord("received +1 2026-05-29T00:00:00Z\nbody\n");
	t.assert(m == nil, "wrong verb → nil");
}

testTooFewHeaderTokens(t: ref T)
{
	# Header must have at least 3 tokens: verb, number, ts.
	m := smssrc->parserecord("from +447700900100\nbody\n");
	t.assert(m == nil, "missing timestamp → nil");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	smssrc = load SmsSrc SmsSrc->PATH;
	if(smssrc == nil) {
		sys->fprint(sys->fildes(2),
			"sms_msgsrc_test: cannot load %s: %r\n", SmsSrc->PATH);
		raise "fail:cannot load SmsSrc";
	}
	# parserecord depends on the module's sys/str refs being set, which
	# init() does. Empty config is fine — sms.b ignores it.
	ierr := smssrc->init("");
	if(ierr != nil) {
		sys->fprint(sys->fildes(2),
			"sms_msgsrc_test: SmsSrc->init failed: %s\n", ierr);
		raise "fail:smssrc init";
	}

	run("Canonical",                       testCanonical);
	run("BodyWithSpacesAndPunct",          testBodyWithSpacesAndPunct);
	run("BodyMissingTrailingNewline",      testBodyMissingTrailingNewline);
	run("BodyWithEmbeddedNewline",         testBodyWithEmbeddedNewline);
	run("NoHeader",                        testNoHeader);
	run("WrongVerb",                       testWrongVerb);
	run("TooFewHeaderTokens",              testTooFewHeaderTokens);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
