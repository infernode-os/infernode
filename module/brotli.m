Brotli: module
{
	PATH:	con "/dis/lib/brotli.dis";
	DICT:	con "/lib/brotli/dictionary.bin";

	# RFC 7932.  size, if not -1, is the length the data must decode to
	# (as WOFF2 gives it), which spares growing the output.
	decompress:	fn(data: array of byte, size: int): (array of byte, string);
};
