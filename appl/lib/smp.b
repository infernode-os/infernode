implement Smp;

#
# Legacy LE pairing from the central's side; see smp.m. The
# specification writes its 128-bit values most-significant-octet
# first and the wire carries them least-significant first, so the
# cryptographic functions here take and give little-endian arrays and
# reverse around the AES block, where the order matters.
#

include "sys.m";
	sys: Sys;
include "keyring.m";
	keyring: Keyring;
include "bthci.m";
	bthci: Bthci;
include "smp.m";

init(b: Bthci, k: Keyring)
{
	sys = load Sys Sys->PATH;
	bthci = b;
	keyring = k;
}

rev(a: array of byte): array of byte
{
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[len a - 1 - i];
	return r;
}

xor(a, b: array of byte): array of byte
{
	r := array[len a] of byte;
	for(i := 0; i < len a; i++)
		r[i] = a[i] ^ b[i];
	return r;
}

# AES-128 of one block: CBC with a zero IV over one block is ECB
e(k, p: array of byte): array of byte
{
	iv := array[16] of { * => byte 0 };
	st := keyring->aessetup(rev(k), iv);
	buf := rev(p);
	keyring->aescbc(st, buf, 16, Keyring->Encrypt);
	return rev(buf);
}

#
# LE Secure Connections: AES-CMAC and the four functions built on it.
# The specification writes every input most significant octet first
# and concatenates them that way; the arrays here are the wire's, so
# each is reversed going in and the result reversed coming out.
#

# one AES-128 block, big-endian, in place
aesbe(k, b: array of byte)
{
	iv := array[16] of { * => byte 0 };
	st := keyring->aessetup(k, iv);
	keyring->aescbc(st, b, 16, Keyring->Encrypt);
}

# RFC 4493 subkey step: shift left one bit, and fold the carry back in
dbl(b: array of byte)
{
	carry := int b[0] & 16r80;
	for(i := 0; i < 15; i++)
		b[i] = byte ((int b[i] << 1) | (int b[i+1] >> 7));
	b[15] = byte (int b[15] << 1);
	if(carry)
		b[15] ^= byte 16r87;
}

cmac(k, m: array of byte): array of byte
{
	k1 := array[16] of { * => byte 0 };
	aesbe(k, k1);
	dbl(k1);
	k2 := array[16] of byte;
	k2[0:] = k1;
	dbl(k2);

	nblk := (len m + 15) / 16;
	last := array[16] of { * => byte 0 };
	sub := k2;
	if(nblk == 0){
		nblk = 1;
		last[0] = byte 16r80;
	}else if(len m % 16 == 0){
		last[0:] = m[(nblk-1)*16:];
		sub = k1;
	}else{
		r := len m - (nblk-1)*16;
		last[0:] = m[(nblk-1)*16:];
		last[r] = byte 16r80;
	}
	x := array[16] of { * => byte 0 };
	for(i := 0; i < nblk-1; i++){
		for(j := 0; j < 16; j++)
			x[j] ^= m[i*16 + j];
		aesbe(k, x);
	}
	for(i = 0; i < 16; i++)
		x[i] ^= last[i] ^ sub[i];
	aesbe(k, x);
	return x;
}

# big-endian concatenation of little-endian parts
becat(parts: list of array of byte): array of byte
{
	n := 0;
	for(l := parts; l != nil; l = tl l)
		n += len hd l;
	m := array[n] of byte;
	o := 0;
	for(l = parts; l != nil; l = tl l){
		m[o:] = rev(hd l);
		o += len hd l;
	}
	return m;
}

# f4(U, V, X, Z) = AES-CMAC_X(U || V || Z)
f4(u, v, x: array of byte, z: int): array of byte
{
	return rev(cmac(rev(x), becat(u :: v :: array[1] of { byte z } :: nil)));
}

