implement X509TotalTest;

#
# The decoders under every certificate are total: bytes in, a value or
# an error out, and never an exception (appl/lib/asn1.b, the DER reader
# and the certificate, CRL and extension decoders of
# appl/lib/crypt/x509.b, appl/lib/crypt/pkcs.b's RSA key).
#
# A certificate is a peer's bytes, decoded before anything says who the
# peer is, by a TLS client whose callers have no exception handler.  A
# length of 16r7fffffff made i+length negative in asn1's decoder and in
# x509's own, and the value was then allocated or sliced at that size
# ("out of memory: heap", "array bounds error"); a TBSCertificate of
# fewer than six fields, an extension with no value, were "dereference
# of nil"; an RSA key with a modulus of 0 was taken, and dividing by it
# was "mpdiv: divide by zero" in the middle of a handshake.
#
# And what they decode is what was encoded.  A BOOLEAN's value was read
# from the first byte of the whole buffer, which in a certificate is
# 16r30: every BOOLEAN was TRUE, so cA FALSE written out made a CA and
# critical FALSE a critical extension.  The one valid empty BIT STRING
# was refused, by the same wrong byte.  An object identifier under arc
# 2 whose second arc is 40 or more came out as another (2.999 as
# 26.39).  The KeyUsage_ constants were 0, 2, 4, 6..., and the key
# usage they were to be tested against was the extension's own DER read
# as a number.
#
# The certificates of /tests/certs/total (made by
# tests/host/x509_chain/gen.py -f, with one of everything the decoders
# read) verify as they are; then some thousands of copies of them, each
# changed, cut or lengthened somewhere, are decoded and verified in
# every place a certificate can be given (leaf, intermediate, root, CRL):
# each is an answer.  The decoders' public entry points have a handler
# of their own now, which says "internal error" when it is used; the
# test fails on that too, so that it is the code under the handler that
# is held to being total.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "asn1.m";
	asn1: ASN1;
	Elem, Oid, Tag, Value: import asn1;
include "keyring.m";
	keyring: Keyring;
	IPint: import keyring;
include "security.m";
include "pkcs.m";
	pkcs: PKCS;
include "x509.m";
	x509: X509;
	Signed, Certificate, CRL, ExtClass, Extension, SubjectPKInfo, PublicKey: import x509;
include "testing.m";
	testing: Testing;
	T: import testing;

X509TotalTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/x509_total_test.b";
FIX: con "/tests/certs/total/";
NOW: con 1800000000;	# 2027-01-15: inside the fixtures' dates, whatever the clock says
MUTANTS: con 3000;

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
		t.log("exception: " + e);
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
	buf := array[65536] of byte;
	tot := 0;
	while(tot < len buf && (n := sys->read(fd, buf[tot:], len buf - tot)) > 0)
		tot += n;
	if(tot == 0)
		return nil;
	return buf[0:tot];
}

fixture(t: ref T, name: string): array of byte
{
	b := readfile(FIX + name + ".der");
	if(b == nil)
		t.fatal("cannot read " + FIX + name + ".der");
	return b;
}

hex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte (hexval(s[2*i]) << 4 | hexval(s[2*i+1]));
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# tag, DER length, body
tlv(tag: int, body: array of byte): array of byte
{
	n := len body;
	h: array of byte;
	if(n < 16r80)
		h = array[] of {byte tag, byte n};
	else if(n < 16r100)
		h = array[] of {byte tag, byte 16r81, byte n};
	else
		h = array[] of {byte tag, byte 16r82, byte (n >> 8), byte n};
	return cat(h, body);
}

# the text of what an element decoded to, as far as these tests look
show(e: ref Elem): string
{
	if(e == nil)
		return "nil";
	pick v := e.val {
	Bool =>
		return sys->sprint("BOOLEAN %d", v.v);
	Int =>
		return sys->sprint("INTEGER %d", v.v);
	BitString =>
		return sys->sprint("BITS %d/%d", len v.bits, v.unusedbits);
	ObjId =>
		return "OID " + v.id.tostring();
	Seq =>
		s := "SEQ {";
		for(l := v.l; l != nil; l = tl l)
			s += " " + show(hd l);
		return s + " }";
	Octets =>
		return sys->sprint("OCTETS %d", len v.bytes);
	}
	return "other";
}

# asn1->decode of hex: what it decoded to, or "error"; an exception is the test's
dec(h: string): string
{
	(err, e) := asn1->decode(hex(h));
	if(err != "")
		return "error";
	return show(e);
}

