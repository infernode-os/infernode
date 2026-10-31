implement NmeaTest;

#
# nmea(2): sentences framed and checked, positions and times read,
# a receiver's burst of sentences for one time assembled into one fix,
# satellites in view and used, error estimates, sentences that are
# short or garbled taken without harm.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "nmea.m";
	nmea: Nmea;
	Fix, Parser: import nmea;

NmeaTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/nmea_test.b";

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

# a sentence with its checksum
cs(body: string): string
{
	sum := 0;
	for(i := 0; i < len body; i++)
		sum ^= body[i];
	return sys->sprint("$%s*%.2X\r\n", body, sum);
}

# feed sentences; the fixes they completed
feed(p: ref Parser, l: list of string): list of ref Fix
{
	out: list of ref Fix;
	for(; l != nil; l = tl l) {
		(fl, err) := p.sentence(hd l);
		if(err != nil)
			raise "fail:feed " + hd l + ": " + err;
		for(; fl != nil; fl = tl fl)
			out = hd fl :: out;
	}
	r: list of ref Fix;
	for(; out != nil; out = tl out)
		r = hd out :: r;
	return r;
}

near(a, b: real): int
{
	d := a - b;
	return d < 0.0000005 && d > -0.0000005;
}

testFraming(t: ref T)
{
	(a, err) := nmea->fields(cs("GPRMC,143205.00,A,4047.04,N,07425.00,W,0.0,0.0,311026,,,A"));
	t.assertnil(err, "a sentence with a good checksum");
	t.asserteq(len a, 13, "every field, the empty ones too");
	t.assertseq(a[0], "GPRMC", "the address");
	t.assertseq(a[10], "", "an empty field");

	s := cs("GPRMC,143205.00,A,4047.04,N,07425.00,W,0.0,0.0,311026,,,A");
	bad := s[0:len s-4] + "00\r\n";
	(nil, err) = nmea->fields(bad);
	t.assertseq(err, "checksum mismatch", "a bad checksum refused");

	(a, err) = nmea->fields("$GPGGA,1,2,3");
	t.assertnil(err, "no checksum is taken");
	t.asserteq(len a, 4, "fields of a sentence with no checksum");

	(nil, err) = nmea->fields("GPGGA,1,2,3*00");
	t.assertseq(err, "not a sentence", "no $");
	(nil, err) = nmea->fields("$GPGGA,1*G0");
	t.assertseq(err, "bad checksum field", "a checksum that is not hex");
	(nil, err) = nmea->fields("$GPGGA,1*0");
	t.assertseq(err, "bad checksum field", "a checksum one digit long");
	(nil, err) = nmea->fields("$G,1");
	t.assertseq(err, "bad address field", "an address too short");
}

