implement Tlspsk;

#
# tlspsk(2): TLS 1.2 (RFC 5246) with PSK key exchange (RFC 4279) and
# ChaCha20-Poly1305 (RFC 7905), the client's side, for 9front's tlssrv.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "tlspsk.m";

Version:	con 16r0303;
Suite:	con 16rCCAB;	# TLS_PSK_WITH_CHACHA20_POLY1305_SHA256
Maxfrag:	con 16384;
Maxrec:	con Maxfrag + 256;

Rchangecipher:	con 20;
Ralert:	con 21;
Rhandshake:	con 22;
Rdata:	con 23;

HClienthello:	con 1;
HServerhello:	con 2;
HServerkx:	con 12;
HCertreq:	con 13;
HServerdone:	con 14;
HClientkx:	con 16;
HFinished:	con 20;

Rec: adt {
	fd:	ref Sys->FD;
	key:	array of byte;	# nil until the change of cipher
	iv:	array of byte;
	seq:	big;
	buf:	array of byte;	# handshake bytes read and not yet taken
};

init(): string
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return sys->sprint("cannot load Keyring: %r");
	return nil;
}

client(fd: ref Sys->FD, identity: string, psk: array of byte): (ref Sys->FD, string)
{
	if(len psk == 0 || len psk > 65535)
		return (nil, "tlspsk: no key");
	id := array of byte identity;
	if(len id > 65535)
		return (nil, "tlspsk: identity too long");
	rd := ref Rec(fd, nil, nil, big 0, array[0] of byte);
	wr := ref Rec(fd, nil, nil, big 0, nil);
	hs := array[0] of byte;		# the handshake's messages, for Finished

	crand := random(32);
	# ClientHello: version, random, no session, one suite, no compression,
	# renegotiation_info (empty: RFC 5746, which servers look for)
	ext := array[] of {byte 16rff, byte 16r01, byte 0, byte 1, byte 0};
	body := cat(array[] of {
		u16(Version), crand, array[] of {byte 0},
		u16(2), u16(Suite), array[] of {byte 1, byte 0},
		u16(len ext), ext,
	});
	m := hsmsg(HClienthello, body);
	hs = cat2(hs, m);
	if((e := writerec(wr, Rhandshake, m)) != nil)
		return (nil, e);

	# ServerHello, [ServerKeyExchange], ServerHelloDone
	srand: array of byte;
	for(;;){
		(t, b, err) := readhs(rd);
		if(err != nil)
			return (nil, err);
		hs = cat2(hs, b);
		b = b[4:];
		case t {
		HServerhello =>
			if(srand != nil)
				return (nil, "tlspsk: a second ServerHello");
			if(len b < 2+32+1)
				return (nil, "tlspsk: short ServerHello");
			if(g16(b, 0) != Version)
				return (nil, sys->sprint("tlspsk: the server chose version %.4ux, not TLS 1.2", g16(b, 0)));
			srand = b[2:34];
			sl := int b[34];
			o := 35 + sl;
			if(len b < o+3)
				return (nil, "tlspsk: short ServerHello");
			if(g16(b, o) != Suite)
				return (nil, sys->sprint("tlspsk: the server chose suite %.4ux, not one offered", g16(b, o)));
			if(b[o+2] != byte 0)
				return (nil, "tlspsk: the server chose compression");
			# RFC 8446's mark of a downgrade from TLS 1.3 is no matter here:
			# 1.2 is all this asks for
		HServerkx =>
			# a psk_identity_hint, which tells nothing used here
			if(srand == nil || len b < 2 || 2 + g16(b, 0) != len b)
				return (nil, "tlspsk: bad ServerKeyExchange");
		HCertreq =>
			return (nil, "tlspsk: the server asks for a certificate");
		HServerdone =>
			if(srand == nil)
				return (nil, "tlspsk: ServerHelloDone before ServerHello");
			if(len b != 0)
				return (nil, "tlspsk: bad ServerHelloDone");
			break;
		* =>
			return (nil, sys->sprint("tlspsk: unexpected handshake message %d", t));
		}
		if(t == HServerdone)
			break;
	}

	# premaster (RFC 4279 2): N zeros and the key, each with its length
	pms := cat(array[] of {u16(len psk), array[len psk] of {* => byte 0}, u16(len psk), psk});
	ms := prf(pms, "master secret", cat2(crand, srand), 48);
	zero(pms);
	kb := prf(ms, "key expansion", cat2(srand, crand), 2*32 + 2*12);

	m = hsmsg(HClientkx, cat2(u16(len id), id));
	hs = cat2(hs, m);
	if((e = writerec(wr, Rhandshake, m)) != nil)
		return (nil, e);
	if((e = writerec(wr, Rchangecipher, array[] of {byte 1})) != nil)
		return (nil, e);
	wr.key = kb[0:32];
	wr.iv = kb[64:76];
	vd := prf(ms, "client finished", sha256(hs), 12);
	m = hsmsg(HFinished, vd);
	hs = cat2(hs, m);
	if((e = writerec(wr, Rhandshake, m)) != nil)
		return (nil, e);

	# the server's ChangeCipherSpec and Finished
	(t, b, err) := readrec(rd);
	if(err != nil)
		return (nil, err);
	if(t != Rchangecipher || len b != 1 || b[0] != byte 1)
		return (nil, "tlspsk: the server did not change cipher (wrong key?)");
	if(len rd.buf != 0)
		return (nil, "tlspsk: handshake bytes before ChangeCipherSpec");
	rd.key = kb[32:64];
	rd.iv = kb[76:88];
	(t, b, err) = readhs(rd);
	if(err != nil)
		return (nil, err+" (wrong key?)");
	if(t != HFinished)
		return (nil, "tlspsk: no Finished from the server");
	want := prf(ms, "server finished", sha256(hs), 12);
	if(!eq(b[4:], want))
		return (nil, "tlspsk: the server's Finished is not right");
	if(len rd.buf != 0)
		return (nil, "tlspsk: handshake bytes after Finished");
	zero(ms);

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return (nil, sys->sprint("tlspsk: pipe: %r"));
	spawn reader(rd, p[1]);
	spawn writer(wr, p[1]);
	return (p[0], nil);
}

