Parread: module
{
	PATH:	con "/dis/lib/parread.dis";

	# Read len b bytes at off into b with up to ways reads in flight at
	# once, each a pread of a contiguous piece in a process of its own.
	# Over a mount each read is a request of its own, so ways of them
	# overlap their round trips where one read's would follow each
	# other.  Returns the bytes read contiguously from the start (a
	# piece cut short ends it) and the first error in the order of the
	# pieces, nil if none.  ways <= 1, or a buffer too small to share,
	# reads as one pread loop.
	pread:	fn(fd: ref Sys->FD, b: array of byte, off: big, ways: int): (int, string);
};
