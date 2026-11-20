implement KeyringDSATest;

#
# DSA key generation and signing (libsec's dsagen and dsasign;
# libkeyring/dsaalg.c; Keyring's DSAsk and genSK).
#
# - A DSA key's secret was drawn below p, and the tree's own reader of
#   keys wants one below q: a key genSK("dsa") made, written to a file,
#   could not be read back.
# - dsagen never freed one of its numbers: 384 bytes of the kernel's
#   main pool for each key made, for good.
# - Given a q that does not divide p-1 it raised ("dsagen foul up")
#   with nine numbers made: 3200 bytes a call.
# - Given a p that is no prime it could look for a generator for ever:
#   a Carmichael number p with q a factor of p-1 has none to find, the
#   call never returned and a killed Prog went on, with a processor.
# - dsasign gave out an s of 0 (one signature in q), which no verifier
#   takes and which tells the secret.
#
# (The prime generators under them are tests/ipints_prime_test.b's.)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint, DSApk, DSAsk, DSAsig: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

KeyringDSATest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_dsa_test.b";

# a Carmichael number: (6k+1)(12k+1)(18k+1) for k = 17592186070181,
# three primes of 47 bits.  2 and 2393 divide p-1, and g^((p-1)/2) and
# g^((p-1)/2393) are 1 for every g prime to p.
CARMICHAEL: con "7056095191475152988892627956718830584844209";

# only the code before waits this out
CALLTIME: con 20000;

passed := 0;
failed := 0;
skipped := 0;

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

ip(i: int): ref IPint
{
	return IPint.inttoip(i);
}

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

