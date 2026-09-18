implement SmpTest;

#
# smp(2): the cryptographic functions against the specification's own
# sample data (Vol 3 Part H, 2.2.3 and 2.2.4), and a legacy Just Works
# pairing run against a responder scripted here with the same
# functions -- the two confirm values check out, both sides derive
# the same STK, and the keys the responder distributes come back.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "bthci.m";
	bthci: Bthci;
include "smp.m";
	smp: Smp;
	Pairing, Ev: import smp;
include "testing.m";
	testing: Testing;
	T: import testing;

SmpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/smp_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip" => ;
	"*" => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# a specification value, written most significant first, as the wire
# carries it: least significant first
le(hex: string): array of byte
{
	a := bthci->parsekey(hex);
	if(a == nil){
		# parsekey wants 32 digits; shorter values by hand
		n := len hex / 2;
		a = array[n] of byte;
		for(i := 0; i < n; i++)
			a[i] = byte hexval(hex[2*i:2*i+2]);
	}
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[len a - 1 - i];
	return r;
}

hexval(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d := 0;
		if(c >= '0' && c <= '9') d = c - '0';
		else if(c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F') d = c - 'A' + 10;
		v = v*16 + d;
	}
	return v;
}

hex(a: array of byte): string
{
	return bthci->hex(a);
}

testVectors(t: ref T)
{
	k := array[16] of { * => byte 0 };
	# 2.2.3: c1 sample
	r := le("5783D52156AD6F0E6388274EC6702EE0");
	preq := le("07071000000101");
	pres := le("05000800000302");
	ia := le("A1A2A3A4A5A6");
	ra := le("B1B2B3B4B5B6");
	c := smp->c1(k, r, preq, pres, 1, ia, 0, ra);
	t.assertseq(hex(c), hex(le("1e1e3fef878988ead2a74dc5bef13b86")), "c1 matches the specification's sample");
	# 2.2.4: s1 sample
	r1 := le("000F0E0D0C0B0A091122334455667788");
	r2 := le("010203040506070899AABBCCDDEEFF00");
	s := smp->s1(k, r1, r2);
	t.assertseq(hex(s), hex(le("9a1fe1f0e8b0f49b5b4216ae796da062")), "s1 matches the specification's sample");
	# e with a nonzero key is AES-128: FIPS-197 C.1
	fk := le("000102030405060708090a0b0c0d0e0f");
	fp := le("00112233445566778899aabbccddeeff");
	t.assertseq(hex(smp->e(fk, fp)), hex(le("69c4e0d86a7b0430d8cdb78070b4c55a")), "e is AES-128 (FIPS-197 C.1)");
	# Vol 6 Part B 1.3.2.3 sample: IRK, prand 0x708194, hash 0x0dfbaa
	irk := le("ec0234a357c8ad05341010a60a397d9b");
	t.assert(smp->resolves(irk, le("7081940dfbaa")), "the specification's sample private address resolves with its IRK");
	t.assert(!smp->resolves(irk, le("7081940dfbab")), "and not with the hash off by one");
	t.assert(!smp->resolves(irk, le("c8f3e806558b")), "and a static address never does");
}

