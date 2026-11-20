implement SpkiPre0Test;

#
# spki(2): a key's numbers in its S-expression. Each is written as its
# bytes, most significant first, with leading zero bytes taken off and
# one put back when the top bit is set (so that the number is read as
# positive). The loop that took the zeros off began by asking whether a
# byte differed from the next, so a leading byte equal to the one after
# it was taken off too, whatever it was: a modulus beginning c3 c3 was
# written without its first byte, as another, smaller number. The
# S-expression, and the hash that names the key, were then another
# key's: one key in 256 could not be written and read back.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "sexprs.m";
	sexprs: Sexprs;
	Sexp: import sexprs;
include "spki.m";
	spki: SPKI;
	Key: import spki;
include "testing.m";
	testing: Testing;
	T: import testing;

SpkiPre0Test: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/spki_pre0_test.b";

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

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}

# 64 bytes: the two given, then a fixed tail that ends odd
modulus(b0, b1: int): string
{
	s := sys->sprint("%.2x%.2x", b0, b1);
	for(i := 2; i < 64; i++)
		s += sys->sprint("%.2x", (i*37+11) & 16rff | 1);
	return s;
}

# the bytes of element name in a public key's S-expression
element(e: ref Sexp, name: string): array of byte
{
	# (public-key (rsa-... (e #..#) (n #..#)))
	args := e.args();
	if(args == nil)
		return nil;
	for(l := (hd args).args(); l != nil; l = tl l)
		if((hd l).op() == name){
			a := (hd l).args();
			if(a != nil)
				return (hd a).asdata();
		}
	return nil;
}

# an RSA public key with modulus n (hex) and exponent 65537
rsapk(t: ref T, n: string): ref Keyring->PK
{
	ip := IPint.strtoip(n, 16);
	if(ip == nil)
		t.fatal("not a number: " + n);
	# the owner is the one parsekey gives a key from an S-expression, which has none
	pk := kr->strtopk("rsa\nsdsi\n" + ip.iptob64() + "\n" + IPint.inttoip(65537).iptob64() + "\n");
	if(pk == nil)
		t.fatal("Keyring does not take the key with modulus " + n[0:8] + "...");
	return pk;
}

check(t: ref T, b0, b1: int, what: string)
{
	n := modulus(b0, b1);
	pk := rsapk(t, n);
	k := ref Key(pk, nil, 512, "sha1", "pkcs1", nil);
	e := k.sexp();
	if(e == nil)
		t.fatal("no S-expression for the key");
	want := n;
	if(b0 & 16r80)
		want = "00" + n;
	t.assertseq(hex(element(e, "n")), want, what);
	# and read back it is the key it was
	k2 := spki->parsekey(e);
	if(k2 == nil || k2.pk == nil)
		t.error(what + ": the S-expression does not read back as a key");
	else
		t.assertseq(kr->pktostr(k2.pk), kr->pktostr(pk), what + ": read back, the same key");
}

testEqualLeadingBytes(t: ref T)
{
	check(t, 16rc3, 16rc3, "a modulus beginning c3 c3 keeps both, after a zero byte");
	check(t, 16r45, 16r45, "a modulus beginning 45 45 keeps both");
	check(t, 16rff, 16rff, "a modulus beginning ff ff keeps both, after a zero byte");
}

testOthers(t: ref T)
{
	check(t, 16rc3, 16r01, "a modulus with its top bit set has a zero byte before it");
	check(t, 16r45, 16r12, "one without is as it is");
	check(t, 16r7f, 16rff, "7f ff is as it is");
	check(t, 16r80, 16r00, "80 00 has a zero byte before it");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	kr = load Keyring Keyring->PATH;
	sexprs = load Sexprs Sexprs->PATH;
	spki = load SPKI SPKI->PATH;
	if(kr == nil || sexprs == nil || spki == nil){
		sys->fprint(sys->fildes(2), "spki_pre0_test: cannot load keyring, sexprs or spki: %r\n");
		raise "fail:load";
	}
	sexprs->init();
	spki->init();

	run("EqualLeadingBytes", testEqualLeadingBytes);
	run("Others", testOthers);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
