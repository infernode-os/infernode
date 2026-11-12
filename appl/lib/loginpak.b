implement Loginpak;

#
# login(6)'s password exchange: PAK over RFC 5114's 2048-bit group with
# a 256-bit subgroup (secstore3's), and ML-KEM (FIPS 203) mixed into
# every hash that follows the exchange.
#
#	user→CA	m = g**x · H(pw), ek
#	CA→user	mu = g**y, ct = Encaps(ek), k = h("server")
#	user→CA	k' = h("client")
#
# where sigma = mu**x = (m · H**-1)**y, ss is the KEM's shared secret,
# and h(label) is SHA-384 over the label and the transcript, sigma, ss
# and H, each field preceded by its length. Each side checks the
# other's proof before it sends anything that depends on its own; the
# session key is h("session").
#
# Why it resists guessing: m hides g**x behind H, and every hash a
# guess could be checked against takes sigma, which needs x or y. An
# attacker who plays either side learns one guess's worth per run. A
# recording later broken by a quantum computer (the discrete log: x,
# y) still needs ss for every hash, and ss needs ML-KEM broken too.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "loginpak.m";

p, q, g, r, one: ref IPint;
Expbits: con 320;	# as secstore3: exponents mod q, a 256-bit q

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("can't load %s: %r", Keyring->PATH);
	# RFC 5114 section 2.3, as secstore3's PAK has it
	p = IPint.strtoip("87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4"+
		"435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D"+
		"830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF"+
		"4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C5"+
		"81B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD83477"+
		"96524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F79"+
		"71506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375"+
		"D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE9"+
		"1E1A1597", 16);
	q = IPint.strtoip("8CF83642A709A097B447997640129DA299B1A47D1EB3750BA308B0FE64F5FBD3", 16);
	g = IPint.strtoip("3FB32C9B73134D0B2E77506660EDBD484CA7B18F21EF205407F4793A"+
		"1A0BA12510DBC15077BE463FFF4FED4AAC0BB555BE3A6C1B0C6B47B1BC3773BF"+
		"7E8C6F62901228F8C28CBB18A55AE31341000A650196F931C77A57F2DDF463E5"+
		"E9EC144B777DE62AAAB8A8628AC376D282D6ED3864E67982428EBC831D14348F"+
		"6F2F9193B5045AF2767164E1DFC967C1FB3F2E55A4BD1BFFE83B9C80D052B985"+
		"D182EA0ADB2A3B7313D3FE14C8484B1E052588B9B7D2BBD2DF016199ECD06E15"+
		"57CD0915B3353BBB64E0EC377FD028370DF92B52C7891428CDC67EB6184B523D"+
		"1DB246C32F63078490F00EF8D647D148D47954515E2327CFEF98C582664B4C0F"+
		"6CC41659", 16);
	one = IPint.inttoip(1);
	(r, nil) = p.sub(one).div(q);
	if(!g.expmod(q, p).eq(one))
		return "loginpak: the group's generator is not of order q";
	return nil;
}

kemname(cnsa: int): string
{
	if(cnsa)
		return "mlkem1024";
	return "mlkem768";
}

pwelem(user: string, pw: array of byte): ref IPint
{
	# SHA-384 in counter mode, 288 bytes: well past p's 2048 bits, so
	# the reduction mod p is near uniform
	seed := fields(Version :: "password" :: user :: nil, pw :: nil);
	buf := array[6*Keyring->SHA384dlen] of byte;
	for(i := 0; i < 6; i++){
		ctr := array[] of {byte i};
		st := kr->sha384(ctr, len ctr, nil, nil);
		kr->sha384(seed, len seed, buf[i*Keyring->SHA384dlen:], st);
	}
	H := IPint.bebytestoip(buf).mod(p).expmod(r, p);
	erase(seed);
	erase(buf);
	if(H.eq(one) || H.eq(IPint.inttoip(0)))
		return g;	# 2**-2000; a fixed element rather than a degenerate one
	return H;
}

# an element of the order-q subgroup other than 1, and below p
ingroup(e: ref IPint): int
{
	if(e == nil || e.cmp(one) <= 0 || e.cmp(p) >= 0)
		return 0;
	return e.expmod(q, p).eq(one);
}

randexp(): ref IPint
{
	x := IPint.random(Expbits, Expbits).mod(q);
	if(x.cmp(one) < 0)
		x = one;
	return x;
}

kemkeygen(kem: string): (array of byte, array of byte)
{
	case kem {
	"mlkem768" =>
		return kr->mlkem768_keygen();
	"mlkem1024" =>
		return kr->mlkem1024_keygen();
	}
	return (nil, nil);
}

