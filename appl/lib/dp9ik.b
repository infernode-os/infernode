implement Dp9ik;

#
# dp9ik(2), 9front's authentication, from 9front's libauthsrv
# (authpak.c and the .mp files it is made of, passtokey.c, form1.c,
# convTR2M.c, convM2T.c, convA2M.c).  tests/host/dp9ik/ref.py is the same
# in Python; both are checked against answers 9front gives.
#
# The arithmetic is IPint's, which is not constant time.  The scalars are
# a session's own (random each time); the hash of the password is mapped
# to the curve once per login.  See the BUGS section of dp9ik(2).
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "dp9ik.m";

P, A, D, GX, GY, Pm1h, Pp1q, Pm3q, Pm2, Zero, One, Two, Nsq: ref IPint;

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("cannot load Keyring: %r");
	Zero = IPint.inttoip(0);
	One = IPint.inttoip(1);
	Two = IPint.inttoip(2);
	P = One.shl(448).sub(One.shl(224)).sub(One);
	A = One;
	D = P.sub(IPint.inttoip(39081));
	GX = IPint.strtoip("117812161263436946737282484343310064665180535357016373416879082147939404277809514858788439644911793978499419995990477371552926308078495", 10);
	GY = IPint.inttoip(19);
	Pm1h = P.sub(One).shr(1);
	Pp1q = P.add(One).shr(2);
	Pm3q = P.sub(IPint.inttoip(3)).shr(2);
	Pm2 = P.sub(Two);
	if(GX == nil)
		return "dp9ik: bad base point";
	# the smallest non-square, as spake2ee_h2P finds it
	n := 2;
	while(legendre(IPint.inttoip(n)) != -1)
		n++;
	Nsq = IPint.inttoip(n);
	return nil;
}

# field arithmetic mod P, results in 0..P-1
md(a: ref IPint): ref IPint
{
	r := a.mod(P);
	if(r.cmp(Zero) < 0)
		r = r.add(P);
	return r;
}
fmul(a, b: ref IPint): ref IPint	{ return md(a.mul(b)); }
fadd(a, b: ref IPint): ref IPint	{ return md(a.add(b)); }
fsub(a, b: ref IPint): ref IPint	{ return md(a.sub(b)); }
fneg(a: ref IPint): ref IPint	{ return md(Zero.sub(a)); }
finv(a: ref IPint): ref IPint	{ return md(a).expmod(Pm2, P); }

legendre(a: ref IPint): int
{
	r := md(a).expmod(Pm1h, P);
	if(r.eq(Zero))
		return 0;
	if(r.eq(One))
		return 1;
	return -1;
}

msqrt(a: ref IPint): ref IPint
{
	a = md(a);
	if(a.eq(Zero) || legendre(a) != 1)
		return Zero;
	return a.expmod(Pp1q, P);	# P = 3 mod 4
}

misqrt(a: ref IPint): ref IPint
{
	return md(a).expmod(Pm3q, P);
}

Pt: adt {
	x, y, z, t: ref IPint;
};

edadd(p, q: ref Pt): ref Pt
{
	a := fmul(p.x, q.x);
	b := fmul(p.y, q.y);
	c := fmul(fmul(D, p.t), q.t);
	d := fmul(p.z, q.z);
	e := fsub(fsub(fmul(fadd(p.x, p.y), fadd(q.x, q.y)), a), b);
	f := fsub(d, c);
	g := fadd(d, c);
	h := fsub(b, fmul(A, a));
	return ref Pt(fmul(e, f), fmul(g, h), fmul(f, g), fmul(e, h));
}

bit(s: array of byte, i: int): int
{
	n := len s;
	if(i/8 >= n)
		return 0;
	return (int s[n-1-i/8] >> (i%8)) & 1;
}

# as edwards.mp: as many steps as P has bits less one, the sum chosen
# by the scalar's bit at each
edscale(s: array of byte, p: ref Pt): ref Pt
{
	q2 := p;
	q3 := ref Pt(Zero, One, One, Zero);
	if(bit(s, 0))
		q3 = p;
	for(i := 1; i < 448; i++){
		q2 = edadd(q2, q2);
		q4 := edadd(q2, q3);
		if(bit(s, i))
			q3 = q4;
	}
	return q3;
}

decafneg(n, r: ref IPint): ref IPint
{
	if(md(n).cmp(Pm1h) > 0)
		return fneg(r);
	return r;
}

