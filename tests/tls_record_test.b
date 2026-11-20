implement TlsRecordTest;

#
# A TLS connection after its handshake (appl/lib/crypt/tls.b: Conn.read,
# Conn.write, the record layer, alerts, KeyUpdate and the other
# post-handshake messages), given what a peer may send once it holds
# the keys, and what one on the path may do to the bytes.
#
# The handshake had a handler and was held to "a connection or an
# error"; what came after it was not looked at.  A record with no data
# in it, which a peer may send as often as it likes (RFC 8446 5.1), was
# a read of 0, the end of the file to a caller that had not been sent
# one (webclient's pump stopped there).  A NewSessionTicket that went
# on in a second record ended the connection, the rest of it read as
# the start of another message; under TLS 1.2 any handshake message at
# all was passed over.  A record was held to 2^14 + 256 bytes as it
# arrived and to nothing once opened.  A read asked for more than its
# buffer held, and a write to a peer that had gone, were exceptions in
# the caller.  After a close_notify the next read read on.  A client
# never answered a KeyUpdate and never sent one; a server answered from
# its reader, beside whatever its writer was sending.  No sequence
# number had an end.
#
# Each end here is a TLS->State made by the test, with keys of its own
# choosing, on one end of a pipe; the test is the peer on the other,
# sealing and opening records with Keyring (so the module's key
# schedule for a KeyUpdate is checked against RFC 8446 7.2 written
# again here).  TLS 1.3 with each of its suites, as client and as
# server; TLS 1.2 with AES-GCM, as client.  Then some thousands of
# streams of good records, each changed, cut or lengthened somewhere:
# every one ends in an error or a clean close, none in an exception,
# and no byte is given to the reader that the peer did not send.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "tls.m";
	tls: TLS;
	Conn, State: import tls;
include "testing.m";
	testing: Testing;
	T: import testing;

TlsRecordTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/tls_record_test.b";
MUTANTS: con 3000;

CT_CCS: con 20;
CT_ALERT: con 21;
CT_HS: con 22;
CT_DATA: con 23;

HT_NST: con 4;
HT_KU: con 24;

GCM12: con TLS->TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;

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
		t.failed = 1;
		t.log("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# ---- the test's own end

# What the test seals records with (the module end's reading keys) and
# opens them with (its writing keys)
Peer: adt {
	fd:	ref Sys->FD;
	version:	int;
	suite:	int;
	ssecret:	array of byte;	# TLS 1.3: the traffic secret it sends under
	skey, siv:	array of byte;
	sseq:	big;
	rsecret:	array of byte;
	rkey, riv:	array of byte;
	rseq:	big;
};

rand(n: int): array of byte
{
	b := array[n] of byte;
	fd := sys->open("/dev/notquiterandom", Sys->OREAD);
	if(fd == nil || sys->read(fd, b, n) != n)
		for(i := 0; i < n; i++)
			b[i] = byte (i * 37 + n);
	return b;
}

hashlen(suite: int): int
{
	if(suite == TLS->TLS_AES_256_GCM_SHA384)
		return 48;
	return 32;
}

keylen(suite: int): int
{
	if(suite == TLS->TLS_AES_128_GCM_SHA256 || suite == GCM12)
		return 16;
	return 32;
}

put16(a: array of byte, o, v: int)
{
	a[o] = byte (v >> 8);
	a[o+1] = byte v;
}

put64(a: array of byte, o: int, v: big)
{
	for(i := 0; i < 8; i++)
		a[o+i] = byte (v >> (56 - 8*i));
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	if(len a > 0)
		r[0:] = a;
	if(len b > 0)
		r[len a:] = b;
	return r;
}

# HKDF-Expand-Label (RFC 8446 7.1), for outputs of one block
expandlabel(suite: int, secret: array of byte, label: string, n: int): array of byte
{
	l := array of byte ("tls13 " + label);
	info := array[2 + 1 + len l + 1 + 1] of byte;
	put16(info, 0, n);
	info[2] = byte len l;
	info[3:] = l;
	info[3 + len l] = byte 0;
	info[4 + len l] = byte 1;	# T(1) = HMAC(secret, info | 01)
	d := array[hashlen(suite)] of byte;
	if(hashlen(suite) == 48)
		kr->hmac_sha384(info, len info, secret, d, nil);
	else
		kr->hmac_sha256(info, len info, secret, d, nil);
	return d[0:n];
}

keys(suite: int, secret: array of byte): (array of byte, array of byte)
{
	return (expandlabel(suite, secret, "key", keylen(suite)), expandlabel(suite, secret, "iv", 12));
}

# The module's end and the test's, on a pipe
pair(version, suite, isserver: int): (ref Conn, ref Peer)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		raise sys->sprint("fail:pipe: %r");
	st := ref State;
	st.fd = p[0];
	st.version = version;
	st.suite = suite;
	st.isserver = isserver;
	st.done = 1;
	st.readseq = big 0;
	st.writeseq = big 0;
	pr := ref Peer;
	pr.fd = p[1];
	pr.version = version;
	pr.suite = suite;
	pr.sseq = big 0;
	pr.rseq = big 0;
	if(version == TLS->TLS13) {
		st.cts = rand(hashlen(suite));
		st.sts = rand(hashlen(suite));
		if(isserver) {
			(pr.ssecret, pr.rsecret) = (st.cts, st.sts);
		} else {
			(pr.ssecret, pr.rsecret) = (st.sts, st.cts);
		}
		(pr.skey, pr.siv) = keys(suite, pr.ssecret);
		(pr.rkey, pr.riv) = keys(suite, pr.rsecret);
	} else {
		pr.skey = rand(keylen(suite));
		pr.siv = rand(4);
		pr.rkey = rand(keylen(suite));
		pr.riv = rand(4);
	}
	(st.readkey, st.readiv) = (pr.skey, pr.siv);
	(st.writekey, st.writeiv) = (pr.rkey, pr.riv);
	c := ref Conn;
	c.version = version;
	c.suite = suite;
	c.st = st;
	return (c, pr);
}