testAsn1Values(t: ref T)
{
	# a BOOLEAN is its own byte
	t.assertseq(dec("3003010100"), "SEQ { BOOLEAN 0 }", "cA FALSE written out");
	t.assertseq(dec("30060101000101ff"), "SEQ { BOOLEAN 0 BOOLEAN 255 }", "FALSE then TRUE");
	t.assertseq(dec("0101ff"), "BOOLEAN 255", "TRUE");
	t.assertseq(dec("010100"), "BOOLEAN 0", "FALSE alone");
	t.assertseq(dec("01020000"), "error", "a BOOLEAN of two bytes");
	# the empty BIT STRING
	t.assertseq(dec("030100"), "BITS 0/0", "the empty BIT STRING");
	t.assertseq(dec("3003030100"), "SEQ { BITS 0/0 }", "the empty BIT STRING in a SEQUENCE");
	t.assertseq(dec("030107"), "error", "an empty BIT STRING with unused bits");
	t.assertseq(dec("03020106"), "BITS 1/1", "keyCertSign and cRLSign");
	# object identifiers: the first two arcs
	t.assertseq(dec("0603551d13"), "OID 2.5.29.19", "2.5.29.19");
	t.assertseq(dec("06012a"), "OID 1.2", "1.2");
	t.assertseq(dec("060127"), "OID 0.39", "0.39");
	t.assertseq(dec("06014f"), "OID 1.39", "1.39");
	t.assertseq(dec("060150"), "OID 2.0", "2.0");
	t.assertseq(dec("060178"), "OID 2.40", "2.40 (it was 3.0)");
	t.assertseq(dec("06028837"), "OID 2.999", "2.999 (it was 26.39)");
	(eerr, enc) := asn1->encode(ref Elem(Tag(ASN1->Universal, ASN1->OBJECT_ID, 0),
		ref Value.ObjId(ref Oid(array[] of {2, 999, 3}))));
	t.assertseq(eerr, "", "encode 2.999.3");
	t.assert(len enc == 5 && enc[2] == byte 16r88 && enc[3] == byte 16r37 && enc[4] == byte 3, "2.999.3 encodes as 06 03 88 37 03");
	# an INTEGER has a byte
	t.assertseq(dec("0200"), "error", "an INTEGER of no bytes");
	t.assertseq(dec("020105"), "INTEGER 5", "5");
	t.assertseq(dec("0201ff"), "INTEGER -1", "-1");
	# what is left over is said
	(xerr, nil) := asn1->decode(hex("0500ff"));
	t.assert(xerr != "", "a byte after the value is an error");
	t.assert(contains(xerr, "extra data"), "and the error says so: " + xerr);
	# the contents of a SEQUENCE under an implicit tag
	(serr, sl) := asn1->decode_seq(hex("020105020106"));
	t.assertseq(serr, "", "decode_seq of two INTEGERs (it could not succeed)");
	t.asserteq(len sl, 2, "decode_seq gives both");
	(serr, sl) = asn1->decode_seq(hex("02010502"));
	t.assert(serr != "", "decode_seq of one and a half is an error");
}

testAsn1Lengths(t: ref T)
{
	# a length of 16r7fffffff under each kind of value
	l := "04847fffffff" :: "02847fffffff" :: "03847fffffff" :: "30847fffffff" :: "06847fffffff" ::
		"0c847fffffff" :: "31847fffffff" :: "a0847fffffff" :: "05847fffffff" :: "01847fffffff" ::
		"09847fffffff" :: "08847fffffff" :: "1e847fffffff" :: "3006" + "04847fffffff" ::
		"04847ffffffe00" :: "0484ffffffff" :: "048500000000ff" :: "0483ffffff" :: "0481ff" ::
		# indefinite lengths: not DER, and read before as a length of 0
		"30800000" :: "30800201050000" :: "0480" :: "24800000" ::
		# cut short
		"30" :: "3003" :: "300302" :: "30030201" :: "0282" :: "028201" :: "1f" :: "1f81" :: "" :: nil;
	for(; l != nil; l = tl l) {
		got := "";
		{
			got = dec(hd l);
		} exception e {
		"*" =>
			got = "EXCEPTION " + e;
		}
		t.assertseq(got, "error", "asn1->decode of " + hd l);
	}
	# and through decode_value and decode_seq
	{
		(verr, nil) := asn1->decode_value(hex("847fffffff"), ASN1->OCTET_STRING, 0);
		t.assert(1, "decode_value answers: " + verr);
		(serr, nil) := asn1->decode_seq(hex("04847fffffff"));
		t.assert(serr != "", "decode_seq of a length past the end is an error");
	} exception e {
	"*" =>
		t.error("decode_value or decode_seq raised " + e);
	}
}