# f5: the key T is AES-CMAC_SALT(W); then counter || "btle" || N1 || N2
# || A1 || A2 || 256 under T, counter 0 for the MacKey and 1 for the LTK
f5(w, n1, n2, a1, a2: array of byte): (array of byte, array of byte)
{
	salt := array[] of {
		byte 16r6C, byte 16r88, byte 16r83, byte 16r91, byte 16rAA, byte 16rF5, byte 16rA5, byte 16r38,
		byte 16r60, byte 16r37, byte 16r0B, byte 16rDB, byte 16r5A, byte 16r60, byte 16r83, byte 16rBE };
	t := cmac(salt, rev(w));
	keyid := array[] of { byte 16r65, byte 16r6c, byte 16r74, byte 16r62 };	# "btle", least significant first
	length := array[] of { byte 16r00, byte 16r01 };				# 256
	m0 := becat(array[1] of { byte 0 } :: keyid :: n1 :: n2 :: a1 :: a2 :: length :: nil);
	m1 := becat(array[1] of { byte 1 } :: keyid :: n1 :: n2 :: a1 :: a2 :: length :: nil);
	return (rev(cmac(t, m0)), rev(cmac(t, m1)));
}

# f6(W, N1, N2, R, IOcap, A1, A2) = AES-CMAC_W(N1 || N2 || R || IOcap || A1 || A2)
f6(w, n1, n2, r, iocap, a1, a2: array of byte): array of byte
{
	return rev(cmac(rev(w), becat(n1 :: n2 :: r :: iocap :: a1 :: a2 :: nil)));
}

# g2(U, V, X, Y) = AES-CMAC_X(U || V || Y) mod 2^32, and then mod 10^6
g2(u, v, x, y: array of byte): int
{
	c := cmac(rev(x), becat(u :: v :: y :: nil));
	n := (big c[12] << 24) | (big c[13] << 16) | (big c[14] << 8) | big c[15];
	return int (n % big 1000000);
}

sckeys(): (array of byte, array of byte, array of byte)
{
	(priv, pub) := keyring->p256_keygen();
	if(priv == nil || pub == nil)
		return (nil, nil, nil);
	b := keyring->p256_point_bytes(pub);	# 0x04 || X || Y, big-endian
	if(len b != 65)
		return (nil, nil, nil);
	return (priv, rev(b[1:33]), rev(b[33:65]));
}

# keyring refuses a point that is not on the curve, which is the check
# the specification requires before the key is used (2.3.5.6.1): an
# invalid-curve point is how a peer would learn our private key
dhkey(priv, x, y: array of byte): array of byte
{
	if(len priv != 32 || len x != 32 || len y != 32)
		return nil;
	b := array[65] of byte;
	b[0] = byte 16r04;
	b[1:] = rev(x);
	b[33:] = rev(y);
	pt := keyring->p256_make_point(b);
	if(pt == nil)
		return nil;
	s := keyring->p256_ecdh(priv, pt);
	if(len s != 32)
		return nil;
	return rev(s);
}

# c1, 2.2.3: e(k, e(k, r xor p1) xor p2), with
#   p1 = pres || preq || rat || iat  (iat least significant)
#   p2 = padding || ia || ra          (ra least significant)
c1(k, r, preq, pres: array of byte, iat: int, ia: array of byte, rat: int, ra: array of byte): array of byte
{
	p1 := array[16] of { * => byte 0 };
	p1[0] = byte iat;
	p1[1] = byte rat;
	p1[2:] = preq[0:7];
	p1[9:] = pres[0:7];
	p2 := array[16] of { * => byte 0 };
	p2[0:] = ra[0:6];
	p2[6:] = ia[0:6];
	return e(k, xor(e(k, xor(r, p1)), p2));
}

# s1, 2.2.4: e(k, r1' || r2'), the least significant halves, r2's least significant
s1(k, r1, r2: array of byte): array of byte
{
	r := array[16] of byte;
	r[0:] = r2[0:8];
	r[8:] = r1[0:8];
	return e(k, r);
}

resolves(irk, a: array of byte): int
{
	if(len irk != 16 || len a != 6 || (int a[5] & 16rc0) != 16r40)
		return 0;
	r := array[16] of { * => byte 0 };
	r[0:] = a[3:6];
	h := e(irk, r);
	return h[0] == a[0] && h[1] == a[1] && h[2] == a[2];
}