nonce13(iv: array of byte, seq: big): array of byte
{
	n := array[12] of byte;
	n[0:] = iv;
	for(i := 0; i < 8; i++)
		n[4+i] ^= byte (seq >> (56 - 8*i));
	return n;
}

header(ctype, n: int): array of byte
{
	h := array[5] of byte;
	h[0] = byte ctype;
	put16(h, 1, 16r0303);
	put16(h, 3, n);
	return h;
}

# A TLS 1.3 record of inner (the whole TLSInnerPlaintext: content, its
# type, any padding) under the peer's sending key
seal13(pr: ref Peer, inner: array of byte): array of byte
{
	if(inner == nil)
		inner = array[0] of byte;
	h := header(CT_DATA, len inner + 16);
	n := nonce13(pr.siv, pr.sseq++);
	ct, tag: array of byte;
	if(pr.suite == TLS->TLS_CHACHA20_POLY1305_SHA256)
		(ct, tag) = kr->ccpolyencrypt(inner, h, pr.skey, n);
	else
		(ct, tag) = kr->aesgcmencrypt(kr->aesgcmsetup(pr.skey, n), inner, h);
	return cat(cat(h, ct), tag);
}

# A TLS 1.2 AES-GCM record (RFC 5288)
seal12(pr: ref Peer, ctype: int, body: array of byte): array of byte
{
	if(body == nil)
		body = array[0] of byte;
	explicit := array[8] of byte;
	put64(explicit, 0, pr.sseq);
	n := cat(pr.siv, explicit);
	aad := array[13] of byte;
	put64(aad, 0, pr.sseq++);
	aad[8] = byte ctype;
	put16(aad, 9, 16r0303);
	put16(aad, 11, len body);
	(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(pr.skey, n), body, aad);
	return cat(header(ctype, 8 + len ct + 16), cat(cat(explicit, ct), tag));
}

# A record of type ctype holding body, as the peer's version seals it
seal(pr: ref Peer, ctype: int, body: array of byte): array of byte
{
	if(pr.version == TLS->TLS13)
		return seal13(pr, cat(body, array[] of {byte ctype}));
	return seal12(pr, ctype, body);
}

# One record the module's end wrote: (type, contents), or (-1, nil)
open(pr: ref Peer): (int, array of byte)
{
	h := array[5] of byte;
	if(readn(pr.fd, h) != 5)
		return (-1, nil);
	n := (int h[3] << 8) | int h[4];
	b := array[n] of byte;
	if(readn(pr.fd, b) != n || n < 16)
		return (-1, nil);
	pt: array of byte;
	ctype := int h[0];
	if(pr.version == TLS->TLS13) {
		nn := nonce13(pr.riv, pr.rseq++);
		if(pr.suite == TLS->TLS_CHACHA20_POLY1305_SHA256)
			pt = kr->ccpolydecrypt(b[0:n-16], h, b[n-16:], pr.rkey, nn);
		else
			pt = kr->aesgcmdecrypt(kr->aesgcmsetup(pr.rkey, nn), b[0:n-16], h, b[n-16:]);
		if(pt == nil || len pt < 1)
			return (-1, nil);
		ctype = int pt[len pt - 1];
		pt = pt[0:len pt - 1];
	} else {
		if(n < 24)
			return (-1, nil);
		aad := array[13] of byte;
		put64(aad, 0, pr.rseq++);
		aad[8] = h[0];
		put16(aad, 9, 16r0303);
		put16(aad, 11, n - 24);
		pt = kr->aesgcmdecrypt(kr->aesgcmsetup(pr.rkey, cat(pr.riv, b[0:8])), b[8:n-16], aad, b[n-16:]);
		if(pt == nil)
			return (-1, nil);
	}
	return (ctype, pt);
}

readn(fd: ref Sys->FD, b: array of byte): int
{
	for(i := 0; i < len b; ) {
		m := sys->read(fd, b[i:], len b - i);
		if(m <= 0)
			break;
		i += m;
	}
	return i;
}

# the peer's next sending key, as its KeyUpdate promises (RFC 8446 7.2)
update(pr: ref Peer)
{
	pr.ssecret = expandlabel(pr.suite, pr.ssecret, "traffic upd", hashlen(pr.suite));
	(pr.skey, pr.siv) = keys(pr.suite, pr.ssecret);
	pr.sseq = big 0;
}

# and the one it reads under, when the module's end sends one
updater(pr: ref Peer)
{
	pr.rsecret = expandlabel(pr.suite, pr.rsecret, "traffic upd", hashlen(pr.suite));
	(pr.rkey, pr.riv) = keys(pr.suite, pr.rsecret);
	pr.rseq = big 0;
}

hsmsg(mtype: int, body: array of byte): array of byte
{
	h := array[4] of byte;
	h[0] = byte mtype;
	h[1] = byte (len body >> 16);
	h[2] = byte (len body >> 8);
	h[3] = byte len body;
	return cat(h, body);
}

writer(fd: ref Sys->FD, b: array of byte, done: chan of int)
{
	{
		for(o := 0; o < len b; ) {
			m := len b - o;
			if(m > 4096)
				m = 4096;
			if(sys->write(fd, b[o:o+m], m) != m)
				break;
			o += m;
		}
	} exception {
	"*" =>
		;
	}
	fd = nil;
	done <-= 1;
}

# The peer sends b and goes: the pipe is written from a Prog of its
# own (it holds less than a record), and closed after
send(pr: ref Peer, b: array of byte): chan of int
{
	done := chan[1] of int;
	fd := pr.fd;
	pr.fd = nil;
	spawn writer(fd, b, done);
	fd = nil;
	return done;
}

# One read: (count, the bytes, the error string), -2 for an exception
rd(c: ref Conn, n: int): (int, array of byte, string)
{
	buf := array[n] of byte;
	r := -2;
	{
		r = c.read(buf, n);
		if(r < 0)
			return (r, nil, sys->sprint("%r"));
	} exception e {
	"*" =>
		return (-2, nil, "EXCEPTION " + e);
	}
	if(r > n)
		return (-2, nil, sys->sprint("read gave %d of %d", r, n));
	return (r, buf[0:r], nil);
}

