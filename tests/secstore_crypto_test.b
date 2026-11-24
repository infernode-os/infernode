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
	t.assert(hasprefix(blob, "SGCM3\n"), "encrypt3 writes the SGCM3 header (its file keys by HMAC-SHA-384)");
	t.assert(secstore->iscurrent(blob), "which is the current form");

	out := secstore->decrypt3(blob, rootkey, gcm1key, nil);
	t.assert(out != nil, "decrypt3 reads SGCM3 blob");
	t.assertseq(string out, string plaintext, "SGCM3 round-trip preserves plaintext");

	# openfile: under version 6's root it is current; under the old
	# root (the form before version 6) it opens and is to be moved
	c := secstore->mkcreds(user, pass);
	(o, cur) := secstore->openfile(secstore->encrypt3(plaintext, c.root6), c);
	t.assert(o != nil && cur == 1, "a file under version 6's root is of the current form");
	(o, cur) = secstore->openfile(blob, c);
	t.assert(o != nil && cur == 0, "one under the old root opens and is to be written again");
	t.asserteq(len c.root6, 48, "version 6's root is 48 bytes (PBKDF2-HMAC-SHA-384)");
	t.asserteq(len c.h6, 48, "and its verifier key too");
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

unhexs(h: string): array of byte
{
	a := array[len h/2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hv(h[2*i])<<4) | hv(h[2*i+1]));
	return a;
}

hv(c: int): int
{
	if(c >= 'a')
		return c - 'a' + 10;
	return c - '0';
}

testPak5Vectors(t: ref T)
{
	m := secstore->pak5mask("secstore5", "alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(19, 6, 32));
	t.assertseq(hexs(m), "da71d1d3a823312da20e38a8af0db52d40f344b5fe3116dfe31293f191bf40df", "the masked ML-KEM seed");
	again := secstore->pak5mask("secstore5", "alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", m);
	t.assertseq(hexs(again), hexs(ramp(19, 6, 32)), "masked again it is the seed");
	(ps, pc, sess) := secstore->pak5keys("secstore5", "alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 5, 32));
	t.assertseq(hexs(ps), "26cfb8ad0806da1276f968a982a1a9890383e7bc36d84bdb0a69e78b7cbce79dec1ac57a3bf7935b6d741261948706a0", "the server's proof");
	t.assertseq(hexs(pc), "20994b4b6b98cc5b5319622eb8494963f1718326330a4d9a9435e314f3cc47d9a97ca979158abda69d1a88b82f82567c", "the client's proof");
	t.assertseq(hexs(sess), "4021c76d1dd4e5ad4548b9c6c5a3d9fc9c934edc9289c49a5f432f7bc79a109505e4e2c261707e33e420e26ec3a84473", "the session's secret");
	# version 6's root and verifier key, and a file in SGCM3, against
	# hashlib's and cryptography's
	root6 := secstore->mkfilekey6("alice", "correct horse battery staple");
	t.assertseq(hexs(root6), "dc93add1269eff22a97aba5002b4da8f9cc3cb931e9c9d2a6b99f73cfdf304c742b113be5f4e6a7487f36e3c4e3a32e7", "version 6's root is PBKDF2-HMAC-SHA-384");
	t.assertseq(hexs(secstore->mkseckey6(root6)), "5b37682cc6d57988d983059602acb7b2d51aa64f34b75aa0e6da4a1029fb2755a2bce4a2a0db24e0c2a437a6d3501f04", "and its verifier key");
	blob := unhexs("5347434d330a0104070a0d101316191c1f2225282b2e02070c11161b20252a2f34391728b46d38baf8b3169a42393744083399b65b74d84682068f1f57adb98c505e8b152a2cf8bb031d433012bd6547247343825b5025");
	pt := secstore->decrypt3(blob, root6, nil, nil);
	t.assert(pt != nil && string pt == "key proto=pass service=x !password=y\n", "an SGCM3 file Python made opens");
	# each input changes it
	(ps2, nil, nil) := secstore->pak5keys("secstore5", "alice", "secstore", "m-text", "mu-text", "sigma-text", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 6, 32));
	t.assert(hexs(ps2) != hexs(ps), "another ML-KEM secret, another proof");
	(ps2, nil, nil) = secstore->pak5keys("secstore5", "alice", "secstore", "m-text", "mu-text", "sigma-texT", "Hi-text", ramp(5, 3, 1568), ramp(13, 4, 1568), ramp(17, 5, 32));
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

	run("SGCM3RoundTrip", testSGCM2RoundTrip);
	run("SGCM1Compat", testSGCM1Compat);
	run("SGCM2UserBinding", testSGCM2UserBinding);
	run("VerifierFormats", testVerifierFormats);
	run("Pak5Vectors", testPak5Vectors);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
