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
# GI, GN) are taken alike.  Proprietary sentences ($P...) and AIS (!)
# are not position sentences and are passed over.
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

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

Fix.new(): ref Fix
{
	return ref Fix(nil, nil, 0, 0, 0.0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, -1, nil, -1,
		-1.0, -1.0, -1.0, -1.0, -1.0);
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
	if(f.valid && f.hasspeed)
		s += sys->sprint(" speed=%.2f", f.speed);
	if(f.valid && f.hascourse)
		s += sys->sprint(" course=%.1f", f.course);
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
	return s[1:];
}

Parser.new(): ref Parser
{
	return ref Parser(Fix.new(), nil, 0, nil, 0, 0, 0, -1,
		array[len systems] of list of ref Sat,
		array[len systems] of list of ref Sat,
		nil, -1);
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
	if(len s < 2 || s[0] != '$')
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

isnum(s: string): int
{
	if(s == nil)
		return 0;
	i := 0;
	if(s[0] == '-' || s[0] == '+')
		i++;
	digits := 0;
	dot := 0;
	for(; i < len s; i++)
		if(s[i] >= '0' && s[i] <= '9')
			digits++;
		else if(s[i] == '.' && !dot)
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
	p.last = p.cur;
	v := p.cur.valid && p.cur.haspos;
	if(v || p.wasvalid != 0)
		out = p.cur.copy() :: out;
	p.wasvalid = v;
	return out;
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
	(v, vok) := num(fld(a, 7));
	f.hasspeed = vok;
	if(vok)
		f.speed = v * Knot;
	(c, cok) := num(fld(a, 8));
	f.hascourse = cok;
	if(cok)
		f.course = c;
	if((d := rmcdate(fld(a, 9))) != nil)
		f.date = d;
}

gga(p: ref Parser, a: array of string)
{
	f := p.cur;
	q := fld(a, 6);
	f.valid = q != "0" && q != "";
	if(f.valid && (qn := quality(q)) != nil)
		f.quality = qn;
	(lat, latok) := angle(fld(a, 2), fld(a, 3), 'N', 'S');
	(lon, lonok) := angle(fld(a, 4), fld(a, 5), 'E', 'W');
	f.haspos = latok && lonok;
	if(f.haspos) {
		f.lat = lat;
		f.lon = lon;
	}
	if((n := inum(fld(a, 7))) >= 0)
		f.sats = n;
	(h, hok) := num(fld(a, 8));
	if(hok)
		f.hdop = h;
	(height, aok) := num(fld(a, 9));
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
	(v, ok) := num(fld(a, 15));
	if(ok)
		f.pdop = v;
	(v, ok) = num(fld(a, 16));
	if(ok)
		f.hdop = v;
	(v, ok) = num(fld(a, 17));
	if(ok)
		f.vdop = v;
	# a receiver sends a GSA for each system for each time: the
	# satellites used are those of every GSA since the last time
	if(p.usedepoch != p.epoch) {
		p.used = nil;
		p.usedepoch = p.epoch;
	}
	sysid := fld(a, 18);
	for(i := 3; i <= 14; i++)
		if((prn := inum(fld(a, i))) > 0)
			p.used = (sysof(talker, sysid, prn), prn) :: p.used;
}

gsv(p: ref Parser, a: array of string, talker: string)
{
	total := inum(fld(a, 1));
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
		prn := inum(fld(a, 4+i));
		if(prn <= 0)
			continue;
		l = ref Sat(sysof(talker, "", prn), prn,
			inum(fld(a, 5+i)), inum(fld(a, 6+i)), inum(fld(a, 7+i))) :: l;
	}
	# the sentences of one report are kept together by the talker's
	# system: SBAS satellites come under GP, so key on the talker
	key := sysindex(sysof(talker, "", 1));
	if(msg == 1)
		p.pending[key] = nil;
	for(; l != nil; l = tl l)
		p.pending[key] = hd l :: p.pending[key];
	if(msg == total) {
		p.inview[key] = p.pending[key];
		p.pending[key] = nil;
	}
}

gst(p: ref Parser, a: array of string)
{
	f := p.cur;
	(la, laok) := num(fld(a, 6));
	(lo, look) := num(fld(a, 7));
	if(laok && look)
		f.err = math->sqrt(la*la + lo*lo);
	(al, alok) := num(fld(a, 8));
	if(alok)
		f.verr = al;
}

vtg(p: ref Parser, a: array of string)
{
	f := p.cur;
	if(fld(a, 9) == "N")
		return;
	(c, cok) := num(fld(a, 1));
	if(cok && fld(a, 2) == "T") {
		f.course = c;
		f.hascourse = 1;
	}
	(k, kok) := num(fld(a, 7));
	if(kok) {
		f.speed = k / 3.6;
		f.hasspeed = 1;
	} else {
		(n, nok) := num(fld(a, 5));
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