# Everything the module's end gives until it stops: (the data, the
# last count, its error string)
drain(c: ref Conn): (array of byte, int, string)
{
	all := array[0] of byte;
	for(i := 0; i < 100000; i++) {
		(r, b, e) := rd(c, 4096);
		if(r <= 0)
			return (all, r, e);
		all = cat(all, b);
	}
	return (all, -3, "the reads did not end");
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
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

# ---- the cases

Kind: adt {
	version:	int;
	suite:	int;
	isserver:	int;
	name:	string;
};

kinds(): list of ref Kind
{
	return
		ref Kind(TLS->TLS13, TLS->TLS_AES_128_GCM_SHA256, 0, "1.3 AES-128-GCM client") ::
		ref Kind(TLS->TLS13, TLS->TLS_AES_256_GCM_SHA384, 0, "1.3 AES-256-GCM client") ::
		ref Kind(TLS->TLS13, TLS->TLS_CHACHA20_POLY1305_SHA256, 0, "1.3 ChaCha20 client") ::
		ref Kind(TLS->TLS13, TLS->TLS_AES_128_GCM_SHA256, 1, "1.3 AES-128-GCM server") ::
		ref Kind(TLS->TLS13, TLS->TLS_AES_256_GCM_SHA384, 1, "1.3 AES-256-GCM server") ::
		ref Kind(TLS->TLS13, TLS->TLS_CHACHA20_POLY1305_SHA256, 1, "1.3 ChaCha20 server") ::
		ref Kind(TLS->TLS12, GCM12, 0, "1.2 AES-128-GCM client") ::
		ref Kind(TLS->TLS12, TLS->TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, 0, "1.2 AES-256-GCM client") :: nil;
}

HELLO: con "hello, world";
alertrec(pr: ref Peer, level, desc: int): array of byte
{
	return seal(pr, CT_ALERT, array[] of {byte level, byte desc});
}
closenotify(pr: ref Peer): array of byte
{
	return alertrec(pr, 1, 0);
}

# the peer sends recs and goes; what the module's end reads
play(k: ref Kind, mk: ref fn(pr: ref Peer): array of byte): (array of byte, int, string)
{
	(c, pr) := pair(k.version, k.suite, k.isserver);
	done := send(pr, mk(pr));
	r := drain(c);
	<-done;
	return r;
}

# data comes through, and a close_notify is the end, at every read after
mkgood(pr: ref Peer): array of byte
{
	return cat(cat(seal(pr, CT_DATA, array of byte HELLO), seal(pr, CT_DATA, array of byte " again")), closenotify(pr));
}

testData(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(c, pr) := pair(k.version, k.suite, k.isserver);
		done := send(pr, mkgood(pr));
		(data, r, e) := drain(c);
		<-done;
		t.assert(string data == HELLO + " again" && r == 0, sys->sprint("%s: two records and a close_notify: %q, then %d %s", k.name, string data, r, e));
		(r, nil, e) = rd(c, 16);
		t.asserteq(r, 0, k.name + ": the read after a close_notify is the end too (it read on): " + e);
		(r, nil, e) = rd(c, 16);
		t.asserteq(r, 0, k.name + ": and the one after");
	}
}

# a record with no data is not the end of the file
mkempty(pr: ref Peer): array of byte
{
	b := seal(pr, CT_DATA, nil);
	b = cat(b, seal(pr, CT_DATA, nil));
	b = cat(b, seal(pr, CT_DATA, array of byte HELLO));
	return cat(b, closenotify(pr));
}

mkemptyflood(pr: ref Peer): array of byte
{
	b := seal(pr, CT_DATA, array of byte HELLO);
	for(i := 0; i < 200; i++)
		b = cat(b, seal(pr, CT_DATA, nil));
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}

testEmptyRecords(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(c, pr) := pair(k.version, k.suite, k.isserver);
		done := send(pr, mkempty(pr));
		(r, b, e) := rd(c, 64);
		t.assert(r == len HELLO && string b == HELLO, sys->sprint("%s: the read after two empty records is the data (it was 0, the end of the file): %d %s", k.name, r, e));
		(r, nil, e) = rd(c, 64);
		t.asserteq(r, 0, k.name + ": then the close_notify");
		<-done;
		(data, n, err) := play(k, mkemptyflood);
		t.assert(string data == HELLO && n == -1 && contains(err, "no data"), sys->sprint("%s: two hundred empty records in a row end the connection with an error: %q %d %s", k.name, string data, n, err));
	}
}

# alerts
mkfatal(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_DATA, array of byte HELLO), alertrec(pr, 2, 40));
}
mkalert1(pr: ref Peer): array of byte
{
	return seal(pr, CT_ALERT, array[] of {byte 1});
}
mkalert3(pr: ref Peer): array of byte
{
	return seal(pr, CT_ALERT, array[] of {byte 1, byte 0, byte 0});
}
mkalert0(pr: ref Peer): array of byte
{
	return seal(pr, CT_ALERT, nil);
}
mkwarning(pr: ref Peer): array of byte
{
	# a warning that is not close_notify: no_renegotiation
	return cat(cat(alertrec(pr, 1, 100), seal(pr, CT_DATA, array of byte HELLO)), closenotify(pr));
}
mkwarnflood(pr: ref Peer): array of byte
{
	b := array[0] of byte;
	for(i := 0; i < 200; i++)
		b = cat(b, alertrec(pr, 1, 100));
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}
mkcanceled(pr: ref Peer): array of byte
{
	return cat(alertrec(pr, 1, 90), closenotify(pr));
}

