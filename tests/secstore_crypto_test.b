implement SecstoreCryptoTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "dial.m";

include "keyring.m";
	kr: Keyring;

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

	# nothing writes SGCM1 now: one made as it was
	magic := array of byte "SGCM1\n";
	nonce := array[12] of {* => byte 9};
	(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(gcm1key, nonce), plaintext, magic);
	blob := array[len magic + 12 + len ct + len tag] of byte;
	blob[0:] = magic;
	blob[len magic:] = nonce;
	blob[len magic + 12:] = ct;
	blob[len magic + 12 + len ct:] = tag;

	out := secstore->decrypt3(blob, rootkey, gcm1key, nil);
	t.assert(out != nil, "decrypt3 reads an SGCM1 blob when given its key");
	t.assertseq(string out, string plaintext, "SGCM1 is read by whoever moves it");
	t.assert(secstore->decrypt3(blob, rootkey, nil, nil) == nil, "and not otherwise: the file does not choose its format");
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

testVerifierFormats(t: ref T)
{
	# secstore2 is retired (the client never offers it, nothing
	# enrols it): a verifier claiming it is refused, not trusted
	(ver, hexHi) := secstore->parseverifier("secstore2 deadbeef");
	t.assertnil(ver, "parseverifier refuses a retired secstore2 verifier");
	t.assertnil(hexHi, "and returns no verifier body for it");

	formatted := secstore->formatverifier("secstore3", "feedface");
	(ver, hexHi) = secstore->parseverifier(formatted);
	t.assertseq(ver, "secstore3", "parseverifier keeps secstore3 prefix");
	t.assertseq(hexHi, "feedface", "parseverifier keeps secstore3 verifier body");

	(ver, hexHi) = secstore->parseverifier("cafebabe");
	t.assertseq(ver, "secstore", "bare verifier parses as legacy secstore");
	t.assertseq(hexHi, "cafebabe", "bare verifier keeps legacy body");
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

# secstore version 5's key derivation (PAK5) against answers made by
# Python from its description (tests/host/secstore/pak5vectors.py)
ramp(mul, add, n: int): array of byte
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte (mul*i + add);
	return a;
}

hexs(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

testPak5Vectors(t: ref T)
{
	m := secstore->pak5mask("alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(19, 6, 32));
	t.assertseq(hexs(m), "0ebe324c5199ee7e72b6cf67a4db3dc0adfa38c909538ab9190b1c62048917af", "the masked ML-KEM seed");
	again := secstore->pak5mask("alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", m);
	t.assertseq(hexs(again), hexs(ramp(19, 6, 32)), "masked again it is the seed");
	(ps, pc, sess) := secstore->pak5keys("alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 5, 32));
	t.assertseq(hexs(ps), "2ba2357fccbb9dc4b4b992984eb6f0dfb4bea19b27b85a2e2485595d3a7ac2dee9244b383fa28c28f7292cfeaf86bf32", "the server's proof");
	t.assertseq(hexs(pc), "c8e4b85e9844e2e148a4b3ee24aa16312c2aa85bb3d77db6ae5516a8be5829fe79e7fbaabe53be4f6a955d9670162078", "the client's proof");
	t.assertseq(hexs(sess), "1eb6f49509ef9ba43cbb0b3e19c45dbf9e4fdf73d9c873a302a89bc8c68836363990ba8e61c4bf9d688d3294bfb0a621", "the session's secret");
	# each input changes it
	(ps2, nil, nil) := secstore->pak5keys("alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 6, 32));
	t.assert(hexs(ps2) != hexs(ps), "another ML-KEM secret, another proof");
	(ps2, nil, nil) = secstore->pak5keys("alice", "secstore", "m-text", "mu-text", "sigma-texT", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 5, 32));
	t.assert(hexs(ps2) != hexs(ps), "another PAK secret, another proof");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	secstore = load Secstore Secstore->PATH;
	kr = load Keyring Keyring->PATH;

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
	run("VerifierFormats", testVerifierFormats);
	run("Pak5Vectors", testPak5Vectors);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