ECDSA256: con "300a06082a8648ce3d040302";

# a Certificate made of a TBSCertificate's bytes, an algorithm and a signature of nothing
signedof(tbs: array of byte): array of byte
{
	return tlv(16r30, cat(cat(tbs, hex(ECDSA256)), hex("03030030" + "00")));
}

# one malformed certificate through every way in: nil if each answered
# with an error, else what happened
refused(m: array of byte, root, inter: array of byte): string
{
	{
		(serr, s) := Signed.decode(m);
		if(internal(serr))
			return serr;
		if(s != nil) {
			(cerr, c) := Certificate.decode(s.tobe_signed);
			if(internal(cerr))
				return cerr;
			if(c != nil && cerr == "")
				return "decoded as a certificate";
		}
		(ok, err) := x509->verify_certchain_roots(m :: inter :: nil, root :: nil, nil, NOW);
		if(ok)
			return "verified";
		if(internal(err))
			return err;
		(ok, err) = x509->verify_certchain_roots(m :: nil, m :: nil, m :: nil, NOW);
		if(ok)
			return "verified as its own root";
		if(internal(err))
			return err;
	} exception e {
	"*" =>
		return "exception: " + e;
	}
	return nil;
}

testMalformedCertificates(t: ref T)
{
	root := fixture(t, "root");
	inter := fixture(t, "inter");
	leaf := fixture(t, "leaf");
	(nil, s) := Signed.decode(leaf);
	if(s == nil)
		t.fatal("the leaf fixture does not decode");
	# the fields of the leaf's TBSCertificate, to build short ones from
	(nil, e) := asn1->decode(s.tobe_signed);
	(nil, el) := e.is_seq();
	t.asserteq(len el, 8, "the leaf has version, six fields and extensions");
	f := array[8] of array of byte;
	i := 0;
	for(; el != nil; el = tl el) {
		(nil, f[i]) = asn1->encode(hd el);
		i++;
	}
	body := array[0] of byte;
	cases: list of (string, array of byte);
	cases = ("a TBSCertificate of no fields", signedof(tlv(16r30, body))) :: cases;
	cases = ("the version alone", signedof(tlv(16r30, hex("a003020102")))) :: cases;
	cases = ("one field", signedof(tlv(16r30, hex("020105")))) :: cases;
	five := cat(cat(cat(cat(hex("020105"), hex(ECDSA256)), hex("3000")), hex("3000")), hex("3000"));
	cases = ("five fields and no version", signedof(tlv(16r30, five))) :: cases;
	withext := hex("a003020102020105" + ECDSA256 + "3000" + "301e170d3236303130313030303030305a170d3439313230333030303030305a" + "3000");
	spki := hex("3013" + "300906072a8648ce3d0201" + "0306000401020304");
	exts: list of (string, string);
	exts = ("an extension of no fields", "3000") ::
		("an extension that is its OID alone", "30050603551d11") ::
		("an extension with no value", "30080603551d110101ff") ::
		("an extension whose value's length is 16r7fffffff", "300b0603551d1104847fffffff") ::
		("an extension with four fields", "300c0603551d110101ff04003000") :: nil;
	for(; exts != nil; exts = tl exts) {
		(what, eh) := hd exts;
		x := tlv(16ra3, tlv(16r30, hex(eh)));
		cases = (what, signedof(tlv(16r30, cat(cat(withext, spki), x)))) :: cases;
	}
	cases = ("an INTEGER whose length is 16r7fffffff", signedof(tlv(16r30, hex("a003020102" + "02847fffffff")))) :: cases;
	cases = ("a key whose BIT STRING's length is 16r7fffffff",
		signedof(tlv(16r30, cat(withext, hex("3011" + "300906072a8648ce3d0201" + "03847fffffff"))))) :: cases;
	cases = ("a name whose string's length is 16r7fffffff",
		signedof(tlv(16r30, hex("a003020102020105" + ECDSA256 + "300f310d300b06035504030c847fffffff")))) :: cases;
	# x509's own DER reader, which takes a certificate apart before asn1 sees it
	cases = ("a TBSCertificate whose length is 16r7fffffff", hex("300a30847fffffff00000000")) :: cases;
	cases = ("an algorithm whose length is 16r7fffffff", tlv(16r30, cat(f[1], hex("30847fffffff")))) :: cases;
	cases = ("a signature whose length is 16r7fffffff", tlv(16r30, cat(cat(f[1], hex(ECDSA256)), hex("03847fffffff")))) :: cases;
	cases = ("a length that does not fit an int", hex("3085010000000000")) :: cases;
	cases = ("an indefinite length", hex("3080300030000300" + "0000")) :: cases;
	cases = ("nothing", array[0] of byte) :: cases;
	cases = ("one byte", hex("30")) :: cases;
	for(; cases != nil; cases = tl cases) {
		(what, m) := hd cases;
		r := refused(m, root, inter);
		t.assert(r == nil, what + ": " + r);
	}
	# a v1 certificate that writes its version out is read (the version was taken for the serial number)
	v1 := cat(hex("a003020100"), cat(cat(cat(cat(cat(f[1], f[2]), f[3]), f[4]), f[5]), f[6]));
	(v1err, v1c) := Certificate.decode(tlv(16r30, v1));
	t.assertseq(v1err, "", "a v1 certificate with its version written out");
	t.assert(v1c != nil && v1c.version == 0, "is version 1");
}

