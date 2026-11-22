implement Nmea;

#
# NMEA 0183 sentences assembled into fixes, for gpsfs(4).
#
# A receiver sends a burst of sentences for each time it computes a
# position: RMC (position, speed, course, date), GGA (position,
# altitude, quality, satellites used), GLL (position), GSA (mode,
# dilutions, which satellites are used), GSV (satellites in view),
# GST (error estimates), VTG (course and speed), ZDA (date).  Which of
# them it sends, and in what order, differ by receiver, so a fix is
# complete when every kind of position sentence the receiver has been
# seen to send has arrived for one time; a sentence for a new time
# completes the old one if one never came.  No timer is needed, and a
# fix is given out as soon as the receiver has said all it will say.
#
# Sentences from every constellation's talker (GP, GL, GA, GB, BD, GQ,
# GI, GN), and from a ship's integrated instruments (II, IN, EC), are
# taken alike.
#
# Beside the position, what aviation and marine receivers add: the
# magnetic variation (RMC), the heading from a compass (HDT, HDG, HDM),
# Garmin's pressure altitude and error estimates (PGRMZ, PGRME), and
# traffic: ships by AIS (!AIVDM: messages 1, 2, 3, 5, 18, 19 and 24)
# and aircraft by FLARM (PFLAA, placed from this fix).  Other
# sentences are taken and passed over.
#
# sentences() goes the other way: a fix from a receiver that does not
# speak NMEA (gdl90(2), garminav(2), a phone's) written as NMEA, so
# gpsfs(4) has one parser and its nmea file one language.
#

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "nmea.m";

Krmc, Kgga, Kgll: con 1<<iota;

# the systems a satellite can belong to, in the order they are listed
systems := array[] of {"gps", "sbas", "glonass", "galileo", "beidou", "qzss", "navic", "gnss"};

Knot: con 1852.0 / 3600.0;	# metres a second
Foot: con 0.3048;	# metres
M: con 111320.0;	# metres a degree of latitude, near enough

#
# What a sentence may say.  A sentence is bytes from a wire (a serial
# line, a datagram from anyone, a log), so every number in one is held
# to what its field can mean before it is used: a count before it sizes
# anything, an angle before it is turned, a table before it grows.
#
Maxwhole: con 9;	# digits before a number's point: it fits an int
Maxnum: con 24;	# characters in a number
Maxalt: con 1.0e7;	# metres, either way
Maxspeed: con 1.0e5;	# knots (or km/h)
Maxerr: con 1.0e6;	# metres of error, or a dilution
Maxprn: con 999;
Maxused: con 256;	# satellites used, all systems
Maxgsv: con 9;	# sentences in one GSV report; four satellites each
Maxvdm: con 9;	# sentences in one AIS message
Maxaispend: con 8;	# AIS messages in parts at once
Aishold: con 60*1000;	# ms a part waits for the rest
Maxid: con 32;	# a target's id
Maxname: con 64;	# a target's name, call sign, category

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

Fix.new(): ref Fix
{
	return ref Fix(nil, nil, 0, 0, 0.0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, -1, nil, -1,
		-1.0, -1.0, -1.0, -1.0, -1.0, 0, 0.0, 0, 0.0, 0, 0.0);
}

Fix.copy(f: self ref Fix): ref Fix
{
	n := ref *f;
	return n;
}

Fix.time(f: self ref Fix): string
{
	if(f.date == nil || f.utc == nil)
		return nil;
	return f.date + "T" + f.utc + "Z";
}

Fix.position(f: self ref Fix): string
{
	if(!f.valid || !f.haspos)
		return nil;
	return sys->sprint("%.6f %.6f", f.lat, f.lon);
}

# the mode the receiver gave, or one inferred from what it sent
Fix.fixmode(f: self ref Fix): int
{
	if(!f.valid || !f.haspos)
		return Mnone;
	if(f.mode == M2d || f.mode == M3d)
		return f.mode;
	if(f.hasalt)
		return M3d;
	return M2d;
}

Fix.text(f: self ref Fix): string
{
	s := "";
	if((t := f.time()) != nil)
		s += " time=" + t;
	if(f.valid && f.haspos)
		s += sys->sprint(" lat=%.6f lon=%.6f", f.lat, f.lon);
	if(f.valid && f.hasalt)
		s += sys->sprint(" alt=%.1f", f.altitude);
	if(f.hasbaro)
		s += sys->sprint(" baroalt=%.1f", f.baroalt);
	if(f.valid && f.hasspeed)
		s += sys->sprint(" speed=%.2f", f.speed);
	if(f.valid && f.hascourse) {
		s += sys->sprint(" course=%.1f", f.course);
		if(f.hasmagvar)
			s += sys->sprint(" mcourse=%.1f", degrees(f.course - f.magvar));
	}
	if(f.hasheading) {
		s += sys->sprint(" heading=%.1f", f.heading);
		if(f.hasmagvar)
			s += sys->sprint(" mheading=%.1f", degrees(f.heading - f.magvar));
	}
	case f.fixmode() {
	Mnone =>
		s += " mode=none";
	M2d =>
		s += " mode=2d";
	M3d =>
		s += " mode=3d";
	}
	if(f.valid && f.quality != nil)
		s += " q=" + f.quality;
	if(f.sats >= 0)
		s += sys->sprint(" sats=%d", f.sats);
	if(f.hdop >= 0.0)
		s += sys->sprint(" hdop=%.1f", f.hdop);
	if(f.vdop >= 0.0)
		s += sys->sprint(" vdop=%.1f", f.vdop);
	if(f.pdop >= 0.0)
		s += sys->sprint(" pdop=%.1f", f.pdop);
	if(f.err >= 0.0)
		s += sys->sprint(" err=%.1f", f.err);
	if(f.verr >= 0.0)
		s += sys->sprint(" verr=%.1f", f.verr);
	if(f.hasmagvar)
		s += sys->sprint(" magvar=%.1f", f.magvar);
	return s[1:];
}

Parser.new(): ref Parser
{
	return ref Parser(Fix.new(), nil, 0, nil, 0, 0, 0, -1,
		array[len systems] of list of ref Sat,
		array[len systems] of list of ref Sat,
		nil, -1, 0, nil, nil, 0, 0.0, 0.0, 0, 0, -1, -1, -1);
}

