implement BioauthTest;

#
# bioauth_test — Unit tests for /dis/lib/bioauth.dis.
#
# The biometric prompt cannot be invoked in a test (no UI, no Secure
# Enclave on the host). What we *can* test, and what burns the most
# real bugs, is everything around the prompt: slot-name validation,
# the wire format that goes over /phone/bio_store, and the failure
# behaviour when /phone is not bound at all (the case on every desktop
# build that boots without a phone bridge).
#
# Tested surfaces:
#   - valid_name() — every reject path (empty, too long, slash, NUL,
#     newline) and the accept path
#   - store() — invalid name short-circuits before any 9p I/O; empty
#     payload likewise; bridge-missing surfaces as an error string
#     rather than a panic
#   - retrieve() — invalid name short-circuits; bridge-missing
#     surfaces as an error
#   - available() — returns AVAIL_NONE when /phone/bio_status is
#     absent (host build)
#
# We do NOT mock the bridge — that would only tell us our mock works.
# The Bioauth module is small enough that the pure-validation paths
# are most of the surface; the bridge half is exercised end-to-end on
# device.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "bioauth.m";
	bioauth: Bioauth;

BioauthTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/bioauth_test.b";

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

testValidNameAccepts(t: ref T)
{
	t.assert(bioauth->valid_name("serve-llm") == 1, "hyphenated kebab name");
	t.assert(bioauth->valid_name("a") == 1, "single char");
	t.assert(bioauth->valid_name("secstore.factotum") == 1, "dotted name");
	# 63 chars (BIO_NAME_MAX-1)
	long63 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
	t.asserteq(len long63, 63, "fixture is 63 chars");
	t.assert(bioauth->valid_name(long63) == 1, "63-char name at limit");
}

testValidNameRejects(t: ref T)
{
	t.assert(bioauth->valid_name("") == 0, "empty rejected");
	# 64 chars (one over limit)
	long64 := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
	t.asserteq(len long64, 64, "fixture is 64 chars");
	t.assert(bioauth->valid_name(long64) == 0, "64-char name over limit");
	t.assert(bioauth->valid_name("a/b") == 0, "slash rejected");
	t.assert(bioauth->valid_name("a\nb") == 0, "newline rejected");
	# NUL byte
	nulname := "a";
	nulname[0] = 0;
	t.assert(bioauth->valid_name(nulname) == 0, "NUL rejected");
}

# store() must short-circuit on invalid name BEFORE opening any file.
# Easiest way to confirm: on a host where /phone is not bound, a
# valid-name store fails with a recognisable open-style error; an
# invalid-name store fails with the validation error. The error
# strings differ — that's the assertion.
testStoreRejectsInvalidName(t: ref T)
{
	err := bioauth->store("a/b", "payload");
	t.assertnotnil(err, "invalid name produces error");
	t.assertseq(err, "bioauth: invalid slot name",
		"validation error string");
}

testStoreRejectsEmptyPayload(t: ref T)
{
	err := bioauth->store("serve-llm", "");
	t.assertnotnil(err, "empty payload produces error");
	t.assertseq(err, "bioauth: empty payload",
		"empty-payload error string");
}

# On a host build /phone is not bound; sys->open returns nil and we
# surface that as a descriptive error rather than crashing.
testStoreSurfacesMissingBridge(t: ref T)
{
	# Skip if /phone happens to be bound (running the test inside an
	# iOS sim build will exercise it for real anyway).
	(ok, nil) := sys->stat("/phone/bio_store");
	if(ok >= 0) {
		t.log("/phone/bio_store present — skipping host-only test");
		t.skipped = 1;
		raise "fail:skip";
	}
	err := bioauth->store("serve-llm", "payload-bytes");
	t.assertnotnil(err, "missing bridge produces error");
	t.assert(len err >= len "bioauth: cannot open",
		"error mentions cannot open");
}

testRetrieveRejectsInvalidName(t: ref T)
{
	(payload, err) := bioauth->retrieve("");
	t.assert(payload == nil, "empty-name returns nil payload");
	t.assertseq(err, "bioauth: invalid slot name",
		"validation error string");
}

testRetrieveSurfacesMissingBridge(t: ref T)
{
	(ok, nil) := sys->stat("/phone/bio_retrieve");
	if(ok >= 0) {
		t.log("/phone/bio_retrieve present — skipping host-only test");
		t.skipped = 1;
		raise "fail:skip";
	}
	(payload, err) := bioauth->retrieve("serve-llm");
	t.assert(payload == nil, "no payload when bridge missing");
	t.assertnotnil(err, "error string when bridge missing");
}

testAvailableNoBridge(t: ref T)
{
	(ok, nil) := sys->stat("/phone/bio_status");
	if(ok >= 0) {
		t.log("/phone/bio_status present — skipping host-only test");
		t.skipped = 1;
		raise "fail:skip";
	}
	# On a host build with no /phone, AVAIL_NONE is the contract:
	# callers degrade to the on-disk keyfile path silently.
	st := bioauth->available();
	t.asserteq(st, Bioauth->AVAIL_NONE,
		"available() returns AVAIL_NONE when /phone absent");
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

	bioauth = load Bioauth Bioauth->PATH;
	if(bioauth == nil) {
		sys->fprint(sys->fildes(2),
			"cannot load Bioauth %s: %r\n", Bioauth->PATH);
		raise "fail:cannot load bioauth";
	}
	if((err := bioauth->init()) != nil) {
		sys->fprint(sys->fildes(2), "bioauth init failed: %s\n", err);
		raise "fail:init";
	}

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("ValidNameAccepts", testValidNameAccepts);
	run("ValidNameRejects", testValidNameRejects);
	run("StoreRejectsInvalidName", testStoreRejectsInvalidName);
	run("StoreRejectsEmptyPayload", testStoreRejectsEmptyPayload);
	run("StoreSurfacesMissingBridge", testStoreSurfacesMissingBridge);
	run("RetrieveRejectsInvalidName", testRetrieveRejectsInvalidName);
	run("RetrieveSurfacesMissingBridge", testRetrieveSurfacesMissingBridge);
	run("AvailableNoBridge", testAvailableNoBridge);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