# LE Secure Connections: Vol 3 Part H Appendix D's sample data, and
# RFC 4493's for the CMAC beneath it
testSecureConnections(t: ref T)
{
	# RFC 4493 section 4: the empty message, one block, 40 bytes, four blocks
	ck := be("2b7e151628aed2a6abf7158809cf4f3c");
	t.assertseq(hex(smp->cmac(ck, array[0] of byte)), hex(be("bb1d6929e95937287fa37d129b756746")), "AES-CMAC of the empty message (RFC 4493 example 1)");
	t.assertseq(hex(smp->cmac(ck, be("6bc1bee22e409f96e93d7e117393172a"))), hex(be("070a16b46b4d4144f79bdd9dd04a287c")), "of one block (example 2)");
	t.assertseq(hex(smp->cmac(ck, be("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"))), hex(be("dfa66747de9ae63030ca32611497c827")), "of 40 bytes (example 3)");

	# D.1: the two P-256 key pairs and what they agree on
	pa := be("3f49f6d4a3c55f3874c9b3e3d2103f504aff607beb40b7995899b8a6cd3c1abd");
	pax := le("20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6");
	pay := le("dc809c49652aeb6d63329abf5a52155c766345c28fed3024741c8ed01589d28b");
	pb := be("55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd");
	pbx := le("1ea1f0f01faf1d9609592284f19e4c0047b58afd8615a69f559077b22faaa190");
	pby := le("4c55f33e429dad377356703a9ab85160472d1130e28e36765f89aff915b1214a");
	dh := le("ec0234a357c8ad05341010a60a397d9b99796b13b4f866f1868d34f373bfa698");
	t.assertseq(hex(smp->dhkey(pa, pbx, pby)), hex(dh), "A's private key and B's public key give the sample DHKey (D.1)");
	t.assertseq(hex(smp->dhkey(pb, pax, pay)), hex(dh), "and B's with A's the same");
	bad := le("4c55f33e429dad377356703a9ab85160472d1130e28e36765f89aff915b1214b");
	t.assert(smp->dhkey(pa, pbx, bad) == nil, "a point that is not on the curve gives no key");
	(priv, x, y) := smp->sckeys();
	t.assert(len priv == 32 && len x == 32 && len y == 32, "a fresh key pair is 32 bytes each way");
	(priv2, x2, y2) := smp->sckeys();
	t.assertseq(hex(smp->dhkey(priv, x2, y2)), hex(smp->dhkey(priv2, x, y)), "and two fresh pairs agree on a secret");

	# D.2: f4
	u := le("20b003d2f297be2c5e2c83a7e9f9a5b9eff49111acf4fddbcc0301480e359de6");
	v := le("55188b3d32f6bb9a900afcfbeed4e72a59cb9ac2f19d7cfb6b4fdd49f47fc5fd");
	xx := le("d5cb8454d177733effffb2ec712baeab");
	t.assertseq(hex(smp->f4(u, v, xx, 0)), hex(le("f2c916f107a9bd1cf1eda1bea974872d")), "f4 matches the sample (D.2)");

	# D.3: f5
	n1 := le("d5cb8454d177733effffb2ec712baeab");
	n2 := le("a6e8e7cc25a75f6e216583f7ff3dc4cf");
	a1 := le("0056123737bfce");
	a2 := le("00a713702dcfc1");
	(mackey, ltk) := smp->f5(dh, n1, n2, a1, a2);
	t.assertseq(hex(mackey), hex(le("2965f176a1084a02fd3f6a20ce636e20")), "f5's MacKey matches the sample (D.3)");
	t.assertseq(hex(ltk), hex(le("6986791169d7cd23980522b594750a38")), "and its LTK");

	# D.4: f6
	r := le("12a3343bb453bb5408da42d20c2d0fc8");
	iocap := le("010102");
	t.assertseq(hex(smp->f6(mackey, n1, n2, r, iocap, a1, a2)), hex(le("e3c473989cd0e8c5d26c0b09da958f61")), "f6 matches the sample (D.4)");

	# D.5: g2 is 0x2f9ed5ba, and the six digits are that mod a million
	t.asserteq(smp->g2(u, v, n1, n2), 16r2f9ed5ba % 1000000, "g2 matches the sample (D.5)");
}

# a hex string as the bytes it spells, most significant first
be(h: string): array of byte
{
	a := le(h);
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[len a - 1 - i];
	return r;
}

# the responder, scripted: it answers as a Just Works peripheral with
# bonding and both key kinds to give
Responder: adt {
	preq, pres: array of byte;
	srand:	array of byte;
	mconfirm: array of byte;
	ltk:	array of byte;
	tk:	array of byte;
};

testPairing(t: ref T)
{
	ia := le("A1A2A3A4A5A6");
	ra := le("C1C2C3C4C5C6");
	mrand := le("00112233445566778899aabbccddeeff");
	srand := le("ffeeddccbbaa99887766554433221100");
	tk := array[16] of { * => byte 0 };
	resp := ref Responder(nil, nil, srand, nil, le("0123456789abcdef0123456789abcdef"), tk);

	p := Pairing.new(0, ia, 1, ra, mrand);
	evs := p.start();
	t.asserteq(len evs, 1, "start sends one PDU");
	req := sendof(hd evs);
	t.asserteq(int req[0], Smp->Cpairreq, "which is a Pairing Request");
	t.asserteq(int req[1], Smp->IOnone, "with no IO capability: Just Works");
	t.asserteq(int req[6], Smp->Kenc | Smp->Kid, "asking for the encryption and identity keys");
	resp.preq = req[0:7];
	# the response: keyboard-only peer, bonding, 16-byte key, will give enc and id
	pres := array[] of { byte Smp->Cpairrsp, byte Smp->IOkeyboardonly, byte 0, byte Smp->Abonding, byte 16, byte 0, byte (Smp->Kenc | Smp->Kid) };
	resp.pres = pres;
	evs = p.recv(pres);
	mconf := sendof(hd evs);
	t.asserteq(int mconf[0], Smp->Cconfirm, "the response is answered with our confirm");
	resp.mconfirm = mconf[1:17];
	# the responder's confirm, from its own random with the same function
	sconf := smp->c1(tk, srand, resp.preq, pres[0:7], 0, ia, 1, ra);
	evs = p.recv(withcode(Smp->Cconfirm, sconf));
	mr := sendof(hd evs);
	t.asserteq(int mr[0], Smp->Crandom, "their confirm is answered with our random");
	t.assertseq(hex(mr[1:17]), hex(mrand), "which is the random we were given");
	# the responder checks our confirm against our random, as we will theirs
	t.assertseq(hex(smp->c1(tk, mr[1:17], resp.preq, pres[0:7], 0, ia, 1, ra)), hex(resp.mconfirm), "the responder finds our confirm good");
	evs = p.recv(withcode(Smp->Crandom, srand));
	t.asserteq(len evs, 1, "their random yields one event");
	stk: array of byte;
	pick e := hd evs {
	Encrypt =>	stk = e.key;
	* =>		t.fatal("expected Encrypt");
	}
	t.assertseq(hex(stk), hex(smp->s1(tk, srand, mrand)), "the STK is s1(TK, Srand, Mrand), the same at both ends");
	t.asserteq(p.state, Smp->Waitencrypt, "waiting for the link to encrypt");
	# encrypted: the peer distributes its keys
	evs = p.encrypted();
	t.asserteq(len evs, 0, "nothing to say until the keys come");
	evs = p.recv(withcode(Smp->Cencinfo, resp.ltk));
	t.asserteq(len evs, 0, "the LTK alone is not the end");
	mid := array[11] of byte;
	mid[0] = byte Smp->Cmasterid;
	mid[1] = byte 16r34; mid[2] = byte 16r12;
	for(i := 3; i < 11; i++)
		mid[i] = byte i;
	evs = p.recv(mid);
	t.asserteq(len evs, 0, "nor the master identification, with identity still to come");
	evs = p.recv(withcode(Smp->Cidinfo, le("aaaabbbbccccddddeeeeffff00001111")));
	idaddr := array[8] of byte;
	idaddr[0] = byte Smp->Cidaddr;
	idaddr[1] = byte 0;
	idaddr[2:] = ra;
	evs = p.recv(idaddr);
	t.asserteq(len evs, 1, "the identity address completes the distribution");
	pick e := hd evs {
	Paired =>
		t.assertseq(hex(e.keys.ltk), hex(resp.ltk), "the LTK is what the peer gave");
		t.asserteq(e.keys.ediv, 16r1234, "with its EDIV");
		t.asserteq(len e.keys.rand, 8, "and Rand");
		t.assert(e.keys.irk != nil, "and the IRK");
		t.assertseq(e.keys.idaddr, bthci->bdaddr(ra, 0), "and the identity address");
	* =>
		t.error("expected Paired");
	}
	t.asserteq(p.state, Smp->Done, "and the pairing is done");
}

