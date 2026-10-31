implement Gdl90;

#
# GDL 90, after Garmin's GDL 90 Data Interface Specification
# (560-1058-00, rev A) and the extensions Stratux and ForeFlight use.
#
# A message is framed by 0x7E flags, 0x7D escaping a flag or itself
# (the next byte xor 0x20), and ends with a CRC-16-CCITT, low byte
# first.  The messages read:
#
#	0	heartbeat: whether the GPS position is valid
#	10	own-ship report: position, pressure altitude, velocity, track
#	20	traffic report: the same for another aircraft
#
# 11 (own-ship geometric altitude) is height above the WGS-84
# ellipsoid, not mean sea level, so it is not given as an altitude: a
# fix from GDL 90 has a pressure altitude (baroalt) and no alt.  The
# NACp of a report (a 95% bound on its position) is given as err at
# half that bound.
#

include "sys.m";
	sys: Sys;

include "nmea.m";
	nmea: Nmea;
	Fix, Target: import nmea;

include "gdl90.m";

Flag: con byte 16r7E;
Esc: con byte 16r7D;
Maxframe: con 512;
Foot: con 0.3048;
Knot: con 1852.0 / 3600.0;

crctab: array of int;

init(n: Nmea)
{
	sys = load Sys Sys->PATH;
	nmea = n;
	crctab = array[256] of int;
	for(i := 0; i < 256; i++) {
		c := i << 8;
		for(j := 0; j < 8; j++)
			if(c & 16r8000)
				c = (c << 1) ^ 16r1021;
			else
				c <<= 1;
		crctab[i] = c & 16rFFFF;
	}
}

crc(b: array of byte): int
{
	c := 0;
	for(i := 0; i < len b; i++)
		c = (crctab[c >> 8] ^ (c << 8) ^ int b[i]) & 16rFFFF;
	return c;
}

frame(msg: array of byte): array of byte
{
	c := crc(msg);
	body := array[len msg + 2] of byte;
	body[0:] = msg;
	body[len msg] = byte c;
	body[len msg + 1] = byte (c >> 8);
	out := array[2 * len body + 2] of byte;
	n := 0;
	out[n++] = Flag;
	for(i := 0; i < len body; i++)
		if(body[i] == Flag || body[i] == Esc) {
			out[n++] = Esc;
			out[n++] = body[i] ^ byte 16r20;
		} else
			out[n++] = body[i];
	out[n++] = Flag;
	return out[0:n];
}

Framer.new(): ref Framer
{
	return ref Framer(array[Maxframe] of byte, 0, 0, 0, 0, 0);
}

Framer.feed(d: self ref Framer, b: array of byte): (list of ref Fix, list of ref Target)
{
	fixes: list of ref Fix;
	targets: list of ref Target;
	for(i := 0; i < len b; i++) {
		c := b[i];
		if(c == Flag) {
			if(d.inframe && d.n >= 3) {
				(f, t) := message(d, d.frame[0:d.n]);
				if(f != nil)
					fixes = f :: fixes;
				if(t != nil)
					targets = t :: targets;
			}
			# a flag both ends one frame and begins the next
			d.inframe = 1;
			d.n = 0;
			d.esc = 0;
			continue;
		}
		if(!d.inframe)
			continue;
		if(c == Esc) {
			d.esc = 1;
			continue;
		}
		if(d.esc) {
			c ^= byte 16r20;
			d.esc = 0;
		}
		if(d.n >= Maxframe) {
			d.inframe = 0;	# no frame is so long: wait for the next flag
			continue;
		}
		d.frame[d.n++] = c;
	}
	return (rev(fixes), revt(targets));
}

