Brotli: module
{
	PATH:	con "/dis/lib/brotli.dis";
	DICT:	con "/lib/brotli/dictionary.bin";

	# RFC 7932.  size, if not -1, is the length the data must decode to
	# (as WOFF2 gives it), which spares growing the output.
	decompress:	fn(data: array of byte, size: int): (array of byte, string);
	# The same for data of no stated length, which may decode to max
	# bytes and no more: past that the answer is (nil, Ebig), and no
	# more than max bytes have been made.  A hundred bytes of Brotli
	# decode to a hundred megabytes.
	decompressmax:	fn(data: array of byte, max: int): (array of byte, string);
	Ebig:	con "brotli: too large";
};
