implement AuditverifyTest;

#
# Unit tests for the offline audit-log verifier (appl/cmd/auditverify.b).
# Deterministic — no mount, no auditfs, no factotum: chains are built
# by hand with the auditchain module (so every stored hash is correct
# by construction), written to files under /tmp, and fed to the real
# auditverify command module. Covers the adversarial cases the live
# integration test cannot conveniently stage:
#
#   - a rewrite that strips signatures / checkpoint records must FAIL
#     under -k (signatures are mandatory when the public key is given)
#   - a truncated chain must FAIL against an off-host head copy (-a)
#   - a forged checkpoint whose head does not match the chain must FAIL
#
# The one mldsa87 signer key is generated once and shared by all tests.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "testing.m";
	testing: Testing;
	T: import testing;

include "auditchain.m";
	ac: Auditchain;

AuditverifyTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);

	# INFR-310 workaround: keep this module type structurally distinct
	# from Auditverify below, or the compiler shares one LDT between
	# them and the ref-fn'd test functions pollute it — making the
	# load demand that auditverify implement the test functions.
	ldtworkaround: fn();
};

# the command under test, loaded by its canonical path
Auditverify: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

ldtworkaround()
{
}

AVPATH: con "/dis/auditverify.dis";
SRCFILE: con "/tests/auditverify_test.b";

sk: ref Keyring->SK;		# shared mldsa87 signer
pubfile: con "/tmp/avtest.pub";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>	;
	"fail:skip" =>	;
	* =>		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# runverify drives the real command; 0 = verified ok, -1 = it raised.
runverify(args: list of string): int
{
	av := load Auditverify AVPATH;
	if(av == nil)
		return -999;
	{
		av->init(nil, "auditverify" :: args);
		return 0;
	} exception {
	"fail:*" =>
		return -1;
	}
}

writefile(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		raise "fail:cannot create " + path;
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		raise "fail:short write " + path;
}

# mkrec seals one record exactly as auditfs does: extend the chain over
# the canonical fields, store the hash between event and message.
mkrec(prev: array of byte, seq, t: int, source, event, msg: string): (array of byte, string)
{
	h := ac->extend(prev, array of byte ac->canon(seq, t, source, event, msg));
	line := sys->sprint("%d %d %s %s %s %s\n", seq, t, source, event, ac->hex(h), msg);
	return (h, line);
}

# mkcheck seals a checkpoint record at sequence number cseq whose signed
# tip is the current chain head (covering records 1..cseq-1).
mkcheck(prev: array of byte, cseq, t: int, signit: int): (array of byte, string)
{
	head := ac->hex(prev);
	msg := sys->sprint("head=%s seq=%d", head, cseq-1);
	if(signit) {
		content := array of byte sys->sprint("audit-checkpoint %s %d", head, cseq-1);
		cert := kr->sign(sk, 0, kr->sha256(content, len content, nil, nil), "sha256");
		if(cert == nil)
			raise "fail:sign failed";
		msg += " sig=" + ac->hex(array of byte kr->certtostr(cert));
	}
	return mkrec(prev, cseq, t, "-", "checkpoint", msg);
}

# chainof builds n plain records and returns (tip, text).
chainof(n: int): (array of byte, string)
{
	prev := ac->genesis();
	s := "";
	for(i := 1; i <= n; i++) {
		line: string;
		(prev, line) = mkrec(prev, i, 1000+i, "login", "unlock", sys->sprint("user=u%d", i));
		s += line;
	}
	return (prev, s);
}

testIntactOk(t: ref T)
{
	(nil, s) := chainof(3);
	writefile("/tmp/avtest.intact", s);
	t.asserteq(runverify("/tmp/avtest.intact" :: nil), 0, "intact chain verifies");
}

