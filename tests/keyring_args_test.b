implement KeyringArgsTest;

#
# What a program may hand Keyring's builtins (libinterp/keyring.c), and
# what they did with it.
#
# - A digest's count of bytes was only held to the array's length from
#   above. A negative one went to libsec as an unsigned length: sha1, md5
#   and md4 stepped back from the array and hashed up to 63 bytes found
#   before it, so a program read the heap below its array a byte at a
#   time by matching digests; the SHA-2 and SHA-3 digests walked forward
#   to the end of memory.
# - sign and verify took their DigestState with a cast. DigestState is an
#   adt of the interface, so ref DigestState(0) is eight bytes of a
#   program's making, where libsec keeps its block buffer and counts: the
#   signer's name was copied to wherever the bytes after it said.
# - A key's sa (and a certificate's) is a field a program can assign.
#   The functions that read a key were found through it: a key given
#   another's sa had one algorithm's code read the other's structure
#   (an RSA key printed as Ed25519 gave the addresses of its numbers);
#   nil and a SigAlg made in Limbo were read through as they were.
# - sktostr, pktostr and certtostr allocated 48K and then looked at
#   their argument, auth 59K, and a raise left them allocated for good;
#   readauthinfo kept its buffer and its open file when a number in the
#   key file was none.
# - Sizes of keys below what a generator can make never returned
#   (released, so the Prog could not be killed); so did signing with a
#   DSA or ElGamal key that has no k to find.
# - rc4setup with a key of no bytes read the byte after the array.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint, RSAsk, DSAsk, DSApk, EGsk, EGpk: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringArgsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_args_test.b";

passed := 0;
failed := 0;
skipped := 0;

# the tests named on the command line, or all of them
only: list of string;

run(name: string, testfn: ref fn(t: ref T))
{
	if(only != nil){
		for(l := only; l != nil; l = tl l)
			if(hd l == name)
				break;
		if(l == nil)
			return;
	}
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

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# the kernel's main pool, in bytes in use
mainpool(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nf, f) := sys->tokenize(hd l, " ");
		if(nf < 2)
			continue;
		name := "";
		for(g := f; g != nil; g = tl g)
			name = hd g;
		if(name == "main")
			return int hd f;
	}
	return -1;
}

