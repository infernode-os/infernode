implement SslRecordTest;

#
# devssl's records (ssl(3)), as the wire has them. One end of a pipe is
# pushed with ssl and the other read and written raw, so each record is
# checked byte for byte against Keyring, not against devssl itself:
#
#	hmac_sha384	header, HMAC-SHA-384(secret, data || be32(n)), data
#	aes_256_gcm	header, AES-256-GCM(data) with the header as its
#			associated data, then the tag; key and nonce by
#			HKDF-SHA-384 from the secret, record n's nonce with n
#			exclusive-ored into its last eight bytes
#
# Then records both ways between two pushed ends at sizes past a record;
# a changed byte, a record sent again, two records swapped and a record
# sent back to its sender each refused.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	ssl: SSL;

include "testing.m";
	testing: Testing;
	T: import testing;

SslRecordTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ssl_record_test.b";

passed := 0;
failed := 0;
skipped := 0;

Taglen: con 16;
Maxdata: con 32767;	# a record's length, header to end, at most

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

# what the pushed end sends under; it receives under its reverse
secret := array[] of {
	byte 16r0b, byte 16r1c, byte 16r2d, byte 16r3e, byte 16r4f, byte 16r50, byte 16r61, byte 16r72,
	byte 16r83, byte 16r94, byte 16ra5, byte 16rb6, byte 16rc7, byte 16rd8, byte 16re9, byte 16rfa,
	byte 16r01, byte 16r12, byte 16r23, byte 16r34, byte 16r45, byte 16r56, byte 16r67, byte 16r78,
	byte 16r89, byte 16r9a, byte 16rab, byte 16rbc, byte 16rcd, byte 16rde, byte 16ref, byte 16rf0,
	byte 16r10, byte 16r20, byte 16r30, byte 16r40, byte 16r50, byte 16r60, byte 16r70, byte 16r80,
	byte 16r90, byte 16ra0, byte 16rb0, byte 16rc0, byte 16rd0, byte 16re0, byte 16rf0, byte 16r00,
};
other: array of byte;

# one end of a pipe pushed with ssl and alg set, the other end raw
pushed(t: ref T, alg: string): (ref Sys->Connection, ref Sys->FD)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	(err, c) := ssl->connect(p[0]);
	if(c == nil)
		t.fatal("ssl connect: " + err);
	err = ssl->secret(c, other, secret);
	if(err != nil)
		t.fatal("ssl secret: " + err);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		t.fatal(sys->sprint("alg %s: %r", alg));
	return (c, p[1]);
}

hdr(n: int): array of byte
{
	return array[] of {byte (16r80 | (n>>8)), byte n};
}

# HMAC-SHA-384(s, data || be32(n)), by Keyring
wantmac(s, data: array of byte, n: int): array of byte
{
	m := array[len data + 4] of byte;
	m[0:] = data;
	m[len data] = byte (n>>24);
	m[len data+1] = byte (n>>16);
	m[len data+2] = byte (n>>8);
	m[len data+3] = byte n;
	d := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(m, len m, s, d, nil);
	return d;
}

# aes_256_gcm's key and record 0's nonce from s: HKDF-SHA-384
gcmkey(s: array of byte): (array of byte, array of byte)
{
	prk := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(s, len s, array[Keyring->SHA384dlen] of {* => byte 0}, prk, nil);
	info := array of byte "infernode ssl aes_256_gcm";
	m := array[len info + 1] of byte;
	m[0:] = info;
	m[len info] = byte 1;
	okm := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(m, len m, prk, okm, nil);
	return (okm[0:32], okm[32:44]);
}

# record n's body (ciphertext then tag) for data under s, by Keyring
wantsealed(s, data: array of byte, n: int): array of byte
{
	(key, iv) := gcmkey(s);
	nonce := array[12] of byte;
	nonce[0:] = iv;
	for(i := 0; i < 8; i++)
		nonce[11-i] ^= byte (big n >> (8*i));
	st := kr->aesgcmsetup(key, nonce);
	(ct, tag) := kr->aesgcmencrypt(st, data, hdr(len data + Taglen));
	b := array[len ct + len tag] of byte;
	b[0:] = ct;
	b[len ct:] = tag;
	return b;
}

