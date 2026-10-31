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
	more := array[] of {
		"!AIVDM",
		"!AIVDM,1,1,,A,,0",
		"!AIVDM,1,1,,A,1,0",
		"!AIVDM,1,1,,A,~~~~,0",
		"!AIVDM,3,2,9,A,15M67FC000G?ufbE,0",
		"$PGRMZ",
		"$PGRMZ,abc,f,3",
		"$PFLAA,0,100,200",
		"$GPHDG",
		"$GPHDT,x,T",
	};
	for(i = 0; i < len more; i++) {
		{
			(nil, nil) = p.sentence(more[i]);
		} exception e {
		"*" =>
			t.error("raised " + e + " on " + more[i]);
		}
	}
	t.assertseq(p.traffic(sys->millisec()), "", "no traffic from any of it");
	(fl, err) := p.sentence("!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0*26");
	t.assertnil(err, "AIS is a sentence");
	t.assert(fl == nil, "and not a fix");
	(nil, err) = p.sentence("!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0*27");
	t.assertseq(err, "checksum mismatch", "an AIS sentence's checksum is checked");
}

# the sentences pyais (a reference AIS codec) made for these, as VDM
AIS1: con "!AIVDM,1,1,,A,139Lg00P1s0ef3PN`kp3K2h1P000,0*32";
AIS3: con "!AIVDM,1,1,,A,139Lg0OP00:l;tqd`0I>4?v1P000,0*1E";
AIS5a: con "!AIVDM,2,1,3,A,539Lg000Bm`L@48<000mJ0EP4m0hD0000000001600000000000000000000,0*01";
AIS5b: con "!AIVDM,2,2,3,A,00000000000,2*27";
AIS18: con "!AIVDM,1,1,,A,B52MJh00=nc@lJ5lQE1hQIP00000,0*36";
AIS24a: con "!AIVDM,1,1,,A,H52MJh1<D6098DE`D00000000000,0*5D";
AIS24b: con "!AIVDM,1,1,,A,H52MJh4U0000000G41ijkl000000,0*11";
AIS19: con "!AIVDM,1,1,,A,C52ulL@0AVcCF85lWb0p@eP0@2T4NU0`b>0000000000J0000000,0*18";

# the traffic, without the ages
traffic(p: ref Parser): list of string
{
	(nil, l) := sys->tokenize(p.traffic(sys->millisec()), "\n");
	r: list of string;
	for(; l != nil; l = tl l) {
		s := hd l;
		for(i := len s - 5; i > 0; i--)
			if(s[i:i+5] == " age=")
				break;
		r = s[0:i] :: r;
	}
	out: list of string;
	for(; r != nil; r = tl r)
		out = hd r :: out;
	return out;
}

testAis(t: ref T)
{
	p := Parser.new();
	feed(p, AIS1 :: nil);
	l := traffic(p);
	t.asserteq(len l, 1, "a position report: a ship");
	t.assertseq(hd l, "kind=ais id=211234560 lat=53.543200 lon=9.987600 speed=6.3 course=87.6 heading=88",
		"its position, speed (12.3 knots), course and heading");

	feed(p, AIS5a :: nil);
	t.assertseq(hd traffic(p), "kind=ais id=211234560 lat=53.543200 lon=9.987600 speed=6.3 course=87.6 heading=88",
		"the first part of two: nothing yet");
	feed(p, AIS5b :: nil);
	t.assertseq(hd traffic(p),
		"kind=ais id=211234560 lat=53.543200 lon=9.987600 speed=6.3 course=87.6 heading=88 name='MV EXAMPLE' callsign=DABC cat=cargo",
		"static data in two parts, merged with the position");

	feed(p, AIS3 :: nil);
	l = traffic(p);
	t.asserteq(len l, 2, "a second ship");
	found := 0;
	for(; l != nil; l = tl l)
		if(hd l == "kind=ais id=211234561 lat=-33.860100 lon=151.210500 speed=0.0")
			found = 1;
	t.assert(found, "course 360 and heading 511 are not known: " + p.traffic(sys->millisec()));

	p = Parser.new();
	feed(p, AIS18 :: AIS24a :: AIS24b :: nil);
	t.assertseq(hd traffic(p),
		"kind=ais id=338123456 lat=40.689200 lon=-74.044500 speed=2.8 course=180.0 heading=179 name='SEA BREEZE' callsign=WDA1234 cat=pleasure",
		"class B: position (18), name (24A), call sign and type (24B)");
	feed(p, AIS19 :: nil);
	found = 0;
	for(l = traffic(p); l != nil; l = tl l)
		if(hd l == "kind=ais id=338654321 lat=40.700000 lon=-74.010000 speed=3.6 course=90.0 heading=91 name='HARBOR TUG' cat=tug")
			found = 1;
	t.assert(found, "class B extended (19): " + p.traffic(sys->millisec()));

	p = Parser.new();
	feed(p, AIS5b :: nil);
	t.asserteq(len traffic(p), 0, "a second part with no first: nothing");

	# nearest first, from this fix
	p = Parser.new();
	feed(p, cs("GPRMC,120000,A,4042.0000,N,07400.6000,W,,,311026,,,A") :: AIS19 :: AIS18 :: nil);
	l = traffic(p);
	t.assert(len l == 2 && contains(hd l, "id=338654321"), "nearest first: " + p.traffic(sys->millisec()));
	t.assertseq(p.traffic(sys->millisec() + 11*60*1000), "", "forgotten after ten minutes");
}

