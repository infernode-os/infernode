implement InflateTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "filter.m";
include "testing.m";
	testing: Testing;
	T: import testing;

InflateTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/inflate_test.b";

passed := 0;
failed := 0;
skipped := 0;

inflate, deflate: Filter;

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

# zlib.compress(b'abcd'*3000 + bytes(range(256))*20 + b'The quick brown fox. '*200, 9)
# from Python's zlib: runs, a pattern and text, adler32 16r720bc4e8
zlibstream := array[] of {
	byte 16r78, byte 16rda, byte 16red, byte 16rcf, byte 16re7, byte 16r57, byte 16rcd, byte 16r01, byte 16r00, byte 16rc6, byte 16r71, byte 16r21,
	byte 16r84, byte 16r64, byte 16r25, byte 16r11, byte 16rfd, byte 16r92, byte 16rdd, byte 16r10, byte 16r25, byte 16r52, byte 16r08, byte 16r4d,
	byte 16rb2, byte 16ra3, byte 16r90, byte 16r51, byte 16ra9, byte 16ree, byte 16r75, byte 16r75, byte 16r6f, byte 16ra5, byte 16r34, byte 16r8c,
	byte 16rec, byte 16r14, byte 16ra5, byte 16r22, byte 16r23, byte 16r7b, byte 16r6f, byte 16r4d, byte 16rab, byte 16r54, byte 16r68, byte 16r98,
	byte 16r25, byte 16r42, byte 16rbb, byte 16rc8, byte 16r1e, byte 16r45, byte 16rc3, byte 16r68, byte 16r18, byte 16rc7, byte 16rbf, byte 16re0,
	byte 16r8d, byte 16r73, byte 16r9c, byte 16ref, byte 16r8b, byte 16rcf, byte 16r9b, byte 16re7, byte 16rcd, byte 16r73, byte 16rbe, byte 16r8e,
	byte 16r4e, byte 16rce, byte 16r8b, byte 16r1d, byte 16r01, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00,
	byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16rf8, byte 16rc7, byte 16r9a,
	byte 16rc9, byte 16r35, byte 16r6f, byte 16rd1, byte 16r52, byte 16rbe, byte 16r55, byte 16reb, byte 16r36, byte 16r0a, byte 16r6d, byte 16rdb,
	byte 16rb5, byte 16r57, byte 16rec, byte 16ra0, byte 16rd4, byte 16rb1, byte 16r53, byte 16re7, byte 16r2e, byte 16r5d, byte 16r95, byte 16rbb,
	byte 16ra9, byte 16r74, byte 16r57, byte 16red, byte 16rd1, byte 16r53, byte 16rad, byte 16r57, byte 16r6f, byte 16r75, byte 16r41, byte 16ra3,
	byte 16r8f, byte 16r66, byte 16rdf, byte 16r7e, byte 16rfd, byte 16r07, byte 16r0c, byte 16r1c, byte 16r34, byte 16r58, byte 16r4b, byte 16r5b,
	byte 16r47, byte 16r77, byte 16r88, byte 16rde, byte 16rd0, byte 16r61, byte 16rfa, byte 16r06, byte 16rc3, byte 16r0d, byte 16r47, byte 16r8c,
	byte 16r34, byte 16r1a, byte 16r65, byte 16r6c, byte 16r32, byte 16r7a, byte 16rcc, byte 16r58, byte 16rd3, byte 16r71, byte 16re3, byte 16r27,
	byte 16r98, byte 16r99, byte 16r5b, byte 16r58, byte 16r5a, byte 16r59, byte 16r4f, byte 16r9c, byte 16r64, byte 16r33, byte 16r79, byte 16rca,
	byte 16rd4, byte 16r69, byte 16rd3, byte 16r67, byte 16rcc, byte 16rb4, byte 16r9d, byte 16r35, byte 16rdb, byte 16rce, byte 16r7e, byte 16rce,
	byte 16rdc, byte 16r79, byte 16r0e, byte 16rf3, byte 16r17, byte 16r2c, byte 16r5c, byte 16rf4, byte 16re7, byte 16rc4, byte 16rc5, byte 16rd5,
	byte 16r4d, byte 16r24, byte 16r5e, byte 16r22, byte 16r59, byte 16rea, byte 16r2e, byte 16r95, byte 16r79, byte 16r78, byte 16r7a, byte 16r2d,
	byte 16rf3, byte 16rf6, byte 16r59, byte 16ree, byte 16reb, byte 16re7, byte 16r1f, byte 16rb0, byte 16r62, byte 16re5, byte 16raa, byte 16rd5,
	byte 16r81, byte 16r6b, byte 16rd6, byte 16rae, byte 16r5b, byte 16rbf, byte 16r61, byte 16re3, byte 16ra6, byte 16ra0, byte 16rcd, byte 16rc1,
	byte 16r21, byte 16r5b, byte 16rb6, byte 16r86, byte 16r86, byte 16r6d, byte 16r0b, byte 16r8f, byte 16r88, byte 16rdc, byte 16rbe, byte 16r23,
	byte 16r6a, byte 16re7, byte 16rae, byte 16rdd, byte 16r7b, byte 16ra2, byte 16rf7, byte 16ree, byte 16rdb, byte 16r7f, byte 16re0, byte 16re0,
	byte 16ra1, byte 16rc3, byte 16r47, byte 16r8e, byte 16r1e, byte 16r3b, byte 16r7e, byte 16re2, byte 16re4, byte 16ra9, byte 16rd3, byte 16r67,
	byte 16rce, byte 16r9e, byte 16r3b, byte 16r7f, byte 16r21, byte 16r26, byte 16r36, byte 16r2e, byte 16r3e, byte 16r21, byte 16rf1, byte 16re2,
	byte 16ra5, byte 16rcb, byte 16r57, byte 16rae, byte 16r26, byte 16r25, byte 16r5f, byte 16r4b, byte 16r49, byte 16r4d, byte 16rbb, byte 16r7e,
	byte 16re3, byte 16r66, byte 16r7a, byte 16r46, byte 16r66, byte 16rd6, byte 16rad, byte 16rdb, byte 16r77, byte 16ree, byte 16rde, byte 16rbb,
	byte 16r9f, byte 16r9d, byte 16rf3, byte 16r20, byte 16rf7, byte 16re1, byte 16ra3, byte 16rbc, byte 16rc7, byte 16r4f, byte 16r9e, byte 16re6,
	byte 16r17, byte 16r14, byte 16r16, byte 16r15, byte 16r97, byte 16r94, byte 16r96, byte 16r95, byte 16r3f, byte 16r7b, byte 16r5e, byte 16rf1,
	byte 16re2, byte 16re5, byte 16rab, byte 16rd7, byte 16r6f, byte 16rde, byte 16rbe, byte 16r7b, byte 16rff, byte 16re1, byte 16r63, byte 16r65,
	byte 16rd5, byte 16ra7, byte 16rcf, byte 16rd5, byte 16r35, byte 16rb5, byte 16r75, byte 16r5f, byte 16rbe, byte 16r7e, byte 16rfb, byte 16r5e,
	byte 16rdf, byte 16rd0, byte 16rd8, byte 16rf4, byte 16re3, byte 16re7, byte 16r2f, byte 16rfa, byte 16re9, byte 16ra7, byte 16r9f, byte 16r7e,
	byte 16rfa, byte 16re9, byte 16ra7, byte 16r9f, byte 16r7e, byte 16rfa, byte 16re9, byte 16ra7, byte 16r9f, byte 16r7e, byte 16rfa, byte 16re9,
	byte 16ra7, byte 16r9f, byte 16r7e, byte 16rfa, byte 16re9, byte 16rff, byte 16r9f, byte 16rfb, byte 16r6d, byte 16r45, byte 16r2e, byte 16r82,
	byte 16ra7, byte 16r8f, byte 16rd8, byte 16r59, byte 16r22, byte 16r38, byte 16r79, byte 16rc9, byte 16r7c, byte 16ra5, byte 16r82, byte 16rab,
	byte 16rcc, byte 16r4f, byte 16r57, byte 16r60, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64,
	byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16r64, byte 16rfc, byte 16r8b, byte 16rf1, byte 16r37, byte 16r72,
	byte 16r0b, byte 16rc4, byte 16re8,
};

