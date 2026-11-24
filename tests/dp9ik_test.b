implement Dp9ikTest;

#
# dp9ik(2) against the answers 9front 11952 gives (tests/host/dp9ik/
# 9front-vectors.txt, made on 9front by vecgen.c in that directory):
# the AES key from a password, the PAK hash, both sides' public keys and
# shared keys from the scalars recorded there, a form1 ticket and
# authenticator byte for byte; then what a peer can send that is not one:
# a public key out of range or off the curve, a ticket or authenticator
# changed, cut, of another type, under another key.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "testing.m";
	testing: Testing;
	T: import testing;

include "keyring.m";
include "dp9ik.m";
	dp: Dp9ik;
	Pak, Ticket, Authenticator, Ticketreq: import dp;

Dp9ikTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dp9ik_test.b";
VECTORS: con "/tests/host/dp9ik/9front-vectors.txt";

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

Case: adt {
	attrs: list of (string, string);
	get: fn(c: self ref Case, k: string): string;
};

Case.get(c: self ref Case, k: string): string
{
	for(l := c.attrs; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return nil;
}

cases: list of ref Case;

readvectors(): string
{
	b := bufio->open(VECTORS, Bufio->OREAD);
	if(b == nil)
		return sys->sprint("cannot open %s: %r", VECTORS);
	cur: ref Case;
	rev: list of ref Case;
	while((s := b.gets('\n')) != nil){
		if(s[len s - 1] == '\n')
			s = s[0:len s - 1];
		if(s == nil || (len s >= 2 && s[0:2] == "@@"))
			continue;
		for(i := 0; i < len s && s[i] != ' '; i++)
			;
		k := s[0:i];
		v := "";
		if(i < len s)
			v = s[i+1:];
		if(k == "case"){
			cur = ref Case(nil);
			rev = cur :: rev;
		}
		if(cur != nil)
			cur.attrs = (k, v) :: cur.attrs;
	}
	for(; rev != nil; rev = tl rev)
		cases = hd rev :: cases;
	return nil;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	a := array[len s / 2] of byte;
	for(i := 0; i < len a; i++){
		(v, nil) := toint(s[2*i:2*i+2]);
		a[i] = byte v;
	}
	return a;
}

toint(s: string): (int, string)
{
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'0' to '9' =>	v = v*16 + c - '0';
		'a' to 'f' =>	v = v*16 + c - 'a' + 10;
		* =>	return (0, s);
		}
	}
	return (v, nil);
}

fill(n: int, b: int): array of byte
{
	return array[n] of {* => byte b};
}

testVectors(t: ref T)
{
	if(cases == nil)
		t.fatal("no vectors");
	for(l := cases; l != nil; l = tl l){
		c := hd l;
		u := c.get("user");
		aes := dp->passtoaeskey(array of byte c.get("password"));
		t.assertseq(hex(aes), c.get("aes"), u+": aes key");
		ph := dp->authpakhash(aes, u);
		t.assertseq(hex(ph), c.get("pakhash"), u+": pakhash");
		pc := Pak.new(ph, 1, unhex(c.get("xc")));
		ps := Pak.new(ph, 0, unhex(c.get("xs")));
		t.assertseq(hex(pc.y), c.get("yc"), u+": client public key");
		t.assertseq(hex(ps.y), c.get("ys"), u+": server public key");
		yc := pc.y;
		ys := ps.y;
		kc := pc.finish(ys);
		ks := ps.finish(yc);
		t.assertseq(hex(kc), c.get("pakkeyc"), u+": client pakkey");
		t.assertseq(hex(ks), c.get("pakkeys"), u+": server pakkey");
		tk := ref Ticket(Dp9ik->AuthTc, fill(8, 'c'), u, u, fill(32, 16r5a));
		tb := dp->sealticket(tk, kc);
		t.assertseq(hex(tb), c.get("ticket"), u+": form1 ticket");
		au := ref Authenticator(Dp9ik->AuthAc, fill(8, 'c'), fill(32, 16r33));
		ab := dp->sealauth(au, fill(32, 16r5a));
		t.assertseq(hex(ab), c.get("authenticator"), u+": form1 authenticator");

		(tk2, err) := dp->openticket(tb, kc);
		if(tk2 == nil)
			t.fatal(u+": ticket does not open: "+err);
		t.assertseq(tk2.cuid, u, u+": ticket's cuid");
		t.assertseq(hex(tk2.chal), hex(tk.chal), u+": ticket's challenge");
		t.assertseq(hex(tk2.key), hex(tk.key), u+": ticket's key");
		t.asserteq(tk2.num, Dp9ik->AuthTc, u+": ticket's type");
	}
}

# a random exchange agrees with itself, and each side's key is the other's
testExchange(t: ref T)
{
	ph := dp->authpakhash(dp->passtoaeskey(array of byte "pw"), "bob");
	for(i := 0; i < 3; i++){
		c := Pak.new(ph, 1, nil);
		s := Pak.new(ph, 0, nil);
		if(c == nil || s == nil)
			t.fatal("Pak.new with a random scalar gave nil");
		kc := c.finish(s.y);
		ks := s.finish(c.y);
		t.assertseq(hex(kc), hex(ks), "both sides' keys");
	}
	# another password: other keys
	ph2 := dp->authpakhash(dp->passtoaeskey(array of byte "pw2"), "bob");
	c := Pak.new(ph, 1, nil);
	s := Pak.new(ph2, 0, nil);
	t.assert(hex(c.finish(s.y)) != hex(s.finish(c.y)), "different passwords, different keys");
	# a scalar is used once
	c = Pak.new(ph, 1, nil);
	s = Pak.new(ph, 0, nil);
	t.assert(c.finish(s.y) != nil, "first finish");
	t.assert(c.finish(s.y) == nil, "second finish refused");
}