# records from the far end, opened, to the pipe
reader(rd: ref Rec, p: ref Sys->FD)
{
	for(;;){
		(t, b, err) := readrec(rd);
		if(err != nil)
			break;
		case t {
		Rdata =>
			if(len b > 0 && sys->write(p, b, len b) != len b)
				break;
			continue;
		Ralert =>
			break;
		Rhandshake =>
			break;	# renegotiation is refused by going away
		* =>
			break;
		}
		break;
	}
	# end of file for the reader of the conversation
	sys->write(p, array[0] of byte, 0);
	rd.fd = nil;
}

# what is written on the pipe, sealed, to the far end
writer(wr: ref Rec, p: ref Sys->FD)
{
	buf := array[Maxfrag] of byte;
	while((n := sys->read(p, buf, len buf)) > 0)
		if(writerec(wr, Rdata, buf[0:n]) != nil)
			return;
	# close_notify, a warning
	writerec(wr, Ralert, array[] of {byte 1, byte 0});
}

readrec(rd: ref Rec): (int, array of byte, string)
{
	h := array[5] of byte;
	if(readn(rd.fd, h, 5) != 5)
		return (-1, nil, "tlspsk: connection closed");
	t := int h[0];
	n := g16(h, 3);
	if(n > Maxrec)
		return (-1, nil, "tlspsk: record too long");
	if(g16(h, 1) != Version && !(rd.key == nil && (g16(h, 1) >> 8) == 3))
		return (-1, nil, "tlspsk: record of another version");
	b := array[n] of byte;
	if(readn(rd.fd, b, n) != n)
		return (-1, nil, "tlspsk: connection closed in a record");
	if(rd.key != nil){
		if(n < 16)
			return (-1, nil, "tlspsk: record too short");
		ad := cat(array[] of {u64(rd.seq), array[] of {byte t}, u16(Version), u16(n-16)});
		pt := kr->ccpolydecrypt(b[0:n-16], ad, b[n-16:], rd.key, nonce(rd.iv, rd.seq));
		if(pt == nil)
			return (-1, nil, "tlspsk: a record does not decrypt");
		rd.seq++;
		b = pt;
	}
	if(t == Ralert && len b >= 2 && int b[1] != 0)
		return (-1, nil, sys->sprint("tlspsk: the server's alert %d", int b[1]));
	return (t, b, nil);
}