internal(s: string): int
{
	return contains(s, "internal error");
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
rsakey(modulus, exponent: array of byte): array of byte
{
	return tlv(16r30, cat(tlv(2, modulus), tlv(2, exponent)));
}

testRsaKeys(t: ref T)
{
	(nil, s) := Signed.decode(fixture(t, "rsaroot"));
	(nil, c) := Certificate.decode(s.tobe_signed);
	(kerr, nil, pk) := c.subject_pkinfo.getPublicKey();
	t.assertseq(kerr, "", "a 2048-bit key with exponent 65537 is taken");
	n: array of byte;
	pick k := pk {
	RSA =>
		t.asserteq(k.pk.modulus.bits(), 2048, "its modulus is 2048 bits");
		n = k.pk.modulus.iptobebytes();
	* =>
		t.fatal("the RSA fixture's key is not RSA");
	}
	n = cat(array[] of {byte 0}, n);	# a positive INTEGER
	e65537 := hex("010001");
	(gerr, good) := pkcs->decode_rsapubkey(rsakey(n, e65537));
	t.assertseq(gerr, "", "the same key rebuilt");
	t.assert(good != nil && good.modlen == 256, "is 256 bytes");
	(e3err, nil) := pkcs->decode_rsapubkey(rsakey(n, hex("03")));
	t.assertseq(e3err, "", "an exponent of 3 is one");

	even := array[len n] of byte;
	even[0:] = n;
	even[len even - 1] &= byte 16rfe;
	short := array[len n] of byte;
	short[0:] = n;
	short[1] &= byte 16r7f;
	bad: list of (string, array of byte);
	bad = ("a modulus of 0", rsakey(hex("00"), hex("03"))) ::
		("a modulus of 1", rsakey(hex("01"), e65537)) ::
		("a modulus of 15, exponent 1", rsakey(hex("0f"), hex("01"))) ::
		("a modulus of 16", rsakey(hex("10"), e65537)) ::
		("a modulus of 2047 bits", rsakey(short, e65537)) ::
		("a negative modulus", rsakey(n[1:], e65537)) ::
		("a modulus of -1", rsakey(hex("ff"), e65537)) ::
		("an even modulus", rsakey(even, e65537)) ::
		("an exponent of 0", rsakey(n, hex("00"))) ::
		("an exponent of 1", rsakey(n, hex("01"))) ::
		("an exponent of 2", rsakey(n, hex("02"))) ::
		("an exponent of 65536", rsakey(n, hex("010000"))) ::
		("a negative exponent", rsakey(n, hex("ff"))) ::
		("an exponent that is the modulus", rsakey(n, n)) ::
		("a modulus of 8193 bits", rsakey(cat(hex("0101"), array[1024] of {* => byte 16rff}), e65537)) ::
		("an INTEGER of no bytes", hex("3005" + "0200" + "0203010001")) ::
		("three INTEGERs", tlv(16r30, cat(cat(tlv(2, n), tlv(2, e65537)), hex("020101")))) ::
		("bytes after the key", cat(rsakey(n, e65537), hex("00"))) ::
		("no key", array[0] of byte) :: nil;
	for(; bad != nil; bad = tl bad) {
		(what, der) := hd bad;
		{
			(err, k) := pkcs->decode_rsapubkey(der);
			t.assert(err != "" && k == nil, what + " is refused");
		} exception x {
		"*" =>
			t.error(what + ": exception " + x);
		}
	}
}

testPkcs(t: ref T)
{
	{
		# the fixture's public key will do for a key: nothing is signed
		(nil, s) := Signed.decode(fixture(t, "rsaroot"));
		(nil, c) := Certificate.decode(s.tobe_signed);
		(nil, nil, pk) := c.subject_pkinfo.getPublicKey();
		key: ref PKCS->RSAKey;
		pick k := pk {
		RSA =>
			key = k.pk;
		}
		(serr, sig) := pkcs->rsa_sign(array of byte "message", key, 999);
		t.assert(serr != "" && sig == nil, "rsa_sign with a digest it does not know is an error (it signed the empty message)");
		(serr, sig) = pkcs->rsa_sign(array of byte "message", key, PKCS->MD2_WithRSAEncryption);
		t.assert(serr != "" && sig == nil, "rsa_sign with MD2, which is not there, is an error (it signed a block with no digest in it)");
		t.asserteq(pkcs->dss_verify(nil, nil, nil), 0, "dss_verify of nothing verifies nothing (it was 1)");
		t.asserteq(pkcs->dss_verify(array[0] of byte, array[40] of byte, nil), 0, "dss_verify of an empty message");
		(derr, d) := pkcs->rsa_decrypt(array[4] of byte, nil, 0);
		t.assert(derr != "" && d == nil, "rsa_decrypt with no key is an error");
	} exception e {
	"*" =>
		t.error("exception " + e);
	}
	# SLH-DSA-SHAKE-192s and -256s, the sets Keyring implements (NIST's registry, RFC 9909)
	t.assertseq((ref pkcs->objIdTab[PKCS->id_slhdsa192s]).tostring(), "2.16.840.1.101.3.4.3.28", "id-slh-dsa-shake-192s");
	t.assertseq((ref pkcs->objIdTab[PKCS->id_slhdsa256s]).tostring(), "2.16.840.1.101.3.4.3.30", "id-slh-dsa-shake-256s");
}

# Signed.verify, for a signature algorithm the path does not take (MD5
# with RSA), went on to a verifier that accepted any block decrypting
# to 00 02, something, 00 and the digest.  With a public exponent of 3
# such a block is a cube root away: this one was made with no private
# key (the verifier's own vector, a 1024-bit key).  It verified.
FORGEN: con "dd589d73e9db56791ff6e0e4d70cecdf05e1b004802e9de81ade3960439ea5c738ba769550ebf29a5f89e38ad797206ba8914a0472ccbdc81e8873731e9d925e50ffb08b442b1af69f1ecaa72c4932b5b782c9302be8f78e3532e70083d25a9530060401affabe5175d28875a8a797008be4ab40b5e95fff2eb3da7a03770689";
FORGED: con "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001436d2ac0e08ab907f41d5120970fb9ec7304664e68c26c816138169b38cebc9e87019cfa8357b7d405e7";

testForgedSignature(t: ref T)
{
	key := ref PKCS->RSAKey(IPint.bebytestoip(hex(FORGEN)), 128, IPint.inttoip(3));
	md5rsa := ref X509->AlgIdentifier(ref Oid(array[] of {1, 2, 840, 113549, 1, 1, 4}), nil);
	s := ref Signed(array of byte "forged message 1", md5rsa, cat(array[] of {byte 0}, hex(FORGED)));
	ok := -1;
	{
		ok = s.verify(ref PublicKey.RSA(key), PKCS->MD5_WithRSAEncryption);
	} exception e {
	"*" =>
		t.error("exception " + e);
	}
	t.asserteq(ok, 0, "a signature forged without the key, under md5WithRSAEncryption, does not verify");
	md2rsa := ref X509->AlgIdentifier(ref Oid(array[] of {1, 2, 840, 113549, 1, 1, 2}), nil);
	s.alg = md2rsa;
	t.asserteq(s.verify(ref PublicKey.RSA(key), PKCS->MD2_WithRSAEncryption), 0, "nor under md2WithRSAEncryption");
}

extof(oid: array of int, value: string): ref Extension
{
	return ref Extension(ref Oid(oid), 0, hex(value));
}

testExtensions(t: ref T)
{
	# the constants are bits, digitalSignature the lowest
	t.asserteq(X509->KeyUsage_DigitalSignature, 1, "KeyUsage_DigitalSignature");
	t.asserteq(X509->KeyUsage_NonRepudiation, 2, "KeyUsage_NonRepudiation");
	t.asserteq(X509->KeyUsage_KeyCertSign, 32, "KeyUsage_KeyCertSign");
	t.asserteq(X509->KeyUsage_CRLSign, 64, "KeyUsage_CRLSign");
	t.asserteq(X509->KeyUsage_DecipherOnly, 256, "KeyUsage_DecipherOnly");
	t.asserteq(X509->Reason_Unspecified, 0, "Reason_Unspecified");
	t.asserteq(X509->Reason_KeyCompromise, 1, "Reason_KeyCompromise");
	t.asserteq(X509->Reason_CertificateHold, 6, "Reason_CertificateHold");
	t.asserteq(X509->Reason_RemoveFromCRL, 8, "Reason_RemoveFromCRL");

	KU := array[] of {2, 5, 29, 15};
	usage := -1;
	(err, ec) := ExtClass.decode(extof(KU, "03020106"));
	t.assertseq(err, "", "keyUsage: keyCertSign and cRLSign");
	if(ec != nil)
		pick k := ec {
		KeyUsage =>
			usage = k.usage;
		}
	t.asserteq(usage, X509->KeyUsage_KeyCertSign | X509->KeyUsage_CRLSign, "are those two bits and no others");
	(err, ec) = ExtClass.decode(extof(KU, "0303070080"));
	usage = -1;
	if(ec != nil)
		pick k := ec {
		KeyUsage =>
			usage = k.usage;
		}
	t.asserteq(usage, X509->KeyUsage_DecipherOnly, "decipherOnly, the ninth bit");
	(err, nil) = ExtClass.decode(extof(KU, "030100"));
	t.assert(err != "", "a keyUsage with no bit set is refused (RFC 5280 4.2.1.3)");

	BC := array[] of {2, 5, 29, 19};
	(err, ec) = ExtClass.decode(extof(BC, "3003010100"));
	t.assertseq(err, "", "basicConstraints with cA FALSE written out");
	(err, nil) = ExtClass.decode(extof(BC, "3003010101"));
	t.assert(err != "", "basicConstraints with TRUE written 01 is not DER");

	AKI := array[] of {2, 5, 29, 35};
	(err, ec) = ExtClass.decode(extof(AKI, "300680040102abcd"));
	t.assertseq(err, "", "an authorityKeyIdentifier that is the key identifier alone (it was a syntax error)");
	idlen := -1;
	if(ec != nil)
		pick a := ec {
		AuthorityKeyIdentifier =>
			idlen = len a.id;
		}
	t.asserteq(idlen, 4, "and its four bytes");
	(err, nil) = ExtClass.decode(extof(AKI, "3000"));
	t.assertseq(err, "", "an empty authorityKeyIdentifier (it was dereference of nil)");

	RC := array[] of {2, 5, 29, 21};
	code := -1;
	(err, ec) = ExtClass.decode(extof(RC, "0a0101"));
	if(ec != nil)
		pick r := ec {
		ReasonCode =>
			code = r.code;
		}
	t.asserteq(code, X509->Reason_KeyCompromise, "reasonCode keyCompromise");

	# an otherName beside a dNSName: the subjectAltName is read (it was a syntax error)
	SAN := array[] of {2, 5, 29, 17};
	(err, ec) = ExtClass.decode(extof(SAN, "3023" + "a01706" + "0a2b060104018237140203" + "a009" + "0c07" + "7540612e657861" + "8208" + "612e6578616d706c"));
	t.assertseq(err, "", "a subjectAltName with an otherName and a dNSName");
	dns := "";
	if(ec != nil)
		pick a := ec {
		SubjectAltName =>
			for(l := a.alias; l != nil; l = tl l)
				pick g := hd l {
				dNSName =>
					dns = g.str;
				}
		}
	t.assertseq(dns, "a.exampl", "and its dNSName");
}

chainof(a, b: array of byte): list of array of byte
{
	if(b == nil)
		return a :: nil;
	return a :: b :: nil;
}

testFixturesVerify(t: ref T)
{
	root := fixture(t, "root");
	inter := fixture(t, "inter");
	leaf := fixture(t, "leaf");
	crl := fixture(t, "crl");
	(ok, err) := x509->verify_certchain_roots(leaf :: inter :: nil, root :: nil, crl :: nil, NOW);
	t.assert(ok, "the chain with one of everything verifies: " + err);
	(ok, err) = x509->verify_certchain_roots(leaf :: nil, root :: nil, nil, NOW);
	t.assert(!ok, "but not without its intermediate");
	(ok, err) = x509->verify_certchain_roots(leaf :: inter :: nil, root :: nil, nil, 0);
	t.assert(!ok, "nor with no clock");
	(ok, err) = x509->verify_certchain_roots(fixture(t, "rsaleaf") :: nil, fixture(t, "rsaroot") :: nil, nil, NOW);
	t.assert(ok, "the RSA chain verifies: " + err);

	# each decodes, and every extension of the three gets an answer
	# from ExtClass.decode (the path does not read them through it,
	# and some of its decoders refuse what is well formed: an answer
	# is all that is asked here)
	names := "root" :: "inter" :: "leaf" :: nil;
	for(; names != nil; names = tl names) {
		(nil, s) := Signed.decode(fixture(t, hd names));
		(cerr, c) := Certificate.decode(s.tobe_signed);
		t.assertseq(cerr, "", hd names + " decodes");
		for(l := c.exts; l != nil; l = tl l) {
			(xerr, nil) := ExtClass.decode(hd l);
			t.assert(!internal(xerr), hd names + ": extension " + (hd l).oid.tostring() + ": " + xerr);
		}
	}
	(nil, cs) := Signed.decode(crl);
	(lerr, l) := CRL.decode(cs.tobe_signed);
	t.assertseq(lerr, "", "the CRL decodes");
	t.assert(l != nil && len l.revoked_certs == 2, "and lists two certificates");
	t.assert(l != nil && l.is_revoked(IPint.inttoip(5001)) && !l.is_revoked(IPint.inttoip(77001)), "5001, and not the leaf");
}

# Every root of the shipped store is still one: its key is taken (the
# RSA ones are 2048 bits or more, with an odd exponent above 1), its
# extensions are ones the path processes, and it stands as its own
# anchor on the day the store was made.
STOREDAY: con 1786590721;	# lib/certs/SOURCE: 13 Aug 2026

testPublicRoots(t: ref T)
{
	dir := "/lib/certs";
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		t.skip("no " + dir);
	n := 0;
	rsa := 0;
	for(;;) {
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++) {
			name := d[i].name;
			if(len name < 4 || name[len name - 4:] != ".der")
				continue;
			der := readfile(dir + "/" + name);
			(serr, s) := Signed.decode(der);
			if(serr != "") {
				t.error(name + ": " + serr);
				continue;
			}
			(cerr, c) := Certificate.decode(s.tobe_signed);
			if(cerr != "") {
				t.error(name + ": " + cerr);
				continue;
			}
			(kerr, nil, pk) := c.subject_pkinfo.getPublicKey();
			t.assertseq(kerr, "", name + ": its key");
			if(pk != nil)
				pick k := pk {
				RSA =>
					rsa++;
				}
			(ok, err) := x509->verify_certchain_roots(der :: nil, der :: nil, nil, STOREDAY);
			t.assert(ok, name + " as its own anchor: " + err);
			n++;
		}
	}
	t.assert(n > 100, sys->sprint("%d roots read", n));
	t.log(sys->sprint("%d roots, %d of them RSA", n, rsa));
}