testTamperFails(t: ref T)
{
	prev := ac->genesis();
	(h1, l1) := mkrec(prev, 1, 1001, "login", "unlock", "user=alice");
	# record 2 edited in place: the message changes, the stored hash doesn't
	(nil, forged) := mkrec(h1, 2, 1002, "login", "unlock", "user=bob");
	forged = replace(forged, "user=bob", "user=mallory");
	writefile("/tmp/avtest.tampered", l1 + forged);
	t.asserteq(runverify("/tmp/avtest.tampered" :: nil), -1, "edited record breaks the chain");
}

testAnchorOk(t: ref T)
{
	(tip, s) := chainof(5);
	writefile("/tmp/avtest.a5", s);
	writefile("/tmp/avtest.head5", sys->sprint("%s 5\n", ac->hex(tip)));
	t.asserteq(runverify("-a" :: "/tmp/avtest.head5" :: "/tmp/avtest.a5" :: nil), 0,
		"chain verifies against its own head");
}

testAnchorMidchainOk(t: ref T)
{
	# an OLDER head copy must still anchor a chain that has since grown
	prev := ac->genesis();
	s := "";
	head3 := "";
	for(i := 1; i <= 5; i++) {
		line: string;
		(prev, line) = mkrec(prev, i, 1000+i, "login", "unlock", sys->sprint("user=u%d", i));
		s += line;
		if(i == 3)
			head3 = ac->hex(prev);
	}
	writefile("/tmp/avtest.grown", s);
	writefile("/tmp/avtest.head3", sys->sprint("%s 3\n", head3));
	t.asserteq(runverify("-a" :: "/tmp/avtest.head3" :: "/tmp/avtest.grown" :: nil), 0,
		"older head copy anchors a grown chain");
}

testAnchorTruncationFails(t: ref T)
{
	(tip, nil) := chainof(5);
	(nil, s3) := chainof(3);	# same chain cut back to 3 records — internally valid
	writefile("/tmp/avtest.trunc", s3);
	writefile("/tmp/avtest.headt", sys->sprint("%s 5\n", ac->hex(tip)));
	t.asserteq(runverify("/tmp/avtest.trunc" :: nil), 0,
		"truncated chain is internally consistent (why anchoring exists)");
	t.asserteq(runverify("-a" :: "/tmp/avtest.headt" :: "/tmp/avtest.trunc" :: nil), -1,
		"truncated chain fails against the off-host head");
}

testAnchorRewriteFails(t: ref T)
{
	(tip, nil) := chainof(5);
	# a full rewrite: same length, different content, all hashes recomputed
	prev := ac->genesis();
	s := "";
	for(i := 1; i <= 5; i++) {
		line: string;
		(prev, line) = mkrec(prev, i, 2000+i, "login", "unlock", sys->sprint("user=evil%d", i));
		s += line;
	}
	writefile("/tmp/avtest.rewrite", s);
	writefile("/tmp/avtest.headr", sys->sprint("%s 5\n", ac->hex(tip)));
	t.asserteq(runverify("/tmp/avtest.rewrite" :: nil), 0,
		"a rewrite with recomputed hashes is internally consistent");
	t.asserteq(runverify("-a" :: "/tmp/avtest.headr" :: "/tmp/avtest.rewrite" :: nil), -1,
		"the rewrite fails against the off-host head");
}

testSignedCheckpointOk(t: ref T)
{
	prev := ac->genesis();
	s := "";
	line: string;
	(prev, line) = mkrec(prev, 1, 1001, "login", "unlock", "user=alice");
	s += line;
	(prev, line) = mkcheck(prev, 2, 1002, 1);
	s += line;
	(prev, line) = mkrec(prev, 3, 1003, "login", "unlock", "user=bob");
	s += line;
	writefile("/tmp/avtest.signed", s);
	t.asserteq(runverify("-k" :: pubfile :: "/tmp/avtest.signed" :: nil), 0,
		"signed checkpoint verifies under -k");
}

