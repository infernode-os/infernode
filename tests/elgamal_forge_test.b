implement ElgamalForgeTest;

#
# ElGamal signatures made from a public key alone (Keyring's "elgamal"
# keys; libsec's egverify, eggen, egsign; libkeyring/egalg.c).
#
# A 2048-bit ElGamal key was RFC 3526's prime with its generator 2, which
# divides p-1. With r = (p-1)/2 the public key to the power r is 1 for
# every key, and r is -1/2, so for an even s chosen from the message the
# signature verifies: any message, any such key, no secret
# (Bleichenbacher, Eurocrypt 1996). A certificate for any name was made
# from the signer's public key, and Keyring->auth took its bearer for
# that name. The same r serves a generator of 4, or any known power of 2:
# what the forger needs is r's logarithm.
#
# Now: r must lie in the subgroup of order (p-1)/2 that the generator
# has (which (p-1)/2 and p-1, the two r's that make the key's power
# trivial, do not), s is from 1 to p-2, and a key is refused unless its
# generator and public value are in that subgroup and its generator does
# not divide p-1. New keys take a random generator of the subgroup. The
# keys made before are refused, when read and when used:
# tests/elgamal/oldkey.sk is one, kept as it was written.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint, EGpk, EGsk, EGsig: import kr;
include "testing.m";
	testing: Testing;
	T: import testing;

ElgamalForgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/elgamal_forge_test.b";
OLDKEY: con "/tests/elgamal/oldkey.sk";

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