Parser.forget(p: self ref Parser)
{
	p.cur = Fix.new();
	p.epoch = 0;
	p.curtime = nil;
	p.got = p.kinds = 0;
	p.done = 0;
	p.pending = array[len systems] of list of ref Sat;
	p.inview = array[len systems] of list of ref Sat;
	p.used = nil;
	p.usedepoch = -1;
	p.gstseen = 0;
	p.targets = nil;
	p.aispend = nil;
	p.hasgood = 0;
	p.suspect = 0;
	p.headat = p.baroat = p.errat = -1;
}

# What a receiver sends beside its position (a compass's heading, a
# pressure altitude, an error estimate) is in the fix while it is
# still being sent.  Each was kept from one time to the next for ever:
# a compass unplugged, its last heading went on in every fix.  One not
# heard for Stale seconds of the receiver's own time is gone.
Stale: con 10;

# a time as utc() gives it, in seconds of the day, or -1
second(t: string): int
{
	if(len t < 8)
		return -1;
	return int t[0:2] * 3600 + int t[3:5] * 60 + int t[6:8];
}

# whether what was heard at second `at` is stale at `now`; at -1 is
# heard now (it came before any time did)
stale(now, at: int): (int, int)
{
	if(at < 0)
		return (0, now);
	d := (now - at + 86400) % 86400;
	return (d > Stale && d < 86400 - Stale, at);
}

age(p: ref Parser, t: string)
{
	now := second(t);
	if(now < 0)
		return;
	f := p.cur;
	gone: int;
	if(f.hasheading){
		(gone, p.headat) = stale(now, p.headat);
		if(gone)
			f.hasheading = 0;
	}
	if(f.hasbaro){
		(gone, p.baroat) = stale(now, p.baroat);
		if(gone)
			f.hasbaro = 0;
	}
	if(f.err >= 0.0 || f.verr >= 0.0){
		(gone, p.errat) = stale(now, p.errat);
		if(gone){
			f.err = f.verr = -1.0;
			p.gstseen = 0;
		}
	}
}

# an angle into 0 <= a < 360.  By division: it was by subtracting 360
# until it fitted, which for a heading of 1e13 is 2.7e10 turns of the
# loop and for 1e17 never ends (a - 360 is a), in the proc that owns
# every file of gpsfs.
degrees(a: real): real
{
	if(!(a > -1.0e9 && a < 1.0e9))	# a NaN too
		return 0.0;
	a -= 360.0 * math->floor(a / 360.0);
	if(!(a >= 0.0 && a < 360.0))
		a = 0.0;
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return -1;
}

fields(s: string): (array of string, string)
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	if(len s < 2 || s[0] != '$' && s[0] != '!')
		return (nil, "not a sentence");
	if(len s > 1024)
		return (nil, "sentence too long");
	body := s[1:];
	for(i := 0; i < len body; i++)
		if(body[i] == '*')
			break;
	if(i < len body) {
		if(len body - i != 3)
			return (nil, "bad checksum field");
		h1 := hexval(body[i+1]);
		h2 := hexval(body[i+2]);
		if(h1 < 0 || h2 < 0)
			return (nil, "bad checksum field");
		body = body[0:i];
		sum := 0;
		for(j := 0; j < len body; j++)
			sum ^= body[j];
		if(sum != (h1<<4 | h2))
			return (nil, "checksum mismatch");
	}
	for(j := 0; j < len body; j++)
		if(body[j] < 16r20 || body[j] > 16r7e)
			return (nil, "bad character");
	# split on every comma, keeping empty fields
	n := 1;
	for(j = 0; j < len body; j++)
		if(body[j] == ',')
			n++;
	a := array[n] of string;
	k := 0;
	st := 0;
	for(j = 0; j <= len body; j++)
		if(j == len body || body[j] == ',') {
			a[k++] = body[st:j];
			st = j+1;
		}
	if(len a[0] < 3)
		return (nil, "bad address field");
	return (a, nil);
}

# field i, or "" past the end
fld(a: array of string, i: int): string
{
	if(i < len a)
		return a[i];
	return "";
}

# a sign, digits, a point, digits; no more before the point than an
# int holds (it took a thousand: 1e999 is Infinity, and int of it
# whatever the processor gives)
isnum(s: string): int
{
	if(s == nil || len s > Maxnum)
		return 0;
	i := 0;
	if(s[0] == '-' || s[0] == '+')
		i++;
	digits := 0;
	whole := 0;
	dot := 0;
	for(; i < len s; i++)
		if(s[i] >= '0' && s[i] <= '9') {
			digits++;
			if(!dot && ++whole > Maxwhole)
				return 0;
		} else if(s[i] == '.' && !dot)
			dot = 1;
		else
			return 0;
	return digits > 0;
}

# (value, ok)
num(s: string): (real, int)
{
	if(!isnum(s))
		return (0.0, 0);
	return (real s, 1);
}

inum(s: string): int
{
	if(!isnum(s))
		return -1;
	return int real s;
}

# a number no less than lo and no more than hi: (value, ok)
numin(s: string, lo, hi: real): (real, int)
{
	(v, ok) := num(s);
	if(!ok || !(v >= lo && v <= hi))
		return (0.0, 0);
	return (v, 1);
}

# a whole number no less than lo and no more than hi, or -1
inumin(s: string, lo, hi: int): int
{
	n := inum(s);
	if(n < lo || n > hi)
		return -1;
	return n;
}

# ddmm.mmmm (or dddmm.mmmm) and a hemisphere, as degrees
angle(v, h: string, pos, neg: int): (real, int)
{
	if(!isnum(v) || v[0] == '-' || v[0] == '+' || len h != 1)
		return (0.0, 0);
	for(i := 0; i < len v; i++)
		if(v[i] == '.')
			break;
	if(i < 3)
		return (0.0, 0);
	deg := real v[0:i-2];
	(min, nil) := num(v[i-2:]);
	if(min >= 60.0)
		return (0.0, 0);
	d := deg + min/60.0;
	# a latitude is no more than 90, a longitude than 180 (9999 degrees
	# north was a fix, and written back as NMEA its minutes wrapped an int)
	lim := 180.0;
	if(pos == 'N')
		lim = 90.0;
	if(!(d <= lim))
		return (0.0, 0);
	if(h[0] == neg)
		d = -d;
	else if(h[0] != pos)
		return (0.0, 0);
	return (d, 1);
}

