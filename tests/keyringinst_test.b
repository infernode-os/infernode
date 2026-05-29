implement KeyringinstTest;

#
# keyringinst_test - Unit tests for /dis/lib/keyringinst.dis.
#
# Covers the testable bits of the Settings "Install keyfile from
# clipboard" flow (INFR-169): payload cleanup, file write with strict
# 0600 perms, presence check. Uses /tmp paths so we don't touch the
# real /lib/keyring/serve-llm on the host.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "keyringinst.m";
	keyringinst: Keyringinst;

KeyringinstTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyringinst_test.b";

passed := 0;
failed := 0;
skipped := 0;

# Fixtures live under a per-test directory under /tmp so a re-run
# never trips on leftover state from a prior failed run.
TMPROOT: con "/tmp/keyringinst_test";

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

# prepare_payload — pure transform on the clipboard buffer. Today's
# only responsibility is stripping a single trailing CR; everything
# else passes through untouched (binary keyfile content stays bit-
# exact, including embedded NUL or 0x80+ bytes if any).

testPrepareTrailingCRStripped(t: ref T)
{
	# Windows-style clipboard contents ending in "...\r" — the
	# keyfile format is line-oriented and a stray CR would confuse
	# factotum / mount -k. One CR, one strip.
	in := "first\nsecond\r";
	out := keyringinst->prepare_payload(in);
	t.assertseq(out, "first\nsecond", "single trailing CR stripped");
}

testPrepareNoTrailingCRUntouched(t: ref T)
{
	in := "first\nsecond";
	out := keyringinst->prepare_payload(in);
	t.assertseq(out, "first\nsecond", "no CR → unchanged");
}

testPrepareEmptyStaysEmpty(t: ref T)
{
	# Empty buffer (e.g. clipboard was empty when snarfget ran)
	# must stay empty so install_payload can flag it without dereferencing.
	out := keyringinst->prepare_payload("");
	t.assertseq(out, "", "empty stays empty");
}

testPrepareLeavesInteriorCRUntouched(t: ref T)
{
	# A CR mid-string is left as-is (it's data, not a Windows newline
	# at end of file). Only the very last byte gets stripped.
	in := "first\rmiddle\nsecond";
	out := keyringinst->prepare_payload(in);
	t.assertseq(out, "first\rmiddle\nsecond",
		"interior CR preserved");
}

# install_payload — writes to disk with strict perms and creates the
# parent dir if missing.

testInstallWritesPayload(t: ref T)
{
	dst := TMPROOT + "/serve-llm";
	payload := "0071\ned25519\ntest@example\nDEADBEEFCAFEBABE\n";
	err := keyringinst->install_payload(payload, dst);
	t.assertseq(err, "", "install reports no error");

	# Read it back, byte-for-byte.
	fd := sys->open(dst, Sys->OREAD);
	t.assert(fd != nil, "destination file readable");
	if(fd == nil) return;
	(sterr, d) := sys->fstat(fd);
	t.asserteq(sterr, 0, "fstat ok");
	t.asserteq(int d.length, len payload, "file size matches payload");

	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	t.asserteq(n, len payload, "read returns full payload");
	t.assertseq(string buf[:n], payload, "contents round-trip");

	# Mode 0600 — and 0600 ONLY. World / group must be zero so
	# factotum / mount -k will accept it.
	t.asserteq(int d.mode & 8r777, 8r600,
		"on-disk mode is exactly 0600");
}

testInstallCreatesParentDir(t: ref T)
{
	# A nested staging dir that doesn't exist yet — install_payload
	# must mkdir it as a side effect.
	dst := TMPROOT + "/nested/keyring/serve-llm";
	payload := "nested install payload\n";
	err := keyringinst->install_payload(payload, dst);
	t.assertseq(err, "", "install through missing dir succeeds");

	fd := sys->open(dst, Sys->OREAD);
	t.assert(fd != nil, "file at the nested path is readable");
}

testInstallEmptyPayloadRejected(t: ref T)
{
	dst := TMPROOT + "/should-not-exist";
	err := keyringinst->install_payload("", dst);
	t.assert(len err > 0,
		"empty payload returns a non-nil error string");
	(ok, nil) := sys->stat(dst);
	t.assert(ok < 0,
		"empty payload does not create the destination");
}

# present / status_text — sanity check against a known-missing path
# (DEFAULT_PATH is /lib/keyring/serve-llm which the test runner host
# almost certainly doesn't have).
testPresentReportsAbsence(t: ref T)
{
	# We can't generally guarantee DEFAULT_PATH is absent — but on
	# the desktop test runner /lib/keyring/serve-llm is not staged
	# (it's a user-supplied secret). status_text() formats the right
	# message for whichever branch fires.
	st := keyringinst->status_text();
	t.assert(st != "", "status_text returns something");
	# It's either present or missing; both substrings are valid.
	is_present := keyringinst->present();
	if(is_present) {
		t.assert(st[0:9] == "Keyfile: ",
			"present status starts with the same prefix");
	} else {
		t.assert(st[0:9] == "Keyfile: ",
			"missing status starts with the same prefix");
	}
}

mkroot()
{
	# Idempotent — sys->create with DMDIR is a mkdir.
	fd := sys->create(TMPROOT, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd != nil)
		fd = nil;
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

	keyringinst = load Keyringinst Keyringinst->PATH;
	if(keyringinst == nil) {
		sys->fprint(sys->fildes(2),
			"keyringinst_test: cannot load %s: %r\n", Keyringinst->PATH);
		raise "fail:cannot load Keyringinst";
	}
	ierr := keyringinst->init();
	if(ierr != nil) {
		sys->fprint(sys->fildes(2),
			"keyringinst_test: init failed: %s\n", ierr);
		raise "fail:keyringinst init";
	}
	mkroot();

	run("PrepareTrailingCRStripped",    testPrepareTrailingCRStripped);
	run("PrepareNoTrailingCRUntouched", testPrepareNoTrailingCRUntouched);
	run("PrepareEmptyStaysEmpty",       testPrepareEmptyStaysEmpty);
	run("PrepareLeavesInteriorCR",      testPrepareLeavesInteriorCRUntouched);
	run("InstallWritesPayload",         testInstallWritesPayload);
	run("InstallCreatesParentDir",      testInstallCreatesParentDir);
	run("InstallEmptyPayloadRejected",  testInstallEmptyPayloadRejected);
	run("PresentReportsAbsence",        testPresentReportsAbsence);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