testBadKeys(t: ref T)
{
	ph := dp->authpakhash(dp->passtoaeskey(array of byte "pw"), "bob");
	bad := array[] of {
		fill(56, 16rff),	# past P
		fill(55, 1),		# short
		fill(57, 0),		# long
	};
	for(i := 0; i < len bad; i++){
		c := Pak.new(ph, 1, nil);
		t.assert(c.finish(bad[i]) == nil, sys->sprint("public key %d refused", i));
	}
	# a value in range that decodes to no point (more than half are not)
	nonpt := 0;
	for(i = 1; i < 40; i++){
		y := fill(56, 0);
		y[55] = byte i;
		c := Pak.new(ph, 1, nil);
		if(c.finish(y) == nil)
			nonpt++;
	}
	t.assert(nonpt > 0, "values that are no point refused");
	t.log(sys->sprint("%d of 39 small values no point", nonpt));
	t.assert(Pak.new(ph[1:], 1, nil) == nil, "short pakhash refused");
}

testForm1Refused(t: ref T)
{
	key := fill(32, 7);
	tk := ref Ticket(Dp9ik->AuthTc, fill(8, 'x'), "glenda", "bootes", fill(32, 9));
	tb := dp->sealticket(tk, key);
	t.asserteq(len tb, Dp9ik->TICKETLEN, "ticket length");
	(ok, nil) := dp->openticket(tb, key);
	t.assert(ok != nil, "ticket opens");
	for(i := 0; i < len tb; i += 7){
		b := array[len tb] of byte;
		b[0:] = tb;
		b[i] ^= byte 1;
		(r, nil) := dp->openticket(b, key);
		t.assert(r == nil, sys->sprint("byte %d changed refused", i));
	}
	(r, nil) := dp->openticket(tb[0:len tb - 1], key);
	t.assert(r == nil, "cut ticket refused");
	(r, nil) = dp->openticket(tb, fill(32, 8));
	t.assert(r == nil, "another key refused");
	# an authenticator is no ticket, and the other way round
	ab := dp->sealauth(ref Authenticator(Dp9ik->AuthAc, fill(8, 1), fill(32, 2)), key);
	(r, nil) = dp->openticket(ab, key);
	t.assert(r == nil, "authenticator as ticket refused");
	(ra, nil) := dp->openauth(tb, key);
	t.assert(ra == nil, "ticket as authenticator refused");
	(ra, nil) = dp->openauth(ab, key);
	t.assert(ra != nil && ra.num == Dp9ik->AuthAc, "authenticator opens");
	t.assert(dp->sealticket(ref Ticket(99, fill(8, 0), "", "", fill(32, 0)), key) == nil, "unknown type not sealed");
}

testTicketreq(t: ref T)
{
	tr := ref Ticketreq(Dp9ik->AuthPAK, "bootes", "9front", fill(8, 3), "", "glenda");
	b := tr.pack();
	t.asserteq(len b, Dp9ik->TICKREQLEN, "ticketreq length");
	(r, err) := Ticketreq.unpack(b);
	if(r == nil)
		t.fatal(err);
	t.assertseq(r.authid, "bootes", "authid");
	t.assertseq(r.authdom, "9front", "authdom");
	t.assertseq(r.uid, "glenda", "uid");
	t.asserteq(r.rtype, Dp9ik->AuthPAK, "type");
	# names longer than their fields are cut and still end in a nil
	tr.authid = "a-name-that-is-longer-than-twenty-eight-bytes";
	(r, nil) = Ticketreq.unpack(tr.pack());
	t.asserteq(len r.authid, Dp9ik->ANAMELEN-1, "long name cut");
	(r, nil) = Ticketreq.unpack(b[0:len b - 1]);
	t.assert(r == nil, "short ticketreq refused");
}

testSecret(t: ref T)
{
	s := dp->sessionsecret(fill(64, 1), fill(32, 2));
	t.asserteq(len s, Dp9ik->SECRETLEN, "secret length");
	# HKDF-SHA256 with salt 01*64, info "Plan 9 session secret", ikm 02*32,
	# its first 16 bytes from Python's hmac
	t.assertseq(hex(s[0:16]), SECRET16, "secret's first bytes");
}

SECRET16: con "caf4ab2912a44aef477133b7c7fc4cec";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	dp = load Dp9ik Dp9ik->PATH;
	if(testing == nil || dp == nil || bufio == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	err := dp->init();
	if(err != nil){
		sys->fprint(sys->fildes(2), "dp9ik: %s\n", err);
		raise "fail:init";
	}
	err = readvectors();
	if(err != nil)
		sys->fprint(sys->fildes(2), "%s\n", err);

	run("Vectors", testVectors);
	run("Exchange", testExchange);
	run("BadKeys", testBadKeys);
	run("Form1Refused", testForm1Refused);
	run("Ticketreq", testTicketreq);
	run("Secret", testSecret);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