testAlerts(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(c, pr) := pair(k.version, k.suite, k.isserver);
		done := send(pr, mkfatal(pr));
		(data, r, e) := drain(c);
		<-done;
		t.assert(string data == HELLO && r == -1 && contains(e, "alert 40"), sys->sprint("%s: a fatal alert is an error that names it: %d %s", k.name, r, e));
		(r, nil, e) = rd(c, 16);
		t.assert(r == -1 && contains(e, "alert 40"), sys->sprint("%s: and every read after is the same error: %d %s", k.name, r, e));

		(nil, r, e) = play(k, mkalert1);
		t.assert(r == -1 && contains(e, "malformed alert"), sys->sprint("%s: an alert of one byte: %d %s", k.name, r, e));
		(nil, r, e) = play(k, mkalert3);
		t.assert(r == -1 && contains(e, "malformed alert"), sys->sprint("%s: an alert of three bytes (it was a close_notify): %d %s", k.name, r, e));
		(nil, r, e) = play(k, mkalert0);
		t.assert(r == -1, sys->sprint("%s: an alert of no bytes: %d %s", k.name, r, e));

		(data, r, e) = play(k, mkwarning);
		if(k.version == TLS->TLS13)
			t.assert(len data == 0 && r == -1 && contains(e, "alert 100"), sys->sprint("%s: TLS 1.3 has no warnings: any alert but close_notify ends the connection: %d %s", k.name, r, e));
		else
			t.assert(string data == HELLO && r == 0, sys->sprint("%s: a TLS 1.2 warning is passed over: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkwarnflood);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: two hundred warnings end the connection: %d %s", k.name, r, e));
		(nil, r, e) = play(k, mkcanceled);
		t.assert(r == 0, sys->sprint("%s: user_canceled and then close_notify is a close: %d %s", k.name, r, e));
	}
}

# record sizes
big16384(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_DATA, array[16384] of {* => byte 'x'}), closenotify(pr));
}
big16385(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_DATA, array[16385] of {* => byte 'x'}), closenotify(pr));
}
bigpadded(pr: ref Peer): array of byte
{
	# 16384 of content, its type, and a byte of padding: 2^14 + 2
	inner := array[16386] of {* => byte 'x'};
	inner[16384] = byte CT_DATA;
	inner[16385] = byte 0;
	return cat(seal13(pr, inner), closenotify(pr));
}
bigcipher(pr: ref Peer): array of byte
{
	# 2^14 + 257 as it arrives
	if(pr.version == TLS->TLS13)
		return seal13(pr, array[16384 + 257 - 16] of {* => byte 0});
	return seal12(pr, CT_DATA, array[16384 + 2049 - 24] of {* => byte 'x'});
}
padded(pr: ref Peer): array of byte
{
	inner := array[len HELLO + 1 + 300] of {* => byte 0};
	inner[0:] = array of byte HELLO;
	inner[len HELLO] = byte CT_DATA;
	return cat(seal13(pr, inner), closenotify(pr));
}
allzero(pr: ref Peer): array of byte
{
	return seal13(pr, array[32] of {* => byte 0});
}
noinner(pr: ref Peer): array of byte
{
	return seal13(pr, nil);
}

testSizes(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(data, r, e) := play(k, big16384);
		t.assert(len data == 16384 && r == 0, sys->sprint("%s: a record of 2^14 bytes is taken: %d %d %s", k.name, len data, r, e));
		(data, r, e) = play(k, big16385);
		t.assert(len data == 0 && r == -1 && contains(e, "record_overflow"), sys->sprint("%s: one of 2^14 + 1 is record_overflow (it was taken): %d %d %s", k.name, len data, r, e));
		(data, r, e) = play(k, bigcipher);
		t.assert(len data == 0 && r == -1 && contains(e, "record_overflow"), sys->sprint("%s: one too long as it arrives: %d %d %s", k.name, len data, r, e));
		if(k.version != TLS->TLS13)
			continue;
		(data, r, e) = play(k, bigpadded);
		t.assert(len data == 0 && r == -1 && contains(e, "record_overflow"), sys->sprint("%s: 2^14 bytes and padding past 2^14 + 1: %d %d %s", k.name, len data, r, e));
		(data, r, e) = play(k, padded);
		t.assert(string data == HELLO && r == 0, sys->sprint("%s: padding is taken off: %q %d %s", k.name, string data, r, e));
		(nil, r, e) = play(k, allzero);
		t.assert(r == -1 && contains(e, "unexpected_message"), sys->sprint("%s: a record that is all padding: %d %s", k.name, r, e));
		(nil, r, e) = play(k, noinner);
		t.assert(r == -1, sys->sprint("%s: a record of nothing, not even a type: %d %s", k.name, r, e));
	}
}

# what is not this connection's record
plainalert(nil: ref Peer): array of byte
{
	return cat(header(CT_ALERT, 2), array[] of {byte 1, byte 0});
}
plaindata(nil: ref Peer): array of byte
{
	return cat(header(CT_DATA, 5), array of byte "hello");
}
ccs(nil: ref Peer): array of byte
{
	return cat(header(CT_CCS, 1), array[] of {byte 1});
}
heartbeat(pr: ref Peer): array of byte
{
	return seal(pr, 24, array[] of {byte 1, byte 0, byte 0});
}
badmac(pr: ref Peer): array of byte
{
	b := seal(pr, CT_DATA, array of byte HELLO);
	b[len b - 1] ^= byte 1;
	return b;
}
replay(pr: ref Peer): array of byte
{
	b := seal(pr, CT_DATA, array of byte HELLO);
	return cat(b, b);
}
swapped(pr: ref Peer): array of byte
{
	a := seal(pr, CT_DATA, array of byte "one");
	b := seal(pr, CT_DATA, array of byte "two");
	return cat(b, a);
}
cutshort(pr: ref Peer): array of byte
{
	b := cat(seal(pr, CT_DATA, array of byte HELLO), seal(pr, CT_DATA, array of byte "cut"));
	return b[0:len b - 3];
}
noclose(pr: ref Peer): array of byte
{
	return seal(pr, CT_DATA, array of byte HELLO);
}
halfheader(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_DATA, array of byte HELLO), array[] of {byte CT_DATA, byte 3});
}

