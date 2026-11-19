#
# Reading a live video feed across a network: the feed's live edge kept
# by the clock, and reads that survive a lossy mount.  See livefeed(2).
#
Livefeed: module
{
	PATH:	con "/dis/lib/livefeed.dis";

	# a read answered "reply gone" (sdg(2): its reply lost and gone
	# from the server's cache) is sent again this many times in all
	GONETRIES:	con 3;

	init:	fn();

	# The newest frame feed's status names (frames= less one, or
	# first= when nothing older is kept), and sys->millisec() just
	# before the read that told it was sent.  The frame was made no
	# later than that read reached the feed, so the time is early for
	# it by at most a frame and the read's one way.  (-1, t) when status
	# could not be read.
	status:	fn(feed: string): (int, int);

	# The live edge: the newest frame by the clock, from fps and a
	# frame known to exist at a time.  It is taken from status only by
	# new and again, never on a reader's errors: under loss a status
	# read is itself delayed, and a clock set from every one runs ahead.
	Edge: adt {
		feed:	string;
		fps:	int;
		lf:	int;	# a frame known to exist
		lt:	int;	# by this sys->millisec()

		# nil if status could not be read
		new:	fn(feed: string, fps: int): ref Edge;
		# the newest frame by the clock
		newest:	fn(e: self ref Edge): int;
		# ms until frame n is due (0 or less once it is)
		due:	fn(e: self ref Edge, n: int): int;
		# take the edge from status again (after "frame expired"):
		# 1, or 0 and the edge unchanged if status could not be read
		again:	fn(e: self ref Edge): int;
		# set it from a status read made elsewhere
		set:	fn(e: self ref Edge, lf, lt: int);
	};

	# sys->pread, a read answered "reply gone" sent again (GONETRIES
	# in all).  -1 with the error set (sys->werrstr) as pread's.
	pread:	fn(fd: ref Sys->FD, b: array of byte, n: int, off: big): int;

	# len b bytes at off as ways pieces read at once whatever their
	# size (a frame of a few KB over sdg's 1176-byte reads is several
	# round trips one after another in one loop), each piece's reads
	# by pread above.  Returns the bytes read contiguously from off (a
	# piece cut short ends it) and the first error in the order of the
	# pieces, nil if none, as parread(2).
	read:	fn(fd: ref Sys->FD, b: array of byte, off: big, ways: int): (int, string);
};