lines(s: string): array of string
{
	(n, l) := sys->tokenize(s, "\n");
	a := array[n] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

# the digest Keyring's sign and verify make of data for a certificate
certdigest(data: array of byte, signer: string, exp: int): ref IPint
{
	tail := array of byte (signer + " " + string exp);
	st := kr->sha256(data, len data, nil, nil);
	digest := array[Keyring->SHA256dlen] of byte;
	kr->sha256(tail, len tail, digest, st);
	return IPint.bebytestoip(digest);
}

# Bleichenbacher's signature on m for a generator of 2 (pow 1) or 4
# (pow 2): r = (p-1)/2 = q, and s even with 2^-s = alpha^m
forgesig(p, m: ref IPint, pow: int): (ref IPint, ref IPint)
{
	one := ip(1);
	q := p.sub(one).shr(1);
	s := q.sub(m.mul(ip(pow)).mod(q));
	if(s.and(one).eq(one) || s.eq(ip(0)))
		s = s.add(q);
	return (q, s);
}

# a certificate by the key in spkstr over data, from that string alone
forgecert(spkstr: string, data: array of byte): string
{
	f := lines(spkstr);	# elgamal, owner, p, alpha, key
	signer := f[1];
	p := IPint.b64toip(f[2]);
	(r, s) := forgesig(p, certdigest(data, signer, 0), 1);
	return "elgamal\nsha256\n" + signer + "\n0\n" + r.iptob64z() + "\n" + s.iptob64z() + "\n";
}

egverify(pk: ref EGpk, r, s, m: ref IPint): string
{
	{
		return string pk.verify(ref EGsig(r, s), m);
	} exception e {
	"*" =>
		return "exception: " + e;
	}
}

egsign(sk: ref EGsk, m: ref IPint): (ref EGsig, string)
{
	{
		return (sk.sign(m), nil);
	} exception e {
	"*" =>
		return (nil, e);
	}
}

# a key as this tree made them before: refused when read and when used
testOldKey(t: ref T)
{
	skstr := readfile(OLDKEY);
	if(skstr == nil)
		t.fatal("cannot read " + OLDKEY);
	f := lines(skstr);	# elgamal, owner, p, alpha, key, secret
	if(len f != 6)
		t.fatal(sys->sprint("%s has %d lines", OLDKEY, len f));
	pkstr := f[0] + "\n" + f[1] + "\n" + f[2] + "\n" + f[3] + "\n" + f[4] + "\n";
	p := IPint.b64toip(f[2]);
	alpha := IPint.b64toip(f[3]);
	key := IPint.b64toip(f[4]);
	secret := IPint.b64toip(f[5]);
	t.asserteq(p.bits(), 2048, "the old key's prime has 2048 bits");
	t.assert(alpha.eq(ip(2)), "its generator is 2");
	t.assert(ip(2).expmod(secret, p).eq(key), "and its public value is 2 to its secret");

	t.assert(kr->strtopk(pkstr) == nil, "the old public key is not read");
	t.assert(kr->strtosk(skstr) == nil, "the old secret key is not read");

	# as adts: nothing verifies with it, forged or made with its secret
	pk := ref EGpk(p, alpha, key);
	m := IPint.random(250, 250);
	(r, s) := forgesig(p, m, 1);
	t.assertseq(egverify(pk, r, s, m), "0", "the forged signature under the old key");
	(sig, e) := egsign(ref EGsk(pk, secret), m);
	t.assert(sig == nil && e != nil, "the old key does not sign: " + e);
	# and one ElGamal's own arithmetic makes with the secret (k = 3)
	pm1 := p.sub(ip(1));
	k := ip(3);
	rr := alpha.expmod(k, p);
	ss := m.sub(secret.mul(rr)).mul(k.invert(pm1)).mod(pm1);
	t.assert(key.expmod(rr, p).mul(rr.expmod(ss, p)).mod(p).eq(alpha.expmod(m, p)), "a signature made with the old secret satisfies the equation");
	t.assertseq(egverify(pk, rr, ss, m), "0", "and is not taken under the old key");
}

# a key as made now
testNewKey(t: ref T)
{
	sk := kr->genSK("elgamal", "signer", 2048);
	if(sk == nil)
		t.fatal("cannot make a 2048-bit ElGamal key");
	pk := kr->sktopk(sk);
	f := lines(kr->pktostr(pk));
	if(len f != 5)
		t.fatal(sys->sprint("an ElGamal public key has %d lines", len f));
	p := IPint.b64toip(f[2]);
	alpha := IPint.b64toip(f[3]);
	key := IPint.b64toip(f[4]);
	one := ip(1);
	q := p.sub(one).shr(1);
	t.asserteq(p.bits(), 2048, "the prime has 2048 bits");
	t.assert(alpha.bits() > 1000, sys->sprint("the generator is a number of the prime's size (%d bits)", alpha.bits()));
	t.assert(!p.sub(one).mod(alpha).eq(ip(0)), "the generator does not divide p-1");
	t.assert(alpha.expmod(q, p).eq(one), "the generator has order (p-1)/2");
	t.assert(key.expmod(q, p).eq(one), "the public value is in its subgroup");
	g := lines(kr->sktostr(sk));
	secret := IPint.b64toip(g[5]);
	t.assert(secret.cmp(one) > 0 && secret.cmp(q) < 0, "the secret is between 1 and (p-1)/2");

	# it signs, verifies, and is read back
	msg := array of byte "a message";
	cert := kr->sign(sk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
	t.assert(cert != nil && kr->verify(pk, cert, kr->sha256(msg, len msg, nil, nil)) == 1, "a certificate verifies");
	other := array of byte "another";
	t.asserteq(kr->verify(pk, cert, kr->sha256(other, len other, nil, nil)), 0, "and not over other data");
	sk2 := kr->strtosk(kr->sktostr(sk));
	pk2 := kr->strtopk(kr->pktostr(pk));
	t.assert(sk2 != nil && pk2 != nil, "the key is read back");
	if(pk2 != nil)
		t.asserteq(kr->verify(pk2, cert, kr->sha256(msg, len msg, nil, nil)), 1, "and verifies the certificate");

	# a user's key from the signer's parameters
	usk := kr->genSKfromPK(pk, "user");
	t.assert(usk != nil, "a key is made from the signer's parameters");
	if(usk != nil){
		u := lines(kr->sktostr(usk));
		t.assert(u[2] == f[2] && u[3] == f[3], "with the signer's prime and generator");
		c2 := kr->sign(usk, 0, kr->sha256(msg, len msg, nil, nil), "sha256");
		t.assert(c2 != nil && kr->verify(kr->sktopk(usk), c2, kr->sha256(msg, len msg, nil, nil)) == 1, "and it signs and verifies");
	}

	# the forgery: a certificate from the public key string alone
	data := array of byte "admin's key";
	forged := kr->strtocert(forgecert(kr->pktostr(pk), data));
	t.assert(forged != nil, "the forged certificate is read");
	if(forged != nil)
		t.asserteq(kr->verify(pk, forged, kr->sha256(data, len data, nil, nil)), 0, "a certificate forged from the public key");

	# a signature's other forms
	sgn := ref EGsk(ref EGpk(p, alpha, key), secret);
	m := IPint.random(250, 250);
	(sig, e) := egsign(sgn, m);
	if(sig == nil)
		t.fatal("the new key does not sign as an adt: " + e);
	t.assertseq(egverify(sgn.pk, sig.r, sig.s, m), "1", "a signature");
	pm1 := p.sub(one);
	t.assertseq(egverify(sgn.pk, sig.r, sig.s.add(pm1), m), "0", "the signature with p-1 added to s");
	t.assertseq(egverify(sgn.pk, sig.r, ip(0), m), "0", "the signature with an s of 0");
	t.assertseq(egverify(sgn.pk, sig.r.add(p), sig.s, m), "0", "the signature with p added to r");
	t.assertseq(egverify(sgn.pk, sig.r, sig.s, m.add(one)), "0", "the signature on another message");
	t.assert(sig.r.expmod(q, p).eq(one), "r is in the generator's subgroup");
}

# a generator of 4 in RFC 3526's group: a key that is one (4 has order
# (p-1)/2 and does not divide p-1), whose signatures were forged all the
# same, with the same r
testGeneratorFour(t: ref T)
{
	(nil, p) := kr->dhparams(2048);
	if(p == nil)
		t.fatal("no 2048-bit group");
	one := ip(1);
	q := p.sub(one).shr(1);
	x := IPint.random(2000, 2000).mod(q.sub(ip(2))).add(ip(2));
	pk := ref EGpk(p, ip(4), ip(4).expmod(x, p));
	sk := ref EGsk(pk, x);
	n := 0;
	for(i := 0; i < 8; i++){
		m := IPint.random(250, 250);
		(r, s) := forgesig(p, m, 2);
		if(egverify(pk, r, s, m) != "0")
			n++;
	}
	t.asserteq(n, 0, "of 8 messages, signatures forged with r = (p-1)/2 under a generator of 4 that verify");
	m := IPint.random(250, 250);
	(sig, e) := egsign(sk, m);
	t.assert(sig != nil, "the key signs: " + e);
	if(sig != nil)
		t.assertseq(egverify(pk, sig.r, sig.s, m), "1", "and its own signature verifies");
	# r = p-1, the other r that makes the key's power trivial
	t.assertseq(egverify(pk, p.sub(one), ip(2), ip(0)), "0", "r = p-1, s = 2 on a message of 0");
}

Result: adt { owner: string; secret: array of byte; };

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of ref Result)
{
	{
		(owner, secret) := kr->auth(fd, ai, 0);
		c <-= ref Result(owner, secret);
	} exception e {
	"*" =>
		c <-= ref Result("exception: " + e, nil);
	}
}

# Keyring->auth with a certificate forged from the signer's public key
testAuth(t: ref T)
{
	ssk := kr->genSK("elgamal", "signer", 2048);
	if(ssk == nil)
		t.fatal("cannot make a 2048-bit ElGamal key");
	spk := kr->sktopk(ssk);
	spkstr := kr->pktostr(spk);
	(alpha, p) := kr->dhparams(2048);
	srvsk := kr->genSK("ed25519", "server", 0);
	srvpk := kr->sktopk(srvsk);
	b := array of byte kr->pktostr(srvpk);
	srv := ref Keyring->Authinfo(srvsk, srvpk, kr->sign(ssk, 0, kr->sha256(b, len b, nil, nil), "sha256"), spk, alpha, p);

	# an honest client first: the signer's certificate over its key
	csk := kr->genSK("ed25519", "client", 0);
	cpk := kr->sktopk(csk);
	b = array of byte kr->pktostr(cpk);
	cli := ref Keyring->Authinfo(csk, cpk, kr->sign(ssk, 0, kr->sha256(b, len b, nil, nil), "sha256"), spk, alpha, p);
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	ca := chan[1] of ref Result;
	cb := chan[1] of ref Result;
	spawn authproc(fds[0], srv, ca);
	spawn authproc(fds[1], cli, cb);
	fds = nil;
	rs := <-ca;
	<-cb;
	t.assertseq(rs.owner, "client", "the server authenticates a client the signer certified");

	# the forger: the signer's public key string and nothing of its secret
	ssk = nil;
	mysk := kr->genSK("ed25519", "admin", 0);
	mypk := kr->sktopk(mysk);
	b = array of byte kr->pktostr(mypk);
	cert := kr->strtocert(forgecert(spkstr, b));
	t.assert(cert != nil, "the forged certificate is read");
	if(cert == nil)
		return;
	me := ref Keyring->Authinfo(mysk, mypk, cert, spk, alpha, p);
	fds = array[2] of ref Sys->FD;
	sys->pipe(fds);
	spawn authproc(fds[0], srv, ca);
	spawn authproc(fds[1], me, cb);
	fds = nil;
	rs = <-ca;
	<-cb;
	t.assert(rs.owner != "admin", "the server's auth with a forged certificate for admin: peer \"" + rs.owner + "\"");
	if(rs.owner == nil && rs.secret != nil)
		t.log("the server's auth says: " + string rs.secret);
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

	run("OldKey", testOldKey);
	run("NewKey", testNewKey);
	run("GeneratorFour", testGeneratorFour);
	run("Auth", testAuth);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
