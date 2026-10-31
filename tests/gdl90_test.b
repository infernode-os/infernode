implement Gdl90Test;

#
# gdl90(2) and garminav(2), the receivers gpsfs(4) reads that do not
# speak NMEA.  GDL 90: the CRC against the specification's heartbeat
# example, framing and escapes both ways, the specification's traffic
# report example (N825V) decoded, an own-ship report with the
# heartbeat's GPS valid bit, frames split anywhere, a bad CRC counted.
# Garmin Aviation: a group of records with and without blanks or
# points, the track made true by the variation, a group with dashes for
# its position, a group whose ETX was lost.  And a fix from each
# written as NMEA reads back the same.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "nmea.m";
	nmea: Nmea;
	Fix, Target, Parser: import nmea;

include "gdl90.m";
	gdl90: Gdl90;
	Framer: import gdl90;

include "garminav.m";
	garminav: Garminav;
	Grouper: import garminav;

Gdl90Test: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/gdl90_test.b";

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

bytes(a: array of int): array of byte
{
	b := array[len a] of byte;
	for(i := 0; i < len a; i++)
		b[i] = byte a[i];
	return b;
}

# GDL 90 specification, 3.5.4: a traffic report, N825V
N825V := array[] of {
	16r14, 16r00, 16rAB, 16r45, 16r49, 16r1F, 16rEF, 16r15, 16rA8, 16r89, 16r78,
	16r0F, 16r09, 16rA9, 16r07, 16rB0, 16r01, 16r20, 16r01, 16r4E, 16r38, 16r32,
	16r35, 16r56, 16r20, 16r20, 16r20, 16r00,
};

