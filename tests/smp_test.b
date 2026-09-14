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
	run("Pairing", testPairing);
	run("Refusals", testRefusals);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
