implement KeyringLetgoTest;

#
# Keyring's builtins that let the VM go while they compute, and what
# they go on using meanwhile.
#
# The key adts (RSApk, RSAsk, DSApk, DSAsk, EGpk, EGsk and their
# signatures) are filled in by programs, and their numbers are fields:
# any thread with the adt can assign one, which frees the number that
# was there.  The builtins took the numbers' addresses from the fields,
# let the VM go, and gave libsec those addresses for an exponentiation
# that takes milliseconds: a thread assigning a field meanwhile freed
# the number under it.  The result was wrong, or nothing, or the
# emulator's memory in whatever state the allocator's reuse left it
# (the sanitizers' emulator, tools/sanemu, stops at the first read of
# the freed number).  Keyring's auth and writeauthinfo did the same
# with an Authinfo's keys, certificate and numbers.
#
# Here one thread computes with a key while another assigns each of the
# key's fields, over and over, a fresh number equal to the one it had.
# The key never changes, so every result must be the right one.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint, RSApk, RSAsk, RSAsig, DSApk, DSAsk, DSAsig, EGpk, EGsk, EGsig: import kr;

include "testing.m";
	testing: Testing;
	T: import testing;

KeyringLetgoTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_letgo_test.b";

passed := 0;
failed := 0;
skipped := 0;

# how long each key is worked on
Ms: con 1500;

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

# a number equal to x, newly made
copy(x: ref IPint): ref IPint
{
	return x.add(IPint.inttoip(0));
}

hex(s: string): ref IPint
{
	return IPint.strtoip(s, 16);
}

# DSA parameters of 2048 and 256 bits (made by OpenSSL)
dsap: con
	"fbb3c424242b908591bda9992dbc4cb8cae2c63de169907609dac193f6c877f2" +
	"e45b2d765013e0ed3cae5a500ce340b54193d3319133131b149562d2cb79f595" +
	"ceb9bf8a80a605b0b584c340c2f290c6344b8cfe6ab7be1a13e1f880bbfb42a7" +
	"63003f6ac8c5917e6664586686f94ab79e724f8d440c4fd87f28fd3f884d7cec" +
	"c6126b5cd784194be5e5223f44cfbc3ff329b6bd127d9d0ddce77025925960f5" +
	"91bac470b0969cad984e622594e7a4dc5d57a1047f801fee6ab2d996cd20e096" +
	"7a11d1d934928bd69064aa8f5528e1059060415ae60a8d1f273166c7801d1a52" +
	"c956faab433b8df7c3b908ad32ddbf96def4134ac07f972d27536da1d3a4c313";
dsaq: con
	"f18f05983e589167a2a829e834f0c0f1bed1152b58d9d414e92e80162b94c66b";
dsag: con
	"c8d88899b790a30d0885bb49774ee42e0596ed3cd045b18f6bd4f62f36859f27" +
	"66d2aca8f3812cc8e6047b65194c66dfc139888a0db0c4517ce26beb67dfb635" +
	"385a8d464235bc23dd115ef692062d254661bf6b75d6937b395f17aeb807afec" +
	"e9de8912038c4f391216265762930ff2e01e5ab67cc79c816b9388ce29ab3597" +
	"f88a14ce215252433edb49848e3bba6a82a8981435bea8cba4e7822c3ce6bab3" +
	"c3ec5d3b33cd4ee684f27fb52ed54cc414888544a9fe02870f265f8317511a15" +
	"ee82b6249ebdbebbf2110e52fcc6103e57f084752801ea3f0c8419e818c34c90" +
	"a1d73b897637352f755950e571ea00bf06af645f74f9a5f21b2e6b1346f2f137";

stop: int;

# ---- RSA ----

rsachanger(sk: ref RSAsk, sig: ref RSAsig, done: chan of int)
{
	n := 0;
	while(!stop){
		sk.pk.n = copy(sk.pk.n);
		sk.pk.ek = copy(sk.pk.ek);
		sk.dk = copy(sk.dk);
		sk.p = copy(sk.p);
		sk.q = copy(sk.q);
		sk.kp = copy(sk.kp);
		sk.kq = copy(sk.kq);
		sk.c2 = copy(sk.c2);
		sig.n = copy(sig.n);
		# the public key adt itself, with its numbers
		if((n++ & 7) == 0)
			sk.pk = ref RSApk(copy(sk.pk.n), copy(sk.pk.ek));
	}
	done <-= n;
}