# hhmmss[.ss] as hh:mm:ss[.ss]; nil if it is not a time
utc(s: string): string
{
	if(len s < 6)
		return nil;
	for(i := 0; i < 6; i++)
		if(s[i] < '0' || s[i] > '9')
			return nil;
	if(int s[0:2] > 23 || int s[2:4] > 59 || int s[4:6] > 60)
		return nil;
	frac := "";
	if(len s > 6) {
		if(s[6] != '.' || len s == 7)
			return nil;
		allzero := 1;
		for(i = 7; i < len s; i++)
			if(s[i] < '0' || s[i] > '9')
				return nil;
			else if(s[i] != '0')
				allzero = 0;
		if(!allzero)
			frac = s[6:];
	}
	return s[0:2] + ":" + s[2:4] + ":" + s[4:6] + frac;
}

# ddmmyy as yyyy-mm-dd
rmcdate(s: string): string
{
	if(len s != 6)
		return nil;
	for(i := 0; i < 6; i++)
		if(s[i] < '0' || s[i] > '9')
			return nil;
	dd := int s[0:2];
	mm := int s[2:4];
	yy := int s[4:6];
	if(dd < 1 || dd > 31 || mm < 1 || mm > 12)
		return nil;
	if(yy < 80)
		yy += 2000;
	else
		yy += 1900;
	return sys->sprint("%.4d-%.2d-%.2d", yy, mm, dd);
}

timeof(s: string): string
{
	(a, err) := fields(s);
	if(err != nil)
		return nil;
	case kind(a[0]) {
	"RMC" or "GGA" or "GST" or "ZDA" =>
		return utc(fld(a, 1));
	"GLL" =>
		return utc(fld(a, 5));
	}
	return nil;
}

# the sentence type of an address field: GPRMC → RMC
kind(addr: string): string
{
	if(addr[0] == 'P' || len addr != 5)
		return nil;
	return addr[2:];
}

sysindex(name: string): int
{
	for(i := 0; i < len systems; i++)
		if(systems[i] == name)
			return i;
	return len systems - 1;
}

# the system a satellite belongs to, from its talker, the system id
# GSA and GSV carry since NMEA 4.10, and its PRN
sysof(talker: string, sysid: string, prn: int): string
{
	case sysid {
	"1" =>
		talker = "GP";
	"2" =>
		talker = "GL";
	"3" =>
		talker = "GA";
	"4" =>
		talker = "GB";
	"5" =>
		talker = "GQ";
	"6" =>
		talker = "GI";
	}
	case talker {
	"GP" =>
		if(prn >= 33 && prn <= 64)
			return "sbas";
		return "gps";
	"GL" =>
		return "glonass";
	"GA" =>
		return "galileo";
	"GB" or "BD" =>
		return "beidou";
	"GQ" =>
		return "qzss";
	"GI" =>
		return "navic";
	}
	# GN, or an unknown talker: the PRN ranges of NMEA 4.x
	if(prn >= 1 && prn <= 32)
		return "gps";
	if(prn >= 33 && prn <= 64)
		return "sbas";
	if(prn >= 65 && prn <= 99)
		return "glonass";
	if(prn >= 193 && prn <= 202)
		return "qzss";
	return "gnss";
}

quality(q: string): string
{
	case q {
	"1" =>
		return "gps";
	"2" =>
		return "dgps";
	"3" =>
		return "pps";
	"4" =>
		return "rtk";
	"5" =>
		return "float";
	"6" =>
		return "dr";
	"7" =>
		return "manual";
	"8" =>
		return "sim";
	}
	return nil;
}

# the mode indicator RMC, GLL and VTG carry since NMEA 2.3
modeind(m: string): (string, int)
{
	case m {
	"A" =>
		return ("gps", 1);
	"D" =>
		return ("dgps", 1);
	"P" =>
		return ("pps", 1);
	"R" =>
		return ("rtk", 1);
	"F" =>
		return ("float", 1);
	"E" =>
		return ("dr", 1);
	"M" =>
		return ("manual", 1);
	"S" =>
		return ("sim", 1);
	"N" =>
		return (nil, 0);
	}
	return (nil, -1);	# not given
}

Parser.sentence(p: self ref Parser, s: string): (list of ref Fix, string)
{
	(a, err) := fields(s);
	if(err != nil)
		return (nil, err);
	if(a[0][0] == 'P') {
		case a[0] {
		"PGRMZ" =>
			pgrmz(p, a);
		"PGRME" =>
			pgrme(p, a);
		"PFLAA" =>
			pflaa(p, a);
		}
		return (nil, nil);
	}
	k := kind(a[0]);
	talker := a[0][0:2];
	out: list of ref Fix;
	case k {
	"RMC" or "GGA" or "GLL" =>
		t: string;
		bit: int;
		case k {
		"RMC" =>
			t = utc(fld(a, 1));
			bit = Krmc;
		"GGA" =>
			t = utc(fld(a, 1));
			bit = Kgga;
		"GLL" =>
			t = utc(fld(a, 5));
			bit = Kgll;
		}
		if(t != p.curtime || p.epoch == 0) {
			# a new time: the old one is complete if it was not already
			if(p.epoch > 0 && !p.done)
				out = give(p, out);
			p.cur = p.cur.copy();
			p.cur.utc = t;
			p.cur.valid = 0;
			age(p, t);
			p.curtime = t;
			p.got = 0;
			p.done = 0;
			p.epoch++;
		}
		case k {
		"RMC" =>
			rmc(p, a);
		"GGA" =>
			gga(p, a);
		"GLL" =>
			gll(p, a);
		}
		p.got |= bit;
		p.kinds |= bit;
		if(p.done) {
			# a kind the receiver had not sent before, for a time
			# already given out: it is in the fix files from now on
			# (unless the time's position was held back)
			if(!(p.cur.valid && p.cur.haspos && far(p, p.cur)))
				p.last = p.cur;
		} else if((p.got & p.kinds) == p.kinds)
			out = give(p, out);
	"GSA" =>
		gsa(p, a, talker);
	"GSV" =>
		gsv(p, a, talker);
	"GST" =>
		gst(p, a);
	"VTG" =>
		vtg(p, a);
	"ZDA" =>
		zda(p, a);
	"HDT" =>
		hdt(p, a);
	"HDG" =>
		hdg(p, a);
	"HDM" =>
		hdm(p, a);
	"VDM" =>
		vdm(p, a);
	}
	# reverse: oldest first
	r: list of ref Fix;
	for(; out != nil; out = tl out)
		r = hd out :: r;
	return (r, nil);
}