testCrc(t: ref T)
{
	# the specification's heartbeat example: CRC B3 8B, low byte first
	t.asserteq(gdl90->crc(bytes(array[] of {16r00, 16r81, 16r41, 16rDB, 16rD0, 16r08, 16r02})), 16r8BB3,
		"the heartbeat example's CRC");
	f := gdl90->frame(bytes(array[] of {16r00, 16r81, 16r41, 16rDB, 16rD0, 16r08, 16r02}));
	want := bytes(array[] of {16r7E, 16r00, 16r81, 16r41, 16rDB, 16rD0, 16r08, 16r02, 16rB3, 16r8B, 16r7E});
	t.assert(same(f, want), "framed as the specification shows it");

	# a flag and an escape inside a message are escaped
	f = gdl90->frame(bytes(array[] of {16r65, 16r7E, 16r7D, 16r01}));
	t.asserteq(int f[2], 16r7D, "0x7E escaped");
	t.asserteq(int f[3], 16r5E, "as 0x7D 0x5E");
	t.asserteq(int f[4], 16r7D, "0x7D escaped");
	t.asserteq(int f[5], 16r5D, "as 0x7D 0x5D");
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

testTraffic(t: ref T)
{
	d := Framer.new();
	(fl, ts) := d.feed(gdl90->frame(bytes(N825V)));
	t.assert(fl == nil, "a traffic report is not own-ship");
	t.asserteq(len ts, 1, "one target");
	tg := hd ts;
	s := tg.text(tg.seen);
	t.assertseq(s, "kind=adsb id=ab4549 lat=44.907067 lon=-122.994862 alt=1524 speed=63.3 course=45.0 climb=0.3 name=N825V cat=light age=0.0",
		"N825V: 44.90708 -122.99488 (to the encoding's 2e-5 degrees), 5000 feet, 123 knots, track 45, +64 feet a minute");
}

# an own-ship report as N825V's, with its id 10
ownship(): array of byte
{
	b := bytes(N825V);
	b[0] = byte 10;
	return b;
}

testOwnship(t: ref T)
{
	d := Framer.new();
	heartbeat := bytes(array[] of {16r00, 16r81, 16r41, 16rDB, 16rD0, 16r08, 16r02});
	(fl, nil) := d.feed(gdl90->frame(ownship()));
	t.asserteq(len fl, 1, "an own-ship report: a fix");
	t.assert(!(hd fl).valid, "before a heartbeat says the GPS is valid: not a fix");
	d.feed(gdl90->frame(heartbeat));
	(fl, nil) = d.feed(gdl90->frame(ownship()));
	f := hd fl;
	t.assert(f.valid && f.haspos, "after one: a fix");
	t.assertseq(sys->sprint("%.5f %.5f", f.lat, f.lon), "44.90707 -122.99486", "its position");
	t.assertseq(sys->sprint("%.1f", f.baroalt), "1524.0", "pressure altitude, 5000 feet");
	t.assert(!f.hasalt, "no altitude above sea level from GDL 90");
	t.assertseq(sys->sprint("%.1f %.1f", f.speed, f.course), "63.3 45.0", "speed and true track");
	t.assertseq(sys->sprint("%.1f", f.err), "15.0", "NACp 9: under 30 m, 95%");

	# written as NMEA, read back
	f.date = "2026-10-31";
	f.utc = "12:00:00";
	p := Parser.new();
	(n, l) := sys->tokenize(nmea->sentences(f), "\r\n");
	t.asserteq(n, 4, "RMC GST GGA PGRMZ");
	for(; l != nil; l = tl l)
		p.sentence(hd l);
	t.assertseq(p.last.text(), "time=2026-10-31T12:00:00Z lat=44.907067 lon=-122.994862 baroalt=1524.0 speed=63.28 course=45.0 mode=2d q=gps err=15.0",
		"as NMEA: the same fix");
}

testFraming(t: ref T)
{
	d := Framer.new();
	all := array[0] of byte;
	for(i := 0; i < 3; i++)
		all = cat(all, gdl90->frame(bytes(N825V)));
	all = cat(bytes(array[] of {16r55, 16r7E, 16r7E}), all);	# noise, then empty frames
	n := 0;
	for(i = 0; i < len all; i += 5) {
		e := i + 5;
		if(e > len all)
			e = len all;
		(nil, got) := d.feed(all[i:e]);
		n += len got;
	}
	t.asserteq(n, 3, "frames fed five bytes at a time");

	bad := gdl90->frame(bytes(N825V));
	bad[10] ^= byte 1;
	(nil, none) := d.feed(bad);
	t.asserteq(len none, 0, "a bad CRC: nothing");
	t.asserteq(d.bad, 1, "and counted");
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

testGarmin(t: ref T)
{
	g := Grouper.new();
	group := "\u0002z00673\r\nAN 40 4106\r\nBW 074 2393\r\nC090\r\nD045\r\nE00123\r\nGL0012\r\n" +
		"I0900\r\nKKJFK \r\nL0900\r\nQW129\r\nS-----\r\nT---------\r\nl000123\r\n\u0003";
	fl := g.feed(array of byte group);
	t.asserteq(len fl, 1, "a group: a fix");
	f := hd fl;
	t.assert(f.valid, "valid");
	t.assertseq(sys->sprint("%.6f %.6f", f.lat, f.lon), "40.684333 -74.398833", "N 40 41.06, W 074 23.93");
	t.assertseq(sys->sprint("%.1f", f.altitude), "205.1", "673 feet");
	t.assertseq(sys->sprint("%.2f", f.speed), "23.15", "45 knots");
	t.assertseq(sys->sprint("%.1f %.1f", f.magvar, f.course), "-12.9 77.1", "magnetic 90, variation 12.9 W: 77.1 true");

	# no blanks, points, in pieces
	g = Grouper.new();
	s := array of byte "\u0002z-0050\r\nAS3351.408\r\nBE15112.918\r\nC000\r\nD000\r\nQE00.0\r\n\u0003";
	fl = nil;
	for(i := 0; i < len s; i++)
		fl = g.feed(s[i:i+1]);
	t.asserteq(len fl, 1, "fed a byte at a time");
	t.assertseq(sys->sprint("%.5f %.5f %.1f", (hd fl).lat, (hd fl).lon, (hd fl).altitude), "-33.85680 151.21530 -15.2",
		"south, east, below sea level");

	# dashes: no position
	g = Grouper.new();
	fl = g.feed(array of byte "\u0002z-----\r\nA----------\r\nB-----------\r\nC---\r\nD---\r\nQ----\r\n\u0003");
	t.asserteq(len fl, 1, "a group of dashes");
	t.assert(!(hd fl).valid, "is a lost fix");

	# a lost ETX: the next z completes it
	g = Grouper.new();
	fl = g.feed(array of byte "\u0002z00100\r\nAN4000.00\r\nBW07400.00\r\nz00200\r\nAN4100.00\r\nBW07400.00\r\n\u0003");
	t.asserteq(len fl, 2, "two groups, the first's ETX lost");
	t.assertseq(sys->sprint("%.1f %.1f", (hd fl).lat, (hd tl fl).lat), "40.0 41.0", "each its own");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	nmea = load Nmea Nmea->PATH;
	gdl90 = load Gdl90 Gdl90->PATH;
	garminav = load Garminav Garminav->PATH;
	if(nmea == nil || gdl90 == nil || garminav == nil) {
		sys->fprint(sys->fildes(2), "cannot load nmea, gdl90 or garminav: %r\n");
		raise "fail:cannot load";
	}
	testing->init();
	nmea->init();
	gdl90->init(nmea);
	garminav->init(nmea);
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Crc", testCrc);
	run("Traffic", testTraffic);
	run("Ownship", testOwnship);
	run("Framing", testFraming);
	run("Garmin", testGarmin);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
