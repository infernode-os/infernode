implement SecstoreCryptoTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "secstore.m";
	secstore: Secstore;

SecstoreCryptoTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/secstore_crypto_test.b";

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

testSGCM2RoundTrip(t: ref T)
{
	user := "alice";
	pass := "correct horse battery staple";
	rootkey := secstore->mkfilekey3(user, pass);
	gcm1key := secstore->mkfilekey2(pass);
	plaintext := array of byte "key proto=pass service=test !password=secret\n";

	blob := secstore->encrypt3(plaintext, rootkey);
	t.assert(blob != nil, "encrypt3 returns a blob");
	t.assert(hasprefix(blob, "SGCM2\n"), "encrypt3 writes SGCM2 header");

	out := secstore->decrypt3(blob, rootkey, gcm1key, nil);
	t.assert(out != nil, "decrypt3 reads SGCM2 blob");
	t.assertseq(string out, string plaintext, "SGCM2 round-trip preserves plaintext");
}

testSGCM1Compat(t: ref T)
{
	user := "alice";
	pass := "correct horse battery staple";
	rootkey := secstore->mkfilekey3(user, pass);
	gcm1key := secstore->mkfilekey2(pass);
	plaintext := array of byte "legacy modern blob\n";

	blob := secstore->encrypt2(plaintext, gcm1key);
	t.assert(blob != nil, "encrypt2 returns a blob");
	t.assert(hasprefix(blob, "SGCM1\n"), "encrypt2 still writes SGCM1 header");

	out := secstore->decrypt3(blob, rootkey, gcm1key, nil);
	t.assert(out != nil, "decrypt3 still reads SGCM1 blob");
	t.assertseq(string out, string plaintext, "SGCM1 compatibility preserved");
}

testSGCM2UserBinding(t: ref T)
{
	pass := "correct horse battery staple";
	right := secstore->mkfilekey3("alice", pass);
	wrong := secstore->mkfilekey3("bob", pass);
	gcm1key := secstore->mkfilekey2(pass);
	plaintext := array of byte "user scoped root key\n";

	blob := secstore->encrypt3(plaintext, right);
	t.assert(blob != nil, "encrypt3 returns a blob for user binding test");

	out := secstore->decrypt3(blob, wrong, gcm1key, nil);
	t.assert(out == nil, "wrong user root key cannot decrypt SGCM2 blob");
}

hasprefix(a: array of byte, s: string): int
{
	p := array of byte s;
	if(len a < len p)
		return 0;
	for(i := 0; i < len p; i++)
		if(a[i] != p[i])
			return 0;
	return 1;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	secstore = load Secstore Secstore->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(secstore == nil) {
		sys->fprint(sys->fildes(2), "cannot load secstore module: %r\n");
		raise "fail:cannot load secstore";
	}

	testing->init();
	secstore->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("SGCM2RoundTrip", testSGCM2RoundTrip);
	run("SGCM1Compat", testSGCM1Compat);
	run("SGCM2UserBinding", testSGCM2UserBinding);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