testNotRecords(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(data, r, e) := play(k, plainalert);
		t.assert(r == -1, sys->sprint("%s: a close_notify in clear is not one (anyone on the path can write it): %d %s", k.name, r, e));
		(data, r, e) = play(k, plaindata);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: data in clear: %d %s", k.name, r, e));
		(nil, r, e) = play(k, ccs);
		t.assert(r == -1 && contains(e, "ChangeCipherSpec"), sys->sprint("%s: a ChangeCipherSpec after the handshake: %d %s", k.name, r, e));
		(nil, r, e) = play(k, heartbeat);
		t.assert(r == -1, sys->sprint("%s: a record of a type there is none of: %d %s", k.name, r, e));
		(data, r, e) = play(k, badmac);
		t.assert(len data == 0 && r == -1 && contains(e, "bad_record_mac"), sys->sprint("%s: a record with a bit changed: %d %s", k.name, r, e));
		(data, r, e) = play(k, replay);
		t.assert(string data == HELLO && r == -1, sys->sprint("%s: a record sent twice is taken once: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, swapped);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: two records in the other order: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, cutshort);
		t.assert(string data == HELLO && r == -1 && contains(e, "cut short"), sys->sprint("%s: a record cut short: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, noclose);
		t.assert(string data == HELLO && r == -1 && contains(e, "no close_notify"), sys->sprint("%s: a connection that ends with no close_notify is an error, not the end of the file: %d %s", k.name, r, e));
		(data, r, e) = play(k, halfheader);
		t.assert(string data == HELLO && r == -1, sys->sprint("%s: a connection that ends inside a record's header: %d %s", k.name, r, e));
	}
}

# ---- handshake messages after the handshake

ticket(n: int): array of byte
{
	return hsmsg(HT_NST, array[n] of {* => byte 0});
}

mkticket(pr: ref Peer): array of byte
{
	return cat(cat(seal(pr, CT_HS, cat(ticket(180), ticket(40))), seal(pr, CT_DATA, array of byte HELLO)), closenotify(pr));
}
mksplitticket(pr: ref Peer): array of byte
{
	# a ticket in three records, the first ending inside its header
	m := cat(ticket(300), ticket(20));
	b := seal(pr, CT_HS, m[0:2]);
	b = cat(b, seal(pr, CT_HS, m[2:150]));
	b = cat(b, seal(pr, CT_HS, m[150:]));
	return cat(cat(b, seal(pr, CT_DATA, array of byte HELLO)), closenotify(pr));
}
mkinterleaved(pr: ref Peer): array of byte
{
	m := ticket(300);
	b := seal(pr, CT_HS, m[0:100]);
	b = cat(b, seal(pr, CT_DATA, array of byte HELLO));
	return cat(b, seal(pr, CT_HS, m[100:]));
}
mkhugeticket(pr: ref Peer): array of byte
{
	# a message that says it is 16MB: refused at its header, not waited for
	h := array[] of {byte HT_NST, byte 16rff, byte 16rff, byte 16rff, byte 0};
	return cat(seal(pr, CT_HS, h), seal(pr, CT_DATA, array of byte "never"));
}
mkemptyhs(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, nil), seal(pr, CT_DATA, array of byte "never"));
}
mkhsflood(pr: ref Peer): array of byte
{
	b := array[0] of byte;
	for(i := 0; i < 200; i++)
		b = cat(b, seal(pr, CT_HS, ticket(8)));
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}
mkhello(pr: ref Peer): array of byte
{
	# a renegotiation: a ClientHello to a server, a ServerHello to a client
	return cat(seal(pr, CT_HS, hsmsg(1, array[40] of byte)), seal(pr, CT_DATA, array of byte "never"));
}
mkshello(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, hsmsg(2, array[40] of byte)), seal(pr, CT_DATA, array of byte "never"));
}
mkcertreq(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, hsmsg(13, array[10] of byte)), seal(pr, CT_DATA, array of byte "never"));
}
mkfinished(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, hsmsg(20, array[32] of byte)), seal(pr, CT_DATA, array of byte "never"));
}
mkhelloreq(pr: ref Peer): array of byte
{
	return cat(cat(seal(pr, CT_HS, hsmsg(0, nil)), seal(pr, CT_DATA, array of byte HELLO)), closenotify(pr));
}
mkhelloreqflood(pr: ref Peer): array of byte
{
	b := array[0] of byte;
	for(i := 0; i < 200; i++)
		b = cat(b, seal(pr, CT_HS, hsmsg(0, nil)));
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}

