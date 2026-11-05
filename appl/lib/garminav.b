implement Garminav;

#
# Garmin's Aviation output, after the GNS 530 installation manual's
# appendix C (RS-232 aviation data format).  9600 baud, 8N1.  Once a
# second: STX, then records, each an item designator (one letter) and
# its data (one to ten characters) and CR LF, then ETX.  The records
# taken:
#
#	z	GPS altitude, feet
#	A	latitude: N or S, degrees, minutes, hundredths of a minute
#	B	longitude: E or W, degrees, minutes, hundredths
#	C	track, whole degrees, magnetic unless the unit is set to true
#	D	ground speed, knots
#	Q	magnetic variation: E or W, then degrees (tenths implied)
#
# The others (distance, cross track, desired track, waypoint, bearing,
# flags) are navigation, not position, and are passed over.  Data the
# unit does not have is dashes: such a record is passed over, and a
# group without a position is a lost fix.
#
# The manual's examples do not settle whether the fields have blanks
# between their parts or a decimal point, so blanks are ignored and a
# point, if any, is taken: "N 40 4106", "N404106" and "N4041.06" read
# alike.  A group ends at ETX, or at the next z if the ETX was lost.
# The track is made true by adding the variation (east positive),
# which is E00.0 when the unit's heading mode is true.
#

include "sys.m";
	sys: Sys;

include "nmea.m";
	nmea: Nmea;
	Fix: import nmea;

include "garminav.m";

STX: con 16r02;
ETX: con 16r03;
Foot: con 0.3048;
Knot: con 1852.0 / 3600.0;

init(n: Nmea)
{
	sys = load Sys Sys->PATH;
	nmea = n;
}

Grouper.new(): ref Grouper
{
	return ref Grouper("", nil, 0, 0.0, 0);
}

Grouper.feed(d: self ref Grouper, b: array of byte): list of ref Fix
{
	out: list of ref Fix;
	for(i := 0; i < len b; i++) {
		c := int b[i] & 16r7F;
		case c {
		STX =>
			d.line = "";
			d.fix = nil;
			d.got = 0;
			d.hastrack = 0;
		ETX =>
			d.line = "";
			if((f := finish(d)) != nil)
				out = f :: out;
		'\n' or '\r' =>
			if(d.line != "") {
				if(d.line[0] == 'z' && d.got > 0)
					if((f := finish(d)) != nil)
						out = f :: out;
				record(d, d.line);
			}
			d.line = "";
		* =>
			if(len d.line < 32)
				d.line[len d.line] = c;
		}
	}
	r: list of ref Fix;
	for(; out != nil; out = tl out)
		r = hd out :: r;
	return r;
}

# the group read, as a fix, or nil if there was none
finish(d: ref Grouper): ref Fix
{
	f := d.fix;
	n := d.got;
	d.fix = nil;
	d.got = 0;
	if(f == nil || n == 0)
		return nil;
	if(d.hastrack) {
		c := d.magtrack;
		if(f.hasmagvar)
			c += f.magvar;
		while(c < 0.0)
			c += 360.0;
		while(c >= 360.0)
			c -= 360.0;
		f.course = c;
		f.hascourse = 1;
	}
	d.hastrack = 0;
	f.valid = f.haspos;
	if(f.valid)
		f.quality = "gps";
	return f;
}

record(d: ref Grouper, s: string)
{
	if(d.fix == nil)
		d.fix = Fix.new();
	f := d.fix;
	id := s[0];
	v := "";
	for(i := 1; i < len s; i++)
		if(s[i] != ' ')
			v[len v] = s[i];
	if(v == "" || v[0] == '-' && len v > 1 && v[1] == '-') {
		d.got |= 4;	# not available, but the group is not empty
		return;
	}
	case id {
	'z' =>
		(x, ok) := number(v);
		if(ok) {
			f.altitude = x * Foot;
			f.hasalt = 1;
		}
	'A' =>
		(x, ok) := latlon(v, 2, 'N', 'S');
		if(ok) {
			f.lat = x;
			d.got |= 1;
		}
	'B' =>
		(x, ok) := latlon(v, 3, 'E', 'W');
		if(ok) {
			f.lon = x;
			d.got |= 2;
		}
	'C' =>
		(x, ok) := number(v);
		if(ok) {
			d.magtrack = x;
			d.hastrack = 1;
		}
	'D' =>
		(x, ok) := number(v);
		if(ok) {
			f.speed = x * Knot;
			f.hasspeed = 1;
		}
	'Q' =>
		if(v[0] == 'E' || v[0] == 'W') {
			x: real;
			ok: int;
			if(hasdot(v[1:]))
				(x, ok) = number(v[1:]);
			else {
				(x, ok) = number(v[1:]);
				x /= 10.0;
			}
			if(ok) {
				if(v[0] == 'W')
					x = -x;
				f.magvar = x;
				f.hasmagvar = 1;
			}
		}
	* =>
		return;
	}
	d.got |= 4;
	f.haspos = (d.got & 3) == 3;
}

hasdot(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			return 1;
	return 0;
}

# a signed decimal number
number(s: string): (real, int)
{
	if(s == "")
		return (0.0, 0);
	i := 0;
	if(s[0] == '-' || s[0] == '+')
		i++;
	d := 0;
	dot := 0;
	for(; i < len s; i++)
		if(s[i] >= '0' && s[i] <= '9')
			d++;
		else if(s[i] == '.' && !dot)
			dot = 1;
		else
			return (0.0, 0);
	if(d == 0)
		return (0.0, 0);
	return (real s, 1);
}

# N or S (E or W), ndeg digits of degrees, minutes: mm.mm or mmhh
latlon(s: string, ndeg, pos, neg: int): (real, int)
{
	if(len s < 1 + ndeg + 2 || s[0] != pos && s[0] != neg)
		return (0.0, 0);
	deg := s[1:1+ndeg];
	min := s[1+ndeg:];
	(dg, dok) := number(deg);
	if(!dok || hasdot(deg))
		return (0.0, 0);
	m: real;
	ok: int;
	if(hasdot(min))
		(m, ok) = number(min);
	else {
		(m, ok) = number(min);
		if(len min > 2)
			for(i := 2; i < len min; i++)
				m /= 10.0;	# mmhh: hundredths implied
	}
	if(!ok || m >= 60.0)
		return (0.0, 0);
	x := dg + m / 60.0;
	if(x > real (90 * (ndeg - 1)))	# 90 or 180
		return (0.0, 0);
	if(s[0] == neg)
		x = -x;
	return (x, 1);
}