expected(): array of byte
{
	d := array[21320] of byte;
	n := 0;
	for(i := 0; i < 3000; i++) {
		d[n++] = byte 'a'; d[n++] = byte 'b'; d[n++] = byte 'c'; d[n++] = byte 'd';
	}
	for(i = 0; i < 20; i++)
		for(j := 0; j < 256; j++)
			d[n++] = byte j;
	fox := array of byte "The quick brown fox. ";
	for(i = 0; i < 200; i++) {
		d[n:] = fox;
		n += len fox;
	}
	return d;
}

# all of data through f with param; (output, error)
filter(f: Filter, param: string, data: array of byte): (array of byte, string)
{
	rq := f->start(param);
	out := array[0] of byte;
	off := 0;
	for(;;) pick m := <-rq {
	Fill =>
		n := len data - off;
		if(n > len m.buf)
			n = len m.buf;
		m.buf[0:] = data[off:off+n];
		off += n;
		m.reply <-= n;
	Result =>
		o := array[len out + len m.buf] of byte;
		o[0:] = out;
		o[len out:] = m.buf;
		out = o;
		m.reply <-= 0;
	Finished =>
		return (out, nil);
	Error =>
		return (out, m.e);
	Info =>
		;
	}
}

differ(a, b: array of byte): int
{
	for(i := 0; i < len a && i < len b; i++)
		if(a[i] != b[i])
			return i;
	return i;
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

# A stream another zlib made, its checksum verified
testZlibStream(t: ref T)
{
	(out, err) := filter(inflate, "z", zlibstream);
	t.assertnil(err, "inflate");
	t.asserteq(len out, 21320, "length");
	t.assert(same(out, expected()), "bytes");
}

# Its checksum changed: refused
testZlibBadSum(t: ref T)
{
	bad := array[len zlibstream] of byte;
	bad[0:] = zlibstream;
	bad[len bad - 1] ^= byte 1;
	(nil, err) := filter(inflate, "z", bad);
	t.assert(err != nil, "a wrong adler32 refused");
	t.log("error: " + err);
}

# Megabytes through deflate and back, as zlib and as gzip: runs whose
# copies overlap themselves (a pixel repeated), long copies that do
# not, and bytes that hardly compress, over many blocks and checksum
# sums (adler32's s2 near its limit with bytes of 255).  At level 9
# deflate matched a string past where its history had slid, and the
# stream failed its own checksum (as gzip -9's could)
testRoundTrip(t: ref T)
{
	n := 3*1024*1024;
	d := array[n] of byte;
	seed := 1;
	for(i := 0; i < n; ) {
		seed = seed * 1103515245 + 12345;
		k := (seed >> 16) & 7;
		l := ((seed >> 4) & 511) + 1;
		if(i + l > n)
			l = n - i;
		case k {
		0 or 1 =>
			for(j := 0; j < l; j++)
				d[i+j] = byte 255;
		2 or 3 =>
			for(j := 0; j < l; j++)
				d[i+j] = byte ((j & 3) * 60 + k);
		4 =>
			if(i >= 4096) {
				d[i:] = d[i-4000:i-4000+l];
				break;
			}
			for(j := 0; j < l; j++)
				d[i+j] = byte j;
		* =>
			for(j := 0; j < l; j++) {
				seed = seed * 1103515245 + 12345;
				d[i+j] = byte (seed >> 16);
			}
		}
		i += l;
	}
	for(pl := "z6" :: "z1" :: "z9" :: "h9" :: nil; pl != nil; pl = tl pl) {
		p := hd pl;
		(z, err) := filter(deflate, p, d);
		if(err != nil)
			t.fatal("deflate " + p + ": " + err);
		(out, err2) := filter(inflate, p[0:1], z);
		if(err2 != nil)
			t.error("inflate " + p + ": " + err2);
		if(!same(out, d))
			t.error(sys->sprint("round trip %s: %d bytes back, differing at %d", p, len out, differ(out, d)));
		t.log(sys->sprint("%s: %d bytes in %d", p, n, len z));
	}
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
	inflate = load Filter "/dis/lib/inflate.dis";
	deflate = load Filter "/dis/lib/deflate.dis";
	if(inflate == nil || deflate == nil) {
		sys->fprint(sys->fildes(2), "cannot load inflate or deflate: %r\n");
		raise "fail:cannot load";
	}
	inflate->init();
	deflate->init();

	run("ZlibStream", testZlibStream);
	run("ZlibBadSum", testZlibBadSum);
	run("RoundTrip", testRoundTrip);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
