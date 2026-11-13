implement TLSHRRTest;

#
# TLS 1.3 HelloRetryRequest (RFC 8446 §4.1.4), against a scripted server.
#
# The client offers key shares for X25519MLKEM768 and X25519 only; P-256
# and P-384 are in supported_groups, and get a share when a server asks
# for one by HelloRetryRequest.  The scripted server here reads the
# ClientHellos, answers with a HelloRetryRequest (a group, a cookie, or
# both), and in the cases that should succeed carries the handshake through:
# its own ECDH, key schedule and AES-GCM, an EncryptedExtensions and a
# Finished, and then the client's Finished checked.  That check passes
# only if the client's transcript is the server's: message_hash(ClientHello1),
# the HRR, ClientHello2 and the rest (§4.4.1).
#
# The cases that should fail check the client's error: a group it sent a
# share for, or did not offer; an HRR that changes nothing; a second HRR;
# a ServerHello that does not agree with the HRR; an extension it did not
# send; a session id not echoed.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "tls.m";
	tls: TLS;
	Conn, Config: import tls;

include "testing.m";
	testing: Testing;
	T: import testing;

TLSHRRTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tls_hrr_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Named groups
X25519:		con 16r001D;
P256:		con 16r0017;
P384:		con 16r0018;
P521:		con 16r0019;
MLKEM768:	con 16r11EC;

AES128:		con 16r1301;	# TLS_AES_128_GCM_SHA256
AES256:		con 16r1302;	# TLS_AES_256_GCM_SHA384

HRRRANDOM: con "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c";

# What the scripted server does
Scenario: adt {
	hrr:		int;	# send a HelloRetryRequest first
	hrrsuite:	int;
	hrrgroup:	int;	# key_share selected_group; 0: no key_share
	cookie:		array of byte;	# nil: no cookie
	extra:		int;	# an extension type the client did not send; 0: none
	badsid:		int;	# echo a session id that is not the client's
	secondhrr:	int;	# answer ClientHello2 with another HRR
	shsuite:	int;	# ServerHello's suite; 0: hrrsuite (or AES128)
	shgroup:	int;	# ServerHello's group; 0: hrrgroup (or X25519)
	flight:	int;	# which messages follow the ServerHello (F* below); 0: EncryptedExtensions, Finished
	v12:		int;	# answer as a TLS 1.2 server would, with this flight (V* below); 0: TLS 1.3
};

# A TLS 1.3 server's encrypted flight before its Finished
Fee2, Fcertcvcert, Fcertfirst, Fcvnocert, Fnocv, Fcr2, Fwhole: con iota + 1;
# A TLS 1.2 server's flight
V12order, V12ske2, V12nocert, V12suite13, V12downgrade, V12plain: con iota + 1;

# A parsed ClientHello
Hello: adt {
	raw:	array of byte;	# the handshake message, header and all
	random:	array of byte;
	sid:	array of byte;
	suites:	array of byte;
	groups:	list of int;
	shares:	list of (int, array of byte);
	cookie:	array of byte;
};

# ================================================================
# Bytes
# ================================================================

put16(buf: array of byte, off, v: int)
{
	buf[off] = byte (v >> 8);
	buf[off+1] = byte v;
}

get16(buf: array of byte, off: int): int
{
	return (int buf[off] << 8) | int buf[off+1];
}

cat(a, b: array of byte): array of byte
{
	if(a == nil)
		return b;
	if(b == nil)
		return a;
	r := array [len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	a := array [len s / 2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hexdig(s[2*i]) << 4) | hexdig(s[2*i+1]));
	return a;
}

hexdig(c: int): int
{
	if(c >= 'a')
		return c - 'a' + 10;
	return c - '0';
}

contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

ext(etype: int, data: array of byte): array of byte
{
	e := array [4 + len data] of byte;
	put16(e, 0, etype);
	put16(e, 2, len data);
	e[4:] = data;
	return e;
}

u16(v: int): array of byte
{
	a := array [2] of byte;
	put16(a, 0, v);
	return a;
}