testRSA(t: ref T)
{
	sk := RSAsk.gen(2048, 17, 0);
	if(sk == nil)
		t.fatal("RSAsk.gen");
	m := IPint.random(2000, 2000);
	c := sk.pk.encrypt(m);
	sig := sk.sign(m);
	if(c == nil || sig == nil)
		t.fatal("the key does not encrypt or sign");
	t.assert(sk.decrypt(c).eq(m), "decrypt undoes encrypt");
	t.asserteq(sk.pk.verify(sig, m), 1, "the signature verifies");
	want := copy(sig.n);

	stop = 0;
	done := chan of int;
	spawn rsachanger(sk, sig, done);
	bad := 0;
	n := 0;
	what := "";
	for(t0 := sys->millisec(); sys->millisec() - t0 < Ms; n++){
		d := sk.decrypt(c);
		if(d == nil || !d.eq(m)){
			bad++;
			what = "decrypt";
		}
		s := sk.sign(m);
		if(s == nil || !s.n.eq(want)){
			bad++;
			what = "sign";
		}
		e := sk.pk.encrypt(m);
		if(e == nil || !e.eq(c)){
			bad++;
			what = "encrypt";
		}
		if(sk.pk.verify(sig, m) != 1){
			bad++;
			what = "verify";
		}
	}
	stop = 1;
	changes := <-done;
	t.log(sys->sprint("%d rounds of decrypt, sign, encrypt and verify beside %d rounds of assignments", n, changes));
	t.assert(n > 0 && changes > 100, sys->sprint("both threads ran (%d rounds, %d rounds of assignments)", n, changes));
	t.asserteq(bad, 0, "every result is the key's, though its fields were assigned meanwhile (the last wrong: " + what + ")");
}

# ---- DSA ----

dsachanger(sk: ref DSAsk, sig: ref DSAsig, done: chan of int)
{
	n := 0;
	while(!stop){
		sk.pk.p = copy(sk.pk.p);
		sk.pk.q = copy(sk.pk.q);
		sk.pk.alpha = copy(sk.pk.alpha);
		sk.pk.key = copy(sk.pk.key);
		sk.secret = copy(sk.secret);
		sig.r = copy(sig.r);
		sig.s = copy(sig.s);
		if((n++ & 7) == 0)
			sk.pk = ref DSApk(copy(sk.pk.p), copy(sk.pk.q), copy(sk.pk.alpha), copy(sk.pk.key));
	}
	done <-= n;
}

testDSA(t: ref T)
{
	p := hex(dsap);
	q := hex(dsaq);
	g := hex(dsag);
	x := IPint.random(250, 250).add(IPint.inttoip(2));
	sk := ref DSAsk(ref DSApk(p, q, g, g.expmod(x, p)), x);
	m := IPint.random(250, 250);
	sig := sk.sign(m);
	if(sig == nil)
		t.fatal("the key does not sign");
	t.asserteq(sk.pk.verify(sig, m), 1, "the signature verifies");
	other := m.add(IPint.inttoip(1));

	stop = 0;
	done := chan of int;
	spawn dsachanger(sk, sig, done);
	bad := 0;
	n := 0;
	what := "";
	keep := ref DSApk(copy(p), copy(q), copy(g), copy(sk.pk.key));	# a key no thread assigns
	for(t0 := sys->millisec(); sys->millisec() - t0 < Ms; n++){
		s := sk.sign(m);
		if(s == nil || keep.verify(s, m) != 1){
			bad++;
			what = "sign";
		}
		if(sk.pk.verify(sig, m) != 1){
			bad++;
			what = "verify";
		}
		if(sk.pk.verify(sig, other) != 0){
			bad++;
			what = "verify of another message";
		}
	}
	stop = 1;
	changes := <-done;
	t.log(sys->sprint("%d rounds of sign and verify beside %d rounds of assignments", n, changes));
	t.assert(n > 0 && changes > 100, sys->sprint("both threads ran (%d rounds, %d rounds of assignments)", n, changes));
	t.asserteq(bad, 0, "every result is the key's, though its fields were assigned meanwhile (the last wrong: " + what + ")");
}

# ---- ElGamal ----

egchanger(sk: ref EGsk, sig: ref EGsig, done: chan of int)
{
	n := 0;
	while(!stop){
		sk.pk.p = copy(sk.pk.p);
		sk.pk.alpha = copy(sk.pk.alpha);
		sk.pk.key = copy(sk.pk.key);
		sk.secret = copy(sk.secret);
		sig.r = copy(sig.r);
		sig.s = copy(sig.s);
		if((n++ & 7) == 0)
			sk.pk = ref EGpk(copy(sk.pk.p), copy(sk.pk.alpha), copy(sk.pk.key));
	}
	done <-= n;
}

