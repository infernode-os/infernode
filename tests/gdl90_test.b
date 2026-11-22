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
# And what a sender can do with them (Callsign, GarminHostile, Fuzz).
# A GDL 90 call sign was its eight bytes as they came: with a newline
# among them a craft was two lines of gpsfs's traffic file, the second
# the sender's.  Garmin's track was brought into 0..360 by taking 360
# off until it fitted: thirty nines never did, and gpsfs's reader of
# that source span for ever; a sign in a latitude's degrees or minutes
# made a fix somewhere else.  Random frames and records raise nothing.
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

# a traffic report for an address, with the eight bytes of its call sign
report(addr: int, cs: array of byte): array of byte
{
	m := bytes(N825V);
	m[2] = byte (addr >> 16);
	m[3] = byte (addr >> 8);
	m[4] = byte addr;
	m[19:] = array[8] of {* => byte ' '};
	m[19:] = cs;
	return m;
}

testCallsign(t: ref T)
{
	d := Framer.new();
	p := Parser.new();
	names := array[] of {
		(16rAB0001, array of byte "A\nkind=x", ""),
		(16rAB0002, array of byte "N1'2=3", ""),
		(16rAB0003, array[] of {byte 'A', byte 16rFF, byte 'B'}, ""),
		(16rAB0004, array of byte "n825v", ""),
		(16rAB0005, array of byte "N825V", "N825V"),
		(16rAB0006, array[] of {byte 'B', byte 'A', byte '1', byte '2', byte 0, byte 0, byte 0, byte 0}, "BA12"),
		(16rAB0007, array of byte "AB 12", "AB 12"),
	};
	for(i := 0; i < len names; i++) {
		(addr, cs, want) := names[i];
		(nil, ts) := d.feed(gdl90->frame(report(addr, cs)));
		t.asserteq(len ts, 1, "a report: a target");
		if(ts == nil)
			continue;
		t.assertseq((hd ts).name, want, sys->sprint("the call sign of %.6x", addr));
		p.target(hd ts);
	}
	(n, nil) := sys->tokenize(p.traffic(sys->millisec()), "\n");
	t.asserteq(n, len names, "a line a craft in the traffic file");
}

# An address is one of six kinds; the kind was dropped, so a TIS-B
# track file with an aircraft's 24 bits replaced the aircraft.  The
# report's "extrapolated" bit and its emergency code were dropped too.
testAddress(t: ref T)
{
	d := Framer.new();
	p := Parser.new();
	plane := report(16rAB0001, array of byte "PLANE");
	track := report(16rAB0001, array of byte "TRACK3");
	track[1] = byte (int track[1] & 16rF0 | 3);
	tisb := report(16rAB0001, array of byte "PLANE");
	tisb[1] = byte (int tisb[1] & 16rF0 | 2);
	for(l := plane :: track :: tisb :: nil; l != nil; l = tl l){
		(nil, ts) := d.feed(gdl90->frame(hd l));
		if(ts != nil)
			p.target(hd ts);
	}
	s := p.traffic(sys->millisec());
	(n, nil) := sys->tokenize(s, "\n");
	t.asserteq(n, 2, "an ICAO address and a track file of the same 24 bits are two craft: " + s);
	t.assert(contains(s, "id=ab0001 ") && contains(s, "id=3.ab0001 "), "the track file's id says its kind: " + s);
	t.assert(contains(s, "name=PLANE") && contains(s, "name=TRACK3"), "each keeps its name: " + s);

	m := report(16rAB0009, array of byte "MAYDAY");
	m[12] = byte (int m[12] | 4);
	m[27] = byte 16r10;
	(nil, ts) := d.feed(gdl90->frame(m));
	t.asserteq(len ts, 1, "a report: a target");
	if(ts != nil){
		x := (hd ts).text((hd ts).seen);
		t.assert(contains(x, " extrapolated=1 emergency=general "), "a reckoned position and an emergency are said: " + x);
	}
	(nil, ts) = d.feed(gdl90->frame(report(16rAB000A, array of byte "CALM")));
	if(ts != nil){
		x := (hd ts).text((hd ts).seen);
		t.assert(!contains(x, "extrapolated") && !contains(x, "emergency"), "and not of a craft with neither: " + x);
	}
}