# a whole record from the raw end: (its body after the two-byte header, error)
readrecord(fd: ref Sys->FD): (array of byte, string)
{
	h := array[2] of byte;
	if(readn(fd, h, 2) != 2)
		return (nil, sys->sprint("no record header: %r"));
	if((int h[0] & 16r80) == 0)
		return (nil, "a padded (three-byte) header");
	n := ((int h[0] & 16r7f)<<8) | int h[1];
	b := array[n] of byte;
	if(readn(fd, b, n) != n)
		return (nil, sys->sprint("short record: %r"));
	return (b, nil);
}

writerecord(fd: ref Sys->FD, body: array of byte)
{
	sys->write(fd, hdr(len body), 2);
	sys->write(fd, body, len body);
}

readn(fd: ref Sys->FD, b: array of byte, n: int): int
{
	got := 0;
	while(got < n){
		r := sys->read(fd, b[got:], n - got);
		if(r <= 0)
			break;
		got += r;
	}
	return got;
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

msgs := array[] of {"hello", "a second record, a little longer", "x"};

testHMACWire(t: ref T)
{
	(c, raw) := pushed(t, "hmac_sha384");
	for(i := 0; i < len msgs; i++){
		data := array of byte msgs[i];
		if(sys->write(c.dfd, data, len data) != len data)
			t.fatal(sys->sprint("write: %r"));
		(rec, err) := readrecord(raw);
		if(err != nil)
			t.fatal(err);
		t.asserteq(len rec, Keyring->SHA384dlen + len data, sys->sprint("record %d is 48 bytes of MAC and its data", i));
		if(len rec != Keyring->SHA384dlen + len data)
			continue;
		t.assert(same(rec[Keyring->SHA384dlen:], data), sys->sprint("record %d's data follow the MAC", i));
		t.assert(same(rec[0:Keyring->SHA384dlen], wantmac(secret, data, i)),
			sys->sprint("record %d's MAC is HMAC-SHA-384(secret, data || %d)", i, i));
	}
}

testGCMWire(t: ref T)
{
	(c, raw) := pushed(t, "aes_256_gcm");
	for(i := 0; i < len msgs; i++){
		data := array of byte msgs[i];
		if(sys->write(c.dfd, data, len data) != len data)
			t.fatal(sys->sprint("write: %r"));
		(rec, err) := readrecord(raw);
		if(err != nil)
			t.fatal(err);
		t.asserteq(len rec, len data + Taglen, sys->sprint("record %d is its data's length and a 16-byte tag", i));
		t.assert(same(rec, wantsealed(secret, data, i)),
			sys->sprint("record %d is AES-256-GCM under the HKDF key, nonce %d, the header its associated data", i, i));
	}
	# and what Keyring seals under the other secret, the pushed end opens
	for(i = 0; i < len msgs; i++){
		data := array of byte msgs[i];
		writerecord(raw, wantsealed(other, data, i));
		buf := array[256] of byte;
		n := sys->read(c.dfd, buf, len buf);
		t.assert(n == len data && same(buf[0:n], data), sys->sprint("record %d sealed by Keyring is opened", i));
	}
}

testLongWrite(t: ref T)
{
	for(l := "aes_256_gcm" :: "hmac_sha384" :: nil; l != nil; l = tl l){
		alg := hd l;
		over := Keyring->SHA384dlen;
		if(alg == "aes_256_gcm")
			over = Taglen;
		(c, raw) := pushed(t, alg);
		size := 70000;
		data := array[size] of byte;
		for(i := 0; i < size; i++)
			data[i] = byte (i*13);
		spawn writer(c.dfd, data);
		got := 0;
		for(nrec := 0; got < size; nrec++){
			(rec, err) := readrecord(raw);
			if(err != nil)
				t.fatal(alg + ": " + err);
			t.assert(len rec <= Maxdata, sys->sprint("%s: record %d of %d bytes fits its header", alg, nrec, len rec));
			got += len rec - over;
		}
		t.asserteq(got, size, alg + ": a write past a record goes as several, all of it");
		t.assert(nrec >= 3, sys->sprint("%s: 70000 bytes in at least three records (%d)", alg, nrec));
	}
}

writer(fd: ref Sys->FD, data: array of byte)
{
	sys->write(fd, data, len data);
}

# ssl both ends, each way its own secret: what is written arrives
pair(t: ref T, alg: string): (ref Sys->Connection, ref Sys->Connection)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	(e1, a) := ssl->connect(p[0]);
	(e2, b) := ssl->connect(p[1]);
	if(a == nil || b == nil)
		t.fatal("ssl connect: " + e1 + e2);
	ssl->secret(a, other, secret);
	ssl->secret(b, secret, other);
	if(sys->fprint(a.cfd, "alg %s", alg) < 0 || sys->fprint(b.cfd, "alg %s", alg) < 0)
		t.fatal(sys->sprint("alg %s: %r", alg));
	return (a, b);
}