testPostHandshake(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		(data, r, e) := play(k, mkhello);
		t.assert(len data == 0 && r == -1 && contains(e, "unexpected_message"), sys->sprint("%s: a ClientHello after the handshake (renegotiation) is refused: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkshello);
		t.assert(len data == 0 && r == -1 && contains(e, "unexpected_message"), sys->sprint("%s: a ServerHello after the handshake is refused (under TLS 1.2 it was passed over): %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkcertreq);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: a CertificateRequest after the handshake, which was not offered: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkfinished);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: a Finished after the handshake: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkemptyhs);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: a handshake record of no bytes: %d %s", k.name, r, e));
		if(k.version == TLS->TLS12) {
			(data, r, e) = play(k, mkhelloreq);
			t.assert(string data == HELLO && r == 0, sys->sprint("%s: a HelloRequest is not answered, and the connection goes on: %q %d %s", k.name, string data, r, e));
			(data, r, e) = play(k, mkhelloreqflood);
			t.assert(len data == 0 && r == -1, sys->sprint("%s: two hundred HelloRequests end it: %d %s", k.name, r, e));
			(data, r, e) = play(k, mkticket);
			t.assert(len data == 0 && r == -1, sys->sprint("%s: a NewSessionTicket under TLS 1.2, which was not asked for: %d %s", k.name, r, e));
			continue;
		}
		(data, r, e) = play(k, mkhelloreq);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: a HelloRequest under TLS 1.3: %d %s", k.name, r, e));
		if(k.isserver) {
			(data, r, e) = play(k, mkticket);
			t.assert(len data == 0 && r == -1 && contains(e, "unexpected_message"), sys->sprint("%s: a NewSessionTicket from a client: %d %s", k.name, r, e));
			continue;
		}
		(data, r, e) = play(k, mkticket);
		t.assert(string data == HELLO && r == 0, sys->sprint("%s: two NewSessionTickets in a record are passed over: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mksplitticket);
		t.assert(string data == HELLO && r == 0, sys->sprint("%s: a NewSessionTicket in three records is passed over (it ended the connection): %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkinterleaved);
		t.assert(len data == 0 && r == -1 && contains(e, "unexpected_message"), sys->sprint("%s: data inside a handshake message: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkhugeticket);
		t.assert(len data == 0 && r == -1 && contains(e, "decode_error"), sys->sprint("%s: a message that says it is 16MB: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkhsflood);
		t.assert(len data == 0 && r == -1 && contains(e, "no data"), sys->sprint("%s: two hundred tickets and no data: %d %s", k.name, r, e));
	}
}

# ---- KeyUpdate (RFC 8446 4.6.3, 7.2)

ku(req: int): array of byte
{
	return hsmsg(HT_KU, array[] of {byte req});
}

mkku(pr: ref Peer): array of byte
{
	b := seal(pr, CT_DATA, array of byte "old key ");
	b = cat(b, seal(pr, CT_HS, ku(0)));
	update(pr);
	b = cat(b, seal(pr, CT_DATA, array of byte "new key"));
	return cat(b, closenotify(pr));
}
mkkusplit(pr: ref Peer): array of byte
{
	m := ku(0);
	b := seal(pr, CT_HS, m[0:3]);
	b = cat(b, seal(pr, CT_HS, m[3:]));
	update(pr);
	return cat(cat(b, seal(pr, CT_DATA, array of byte HELLO)), closenotify(pr));
}
mkkunotlast(pr: ref Peer): array of byte
{
	# a KeyUpdate and then a ticket in its record: what follows a
	# KeyUpdate is under the new key
	return cat(seal(pr, CT_HS, cat(ku(0), ticket(8))), seal(pr, CT_DATA, array of byte "never"));
}
mkkutwo(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, cat(ku(0), ku(0))), seal(pr, CT_DATA, array of byte "never"));
}
mkkubad(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, ku(2)), seal(pr, CT_DATA, array of byte "never"));
}
mkkulong(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, hsmsg(HT_KU, array[2] of byte)), seal(pr, CT_DATA, array of byte "never"));
}
mkkuempty(pr: ref Peer): array of byte
{
	return cat(seal(pr, CT_HS, hsmsg(HT_KU, nil)), seal(pr, CT_DATA, array of byte "never"));
}
mkkuoldkey(pr: ref Peer): array of byte
{
	# a KeyUpdate, and then a record under the key it gave up
	b := seal(pr, CT_HS, ku(0));
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}
mkkuflood(pr: ref Peer): array of byte
{
	b := array[0] of byte;
	for(i := 0; i < 200; i++) {
		b = cat(b, seal(pr, CT_HS, ku(1)));
		update(pr);
	}
	return cat(b, seal(pr, CT_DATA, array of byte "never"));
}
mkkumany(pr: ref Peer): array of byte
{
	# forty KeyUpdates, each with data after it: all taken
	b := array[0] of byte;
	for(i := 0; i < 40; i++) {
		b = cat(b, seal(pr, CT_HS, ku(0)));
		update(pr);
		b = cat(b, seal(pr, CT_DATA, array of byte "x"));
	}
	return cat(b, closenotify(pr));
}

testKeyUpdate(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		if(k.version != TLS->TLS13) {
			(data, r, e) := play(k, mkkuoldkey);
			t.assert(len data == 0 && r == -1, sys->sprint("%s: a KeyUpdate under TLS 1.2: %d %s", k.name, r, e));
			continue;
		}
		(data, r, e) := play(k, mkku);
		t.assert(string data == "old key new key" && r == 0, sys->sprint("%s: the peer's KeyUpdate moves its key on: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkkusplit);
		t.assert(string data == HELLO && r == 0, sys->sprint("%s: a KeyUpdate in two records: %q %d %s", k.name, string data, r, e));
		(data, r, e) = play(k, mkkumany);
		t.assert(len data == 40 && r == 0, sys->sprint("%s: forty KeyUpdates with data between: %d %d %s", k.name, len data, r, e));
		(data, r, e) = play(k, mkkuoldkey);
		t.assert(len data == 0 && r == -1 && contains(e, "bad_record_mac"), sys->sprint("%s: a record under the key a KeyUpdate gave up: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkunotlast);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: a message after a KeyUpdate in its record: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkutwo);
		t.assert(len data == 0 && r == -1, sys->sprint("%s: two KeyUpdates in one record: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkubad);
		t.assert(len data == 0 && r == -1 && contains(e, "illegal_parameter"), sys->sprint("%s: a KeyUpdate that asks for 2: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkulong);
		t.assert(len data == 0 && r == -1 && contains(e, "decode_error"), sys->sprint("%s: a KeyUpdate of two bytes: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkuempty);
		t.assert(len data == 0 && r == -1 && contains(e, "decode_error"), sys->sprint("%s: a KeyUpdate of none: %d %s", k.name, r, e));
		(data, r, e) = play(k, mkkuflood);
		t.assert(len data == 0 && r == -1 && contains(e, "no data"), sys->sprint("%s: two hundred KeyUpdates and no data: %d %s", k.name, r, e));
	}
}

# What the module's end writes: its own KeyUpdate when the peer asks
# for one, before the next data and not from its reader; and before its
# key has sealed too many records
wr(c: ref Conn, s: string): (int, string)
{
	b := array of byte s;
	r := -2;
	{
		r = c.write(b, len b);
		if(r < 0)
			return (r, sys->sprint("%r"));
	} exception e {
	"*" =>
		return (-2, "EXCEPTION " + e);
	}
	return (r, nil);
}

testOurKeyUpdate(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		if(k.version != TLS->TLS13)
			continue;
		# the peer asks: the answer is the writer's, before its next record
		(c, pr) := pair(k.version, k.suite, k.isserver);
		fd := pr.fd;
		req := seal(pr, CT_HS, ku(1));
		update(pr);
		req = cat(req, seal(pr, CT_DATA, array of byte HELLO));
		if(sys->write(fd, req, len req) != len req)
			t.fatal("pipe write");
		(r, b, e) := rd(c, 64);
		t.assert(r == len HELLO && string b == HELLO, sys->sprint("%s: data after a KeyUpdate that asks for ours: %d %s", k.name, r, e));
		t.assert(c.st.kureply == 1 && c.st.writeseq == big 0, k.name + ": the reader wrote nothing; the writer has been told");
		(n, we) := wr(c, "after");
		t.assert(n == 5, sys->sprint("%s: the write: %d %s", k.name, n, we));
		(ct, body) := open(pr);
		t.assert(ct == CT_HS && same(body, ku(0)), sys->sprint("%s: the writer's first record is its KeyUpdate, asking for none back: type %d, %d bytes", k.name, ct, len body));
		updater(pr);
		(ct, body) = open(pr);
		t.assert(ct == CT_DATA && string body == "after", sys->sprint("%s: and its data is under the new key: type %d %q", k.name, ct, string body));
		(n, we) = wr(c, "more");
		(ct, body) = open(pr);
		t.assert(ct == CT_DATA && string body == "more", k.name + ": one KeyUpdate, not one a write");

		# its own key is changed before it has sealed too many records
		c.st.writeseq = big (1<<23) - big 1;
		(n, we) = wr(c, "a");
		(ct, body) = open0(pr, big (1<<23) - big 1);
		t.assert(ct == CT_DATA && string body == "a", sys->sprint("%s: record 2^23 - 1 of a key: type %d", k.name, ct));
		(n, we) = wr(c, "b");
		t.assert(n == 1, sys->sprint("%s: the write at 2^23: %d %s", k.name, n, we));
		(ct, body) = open(pr);
		t.assert(ct == CT_HS && same(body, ku(0)), sys->sprint("%s: at 2^23 records the writer sends a KeyUpdate first (it never did): type %d", k.name, ct));
		updater(pr);
		(ct, body) = open(pr);
		t.assert(ct == CT_DATA && string body == "b" && c.st.writeseq == big 1, k.name + ": and goes on under a new key, from sequence number 0");

		# the peer's key is asked to change, and refused past the limit
		if(k.suite != TLS->TLS_CHACHA20_POLY1305_SHA256) {
			c.st.readseq = big (1<<23) + big 1;
			pr.sseq = big (1<<23) + big 1;
			one := seal(pr, CT_DATA, array of byte "x");
			sys->write(fd, one, len one);
			(r, b, e) = rd(c, 8);
			t.assert(r == 1 && c.st.kuask == 1, sys->sprint("%s: a peer's AES-GCM key past 2^23 records: its record is taken and the writer told to ask: %d %s", k.name, r, e));
			(n, we) = wr(c, "c");
			(ct, body) = open(pr);
			t.assert(ct == CT_HS && same(body, ku(1)), sys->sprint("%s: the writer's KeyUpdate asks for the peer's: type %d", k.name, ct));
			updater(pr);
			(ct, body) = open(pr);
			t.assert(ct == CT_DATA && string body == "c", k.name + ": then its data");
			c.st.readseq = big 23000000;
			pr.sseq = big 23000000;
			one = seal(pr, CT_DATA, array of byte "y");
			sys->write(fd, one, len one);
			(r, b, e) = rd(c, 8);
			t.assert(r == -1 && contains(e, "too many records"), sys->sprint("%s: and a peer that sends on to the limit with no KeyUpdate is refused: %d %s", k.name, r, e));
		}
	}
}

# open a record sealed at a sequence number the test set
open0(pr: ref Peer, seq: big): (int, array of byte)
{
	pr.rseq = seq;
	return open(pr);
}

# ---- sequence numbers, counts, and a peer that has gone

testEdges(t: ref T)
{
	for(l := kinds(); l != nil; l = tl l) {
		k := hd l;
		# a count past the buffer
		(c, pr) := pair(k.version, k.suite, k.isserver);
		done := send(pr, cat(seal(pr, CT_DATA, array of byte "0123456789abcdefghij"), closenotify(pr)));
		buf := array[8] of byte;
		r := -2;
		e := "";
		{
			r = c.read(buf, 100);
		} exception x {
		"*" =>
			e = x;
		}
		t.assert(r == 8 && string buf == "01234567", sys->sprint("%s: a read of 100 into a buffer of 8 gives 8 (it was an exception): %d %s", k.name, r, e));
		(r, nil, e) = rd(c, 0);
		t.asserteq(r, 0, k.name + ": a read of nothing");
		(data, n, err) := drain(c);
		t.assert(string data == "89abcdefghij" && n == 0, sys->sprint("%s: and the rest of the record is kept: %q %d %s", k.name, string data, n, err));
		<-done;

		# the last sequence number
		(c, pr) = pair(k.version, k.suite, k.isserver);
		c.st.writeseq = big 16r3fffffffffffffff;
		(w, we) := wr(c, "x");
		t.assert(w == -1 && contains(we, "sequence"), sys->sprint("%s: a write with no sequence number left is refused (it wrapped): %d %s", k.name, w, we));
		(w, we) = wr(c, "x");
		t.assert(w == -1 && contains(we, "sequence"), sys->sprint("%s: and every write after: %d %s", k.name, w, we));
		c.st.readseq = big 16r3fffffffffffffff;
		pr.sseq = big 16r3fffffffffffffff;
		done = send(pr, seal(pr, CT_DATA, array of byte "x"));
		(r, nil, e) = rd(c, 8);
		t.assert(r == -1 && contains(e, "sequence"), sys->sprint("%s: and a read: %d %s", k.name, r, e));
		<-done;

		# a peer that has gone
		(c, pr) = pair(k.version, k.suite, k.isserver);
		pr.fd = nil;
		(w, we) = wr(c, "to nobody");
		t.assert(w == -1 && !contains(we, "EXCEPTION"), sys->sprint("%s: a write to a peer that has gone is an error (it was an exception): %d %s", k.name, w, we));
		(w, we) = wr(c, "again");
		t.assert(w == -1, k.name + ": and so is the next");
		cerr := "";
		{
			c.close();
		} exception x {
		"*" =>
			cerr = x;
		}
		t.assertseq(cerr, "", k.name + ": close with the peer gone raises nothing");
		(r, nil, e) = rd(c, 8);
		t.assert(r == -1, k.name + ": a read after close");
		(w, we) = wr(c, "x");
		t.assert(w == -1, k.name + ": a write after close");

		# close sends close_notify
		(c, pr) = pair(k.version, k.suite, k.isserver);
		wr(c, "bye");
		c.close();
		(ct, body) := open(pr);
		t.assert(ct == CT_DATA && string body == "bye", k.name + ": data before close");
		(ct, body) = open(pr);
		t.assert(ct == CT_ALERT && len body == 2 && body[1] == byte 0, sys->sprint("%s: close sends close_notify: type %d", k.name, ct));
	}
}

# ---- streams of good records, changed

seed := 0;

rnd(n: int): int
{
	seed = seed * 1103515245 + 12345;
	return ((seed >> 16) & 16r7fff) % n;
}

interesting := array[] of {
	byte 0, byte 1, byte 2, byte 4, byte 20, byte 21, byte 22, byte 23, byte 24, byte 16r3f, byte 16r40, byte 16r41,
	byte 16r7f, byte 16r80, byte 16rff,
};

mutate(a: array of byte): array of byte
{
	n := len a;
	case rnd(8) {
	0 or 1 =>
		m := array[n] of byte;
		m[0:] = a;
		m[rnd(n)] ^= byte (1 << rnd(8));
		return m;
	2 or 3 =>
		m := array[n] of byte;
		m[0:] = a;
		m[rnd(n)] = interesting[rnd(len interesting)];
		return m;
	4 =>
		return a[0:rnd(n)];
	5 =>
		i := rnd(n);
		k := 1 + rnd(8);
		if(i + k > n)
			k = n - i;
		return cat(a[0:i], a[i+k:]);
	6 =>
		# a record header's length, made long
		i := rnd(n);
		m := array[n] of byte;
		m[0:] = a;
		m[i] = byte 16r40;
		return m;
	* =>
		i := rnd(n);
		j := rnd(n);
		k := 1 + rnd(40);
		if(j + k > n)
			k = n - j;
		return cat(cat(a[0:i], a[j:j+k]), a[i:]);
	}
}

# a stream with one of everything a peer may send, and what it says
stream(pr: ref Peer): (array of byte, string)
{
	b := seal(pr, CT_DATA, array of byte "alpha ");
	if(pr.version == TLS->TLS13) {
		b = cat(b, seal(pr, CT_HS, ku(1)));
		update(pr);
		b = cat(b, seal(pr, CT_DATA, array of byte "beta "));
		b = cat(b, seal(pr, CT_DATA, nil));
		b = cat(b, seal(pr, CT_HS, ku(0)));
		update(pr);
	} else {
		b = cat(b, seal(pr, CT_HS, hsmsg(0, nil)));
		b = cat(b, seal(pr, CT_DATA, array of byte "beta "));
		b = cat(b, seal(pr, CT_DATA, nil));
		b = cat(b, alertrec(pr, 1, 100));
	}
	b = cat(b, seal(pr, CT_DATA, array of byte "gamma "));
	b = cat(b, seal(pr, CT_DATA, array[300] of {* => byte 'd'}));
	b = cat(b, closenotify(pr));
	return (b, "alpha beta gamma " + string array[300] of {* => byte 'd'});
}

testMutations(t: ref T)
{
	ks := kinds();
	nk := len ks;
	ka := array[nk] of ref Kind;
	for(i := 0; ks != nil; ks = tl ks)
		ka[i++] = hd ks;
	bad := 0;
	clean := 0;
	errors := 0;
	for(i = 0; i < MUTANTS && bad < 5; i++) {
		seed = i * 7919 + 1;
		k := ka[i % nk];
		(c, pr) := pair(k.version, k.suite, k.isserver);
		(good, text) := stream(pr);
		m := mutate(good);
		if(same(m, good))
			continue;
		done := send(pr, m);
		(data, r, e) := drain(c);
		<-done;
		got := string data;
		why := "";
		if(r == -2 || r == -3)
			why = e;
		else if(r == 0 && got != text)
			why = sys->sprint("a clean close after %d bytes that are not the stream's", len data);
		else if(len got > len text || got != text[0:len got])
			why = "bytes the peer did not send";
		else if(r == -1 && (e == nil || e == ""))
			why = "an error with no reason";
		if(why != "") {
			bad++;
			t.error(sys->sprint("mutant %d (%s, %d bytes): %s", i, k.name, len m, why));
		}
		# a write after whatever happened raises nothing either
		(w, we) := wr(c, "reply");
		if(w == -2) {
			bad++;
			t.error(sys->sprint("mutant %d (%s): write: %s", i, k.name, we));
		}
		{
			c.close();
		} exception x {
		"*" =>
			bad++;
			t.error(sys->sprint("mutant %d (%s): close raised %s", i, k.name, x));
		}
		if(r == 0)
			clean++;
		else
			errors++;
	}
	t.asserteq(bad, 0, "no changed stream raised, gave bytes that were not sent, or ended cleanly short");
	t.assert(errors > MUTANTS / 2, sys->sprint("most ended in an error: %d of %d", errors, MUTANTS));
	t.log(sys->sprint("%d streams: %d ended in an error, %d cleanly with every byte (changed where the reader does not look: a record's version)", MUTANTS, errors, clean));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	kr = load Keyring Keyring->PATH;
	tls = load TLS TLS->PATH;
	if(kr == nil || tls == nil) {
		sys->fprint(sys->fildes(2), "cannot load keyring or tls: %r\n");
		raise "fail:cannot load";
	}
	if((e := tls->init()) != nil) {
		sys->fprint(sys->fildes(2), "tls init: %s\n", e);
		raise "fail:init";
	}

	run("Data", testData);
	run("EmptyRecords", testEmptyRecords);
	run("Alerts", testAlerts);
	run("Sizes", testSizes);
	run("NotRecords", testNotRecords);
	run("PostHandshake", testPostHandshake);
	run("KeyUpdate", testKeyUpdate);
	run("OurKeyUpdate", testOurKeyUpdate);
	run("Edges", testEdges);
	run("Mutations", testMutations);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