testRmc(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("GPRMC,143205.25,A,4047.0400,N,07425.0000,W,10.0,271.5,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "RMC alone: a fix");
	f := hd fl;
	t.assert(near(f.lat, 40.784), "latitude: " + string f.lat);
	t.assert(near(f.lon, -74.416667) || (f.lon + 74.416667 < 0.000001 && f.lon + 74.416667 > -0.000001),
		"longitude west is negative: " + string f.lon);
	t.assertseq(f.time(), "2026-10-31T14:32:05.25Z", "date and time, the fraction kept");
	t.assertseq(sys->sprint("%.4f", f.speed), "5.1444", "knots as metres a second");
	t.assertseq(sys->sprint("%.1f", f.course), "271.5", "course");
	t.assertseq(f.position(), "40.784000 -74.416667", "position");
	t.assertseq(f.quality, "gps", "the mode indicator");

	p = Parser.new();
	fl = feed(p, cs("GPRMC,000000.00,A,3352.0000,S,15112.0000,E,,,010199,,") :: nil);
	f = hd fl;
	t.assertseq(f.position(), "-33.866667 151.200000", "south and east");
	t.assertseq(f.time(), "1999-01-01T00:00:00Z", "a zero fraction dropped, 99 is 1999");
	t.assert(!f.hasspeed && !f.hascourse, "no speed, no course");
	t.assertseq(f.text(), "time=1999-01-01T00:00:00Z lat=-33.866667 lon=151.200000 mode=2d",
		"absent fields left out");
}

testEpoch(t: ref T)
{
	p := Parser.new();
	rmc1 := cs("GPRMC,120000,A,5130.0000,N,00007.0000,W,0.0,0.0,311026,,,A");
	gga1 := cs("GPGGA,120000,5130.0000,N,00007.0000,W,1,08,0.9,35.2,M,47.0,M,,");
	rmc2 := cs("GPRMC,120001,A,5130.0060,N,00007.0000,W,0.0,0.0,311026,,,A");
	gga2 := cs("GPGGA,120001,5130.0060,N,00007.0000,W,2,09,0.8,35.4,M,47.0,M,,");
	rmc3 := cs("GPRMC,120002,A,5130.0120,N,00007.0000,W,0.0,0.0,311026,,,A");
	rmc4 := cs("GPRMC,120003,A,5130.0180,N,00007.0000,W,0.0,0.0,311026,,,A");

	fl := feed(p, rmc1 :: nil);
	t.asserteq(len fl, 1, "the first RMC: a fix, before the receiver is known to send GGA");
	fl = feed(p, gga1 :: nil);
	t.asserteq(len fl, 0, "GGA for a time given out: no second fix");
	t.assert(p.last.hasalt, "but the last fix has the GGA's altitude");
	t.assertseq(sys->sprint("%.1f", p.last.altitude), "35.2", "altitude");
	t.asserteq(p.last.sats, 8, "satellites used");

	fl = feed(p, rmc2 :: nil);
	t.asserteq(len fl, 0, "RMC for a new time: wait for its GGA");
	fl = feed(p, gga2 :: nil);
	t.asserteq(len fl, 1, "its GGA: the fix");
	f := hd fl;
	t.assertseq(f.utc, "12:00:01", "the new time");
	t.assertseq(sys->sprint("%.1f", f.altitude), "35.4", "with the GGA's altitude");
	t.assertseq(f.quality, "dgps", "GGA's quality");
	t.asserteq(f.sats, 9, "and satellites");

	fl = feed(p, rmc3 :: nil);
	t.asserteq(len fl, 0, "RMC with its GGA lost");
	fl = feed(p, rmc4 :: nil);
	t.asserteq(len fl, 1, "the next time completes it");
	t.assertseq((hd fl).utc, "12:00:02", "the one whose GGA was lost");
	t.assertseq((hd fl).position(), "51.500200 -0.116667", "with its own position");

	p.forget();
	t.assertseq(p.last.position(), "51.500200 -0.116667", "forget keeps the last fix");
	fl = feed(p, cs("GPRMC,130000,A,5130.0000,N,00007.0000,W,0.0,0.0,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "but not that the receiver sent GGA");
}

testNoFix(t: ref T)
{
	p := Parser.new();
	v := cs("GPRMC,,V,,,,,,,,,,N");
	fl := feed(p, v :: nil);
	t.asserteq(len fl, 1, "no fix at first: told once");
	t.assertseq((hd fl).text(), "mode=none", "the record says none");
	t.assertnil((hd fl).position(), "no position");
	fl = feed(p, cs("GPRMC,100000,V,,,,,,,311026,,,N") :: cs("GPRMC,100001,V,,,,,,,311026,,,N") :: nil);
	t.asserteq(len fl, 0, "still no fix: not told again");
	fl = feed(p, cs("GPRMC,100002,A,0100.0000,N,00100.0000,E,,,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "a fix");
	fl = feed(p, cs("GPRMC,100003,V,0100.0000,N,00100.0000,E,,,311026,,,N") :: nil);
	t.asserteq(len fl, 1, "the fix lost: told");
	t.assert(!(hd fl).valid, "invalid");
	t.assertnil((hd fl).position(), "a position the receiver says is not a fix is not given");
}

testSatellites(t: ref T)
{
	p := Parser.new();
	feed(p, cs("GPRMC,080000,A,0000.0000,N,00000.0000,E,,,311026,,,A") ::
		cs("GPGSA,A,3,04,09,46,,,,,,,,,,1.8,1.0,1.5") ::
		cs("GLGSA,A,3,70,,,,,,,,,,,,1.8,1.0,1.5") ::
		cs("GPGSV,2,1,05,04,45,270,38,09,10,020,22,12,05,300,,46,30,200,40") ::
		cs("GPGSV,2,2,05,17,60,100,33") ::
		cs("GLGSV,1,1,02,70,50,150,30,71,05,010,") ::
		nil);
	s := p.satellites();
	want := "gps 4 45 270 38 1\n" +
		"gps 9 10 20 22 1\n" +
		"gps 12 5 300 - 0\n" +
		"gps 17 60 100 33 0\n" +
		"sbas 46 30 200 40 1\n" +
		"glonass 70 50 150 30 1\n" +
		"glonass 71 5 10 - 0\n";
	t.assertseq(s, want, "in view, by system and PRN, used from GSA");
	t.asserteq(p.cur.mode, Nmea->M3d, "GSA's mode");
	t.assertseq(sys->sprint("%.1f %.1f %.1f", p.cur.pdop, p.cur.hdop, p.cur.vdop), "1.8 1.0 1.5", "dilutions");

	# a report half sent does not replace the last whole one
	feed(p, cs("GPGSV,2,1,05,04,45,270,38,09,10,020,22,12,05,300,,46,30,200,40") :: nil);
	t.assertseq(p.satellites(), want, "a report in progress is not shown");

	# NMEA 4.10: GN talker with a system id, Galileo's own talker
	p = Parser.new();
	feed(p, cs("GNRMC,080000,A,0000.0000,N,00000.0000,E,,,311026,,,A") ::
		cs("GNGSA,A,3,11,,,,,,,,,,,,1.8,1.0,1.5,3") ::
		cs("GAGSV,1,1,01,11,40,090,35,7") ::
		nil);
	t.assertseq(p.satellites(), "galileo 11 40 90 35 1\n", "Galileo, by GSA's system id");
}

testErrors(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("GPGST,090000,1.0,3.0,2.0,0.0,3.0,4.0,6.5") ::
		cs("GPRMC,090000,A,1000.0000,N,01000.0000,E,,,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "a fix");
	f := hd fl;
	t.assertseq(sys->sprint("%.1f %.1f", f.err, f.verr), "5.0 6.5", "GST's errors");
	t.assert(len f.text() > 0, "text: " + f.text());
	t.assert(contains(f.text(), " err=5.0 verr=6.5"), "in the record");
}

testVtgZda(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("GPZDA,070000,31,10,2026,00,00") ::
		cs("GPVTG,90.0,T,,M,,N,36.0,K,A") ::
		cs("GPGGA,070000,0000.0000,N,00000.0000,E,1,05,1.2,10.0,M,,,,") :: nil);
	t.asserteq(len fl, 1, "GGA alone: a fix");
	f := hd fl;
	t.assertseq(f.time(), "2026-10-31T07:00:00Z", "the date from ZDA");
	t.assertseq(sys->sprint("%.1f %.1f", f.speed, f.course), "10.0 90.0", "VTG's km/h and course");
	t.asserteq(f.fixmode(), Nmea->M3d, "an altitude: 3d");
	t.assertseq(f.text(),
		"time=2026-10-31T07:00:00Z lat=0.000000 lon=0.000000 alt=10.0 speed=10.00 course=90.0 mode=3d q=gps sats=5 hdop=1.2",
		"the whole record");

	p = Parser.new();
	fl = feed(p, cs("GPGGA,070000,0000.0000,N,00000.0000,E,1,05,1.2,10.0,M,,,,") :: nil);
	t.assertnil((hd fl).time(), "GGA has no date: no time");
	t.assertseq(nmea->timeof(cs("GPGGA,070000,0000.0000,N,00000.0000,E,1,05,1.2,10.0,M,,,,")), "07:00:00", "timeof");
	t.assertseq(nmea->timeof(cs("GPGLL,0000.00,N,00000.00,E,070001.5,A,A")), "07:00:01.5", "timeof GLL");
	t.assertnil(nmea->timeof(cs("GPGSA,A,3")), "timeof a sentence with no time");
}

testGarbled(t: ref T)
{
	p := Parser.new();
	junk := array[] of {
		"$GPRMC",
		"$GPRMC,",
		"$GPGGA,,,,,,,,,,,,,,",
		"$GPGSV",
		"$GPGSV,9,10,",
		"$GPGSV,1,1,03,04,4",
		"$GPGSA,A",
		"$GPRMC,12,A,40,N,74,W,,,9999,,",
		"$GPRMC,120000,A,4099.0000,N,07425.0000,W,,,311026,,",
		"$GPRMC,250000,A,4000.0000,X,07425.0000,W,,,311026,,",
		"$GPGST,1,,,,,,,",
		"$GPZDA,1,99,99,99",
		"$PUBX,00,whatever",
		"$GPXYZ,1,2,3",
		"$--RMC,1",
	};
	for(i := 0; i < len junk; i++) {
		{
			(nil, nil) = p.sentence(junk[i]);
		} exception e {
		"*" =>
			t.error("raised " + e + " on " + junk[i]);
		}
	}
	t.assert(p.last == nil || p.last.position() == nil, "no position from any of it");
	(nil, err) := p.sentence("!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0*26");
	t.assertseq(err, "not a sentence", "AIS is not a sentence");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
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
	if(nmea == nil) {
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Nmea->PATH);
		raise "fail:cannot load nmea";
	}
	testing->init();
	nmea->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Framing", testFraming);
	run("Rmc", testRmc);
	run("Epoch", testEpoch);
	run("NoFix", testNoFix);
	run("Satellites", testSatellites);
	run("Errors", testErrors);
	run("VtgZda", testVtgZda);
	run("Garbled", testGarbled);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