testRoundTrip(t: ref T)
{
	for(l := "aes_256_gcm" :: "hmac_sha384" :: nil; l != nil; l = tl l){
		alg := hd l;
		(a, b) := pair(t, alg);
		for(size := 1; size <= 70000; size = size*3 + 1){
			data := array[size] of byte;
			for(i := 0; i < size; i++)
				data[i] = byte (i*7 + size);
			spawn writer(a.dfd, data);
			got := array[size] of byte;
			n := readn(b.dfd, got, size);
			t.asserteq(n, size, sys->sprint("%s: %d bytes arrive", alg, size));
			t.assert(same(got[0:n], data[0:n]), sys->sprint("%s: %d bytes arrive unchanged", alg, size));
		}
	}
}

# what the pushed end does with a record written to its raw end: read's count
offer(c: ref Sys->Connection, raw: ref Sys->FD, body: array of byte): int
{
	writerecord(raw, body);
	buf := array[256] of byte;
	return sys->read(c.dfd, buf, len buf);
}

testRefused(t: ref T)
{
	data := array of byte "pay the bearer";
	for(l := "aes_256_gcm" :: "hmac_sha384" :: nil; l != nil; l = tl l){
		alg := hd l;
		seal := wantsealed;
		if(alg == "hmac_sha384")
			seal = macced;

		# a changed byte: the first of the body, then the last
		for(k := 0; k < 2; k++){
			(c, raw) := pushed(t, alg);
			rec := seal(other, data, 0);
			if(k == 0)
				rec[0] ^= byte 1;
			else
				rec[len rec-1] ^= byte 16r80;
			t.assert(offer(c, raw, rec) < 0, sys->sprint("%s: a record with its %s byte changed is refused", alg, (array[] of {"first", "last"})[k]));
		}

		# record 0 again where record 1 is due
		(c, raw) := pushed(t, alg);
		t.asserteq(offer(c, raw, seal(other, data, 0)), len data, alg + ": record 0 is taken");
		t.assert(offer(c, raw, seal(other, data, 0)) < 0, alg + ": record 0 sent again is refused");

		# record 1 first
		(c, raw) = pushed(t, alg);
		t.assert(offer(c, raw, seal(other, data, 1)) < 0, alg + ": record 1 before record 0 is refused");

		# the end's own record 0 sent back to it
		(c, raw) = pushed(t, alg);
		sys->write(c.dfd, data, len data);
		(mine, err) := readrecord(raw);
		if(err != nil)
			t.fatal(err);
		t.assert(offer(c, raw, mine) < 0, alg + ": a record sent back to its sender is refused");
	}
}

