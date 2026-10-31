#
# NMEA 0183: the sentences a GPS receiver sends, assembled into fixes.
# gpsfs(4) is its server; see nmea(2).
#
Nmea: module
{
	PATH:	con "/dis/lib/nmea.dis";

	# fix modes
	Mnone, M2d, M3d: con iota;

	# One position, as the receiver gave it for one time.  A value
	# the receiver did not send is unknown: the has* flags, -1 for a
	# count, a negative real for a dilution or an error.
	Fix: adt {
		date:	string;		# yyyy-mm-dd, or nil
		utc:	string;		# hh:mm:ss or hh:mm:ss.ss, or nil
		valid:	int;		# the receiver says it has a fix
		haspos:	int;
		lat:	real;		# degrees, north positive
		lon:	real;		# degrees, east positive
		hasalt:	int;
		altitude:	real;	# metres above mean sea level
		hasspeed:	int;
		speed:	real;		# metres a second over the ground
		hascourse:	int;
		course:	real;		# degrees true
		mode:	int;		# Mnone, M2d, M3d; -1 unknown
		quality:	string;	# gps dgps pps rtk float dr manual sim, or nil
		sats:	int;		# satellites used
		hdop:	real;
		vdop:	real;
		pdop:	real;
		err:	real;		# horizontal error, metres (1 sigma)
		verr:	real;		# vertical error, metres (1 sigma)

		new:	fn(): ref Fix;
		copy:	fn(f: self ref Fix): ref Fix;
		time:	fn(f: self ref Fix): string;		# RFC 3339, or nil
		text:	fn(f: self ref Fix): string;		# attr=value, no newline
		position:	fn(f: self ref Fix): string;	# "lat lon", or nil
		fixmode:	fn(f: self ref Fix): int;
	};

	# A satellite in view.
	Sat: adt {
		system:	string;		# gps sbas glonass galileo beidou qzss navic gnss
		prn:	int;
		elev:	int;		# degrees, -1 unknown
		azim:	int;		# degrees, -1 unknown
		snr:	int;		# dB-Hz, -1 not tracked
	};

	# Sentences in, fixes out.  A fix is complete when every kind of
	# position sentence the receiver sends (RMC, GGA, GLL) has arrived
	# for one time, or when a sentence for a new time arrives first.
	Parser: adt {
		cur:	ref Fix;	# the time being assembled
		last:	ref Fix;	# the last complete fix, or nil
		epoch:	int;		# times seen
		curtime:	string;
		got:	int;		# kinds of position sentence for curtime
		kinds:	int;		# kinds the receiver has sent
		done:	int;		# cur has been given out
		wasvalid:	int;	# the last fix given out: 1, 0, or -1 for none
		pending:	array of list of ref Sat;	# GSV in progress, by system
		inview:	array of list of ref Sat;	# GSV complete, by system
		used:	list of (string, int);		# from GSA: system, prn
		usedepoch:	int;

		new:	fn(): ref Parser;
		# the fixes the sentence completed (oldest first), or an error
		sentence:	fn(p: self ref Parser, s: string): (list of ref Fix, string);
		satellites:	fn(p: self ref Parser): string;	# one line a satellite
		# a new receiver: forget what the old one sent, keep its last fix
		forget:	fn(p: self ref Parser);
	};

	init:	fn();
	# the sentence's fields, $ and checksum removed, or an error
	fields:	fn(s: string): (array of string, string);
	# the time field of a sentence that has one, or nil
	timeof:	fn(s: string): string;
};
