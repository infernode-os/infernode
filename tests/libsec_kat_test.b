implement LibsecKatTest;

#
# Keyring's AES-256-GCM, AES-256-CBC and SHA-256 (libsec underneath)
# against answers worked out elsewhere: OpenSSL's for GCM
# (tests/host/gcm/vectors.txt, 438 cases: 128-, 192- and 256-bit keys,
# IVs of 12 bytes and others, every length across the blocks), NIST SP
# 800-38A F.2.5 for CBC, FIPS 180-4's examples (a million "a"s among
# them) for SHA-256.  Wherever it runs -- the emulator, a native kernel
# on a core with the ARMv8 instructions or without -- the answers are
# the same, so a path through AESE, PMULL or SHA256H that gives anything
# else fails here, as one checked only against itself would not.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

LibsecKatTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/libsec_kat_test.b";
VECTORS: con "/tests/host/gcm/vectors.txt";

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
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

unhex(s: string): array of byte
{
	if(s == "-")
		return array[0] of byte;
	b := array[len s/2] of byte;
	for(i := 0; i < len b; i++){
		v := 0;
		for(k := 0; k < 2; k++){
			c := s[2*i+k];
			if(c >= 'a')
				v = v*16 + c - 'a' + 10;
			else
				v = v*16 + c - '0';
		}
		b[i] = byte v;
	}
	return b;
}

hex(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s += sys->sprint("%.2ux", int b[i]);
	return s;
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

testGCM(t: ref T)
{
	f := bufio->open(VECTORS, Bufio->OREAD);
	if(f == nil)
		t.skip(sys->sprint("no %s: %r", VECTORS));
	n := bad := 0;
	while((line := f.gets('\n')) != nil){
		(nf, fl) := sys->tokenize(line, " \t\n");
		if(nf != 7 || hd fl != "gcm")
			continue;
		fl = tl fl;
		key := unhex(hd fl); fl = tl fl;
		iv := unhex(hd fl); fl = tl fl;
		aad := unhex(hd fl); fl = tl fl;
		pt := unhex(hd fl); fl = tl fl;
		ct := unhex(hd fl); fl = tl fl;
		tag := unhex(hd fl);
		n++;
		st := kr->aesgcmsetup(key, iv);
		(gct, gtag) := kr->aesgcmencrypt(st, pt, aad);
		ok := same(gct, ct) && same(gtag, tag);
		if(ok){
			st = kr->aesgcmsetup(key, iv);
			back := kr->aesgcmdecrypt(st, ct, aad, tag);
			ok = (len pt == 0 && len ct == 0) || same(back, pt);
		}
		if(!ok && bad++ < 5)
			t.error(sys->sprint("vector %d: key %d, iv %d, aad %d, data %d bytes: not OpenSSL's", n, len key, len iv, len aad, len pt));
	}
	t.assert(n >= 438, sys->sprint("%d vectors read", n));
	t.asserteq(bad, 0, "AES-GCM gives OpenSSL's ciphertext and tag, and opens them");
	t.log(sys->sprint("%d GCM vectors", n));
}

# NIST SP 800-38A F.2.5 (CBC-AES256.Encrypt) and F.2.6 (Decrypt)
testCBC(t: ref T)
{
	key := unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
	iv := unhex("000102030405060708090a0b0c0d0e0f");
	pt := unhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
	want := "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b";
	b := array[len pt] of byte;
	b[0:] = pt;
	kr->aescbc(kr->aessetup(key, iv), b, len b, Keyring->Encrypt);
	t.assertseq(hex(b), want, "SP 800-38A F.2.5: AES-256-CBC encrypts to NIST's ciphertext");
	kr->aescbc(kr->aessetup(key, iv), b, len b, Keyring->Decrypt);
	t.assert(same(b, pt), "F.2.6: and decrypts back");
}

sha(m: array of byte): string
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(m, len m, d, nil);
	return hex(d);
}

# FIPS 180-4's examples (NIST's SHA256.pdf, and the million "a"s)
testSHA256(t: ref T)
{
	t.assertseq(sha(array of byte "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256(\"abc\")");
	t.assertseq(sha(array[0] of byte), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of nothing");
	t.assertseq(sha(array of byte "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
		"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256 of the 448-bit message");
	a := array[1000000] of {* => byte 'a'};
	t.assertseq(sha(a), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "SHA-256 of a million \"a\"s");
	# the same million fed in pieces that cross the blocks unevenly
	st: ref Keyring->DigestState;
	for(o := 0; o < len a; ){
		k := 1 + ((o % 1000) * 7919) % 1000;
		if(o + k > len a)
			k = len a - o;
		st = kr->sha256(a[o:o+k], k, nil, st);
		o += k;
	}
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, d, st);
	t.assertseq(hex(d), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "and in uneven pieces");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	run("Libsec/AESGCM", testGCM);
	run("Libsec/AESCBC", testCBC);
	run("Libsec/SHA256", testSHA256);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