# cur is complete: it is the last fix; give it out if it is a fix, or
# if it is the first without one
give(p: ref Parser, out: list of ref Fix): list of ref Fix
{
	p.done = 1;
	v := p.cur.valid && p.cur.haspos;
	if(v && far(p, p.cur)) {
		if(p.suspect < 3) {
			# a glitch, as like as not: held back, not believed
			p.suspect++;
			p.suspects++;
			return out;
		}
	}
	p.last = p.cur;
	if(v) {
		p.hasgood = 1;
		p.goodlat = p.cur.lat;
		p.goodlon = p.cur.lon;
		p.suspect = 0;
	}
	if(v || p.wasvalid != 0)
		out = p.cur.copy() :: out;
	p.wasvalid = v;
	return out;
}

# more than a degree from the last position given out
far(p: ref Parser, f: ref Fix): int
{
	if(!p.hasgood)
		return 0;
	dlon := f.lon - p.goodlon;
	if(dlon < 0.0)
		dlon = -dlon;
	if(dlon > 180.0)
		dlon = 360.0 - dlon;	# across the date line
	dlat := f.lat - p.goodlat;
	return dlat > 1.0 || dlat < -1.0 || dlon * coslat(f.lat) > 1.0;
}

rmc(p: ref Parser, a: array of string)
{
	f := p.cur;
	f.valid = fld(a, 2) == "A";
	(q, ok) := modeind(fld(a, 12));
	if(ok == 0)
		f.valid = 0;
	else if(ok > 0)
		f.quality = q;
	(lat, latok) := angle(fld(a, 3), fld(a, 4), 'N', 'S');
	(lon, lonok) := angle(fld(a, 5), fld(a, 6), 'E', 'W');
	f.haspos = latok && lonok;
	if(f.haspos) {
		f.lat = lat;
		f.lon = lon;
	}
	(v, vok) := numin(fld(a, 7), 0.0, Maxspeed);
	f.hasspeed = vok;
	if(vok)
		f.speed = v * Knot;
	(c, cok) := numin(fld(a, 8), 0.0, 360.0);
	f.hascourse = cok;
	if(cok)
		f.course = degrees(c);
	if((d := rmcdate(fld(a, 9))) != nil)
		f.date = d;
	(mv, mvok) := hemi(fld(a, 10), fld(a, 11), 'E', 'W');
	if(mvok) {
		f.magvar = mv;
		f.hasmagvar = 1;
	}
}

# a value and its hemisphere letter, as a signed number
hemi(v, h: string, pos, neg: int): (real, int)
{
	(x, ok) := numin(v, 0.0, 180.0);	# a variation or a deviation
	if(!ok || len h != 1 || h[0] != pos && h[0] != neg)
		return (0.0, 0);
	if(h[0] == neg)
		x = -x;
	return (x, 1);
}

gga(p: ref Parser, a: array of string)
{
	f := p.cur;
	q := fld(a, 6);
	# A fix is one of the qualities there are.  Anything but 0 or
	# nothing was a fix: a field damaged, or a number no receiver
	# sends, said there was one.
	qn := quality(q);
	f.valid = qn != nil;
	if(f.valid)
		f.quality = qn;
	(lat, latok) := angle(fld(a, 2), fld(a, 3), 'N', 'S');
	(lon, lonok) := angle(fld(a, 4), fld(a, 5), 'E', 'W');
	f.haspos = latok && lonok;
	if(f.haspos) {
		f.lat = lat;
		f.lon = lon;
	}
	if((n := inumin(fld(a, 7), 0, Maxprn)) >= 0)
		f.sats = n;
	(h, hok) := numin(fld(a, 8), 0.0, Maxerr);
	if(hok)
		f.hdop = h;
	(height, aok) := numin(fld(a, 9), -Maxalt, Maxalt);
	f.hasalt = aok && fld(a, 10) == "M";
	if(f.hasalt)
		f.altitude = height;
}

gll(p: ref Parser, a: array of string)
{
	f := p.cur;
	f.valid = fld(a, 6) == "A";
	(q, ok) := modeind(fld(a, 7));
	if(ok == 0)
		f.valid = 0;
	else if(ok > 0)
		f.quality = q;
	(lat, latok) := angle(fld(a, 1), fld(a, 2), 'N', 'S');
	(lon, lonok) := angle(fld(a, 3), fld(a, 4), 'E', 'W');
	f.haspos = latok && lonok;
	if(f.haspos) {
		f.lat = lat;
		f.lon = lon;
	}
}

gsa(p: ref Parser, a: array of string, talker: string)
{
	f := p.cur;
	case fld(a, 2) {
	"1" =>
		f.mode = Mnone;
	"2" =>
		f.mode = M2d;
	"3" =>
		f.mode = M3d;
	}
	(v, ok) := numin(fld(a, 15), 0.0, Maxerr);
	if(ok)
		f.pdop = v;
	(v, ok) = numin(fld(a, 16), 0.0, Maxerr);
	if(ok)
		f.hdop = v;
	(v, ok) = numin(fld(a, 17), 0.0, Maxerr);
	if(ok)
		f.vdop = v;
	# a receiver sends a GSA for each system for each time: the
	# satellites used are those of every GSA since the last time
	if(p.usedepoch != p.epoch) {
		p.used = nil;
		p.usedepoch = p.epoch;
	}
	# no more than the systems have between them: with no position
	# sentence to begin a new time the list grew by twelve a sentence,
	# for ever
	sysid := fld(a, 18);
	nused := len p.used;
	for(i := 3; i <= 14 && nused < Maxused; i++)
		if((prn := inumin(fld(a, i), 1, Maxprn)) > 0) {
			p.used = (sysof(talker, sysid, prn), prn) :: p.used;
			nused++;
		}
}

gsv(p: ref Parser, a: array of string, talker: string)
{
	total := inumin(fld(a, 1), 1, Maxgsv);
	msg := inum(fld(a, 2));
	if(total < 1 || msg < 1 || msg > total)
		return;
	# four satellites to a sentence; NMEA 4.10 adds a signal id after
	# them, which makes the count of fields after the header odd
	n := len a - 4;
	if(n % 4 == 1)
		n--;
	l: list of ref Sat;
	for(i := 0; i+3 < n; i += 4) {
		prn := inumin(fld(a, 4+i), 1, Maxprn);
		if(prn <= 0)
			continue;
		l = ref Sat(sysof(talker, "", prn), prn,
			inumin(fld(a, 5+i), 0, 90), inumin(fld(a, 6+i), 0, 360), inumin(fld(a, 7+i), 0, 999)) :: l;
	}
	# the sentences of one report are kept together by the talker's
	# system: SBAS satellites come under GP, so key on the talker
	key := sysindex(sysof(talker, "", 1));
	if(msg == 1)
		p.pending[key] = nil;
	# a report is at most Maxgsv sentences of four: one whose first
	# sentence never comes again (2 of 9, for ever) grew without end
	room := 4*Maxgsv - len p.pending[key];
	for(; l != nil && room > 0; l = tl l) {
		p.pending[key] = hd l :: p.pending[key];
		room--;
	}
	if(msg == total) {
		p.inview[key] = p.pending[key];
		p.pending[key] = nil;
	}
}

