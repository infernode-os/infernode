implement AuditchainTest;

#
# Unit tests for the audit-log hash chain (module/auditchain.m).
# Pure and deterministic — no mount, no clock, no I/O.
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

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