decafencode(p: ref Pt): ref IPint
{
	amd := fsub(A, D);
	r := misqrt(fmul(fmul(amd, fadd(p.z, p.y)), fsub(p.z, p.y)));
	u := fmul(amd, r);
	r = decafneg(fmul(fmul(fneg(Two), u), p.z), r);
	s := fmul(fmul(u, fadd(fmul(r, fsub(fmul(fmul(A, p.z), p.x), fmul(D, fmul(p.y, p.t)))), p.y)), finv(A));
	return decafneg(s, s);
}

decafdecode(s: ref IPint): ref Pt
{
	if(s.cmp(Pm1h) > 0)
		return nil;
	ss := fmul(s, s);
	z := fadd(One, fmul(A, ss));
	u := fsub(fmul(z, z), fmul(fmul(IPint.inttoip(4), D), ss));
	v := fmul(u, ss);
	if(!v.eq(Zero)){
		ok := msqrt(v);
		if(ok.eq(Zero))
			return nil;
		v = finv(ok);
	}
	v = decafneg(fmul(u, v), v);
	w := fmul(fmul(v, s), fsub(Two, z));
	if(s.eq(Zero))
		w = fadd(w, One);
	x := fmul(Two, s);
	return ref Pt(x, fmul(w, z), z, fmul(w, x));
}

elligator2(r0: ref IPint): ref Pt
{
	n := Nsq;
	r := fmul(fmul(n, r0), r0);
	dd := fmul(fadd(fmul(D, r), fsub(A, D)), fsub(fsub(fmul(D, r), fmul(A, r)), D));
	a2d := fsub(A, fmul(Two, D));
	nn := fmul(fadd(r, One), a2d);
	nd := fmul(nn, dd);
	c, e: ref IPint;
	if(nd.eq(Zero)){
		c = One;
		e = Zero;
	}else{
		e = msqrt(nd);
		if(!e.eq(Zero)){
			c = One;
			e = finv(e);
		}else{
			c = fneg(One);
			e = fmul(fmul(n, r0), misqrt(fmul(n, nd)));
		}
	}
	s := fmul(fmul(c, nn), e);
	ae := fmul(a2d, e);
	t := fsub(fmul(fmul(fmul(fneg(c), nn), fsub(r, One)), fmul(ae, ae)), One);
	ass := fmul(fmul(A, s), s);
	return ref Pt(fmul(fmul(Two, s), t), fmul(fsub(One, ass), fadd(One, ass)),
		fmul(fadd(One, ass), t), fmul(fmul(Two, s), fsub(One, ass)));
}

# big-endian, exactly n bytes
be(x: ref IPint, n: int): array of byte
{
	b := x.iptobebytes();
	out := array[n] of {* => byte 0};
	if(len b > n)
		b = b[len b - n:];
	out[n-len b:] = b;
	return out;
}

bint(b: array of byte): ref IPint
{
	return IPint.bebytestoip(b);
}

ptbytes(p: ref Pt): array of byte
{
	out := array[PAKPLEN] of byte;
	out[0:] = be(p.x, PAKSLEN);
	out[PAKSLEN:] = be(p.y, PAKSLEN);
	out[2*PAKSLEN:] = be(p.z, PAKSLEN);
	out[3*PAKSLEN:] = be(p.t, PAKSLEN);
	return out;
}

bytespt(b: array of byte): ref Pt
{
	return ref Pt(bint(b[0:PAKSLEN]), bint(b[PAKSLEN:2*PAKSLEN]),
		bint(b[2*PAKSLEN:3*PAKSLEN]), bint(b[3*PAKSLEN:4*PAKSLEN]));
}

sha256(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return d;
}