failtext(reason: int): string
{
	case reason {
	Fpasskeyfailed =>	return "passkey entry failed";
	Foobnotavail =>		return "OOB not available";
	Fauthreq =>		return "authentication requirements not met";
	Fconfirmfailed =>	return "confirm value failed";
	Fnotsupported =>	return "pairing not supported";
	Fenckeysize =>		return "encryption key size";
	Fcmdnotsupported =>	return "command not supported";
	Funspecified =>		return "unspecified reason";
	Frepeated =>		return "repeated attempts";
	Finvalidparams =>	return "invalid parameters";
	Fdhkeycheck =>		return "DHKey check failed";
	Fnumcmp =>		return "numeric comparison failed";
	}
	return sys->sprint("pairing failed 0x%2.2x", reason);
}

Pairing.new(iat: int, ia: array of byte, rat: int, ra: array of byte, mrand: array of byte): ref Pairing
{
	return ref Pairing(Idle, iat, ia, rat, ra, nil, nil, mrand, nil, nil, array[16] of { * => byte 0 }, nil, nil, 0,
		IOnone, 1, 0, nil, nil, nil, nil, nil, nil, nil, 0);
}

# Pairing Request: bonding, a 16-byte key, and we ask for the peer's
# encryption and identity keys and give none. Secure Connections is
# offered unless the caller said not; man-in-the-middle protection is
# asked for when we can show digits and take an answer, which is what
# numeric comparison needs.
Pairing.start(p: self ref Pairing): list of ref Ev
{
	req := array[7] of byte;
	req[0] = byte Cpairreq;
	req[1] = byte p.io;
	req[2] = byte 0;			# no OOB
	auth := Abonding;
	if(p.offersc)
		auth |= Asc;
	if(p.io == IOdisplayyesno || p.io == IOkeyboarddisplay)
		auth |= Amitm;
	req[3] = byte auth;
	req[4] = byte 16;
	req[5] = byte 0;			# we distribute nothing
	req[6] = byte (Kenc | Kid);
	p.preq = req;
	p.state = Waitrsp;
	return ref Ev.Send(req) :: nil;
}

fail(p: ref Pairing, reason: int): list of ref Ev
{
	p.state = Failed;
	f := array[] of { byte Cfailed, byte reason };
	return ref Ev.Send(f) :: ref Ev.Failed(reason, failtext(reason)) :: nil;
}

Pairing.recv(p: self ref Pairing, pdu: array of byte): list of ref Ev
{
	if(len pdu < 1)
		return nil;
	code := int pdu[0];
	if(code == Cfailed){
		p.state = Failed;
		reason := Funspecified;
		if(len pdu >= 2)
			reason = int pdu[1];
		return ref Ev.Failed(reason, failtext(reason)) :: nil;
	}
	case p.state {
	Waitrsp =>
		if(code != Cpairrsp || len pdu < 7)
			return fail(p, Finvalidparams);
		p.pres = pdu[0:7];
		# a peer that will only do Secure Connections has set SC and
		# will refuse legacy; say so now rather than fail the confirm
		if(int pdu[4] < 7)
			return fail(p, Fenckeysize);
		p.want = int pdu[6] & (Kenc | Kid);
		if(p.offersc && (int pdu[3] & Asc))
			return scstart(p);
		p.state = Waitconfirm;
		mconfirm := c1(p.tk, p.mrand, p.preq, p.pres, p.iat, p.ia, p.rat, p.ra);
		return ref Ev.Send(withcode(Cconfirm, mconfirm)) :: nil;
	Waitpubkey or Waitscconfirm or Waitscrandom or Waitdhcheck =>
		return screcv(p, code, pdu);
	Waituser =>
		return nil;	# nothing is due from the peer while the user looks at the digits
	Waitconfirm =>
		if(code != Cconfirm || len pdu < 17)
			return fail(p, Finvalidparams);
		p.sconfirm = pdu[1:17];
		p.state = Waitrandom;
		return ref Ev.Send(withcode(Crandom, p.mrand)) :: nil;
	Waitrandom =>
		if(code != Crandom || len pdu < 17)
			return fail(p, Finvalidparams);
		p.srand = pdu[1:17];
		want := c1(p.tk, p.srand, p.preq, p.pres, p.iat, p.ia, p.rat, p.ra);
		if(!same(want, p.sconfirm))
			return fail(p, Fconfirmfailed);
		p.stk = s1(p.tk, p.srand, p.mrand);
		p.state = Waitencrypt;
		return ref Ev.Encrypt(p.stk) :: nil;
	Waitkeys =>
		return keydist(p, code, pdu);
	Waitencrypt =>
		# a peer may start distributing before we saw the encryption change
		return keydist(p, code, pdu);
	}
	return nil;
}

