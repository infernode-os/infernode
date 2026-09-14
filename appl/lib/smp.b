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
	}
	return sys->sprint("pairing failed 0x%2.2x", reason);
}

Pairing.new(iat: int, ia: array of byte, rat: int, ra: array of byte, mrand: array of byte): ref Pairing
{
	return ref Pairing(Idle, iat, ia, rat, ra, nil, nil, mrand, nil, nil, array[16] of { * => byte 0 }, nil, nil, 0);
}

# Pairing Request: Just Works with bonding, a 16-byte key, and we ask
# for the peer's encryption and identity keys and give none
Pairing.start(p: self ref Pairing): list of ref Ev
{
	req := array[7] of byte;
	req[0] = byte Cpairreq;
	req[1] = byte IOnone;
	req[2] = byte 0;			# no OOB
	req[3] = byte Abonding;
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
		p.state = Waitconfirm;
		mconfirm := c1(p.tk, p.mrand, p.preq, p.pres, p.iat, p.ia, p.rat, p.ra);
		return ref Ev.Send(withcode(Cconfirm, mconfirm)) :: nil;
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

Pairing.encrypted(p: self ref Pairing): list of ref Ev
{
	if(p.state != Waitencrypt)
		return nil;
	p.state = Waitkeys;
	if(p.keys == nil)
		p.keys = ref Keys(nil, 0, nil, nil, 0, nil);
	return done(p);
}

keydist(p: ref Pairing, code: int, pdu: array of byte): list of ref Ev
{
	if(p.keys == nil)
		p.keys = ref Keys(nil, 0, nil, nil, 0, nil);
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
	if(p.keys.ltk == nil){
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