testRefusals(t: ref T)
{
	ia := le("A1A2A3A4A5A6");
	ra := le("C1C2C3C4C5C6");
	mrand := le("00112233445566778899aabbccddeeff");
	# a wrong confirm
	p := Pairing.new(0, ia, 1, ra, mrand);
	p.start();
	pres := array[] of { byte Smp->Cpairrsp, byte Smp->IOnone, byte 0, byte Smp->Abonding, byte 16, byte 0, byte 0 };
	p.recv(pres);
	p.recv(withcode(Smp->Cconfirm, array[16] of { * => byte 16r55 }));
	evs := p.recv(withcode(Smp->Crandom, array[16] of { * => byte 16raa }));
	t.asserteq(len evs, 2, "a confirm that does not check out is answered and reported");
	pick e := hd tl evs {
	Failed =>	t.asserteq(e.reason, Smp->Fconfirmfailed, "as 'confirm value failed'");
	* =>		t.error("expected Failed");
	}
	t.asserteq(p.state, Smp->Failed, "and the pairing is over");
	# the peer gives up
	p = Pairing.new(0, ia, 1, ra, mrand);
	p.start();
	evs = p.recv(array[] of { byte Smp->Cfailed, byte Smp->Fnotsupported });
	t.asserteq(len evs, 1, "a Pairing Failed from the peer is one event");
	pick e := hd evs {
	Failed =>	t.assertseq(e.text, "pairing not supported", "with its reason in words");
	* =>		t.error("expected Failed");
	}
	# no keys to come: the STK is the key, marked unstorable
	p = Pairing.new(0, ia, 1, ra, mrand);
	p.start();
	pres = array[] of { byte Smp->Cpairrsp, byte Smp->IOnone, byte 0, byte 0, byte 16, byte 0, byte 0 };
	p.recv(pres);
	sconf := smp->c1(array[16] of { * => byte 0 }, mrand, p.preq, pres[0:7], 0, ia, 1, ra);
	p.recv(withcode(Smp->Cconfirm, sconf));
	p.recv(withcode(Smp->Crandom, mrand));
	evs = p.encrypted();
	t.asserteq(len evs, 1, "with nothing to distribute, encryption completes the pairing");
	pick e := hd evs {
	Paired =>	t.asserteq(e.keys.ediv, 0, "and the key is the STK, EDIV 0");
	* =>		t.error("expected Paired");
	}
}

sendof(e: ref Ev): array of byte
{
	pick x := e {
	Send =>	return x.pdu;
	}
	return nil;
}

withcode(code: int, v: array of byte): array of byte
{
	r := array[1 + len v] of byte;
	r[0] = byte code;
	r[1:] = v;
	return r;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	keyring = load Keyring Keyring->PATH;
	bthci = load Bthci Bthci->PATH;
	bthci->init();
	smp = load Smp Smp->PATH;
	smp->init(bthci, keyring);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Vectors", testVectors);
	run("SecureConnections", testSecureConnections);
	run("Pairing", testPairing);
	run("Refusals", testRefusals);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