testUnsignedCheckpointFailsStrict(t: ref T)
{
	prev := ac->genesis();
	s := "";
	line: string;
	(prev, line) = mkrec(prev, 1, 1001, "login", "unlock", "user=alice");
	s += line;
	(prev, line) = mkcheck(prev, 2, 1002, 0);
	s += line;
	writefile("/tmp/avtest.unsigned", s);
	t.asserteq(runverify("/tmp/avtest.unsigned" :: nil), 0,
		"unsigned checkpoint passes without -k (chain-only reading)");
	t.asserteq(runverify("-k" :: pubfile :: "/tmp/avtest.unsigned" :: nil), -1,
		"unsigned checkpoint FAILS under -k (a rewrite could mint one)");
}

testStrippedCheckpointsFailStrict(t: ref T)
{
	# the whole-file rewrite that drops every checkpoint record: the
	# chain is internally valid, but with the public key in hand it
	# must NOT verify — nothing ties it to the audit key.
	(nil, s) := chainof(4);
	writefile("/tmp/avtest.stripped", s);
	t.asserteq(runverify("-k" :: pubfile :: "/tmp/avtest.stripped" :: nil), -1,
		"a chain with no signed checkpoints fails under -k");
}

testForgedCheckpointHeadFails(t: ref T)
{
	# a checkpoint whose head token is not the chain tip at that point
	prev := ac->genesis();
	s := "";
	line: string;
	(prev, line) = mkrec(prev, 1, 1001, "login", "unlock", "user=alice");
	s += line;
	msg := sys->sprint("head=%s seq=1", ac->hex(ac->genesis()));	# wrong tip
	(prev, line) = mkrec(prev, 2, 1002, "-", "checkpoint", msg);
	s += line;
	writefile("/tmp/avtest.forged", s);
	t.asserteq(runverify("/tmp/avtest.forged" :: nil), -1,
		"checkpoint head mismatch fails even without -k");
}

testWrongKeyFails(t: ref T)
{
	# a checkpoint signed by a DIFFERENT key must not verify
	other := kr->genSK("mldsa87", "other", 0);
	if(other == nil)
		t.fatal("genSK for second key failed");
	saved := sk;
	sk = other;
	prev := ac->genesis();
	s := "";
	line: string;
	(prev, line) = mkrec(prev, 1, 1001, "login", "unlock", "user=alice");
	s += line;
	(prev, line) = mkcheck(prev, 2, 1002, 1);
	s += line;
	sk = saved;
	writefile("/tmp/avtest.wrongkey", s);
	t.asserteq(runverify("-k" :: pubfile :: "/tmp/avtest.wrongkey" :: nil), -1,
		"checkpoint signed by another key fails under -k");
}

replace(s, pat, sub: string): string
{
	for(i := 0; i + len pat <= len s; i++)
		if(s[i:i+len pat] == pat)
			return s[0:i] + sub + s[i+len pat:];
	return s;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		raise "fail:cannot load keyring";
	ac = load Auditchain Auditchain->PATH;
	if(ac == nil)
		raise "fail:cannot load auditchain";
	ac->init();

	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	sk = kr->genSK("mldsa87", "audit", 0);
	if(sk == nil)
		raise "fail:genSK mldsa87 failed";
	writefile(pubfile, kr->pktostr(kr->sktopk(sk)));

	run("IntactOk", testIntactOk);
	run("TamperFails", testTamperFails);
	run("AnchorOk", testAnchorOk);
	run("AnchorMidchainOk", testAnchorMidchainOk);
	run("AnchorTruncationFails", testAnchorTruncationFails);
	run("AnchorRewriteFails", testAnchorRewriteFails);
	run("SignedCheckpointOk", testSignedCheckpointOk);
	run("UnsignedCheckpointFailsStrict", testUnsignedCheckpointFailsStrict);
	run("StrippedCheckpointsFailStrict", testStrippedCheckpointsFailStrict);
	run("ForgedCheckpointHeadFails", testForgedCheckpointHeadFails);
	run("WrongKeyFails", testWrongKeyFails);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