hsmsg(mtype: int, body: array of byte): array of byte
{
	n := len body;
	m := array [4 + n] of byte;
	m[0] = byte mtype;
	m[1] = byte (n >> 16);
	m[2] = byte (n >> 8);
	m[3] = byte n;
	m[4:] = body;
	return m;
}

record(ctype: int, payload: array of byte): array of byte
{
	r := array [5 + len payload] of byte;
	r[0] = byte ctype;
	put16(r, 1, 16r0303);
	put16(r, 3, len payload);
	r[5:] = payload;
	return r;
}

# ================================================================
# Hashes and the TLS 1.3 key schedule, for the server's side
# ================================================================

hashlen(suite: int): int
{
	if(suite == AES256)
		return 48;
	return 32;
}

hash(suite: int, data: array of byte): array of byte
{
	d := array [hashlen(suite)] of byte;
	if(suite == AES256)
		kr->sha384(data, len data, d, nil);
	else
		kr->sha256(data, len data, d, nil);
	return d;
}

hmac(suite: int, key, data: array of byte): array of byte
{
	d := array [hashlen(suite)] of byte;
	if(suite == AES256)
		kr->hmac_sha384(data, len data, key, d, nil);
	else
		kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

expandlabel(suite: int, secret: array of byte, label: string, ctx: array of byte, n: int): array of byte
{
	l := array of byte ("tls13 " + label);
	info := array [2 + 1 + len l + 1 + len ctx] of byte;
	put16(info, 0, n);
	info[2] = byte len l;
	info[3:] = l;
	info[3 + len l] = byte len ctx;
	info[4 + len l:] = ctx;
	out := array [n] of byte;
	prev: array of byte;
	for(i := 1; (i - 1) * hashlen(suite) < n; i++) {
		prev = hmac(suite, secret, cat(prev, cat(info, array[] of {byte i})));
		k := (i - 1) * hashlen(suite);
		m := len prev;
		if(k + m > n)
			m = n - k;
		out[k:] = prev[0:m];
	}
	return out;
}

TrafficKeys: adt {
	key:	array of byte;
	iv:	array of byte;
	seq:	int;
};

traffickeys(suite: int, secret: array of byte): ref TrafficKeys
{
	klen := 16;
	if(suite == AES256)
		klen = 32;
	return ref TrafficKeys(expandlabel(suite, secret, "key", nil, klen),
		expandlabel(suite, secret, "iv", nil, 12), 0);
}

nonce(k: ref TrafficKeys): array of byte
{
	n := array [12] of byte;
	n[0:] = k.iv;
	for(i := 0; i < 8; i++)
		n[11 - i] ^= byte (k.seq >> (8 * i));
	k.seq++;
	return n;
}

seal(k: ref TrafficKeys, ctype: int, msg: array of byte): array of byte
{
	inner := cat(msg, array[] of {byte ctype});
	aad := array [5] of byte;
	aad[0] = byte 23;
	put16(aad, 1, 16r0303);
	put16(aad, 3, len inner + 16);
	st := kr->aesgcmsetup(k.key, nonce(k));
	(ct, tag) := kr->aesgcmencrypt(st, inner, aad);
	return record(23, cat(ct, tag));
}

open(k: ref TrafficKeys, payload: array of byte): (int, array of byte)
{
	if(len payload < 17)
		return (-1, nil);
	aad := array [5] of byte;
	aad[0] = byte 23;
	put16(aad, 1, 16r0303);
	put16(aad, 3, len payload);
	st := kr->aesgcmsetup(k.key, nonce(k));
	n := len payload - 16;
	pt := kr->aesgcmdecrypt(st, payload[0:n], aad, payload[n:]);
	if(pt == nil || len pt < 1)
		return (-1, nil);
	return (int pt[len pt - 1], pt[0:len pt - 1]);
}

# ================================================================
# The scripted server
# ================================================================

readn(fd: ref Sys->FD, n: int): array of byte
{
	buf := array [n] of byte;
	for(got := 0; got < n; ) {
		r := sys->read(fd, buf[got:], n - got);
		if(r <= 0)
			return nil;
		got += r;
	}
	return buf;
}

readrecord(fd: ref Sys->FD): (int, array of byte)
{
	h := readn(fd, 5);
	if(h == nil)
		return (-1, nil);
	p := readn(fd, get16(h, 3));
	if(p == nil)
		return (-1, nil);
	return (int h[0], p);
}

# Read a ClientHello (one record holds it) and parse what we look at
readhello(fd: ref Sys->FD): (ref Hello, string)
{
	(ctype, m) := readrecord(fd);
	if(ctype < 0)
		return (nil, "eof");
	if(ctype != 22 || len m < 4 || int m[0] != 1)
		return (nil, sys->sprint("expected a ClientHello, got record %d", ctype));
	h := ref Hello;
	h.raw = m;
	b := m[4:];
	off := 2;
	h.random = b[off:off+32];
	off += 32;
	h.sid = b[off+1:off+1+int b[off]];
	off += 1 + int b[off];
	h.suites = b[off+2:off+2+get16(b, off)];
	off += 2 + get16(b, off);
	off += 1 + int b[off];
	end := off + 2 + get16(b, off);
	off += 2;
	while(off < end) {
		etype := get16(b, off);
		elen := get16(b, off + 2);
		d := b[off+4:off+4+elen];
		off += 4 + elen;
		case etype {
		10 =>
			for(i := 2; i < len d; i += 2)
				h.groups = get16(d, i) :: h.groups;
			h.groups = rev(h.groups);
		51 =>
			for(i := 2; i < len d; ) {
				g := get16(d, i);
				n := get16(d, i + 2);
				h.shares = (g, d[i+4:i+4+n]) :: h.shares;
				i += 4 + n;
			}
			h.shares = revshares(h.shares);
		44 =>
			h.cookie = d[2:];
		}
	}
	return (h, nil);
}

rev(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revshares(l: list of (int, array of byte)): list of (int, array of byte)
{
	r: list of (int, array of byte);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

sharegroups(h: ref Hello): list of int
{
	r: list of int;
	for(l := h.shares; l != nil; l = tl l) {
		(g, nil) := hd l;
		r = g :: r;
	}
	return rev(r);
}

share(h: ref Hello, group: int): array of byte
{
	for(l := h.shares; l != nil; l = tl l) {
		(g, d) := hd l;
		if(g == group)
			return d;
	}
	return nil;
}

member(l: list of int, x: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}

listeq(a, b: list of int): int
{
	for(; a != nil && b != nil; (a, b) = (tl a, tl b))
		if(hd a != hd b)
			return 0;
	return a == nil && b == nil;
}

groupstr(l: list of int): string
{
	s := "";
	for(; l != nil; l = tl l)
		s += sys->sprint(" %04x", hd l);
	return s;
}

mkhrr(sc: ref Scenario, sid: array of byte): array of byte
{
	if(sc.badsid) {
		bad := array [len sid] of byte;
		bad[0:] = sid;
		bad[0] ^= byte 1;
		sid = bad;
	}
	exts := ext(43, u16(16r0304));
	if(sc.hrrgroup != 0)
		exts = cat(exts, ext(51, u16(sc.hrrgroup)));
	if(sc.cookie != nil)
		exts = cat(exts, ext(44, cat(u16(len sc.cookie), sc.cookie)));
	if(sc.extra != 0)
		exts = cat(exts, ext(sc.extra, nil));
	return hsmsg(2, cat(u16(16r0303), cat(unhex(HRRRANDOM), cat(array[] of {byte len sid}, cat(sid,
		cat(u16(sc.hrrsuite), cat(array[] of {byte 0}, cat(u16(len exts), exts))))))));
}

mkserverhello(suite: int, sid: array of byte, group: int, sshare: array of byte): array of byte
{
	random := array [32] of {* => byte 16r5A};
	exts := cat(ext(43, u16(16r0304)), ext(51, cat(u16(group), cat(u16(len sshare), sshare))));
	return hsmsg(2, cat(u16(16r0303), cat(random, cat(array[] of {byte len sid}, cat(sid,
		cat(u16(suite), cat(array[] of {byte 0}, cat(u16(len exts), exts))))))));
}

# The server's share for group, and the secret it shares with cshare (nil if
# the client sent none, or it is bad)
serverkex(group: int, cshare: array of byte): (array of byte, array of byte)
{
	case group {
	X25519 =>
		priv := array [32] of {* => byte 16r33};
		pub := kr->x25519_base(priv);
		if(cshare == nil || len cshare != 32)
			return (pub, nil);
		return (pub, kr->x25519(priv, cshare));
	P256 =>
		(priv, pt) := kr->p256_keygen();
		pub := kr->p256_point_bytes(pt);
		if(cshare == nil)
			return (pub, nil);
		cpt := kr->p256_make_point(cshare);
		if(cpt == nil)
			return (pub, nil);
		return (pub, kr->p256_ecdh(priv, cpt));
	P384 =>
		(priv, pub) := kr->p384_keygen();
		if(cshare == nil)
			return (pub, nil);
		return (pub, kr->p384_ecdh(priv, cshare));
	}
	return (array [32] of {* => byte 1}, nil);
}

server(fd: ref Sys->FD, sc: ref Scenario, result: chan of string)
{
	r: string;
	{
		r = server0(fd, sc);
	} exception e {
	"*" =>
		r = "server: exception " + e;
	}
	result <-= r;
}

server0(fd: ref Sys->FD, sc: ref Scenario): string
{
	(ch1, e1) := readhello(fd);
	if(ch1 == nil)
		return "ClientHello1: " + e1;

	# shares for the hybrid and X25519 only; P-256 and P-384 offered without
	if(!listeq(sharegroups(ch1), MLKEM768 :: X25519 :: nil))
		return "ClientHello1 shares" + groupstr(sharegroups(ch1)) + ", want 11ec 001d";
	if(!member(ch1.groups, P256) || !member(ch1.groups, P384))
		return "ClientHello1 supported_groups" + groupstr(ch1.groups) + " lacks P-256 or P-384";
	if(ch1.cookie != nil)
		return "ClientHello1 has a cookie";

	suite := AES128;
	transcript: array of byte;
	ch := ch1;
	if(sc.hrr) {
		suite = sc.hrrsuite;
		hrr := mkhrr(sc, ch1.sid);
		writeall(fd, record(22, hrr));
		transcript = cat(hsmsg(254, hash(suite, ch1.raw)), hrr);

		(ch2, e2) := readhello(fd);
		if(ch2 == nil)
			return "ClientHello2: " + e2;
		if(!eq(ch2.random, ch1.random))
			return "ClientHello2 random differs";
		if(!eq(ch2.sid, ch1.sid))
			return "ClientHello2 session id differs";
		if(!eq(ch2.suites, ch1.suites))
			return "ClientHello2 cipher suites differ";
		if(!listeq(ch2.groups, ch1.groups))
			return "ClientHello2 supported_groups differ";
		if(sc.cookie == nil && ch2.cookie != nil)
			return "ClientHello2 has a cookie the server did not send";
		if(sc.cookie != nil && (ch2.cookie == nil || !eq(ch2.cookie, sc.cookie)))
			return "ClientHello2 cookie " + hex(ch2.cookie) + ", want " + hex(sc.cookie);
		if(sc.hrrgroup != 0) {
			if(!listeq(sharegroups(ch2), sc.hrrgroup :: nil))
				return "ClientHello2 shares" + groupstr(sharegroups(ch2)) + sys->sprint(", want %04x alone", sc.hrrgroup);
			want := 65;
			if(sc.hrrgroup == P384)
				want = 97;
			if(len share(ch2, sc.hrrgroup) != want)
				return sys->sprint("ClientHello2 share is %d bytes, want %d", len share(ch2, sc.hrrgroup), want);
		}else if(!listeq(sharegroups(ch2), sharegroups(ch1)))
			return "ClientHello2 shares" + groupstr(sharegroups(ch2)) + " differ from ClientHello1's";
		transcript = cat(transcript, ch2.raw);
		ch = ch2;
		if(sc.secondhrr) {
			writeall(fd, record(22, hrr));
			return waiteof(fd);
		}
	}else
		transcript = ch1.raw;

	if(sc.v12 != 0)
		return server12(fd, sc, ch);

	if(sc.shsuite != 0)
		suite = sc.shsuite;
	group := sc.shgroup;
	if(group == 0)
		group = sc.hrrgroup;
	if(group == 0)
		group = X25519;
	(sshare, ss) := serverkex(group, share(ch, group));
	sh := mkserverhello(suite, ch.sid, group, sshare);
	writeall(fd, record(22, sh));
	transcript = cat(transcript, sh);
	if(ss == nil)
		return waiteof(fd);

	# handshake keys
	hl := hashlen(suite);
	zeros := array [hl] of {* => byte 0};
	early := hmac(suite, zeros, zeros);
	derived := expandlabel(suite, early, "derived", hash(suite, nil), hl);
	hs := hmac(suite, derived, ss);
	th := hash(suite, transcript);
	chs := expandlabel(suite, hs, "c hs traffic", th, hl);
	shs := expandlabel(suite, hs, "s hs traffic", th, hl);
	skeys := traffickeys(suite, shs);
	ckeys := traffickeys(suite, chs);

	ee := hsmsg(8, u16(0));
	# a certificate of ten bytes with no extensions, a CertificateVerify
	# of four, a CertificateRequest asking for nothing: their order is
	# what is tested, and the client is not verifying (config.insecure)
	cert := hsmsg(11, cat(array[] of {byte 0, byte 0, byte 0, byte 15, byte 0, byte 0, byte 10},
		cat(array[10] of {* => byte 16r30}, u16(0))));
	cv := hsmsg(15, cat(u16(16r0804), cat(u16(4), array[4] of {* => byte 1})));
	cr := hsmsg(13, cat(array[] of {byte 0}, u16(0)));
	msgs: list of array of byte;
	case sc.flight {
	Fee2 =>
		msgs = ee :: ee :: nil;
	Fcertcvcert =>
		msgs = ee :: cert :: cv :: cert :: nil;
	Fcertfirst =>
		msgs = cert :: ee :: nil;
	Fcvnocert =>
		msgs = ee :: cv :: nil;
	Fnocv =>
		msgs = ee :: cert :: nil;
	Fcr2 =>
		msgs = ee :: cr :: cr :: nil;
	Fwhole =>
		msgs = ee :: cert :: cv :: nil;
	* =>
		msgs = ee :: nil;
	}
	out: array of byte;
	for(; msgs != nil; msgs = tl msgs){
		transcript = cat(transcript, hd msgs);
		out = cat(out, seal(skeys, 22, hd msgs));
	}
	sfin := hsmsg(20, hmac(suite, expandlabel(suite, shs, "finished", nil, hl), hash(suite, transcript)));
	transcript = cat(transcript, sfin);
	out = cat(out, seal(skeys, 22, sfin));
	writeall(fd, out);
	if(sc.flight != 0 && sc.flight != Fwhole)
		return waiteof(fd);	# the client is to refuse it

	# the client's Finished, over the transcript as we have it
	(ctype, payload) := readrecord(fd);
	if(ctype < 0)
		return "eof before the client's Finished";
	if(ctype != 23)
		return sys->sprint("client sent record %d, want an encrypted Finished", ctype);
	(itype, msg) := open(ckeys, payload);
	if(itype != 22)
		return "client's Finished does not decrypt";
	want := hsmsg(20, hmac(suite, expandlabel(suite, chs, "finished", nil, hl), hash(suite, transcript)));
	if(!eq(msg, want))
		return "client's Finished does not match the server's transcript";
	return "ok";
}

# A TLS 1.2 server's answer to ch, in the clear: ServerHello and the
# flight sc.v12 names.  The client is to refuse each before it sends
# anything, so nothing is read but the end of the connection.
server12(fd: ref Sys->FD, sc: ref Scenario, ch: ref Hello): string
{
	random := array [32] of {* => byte 16r5A};
	suite := 16rC02F;	# TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
	if(sc.v12 == V12suite13)
		suite = AES128;
	if(sc.v12 == V12downgrade)
		random[24:] = array[] of {byte 16r44, byte 16r4f, byte 16r57, byte 16r4e, byte 16r47, byte 16r52, byte 16r44, byte 1};
	sh := hsmsg(2, cat(u16(16r0303), cat(random, cat(array[] of {byte len ch.sid}, cat(ch.sid,
		cat(u16(suite), array[] of {byte 0}))))));
	# a certificate of ten bytes; a key exchange on X25519 with a signature of four
	cert := hsmsg(11, cat(array[] of {byte 0, byte 0, byte 13, byte 0, byte 0, byte 10}, array[10] of {* => byte 16r30}));
	pub := kr->x25519_base(array [32] of {* => byte 16r33});
	ske := hsmsg(12, cat(array[] of {byte 3, byte 0, byte 16r1d, byte 32}, cat(pub,
		cat(u16(16r0804), cat(u16(4), array[4] of {* => byte 1})))));
	done := hsmsg(14, nil);
	msgs: list of array of byte;
	case sc.v12 {
	V12order =>
		msgs = sh :: cert :: ske :: cert :: done :: nil;
	V12ske2 =>
		msgs = sh :: cert :: ske :: ske :: done :: nil;
	V12nocert =>
		msgs = sh :: done :: nil;
	* =>
		msgs = sh :: nil;	# refused at the ServerHello
	}
	# in one write: the client hangs up at the message it refuses
	out: array of byte;
	for(; msgs != nil; msgs = tl msgs)
		out = cat(out, record(22, hd msgs));
	writeall(fd, out);
	return waiteof(fd);
}

writeall(fd: ref Sys->FD, b: array of byte)
{
	sys->write(fd, b, len b);
}

waiteof(fd: ref Sys->FD): string
{
	buf := array [4096] of byte;
	while(sys->read(fd, buf, len buf) > 0)
		;
	return "eof";
}

# ================================================================
# Running a scenario
# ================================================================

timer(pid: chan of int, c: chan of int, ms: int)
{
	pid <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# Run sc, a handshake that must fail with an error containing want
runscenario(t: ref T, sc: ref Scenario, want: string)
{
	runscenariomin(t, sc, want, TLS->TLS12);
}

# the same, with a client that takes no version below minver
runscenariomin(t: ref T, sc: ref Scenario, want: string, minver: int)
{
	p := array [2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	result := chan[1] of string;
	spawn server(p[1], sc, result);
	p[1] = nil;

	config := tls->defaultconfig();
	config.servername = "test.example.com";
	config.insecure = 1;
	config.minver = minver;
	(conn, err) := tls->client(p[0], config);
	p[0] = nil;
	if(conn != nil)
		conn.close();
	conn = nil;

	srv := waitserver(result);
	if(err == nil)
		t.fatal("handshake succeeded; want an error containing '" + want + "'");
	if(!contains(err, want))
		t.error("error '" + err + "' does not contain '" + want + "'");
	else
		t.log("got expected error: " + err);
	# the client gave up, so the server read the end of the pipe
	if(!contains(srv, "eof"))
		t.error("server: " + srv);
}

waitserver(result: chan of string): string
{
	timeout := chan[1] of int;
	pid := chan of int;
	spawn timer(pid, timeout, 15000);
	tpid := <-pid;
	alt {
	srv := <-result =>
		kill(tpid);
		return srv;
	<-timeout =>
		return "server timed out";
	}
}

# Run sc, a handshake that must succeed with group
runok(t: ref T, sc: ref Scenario, group: int)
{
	p := array [2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	result := chan[1] of string;
	spawn server(p[1], sc, result);
	p[1] = nil;

	config := tls->defaultconfig();
	config.servername = "test.example.com";
	config.insecure = 1;
	(conn, err) := tls->client(p[0], config);
	p[0] = nil;

	srv := waitserver(result);
	if(err != nil)
		t.fatal("handshake failed: " + err + "; server: " + srv);
	t.assertseq(srv, "ok", "server's view of the handshake");
	t.asserteq(conn.group, group, "negotiated group");
	t.asserteq(conn.version, TLS->TLS13, "version");
	suite := sc.shsuite;
	if(suite == 0)
		suite = sc.hrrsuite;
	t.asserteq(conn.suite, suite, "cipher suite");
	# not conn.close(): its close_notify would go to a server that has gone
}

# ================================================================
# Tests
# ================================================================

# HRR selecting P-256 and sending a cookie: ClientHello2 carries one
# P-256 share and the cookie, the rest as before; the handshake completes.
testHRRP256Cookie(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, array of byte "a cookie, opaque to the client", 0, 0, 0, 0, 0, 0, 0);
	runok(t, sc, P256);
}

# HRR selecting P-384, no cookie
testHRRP384(t: ref T)
{
	sc := ref Scenario(1, AES128, P384, nil, 0, 0, 0, 0, 0, 0, 0);
	runok(t, sc, P384);
}

# HRR with a cookie and no key_share (a stateless server checking the
# client's address): ClientHello2 repeats the shares with the cookie.
# The suite is the SHA-384 one, so the message_hash is SHA-384's.
testHRRCookieOnlySHA384(t: ref T)
{
	cookie := array [300] of byte;
	for(i := 0; i < len cookie; i++)
		cookie[i] = byte (i * 7);
	sc := ref Scenario(1, AES256, 0, cookie, 0, 0, 0, 0, 0, 0, 0);
	runok(t, sc, X25519);
}

# HRR selecting P-256, under the SHA-384 suite
testHRRP256SHA384(t: ref T)
{
	sc := ref Scenario(1, AES256, P256, nil, 0, 0, 0, 0, 0, 0, 0);
	runok(t, sc, P256);
}

# No HRR: a server taking X25519 needs none
testNoHRR(t: ref T)
{
	sc := ref Scenario(0, AES128, 0, nil, 0, 0, 0, 0, X25519, 0, 0);
	runok(t, sc, X25519);
}

# A ServerHello (no HRR) choosing P-256, for which no share was sent
testServerHelloUnsentGroup(t: ref T)
{
	sc := ref Scenario(0, AES128, 0, nil, 0, 0, 0, 0, P256, 0, 0);
	runscenario(t, sc, "which we did not send");
}

testHRRGroupAlreadyShared(t: ref T)
{
	sc := ref Scenario(1, AES128, X25519, nil, 0, 0, 0, 0, 0, 0, 0);
	runscenario(t, sc, "which we sent a share for");
}

testHRRGroupNotOffered(t: ref T)
{
	sc := ref Scenario(1, AES128, P521, nil, 0, 0, 0, 0, 0, 0, 0);
	runscenario(t, sc, "which we did not offer");
}

testHRRNoChange(t: ref T)
{
	sc := ref Scenario(1, AES128, 0, nil, 0, 0, 0, 0, 0, 0, 0);
	runscenario(t, sc, "asks for no change");
}

testHRRUnknownExtension(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, nil, 16r1234, 0, 0, 0, 0, 0, 0);
	runscenario(t, sc, "we did not send");
}

testHRRBadSessionID(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, nil, 0, 1, 0, 0, 0, 0, 0);
	runscenario(t, sc, "session id");
}

testHRRUnofferedSuite(t: ref T)
{
	sc := ref Scenario(1, 16rC02F, P256, nil, 0, 0, 0, 0, 0, 0, 0);
	runscenario(t, sc, "unsupported suite");
}

testSecondHRR(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, array of byte "c", 0, 0, 1, 0, 0, 0, 0);
	runscenario(t, sc, "second HelloRetryRequest");
}

testServerHelloSuiteDiffers(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, nil, 0, 0, 0, AES256, 0, 0, 0);
	runscenario(t, sc, "cipher suite differs");
}

testServerHelloGroupDiffers(t: ref T)
{
	sc := ref Scenario(1, AES128, P256, nil, 0, 0, 0, 0, X25519, 0, 0);
	runscenario(t, sc, "key share differs");
}

# ================================================================
# The order of a server's handshake messages.  They were taken in any
# order and any number, the last Certificate replacing the one before,
# so the chain verified at the end need not be the one whose key signed
# the handshake.  The client here verifies nothing (config.insecure):
# what is tested is that the order is refused before verification is
# reached at all.
# ================================================================

flight(f: int): ref Scenario
{
	return ref Scenario(0, AES128, 0, nil, 0, 0, 0, 0, X25519, f, 0);
}

testOrder13(t: ref T)
{
	runscenario(t, flight(Fcertcvcert), "Certificate out of order or sent twice");
	runscenario(t, flight(Fee2), "EncryptedExtensions out of order or sent twice");
	runscenario(t, flight(Fcertfirst), "Certificate out of order");
	runscenario(t, flight(Fcvnocert), "CertificateVerify out of order");
	runscenario(t, flight(Fnocv), "with no CertificateVerify");
	runscenario(t, flight(Fcr2), "CertificateRequest out of order or sent twice");
}

# each message once and in order is still a handshake
testOrder13Whole(t: ref T)
{
	runok(t, flight(Fwhole), X25519);
}

v12(v: int): ref Scenario
{
	return ref Scenario(0, AES128, 0, nil, 0, 0, 0, 0, 0, 0, v);
}

testOrder12(t: ref T)
{
	runscenario(t, v12(V12order), "Certificate out of order or sent twice");
	runscenario(t, v12(V12ske2), "ServerKeyExchange out of order or sent twice");
	runscenario(t, v12(V12nocert), "ServerHelloDone before Certificate");
}

# the version and suite a ServerHello chooses
testServerHelloVersion(t: ref T)
{
	# a TLS 1.3 suite under TLS 1.2: it has no key exchange of 1.2's
	runscenario(t, v12(V12suite13), "is not one of version");
	# RFC 8446 4.1.3: the mark a 1.3 server leaves when asked for less
	runscenario(t, v12(V12downgrade), "downgrade");
	# a client set for 1.3 only, answered in 1.2
	runscenariomin(t, v12(V12plain), "outside what is configured", TLS->TLS13);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	testing = load Testing Testing->PATH;
	tls = load TLS TLS->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(tls == nil || kr == nil) {
		sys->fprint(sys->fildes(2), "cannot load TLS or Keyring: %r\n");
		raise "fail:cannot load TLS";
	}

	# host /dev/urandom, where there is one, for tls->client's randomness
	sys->bind("#U/dev", "/dev", Sys->MAFTER);

	testing->init();
	terr := tls->init();
	if(terr != nil) {
		sys->fprint(sys->fildes(2), "TLS init failed: %s\n", terr);
		raise "fail:TLS init";
	}
	# the scripted server's first ClientHello check assumes the default
	# key shares, which /env/cnsatls would change
	sys->remove("/env/cnsatls");

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("HRRP256Cookie", testHRRP256Cookie);
	run("HRRP384", testHRRP384);
	run("HRRCookieOnlySHA384", testHRRCookieOnlySHA384);
	run("HRRP256SHA384", testHRRP256SHA384);
	run("NoHRR", testNoHRR);
	run("ServerHelloUnsentGroup", testServerHelloUnsentGroup);
	run("HRRGroupAlreadyShared", testHRRGroupAlreadyShared);
	run("HRRGroupNotOffered", testHRRGroupNotOffered);
	run("HRRNoChange", testHRRNoChange);
	run("HRRUnknownExtension", testHRRUnknownExtension);
	run("HRRBadSessionID", testHRRBadSessionID);
	run("HRRUnofferedSuite", testHRRUnofferedSuite);
	run("SecondHRR", testSecondHRR);
	run("ServerHelloSuiteDiffers", testServerHelloSuiteDiffers);
	run("ServerHelloGroupDiffers", testServerHelloGroupDiffers);
	run("Order13", testOrder13);
	run("Order13Whole", testOrder13Whole);
	run("Order12", testOrder12);
	run("ServerHelloVersion", testServerHelloVersion);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