rev(l: list of ref Fix): list of ref Fix
{
	r: list of ref Fix;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revt(l: list of ref Target): list of ref Target
{
	r: list of ref Target;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# one frame, its CRC last: an own-ship fix, or a target, or neither
message(d: ref Framer, f: array of byte): (ref Fix, ref Target)
{
	n := len f - 2;
	if(crc(f[0:n]) != (int f[n] | int f[n+1] << 8)) {
		d.bad++;
		return (nil, nil);
	}
	m := f[0:n];
	case int m[0] {
	0 =>
		if(len m >= 2)
			d.gpsvalid = (int m[1] & 16r80) != 0;
	10 =>
		if(len m >= 28)
			return (ownship(d, m[1:28]), nil);
	20 =>
		if(len m >= 28)
			return (nil, traffic(m[1:28]));
	}
	return (nil, nil);
}

# 24 bits, signed
s24(b: array of byte): int
{
	v := int b[0] << 16 | int b[1] << 8 | int b[2];
	if(v & 16r800000)
		v -= 16r1000000;
	return v;
}

# a 95% position bound in metres for each NACp, or -1
epu := array[] of {
	-1.0, 18520.0, 7408.0, 3704.0, 1852.0, 926.0, 555.6, 185.2, 92.6, 30.0, 10.0, 3.0,
};

# what a report holds: (has position, lat, lon, NIC, NACp,
# has pressure altitude, feet, has speed, knots, has vertical speed,
# feet a minute, track type, track degrees, airborne)
Report: adt {
	haspos:	int;
	lat, lon:	real;
	nic, nacp:	int;
	hasalt:	int;
	feet:	int;
	hasspeed:	int;
	knots:	int;
	hasvs:	int;
	fpm:	int;
	tracktype:	int;	# 0 none, 1 true track, 2 magnetic heading, 3 true heading
	track:	real;
	addr:	int;
	addrtype:	int;
	emitter:	int;
	callsign:	string;
};

report(b: array of byte): ref Report
{
	r := ref Report;
	r.addrtype = int b[0] & 16rF;
	r.addr = int b[1] << 16 | int b[2] << 8 | int b[3];
	lat := s24(b[4:7]);
	lon := s24(b[7:10]);
	r.nic = int b[12] >> 4;
	r.nacp = int b[12] & 16rF;
	r.haspos = (lat != 0 || lon != 0 || r.nic != 0);
	r.lat = real lat * 180.0 / real 16r800000;
	r.lon = real lon * 180.0 / real 16r800000;
	if(r.lat < -90.0 || r.lat > 90.0 || r.lon < -180.0 || r.lon > 180.0)
		r.haspos = 0;
	a := int b[10] << 4 | int b[11] >> 4;
	r.hasalt = a != 16rFFF;
	r.feet = a * 25 - 1000;
	misc := int b[11] & 16rF;
	r.tracktype = misc & 3;
	hv := int b[13] << 4 | int b[14] >> 4;
	r.hasspeed = hv != 16rFFF;
	r.knots = hv;
	vv := (int b[14] & 16rF) << 8 | int b[15];
	r.hasvs = vv != 16r800;
	if(vv & 16r800)
		vv -= 16r1000;
	r.fpm = vv * 64;
	r.track = real int b[16] * 360.0 / 256.0;
	r.emitter = int b[17];
	cs := string b[18:26];
	while(len cs > 0 && (cs[len cs-1] == ' ' || cs[len cs-1] == 0))
		cs = cs[0:len cs-1];
	r.callsign = cs;
	return r;
}

ownship(d: ref Framer, b: array of byte): ref Fix
{
	r := report(b);
	f := Fix.new();
	f.haspos = r.haspos;
	f.lat = r.lat;
	f.lon = r.lon;
	f.valid = r.haspos && d.gpsvalid;
	if(r.hasalt) {
		f.hasbaro = 1;
		f.baroalt = real r.feet * Foot;
	}
	if(r.hasspeed) {
		f.hasspeed = 1;
		f.speed = real r.knots * Knot;
	}
	case r.tracktype {
	1 =>
		f.hascourse = 1;
		f.course = r.track;
	3 =>
		f.hasheading = 1;
		f.heading = r.track;
	}
	if(r.nacp > 0 && r.nacp < len epu)
		f.err = epu[r.nacp] / 2.0;
	if(f.valid)
		f.quality = "gps";
	return f;
}

emitters := array[] of {
	nil, "light", "small", "large", "highvortex", "heavy", "highperf", "rotorcraft",
	nil, "glider", "balloon", "parachutist", "ultralight", nil, "uav", "space",
	nil, "emergency", "service", "obstacle", "obstacle", "obstacle",
};

traffic(b: array of byte): ref Target
{
	r := report(b);
	t := Target.new("adsb", sys->sprint("%.6x", r.addr));
	if(r.haspos) {
		t.haspos = 1;
		t.lat = r.lat;
		t.lon = r.lon;
	}
	if(r.hasalt) {
		t.hasalt = 1;
		t.altitude = real r.feet * Foot;
	}
	if(r.hasspeed) {
		t.hasspeed = 1;
		t.speed = real r.knots * Knot;
	}
	if(r.hasvs) {
		t.hasclimb = 1;
		t.climb = real r.fpm * Foot / 60.0;
	}
	case r.tracktype {
	1 =>
		t.hascourse = 1;
		t.course = r.track;
	3 =>
		t.hasheading = 1;
		t.heading = r.track;
	}
	if(r.callsign != nil)
		t.name = r.callsign;
	if(r.emitter < len emitters)
		t.category = emitters[r.emitter];
	return t;
}