#
# LE Secure Connections, 2.3.5.6, as the initiator. A is us, B the peer.
#

# an address as f5 and f6 take it: six bytes and then its type
addr7(a: array of byte, t: int): array of byte
{
	r := array[7] of byte;
	r[0:] = a[0:6];
	r[6] = byte t;
	return r;
}

# can this end show six digits and take a yes or no?
canconfirm(io: int): int
{
	return io == IOdisplayyesno || io == IOkeyboarddisplay;
}

# Public keys first: ours goes, the peer's comes back.
scstart(p: ref Pairing): list of ref Ev
{
	p.sc = 1;
	# SC distributes no LTK: both ends make it. Only the identity is still to come.
	p.want &= Kid;
	if(p.priv == nil)
		(p.priv, p.pkx, p.pky) = sckeys();
	if(p.priv == nil)
		return fail(p, Funspecified);
	# Numeric comparison when both ends can show and answer and either
	# asked for protection from a man in the middle (2.3.5.1, table
	# 2.8); Just Works otherwise. A pairing that would need a passkey
	# typed is not one we can do.
	peerio := int p.pres[1];
	mitm := (int p.preq[3] | int p.pres[3]) & Amitm;
	p.numeric = 0;
	if(mitm){
		if(canconfirm(p.io) && canconfirm(peerio))
			p.numeric = 1;
		else if(p.io != IOnone && peerio != IOnone &&
		   (p.io == IOkeyboardonly || peerio == IOkeyboardonly || p.io == IOkeyboarddisplay || peerio == IOkeyboarddisplay))
			return fail(p, Fauthreq);	# passkey entry
	}
	pk := array[65] of byte;
	pk[0] = byte Cpublickey;
	pk[1:] = p.pkx;
	pk[33:] = p.pky;
	p.state = Waitpubkey;
	return ref Ev.Send(pk) :: nil;
}

screcv(p: ref Pairing, code: int, pdu: array of byte): list of ref Ev
{
	zero := array[16] of { * => byte 0 };
	case p.state {
	Waitpubkey =>
		if(code != Cpublickey || len pdu < 65)
			return fail(p, Finvalidparams);
		p.peerx = pdu[1:33];
		p.peery = pdu[33:65];
		# our own key handed back proves nothing about who holds its
		# private half; and dhkey() refuses a point off the curve
		if(same(p.peerx, p.pkx))
			return fail(p, Fdhkeycheck);
		p.dh = dhkey(p.priv, p.peerx, p.peery);
		if(p.dh == nil)
			return fail(p, Fdhkeycheck);
		p.state = Waitscconfirm;
		return nil;
	Waitscconfirm =>
		# the peer commits to its nonce before it sees ours
		if(code != Cconfirm || len pdu < 17)
			return fail(p, Finvalidparams);
		p.sconfirm = pdu[1:17];
		p.state = Waitscrandom;
		return ref Ev.Send(withcode(Crandom, p.mrand)) :: nil;
	Waitscrandom =>
		if(code != Crandom || len pdu < 17)
			return fail(p, Finvalidparams);
		p.srand = pdu[1:17];
		if(!same(f4(p.peerx, p.pkx, p.srand, 0), p.sconfirm))
			return fail(p, Fconfirmfailed);
		if(p.numeric){
			p.state = Waituser;
			return ref Ev.Confirm(g2(p.pkx, p.peerx, p.mrand, p.srand)) :: nil;
		}
		return sccheck(p);
	Waitdhcheck =>
		if(code != Cdhkeycheck || len pdu < 17)
			return fail(p, Finvalidparams);
		a := addr7(p.ia, p.iat);
		b := addr7(p.ra, p.rat);
		eb := f6(p.mackey, p.srand, p.mrand, zero, p.pres[1:4], b, a);
		if(!same(eb, pdu[1:17]))
			return fail(p, Fdhkeycheck);
		# the LTK both ends computed is the key: no STK, nothing sent
		p.state = Waitencrypt;
		return ref Ev.Encrypt(p.stk) :: nil;
	}
	return nil;
}