testElGamal(t: ref T)
{
	# RFC 3526's 2048-bit prime is a safe prime, and 4 generates the
	# subgroup of half its order
	(nil, p) := kr->dhparams(2048);
	if(p == nil)
		t.fatal("dhparams");
	alpha := IPint.inttoip(4);
	x := IPint.random(256, 256).add(IPint.inttoip(2));
	sk := ref EGsk(ref EGpk(p, alpha, alpha.expmod(x, p)), x);
	m := IPint.random(250, 250);
	sig: ref EGsig;
	{
		sig = sk.sign(m);
	} exception e {
	"*" =>
		t.fatal("the key does not sign: " + e);
	}
	if(sig == nil)
		t.fatal("the key does not sign");
	t.asserteq(sk.pk.verify(sig, m), 1, "the signature verifies");
	other := m.add(IPint.inttoip(1));

	stop = 0;
	done := chan of int;
	spawn egchanger(sk, sig, done);
	bad := 0;
	n := 0;
	what := "";
	keep := ref EGpk(copy(p), copy(alpha), copy(sk.pk.key));
	for(t0 := sys->millisec(); sys->millisec() - t0 < Ms; n++){
		s: ref EGsig;
		{
			s = sk.sign(m);
		} exception {
		"*" =>
			s = nil;
		}
		if(s == nil || keep.verify(s, m) != 1){
			bad++;
			what = "sign";
		}
		if(sk.pk.verify(sig, m) != 1){
			bad++;
			what = "verify";
		}
		if(sk.pk.verify(sig, other) != 0){
			bad++;
			what = "verify of another message";
		}
	}
	stop = 1;
	changes := <-done;
	t.log(sys->sprint("%d rounds of sign and verify beside %d rounds of assignments", n, changes));
	t.assert(n > 0 && changes > 100, sys->sprint("both threads ran (%d rounds, %d rounds of assignments)", n, changes));
	t.asserteq(bad, 0, "every result is the key's, though its fields were assigned meanwhile (the last wrong: " + what + ")");
}

# ---- auth and writeauthinfo: an Authinfo's fields ----

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");

	ai := ref Keyring->Authinfo;
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}

# every field of the Authinfo assigned an equal value newly made
infochanger(ai: ref Keyring->Authinfo, done: chan of int)
{
	n := 0;
	while(!stop){
		ai.p = copy(ai.p);
		ai.alpha = copy(ai.alpha);
		ai.mysk = kr->strtosk(kr->sktostr(ai.mysk));
		ai.mypk = kr->strtopk(kr->pktostr(ai.mypk));
		ai.spk = kr->strtopk(kr->pktostr(ai.spk));
		ai.cert = kr->strtocert(kr->certtostr(ai.cert));
		n++;
		# auth lets the VM go and takes it back for every message:
		# give it up here, or each of those waits out a time slice
		sys->sleep(0);
	}
	done <-= n;
}

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of (string, array of byte))
{
	c <-= kr->auth(fd, ai, 0);
}

testAuthinfo(t: ref T)
{
	signersk := kr->genSK("ed25519", "signer", 0);
	if(signersk == nil)
		t.fatal("genSK");
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		t.fatal("dhparams");
	alice := mkauthinfo(signersk, signerpk, alpha, p, "alice");
	bob := mkauthinfo(signersk, signerpk, copy(alpha), copy(p), "bob");

	stop = 0;
	done := chan of int;
	spawn infochanger(alice, done);
	bad := 0;
	n := 0;
	what := "";
	for(t0 := sys->millisec(); sys->millisec() - t0 < Ms; n++){
		fds := array[2] of ref Sys->FD;
		if(sys->pipe(fds) < 0)
			t.fatal(sys->sprint("pipe: %r"));
		cb := chan[1] of (string, array of byte);
		spawn authproc(fds[1], bob, cb);
		(who, secret) := kr->auth(fds[0], alice, 0);
		(bwho, bsecret) := <-cb;
		if(secret == nil || bsecret == nil || who != "bob" || bwho != "alice"){
			bad++;
			what = who + " / " + bwho;
		}
		if(kr->writeauthinfo("/tmp/keyring_letgo_test.key", alice) < 0){
			bad++;
			what = sys->sprint("writeauthinfo: %r");
		}else{
			back := kr->readauthinfo("/tmp/keyring_letgo_test.key");
			if(back == nil || back.mypk == nil || back.mypk.owner != "alice"){
				bad++;
				what = "the key file written is not read back";
			}
		}
	}
	stop = 1;
	changes := <-done;
	sys->remove("/tmp/keyring_letgo_test.key");
	t.log(sys->sprint("%d rounds of auth and writeauthinfo beside %d rounds of assignments", n, changes));
	t.assert(n > 0 && changes > 5, sys->sprint("both threads ran (%d rounds, %d rounds of assignments)", n, changes));
	t.asserteq(bad, 0, "every auth succeeded and every key file was whole, though the Authinfo's fields were assigned meanwhile (the last wrong: " + what + ")");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
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

	run("RSA", testRSA);
	run("DSA", testDSA);
	run("ElGamal", testElGamal);
	run("Authinfo", testAuthinfo);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
