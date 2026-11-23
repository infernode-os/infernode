implement NmeaTest;

#
# nmea(2): sentences framed and checked, positions and times read,
# a receiver's burst of sentences for one time assembled into one fix,
# satellites in view and used, error estimates, sentences that are
# short or garbled taken without harm.
#
# And sentences written to do harm (Hostile, Tables, Names, Fuzz).  A
# sentence is a wire's bytes, from anyone where gpsfs listens to UDP,
# and gpsfs's one server proc runs this parser:
#   - an AIS sentence saying it was part 1 of 200000000 sized the array
#     its parts are kept in: 1.6GB asked of the heap, and the exception
#     ended the server;
#   - an angle was brought into 0..360 by taking 360 off until it
#     fitted: a heading of 1e13 or more (HDT, HDG, HDM, FLARM's track,
#     an RMC course with a variation) never returned;
#   - 9999 degrees north was a fix;
#   - the satellites used grew by twelve with every GSA when no position
#     sentence came, a GSV report whose first sentence never came grew
#     without end, the eight oldest AIS messages in parts shut out the
#     newest, a thousand ships took every aircraft off the list;
#   - a target's name with a newline in it was two lines of traffic.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "nmea.m";
	nmea: Nmea;
	Fix, Parser, Target: import nmea;

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