hmac256(key, data: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

hkdf(salt, info, ikm: array of byte, n: int): array of byte
{
	prk := hmac256(salt, ikm);
	out := array[n] of byte;
	t := array[0] of byte;
	for(i := 1; (i-1)*Keyring->SHA256dlen < n; i++){
		m := array[len t + len info + 1] of byte;
		m[0:] = t;
		m[len t:] = info;
		m[len t + len info] = byte i;
		t = hmac256(prk, m);
		o := (i-1)*Keyring->SHA256dlen;
		k := len t;
		if(o + k > n)
			k = n - o;
		out[o:] = t[0:k];
		zero(m);
	}
	zero(prk);
	zero(t);
	return out;
}

passtoaeskey(pw: array of byte): array of byte
{
	salt := array of byte "Plan 9 key derivation";
	# PBKDF2-HMAC-SHA1, one block of 20 bytes, its first 16 taken
	blk := array[len salt + 4] of byte;
	blk[0:] = salt;
	blk[len salt:] = array[] of {byte 0, byte 0, byte 0, byte 1};
	u := array[Keyring->SHA1dlen] of byte;
	kr->hmac_sha1(blk, len blk, pw, u, nil);
	t := array[Keyring->SHA1dlen] of byte;
	t[0:] = u;
	for(i := 1; i < 9001; i++){
		kr->hmac_sha1(u, len u, pw, u, nil);
		for(j := 0; j < len t; j++)
			t[j] ^= u[j];
	}
	k := array[AESKEYLEN] of byte;
	k[0:] = t[0:AESKEYLEN];
	zero(t);
	zero(u);
	return k;
}

authpakhash(aes: array of byte, user: string): array of byte
{
	salt := sha256(array of byte user);
	h := hkdf(salt, array of byte "Plan 9 AuthPAK hash", aes, 2*PAKSLEN);
	out := array[PAKHASHLEN] of byte;
	out[0:] = ptbytes(elligator2(md(bint(h[0:PAKSLEN]))));
	out[PAKPLEN:] = ptbytes(elligator2(md(bint(h[PAKSLEN:]))));
	zero(h);
	return out;
}

Pak.new(pakhash: array of byte, isclient: int, x: array of byte): ref Pak
{
	if(len pakhash != PAKHASHLEN)
		return nil;
	if(x == nil){
		# as mpnrand: uniform in 0..P-1
		for(;;){
			x = randombytes(PAKSLEN);
			if(bint(x).cmp(P) < 0)
				break;
		}
	}
	off := 0;
	if(!isclient)
		off = PAKPLEN;
	pm := bytespt(pakhash[off:off+PAKPLEN]);
	g := ref Pt(GX, GY, One, fmul(GX, GY));
	y := be(decafencode(edadd(edscale(x, g), pm)), PAKYLEN);
	return ref Pak(bint(x), y, isclient, pakhash);
}

Pak.finish(p: self ref Pak, y: array of byte): array of byte
{
	if(len y != PAKYLEN || p.x == nil)
		return nil;
	off := PAKPLEN;
	if(!p.isclient)
		off = 0;
	pn := bytespt(p.pakhash[off:off+PAKPLEN]);
	q := decafdecode(bint(y));
	if(q == nil)
		return nil;
	q = edadd(q, ref Pt(fneg(pn.x), pn.y, pn.z, fneg(pn.t)));
	z := be(decafencode(edscale(be(p.x, PAKSLEN), q)), PAKSLEN);
	m := array[2*PAKYLEN] of byte;
	if(p.isclient){
		m[0:] = p.y;
		m[PAKYLEN:] = y;
	}else{
		m[0:] = y;
		m[PAKYLEN:] = p.y;
	}
	k := hkdf(sha256(m), array of byte "Plan 9 AuthPAK key", z, PAKKEYLEN);
	zero(z);
	p.x = nil;
	return k;
}

randombytes(n: int): array of byte
{
	b := IPint.random(0, 8*n).iptobebytes();
	out := array[n] of {* => byte 0};
	if(len b > n)
		b = b[len b - n:];
	out[n - len b:] = b;
	return out;
}

# form1
sig(num: int): array of byte
{
	s: string;
	case num {
	3 =>	s = "form1 PR";
	AuthTs =>	s = "form1 Ts";
	AuthTc =>	s = "form1 Tc";
	AuthAs =>	s = "form1 As";
	AuthAc =>	s = "form1 Ac";
	68 =>	s = "form1 Tp";
	69 =>	s = "form1 Hr";
	* =>	return nil;
	}
	return array of byte s;
}

sigtype(a: array of byte): int
{
	if(len a < 8)
		return -1;
	for(n := 0; n < 128; n++){
		s := sig(n);
		if(s == nil)
			continue;
		for(i := 0; i < 8; i++)
			if(a[i] != s[i])
				break;
		if(i == 8)
			return n;
	}
	return -1;
}

counter := 0;

form1seal(num: int, body, key: array of byte): array of byte
{
	s := sig(num);
	if(s == nil || len key != 32)
		return nil;
	nonce := array[12] of byte;
	nonce[0:] = s;
	c := counter++;
	nonce[8] = byte c;
	nonce[9] = byte (c>>8);
	nonce[10] = byte (c>>16);
	nonce[11] = byte (c>>24);
	(ct, tag) := kr->ccpolyencrypt(body, nil, key, nonce);
	if(ct == nil || tag == nil)
		return nil;
	out := array[12 + len ct + len tag] of byte;
	out[0:] = nonce;
	out[12:] = ct;
	out[12 + len ct:] = tag;
	return out;
}

form1open(a, key: array of byte): (int, array of byte)
{
	num := sigtype(a);
	if(num < 0 || len a <= 12+16 || len key != 32)
		return (-1, nil);
	n := len a - 12 - 16;
	pt := kr->ccpolydecrypt(a[12:12+n], nil, a[12+n:], key, a[0:12]);
	if(pt == nil)
		return (-1, nil);
	return (num, pt);
}

putname(b: array of byte, s: string, n: int)
{
	a := array of byte s;
	if(len a > n-1)
		a = a[0:n-1];	# as strncpy into a field ending in a nil
	for(i := 0; i < n; i++)
		b[i] = byte 0;
	b[0:] = a;
}

getname(b: array of byte): string
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte 0)
			break;
	return string b[0:i];
}