# records too short to hold what their algorithm needs, the header on its own
testShort(t: ref T)
{
	for(l := "aes_256_gcm" :: "hmac_sha384" :: nil; l != nil; l = tl l){
		alg := hd l;
		# no bytes at all: two bytes from anyone, before any MAC is looked at
		(c, raw) := pushed(t, alg);
		t.assert(offer(c, raw, array[0] of byte) < 0, alg + ": a record of no bytes is refused");
		# fewer than a MAC or a tag
		(c, raw) = pushed(t, alg);
		t.assert(offer(c, raw, array[10] of {* => byte 16r5a}) < 0, alg + ": a record shorter than its MAC is refused");
		# and a conversation beside it goes on
		(c, raw) = pushed(t, alg);
		seal := wantsealed;
		if(alg == "hmac_sha384")
			seal = macced;
		data := array of byte "still here";
		t.asserteq(offer(c, raw, seal(other, data, 0)), len data, alg + ": a whole record is still taken");
	}
}

# a conversation of its own, not yet pushed onto anything: its ctl and its number
bare(t: ref T): (ref Sys->FD, string)
{
	cfd := sys->open("#D/clone", Sys->ORDWR);
	if(cfd == nil)
		t.fatal(sys->sprint("open #D/clone: %r"));
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		t.fatal(sys->sprint("read #D/clone: %r"));
	return (cfd, string b[0:n]);
}

# what a conversation may be pushed onto: a channel open both ways that is
# not a directory and not ssl's own
testPushedOnto(t: ref T)
{
	# another conversation, with a record waiting to be read
	(victim, vraw) := pushed(t, "hmac_sha384");
	secretdata := array of byte "not yours to read";
	writerecord(vraw, macced(other, secretdata, 0));
	vdir := victim.dir;

	# its directory, which anyone may open
	(cfd, nil) := bare(t);
	dfd := sys->open(vdir, Sys->OREAD);
	if(dfd == nil)
		t.fatal(sys->sprint("open %s: %r", vdir));
	t.assert(sys->fprint(cfd, "fd %d", dfd.fd) < 0, "a conversation's directory is refused as a channel to push onto");

	# ssl's own top directory
	(cfd, nil) = bare(t);
	dfd = sys->open("#D", Sys->OREAD);
	if(dfd == nil)
		t.fatal(sys->sprint("open #D: %r"));
	t.assert(sys->fprint(cfd, "fd %d", dfd.fd) < 0, "#D is refused as a channel to push onto");

	# its own data file
	n: string;
	(cfd, n) = bare(t);
	dfd = sys->open("#D/" + n + "/data", Sys->ORDWR);
	if(dfd == nil)
		t.fatal(sys->sprint("open #D/%s/data: %r", n));
	t.assert(sys->fprint(cfd, "fd %d", dfd.fd) < 0, "a conversation's own data file is refused as its channel");

	# a channel open one way only
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	(cfd, nil) = bare(t);
	rfd := sys->open("/dev/null", Sys->OREAD);
	t.assert(rfd != nil && sys->fprint(cfd, "fd %d", rfd.fd) < 0, "a channel open only for reading is refused");

	# a second fd
	(cfd, nil) = bare(t);
	t.assert(sys->fprint(cfd, "fd %d", p[0].fd) >= 0, "a pipe is taken");
	t.assert(sys->fprint(cfd, "fd %d", p[1].fd) < 0, "a second fd is refused");

	# and the other conversation's record is still its owner's to read
	buf := array[256] of byte;
	m := sys->read(victim.dfd, buf, len buf);
	t.assert(m == len secretdata && same(buf[0:m], secretdata), sys->sprint("the other conversation's record is read by its owner (%d)", m));
}

# hmac_sha384's body for record n: MAC then data
macced(s, data: array of byte, n: int): array of byte
{
	m := wantmac(s, data, n);
	b := array[len m + len data] of byte;
	b[0:] = m;
	b[len m:] = data;
	return b;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(ssl == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", SSL->PATH);
		raise "fail:cannot load ssl";
	}
	other = array[len secret] of byte;
	for(i := 0; i < len secret; i++)
		other[i] = secret[len secret - 1 - i] ^ byte 16r5a;

	run("SSL/HMACSHA384Wire", testHMACWire);
	run("SSL/AESGCMWire", testGCMWire);
	run("SSL/LongWrite", testLongWrite);
	run("SSL/RoundTrip", testRoundTrip);
	run("SSL/Refused", testRefused);
	run("SSL/Short", testShort);
	run("SSL/PushedOnto", testPushedOnto);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