# A change made somewhere in a copy of a: what a peer that can send
# anything sends.  The generator is the test's own, so that a failure
# can be had again from its number.
seed := 0;

rnd(n: int): int
{
	seed = seed * 1103515245 + 12345;
	return ((seed >> 16) & 16r7fff) % n;
}

interesting := array[] of {
	byte 0, byte 1, byte 16r7f, byte 16r80, byte 16r81, byte 16r82, byte 16r84, byte 16rff,
	byte 16r30, byte 16r31, byte 16ra0, byte 16ra3, byte 2, byte 3, byte 4, byte 5, byte 6,
};
huge := array[] of {byte 16r84, byte 16r7f, byte 16rff, byte 16rff, byte 16rff};

mutate(a: array of byte): array of byte
{
	n := len a;
	case rnd(8) {
	0 or 1 =>
		# a bit
		m := array[n] of byte;
		m[0:] = a;
		m[rnd(n)] ^= byte (1 << rnd(8));
		return m;
	2 or 3 =>
		# a byte that means something to a decoder
		m := array[n] of byte;
		m[0:] = a;
		m[rnd(n)] = interesting[rnd(len interesting)];
		return m;
	4 =>
		# cut short
		return a[0:rnd(n)];
	5 =>
		# a few bytes gone
		i := rnd(n);
		k := 1 + rnd(8);
		if(i + k > n)
			k = n - i;
		return cat(a[0:i], a[i+k:]);
	6 =>
		# a length of 16r7fffffff where a length was, or anywhere
		i := 1 + rnd(n - 1);
		return cat(cat(a[0:i], huge), a[i+1:]);
	* =>
		# a piece of it again somewhere else
		i := rnd(n);
		j := rnd(n);
		k := 1 + rnd(24);
		if(j + k > n)
			k = n - j;
		return cat(cat(a[0:i], a[j:j+k]), a[i:]);
	}
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# the same bytes signed, and the same signature
samesigned(a, b: array of byte): int
{
	(nil, sa) := Signed.decode(a);
	(nil, sb) := Signed.decode(b);
	return sa != nil && sb != nil && same(sa.tobe_signed, sb.tobe_signed) && same(sa.signature, sb.signature);
}

# everything a decoder can be asked of m: nil, or what went wrong
decodes(m: array of byte): string
{
	{
		asn1->decode(m);
		asn1->decode_seq(m);
		pkcs->decode_rsapubkey(m);
		(serr, s) := Signed.decode(m);
		if(internal(serr))
			return serr;
		tbs := m;
		if(s != nil)
			tbs = s.tobe_signed;
		(cerr, c) := Certificate.decode(tbs);
		if(internal(cerr))
			return cerr;
		if(c != nil) {
			c.subject_pkinfo.getPublicKey();
			for(l := c.exts; l != nil; l = tl l) {
				(xerr, nil) := ExtClass.decode(hd l);
				if(internal(xerr))
					return xerr;
			}
			x509->parse_exts(c.exts);
		}
		(lerr, crl) := CRL.decode(tbs);
		if(internal(lerr))
			return lerr;
		if(crl != nil)
			crl.is_revoked(IPint.inttoip(5001));
	} exception e {
	"*" =>
		return "exception: " + e;
	}
	return nil;
}

testMutations(t: ref T)
{
	root := fixture(t, "root");
	inter := fixture(t, "inter");
	leaf := fixture(t, "leaf");
	crl := fixture(t, "crl");
	rsaroot := fixture(t, "rsaroot");
	rsaleaf := fixture(t, "rsaleaf");
	seeds := array[] of {leaf, inter, root, crl, rsaleaf, rsaroot};
	bad := 0;
	verified := 0;
	refusals := 0;
	for(i := 0; i < MUTANTS && bad < 5; i++) {
		seed = i * 7919 + 1;
		which := i % len seeds;
		orig := seeds[which];
		m := mutate(orig);
		if(same(m, orig))
			continue;
		r := decodes(m);
		ok := 0;
		err := "";
		{
			# in the place its original has in a chain
			case which {
			0 =>	(ok, err) = x509->verify_certchain_roots(m :: inter :: nil, root :: nil, crl :: nil, NOW);
			1 =>	(ok, err) = x509->verify_certchain_roots(leaf :: m :: nil, root :: nil, crl :: nil, NOW);
			2 =>	(ok, err) = x509->verify_certchain_roots(leaf :: inter :: nil, m :: nil, nil, NOW);
			3 =>	(ok, err) = x509->verify_certchain_roots(leaf :: inter :: nil, root :: nil, m :: nil, NOW);
			4 =>	(ok, err) = x509->verify_certchain_roots(m :: nil, rsaroot :: nil, nil, NOW);
			5 =>	(ok, err) = x509->verify_certchain_roots(rsaleaf :: nil, m :: nil, nil, NOW);
			}
			if(internal(err))
				r = err;
		} exception e {
		"*" =>
			r = "exception: " + e;
		}
		if(r != nil) {
			bad++;
			t.error(sys->sprint("mutant %d (of fixture %d, %d bytes): %s", i, which, len m, r));
		}
		if(ok)
			verified++;
		else
			refusals++;
		# A changed leaf or intermediate is another certificate or
		# none, and a changed CRL one no root signed: the chain does
		# not verify.  (A root is trusted as it is given, changed or
		# not; and a certificate whose signed bytes and signature are
		# the original's is the original: the algorithm written
		# between them is not signed.)
		if(ok && which != 2 && which != 5 && !samesigned(m, orig)) {
			bad++;
			t.error(sys->sprint("mutant %d (of fixture %d) verified", i, which));
		}
	}
	t.asserteq(bad, 0, "no mutant raised, or verified where it could not");
	t.log(sys->sprint("%d mutants: %d refused, %d taken (a root, changed where it does not matter to the chain)", MUTANTS, refusals, verified));
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	keyring = load Keyring Keyring->PATH;
	asn1 = load ASN1 ASN1->PATH;
	pkcs = load PKCS PKCS->PATH;
	x509 = load X509 X509->PATH;
	if(keyring == nil || asn1 == nil || pkcs == nil || x509 == nil) {
		sys->fprint(sys->fildes(2), "cannot load asn1, pkcs or x509: %r\n");
		raise "fail:cannot load";
	}
	asn1->init();
	if((e := pkcs->init()) != nil || (e = x509->init()) != nil) {
		sys->fprint(sys->fildes(2), "init: %s\n", e);
		raise "fail:init";
	}

	run("Asn1Values", testAsn1Values);
	run("Asn1Lengths", testAsn1Lengths);
	run("MalformedCertificates", testMalformedCertificates);
	run("RsaKeys", testRsaKeys);
	run("Pkcs", testPkcs);
	run("ForgedSignature", testForgedSignature);
	run("Extensions", testExtensions);
	run("FixturesVerify", testFixturesVerify);
	run("PublicRoots", testPublicRoots);
	run("Mutations", testMutations);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