Ticketreq.pack(t: self ref Ticketreq): array of byte
{
	b := array[TICKREQLEN] of {* => byte 0};
	b[0] = byte t.rtype;
	o := 1;
	putname(b[o:o+ANAMELEN], t.authid, ANAMELEN); o += ANAMELEN;
	putname(b[o:o+DOMLEN], t.authdom, DOMLEN); o += DOMLEN;
	if(t.chal != nil)
		b[o:] = t.chal[0:CHALLEN];
	o += CHALLEN;
	putname(b[o:o+ANAMELEN], t.hostid, ANAMELEN); o += ANAMELEN;
	putname(b[o:o+ANAMELEN], t.uid, ANAMELEN);
	return b;
}

Ticketreq.unpack(b: array of byte): (ref Ticketreq, string)
{
	if(len b < TICKREQLEN)
		return (nil, "short ticket request");
	t := ref Ticketreq;
	t.rtype = int b[0];
	o := 1;
	t.authid = getname(b[o:o+ANAMELEN]); o += ANAMELEN;
	t.authdom = getname(b[o:o+DOMLEN]); o += DOMLEN;
	t.chal = array[CHALLEN] of byte;
	t.chal[0:] = b[o:o+CHALLEN]; o += CHALLEN;
	t.hostid = getname(b[o:o+ANAMELEN]); o += ANAMELEN;
	t.uid = getname(b[o:o+ANAMELEN]);
	return (t, nil);
}

sealticket(t: ref Ticket, key: array of byte): array of byte
{
	b := array[CHALLEN+2*ANAMELEN+NONCELEN] of {* => byte 0};
	b[0:] = t.chal[0:CHALLEN];
	putname(b[CHALLEN:CHALLEN+ANAMELEN], t.cuid, ANAMELEN);
	putname(b[CHALLEN+ANAMELEN:CHALLEN+2*ANAMELEN], t.suid, ANAMELEN);
	b[CHALLEN+2*ANAMELEN:] = t.key[0:NONCELEN];
	r := form1seal(t.num, b, key);
	zero(b);
	return r;
}

openticket(a, key: array of byte): (ref Ticket, string)
{
	if(len a != TICKETLEN)
		return (nil, "ticket the wrong length");
	(num, b) := form1open(a, key);
	if(num != AuthTc && num != AuthTs)
		return (nil, "ticket does not decrypt");
	t := ref Ticket;
	t.num = num;
	t.chal = array[CHALLEN] of byte;
	t.chal[0:] = b[0:CHALLEN];	# b is zeroed below
	t.cuid = getname(b[CHALLEN:CHALLEN+ANAMELEN]);
	t.suid = getname(b[CHALLEN+ANAMELEN:CHALLEN+2*ANAMELEN]);
	t.key = array[NONCELEN] of byte;
	t.key[0:] = b[CHALLEN+2*ANAMELEN:];
	zero(b);
	return (t, nil);
}

sealauth(a: ref Authenticator, key: array of byte): array of byte
{
	b := array[CHALLEN+NONCELEN] of byte;
	b[0:] = a.chal[0:CHALLEN];
	b[CHALLEN:] = a.rand[0:NONCELEN];
	return form1seal(a.num, b, key);
}

openauth(b, key: array of byte): (ref Authenticator, string)
{
	if(len b != AUTHENTLEN)
		return (nil, "authenticator the wrong length");
	(num, pt) := form1open(b, key);
	if(num != AuthAs && num != AuthAc)
		return (nil, "authenticator does not decrypt");
	a := ref Authenticator(num, pt[0:CHALLEN], pt[CHALLEN:]);
	return (a, nil);
}

sessionsecret(rand, tkey: array of byte): array of byte
{
	return hkdf(rand, array of byte "Plan 9 session secret", tkey, SECRETLEN);
}

zero(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}
