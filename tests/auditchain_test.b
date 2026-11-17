implement AuditchainTest;

#
# Unit tests for the audit-log hash chain (module/auditchain.m).
# Pure and deterministic — no mount, no clock, no I/O.
#
# CanonicalText, Value and Parse: a record has one text.  The cleaning
# was in the server, in two functions with two rules, and the stored
# line was read back by a third: see audit_canon_test.b.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "auditchain.m";
	ac: Auditchain;

AuditchainTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auditchain_test.b";

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

rec(seq, t: int, source, event, msg: string): array of byte
{
	return array of byte ac->canon(seq, t, source, event, msg);
}

testGenesisDeterministic(t: ref T)
{
	g1 := ac->genesis();
	g2 := ac->genesis();
	t.asserteq(len g1, Auditchain->HASHLEN, "genesis is HASHLEN bytes");
	t.assertseq(ac->hex(g1), ac->hex(g2), "genesis is deterministic");
}

testExtendChains(t: ref T)
{
	g := ac->genesis();
	h1 := ac->extend(g, rec(1, 1000, "login", "unlock", "user=alice"));
	h2 := ac->extend(h1, rec(2, 1001, "factotum", "keyadd", "owner=alice"));
	t.asserteq(len h1, Auditchain->HASHLEN, "h1 is HASHLEN bytes");
	t.assertsne(ac->hex(h1), ac->hex(g), "extend changes the hash");
	t.assertsne(ac->hex(h2), ac->hex(h1), "a second extend changes it again");
}

testTamperDetected(t: ref T)
{
	g := ac->genesis();
	r1  := rec(1, 1000, "login", "unlock", "user=alice");
	r1b := rec(1, 1000, "login", "unlock", "user=mallory");
	r2  := rec(2, 1001, "factotum", "keyadd", "owner=alice");
	good     := ac->hex(ac->extend(ac->extend(g, r1),  r2));
	tampered := ac->hex(ac->extend(ac->extend(g, r1b), r2));
	t.assertsne(good, tampered, "editing an earlier record changes the tip");
}

testReorderDetected(t: ref T)
{
	g := ac->genesis();
	r1 := rec(1, 1000, "a", "x", "m1");
	r2 := rec(2, 1001, "b", "y", "m2");
	ord12 := ac->hex(ac->extend(ac->extend(g, r1), r2));
	ord21 := ac->hex(ac->extend(ac->extend(g, r2), r1));
	t.assertsne(ord12, ord21, "reordering records changes the tip");
}

testDeletionDetected(t: ref T)
{
	g := ac->genesis();
	r1 := rec(1, 1000, "a", "x", "m1");
	r2 := rec(2, 1001, "b", "y", "m2");
	full    := ac->hex(ac->extend(ac->extend(g, r1), r2));
	dropped := ac->hex(ac->extend(g, r2));
	t.assertsne(full, dropped, "deleting a record changes the tip");
}

testHexFormat(t: ref T)
{
	h := ac->hex(ac->genesis());
	t.asserteq(len h, 2 * Auditchain->HASHLEN, "hex is 2 chars per byte");
}

# The canonical text: what the server seals is what a replay reads.
testCanonicalText(t: ref T)
{
	t.assertseq(ac->text("agent=1 tool=read\r\n"), "agent=1 tool=read", "CR LF at the end");
	t.assertseq(ac->text(" a  b\tc\nd \r e\u0000f\u007fg"), "a b c d e f g", "every blank one space");
	t.assertseq(ac->text("a\u00a0b\u2028c\u202ed\u3000e"), "a b c d e", "Unicode spaces, separators, reordering");
	t.assertseq(ac->text("\r\n \t"), "", "nothing but blanks is empty");
	t.assertseq(ac->text("café 日本"), "café 日本", "other text is kept");
	t.assertseq(ac->text(ac->text(" x \r y ")), ac->text(" x \r y "), "text of text is itself");

	t.assertseq(ac->token("check point\r"), "check_point_", "a token is one word");
	t.assertseq(ac->token(""), "-", "an empty token is -");
	t.assertseq(ac->token("login"), "login", "a word is kept");
}

testValue(t: ref T)
{
	v := ac->value("read status=ok content=0000\r\nsha256=ff 100%");
	t.assertseq(v, "read%20status%3Dok%20content%3D0000%0D%0Asha256%3Dff%20100%25", "a value is one word with no key in it");
	t.assertseq(ac->unvalue(v), "read status=ok content=0000\r\nsha256=ff 100%", "and reads back");
	t.assertseq(ac->value("a\u2028b"), "a%u2028b", "runes past U+00FF");
	t.assertseq(ac->unvalue("a%u2028b"), "a\u2028b", "read back");
	t.assertseq(ac->value("café-日本.txt"), "café-日本.txt", "text with nothing to hide is unchanged");
	t.assertseq(ac->unvalue("100%"), "100%", "a % that begins no escape is itself");
	t.assertseq(ac->unvalue("%zz%4"), "%zz%4", "nor one before what is not hex");
	t.assertseq(ac->text(ac->value(" a  b ")), ac->value(" a  b "), "a value is canonical text");
}

testParse(t: ref T)
{
	h := ac->hex(ac->genesis());
	line := ac->record(7, 1700000000, "login", "unlock", h, "user=alice aal=3");
	t.assertseq(line, "7 1700000000 login unlock " + h + " user=alice aal=3", "the stored line");
	(seq, tm, src, ev, hash, msg, ok) := ac->parse(line);
	t.assert(ok, "it parses");
	t.asserteq(seq, 7, "seq");
	t.asserteq(tm, 1700000000, "time");
	t.assertseq(src + " " + ev, "login unlock", "source and event");
	t.assertseq(hash, h, "hash");
	t.assertseq(msg, "user=alice aal=3", "message");

	(nil, nil, nil, nil, nil, m0, ok0) := ac->parse(ac->record(1, 5, "t", "e", h, ""));
	t.assert(ok0 && m0 == "", "an empty message parses");

	bad := array[] of {
		"7 1700000000 login unlock " + h + "  user=alice",	# two blanks
		" 7 1700000000 login unlock " + h + " user=alice",
		"7 1700000000 login unlock " + h + " user=alice ",
		"07 1700000000 login unlock " + h + " x",
		"7x 1700000000 login unlock " + h + " x",
		"+7 1700000000 login unlock " + h + " x",
		"0 1700000000 login unlock " + h + " x",
		"-3 1700000000 login unlock " + h + " x",
		"7 17e8 login unlock " + h + " x",
		"99999999999 1700000000 login unlock " + h + " x",
		"7 1700000000 login unlock " + h[0:63] + " x",
		"7 1700000000 login unlock " + h[0:63] + "G x",
		"7 1700000000 login unlock",
		"",
	};
	for(i := 0; i < len bad; i++) {
		(nil, nil, nil, nil, nil, nil, okb) := ac->parse(bad[i]);
		t.assert(!okb, sys->sprint("not a record: %q", bad[i]));
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	ac = load Auditchain Auditchain->PATH;
	if(ac == nil) {
		sys->fprint(sys->fildes(2), "cannot load auditchain module: %r\n");
		raise "fail:cannot load auditchain";
	}
	ac->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("GenesisDeterministic", testGenesisDeterministic);
	run("ExtendChains", testExtendChains);
	run("TamperDetected", testTamperDetected);
	run("ReorderDetected", testReorderDetected);
	run("DeletionDetected", testDeletionDetected);
	run("HexFormat", testHexFormat);
	run("CanonicalText", testCanonicalText);
	run("Value", testValue);
	run("Parse", testParse);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
