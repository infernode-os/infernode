implement SSLTransportTest;

#
# SSL transport tests: the kernel SSL device (#D) and what it offers
#
# Tests:
# - encalgs is aes_256_gcm alone, hashalgs hmac_sha384 alone
# - AES-256-GCM data round-trip through a pipe
# - HMAC-SHA-384 (the data clear) round-trip through a pipe
# - the same secret both ways, a short secret, one way's secret alone,
#   two algorithms at once and the old algorithms refused
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";

include "security.m";
	ssl: SSL;

include "testing.m";
	testing: Testing;
	T: import testing;

SSLTransportTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ssl_transport_test.b";

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

# Read a string from a file descriptor
readstring(fd: ref Sys->FD): string
{
	if(fd == nil)
		return nil;
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

# Read algorithm lists from the SSL device by cloning a connection
readalgs(): (list of string, list of string)
{
	# Clone an SSL connection to read its algorithm files
	(rc, nil) := sys->stat("#D");
	if(rc < 0)
		return (nil, nil);
	dir := "#D";
	(rc, nil) = sys->stat("#D/ssl");
	if(rc >= 0)
		dir = "#D/ssl";
	cfd := sys->open(dir+"/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, nil);
	slot := readstring(cfd);
	if(slot == nil)
		return (nil, nil);
	sdir := dir + "/" + slot;
	(nil, encalgs) := sys->tokenize(readstring(sys->open(sdir+"/encalgs", Sys->OREAD)), " \t\n");
	(nil, hashalgs) := sys->tokenize(readstring(sys->open(sdir+"/hashalgs", Sys->OREAD)), " \t\n");
	return (encalgs, hashalgs);
}

# Check that new algorithms appear in the SSL device's advertised lists
testAlgorithmAdvertised(t: ref T)
{
	(encalgs, hashalgs) := readalgs();
	if(encalgs == nil) {
		t.skip("cannot read SSL algorithm lists");
		return;
	}

	t.assertseq(join(encalgs), "aes_256_gcm", "encalgs is aes_256_gcm alone");
	t.assertseq(join(hashalgs), "hmac_sha384", "hashalgs is hmac_sha384 alone");
}

join(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != nil)
			s += " ";
		s += hd l;
	}
	return s;
}

# Set up two SSL connections over a pipe, configure algorithm, return (side_a, side_b)
# A sends under secret and B under its reverse: each way its own
sslpair(t: ref T, alg: string, secret: array of byte): (ref Sys->Connection, ref Sys->Connection)
{
	other := array[len secret] of byte;
	for(i := 0; i < len secret; i++)
		other[i] = secret[len secret - 1 - i] ^ byte 16r5a;

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0) {
		t.fatal(sys->sprint("pipe failed: %r"));
		return (nil, nil);
	}

	(erra, ca) := ssl->connect(p[0]);
	if(erra != nil) {
		t.fatal("ssl connect side A: " + erra);
		return (nil, nil);
	}

	(errb, cb) := ssl->connect(p[1]);
	if(errb != nil) {
		t.fatal("ssl connect side B: " + errb);
		return (nil, nil);
	}

	err := ssl->secret(ca, other, secret);
	if(err != nil) {
		t.fatal("secret side A: " + err);
		return (nil, nil);
	}

	err = ssl->secret(cb, secret, other);
	if(err != nil) {
		t.fatal("secret side B: " + err);
		return (nil, nil);
	}

	# Set algorithm on both sides
	if(sys->fprint(ca.cfd, "alg %s", alg) < 0) {
		t.fatal(sys->sprint("alg side A: %r"));
		return (nil, nil);
	}
	if(sys->fprint(cb.cfd, "alg %s", alg) < 0) {
		t.fatal(sys->sprint("alg side B: %r"));
		return (nil, nil);
	}

	return (ca, cb);
}

# Write data on one SSL connection, read on the other, compare
roundtrip(t: ref T, alg: string, secret: array of byte, plaintext: array of byte)
{
	(ca, cb) := sslpair(t, alg, secret);
	if(ca == nil)
		return;

	# Spawn reader on side B
	result := chan of (array of byte, string);
	spawn reader(cb.dfd, len plaintext, result);

	# Write plaintext on side A
	n := sys->write(ca.dfd, plaintext, len plaintext);
	if(n != len plaintext) {
		t.fatal(sys->sprint("write: wanted %d, got %d: %r", len plaintext, n));
		return;
	}
	t.log(sys->sprint("wrote %d bytes", n));

	# Read result from side B
	(got, err) := <-result;
	if(err != nil) {
		t.fatal("read side B: " + err);
		return;
	}

	t.asserteq(len got, len plaintext, "received length");

	# Compare byte-by-byte
	for(i := 0; i < len plaintext; i++) {
		if(got[i] != plaintext[i]) {
			t.error(sys->sprint("mismatch at byte %d: got 16r%2.2ux want 16r%2.2ux", i, int got[i], int plaintext[i]));
			return;
		}
	}
	t.log("data verified OK");
}