kemencaps(kem: string, ek: array of byte): (array of byte, array of byte)
{
	case kem {
	"mlkem768" =>
		if(len ek == Keyring->MLKEM768_PKLEN)
			return kr->mlkem768_encaps(ek);
	"mlkem1024" =>
		if(len ek == Keyring->MLKEM1024_PKLEN)
			return kr->mlkem1024_encaps(ek);
	}
	return (nil, nil);
}

kemdecaps(kem: string, dk, ct: array of byte): array of byte
{
	case kem {
	"mlkem768" =>
		if(len ct == Keyring->MLKEM768_CTLEN)
			return kr->mlkem768_decaps(dk, ct);
	"mlkem1024" =>
		if(len ct == Keyring->MLKEM1024_CTLEN)
			return kr->mlkem1024_decaps(dk, ct);
	}
	return nil;
}

Client.new(kem, user: string, pw: array of byte): (ref Client, string)
{
	(ek, dk) := kemkeygen(kem);
	if(ek == nil)
		return (nil, "unknown key encapsulation: " + kem);
	c := ref Client;
	c.kem = kem;
	c.user = user;
	c.H = pwelem(user, pw);
	c.x = randexp();
	c.m = g.expmod(c.x, p).mul(c.H).mod(p).iptob64();
	c.ek = ek;
	c.dk = dk;
	return (c, nil);
}

Client.respond(c: self ref Client, hexmu: string, ct, k: array of byte): (array of byte, string)
{
	mu := IPint.b64toip(hexmu);
	if(!ingroup(mu))
		return (nil, "the signer's mu is not in the group");
	ss := kemdecaps(c.kem, c.dk, ct);
	erase(c.dk);
	if(ss == nil)
		return (nil, "the signer's key encapsulation is the wrong length");
	sigma := mu.expmod(c.x, p).iptob64();
	t := transcript(c.kem, c.user, c.m, hexmu, c.ek, ct, sigma, ss, c.H.iptob64());
	if(!same(h("server", t), k)){
		erase(t);
		erase(ss);
		return (nil, "name or secret incorrect");
	}
	kp := h("client", t);
	c.session = h("session", t);
	erase(t);
	erase(ss);
	return (kp, nil);
}

Server.new(kem, user: string, H: ref IPint, hexm: string, ek: array of byte): (ref Server, string, array of byte, array of byte, string)
{
	m := IPint.b64toip(hexm);
	# m's membership does not depend on the password (H is in the
	# group), so refusing a bad one tells nothing; m = 0 (or p) would
	# make sigma 0 and k a function of H alone, to be guessed against
	if(!ingroup(m))
		return (nil, nil, nil, nil, "the client's m is not in the group");
	(ct, ss) := kemencaps(kem, ek);
	if(ct == nil)
		return (nil, nil, nil, nil, "the client's key encapsulation is not " + kem);
	if(H == nil)
		H = g.expmod(randexp(), p);
	y := randexp();
	hexmu := g.expmod(y, p).iptob64();
	sigma := m.mul(H.invert(p)).mod(p).expmod(y, p).iptob64();
	t := transcript(kem, user, hexm, hexmu, ek, ct, sigma, ss, H.iptob64());
	s := ref Server;
	s.kem = kem;
	k := h("server", t);
	s.kprime = h("client", t);
	s.session = h("session", t);
	erase(t);
	erase(ss);
	return (s, hexmu, ct, k, nil);
}

Server.check(s: self ref Server, kprime: array of byte): int
{
	ok := same(s.kprime, kprime);
	if(!ok)
		erase(s.session);
	return ok;
}

transcript(kem, user, m, mu: string, ek, ct: array of byte, sigma: string, ss: array of byte, H: string): array of byte
{
	return fields(Version :: kem :: user :: m :: mu :: nil, ek :: ct :: array of byte sigma :: ss :: array of byte H :: nil);
}

h(label: string, t: array of byte): array of byte
{
	l := array of byte label;
	st := kr->sha384(l, len l, nil, nil);
	d := array[Keyring->SHA384dlen] of byte;
	kr->sha384(t, len t, d, st);
	return d;
}

# each field as four bytes of its length, big-endian, then itself
fields(ss: list of string, bs: list of array of byte): array of byte
{
	all: list of array of byte;
	for(; ss != nil; ss = tl ss)
		all = array of byte hd ss :: all;
	for(; bs != nil; bs = tl bs)
		all = hd bs :: all;
	n := 0;
	for(l := all; l != nil; l = tl l)
		n += 4 + len hd l;
	out := array[n] of byte;
	# all is reversed; fill from the end
	o := n;
	for(l = all; l != nil; l = tl l){
		f := hd l;
		o -= len f;
		out[o:] = f;
		o -= 4;
		v := len f;
		out[o] = byte (v>>24);
		out[o+1] = byte (v>>16);
		out[o+2] = byte (v>>8);
		out[o+3] = byte v;
	}
	return out;
}

# equal, in time independent of where they differ
same(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

erase(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}