testMagnetic(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("GPRMC,120000,A,4041.0000,N,07403.0000,W,10.0,90.0,311026,12.9,W,A") :: nil);
	f := hd fl;
	t.assertseq(sys->sprint("%.1f", f.magvar), "-12.9", "variation west is negative");
	t.assert(contains(f.text(), " course=90.0 mcourse=102.9 "), "course, and magnetic: " + f.text());
	t.assert(contains(f.text(), " magvar=-12.9"), "the variation in the record");

	feed(p, cs("HEHDT,45.5,T") :: nil);
	t.assertseq(sys->sprint("%.1f", p.cur.heading), "45.5", "HDT: true heading");
	t.assert(contains(p.cur.text(), " heading=45.5 mheading=58.4"), "heading, and magnetic: " + p.cur.text());

	# a magnetic sensor 100, deviation 2 E, variation 13 W: 100+2-13 true
	feed(p, cs("HCHDG,100.0,2.0,E,13.0,W") :: nil);
	t.assertseq(sys->sprint("%.1f %.1f", p.cur.heading, p.cur.magvar), "89.0 -13.0", "HDG: deviation and variation applied");
	feed(p, cs("HCHDM,200.0,M") :: nil);
	t.assertseq(sys->sprint("%.1f", p.cur.heading), "187.0", "HDM with the variation known");

	p = Parser.new();
	feed(p, cs("HCHDM,200.0,M") :: nil);
	t.assert(!p.cur.hasheading, "HDM with no variation known: no true heading");
}

testGarminSentences(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("PGRMZ,5500,f,3") :: cs("PGRME,4.5,M,6.0,M,7.5,M") ::
		cs("GPRMC,120000,A,4041.0000,N,07403.0000,W,,,311026,,,A") :: nil);
	f := hd fl;
	t.assertseq(sys->sprint("%.1f", f.baroalt), "1676.4", "PGRMZ: 5500 feet");
	t.assertseq(sys->sprint("%.1f %.1f", f.err, f.verr), "4.5 6.0", "PGRME's errors");
	t.assert(contains(f.text(), " baroalt=1676.4 "), "baroalt in the record: " + f.text());

	feed(p, cs("GPGST,120001,1.0,3.0,2.0,0.0,3.0,4.0,6.5") :: cs("PGRME,9.0,M,9.0,M,9.0,M") :: nil);
	t.assertseq(sys->sprint("%.1f %.1f", p.cur.err, p.cur.verr), "5.0 6.5", "GST's errors preferred to PGRME's");
	feed(p, cs("PGRMZ,500,m,3") :: nil);
	t.assertseq(sys->sprint("%.1f", p.cur.baroalt), "500.0", "PGRMZ in metres");
}

testFlarm(t: ref T)
{
	p := Parser.new();
	feed(p, cs("PFLAA,0,1000,0,100,2,DD1234,90,,30,1.5,1") :: nil);
	t.asserteq(len traffic(p), 0, "FLARM traffic with no fix: not placed");
	feed(p, cs("GPRMC,120000,A,4600.0000,N,00800.0000,E,,,311026,,,A") ::
		cs("GPGGA,120000,4600.0000,N,00800.0000,E,1,08,0.9,1000.0,M,,,,") ::
		cs("PFLAA,0,1113,-773,150,2,DD1234,90,,30,1.5,1") :: nil);
	l := traffic(p);
	t.asserteq(len l, 1, "placed from the fix");
	t.assertseq(hd l, "kind=flarm id=DD1234 lat=46.009998 lon=7.990004 alt=1150 speed=30.0 course=90.0 climb=1.5 cat=glider",
		"1113 m north, 773 m west, 150 m above");
}

testSentences(t: ref T)
{
	f := Fix.new();
	f.date = "2026-10-31";
	f.utc = "07:08:09.50";
	f.valid = f.haspos = 1;
	f.lat = -33.8568;
	f.lon = 151.2153;
	f.hasalt = 1;
	f.altitude = 12.5;
	f.hasspeed = 1;
	f.speed = 5.0;
	f.hascourse = 1;
	f.course = 271.5;
	f.err = 4.0;
	f.verr = 6.0;
	f.hasmagvar = 1;
	f.magvar = 12.4;
	f.hasheading = 1;
	f.heading = 270.0;
	f.hasbaro = 1;
	f.baroalt = 30.48;
	s := nmea->sentences(f);
	(n, l) := sys->tokenize(s, "\r\n");
	t.asserteq(n, 5, "RMC GST GGA HDT PGRMZ: " + s);
	t.assert(contains(s, "\r\n"), "lines end CR LF");
	p := Parser.new();
	out: list of ref Fix;
	for(; l != nil; l = tl l) {
		(fl, err) := p.sentence(hd l);
		if(err != nil)
			t.error("refused: " + hd l + ": " + err);
		for(; fl != nil; fl = tl fl)
			out = hd fl :: out;
	}
	t.asserteq(len out, 1, "one fix back");
	t.assertseq(p.last.text(),
		"time=2026-10-31T07:08:09.50Z lat=-33.856800 lon=151.215300 alt=12.5 baroalt=30.5 speed=5.00 course=271.5 mcourse=259.1 heading=270.0 mheading=257.6 mode=3d q=gps err=4.0 verr=6.0 magvar=12.4",
		"read back as it was written");

	g := Fix.new();
	s = nmea->sentences(g);
	t.assertseq(s, cs("GPRMC,,V,,,,,,,,,,N"), "no fix: an RMC saying so");
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
	run("Ais", testAis);
	run("Magnetic", testMagnetic);
	run("GarminSentences", testGarminSentences);
	run("Flarm", testFlarm);
	run("Sentences", testSentences);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