reader(dfd: ref Sys->FD, expect: int, result: chan of (array of byte, string))
{
	buf := array[expect + 256] of byte;
	total := 0;
	while(total < expect) {
		n := sys->read(dfd, buf[total:], len buf - total);
		if(n <= 0) {
			result <-= (nil, sys->sprint("read returned %d at offset %d: %r", n, total));
			return;
		}
		total += n;
	}
	result <-= (buf[0:total], nil);
}

mksecret(n: int): array of byte
{
	s := array[n] of byte;
	for(i := 0; i < len s; i++)
		s[i] = byte ((i * 37 + 7) % 256);
	return s;
}

testdata(): array of byte
{
	# 200 bytes of varied data, not a multiple of 16
	s := array[200] of byte;
	for(i := 0; i < len s; i++)
		s[i] = byte ((i * 71 + 3) % 256);
	return s;
}

testAESGCM(t: ref T)
{
	roundtrip(t, "aes_256_gcm", mksecret(48), testdata());
	roundtrip(t, "aes_256_gcm", mksecret(32), testdata());
}

testHMACSHA384(t: ref T)
{
	roundtrip(t, "hmac_sha384", mksecret(48), testdata());
}

# the alg named on a connection with these secrets: the error, or nil
pushalg(alg: string, secretin, secretout: array of byte): string
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("pipe: %r");
	(err, c) := ssl->connect(p[0]);
	if(err != nil)
		return "connect: " + err;
	if(ssl->secret(c, secretin, secretout) != nil)
		return "secret";
	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return sys->sprint("%r");
	return nil;
}

refused(t: ref T, what, alg: string, secretin, secretout: array of byte, why: string)
{
	err := pushalg(alg, secretin, secretout);
	t.assert(err != nil, what + " refused");
	t.assert(err != nil && contains(err, why), sys->sprint("%s: says %q (got %q)", what, why, err));
}

testRefused(t: ref T)
{
	a := mksecret(48);
	b := mksecret(48);
	b[0] ^= byte 1;
	for(l := "aes_256_gcm" :: "hmac_sha384" :: nil; l != nil; l = tl l){
		alg := hd l;
		refused(t, alg+": the same secret both ways", alg, a, a, "same secret both ways");
		refused(t, alg+": a secret of 31 bytes", alg, a, mksecret(31), "too short");
		refused(t, alg+": one way's secret alone", alg, a, nil, "a secret each way");
	}
	refused(t, "two algorithms", "aes_256_gcm hmac_sha384", a, b, "one algorithm");
	refused(t, "two algorithms with a slash", "hmac_sha384/aes_256_gcm", a, b, "one algorithm");
	for(l = "aes_256_cbc" :: "aes_128_cbc" :: "sha256" :: "sha1" :: "md5" :: "rc4" :: nil; l != nil; l = tl l)
		refused(t, hd l, hd l, a, b, "unknown algorithm");
	t.assertnil(pushalg("aes_256_gcm", a, b), "and with a secret each way, 48 bytes, aes_256_gcm is taken");
	t.assertnil(pushalg("clear", a, a), "clear takes any secrets");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testConversationPermissions(t: ref T)
{
	dir := "#D";
	(rc, nil) := sys->stat("#D/ssl");
	if(rc >= 0)
		dir = "#D/ssl";
	cfd := sys->open(dir+"/clone", Sys->ORDWR);
	if(cfd == nil) {
		t.skip("cannot clone SSL conversation");
		return;
	}
	slot := readstring(cfd);
	if(slot == nil) {
		t.fatal("cannot read SSL conversation number");
		return;
	}
	d := sys->nulldir;
	d.mode = 8r600;
	if(sys->fwstat(cfd, d) < 0) {
		t.skip("cannot restrict SSL conversation mode");
		return;
	}
	userfd := sys->open("/dev/user", Sys->OWRITE);
	if(userfd == nil) {
		t.skip("test is not running as host owner");
		return;
	}
	other := array of byte "ssl-permission-test";
	if(sys->write(userfd, other, len other) != len other) {
		t.fatal(sys->sprint("cannot drop identity: %r"));
		return;
	}
	userfd = nil;
	fd := sys->open(dir+"/"+slot+"/ctl", Sys->ORDWR);
	t.assert(fd == nil, "non-owner opened owner-only SSL conversation");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	ssl = load SSL SSL->PATH;
	if(ssl == nil) {
		sys->fprint(sys->fildes(2), "cannot load SSL module: %r\n");
		raise "fail:cannot load SSL";
	}
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}

	testing->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("AlgorithmAdvertised", testAlgorithmAdvertised);
	run("AES256_GCM", testAESGCM);
	run("HMAC_SHA384", testHMACSHA384);
	run("Refused", testRefused);
	# This deliberately drops the test process identity, so it must run last.
	run("ConversationPermissions", testConversationPermissions);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
