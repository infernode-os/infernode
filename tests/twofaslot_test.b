implement TwofaslotTest;

#
# Regression / accreditation tests for the YubiKey-gated secstore key-slot model
# (see doc/second-factor-auth.md, doc/yubikey-2fa-operations.md). These assert the
# security PROPERTIES that must never regress, using only the recovery-slot path
# and the crypto primitives — NO hardware touch required, so they run in CI.
#
# Hardware paths (UV derive determinism, key-slot unlock, backup-key login) need a
# physical touch and live in the manual t2uv-style harness, not here.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";			# secstore.m / twofaslot.m reference Dial->Connection
include "keyring.m";
include "security.m";
	random: Random;
include "testing.m";
	testing: Testing;
	T: import testing;
include "secstore.m";
	secstore: Secstore;
include "twofaslot.m";
	twofaslot: Twofaslot;

TwofaslotTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE:  con "/tests/twofaslot_test.b";
TESTUSER: con "twofa_regress";

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

eqb(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

slotdir(): string
{
	return Twofaslot->Slotbase + "/" + TESTUSER + "/2fa";
}

cleanslots()
{
	dir := slotdir();
	fd := sys->open(dir, Sys->OREAD);
	if(fd != nil){
		for(;;){
			(n, d) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				sys->remove(dir + "/" + d[i].name);
		}
		fd = nil;
	}
	sys->remove(dir);
	sys->remove(Twofaslot->Slotbase + "/" + TESTUSER);
}

# The slot envelope: a random data key wraps and unwraps cleanly under a KEK.
testDataKeyEnvelope(t: ref T)
{
	DK := random->randombuf(Random->ReallyRandom, 32);
	t.assert(DK != nil && len DK == 32, "generate a 32-byte data key");
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	R := random->randombuf(Random->ReallyRandom, 32);
	kek := secstore->mkkek2fa(rootkey, R);
	t.assert(kek != nil && len kek == 32, "mkkek2fa yields a 32-byte KEK");
	wrap := secstore->encrypt3(DK, kek);
	t.assert(wrap != nil, "encrypt3 wraps the data key");
	out := secstore->decrypt3(wrap, kek, nil, nil);
	t.assert(eqb(out, DK), "decrypt3 recovers the exact data key");
	t.assert(!eqb(secstore->decrypt3(wrap, rootkey, nil, nil), DK),
		"a different key cannot unwrap the data key");
}

# mkkek2fa is deterministic in (rootkey, R) and sensitive to both inputs.
testMkkek2faDeterminism(t: ref T)
{
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	R := array[32] of byte;
	for(i := 0; i < 32; i++)
		R[i] = byte i;
	k1 := secstore->mkkek2fa(rootkey, R);
	k2 := secstore->mkkek2fa(rootkey, R);
	t.assert(eqb(k1, k2), "mkkek2fa is deterministic for the same (rootkey,R)");
	R2 := array[32] of byte;
	for(i = 0; i < 32; i++)
		R2[i] = byte (i + 1);
	t.assert(!eqb(k1, secstore->mkkek2fa(rootkey, R2)), "a different R yields a different KEK");
	root2 := secstore->mkfilekey3(TESTUSER, "other-password");
	t.assert(!eqb(k1, secstore->mkkek2fa(root2, R)), "a different rootkey yields a different KEK");
}

# The recovery slot round-trips the data key end-to-end (no hardware).
testRecoverySlotRoundTrip(t: ref T)
{
	cleanslots();
	DK := random->randombuf(Random->ReallyRandom, 32);
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	recpass := "correct horse battery staple";
	e := twofaslot->writeslots(TESTUSER, rootkey, DK, nil, recpass, "");
	t.assertnil(e, "writeslots writes a recovery slot");
	t.asserteq(twofaslot->is2fa(TESTUSER), 1, "account reads as 2FA once a slot exists");
	(dk2, ue) := twofaslot->unlock(TESTUSER, rootkey, recpass, "");
	t.assertnil(ue, "unlock via the recovery passphrase succeeds");
	t.assert(eqb(dk2, DK), "the recovery slot recovers the exact data key");
	cleanslots();
	t.asserteq(twofaslot->is2fa(TESTUSER), 0, "account is not 2FA after the slots are gone");
}

# A wrong recovery passphrase cannot recover the data key.
testWrongRecoveryFails(t: ref T)
{
	cleanslots();
	DK := random->randombuf(Random->ReallyRandom, 32);
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	twofaslot->writeslots(TESTUSER, rootkey, DK, nil, "right-passphrase", "");
	(dk2, ue) := twofaslot->unlock(TESTUSER, rootkey, "wrong-passphrase", "");
	t.assert(dk2 == nil, "a wrong recovery passphrase yields no data key");
	t.assertnotnil(ue, "a wrong recovery passphrase returns an error");
	cleanslots();
}

# THE core AAL3 property: a data-key-encrypted factotum blob is NOT decryptable
# with the password — so a 2FA account can never silently fall back to password
# strength (closes the downgrade gap).
testNoSilentDowngrade(t: ref T)
{
	DK := random->randombuf(Random->ReallyRandom, 32);
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	filekey := secstore->mkfilekey2("pw");
	legacy := secstore->mkfilekey("pw");
	plaintext := array of byte "key proto=pass service=x !password=s\n";
	blob := secstore->encrypt3(plaintext, DK);
	t.assert(blob != nil, "factotum blob encrypted under the data key");
	out := secstore->decrypt3(blob, rootkey, filekey, legacy);
	t.assert(out == nil, "password-derived keys CANNOT decrypt a DK-encrypted blob");
	t.assert(eqb(secstore->decrypt3(blob, DK, nil, nil), plaintext),
		"the data key still decrypts its own blob");
}

# writeslots is additive: adding a slot never deletes a pre-existing one
# (the no-single-point-of-failure invariant behind '2fa addkey').
testWriteslotsAdditive(t: ref T)
{
	cleanslots();
	sys->create(Twofaslot->Slotbase, Sys->OREAD, Sys->DMDIR | int 8r700);
	sys->create(Twofaslot->Slotbase + "/" + TESTUSER, Sys->OREAD, Sys->DMDIR | int 8r700);
	dir := slotdir();
	sys->create(dir, Sys->OREAD, Sys->DMDIR | int 8r700);
	fd := sys->create(dir + "/key", Sys->OWRITE, 8r600);
	if(fd != nil){
		b := array of byte "kind key\ncred deadbeef\nsalt 0011\nwrap 00\n";
		sys->write(fd, b, len b);
		fd = nil;
	}
	DK := random->randombuf(Random->ReallyRandom, 32);
	rootkey := secstore->mkfilekey3(TESTUSER, "pw");
	twofaslot->writeslots(TESTUSER, rootkey, DK, nil, "recpass", "");
	(ok, nil) := sys->stat(dir + "/key");
	t.assert(ok >= 0, "writeslots preserved the pre-existing key slot");
	(ok2, nil) := sys->stat(dir + "/recovery");
	t.assert(ok2 >= 0, "writeslots added the recovery slot alongside it");
	cleanslots();
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	secstore = load Secstore Secstore->PATH;
	twofaslot = load Twofaslot Twofaslot->PATH;
	random = load Random Random->PATH;

	if(testing == nil){ sys->fprint(sys->fildes(2), "cannot load testing: %r\n"); raise "fail:load"; }
	if(secstore == nil){ sys->fprint(sys->fildes(2), "cannot load secstore: %r\n"); raise "fail:load"; }
	if(twofaslot == nil){ sys->fprint(sys->fildes(2), "cannot load twofaslot: %r\n"); raise "fail:load"; }
	if(random == nil){ sys->fprint(sys->fildes(2), "cannot load random: %r\n"); raise "fail:load"; }

	testing->init();
	secstore->init();
	twofaslot->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("DataKeyEnvelope", testDataKeyEnvelope);
	run("Mkkek2faDeterminism", testMkkek2faDeterminism);
	run("RecoverySlotRoundTrip", testRecoverySlotRoundTrip);
	run("WrongRecoveryFails", testWrongRecoveryFails);
	run("NoSilentDowngrade", testNoSilentDowngrade);
	run("WriteslotsAdditive", testWriteslotsAdditive);

	cleanslots();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
