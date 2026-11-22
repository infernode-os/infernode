#
# GDL 90: what an ADS-B receiver (Stratux, Stratus, SkyEcho, ...) sends
# an electronic flight bag, usually as UDP datagrams to port 4000: its
# own position and the traffic it hears.  gpsfs(4) reads it; see
# gdl90(2).
#
Gdl90: module
{
	PATH:	con "/dis/lib/gdl90.dis";

	Framer: adt {
		frame:	array of byte;	# the frame being read
		n:	int;
		inframe:	int;
		esc:	int;
		gpsvalid:	int;	# the last heartbeat's GPS position valid bit
		bad:	int;		# frames with a bad CRC

		new:	fn(): ref Framer;
		# bytes in, in any pieces: the own-ship fixes and the traffic
		# they completed.  A fix has no time (GDL 90's heartbeat
		# gives only seconds of the day): the caller stamps it.
		feed:	fn(d: self ref Framer, b: array of byte): (list of ref Nmea->Fix, list of ref Nmea->Target);
	};

	init:	fn(n: Nmea);
	# the CRC-16-CCITT GDL 90 uses
	crc:	fn(b: array of byte): int;
	# a message (its id first) framed: CRC, escapes, flags
	frame:	fn(msg: array of byte): array of byte;
};