gst(p: ref Parser, a: array of string)
{
	f := p.cur;
	(la, laok) := numin(fld(a, 6), 0.0, Maxerr);
	(lo, look) := numin(fld(a, 7), 0.0, Maxerr);
	if(laok && look)
		f.err = math->sqrt(la*la + lo*lo);
	(al, alok) := numin(fld(a, 8), 0.0, Maxerr);
	if(alok)
		f.verr = al;
	p.gstseen = 1;
	if(laok && look || alok)
		p.errat = second(p.curtime);
}

# heading, true: HDT,x.x,T
hdt(p: ref Parser, a: array of string)
{
	(h, ok) := numin(fld(a, 1), 0.0, 360.0);
	if(ok && fld(a, 2) == "T") {
		p.cur.heading = degrees(h);
		p.cur.hasheading = 1;
		p.headat = second(p.curtime);
	}
}

# heading from a magnetic sensor, its deviation and the variation:
# HDG,x.x,d.d,E|W,v.v,E|W
hdg(p: ref Parser, a: array of string)
{
	f := p.cur;
	(h, ok) := numin(fld(a, 1), 0.0, 360.0);
	if(!ok)
		return;
	(dev, devok) := hemi(fld(a, 2), fld(a, 3), 'E', 'W');
	if(devok)
		h += dev;
	(mv, mvok) := hemi(fld(a, 4), fld(a, 5), 'E', 'W');
	if(mvok) {
		f.magvar = mv;
		f.hasmagvar = 1;
	}
	if(f.hasmagvar) {
		f.heading = degrees(h + f.magvar);
		f.hasheading = 1;
		p.headat = second(p.curtime);
	}
}

# heading, magnetic: HDM,x.x,M; true only with the variation known
hdm(p: ref Parser, a: array of string)
{
	f := p.cur;
	(h, ok) := numin(fld(a, 1), 0.0, 360.0);
	if(ok && fld(a, 2) == "M" && f.hasmagvar) {
		f.heading = degrees(h + f.magvar);
		f.hasheading = 1;
		p.headat = second(p.curtime);
	}
}

# Garmin's altitude: PGRMZ,a,f|m,d.  Pressure altitude from FLARM and
# from an encoder wired to a panel GPS; some handhelds give GPS
# altitude here.
pgrmz(p: ref Parser, a: array of string)
{
	(v, ok) := num(fld(a, 1));
	if(!ok)
		return;
	case fld(a, 2) {
	"f" or "F" =>
		v *= Foot;
	"m" or "M" =>
		;
	* =>
		return;
	}
	if(!(v >= -Maxalt && v <= Maxalt))
		return;
	p.cur.baroalt = v;
	p.cur.hasbaro = 1;
	p.baroat = second(p.curtime);
}

# Garmin's estimated errors: PGRME,h,M,v,M,e,M; GST's when it sends both
pgrme(p: ref Parser, a: array of string)
{
	if(p.gstseen)
		return;
	(h, hok) := numin(fld(a, 1), 0.0, Maxerr);
	if(hok && fld(a, 2) == "M")
		p.cur.err = h;
	(v, vok) := numin(fld(a, 3), 0.0, Maxerr);
	if(vok && fld(a, 4) == "M")
		p.cur.verr = v;
	if(hok || vok)
		p.errat = second(p.curtime);
}

flarmtypes := array[] of {
	nil, "glider", "towplane", "helicopter", "parachute", "dropplane",
	"hangglider", "paraglider", "aircraft", "jet", nil, "balloon",
	"airship", "uav", nil, "obstacle",
};

# FLARM traffic, placed from this fix: PFLAA,alarm,north,east,vertical,
# idtype,id,track,turn,speed,climb,type
pflaa(p: ref Parser, a: array of string)
{
	own := p.cur;
	if(!own.valid || !own.haspos)
		own = p.last;
	if(own == nil || !own.valid || !own.haspos)
		return;
	# the data port's ranges: metres north and east to 20000000, up to
	# 32767, a track of 0 to 359, a speed to 32767 m/s
	(n, nok) := numin(fld(a, 2), -2.0e7, 2.0e7);
	(e, eok) := numin(fld(a, 3), -2.0e7, 2.0e7);
	id := fld(a, 6);
	if(!nok || !eok || id == "")
		return;
	t := Target.new("flarm", id);
	t.haspos = 1;
	t.lat = own.lat + n / M;
	t.lon = own.lon + e / (M * coslat(own.lat));
	if(t.lon > 180.0)
		t.lon -= 360.0;
	else if(t.lon < -180.0)
		t.lon += 360.0;
	if(!(t.lat >= -90.0 && t.lat <= 90.0 && t.lon >= -180.0 && t.lon <= 180.0))
		return;	# nowhere on the earth
	(v, vok) := numin(fld(a, 4), -32768.0, 32767.0);
	if(vok && own.hasalt) {
		t.altitude = own.altitude + v;
		t.hasalt = 1;
	}
	(c, cok) := numin(fld(a, 7), 0.0, 360.0);
	if(cok) {
		t.course = degrees(c);
		t.hascourse = 1;
	}
	(sp, sok) := numin(fld(a, 9), 0.0, 32767.0);
	if(sok) {
		t.speed = sp;
		t.hasspeed = 1;
	}
	(cl, clok) := numin(fld(a, 10), -1000.0, 1000.0);
	if(clok) {
		t.climb = cl;
		t.hasclimb = 1;
	}
	ty := fld(a, 11);
	if(len ty == 1) {
		i := hexval(ty[0]);
		if(i >= 0 && i < len flarmtypes)
			t.category = flarmtypes[i];
	}
	p.target(t);
}

coslat(lat: real): real
{
	c := math->cos(lat * Math->Pi / 180.0);
	if(c < 0.01)
		c = 0.01;
	return c;
}