# authentication stage 2: the keys from f5, and our check value
sccheck(p: ref Pairing): list of ref Ev
{
	zero := array[16] of { * => byte 0 };
	a := addr7(p.ia, p.iat);
	b := addr7(p.ra, p.rat);
	(p.mackey, p.stk) = f5(p.dh, p.mrand, p.srand, a, b);
	ea := f6(p.mackey, p.mrand, p.srand, zero, p.preq[1:4], a, b);
	p.state = Waitdhcheck;
	return ref Ev.Send(withcode(Cdhkeycheck, ea)) :: nil;
}

Pairing.confirm(p: self ref Pairing, yes: int): list of ref Ev
{
	if(p.state != Waituser)
		return nil;
	if(!yes)
		return fail(p, Fnumcmp);
	return sccheck(p);
}

Pairing.encrypted(p: self ref Pairing): list of ref Ev
{
	if(p.state != Waitencrypt)
		return nil;
	p.state = Waitkeys;
	if(p.keys == nil)
		p.keys = ref Keys(nil, 0, nil, nil, 0, nil, 0);
	return done(p);
}

keydist(p: ref Pairing, code: int, pdu: array of byte): list of ref Ev
{
	if(p.keys == nil)
		p.keys = ref Keys(nil, 0, nil, nil, 0, nil, 0);
	case code {
	Cencinfo =>
		if(len pdu < 17)
			return fail(p, Finvalidparams);
		p.keys.ltk = pdu[1:17];
	Cmasterid =>
		if(len pdu < 11)
			return fail(p, Finvalidparams);
		p.keys.ediv = int pdu[1] | (int pdu[2] << 8);
		p.keys.rand = pdu[3:11];
		p.want &= ~Kenc;
	Cidinfo =>
		if(len pdu < 17)
			return fail(p, Finvalidparams);
		p.keys.irk = pdu[1:17];
	Cidaddr =>
		if(len pdu < 8)
			return fail(p, Finvalidparams);
		p.keys.idtype = int pdu[1];
		p.keys.idaddr = bthci->bdaddr(pdu, 2);
		p.want &= ~Kid;
	Csigninfo =>
		;	# not asked for; ignored if given
	* =>
		return nil;
	}
	if(p.state == Waitkeys)
		return done(p);
	return nil;
}

done(p: ref Pairing): list of ref Ev
{
	if(p.want != 0)
		return nil;
	p.state = Done;
	if(p.sc){
		# the LTK f5 made: EDIV 0 and Rand 0 by definition, and a
		# key to keep -- which is what keys.sc tells the caller,
		# since a legacy STK looks the same and is not
		p.keys.ltk = p.stk;
		p.keys.rand = array[8] of { * => byte 0 };
		p.keys.ediv = 0;
		p.keys.sc = 1;
	}else if(p.keys.ltk == nil){
		# no encryption key was to come: the STK is all there is,
		# and it cannot be stored (Rand 0, EDIV 0 marks it as such)
		p.keys.ltk = p.stk;
		p.keys.rand = array[8] of { * => byte 0 };
		p.keys.ediv = 0;
	}
	return ref Ev.Paired(p.keys) :: nil;
}

withcode(code: int, v: array of byte): array of byte
{
	r := array[1 + len v] of byte;
	r[0] = byte code;
	r[1:] = v;
	return r;
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}