# a whole handshake message, header and all
readhs(rd: ref Rec): (int, array of byte, string)
{
	for(;;){
		if(len rd.buf >= 4){
			n := (int rd.buf[1]<<16) | (int rd.buf[2]<<8) | int rd.buf[3];
			if(n > Maxrec)
				return (-1, nil, "tlspsk: handshake message too long");
			if(len rd.buf >= 4+n){
				m := rd.buf[0:4+n];
				rd.buf = rd.buf[4+n:];
				return (int m[0], m, nil);
			}
		}
		(t, b, err) := readrec(rd);
		if(err != nil)
			return (-1, nil, err);
		if(t == Ralert)
			return (-1, nil, "tlspsk: the server closed the handshake");
		if(t != Rhandshake)
			return (-1, nil, sys->sprint("tlspsk: record type %d in the handshake", t));
		rd.buf = cat2(rd.buf, b);
	}
}

writerec(wr: ref Rec, t: int, b: array of byte): string
{
	for(o := 0; o < len b || o == 0; ){
		n := len b - o;
		if(n > Maxfrag)
			n = Maxfrag;
		f := b[o:o+n];
		if(wr.key != nil){
			ad := cat(array[] of {u64(wr.seq), array[] of {byte t}, u16(Version), u16(n)});
			(ct, tag) := kr->ccpolyencrypt(f, ad, wr.key, nonce(wr.iv, wr.seq));
			wr.seq++;
			f = cat2(ct, tag);
		}
		r := cat(array[] of {array[] of {byte t}, u16(Version), u16(len f), f});
		if(sys->write(wr.fd, r, len r) != len r)
			return sys->sprint("tlspsk: write: %r");
		o += n;
		if(n == 0)
			break;
	}
	return nil;
}

nonce(iv: array of byte, seq: big): array of byte
{
	n := array[12] of byte;
	n[0:] = iv;
	s := u64(seq);
	for(i := 0; i < 8; i++)
		n[4+i] ^= s[i];
	return n;
}

hsmsg(t: int, b: array of byte): array of byte
{
	n := len b;
	return cat2(array[] of {byte t, byte (n>>16), byte (n>>8), byte n}, b);
}

# TLS 1.2's PRF, P_SHA256
prf(secret: array of byte, label: string, seed: array of byte, n: int): array of byte
{
	s := cat2(array of byte label, seed);
	out := array[n] of byte;
	a := s;
	for(o := 0; o < n; ){
		a = hmac(secret, a);
		p := hmac(secret, cat2(a, s));
		k := len p;
		if(o + k > n)
			k = n - o;
		out[o:] = p[0:k];
		o += k;
	}
	return out;
}

hmac(key, data: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

sha256(a: array of byte): array of byte
{
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return d;
}

random(n: int): array of byte
{
	b := IPint.random(0, 8*n).iptobebytes();
	out := array[n] of {* => byte 0};
	if(len b > n)
		b = b[len b - n:];
	out[n - len b:] = b;
	return out;
}

readn(fd: ref Sys->FD, b: array of byte, n: int): int
{
	for(m := 0; m < n; ){
		r := sys->read(fd, b[m:], n - m);
		if(r <= 0)
			return m;
		m += r;
	}
	return n;
}

u16(v: int): array of byte
{
	return array[] of {byte (v>>8), byte v};
}

u64(v: big): array of byte
{
	b := array[8] of byte;
	for(i := 7; i >= 0; i--){
		b[i] = byte v;
		v >>= 8;
	}
	return b;
}

g16(b: array of byte, o: int): int
{
	return (int b[o] << 8) | int b[o+1];
}

cat2(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

cat(l: array of array of byte): array of byte
{
	n := 0;
	for(i := 0; i < len l; i++)
		n += len l[i];
	r := array[n] of byte;
	n = 0;
	for(i = 0; i < len l; i++){
		r[n:] = l[i];
		n += len l[i];
	}
	return r;
}

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

zero(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}