vtg(p: ref Parser, a: array of string)
{
	f := p.cur;
	if(fld(a, 9) == "N")
		return;
	(c, cok) := numin(fld(a, 1), 0.0, 360.0);
	if(cok && fld(a, 2) == "T") {
		f.course = degrees(c);
		f.hascourse = 1;
	}
	(k, kok) := numin(fld(a, 7), 0.0, Maxspeed);
	if(kok) {
		f.speed = k / 3.6;
		f.hasspeed = 1;
	} else {
		(n, nok) := numin(fld(a, 5), 0.0, Maxspeed);
		if(nok) {
			f.speed = n * Knot;
			f.hasspeed = 1;
		}
	}
}

zda(p: ref Parser, a: array of string)
{
	dd := inum(fld(a, 2));
	mm := inum(fld(a, 3));
	yy := inum(fld(a, 4));
	if(dd < 1 || dd > 31 || mm < 1 || mm > 12 || yy < 1980 || yy > 9999)
		return;
	d := sys->sprint("%.4d-%.2d-%.2d", yy, mm, dd);
	p.cur.date = d;
	if(p.last != nil && p.last != p.cur && p.last.date == nil)
		p.last.date = d;
}

Parser.satellites(p: self ref Parser): string
{
	s := "";
	for(i := 0; i < len systems; i++) {
		# in PRN order
		a := array[len p.inview[i]] of ref Sat;
		j := 0;
		for(l := p.inview[i]; l != nil; l = tl l)
			a[j++] = hd l;
		for(j = 1; j < len a; j++)
			for(k := j; k > 0 && (a[k].system < a[k-1].system ||
					a[k].system == a[k-1].system && a[k].prn < a[k-1].prn); k--)
				(a[k], a[k-1]) = (a[k-1], a[k]);
		for(j = 0; j < len a; j++) {
			t := a[j];
			used := 0;
			for(u := p.used; u != nil; u = tl u)
				if((hd u).t0 == t.system && (hd u).t1 == t.prn)
					used = 1;
			s += sys->sprint("%s %d %s %s %s %d\n", t.system, t.prn,
				unk(t.elev), unk(t.azim), unk(t.snr), used);
		}
	}
	return s;
}

unk(n: int): string
{
	if(n < 0)
		return "-";
	return string n;
}

#
# AIS: !xxVDM,count,number,sequence,channel,payload,fill.  A message of
# more than one sentence is held until its last part comes.
#
vdm(p: ref Parser, a: array of string)
{
	# The count is one digit: no message is more than five sentences.
	# It was any number, and sized the array the parts are kept in: a
	# count of 200000000 asked the heap for 1.6GB, and the exception
	# ended whoever was parsing (gpsfs's one server proc).
	count := inumin(fld(a, 1), 1, Maxvdm);
	num := inum(fld(a, 2));
	seq := fld(a, 3);
	channel := fld(a, 4);
	payload := fld(a, 5);
	fill := inum(fld(a, 6));
	if(count < 1 || num < 1 || num > count || payload == "" ||
	   len seq > 2 || len channel > 2 || fill > 5)
		return;
	if(fill < 0)
		fill = 0;
	if(count == 1) {
		aismsg(p, payload, fill);
		return;
	}
	now := sys->millisec();
	key := a[0][0:2] + "/" + seq + "/" + channel;
	parts: array of string;
	# the other messages in parts, oldest first, less those whose rest
	# never came
	rest: list of (string, array of string, int, int);
	nrest := 0;
	for(l := p.aispend; l != nil; l = tl l) {
		(k, pa, nil, when) := hd l;
		if(k == key) {
			if(len pa == count && num != 1)
				parts = pa;
		} else if(now - when < Aishold) {
			rest = hd l :: rest;
			nrest++;
		}
	}
	if(parts == nil && num != 1) {
		p.aispend = newest(rest, nrest, Maxaispend);
		return;	# its first part was lost
	}
	if(parts == nil)
		parts = array[count] of string;
	parts[num-1] = payload;
	if(num < count) {
		# no more than a few messages in parts at once, and those the
		# newest: it kept the eight oldest, so eight first parts whose
		# rest never came shut out every message after them
		p.aispend = (key, parts, fill, now) :: newest(rest, nrest, Maxaispend-1);
		return;
	}
	p.aispend = newest(rest, nrest, Maxaispend);
	whole := "";
	for(i := 0; i < count; i++) {
		if(parts[i] == nil)
			return;
		whole += parts[i];
	}
	aismsg(p, whole, fill);
}