lines(s: string): array of string
{
	(n, l) := sys->tokenize(s, "\n");
	a := array[n] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

join(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += a[i] + "\n";
	return s;
}

# DSAsk.gen with p and q: "key", or what it raised
dsagen(p, q: ref IPint): string
{
	{
		sk := DSAsk.gen(ref DSApk(p, q, ip(2), ip(4)));
		if(sk == nil || sk.pk == nil || sk.pk.alpha == nil)
			return "nil";
	} exception e {
	"*" =>
		return "raised " + e;
	}
	return "key";
}

call(which: string, c: chan of string)
{
	p := IPint.strtoip(CARMICHAEL, 10);
	r: string;
	{
		case which {
		"DSAsk.gen" =>
			r = dsagen(p, ip(2));
		"genSKfromPK" =>
			pk := kr->strtopk("dsa\nx\n" + p.iptob64z() + "\n" + ip(2393).iptob64z() + "\n" + ip(2).iptob64z() + "\n" + ip(4).iptob64z() + "\n");
			if(pk == nil)
				r = "no public key";
			else if(kr->genSKfromPK(pk, "x") == nil)
				r = "nil";
			else
				r = "key";
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

timed(which: string): string
{
	c := chan[1] of string;
	tc := chan[1] of int;
	spawn call(which, c);
	spawn timer(tc, CALLTIME);
	alt{
	r := <-c =>
		return r;
	<-tc =>
		return "never returned";
	}
}

# a key genSK makes is one its text reads back as
testReadBack(t: ref T)
{
	sk := kr->genSK("dsa", "t", 1024);
	if(sk == nil)
		t.fatal("cannot make a DSA key");
	s := kr->sktostr(sk);
	f := lines(s);	# dsa, owner, p, q, alpha, key, secret
	if(len f != 7)
		t.fatal(sys->sprint("a DSA secret key has %d lines", len f));
	p := IPint.b64toip(f[2]);
	q := IPint.b64toip(f[3]);
	secret := IPint.b64toip(f[6]);
	t.assert(secret.cmp(ip(0)) > 0 && secret.cmp(q) < 0, sys->sprint("the secret is from 1 to q-1 (it has %d bits, q %d)", secret.bits(), q.bits()));
	sk2 := kr->strtosk(s);
	t.assert(sk2 != nil, "the key just made is read back");
	msg := array of byte "a message";
	if(sk2 != nil){
		cert := kr->sign(sk2, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
		t.assert(cert != nil && kr->verify(kr->sktopk(sk), cert, kr->sha256(msg, len msg, nil, nil)) == 1, "and its signature verifies under the key as made");
	}
	# a key as the code before wrote them: the secret plus a multiple of q, below p
	f[6] = secret.add(q.mul(ip(1000003))).iptob64z();
	old := kr->strtosk(join(f));
	t.assert(old != nil, "a key whose secret is past q and below p is read");
	if(old != nil){
		cert := kr->sign(old, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
		t.assert(cert != nil && kr->verify(kr->sktopk(sk), cert, kr->sha256(msg, len msg, nil, nil)) == 1, "and signs as the key it is");
	}
	f[6] = p.add(secret).iptob64z();
	t.assert(kr->strtosk(join(f)) == nil, "a key whose secret is past p is not read");
}

testGenLeak(t: ref T)
{
	m0 := mainpool();
	if(m0 < 0)
		t.skip("no /dev/memory");
	p := ip(23);
	q := ip(11);
	n := 0;
	for(i := 0; i < 5000; i++)
		if(dsagen(p, q) == "key")
			n++;
	t.asserteq(n, 5000, "5000 keys made with p 23 and q 11");
	grew := mainpool() - m0;
	t.log(sys->sprint("5000 keys: main pool %d bytes more", grew));
	t.assert(grew < 512*1024, sys->sprint("5000 keys made kept %d bytes of the main pool", grew));

	# q does not divide p-1
	m0 = mainpool();
	q = ip(7);
	n = 0;
	for(i = 0; i < 5000; i++){
		r := dsagen(p, q);
		if(len r > 6 && r[0:6] == "raised")
			n++;
	}
	t.asserteq(n, 5000, "5000 keys refused with p 23 and q 7");
	grew = mainpool() - m0;
	t.log(sys->sprint("5000 refusals: main pool %d bytes more", grew));
	t.assert(grew < 512*1024, sys->sprint("5000 keys refused kept %d bytes of the main pool", grew));

	# neither prime: 25 and 6 (6 divides 24)
	r := dsagen(ip(25), ip(6));
	t.assert(len r > 6 && r[0:6] == "raised", "p 25 and q 6: " + r);
	r = dsagen(ip(23), ip(22));
	t.assert(len r > 6 && r[0:6] == "raised", "p 23 and q 22: " + r);
}

# a p that is no prime and has no generator to find
testCarmichael(t: ref T)
{
	p := IPint.strtoip(CARMICHAEL, 10);
	t.asserteq(p.bits(), 143, "the Carmichael number has 143 bits");
	t.assert(p.sub(ip(1)).mod(ip(2393)).eq(ip(0)), "and 2393 divides p-1");
	r := timed("DSAsk.gen");
	t.assert(len r > 6 && r[0:6] == "raised", "DSAsk.gen with a Carmichael p and q 2: " + r);
	r = timed("genSKfromPK");
	t.assertseq(r, "nil", "genSKfromPK of a dsa key with a Carmichael p and q 2393");
}

# no signature with an r or an s of 0
testSignZero(t: ref T)
{
	# p 23, q 11; 4 has order 11; the secret 3, the key 4^3 = 18
	pk := ref DSApk(ip(23), ip(11), ip(4), ip(18));
	sk := ref DSAsk(pk, ip(3));
	zero := ip(0);
	nz := 0;
	bad := 0;
	for(i := 0; i < 20000; i++){
		m := ip(i);
		sig := sk.sign(m);
		if(sig.r.eq(zero) || sig.s.eq(zero))
			nz++;
		else if(i < 2000 && pk.verify(sig, m) != 1)
			bad++;
	}
	t.asserteq(nz, 0, "of 20000 signatures in a group of 11, those with an r or s of 0");
	t.asserteq(bad, 0, "of the first 2000, those that do not verify");
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

	run("ReadBack", testReadBack);
	run("GenLeak", testGenLeak);
	run("Carmichael", testCarmichael);
	run("SignZero", testSignZero);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