testGlitch(t: ref T)
{
	p := Parser.new();
	fl := feed(p, cs("GPRMC,120000,A,5130.0000,N,00007.0000,W,,,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "a fix");
	# a position 5 degrees off for a second: held back
	fl = feed(p, cs("GPRMC,120001,A,5630.0000,N,00007.0000,W,,,311026,,,A") ::
		cs("GPRMC,120002,A,5130.0010,N,00007.0000,W,,,311026,,,A") :: nil);
	t.asserteq(len fl, 1, "the glitch held back, the next given");
	t.assertseq((hd fl).utc, "12:00:02", "the one after it");
	t.asserteq(p.suspects, 1, "and counted");
	# a receiver really moved: believed at the fourth
	fl = feed(p, cs("GPRMC,120003,A,4000.0000,N,07400.0000,W,,,311026,,,A") ::
		cs("GPRMC,120004,A,4000.0010,N,07400.0000,W,,,311026,,,A") ::
		cs("GPRMC,120005,A,4000.0020,N,07400.0000,W,,,311026,,,A") ::
		cs("GPRMC,120006,A,4000.0030,N,07400.0000,W,,,311026,,,A") ::
		cs("GPRMC,120007,A,4000.0040,N,07400.0000,W,,,311026,,,A") :: nil);
	t.asserteq(len fl, 2, "three held back, then believed");
	t.assertseq((hd fl).utc, "12:00:06", "from the fourth");
	t.assertseq(p.last.position(), "40.000067 -74.000000", "the last fix the new place");
	# across the date line is not far
	p = Parser.new();
	fl = feed(p, cs("GPRMC,120000,A,1000.0000,S,17959.9000,E,,,311026,,,A") ::
		cs("GPRMC,120001,A,1000.0000,S,17959.9000,W,,,311026,,,A") :: nil);
	t.asserteq(len fl, 2, "a step across the date line is believed");
}

#
# Sentences written to do harm
#

zeros(n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s += "0";
	return s;
}

GOOD: con "$GPRMC,120000,A,4047.0400,N,07425.0000,W,0.0,0.0,311026,003.1,W,A";

# pre then s parsed in a proc of its own; what the fix then says, or
# "raised ..."
hostileproc(pre: list of string, s: string, done: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	{
		p := Parser.new();
		for(; pre != nil; pre = tl pre)
			p.sentence(hd pre);
		p.sentence(s);
		r := p.cur.text() + " | " + nmea->sentences(p.cur) + " | " + p.traffic(sys->millisec());
		if(p.aispend != nil)
			r += " | parts kept";
		done <-= r;
	} exception e {
	"*" =>
		done <-= "raised " + e;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

killproc(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# the result, or "hung" if it has not come in three seconds
hostile(pre: list of string, s: string): string
{
	done := chan[1] of string;
	pidc := chan of int;
	spawn hostileproc(pre, s, done, pidc);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 3000);
	alt {
	r := <-done =>
		return r;
	<-tc =>
		killproc(pid);
		return "hung";
	}
}

testHostile(t: ref T)
{
	# a count that sizes an array
	r := hostile(nil, "!AIVDM,200000000,1,0,A,0,0");
	t.assert(!contains(r, "raised") && r != "hung", "an AIS part 1 of 200000000: " + r);
	t.assert(!contains(r, "parts kept"), "and nothing is kept for it");
	r = hostile(nil, "!AIVDM,99999999999999999999,1,0,A,0,0");
	t.assert(!contains(r, "raised") && r != "hung", "an AIS part 1 of 1e20: " + r);

	# angles
	h := array[] of {
		("HDT 1e20", "$GPHDT,1" + zeros(20) + ",T"),
		("HDT 1e13", "$GPHDT,1" + zeros(13) + ",T"),
		("HDT -1e20", "$GPHDT,-1" + zeros(20) + ",T"),
		("HDT 1e8", "$GPHDT,1" + zeros(8) + ",T"),
		("HDG 1e20", "$HCHDG,1" + zeros(20) + ",,,,"),
		("HDM 1e20", "$HCHDM,1" + zeros(20) + ",M"),
		("FLARM's track 1e20", "$PFLAA,0,100,100,10,2,DD8F12,1" + zeros(20) + ",,30,-1.4,1"),
		("an RMC course of 1e20", "$GPRMC,120001,A,4047.0400,N,07425.0000,W,0.0,1" + zeros(20) + ",311026,003.1,W,A"),
		("an RMC variation of 1e20", "$GPRMC,120001,A,4047.0400,N,07425.0000,W,0.0,90.0,311026,1" + zeros(20) + ",W,A"),
	};
	for(i := 0; i < len h; i++) {
		(name, sent) := h[i];
		r = hostile(GOOD :: nil, sent);
		t.assert(r != "hung", name + " returns");
		t.assert(!contains(r, "raised"), name + ": " + r);
		t.assert(!contains(r, "heading=") && !contains(r, "course=1") && !contains(r, "magvar=1"),
			name + " is no heading, course or variation: " + r);
	}

	r = hostile(GOOD :: nil, "$HCHDG,10.0,1" + zeros(20) + ",E,,");
	t.assert(contains(r, " heading=6.9 "), "a deviation of 1e20 is none, and the heading is read without it: " + r);

	# numbers past what an int or a field holds
	n := array[] of {
		"$GPGGA,120001,4047.0400,N,07425.0000,W,1,9" + zeros(30) + ",1.0,10,M,,M,,",
		"$GPGGA,120001,4047.0400,N,07425.0000,W,1,09,1.0,1" + zeros(309) + ",M,,M,,",
		"$PGRMZ,1" + zeros(309) + ",f,3",
		"$PGRMZ,999999999,m,3",
		"$GPVTG,1" + zeros(309) + ",T,,M,1" + zeros(309) + ",N,1" + zeros(309) + ",K,A",
		"$GPZDA,120000,1" + zeros(309) + ",10,2026,00,00",
		"$GPGSV,1,1,01,1" + zeros(309) + ",10,100,30",
		"$GPGSV,999999999,1,01,01,10,100,30",
		"$GPGSA,A,3,999999999,,,,,,,,,,,,1" + zeros(40) + ",1.0,1.0",
		"$GPGST,120001,,,,,1" + zeros(200) + ",1" + zeros(200) + ",1" + zeros(200),
		"$PGRME,1" + zeros(200) + ",M,1" + zeros(200) + ",M,,M",
		"$PFLAA,0,1" + zeros(60) + ",1" + zeros(60) + ",1" + zeros(60) + ",2,DD8F12,90,,1" + zeros(60) + ",1" + zeros(60) + ",1",
		"!AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,99999",
	};
	for(i = 0; i < len n; i++) {
		r = hostile(GOOD :: nil, n[i]);
		t.assert(r != "hung" && !contains(r, "raised"), sys->sprint("%.40s...: %.80s", n[i], r));
		t.assert(!contains(r, "nfinity") && !contains(r, "NaN") && !contains(r, "e+"),
			sys->sprint("%.40s... leaves no number that is none: %.200s", n[i], r));
	}

	# a position that is nowhere
	p := Parser.new();
	fl := feed(p, cs("GPRMC,120001,A,999959.0000,N,07425.0000,W,,,311026,,,A") :: nil);
	t.assert(fl == nil || (hd fl).position() == nil, "9999 degrees north is no position");
	p = Parser.new();
	fl = feed(p, cs("GPGGA,120001,4047.0400,N,18100.0000,E,1,09,1.0,10.0,M,,M,,") :: nil);
	t.assert(fl == nil || (hd fl).position() == nil, "181 degrees east is no position");
	p = Parser.new();
	fl = feed(p, cs("GPRMC,120001,A,9000.0000,S,18000.0000,W,,,311026,,,A") :: nil);
	t.assert(fl != nil && (hd fl).position() == "-90.000000 -180.000000", "the pole and the date line are");
	p = Parser.new();
	feed(p, GOOD :: cs("PFLAA,0,20000000,0,10,2,DD8F12,90,,30,1.0,1") :: nil);
	t.asserteq(len traffic(p), 0, "an aircraft 20000 km north of 40 north is nowhere");

	# what is in range is still read, and turned
	p = Parser.new();
	feed(p, cs("GPRMC,120001,A,4047.0400,N,07425.0000,W,5.0,360.0,311026,010.0,W,A") :: cs("GPHDT,359.5,T") :: nil);
	t.assert(p.cur.hascourse && near(p.cur.course, 0.0), "a course of 360 is 0");
	t.assert(p.cur.hasheading && near(p.cur.heading, 359.5), "a heading of 359.5");
	t.assert(contains(p.cur.text(), "mcourse=10.0") && contains(p.cur.text(), "mheading=9.5"),
		"magnetic from true, across north: " + p.cur.text());
	p = Parser.new();
	feed(p, cs("HCHDG,355.0,10.0,E,10.0,E") :: nil);
	t.assert(p.cur.hasheading && near(p.cur.heading, 15.0), "355 and 10 and 10 east is 15");
}

listlen(l: list of (string, int)): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

# an AIS position report (message 1) for an mmsi, at 1 north 1 east
aispayload(mmsi: int): string
{
	bits := array[168] of {* => 0};
	put(bits, 0, 6, 1);
	put(bits, 8, 30, mmsi);
	put(bits, 61, 28, 600000);
	put(bits, 89, 27, 600000);
	s := "";
	for(i := 0; i < 168; i += 6) {
		v := 0;
		for(j := 0; j < 6; j++)
			v = v<<1 | bits[i+j];
		c := v + 48;
		if(c > 87)
			c += 8;
		s[len s] = c;
	}
	return s;
}

put(b: array of int, start, n, v: int)
{
	for(i := 0; i < n; i++)
		b[start+i] = (v >> (n-1-i)) & 1;
}

testTables(t: ref T)
{
	# satellites used, with no position sentence to begin a new time
	p := Parser.new();
	for(i := 0; i < 5000; i++)
		p.sentence("$GPGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,1.0,1.0,1.0");
	t.assert(listlen(p.used) <= 256, sys->sprint("5000 GSA with no position: %d satellites used kept", listlen(p.used)));

	# a GSV report whose first sentence never comes
	for(i = 0; i < 5000; i++)
		p.sentence("$GPGSV,9,2,36,01,10,100,30,02,10,100,30,03,10,100,30,04,10,100,30");
	n := 0;
	for(i = 0; i < len p.pending; i++)
		n += len p.pending[i];
	t.assert(n <= 36, sys->sprint("5000 second sentences of a GSV report: %d satellites pending", n));
	(nil, err) := p.sentence("$GPGSV,10,1,40,01,10,100,30");
	t.assertnil(err, "a GSV report of ten sentences is a sentence");
	t.assertseq(p.satellites(), "", "and no report: none in view");

	# the newest AIS messages in parts are the ones kept
	part1 := "55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8";
	p = Parser.new();
	for(i = 0; i < 8; i++)
		p.sentence(sys->sprint("!AIVDM,2,1,%d,A,%s,0", i, part1));
	p.sentence("!AIVDM,2,1,8,A," + part1 + ",0");
	p.sentence("!AIVDM,2,1,9,B," + part1 + ",0");
	p.sentence("!AIVDM,2,2,8,A,88888888880,2");
	t.asserteq(len p.targets, 1, "a message in two parts behind eight whose second never came, and one between");
	t.assert(len p.aispend <= 8, sys->sprint("%d messages kept in parts", len p.aispend));
	for(i = 0; i < 200; i++)
		p.sentence(sys->sprint("!AIVDM,9,1,%d,%c,%s,0", i%10, 'A' + i%26, part1));
	t.assert(len p.aispend <= 8, sys->sprint("%d messages kept in parts after 200 first parts", len p.aispend));
	(nil, err) = p.sentence("!AIVDM,2,1,333,ABC," + part1 + ",0");
	t.assertnil(err, "a sequence number of three digits is a sentence");
	for(l := p.aispend; l != nil; l = tl l)
		t.assert(!contains((hd l).t0, "333"), "and no message");

	# a thousand ships do not take the aircraft off the list
	p = Parser.new();
	feed(p, cs("GPRMC,120000,A,0100.0000,N,00100.0000,E,0.0,0.0,311026,,,A") ::
		cs("PFLAA,0,100,100,10,2,DD8F12,180,,30,-1.4,1") :: nil);
	t0 := sys->millisec();
	for(i = 1; i <= 1300; i++)
		p.sentence("!AIVDM,1,1,,A," + aispayload(200000000 + i) + ",0");
	ms := sys->millisec() - t0;
	nais := 0;
	nflarm := 0;
	newest := 0;
	for(tl0 := p.targets; tl0 != nil; tl0 = tl tl0) {
		if((hd tl0).kind == "flarm")
			nflarm++;
		else
			nais++;
		if((hd tl0).id == "200001300")
			newest = 1;
	}
	t.asserteq(nflarm, 1, "the aircraft is still heard after 1300 ships");
	t.asserteq(nais, 1000, "a thousand ships are kept");
	t.assert(newest, "the last heard among them");
	t.log(sys->sprint("1300 ships: %d ms", ms));
}

testNames(t: ref T)
{
	p := Parser.new();
	x := Target.new("adsb", "abcdef");
	x.name = "A\nkind=x";
	p.target(x);
	x = Target.new("adsb", "abc\ndef");
	p.target(x);
	x = Target.new("adsb", "123456");
	x.name = "N825V";
	x.callsign = "\u007f";
	x.category = "light\r";
	p.target(x);
	x = Target.new("adsb", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	p.target(x);
	p.target(nil);
	l := traffic(p);
	t.asserteq(len l, 2, "two craft are two lines: " + p.traffic(sys->millisec()));
	for(; l != nil; l = tl l)
		t.assert(hd l == "kind=adsb id=abcdef" || hd l == "kind=adsb id=123456 name=N825V", "a line: " + hd l);

	# FLARM's id is the sentence's: blanks and quotes are quoted
	p = Parser.new();
	feed(p, cs("GPRMC,120000,A,4600.0000,N,00800.0000,E,,,311026,,,A") ::
		cs("PFLAA,0,1113,-773,150,2,DD 12'34,90,,30,1.5,1") :: nil);
	l = traffic(p);
	t.assert(len l == 1 && contains(hd l, "id='DD 12''34' "), "an id with a blank and a quote: " + p.traffic(sys->millisec()));
	(n, toks) := sys->tokenize(hd l, " ");
	t.assert(n > 3, "tokenized");
	toks = nil;
}

#
# Mutated sentences of every kind, as many as there is time for.  None
# may raise or go on for ever, and what the parser keeps stays within
# its bounds.
#
seeds := array[] of {
	"GPRMC,120000,A,4047.0400,N,07425.0000,W,5.5,84.4,311026,003.1,W,A",
	"GPGGA,120000,4047.0400,N,07425.0000,W,1,08,0.9,545.4,M,46.9,M,,",
	"GPGLL,4047.0400,N,07425.0000,W,120000,A,A",
	"GPGSA,A,3,04,05,,09,12,,,24,,,,,2.5,1.3,2.1",
	"GNGSA,A,3,65,66,67,,,,,,,,,,2.5,1.3,2.1,2",
	"GPGSV,2,1,08,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45",
	"GPGSV,2,2,08,15,12,111,30,17,60,200,44,19,05,010,,24,33,150,40",
	"GPGST,120000,0.006,0.023,0.020,273.6,0.023,0.020,0.031",
	"GPVTG,84.4,T,87.5,M,5.5,N,10.2,K,A",
	"GPZDA,120000,31,10,2026,00,00",
	"GPHDT,274.07,T",
	"HCHDG,98.3,0.0,E,12.6,W",
	"HCHDM,238.5,M",
	"PGRMZ,2062,f,3",
	"PGRME,15.0,M,22.5,M,27.0,M",
	"PFLAA,0,-1234,1234,220,2,DD8F12,180,,30,-1.4,1",
	"AIVDM,1,1,,A,13aEOK?P00PD2wVMdLDRhgvL289?,0",
	"AIVDM,2,1,3,A,539Lg000Bm`L@48<000mJ0EP4m0hD0000000001600000000000000000000,0",
	"AIVDM,2,2,3,A,00000000000,2",
	"AIVDM,1,1,,A,B52MJh00=nc@lJ5lQE1hQIP00000,0",
	"AIVDM,1,1,,A,H52MJh1<D6098DE`D00000000000,0",
	"AIVDM,1,1,,A,C52ulL@0AVcCF85lWb0p@eP0@2T4NU0`b>0000000000J0000000,0",
};

# what a field is replaced with
poison: array of string;

rstate := 20261116;
rnd(n: int): int
{
	rstate = rstate * 1103515245 + 12345;
	return ((rstate >> 8) & 16r7fffff) % n;
}

mkpoison()
{
	poison = array[] of {
		"", "0", "1", "-1", "9", "10", "360", "360.01", "-0.1", "1e9", "1.5e300",
		"255", "256", "32768", "65536", "2147483647", "2147483648", "-2147483648",
		"4294967295", "4294967296", "999999999", "9999999999", "200000000",
		"1" + zeros(13), "1" + zeros(17), "1" + zeros(20), "-1" + zeros(20), "1" + zeros(40),
		"1" + zeros(310), "0." + zeros(300) + "1", "9999.99", "99999.9999", "18000.0000", "9000.0000",
		".", "-", "+", "..", "1.2.3", "--1", "A", "V", "N", "S", "E", "W", "T", "M", "f", "K",
		"*", "*00", "$", "!", ",", ",,,,,,,,,,,,,,,,,,,,", " ", "'", "=", "\t", "\n", "\u0000", "\u00e9", "\u20ac",
		"250000", "126060.999", "320026", "000000", "311026", "@@@@@@@@", "~~~~~~~~", "wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
	};
}

mutate(s: string): string
{
	nf := 1;
	for(i := 0; i < len s; i++)
		if(s[i] == ',')
			nf++;
	f := array[nf] of string;
	k := 0;
	st := 0;
	for(i = 0; i <= len s; i++)
		if(i == len s || s[i] == ',') {
			f[k++] = s[st:i];
			st = i+1;
		}
	for(times := 1 + rnd(3); times > 0; times--)
		case rnd(9) {
		0 or 1 or 2 or 3 =>
			f[rnd(nf)] = poison[rnd(len poison)];
		4 =>
			# a character changed
			j := rnd(nf);
			if(len f[j] > 0)
				f[j][rnd(len f[j])] = ' ' + rnd(95);
		5 =>
			# a field gone, the rest moved up
			j := rnd(nf);
			for(; j+1 < nf; j++)
				f[j] = f[j+1];
			f[nf-1] = "";
		6 =>
			# two fields changed places
			a := rnd(nf);
			b := rnd(nf);
			(f[a], f[b]) = (f[b], f[a]);
		7 =>
			# a field's digits made many
			j := rnd(nf);
			f[j] += f[j] + f[j];
		8 =>
			# cut short
			nf = 1 + rnd(nf);
		}
	r := f[0];
	for(i = 1; i < nf; i++)
		r += "," + f[i];
	return r;
}

# the parser's own bounds, or what is past them
bounds(p: ref Parser): string
{
	if(listlen(p.used) > 256)
		return sys->sprint("%d satellites used", listlen(p.used));
	for(i := 0; i < len p.pending; i++)
		if(len p.pending[i] > 36 || len p.inview[i] > 36)
			return sys->sprint("%d satellites pending, %d in view", len p.pending[i], len p.inview[i]);
	if(len p.aispend > 8)
		return sys->sprint("%d AIS messages in parts", len p.aispend);
	for(q := p.aispend; q != nil; q = tl q)
		if(len (hd q).t1 > 9)
			return sys->sprint("an AIS message of %d parts", len (hd q).t1);
	if(len p.targets > 2000)
		return sys->sprint("%d targets", len p.targets);
	for(l := p.cur :: p.last :: nil; l != nil; l = tl l) {
		f := hd l;
		if(f == nil)
			continue;
		if(f.haspos && !(f.lat >= -90.0 && f.lat <= 90.0 && f.lon >= -180.0 && f.lon <= 180.0))
			return sys->sprint("a position of %g %g", f.lat, f.lon);
		if(f.hascourse && !(f.course >= 0.0 && f.course < 360.0))
			return sys->sprint("a course of %g", f.course);
		if(f.hasheading && !(f.heading >= 0.0 && f.heading < 360.0))
			return sys->sprint("a heading of %g", f.heading);
		if(f.hasmagvar && !(f.magvar >= -180.0 && f.magvar <= 180.0))
			return sys->sprint("a variation of %g", f.magvar);
	}
	return nil;
}

Fuzzn: con 300000;
Fuzzms: con 20000;	# the interpreter does fewer in its time

fuzzproc(done: chan of string, pidc: chan of int, count: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	last := "";
	n := 0;
	{
		p := Parser.new();
		t0 := sys->millisec();
		for(n = 0; n < Fuzzn; n++) {
			last = mutate(seeds[rnd(len seeds)]);
			if(last != nil && last[0] == 'A')
				last = "!" + last;
			else
				last = "$" + last;
			p.sentence(last);
			if(n % 64 == 0) {
				if((e := bounds(p)) != nil) {
					done <-= sys->sprint("%s after the %dth: %s", e, n, last);
					return;
				}
				nmea->timeof(last);
				p.cur.text();
				if(p.last != nil) {
					p.last.text();
					nmea->sentences(p.last);
				}
				nmea->sentences(p.cur);
				tr := p.traffic(sys->millisec());
				(ntr, nil) := sys->tokenize(tr, "\n");
				if(ntr != len p.targets) {
					done <-= sys->sprint("%d targets are %d lines after %s", len p.targets, ntr, last);
					return;
				}
				p.satellites();
				count <-= n;
				if(sys->millisec() - t0 > Fuzzms)
					break;
			}
			if(n % 4096 == 4095)
				p.forget();
		}
		count <-= n;
		done <-= nil;
	} exception e {
	"*" =>
		done <-= sys->sprint("raised %s at the %dth: %s", e, n, last);
	}
}

# What is sent beside a position (a compass's heading, a pressure
# altitude, an error estimate) is in the fix while it is being sent:
# each was copied from one time to the next for ever, so a compass
# unplugged left its last heading in every fix after.
rmcat(hms: string): string
{
	return cs("GPRMC," + hms + ",A,4041.0000,N,07403.0000,W,10.0,90.0,311026,12.9,W,A");
}

testStale(t: ref T)
{
	p := Parser.new();
	feed(p, rmcat("120000") :: cs("HEHDT,45.5,T") :: cs("PGRMZ,1000,f,3") :: cs("PGRME,5.0,M,7.0,M,9.0,M") :: nil);
	feed(p, rmcat("120001") :: rmcat("120002") :: rmcat("120003") :: rmcat("120004") :: rmcat("120005") :: nil);
	s := p.last.text();
	t.assert(contains(s, " heading=45.5") && contains(s, " baroalt=304.8") && contains(s, " err=5.0"),
		"five seconds on, the heading, pressure altitude and error are still the fix's: " + s);
	feed(p, rmcat("120008") :: rmcat("120011") :: rmcat("120015") :: nil);
	s = p.last.text();
	t.assert(!contains(s, "heading="), "a heading not heard for fifteen seconds is gone: " + s);
	t.assert(!contains(s, "baroalt="), "and a pressure altitude: " + s);
	t.assert(!contains(s, " err=") && !contains(s, "verr="), "and an error: " + s);
	t.assert(contains(s, " course=90.0"), "what the position sentence says is there: " + s);
	feed(p, cs("HEHDT,50.0,T") :: rmcat("120016") :: nil);
	t.assert(contains(p.last.text(), " heading=50.0"), "heard again, it is back: " + p.last.text());

	# heard each second, it stays; and across midnight
	p = Parser.new();
	feed(p, rmcat("235950") :: cs("HEHDT,10.0,T") :: rmcat("235955") :: cs("HEHDT,11.0,T") :: rmcat("000001") :: rmcat("000004") :: nil);
	t.assert(contains(p.last.text(), " heading=11.0"), "nine seconds across midnight: still there: " + p.last.text());
	feed(p, rmcat("000030") :: nil);
	t.assert(!contains(p.last.text(), "heading="), "thirty-five seconds across midnight: gone: " + p.last.text());
}

# GGA's fix quality: a fix is one of the qualities there are.  Anything
# but 0 or nothing was taken for one.
testQuality(t: ref T)
{
	for(q := array[] of {"9", "A", "-1", "10", "0", ""}; len q > 0; q = q[1:]){
		p := Parser.new();
		feed(p, cs("GPGGA,120000,4041.0000,N,07403.0000,W," + q[0] + ",08,0.9,10.0,M,-34.0,M,,") :: nil);
		t.assert(!p.cur.valid, "GGA quality \"" + q[0] + "\" is no fix");
	}
	for(g := array[] of {("1", "gps"), ("2", "dgps"), ("4", "rtk"), ("6", "dr")}; len g > 0; g = g[1:]){
		p := Parser.new();
		feed(p, cs("GPGGA,120000,4041.0000,N,07403.0000,W," + g[0].t0 + ",08,0.9,10.0,M,-34.0,M,,") :: nil);
		t.assert(p.cur.valid && p.cur.quality == g[0].t1, "GGA quality " + g[0].t0 + " is a fix, " + g[0].t1);
	}
}

testFuzz(t: ref T)
{
	mkpoison();
	done := chan[1] of string;
	pidc := chan of int;
	count := chan[4] of int;
	spawn fuzzproc(done, pidc, count);
	pid := <-pidc;
	n := 0;
	seen := -1;
	tc := chan[1] of int;
	spawn timer(tc, 5000);
	for(;;) alt {
	n = <-count =>
		;
	r := <-done =>
		t.assertnil(r, "mutated sentences");
		t.assert(n >= 20000, sys->sprint("%d sentences tried", n));
		t.log(sys->sprint("%d mutated sentences", n));
		return;
	<-tc =>
		if(n == seen) {
			killproc(pid);
			t.fatal(sys->sprint("a sentence after the %dth never returned", n));
		}
		seen = n;
		spawn timer(tc, 5000);
	}
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
	run("Glitch", testGlitch);
	run("Hostile", testHostile);
	run("Tables", testTables);
	run("Names", testNames);
	run("Stale", testStale);
	run("Quality", testQuality);
	run("Fuzz", testFuzz);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