# the newest max of n messages in parts given oldest first, newest first
newest(l: list of (string, array of string, int, int), n, max: int): list of (string, array of string, int, int)
{
	for(; n > max; n--)
		l = tl l;
	r: list of (string, array of string, int, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# the payload's six-bit characters as numbers; the count of bits
unarmour(s: string, fill: int): (array of int, int)
{
	b := array[len s] of int;
	for(i := 0; i < len s; i++) {
		c := s[i] - 48;
		if(c > 40)
			c -= 8;
		if(c < 0 || c > 63)
			return (nil, 0);
		b[i] = c;
	}
	return (b, 6 * len s - fill);
}

# n bits from bit start, unsigned, or -1 past the end
getu(b: array of int, nbits, start, n: int): int
{
	if(start + n > nbits)
		return -1;
	v := 0;
	for(i := start; i < start + n; i++)
		v = v<<1 | (b[i/6] >> (5 - i%6)) & 1;
	return v;
}

# n bits, signed; the second value is 0 past the end
gets(b: array of int, nbits, start, n: int): (int, int)
{
	v := getu(b, nbits, start, n);
	if(v < 0)
		return (0, 0);
	if(v & (1<<(n-1)))
		v -= 1<<n;
	return (v, 1);
}

sixbit: con "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?";

# n characters of six-bit text, trailing @ and blanks gone
aistext(b: array of int, nbits, start, n: int): string
{
	s := "";
	for(i := 0; i < n; i++) {
		c := getu(b, nbits, start + 6*i, 6);
		if(c < 0)
			break;
		s[len s] = sixbit[c];
	}
	while(len s > 0 && (s[len s-1] == '@' || s[len s-1] == ' '))
		s = s[0:len s-1];
	for(i = 0; i < len s; i++)
		if(s[i] == '@')
			return s[0:i];
	return s;
}

shiptype(n: int): string
{
	case n {
	30 =>	return "fishing";
	31 or 32 =>	return "towing";
	33 =>	return "dredging";
	34 =>	return "diving";
	35 =>	return "military";
	36 =>	return "sailing";
	37 =>	return "pleasure";
	50 =>	return "pilot";
	51 =>	return "sar";
	52 =>	return "tug";
	53 =>	return "tender";
	54 =>	return "antipollution";
	55 =>	return "law";
	58 =>	return "medical";
	}
	if(n >= 20 && n <= 29)
		return "wig";
	if(n >= 40 && n <= 49)
		return "hsc";
	if(n >= 60 && n <= 69)
		return "passenger";
	if(n >= 70 && n <= 79)
		return "cargo";
	if(n >= 80 && n <= 89)
		return "tanker";
	return nil;
}

# a position report's fields: speed, longitude, latitude, course and
# heading at the bits given
aispos(t: ref Target, b: array of int, nb, sog, lon, lat, cog, hdg: int)
{
	v := getu(b, nb, sog, 10);
	if(v >= 0 && v != 1023) {
		t.speed = real v / 10.0 * Knot;
		t.hasspeed = 1;
	}
	(x, xok) := gets(b, nb, lon, 28);
	(y, yok) := gets(b, nb, lat, 27);
	if(xok && yok && x != 108600000 && y != 54600000 &&
	   x >= -108000000 && x <= 108000000 && y >= -54000000 && y <= 54000000) {
		t.lon = real x / 600000.0;
		t.lat = real y / 600000.0;
		t.haspos = 1;
	}
	v = getu(b, nb, cog, 12);
	if(v >= 0 && v < 3600) {
		t.course = real v / 10.0;
		t.hascourse = 1;
	}
	v = getu(b, nb, hdg, 9);
	if(v >= 0 && v < 360) {
		t.heading = real v;
		t.hasheading = 1;
	}
}

aismsg(p: ref Parser, payload: string, fill: int)
{
	(b, nb) := unarmour(payload, fill);
	if(b == nil)
		return;
	ty := getu(b, nb, 0, 6);
	mmsi := getu(b, nb, 8, 30);
	if(ty < 0 || mmsi <= 0)
		return;
	t := Target.new("ais", string mmsi);
	case ty {
	1 or 2 or 3 =>
		aispos(t, b, nb, 50, 61, 89, 116, 128);
	18 =>
		aispos(t, b, nb, 46, 57, 85, 112, 124);
	19 =>
		aispos(t, b, nb, 46, 57, 85, 112, 124);
		t.name = aistext(b, nb, 143, 20);
		t.category = shiptype(getu(b, nb, 263, 8));
	5 =>
		t.callsign = aistext(b, nb, 70, 7);
		t.name = aistext(b, nb, 112, 20);
		t.category = shiptype(getu(b, nb, 232, 8));
	24 =>
		case getu(b, nb, 38, 2) {
		0 =>
			t.name = aistext(b, nb, 40, 20);
		1 =>
			t.category = shiptype(getu(b, nb, 40, 8));
			t.callsign = aistext(b, nb, 90, 7);
		* =>
			return;
		}
	* =>
		return;
	}
	p.target(t);
}

#
# Traffic
#
Target.new(kind, id: string): ref Target
{
	return ref Target(kind, id, 0, 0.0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0,
		nil, nil, nil, 0, 0, nil);
}

Maxtargets: con 1000;	# of each kind
Forget: con 10*60*1000;	# ms

# text that becomes part of a line of the traffic file: printable, and
# no longer than such a thing is
plain(s: string, max: int): int
{
	if(len s > max)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < ' ' || s[i] > '~')
			return 0;
	return 1;
}

Parser.target(p: self ref Parser, t: ref Target)
{
	# A target is a line of the traffic file, which programs read a
	# line a craft: a name with a newline in it (a GDL 90 callsign is
	# eight bytes of the sender's) made a second line of its own
	# choosing.  A target without an id that can be a word is not one;
	# a name that cannot be shown is no name.
	if(t == nil || t.id == nil || !plain(t.id, Maxid) || t.kind == nil || !plain(t.kind, Maxid))
		return;
	if(!plain(t.name, Maxname))
		t.name = nil;
	if(!plain(t.callsign, Maxname))
		t.callsign = nil;
	if(!plain(t.category, Maxname))
		t.category = nil;
	if(!plain(t.emergency, Maxname))
		t.emergency = nil;
	t.seen = sys->millisec();
	n := 0;
	for(l := p.targets; l != nil; l = tl l) {
		o := hd l;
		if(o.kind != t.kind)
			continue;
		n++;
		if(o.id != t.id)
			continue;
		if(t.haspos) {
			o.haspos = 1;
			o.lat = t.lat;
			o.lon = t.lon;
		}
		if(t.hasalt) {
			o.hasalt = 1;
			o.altitude = t.altitude;
		}
		if(t.hasspeed) {
			o.hasspeed = 1;
			o.speed = t.speed;
		}
		if(t.hascourse) {
			o.hascourse = 1;
			o.course = t.course;
		}
		if(t.hasheading) {
			o.hasheading = 1;
			o.heading = t.heading;
		}
		if(t.hasclimb) {
			o.hasclimb = 1;
			o.climb = t.climb;
		}
		if(t.name != nil)
			o.name = t.name;
		if(t.callsign != nil)
			o.callsign = t.callsign;
		if(t.category != nil)
			o.category = t.category;
		# as its last report says, not as an earlier one did
		if(t.haspos)
			o.extrapolated = t.extrapolated;
		o.emergency = t.emergency;
		o.seen = t.seen;
		return;
	}
	# A kind's table full: the old are forgotten, then the one of the
	# kind longest unheard.  The tables are apart so that a thousand
	# invented ships do not take the aircraft off the list, and nothing
	# is formatted or sorted to make room (each new ship past the
	# thousandth cost 19 ms of the proc that serves every file).
	if(n >= Maxtargets) {
		expire(p, t.seen);
		n = 0;
		oldest: ref Target;
		for(l = p.targets; l != nil; l = tl l)
			if((hd l).kind == t.kind) {
				n++;
				if(oldest == nil || (hd l).seen - oldest.seen < 0)
					oldest = hd l;
			}
		if(n >= Maxtargets) {
			kept: list of ref Target;
			for(l = p.targets; l != nil; l = tl l)
				if(hd l != oldest)
					kept = hd l :: kept;
			p.targets = kept;
		}
	}
	p.targets = t :: p.targets;
}

# forget the targets not heard for ten minutes
expire(p: ref Parser, now: int)
{
	kept: list of ref Target;
	for(l := p.targets; l != nil; l = tl l)
		if(now - (hd l).seen < Forget)
			kept = hd l :: kept;
	p.targets = kept;
}

Parser.traffic(p: self ref Parser, now: int): string
{
	expire(p, now);
	a := array[len p.targets] of ref Target;
	i := 0;
	for(l := p.targets; l != nil; l = tl l)
		a[i++] = hd l;
	own := p.last;
	if(own == nil || !own.valid || !own.haspos)
		own = nil;
	sortby(a, own);
	s := "";
	for(i = 0; i < len a; i++)
		s += a[i].text(now) + "\n";
	return s;
}

# nearest first from own, those with no position last; with no own
# position, the most lately heard first
sortby(a: array of ref Target, own: ref Fix)
{
	d := array[len a] of real;
	for(i := 0; i < len a; i++)
		if(own == nil)
			d[i] = real -a[i].seen;
		else if(!a[i].haspos)
			d[i] = 1.0e30;
		else {
			dy := (a[i].lat - own.lat) * M;
			dx := (a[i].lon - own.lon) * M * coslat(own.lat);
			d[i] = dx*dx + dy*dy;
		}
	for(i = 1; i < len a; i++)
		for(j := i; j > 0 && d[j] < d[j-1]; j--) {
			(a[j], a[j-1]) = (a[j-1], a[j]);
			(d[j], d[j-1]) = (d[j-1], d[j]);
		}
}

Target.text(t: self ref Target, now: int): string
{
	s := "kind=" + t.kind + " id=" + quoted(t.id);
	if(t.haspos)
		s += sys->sprint(" lat=%.6f lon=%.6f", t.lat, t.lon);
	if(t.hasalt)
		s += sys->sprint(" alt=%.0f", t.altitude);
	if(t.hasspeed)
		s += sys->sprint(" speed=%.1f", t.speed);
	if(t.hascourse)
		s += sys->sprint(" course=%.1f", t.course);
	if(t.hasheading)
		s += sys->sprint(" heading=%.0f", t.heading);
	if(t.hasclimb)
		s += sys->sprint(" climb=%.1f", t.climb);
	if(t.name != nil)
		s += " name=" + quoted(t.name);
	if(t.callsign != nil)
		s += " callsign=" + quoted(t.callsign);
	if(t.category != nil)
		s += " cat=" + t.category;
	if(t.extrapolated)
		s += " extrapolated=1";
	if(t.emergency != nil)
		s += " emergency=" + t.emergency;
	s += sys->sprint(" age=%.1f", real (now - t.seen) / 1000.0);
	return s;
}

# as sys->tokenize takes it back: quoted if it has a blank or a quote
quoted(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t' || s[i] == '\'' || s[i] == '=')
			break;
	if(i == len s && s != "")
		return s;
	q := "'";
	for(i = 0; i < len s; i++) {
		if(s[i] == '\'')
			q += "'";
		q[len q] = s[i];
	}
	return q + "'";
}

