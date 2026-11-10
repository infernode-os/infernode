implement SslHmacTest;

#
# devssl's hmac_sha384 (ssl(3)): HMAC-SHA-384 (FIPS 198-1) keyed by the
# secret, of a record and its number. One end of a pipe is pushed with
# ssl and the other read raw, so a record's MAC is checked byte for byte
# against Keyring's own hmac_sha384, not against devssl itself; then
# records both ways between two pushed ends, digest alone and with
# aes_256_cbc, a changed byte refused, and sha256 (SSL 2's MAC) as it was.
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

SslHmacTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ssl_hmac_test.b";

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

secret := array[] of {
	byte 16r0b, byte 16r1c, byte 16r2d, byte 16r3e, byte 16r4f, byte 16r50, byte 16r61, byte 16r72,
	byte 16r83, byte 16r94, byte 16ra5, byte 16rb6, byte 16rc7, byte 16rd8, byte 16re9, byte 16rfa,
	byte 16r01, byte 16r12, byte 16r23, byte 16r34, byte 16r45, byte 16r56, byte 16r67, byte 16r78,
	byte 16r89, byte 16r9a, byte 16rab, byte 16rbc, byte 16rcd, byte 16rde, byte 16ref, byte 16rf0,
	byte 16r10, byte 16r20, byte 16r30, byte 16r40, byte 16r50, byte 16r60, byte 16r70, byte 16r80,
	byte 16r90, byte 16ra0, byte 16rb0, byte 16rc0, byte 16rd0, byte 16re0, byte 16rf0, byte 16r00,
};

# one end of a pipe pushed with ssl and alg set, the other end raw
pushed(t: ref T, alg: string): (ref Sys->Connection, ref Sys->FD)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	(err, c) := ssl->connect(p[0]);
	if(c == nil)
		t.fatal("ssl connect: " + err);
	err = ssl->secret(c, secret, secret);
	if(err != nil)
		t.fatal("ssl secret: " + err);
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		t.fatal(sys->sprint("alg %s: %r", alg));
	return (c, p[1]);
}

# HMAC-SHA-384(secret, data || be32(n)), by Keyring
wantmac(data: array of byte, n: int): array of byte
{
	m := array[len data + 4] of byte;
	m[0:] = data;
	m[len data] = byte (n>>24);
	m[len data+1] = byte (n>>16);
	m[len data+2] = byte (n>>8);
	m[len data+3] = byte n;
	d := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(m, len m, secret, d, nil);
	return d;
}