# The heartbeat's word that the GPS position is good was kept for
# ever: one heartbeat, and every own-ship report after was a valid fix.
testHeartbeat(t: ref T)
{
	d := Framer.new();
	heartbeat := bytes(array[] of {16r00, 16r81, 16r41, 16rDB, 16rD0, 16r08, 16r02});
	d.feed(gdl90->frame(heartbeat));
	nvalid := 0;
	fl: list of ref Fix;
	for(i := 0; i < 40; i++){
		(fl, nil) = d.feed(gdl90->frame(ownship()));
		if(fl != nil && (hd fl).valid)
			nvalid++;
	}
	t.asserteq(nvalid, 10, "forty own-ship reports after one heartbeat: the first ten are fixes");
	d.feed(gdl90->frame(heartbeat));
	(fl, nil) = d.feed(gdl90->frame(ownship()));
	t.assert(fl != nil && (hd fl).valid, "a heartbeat again: a fix again");
}

# A group whose ETX was lost and whose successor begins with STX was
# dropped; a record saying "not available" after one that gave a value
# left the value.
testGarminGroups(t: ref T)
{
	g := Grouper.new();
	fl := g.feed(array of byte "\u0002z00100\r\nAN4000.00\r\nBW07400.00\r\n\u0002z00200\r\nAN4100.00\r\nBW07400.00\r\n\u0003");
	t.asserteq(len fl, 2, "two groups, the first's ETX lost, the second begun with STX");
	if(len fl == 2)
		t.assertseq(sys->sprint("%.1f %.1f", (hd fl).lat, (hd tl fl).lat), "40.0 41.0", "each its own");

	g = Grouper.new();
	fl = g.feed(array of byte "\u0002z00100\r\nAN4000.00\r\nBW07400.00\r\nD045\r\nA----------\r\nD---\r\n\u0003");
	t.asserteq(len fl, 1, "a group");
	if(fl != nil){
		t.assert(!(hd fl).valid && !(hd fl).haspos, "a latitude taken back by a later record: no fix");
		t.assert(!(hd fl).hasspeed, "and a speed");
	}
}

