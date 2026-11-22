#
# Garmin's Aviation output: what a panel GPS (GNS 430/530, GTN, the
# aera and GPSMAP aviation portables) sends on an RS-232 port set to
# "Aviation", for a fuel computer, an autopilot or an ELT.  Not NMEA.
# gpsfs(4) reads it; see garminav(2).
#
Garminav: module
{
	PATH:	con "/dis/lib/garminav.dis";

	Grouper: adt {
		line:	string;		# the record being read
		fix:	ref Nmea->Fix;	# the group being read
		got:	int;		# records in it
		magtrack:	real;	# C, waiting for Q to make it true
		hastrack:	int;

		new:	fn(): ref Grouper;
		# bytes in, in any pieces: the fixes the groups completed.
		# A fix has no time (the format gives none): the caller
		# stamps it.
		feed:	fn(d: self ref Grouper, b: array of byte): list of ref Nmea->Fix;
	};

	init:	fn(n: Nmea);
};