#
# A fix written as sentences
#
sentences(f: ref Fix): string
{
	hms := "";
	if(f.utc != nil && len f.utc >= 8) {
		hms = f.utc[0:2] + f.utc[3:5] + f.utc[6:8];
		if(len f.utc > 8)
			hms += f.utc[8:];
	}
	dmy := "";
	if(f.date != nil && len f.date == 10)
		dmy = f.date[8:10] + f.date[5:7] + f.date[2:4];
	# a fix from a decoder is whatever the decoder was sent: a position
	# off the earth is none (its minutes do not fit latlon's int)
	haspos := f.haspos && f.lat >= -90.0 && f.lat <= 90.0 && f.lon >= -180.0 && f.lon <= 180.0;
	pos := ",,,";
	if(haspos)
		pos = latlon(f.lat, 2, 'N', 'S') + "," + latlon(f.lon, 3, 'E', 'W');
	status := "V";
	mode := "N";
	if(f.valid && haspos) {
		status = "A";
		mode = "A";
	}
	b := "GPRMC," + hms + "," + status + "," + pos + ",";
	if(f.hasspeed)
		b += sys->sprint("%.2f", f.speed / Knot);
	b += ",";
	if(f.hascourse)
		b += sys->sprint("%.1f", f.course);
	b += "," + dmy + ",";
	if(f.hasmagvar) {
		if(f.magvar < 0.0)
			b += sys->sprint("%.1f,W", -f.magvar);
		else
			b += sys->sprint("%.1f,E", f.magvar);
	} else
		b += ",";
	s := cksum(b + "," + mode);

	if(f.err >= 0.0 || f.verr >= 0.0) {
		b = "GPGST," + hms + ",,,,,";
		if(f.err >= 0.0)
			b += sys->sprint("%.1f,%.1f,", f.err / Sqrt2, f.err / Sqrt2);
		else
			b += ",,";
		if(f.verr >= 0.0)
			b += sys->sprint("%.1f", f.verr);
		s += cksum(b);
	}
	if(haspos) {
		q := "0";
		if(f.valid)
			q = "1";
		b = "GPGGA," + hms + "," + pos + "," + q + ",";
		if(f.sats >= 0)
			b += sys->sprint("%.2d", f.sats);
		b += ",";
		if(f.hdop >= 0.0)
			b += sys->sprint("%.1f", f.hdop);
		b += ",";
		if(f.hasalt)
			b += sys->sprint("%.1f", f.altitude);
		s += cksum(b + ",M,,M,,");
	}
	if(f.hasheading)
		s += cksum(sys->sprint("GPHDT,%.1f,T", f.heading));
	if(f.hasbaro && f.baroalt >= -Maxalt && f.baroalt <= Maxalt) {
		d := "2";
		if(f.hasalt)
			d = "3";
		s += cksum(sys->sprint("PGRMZ,%d,f,%s", int (f.baroalt / Foot), d));
	}
	return s;
}

Sqrt2: con 1.41421356;

# degrees as NMEA's d(dd)mm.mmmmm and its hemisphere
latlon(v: real, ndeg, pos, neg: int): string
{
	h := pos;
	if(v < 0.0) {
		v = -v;
		h = neg;
	}
	m := int (v * 60.0 * 100000.0);	# hundred-thousandths of a minute (int rounds)
	d := sys->sprint("%d", m / 6000000);
	while(len d < ndeg)
		d = "0" + d;
	return sys->sprint("%s%.2d.%.5d,%c", d, m / 100000 % 60, m % 100000, h);
}

cksum(body: string): string
{
	sum := 0;
	for(i := 0; i < len body; i++)
		sum ^= body[i];
	return sys->sprint("$%s*%.2X\r\n", body, sum);
}