# a group fed in a proc of its own: the fixes' text, "raised ...", or
# "hung" if it has not returned in three seconds
garminproc(s: string, done: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	{
		g := Grouper.new();
		r := "";
		for(fl := g.feed(array of byte s); fl != nil; fl = tl fl)
			r += "[" + (hd fl).text() + "] " + nmea->sentences(hd fl);
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

garmin(s: string): string
{
	done := chan[1] of string;
	pidc := chan of int;
	spawn garminproc(s, done, pidc);
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

testGarminHostile(t: ref T)
{
	pos := "\u0002z00673\r\nAN 40 4106\r\nBW 074 2393\r\n";
	r := garmin(pos + "C9999999999999999999999999999999\r\nD045\r\n\u0003");
	t.assert(r != "hung", "a track of thirty-one nines returns");
	t.assert(!contains(r, "raised") && !contains(r, "course="), "and is no course: " + r);
	r = garmin(pos + "C090\r\nQE99999999999999999999999999999\r\n\u0003");
	t.assert(r != "hung", "a variation of twenty-nine nines returns");
	t.assert(contains(r, "course=90.0") && !contains(r, "magvar="), "and is no variation: " + r);
	r = garmin(pos + "C-90\r\nD-45\r\n\u0003");
	t.assert(!contains(r, "course=") && !contains(r, "speed="), "a track and a speed below nothing are none: " + r);
	r = garmin(pos + "C360\r\nQE010\r\n\u0003");
	t.assert(contains(r, "course=1.0 "), "a track of 360 and 1 east is 1: " + r);
	r = garmin(pos + "C005\r\nQW100\r\n\u0003");
	t.assert(contains(r, "course=355.0 "), "a track of 5 and 10 west is 355: " + r);
	r = garmin("\u0002z9999999999999999999999999999999\r\nAN 40 4106\r\nBW 074 2393\r\nD9999999999999999999\r\n\u0003");
	t.assert(!contains(r, "alt=") && !contains(r, "speed="), "an altitude and a speed past any are none: " + r);

	# a sign in the degrees or the minutes
	r = garmin("\u0002z00100\r\nAN-941.06\r\nBW-9955.50\r\n\u0003");
	t.assert(!contains(r, "lat="), "signed degrees are no position: " + r);
	r = garmin("\u0002z00100\r\nAN40-1.06\r\nBW074+3.50\r\n\u0003");
	t.assert(!contains(r, "lat="), "signed minutes are no position: " + r);
}

rstate := 20261116;
rnd(n: int): int
{
	rstate = rstate * 1103515245 + 12345;
	return ((rstate >> 8) & 16r7fffff) % n;
}

fuzzproc(done: chan of string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	what := "";
	{
		d := Framer.new();
		p := Parser.new();
		g := Grouper.new();
		recs := "zABCDQEGIKLSTl";
		for(n := 0; n < 20000; n++) {
			# a frame with a good CRC and a body of any bytes, of any
			# length; sometimes raw bytes with no frame to them
			what = "gdl90";
			m := array[rnd(40)] of byte;
			for(i := 0; i < len m; i++)
				m[i] = byte rnd(256);
			if(len m > 0 && rnd(4) != 0)
				m[0] = byte (array[] of {0, 10, 20})[rnd(3)];
			b := m;
			if(rnd(8) != 0)
				b = gdl90->frame(m);
			(fl, ts) := d.feed(b);
			for(; ts != nil; ts = tl ts)
				p.target(hd ts);
			for(; fl != nil; fl = tl fl) {
				f := hd fl;
				(hd fl).text();
				if(f.haspos && !(f.lat >= -90.0 && f.lat <= 90.0 && f.lon >= -180.0 && f.lon <= 180.0)) {
					done <-= sys->sprint("a GDL 90 position of %g %g", f.lat, f.lon);
					return;
				}
				nmea->sentences(f);
			}
			# a Garmin group of records that are any printable bytes
			what = "garmin";
			s := "\u0002";
			for(k := rnd(8); k > 0; k--) {
				s[len s] = recs[rnd(len recs)];
				for(j := rnd(34); j > 0; j--)
					case rnd(6) {
					0 =>
						s[len s] = ' ' + rnd(95);
					1 =>
						s[len s] = "NSEW-+. "[rnd(8)];
					* =>
						s[len s] = '0' + rnd(10);
					}
				s += "\r\n";
			}
			if(rnd(4) != 0)
				s[len s] = 16r03;
			for(fl = g.feed(array of byte s); fl != nil; fl = tl fl) {
				f := hd fl;
				f.text();
				if(f.haspos && !(f.lat >= -90.0 && f.lat <= 90.0 && f.lon >= -180.0 && f.lon <= 180.0) ||
				   f.hascourse && !(f.course >= 0.0 && f.course < 360.0)) {
					done <-= sys->sprint("a Garmin fix of %s from %s", f.text(), s);
					return;
				}
				nmea->sentences(f);
			}
		}
		tr := p.traffic(sys->millisec());
		(ntr, nil) := sys->tokenize(tr, "\n");
		if(ntr != len p.targets) {
			done <-= sys->sprint("%d targets are %d lines", len p.targets, ntr);
			return;
		}
		done <-= nil;
	} exception e {
	"*" =>
		done <-= "raised " + e + " in " + what;
	}
}

testFuzz(t: ref T)
{
	done := chan[1] of string;
	pidc := chan of int;
	spawn fuzzproc(done, pidc);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, 60000);
	alt {
	r := <-done =>
		t.assertnil(r, "20000 random frames and groups");
	<-tc =>
		killproc(pid);
		t.fatal("a frame or a group never returned");
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
	run("Callsign", testCallsign);
	run("Address", testAddress);
	run("Heartbeat", testHeartbeat);
	run("GarminGroups", testGarminGroups);
	run("GarminHostile", testGarminHostile);
	run("Fuzz", testFuzz);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
