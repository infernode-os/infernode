implement X509PathTest;
#
# X.509 certification path validation tests.
#
# The fixtures in /tests/certs/pki are a generated test PKI (see
# tests/certs/pki/README). Its roots are made trust anchors only inside
# this test's private namespace, by binding tests/certs/pki/anchors over
# /lib/certs before x509 first loads its trust store. No test root is ever
# part of the shipped trust store.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "asn1.m";
include "keyring.m";
include "security.m";
include "pkcs.m";
include "x509.m";
	x509: X509;
include "testing.m";
	testing: Testing;
	T: import testing;

X509PathTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/x509_path_test.b";
PKI: con "/tests/certs/pki/";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.failed = 1;
		t.log("unexpected exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	buf := array [int d.length] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return buf[0:n];
}

# chain from file names, leaf first
chain(t: ref T, names: list of string): list of array of byte
{
	l: list of array of byte;
	for(; names != nil; names = tl names) {
		b := readfile(PKI + hd names + ".der");
		if(b == nil)
			t.fatal("cannot read fixture " + hd names);
		l = b :: l;
	}
	r: list of array of byte;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

accept(t: ref T, names: list of string, what: string)
{
	(ok, err) := x509->verify_certchain(chain(t, names));
	if(!ok)
		t.log("error: " + err);
	t.asserteq(ok, 1, what);
}

reject(t: ref T, names: list of string, want, what: string)
{
	(ok, err) := x509->verify_certchain(chain(t, names));
	t.asserteq(ok, 0, what);
	t.log("rejected: " + err);
	if(want != nil)
		t.assert(contains(err, want), what + ": reason should mention '" + want + "'");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# --- paths that must validate ---

testLeafIntermediateRoot(t: ref T)	{ accept(t, "leaf" :: "inter" :: nil, "leaf <- intermediate <- trusted root"); }
testRootPresented(t: ref T)	{ accept(t, "leaf" :: "inter" :: "root" :: nil, "server also sends the root"); }
testDuplicateLeaf(t: ref T)	{ accept(t, "leaf" :: "leaf" :: "inter" :: nil, "duplicate leaf (as sam.gov sends)"); }
testOutOfOrder(t: ref T)	{ accept(t, "leaf" :: "root" :: "inter" :: nil, "intermediates out of order"); }
testExtraUnrelated(t: ref T)	{ accept(t, "leaf" :: "notca" :: "inter" :: nil, "unrelated extra certificate"); }
testRSASha512(t: ref T)	{ accept(t, "rleaf" :: nil, "RSA root signs leaf with SHA-512"); }
testP384SignsSha256(t: ref T)	{ accept(t, "eleaf" :: nil, "P-384 root signs P-256 leaf with SHA-256"); }
testAnchorAlone(t: ref T)	{ accept(t, "root" :: nil, "a trust anchor presented alone"); }

# --- paths that must be rejected ---

testSelfSigned(t: ref T)	{ reject(t, "self" :: nil, "no trusted root", "self-signed leaf not in the store"); }
testMissingIntermediate(t: ref T)	{ reject(t, "leaf" :: nil, "no trusted root", "intermediate not sent"); }
testIssuerNotCA(t: ref T)	{ reject(t, "leaf-notca" :: "notca" :: nil, "not a CA", "issuer has CA:false"); }
testIssuerNoCertSign(t: ref T)	{ reject(t, "leaf-nosign" :: "nosign" :: nil, "keyCertSign", "issuer keyUsage lacks keyCertSign"); }
testPathLen(t: ref T)	{ reject(t, "leaf-pathlen" :: "inter1" :: "inter0" :: nil, "pathLen", "pathLenConstraint 0 exceeded"); }

# A leaf cannot vouch for another certificate: tamper the leaf's
# signature and the path must fail on signature, not pass on names.
testTamperedSignature(t: ref T)
{
	c := chain(t, "leaf" :: "inter" :: nil);
	leaf := array [len hd c] of byte;
	leaf[0:] = hd c;
	leaf[len leaf - 5] ^= byte 16r01;
	(ok, err) := x509->verify_certchain(leaf :: tl c);
	t.asserteq(ok, 0, "tampered leaf signature");
	t.log("rejected: " + err);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	# Private namespace: the test PKI's roots become the trust store.
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind(PKI + "anchors", "/lib/certs", Sys->MREPL) < 0) {
		sys->fprint(sys->fildes(2), "x509_path_test: bind anchors: %r\n");
		raise "fail:setup";
	}
	x509 = load X509 X509->PATH;
	if(x509 == nil || x509->init() != nil) {
		sys->fprint(sys->fildes(2), "x509_path_test: load x509: %r\n");
		raise "fail:setup";
	}

	run("LeafIntermediateRoot", testLeafIntermediateRoot);
	run("RootPresented", testRootPresented);
	run("DuplicateLeaf", testDuplicateLeaf);
	run("OutOfOrder", testOutOfOrder);
	run("ExtraUnrelated", testExtraUnrelated);
	run("RSASha512", testRSASha512);
	run("P384SignsSha256", testP384SignsSha256);
	run("AnchorAlone", testAnchorAlone);
	run("SelfSigned", testSelfSigned);
	run("MissingIntermediate", testMissingIntermediate);
	run("IssuerNotCA", testIssuerNotCA);
	run("IssuerNoCertSign", testIssuerNoCertSign);
	run("PathLen", testPathLen);
	run("TamperedSignature", testTamperedSignature);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