nfds(): int
{
	fd := sys->open(sys->sprint("/prog/%d/fd", sys->pctl(0, nil)), Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[8192] of byte;
	t := 0;
	while((m := sys->read(fd, b, len b)) > 0)
		for(i := 0; i < m; i++)
			if(b[i] == byte '\n')
				t++;
	return t;
}

digests := array[] of {
	# the three that stepped back and read, first: they raise nothing
	# in the code before, where the others fault
	"sha1", "md5", "md4", "hmac_sha1", "hmac_md5",
	"sha224", "sha256", "sha384", "sha512",
	"hmac_sha256", "hmac_sha384", "hmac_sha512",
	"sha3_256", "sha3_512", "keccak256",
};

# the exception a digest raises for buf and n, or nil
digest(alg: string, buf: array of byte, n: int): string
{
	d := array[64] of byte;
	key := array[8] of {* => byte 7};
	{
		case alg {
		"sha1" =>	kr->sha1(buf, n, d, nil);
		"md5" =>	kr->md5(buf, n, d, nil);
		"md4" =>	kr->md4(buf, n, d, nil);
		"sha224" =>	kr->sha224(buf, n, d, nil);
		"sha256" =>	kr->sha256(buf, n, d, nil);
		"sha384" =>	kr->sha384(buf, n, d, nil);
		"sha512" =>	kr->sha512(buf, n, d, nil);
		"hmac_sha1" =>	kr->hmac_sha1(buf, n, key, d, nil);
		"hmac_md5" =>	kr->hmac_md5(buf, n, key, d, nil);
		"hmac_sha256" =>	kr->hmac_sha256(buf, n, key, d, nil);
		"hmac_sha384" =>	kr->hmac_sha384(buf, n, key, d, nil);
		"hmac_sha512" =>	kr->hmac_sha512(buf, n, key, d, nil);
		"sha3_256" =>	kr->sha3_256(buf, n, d);
		"sha3_512" =>	kr->sha3_512(buf, n, d);
		"keccak256" =>	kr->keccak256(buf, n, d);
		* =>	return "no such digest";
		}
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

testDigestCount(t: ref T)
{
	buf := array[16] of {* => byte 1};
	counts := array[] of {-1, -63, -64, -65, 17, 16r7fffffff, -16r7fffffff-1};

	for(i := 0; i < len digests; i++)
		for(j := 0; j < len counts; j++){
			e := digest(digests[i], buf, counts[j]);
			# fatal: the code before goes on to fault in the digests after sha1
			if(e == nil)
				t.fatal(sys->sprint("%s took a count of %d for an array of %d",
					digests[i], counts[j], len buf));
			if(!contains(e, "bounds"))
				t.fatal(sys->sprint("%s with a count of %d raised %s", digests[i], counts[j], e));
		}

	# counts within the array are still taken
	for(i = 0; i < len digests; i++){
		e := digest(digests[i], buf, len buf);
		t.assert(e == nil, digests[i] + " of the whole array: " + e);
		e = digest(digests[i], buf, 0);
		t.assert(e == nil, digests[i] + " of none of it: " + e);
	}

	# and give the digest they gave
	abc := array of byte "abc";
	d := array[kr->SHA1dlen] of byte;
	kr->sha1(abc, 3, d, nil);
	t.assertseq(hex(d), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 of abc");
	st := kr->sha1(abc, 2, nil, nil);
	kr->sha1(abc[2:], 1, d, st);
	t.assertseq(hex(d), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 of abc in two pieces");
	d256 := array[kr->SHA256dlen] of byte;
	kr->sha256(abc, 3, d256, nil);
	t.assertseq(hex(d256), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc");

	# no array is no bytes, and nothing else
	st = kr->sha1(abc, 3, nil, nil);
	kr->sha1(nil, 0, d, st);
	t.assertseq(hex(d), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 finished with no array");
	t.assert(digest("sha1", nil, 1) != nil, "one byte of no array is refused");
}

signwith(sk: ref Keyring->SK, st: ref Keyring->DigestState): string
{
	{
		kr->sign(sk, 0, st, "sha256");
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

verifywith(pk: ref Keyring->PK, c: ref Keyring->Certificate, st: ref Keyring->DigestState): string
{
	{
		kr->verify(pk, c, st);
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

testDigestStateType(t: ref T)
{
	sk := kr->genSK("ed25519", "tester", 0);
	if(sk == nil)
		t.fatal("no ed25519 key");
	pk := kr->sktopk(sk);
	msg := array of byte "a message";
	cert := kr->sign(sk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	if(cert == nil)
		t.fatal("sign gave no certificate");
	t.asserteq(kr->verify(pk, cert, kr->sha256(msg, len msg, nil, nil)), 1, "a signature verifies");

	# a DigestState of the program's own making is not one
	e := signwith(sk, ref Keyring->DigestState(0));
	if(e == nil || !contains(e, "DigestState"))
		t.fatal("sign took a DigestState made in Limbo: " + e);
	e = verifywith(pk, cert, ref Keyring->DigestState(0));
	if(e == nil || !contains(e, "DigestState"))
		t.fatal("verify took a DigestState made in Limbo: " + e);

	# none is still no signature, and nothing raised
	t.assert(kr->sign(sk, 0, nil, "sha256") == nil, "sign with no state gives no certificate");
	t.asserteq(kr->verify(pk, cert, nil), 0, "verify with no state verifies nothing");
	t.asserteq(kr->verify(pk, cert, kr->sha256(msg, len msg, nil, nil)), 1, "and the signature still verifies");
}

# each of the calls that reads a secret key, on sk; the exception or nil
skcall(which: string, sk: ref Keyring->SK): string
{
	{
		case which {
		"sktostr" =>	kr->sktostr(sk);
		"sktoattr" =>	kr->sktoattr(sk);
		"sktopk" =>	kr->sktopk(sk);
		"sign" =>	kr->sign(sk, 0, kr->sha256(array[4] of byte, 4, nil, nil), "sha256");
		"signm" =>	kr->signm(sk, IPint.inttoip(12345), "sha256");
		}
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

pkcall(which: string, pk: ref Keyring->PK, cert: ref Keyring->Certificate): string
{
	{
		case which {
		"pktostr" =>	kr->pktostr(pk);
		"pktoattr" =>	kr->pktoattr(pk);
		"genSKfromPK" =>	kr->genSKfromPK(pk, "x");
		"verify" =>	kr->verify(pk, cert, kr->sha256(array[4] of byte, 4, nil, nil));
		"verifym" =>	kr->verifym(pk, cert, IPint.inttoip(12345));
		"certtostr" =>	kr->certtostr(cert);
		"certtoattr" =>	kr->certtoattr(cert);
		}
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

skcalls := array[] of {"sktostr", "sktoattr", "sktopk", "sign", "signm"};
pkcalls := array[] of {"pktostr", "pktoattr", "genSKfromPK", "verify", "verifym"};
certcalls := array[] of {"certtostr", "certtoattr", "verify", "verifym"};

testSigAlg(t: ref T)
{
	ed := kr->genSK("ed25519", "ed", 0);
	rsa := kr->genSK("rsa", "rsa", 512);
	if(ed == nil || rsa == nil)
		t.fatal("no keys to test with");
	edpk := kr->sktopk(ed);
	rsapk := kr->sktopk(rsa);
	msg := array[4] of byte;
	edcert := kr->sign(ed, 0, kr->sha256(msg, 4, nil, nil), "sha256");
	rsacert := kr->sign(rsa, 0, kr->sha256(msg, 4, nil, nil), "sha256");
	rsastr := kr->sktostr(rsa);
	edstr := kr->sktostr(ed);
	rsasa := rsa.sa;
	edsa := ed.sa;

	# an RSA key that says it is Ed25519.  fatal: the code before goes on
	# to use the bytes of one key as the pointers of another
	rsa.sa = edsa;
	e := skcall("sktostr", rsa);
	if(e == nil)
		t.fatal("sktostr printed an RSA key relabelled Ed25519");
	t.assert(contains(e, "bad secret key"), "a relabelled key is a bad secret key: " + e);
	for(i := 0; i < len skcalls; i++)
		t.assert(skcall(skcalls[i], rsa) != nil, skcalls[i] + " refuses an RSA key relabelled Ed25519");
	ed.sa = rsasa;
	for(i = 0; i < len skcalls; i++)
		t.assert(skcall(skcalls[i], ed) != nil, skcalls[i] + " refuses an Ed25519 key relabelled RSA");

	# no algorithm, and one made in Limbo
	ed.sa = nil;
	for(i = 0; i < len skcalls; i++)
		t.assert(skcall(skcalls[i], ed) != nil, skcalls[i] + " refuses a key with no sa");
	ed.sa = ref Keyring->SigAlg("ed25519");
	for(i = 0; i < len skcalls; i++)
		t.assert(skcall(skcalls[i], ed) != nil, skcalls[i] + " refuses a key with a SigAlg made in Limbo");

	# put back, the keys are what they were
	rsa.sa = rsasa;
	ed.sa = edsa;
	t.assertseq(kr->sktostr(rsa), rsastr, "the RSA key with its own sa again");
	t.assertseq(kr->sktostr(ed), edstr, "the Ed25519 key with its own sa again");
	for(i = 0; i < len skcalls; i++)
		t.assert(skcall(skcalls[i], ed) == nil, skcalls[i] + " takes the key with its own sa: " + skcall(skcalls[i], ed));

	# public keys
	edpksa := edpk.sa;
	edpk.sa = rsapk.sa;
	for(i = 0; i < len pkcalls; i++)
		t.assert(pkcall(pkcalls[i], edpk, edcert) != nil, pkcalls[i] + " refuses a relabelled public key");
	edpk.sa = nil;
	for(i = 0; i < len pkcalls; i++)
		t.assert(pkcall(pkcalls[i], edpk, edcert) != nil, pkcalls[i] + " refuses a public key with no sa");
	edpk.sa = ref Keyring->SigAlg("ed25519");
	for(i = 0; i < len pkcalls; i++)
		t.assert(pkcall(pkcalls[i], edpk, edcert) != nil, pkcalls[i] + " refuses a public key with a Limbo SigAlg");
	edpk.sa = edpksa;

	# certificates
	edcertsa := edcert.sa;
	edcert.sa = rsacert.sa;
	for(i = 0; i < len certcalls; i++)
		t.assert(pkcall(certcalls[i], edpk, edcert) != nil, certcalls[i] + " refuses a relabelled certificate");
	edcert.sa = nil;
	for(i = 0; i < len certcalls; i++)
		t.assert(pkcall(certcalls[i], edpk, edcert) != nil, certcalls[i] + " refuses a certificate with no sa");
	edcert.sa = edcertsa;
	t.asserteq(kr->verify(edpk, edcert, kr->sha256(msg, 4, nil, nil)), 1, "the certificate verifies with its own sa again");
	t.asserteq(kr->verify(rsapk, rsacert, kr->sha256(msg, 4, nil, nil)), 1, "the RSA certificate verifies");
	# a key of one algorithm and a signature of another: no signature, as before
	t.asserteq(kr->verify(rsapk, edcert, kr->sha256(msg, 4, nil, nil)), 0, "an Ed25519 signature under an RSA key verifies nothing");

	# keys and certificates made in Limbo have nothing behind them
	t.assert(skcall("sktostr", ref Keyring->SK(edsa, "x")) != nil, "an SK made in Limbo is refused");
	t.assert(pkcall("pktostr", ref Keyring->PK(edsa, "x"), edcert) != nil, "a PK made in Limbo is refused");
	t.assert(pkcall("certtostr", edpk, ref Keyring->Certificate(edsa, "sha256", "x", 0)) != nil,
		"a Certificate made in Limbo is refused");

	# the names printed are the keys' own
	t.assert(len rsastr > 4 && rsastr[0:4] == "rsa\n", "an RSA key's text begins rsa");
	t.assert(len edstr > 8 && edstr[0:8] == "ed25519\n", "an Ed25519 key's text begins ed25519");
}

# the far end of auth's pipe (which has said version 2 already): reads
# until it has the whole of an error message ("!ddd\n" and ddd bytes), or
# is hung up on, and goes
peer(fd: ref Sys->FD, done: chan of int)
{
	buf := array[8192] of byte;
	acc := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			acc[len acc] = int buf[i];
		bang := -1;
		for(i = 0; i < len acc; i++)
			if(acc[i] == '!'){
				bang = i;
				break;
			}
		if(bang >= 0 && len acc >= bang+5 && len acc >= bang+5+int acc[bang+1:bang+4])
			break;
	}
	fd = nil;
	done <-= 1;
}

# auth with info on a pipe: what it returned, or raised
auth(info: ref Keyring->Authinfo): (string, string)
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return (nil, "no pipe");
	v := array of byte "0001\n2";
	sys->write(fds[1], v, len v);
	done := chan[1] of int;
	spawn peer(fds[1], done);
	fds[1] = nil;
	s, e: string;
	{
		(s, nil) = kr->auth(fds[0], info, 0);
	} exception x {
	"*" =>
		e = x;
	}
	fds[0] = nil;
	<-done;
	return (s, e);
}

testLostBuffers(t: ref T)
{
	m0 := mainpool();
	if(m0 < 0)
		t.skip("no /dev/memory");

	# a nil key: each call raises, and gave back nothing
	n := 0;
	for(i := 0; i < 300; i++){
		{ kr->sktostr(nil); } exception { "*" => n++; }
		{ kr->pktostr(nil); } exception { "*" => n++; }
		{ kr->certtostr(nil); } exception { "*" => n++; }
	}
	t.asserteq(n, 900, "sktostr, pktostr and certtostr of nil raise");
	grew := mainpool() - m0;
	t.log(sys->sprint("900 raises: main pool %d bytes more", grew));
	t.assert(grew < 1024*1024, sys->sprint("900 refused calls kept %d bytes of the main pool", grew));

	# auth with keys that are none
	m0 = mainpool();
	bad := ref Keyring->Authinfo(nil, nil, nil, nil, IPint.inttoip(5), IPint.inttoip(23));
	n = 0;
	for(i = 0; i < 100; i++){
		(nil, e) := auth(bad);
		if(e != nil)
			n++;
	}
	t.asserteq(n, 100, "auth with no keys raises");
	grew = mainpool() - m0;
	t.log(sys->sprint("100 auths: main pool %d bytes more", grew));
	t.assert(grew < 1024*1024, sys->sprint("100 refused auths kept %d bytes of the main pool", grew));
}

testAuthModulus(t: ref T)
{
	sk := kr->genSK("ed25519", "me", 0);
	pk := kr->sktopk(sk);
	pkb := array of byte kr->pktostr(pk);
	cert := kr->sign(sk, 0, kr->sha256(pkb, len pkb, nil, nil), "sha256");

	# a modulus of zero is divided by: said, not raised with everything allocated
	(s, e) := auth(ref Keyring->Authinfo(sk, pk, cert, pk, IPint.inttoip(5), IPint.inttoip(0)));
	t.assert(e == nil, "auth with a modulus of zero raises nothing: " + e);
	t.assert(s != nil && contains(s, "diffie hellman mod"), "and says why: " + s);

	# one longer than its transcript has room for
	bigp := IPint.inttoip(1).shl(40000).add(IPint.inttoip(1));
	(s, e) = auth(ref Keyring->Authinfo(sk, pk, cert, pk, IPint.inttoip(5), bigp));
	t.assert(e == nil, "auth with a modulus of 40000 bits raises nothing: " + e);
	t.assert(s != nil && contains(s, "diffie hellman mod"), "and says why: " + s);

	# as before
	(s, e) = auth(ref Keyring->Authinfo(sk, pk, cert, pk, IPint.inttoip(5), IPint.inttoip(-23)));
	t.assert(e == nil && s != nil && contains(s, "-ve modulus"), "a negative modulus: " + s + e);
	(s, e) = auth(nil);
	t.assert(e == nil && s != nil && contains(s, "no authentication information"), "no Authinfo: " + s + e);
	(s, e) = auth(ref Keyring->Authinfo(sk, pk, cert, pk, IPint.inttoip(5), nil));
	t.assert(e == nil && s != nil && contains(s, "missing diffie hellman mod"), "no modulus: " + s + e);
}

testReadauthinfo(t: ref T)
{
	sk := kr->genSK("ed25519", "me", 0);
	pk := kr->sktopk(sk);
	pkb := array of byte kr->pktostr(pk);
	cert := kr->sign(sk, 0, kr->sha256(pkb, len pkb, nil, nil), "sha256");
	ai := ref Keyring->Authinfo(sk, pk, cert, pk, IPint.inttoip(5), IPint.inttoip(23));
	(tok, nil) := sys->stat("/tmp");
	if(tok < 0)
		sys->create("/tmp", Sys->OREAD, Sys->DMDIR|8r777);
	good := sys->sprint("/tmp/keyring_args_test.%d.good", sys->pctl(0, nil));
	bad := sys->sprint("/tmp/keyring_args_test.%d.bad", sys->pctl(0, nil));
	if(kr->writeauthinfo(good, ai) < 0)
		t.skip("cannot write a key file in /tmp");
	t.assert(kr->readauthinfo(good) != nil, "a key file written is read");

	fd := sys->open(good, Sys->OREAD);
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		t.fatal("cannot read the key file back");
	s := string buf[0:n];
	# its last two records are the base "BQ==" and the modulus "Fw==": make the base no number
	changed := 0;
	for(i := 0; i < len s - 3; i++)
		if(s[i:i+4] == "BQ=="){
			s = s[0:i] + "!!!!" + s[i+4:];
			changed = 1;
			break;
		}
	if(!changed)
		t.fatal("no Diffie-Hellman base in the key file");
	fd = sys->create(bad, Sys->OWRITE, 8r600);
	b := array of byte s;
	sys->write(fd, b, len b);
	fd = nil;

	m0 := mainpool();
	f0 := nfds();
	raised := 0;
	notnil := 0;
	for(i = 0; i < 50; i++){
		{
			if(kr->readauthinfo(bad) != nil)
				notnil++;
		} exception {
		"*" =>
			raised++;
		}
	}
	f1 := nfds();
	grew := mainpool() - m0;
	sys->remove(good);
	sys->remove(bad);
	t.asserteq(raised, 0, "a key file with a number that is none raises nothing");
	t.asserteq(notnil, 0, "and gives no Authinfo");
	t.asserteq(f1, f0, "and leaves no file open");
	t.assert(grew < 512*1024, sys->sprint("fifty of them kept %d bytes of the main pool", grew));
}

# a call that must come back: run aside, with a time limit, as the code
# before never returns from some of these (and cannot then be killed)
SIZETIME: con 20000;	# (only the code before waits it out; a loaded machine needs more than a few seconds for the sizes that work)

gencall(which: string, n: int, c: chan of string)
{
	r := "returned";
	{
		case which {
		"dhparams" =>
			(a, p) := kr->dhparams(n);
			r = sys->sprint("returned %d bits", p.bits());
			a = nil;
		"RSAsk.gen" =>
			sk := RSAsk.gen(n, 6, 0);
			r = sys->sprint("returned %d bits", sk.pk.n.bits());
		"RSAsk.gen elen" =>
			RSAsk.gen(64, n, 0);
		"EGsk.gen" =>
			sk := EGsk.gen(n, 0);
			r = sys->sprint("returned %d bits", sk.pk.p.bits());
		"genSK rsa" =>
			if(kr->genSK("rsa", "x", n) == nil)
				r = "nil";
		"genSK elgamal" =>
			if(kr->genSK("elgamal", "x", n) == nil)
				r = "nil";
		"random" =>
			IPint.random(0, n);
		"DSAsk.sign q" =>
			# p 23, q n: 11 divides 22
			sk := ref DSAsk(ref DSApk(IPint.inttoip(23), IPint.inttoip(n), IPint.inttoip(2), IPint.inttoip(4)), IPint.inttoip(3));
			sk.sign(IPint.inttoip(5));
		"DSAsk.gen p" =>
			# q 2, so that it is p that has no generator
			DSAsk.gen(ref DSApk(IPint.inttoip(n), IPint.inttoip(2), IPint.inttoip(2), IPint.inttoip(4)));
		"EGsk.sign p" =>
			sk := ref EGsk(ref EGpk(IPint.inttoip(n), IPint.inttoip(2), IPint.inttoip(4)), IPint.inttoip(3));
			sk.sign(IPint.inttoip(5));
		}
	} exception e {
	"*" =>
		r = "raised " + e;
	}
	c <-= r;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

gen(which: string, n: int): string
{
	c := chan[1] of string;
	tc := chan[1] of int;
	spawn gencall(which, n, c);
	spawn timer(tc, SIZETIME);
	alt{
	r := <-c =>
		return r;
	<-tc =>
		return "never returned";
	}
}

refused(t: ref T, which: string, n: int)
{
	r := gen(which, n);
	t.assert(len r > 6 && r[0:6] == "raised", sys->sprint("%s(%d) is refused: %s", which, n, r));
}

isnil(t: ref T, which: string, n: int)
{
	t.assertseq(gen(which, n), "nil", sys->sprint("%s(%d) gives no key", which, n));
}

testKeySizes(t: ref T)
{
	# sizes that have no key
	sizes := array[] of {-16r7fffffff-1, -100, -1, 0, 1, 2};
	for(i := 0; i < len sizes; i++){
		refused(t, "dhparams", sizes[i]);
		refused(t, "EGsk.gen", sizes[i]);
		refused(t, "RSAsk.gen", sizes[i]);
		isnil(t, "genSK rsa", sizes[i]);
		isnil(t, "genSK elgamal", sizes[i]);
	}
	refused(t, "RSAsk.gen", 3);
	refused(t, "RSAsk.gen", 5);
	refused(t, "RSAsk.gen", 15);
	isnil(t, "genSK rsa", 5);
	refused(t, "RSAsk.gen elen", 0);
	refused(t, "RSAsk.gen elen", -1);
	refused(t, "RSAsk.gen elen", 16r7fffffff);
	refused(t, "random", -1);
	refused(t, "random", -100);
	refused(t, "random", 16r7fffffff);

	# and sizes too large for anyone to wait for, or for libmp's digit counts
	huge := array[] of {1<<17, 1<<30, 16r7fffffff};
	for(i = 0; i < len huge; i++){
		refused(t, "dhparams", huge[i]);
		refused(t, "EGsk.gen", huge[i]);
		refused(t, "RSAsk.gen", huge[i]);
		isnil(t, "genSK rsa", huge[i]);
		isnil(t, "genSK elgamal", huge[i]);
	}

	# the least there is
	t.assertseq(gen("dhparams", 3), "returned 3 bits", "dhparams(3) is 7");
	t.assertseq(gen("dhparams", 5), "returned 5 bits", "dhparams(5)");
	t.assertseq(gen("EGsk.gen", 3), "returned 3 bits", "EGsk.gen(3)");
	t.assertseq(gen("EGsk.gen", 8), "returned 8 bits", "EGsk.gen(8)");
	t.assertseq(gen("RSAsk.gen", 16), "returned 16 bits", "RSAsk.gen(16)");
	t.assertseq(gen("RSAsk.gen", 64), "returned 64 bits", "RSAsk.gen(64)");
	t.assertseq(gen("genSK rsa", 16), "returned", "genSK rsa 16");
	t.assertseq(gen("genSK elgamal", 3), "returned", "genSK elgamal 3");
	t.assertseq(gen("random", 0), "returned", "random of no bits");
	t.assertseq(gen("random", 100), "returned", "random of 100 bits");

	# keys with no k to sign with, and no generator to find
	refused(t, "DSAsk.sign q", 1);
	refused(t, "DSAsk.sign q", 0);
	refused(t, "DSAsk.sign q", -11);
	refused(t, "DSAsk.gen p", 1);
	refused(t, "DSAsk.gen p", 0);
	refused(t, "EGsk.sign p", 1);
	refused(t, "EGsk.sign p", 0);
	refused(t, "EGsk.sign p", -23);
	t.assertseq(gen("DSAsk.sign q", 11), "returned", "a DSA key with q 11 signs");
	t.assertseq(gen("EGsk.sign p", 23), "returned", "an ElGamal key with p 23 signs");
}

rc4stream(st: ref Keyring->RC4state, n: int): string
{
	b := array[n] of {* => byte 0};
	kr->rc4(st, b, n);
	return hex(b);
}

# A key for AES-GCM is 16, 24 or 32 bytes. aesgcmsetup took any that was
# not empty, and a length that is no key's made a state with no rounds:
# what it "encrypted" opened again, 33 and 100 bytes gave one output, and
# on a processor with the AES instructions the tag carried 16 bytes of
# the emulator's stack.
testAESGCMKey(t: ref T)
{
	iv := array[12] of {* => byte 7};
	lens := array[] of {0, 1, 5, 15, 17, 20, 31, 33, 100};
	for(i := 0; i < len lens; i++){
		e: string;
		{
			kr->aesgcmsetup(array[lens[i]] of {* => byte 16r41}, iv);
		} exception x {
		"*" =>
			e = x;
		}
		t.assert(e != nil, sys->sprint("aesgcmsetup with a key of %d bytes is refused", lens[i]));
	}
	lens = array[] of {16, 24, 32};
	for(i = 0; i < len lens; i++){
		key := array[lens[i]] of {* => byte 16r41};
		st := kr->aesgcmsetup(key, iv);
		t.assert(st != nil, sys->sprint("aesgcmsetup with a key of %d bytes", lens[i]));
		msg := array of byte "a message";
		(ct, tag) := kr->aesgcmencrypt(st, msg, nil);
		pt := kr->aesgcmdecrypt(kr->aesgcmsetup(key, iv), ct, nil, tag);
		t.assert(pt != nil && string pt == "a message" && string ct != "a message", sys->sprint("a key of %d bytes seals and opens", lens[i]));
	}
	# what the two longest gave: the same
	e: string;
	{
		kr->aesgcmsetup(array[0] of byte, iv);
	} exception x {
	"*" =>
		e = x;
	}
	t.assert(e != nil, "aesgcmsetup with an empty key is refused");
}

testRC4(t: ref T)
{
	# a key of no bytes: the byte after the array was the key
	a := array[8] of {* => byte 16r41};
	e: string;
	{
		kr->rc4setup(a[8:8]);
	} exception x {
	"*" =>
		e = x;
	}
	t.assert(e != nil, "rc4setup with a key of no bytes is refused");
	e = nil;
	{
		kr->rc4setup(array[0] of byte);
	} exception x {
	"*" =>
		e = x;
	}
	t.assert(e != nil, "rc4setup with an empty array is refused");

	# RC4 as it was: "Key" and "Plaintext"
	st := kr->rc4setup(array of byte "Key");
	p := array of byte "Plaintext";
	kr->rc4(st, p, len p);
	t.assertseq(hex(p), "bbf316e8d940af0ad3", "rc4 of Plaintext under Key");

	# a long skip (gone on a copy, the VM let go) is the short skips it is made of
	s1 := kr->rc4setup(array of byte "Key");
	s2 := kr->rc4setup(array of byte "Key");
	kr->rc4skip(s1, (1<<20) + 12345);
	kr->rc4skip(s2, 1<<20);
	kr->rc4skip(s2, 12345);
	t.assertseq(rc4stream(s1, 16), rc4stream(s2, 16), "a skip of 2^20+12345 and two skips of as much");
	kr->rc4back(s1, (1<<20) + 12345 + 16);
	t.assertseq(rc4stream(s1, 9), rc4stream(kr->rc4setup(array of byte "Key"), 9),
		"and back again is the start");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(sys->fildes(2), "cannot load Keyring: %r\n");
		raise "fail:cannot load Keyring";
	}
	testing->init();
	if(args != nil)
		args = tl args;
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		else
			only = hd a :: only;
	}

	run("DigestCount", testDigestCount);
	run("DigestStateType", testDigestStateType);
	run("SigAlg", testSigAlg);
	run("LostBuffers", testLostBuffers);
	run("AuthModulus", testAuthModulus);
	run("Readauthinfo", testReadauthinfo);
	run("RC4", testRC4);
	run("AESGCMKey", testAESGCMKey);
	run("KeySizes", testKeySizes);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