# a whole record from the raw end: (its body after the two-byte header, error)
readrecord(fd: ref Sys->FD): (array of byte, string)
{
	h := array[2] of byte;
	if(readn(fd, h, 2) != 2)
		return (nil, sys->sprint("no record header: %r"));
	if((int h[0] & 16r80) == 0)
		return (nil, "a padded (three-byte) header where none was expected");
	n := ((int h[0] & 16r7f)<<8) | int h[1];
	b := array[n] of byte;
	if(readn(fd, b, n) != n)
		return (nil, sys->sprint("short record: %r"));
	return (b, nil);
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

testListed(t: ref T)
{
	(c, nil) := pushed(t, "clear");
	fd := sys->open(c.dir + "/hashalgs", Sys->OREAD);
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	t.assert(n > 0, "hashalgs reads");
	(nil, l) := sys->tokenize(string b[0:n], " \t\n");
	has := 0;
	for(; l != nil; l = tl l)
		if(hd l == "hmac_sha384")
			has = 1;
	t.assert(has, "hashalgs lists hmac_sha384: " + string b[0:n]);
}

# the wire: each record is its MAC then its data, the MAC HMAC-SHA-384
testWire(t: ref T)
{
	(c, raw) := pushed(t, "hmac_sha384");
	msgs := array[] of {"hello", "", "a second record, a little longer", "x"};
	for(i := 0; i < len msgs; i++){
		data := array of byte msgs[i];
		if(len data == 0)
			continue;	# a zero-length write sends nothing
		if(sys->write(c.dfd, data, len data) != len data)
			t.fatal(sys->sprint("write: %r"));
	}
	n := 0;
	for(i = 0; i < len msgs; i++){
		data := array of byte msgs[i];
		if(len data == 0)
			continue;
		(rec, err) := readrecord(raw);
		if(err != nil)
			t.fatal(err);
		t.asserteq(len rec, Keyring->SHA384dlen + len data, sys->sprint("record %d is 48 bytes of MAC and its data", n));
		if(len rec != Keyring->SHA384dlen + len data)
			continue;
		t.assert(same(rec[Keyring->SHA384dlen:], data), sys->sprint("record %d's data follow the MAC", n));
		t.assert(same(rec[0:Keyring->SHA384dlen], wantmac(data, n)),
			sys->sprint("record %d's MAC is HMAC-SHA-384(secret, data || %d)", n, n));
		n++;
	}
}

# ssl both ends: what is written arrives
pair(t: ref T, alg: string): (ref Sys->Connection, ref Sys->Connection)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	(e1, a) := ssl->connect(p[0]);
	(e2, b) := ssl->connect(p[1]);
	if(a == nil || b == nil)
		t.fatal("ssl connect: " + e1 + e2);
	ssl->secret(a, secret, secret);
	ssl->secret(b, secret, secret);
	if(sys->fprint(a.cfd, "alg %s", alg) < 0 || sys->fprint(b.cfd, "alg %s", alg) < 0)
		t.fatal(sys->sprint("alg %s: %r", alg));
	return (a, b);
}

roundtrip(t: ref T, alg: string)
{
	(a, b) := pair(t, alg);
	for(size := 1; size <= 20000; size = size*3 + 1){
		data := array[size] of byte;
		for(i := 0; i < size; i++)
			data[i] = byte (i*7 + size);
		if(sys->write(a.dfd, data, size) != size)
			t.fatal(sys->sprint("%s: write %d: %r", alg, size));
		got := array[size] of byte;
		n := readn(b.dfd, got, size);
		t.asserteq(n, size, sys->sprint("%s: %d bytes arrive", alg, size));
		t.assert(same(got[0:n], data[0:n]), sys->sprint("%s: %d bytes arrive unchanged", alg, size));
	}
}

testRoundTrip(t: ref T)
{
	roundtrip(t, "hmac_sha384");
	roundtrip(t, "hmac_sha384 aes_256_cbc");
	roundtrip(t, "sha256");
	roundtrip(t, "sha256 aes_256_cbc");
}

# a byte changed in transit, data or MAC, is refused
testTampered(t: ref T)
{
	for(k := 0; k < 2; k++){
		(c, raw) := pushed(t, "hmac_sha384");
		data := array of byte "pay the bearer";
		sys->write(c.dfd, data, len data);
		(rec, err) := readrecord(raw);
		if(err != nil)
			t.fatal(err);
		# change one byte: the data's first, then the MAC's last
		if(k == 0)
			rec[Keyring->SHA384dlen] ^= byte 1;
		else
			rec[Keyring->SHA384dlen-1] ^= byte 16r80;
		hdr := array[2] of byte;
		hdr[0] = byte (16r80 | (len rec >> 8));
		hdr[1] = byte len rec;
		sys->write(raw, hdr, 2);
		sys->write(raw, rec, len rec);
		buf := array[64] of byte;
		n := sys->read(c.dfd, buf, len buf);
		what := "data";
		if(k == 1)
			what = "MAC";
		t.assert(n < 0, sys->sprint("a record with its %s changed is refused (read gave %d)", what, n));
	}
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

	run("SSL/HashalgsListed", testListed);
	run("SSL/HMACSHA384Wire", testWire);
	run("SSL/RoundTrip", testRoundTrip);
	run("SSL/Tampered", testTampered);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
