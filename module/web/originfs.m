Originfs: module
{
	PATH:	con "/dis/lib/web/originfs.dis";

	# Serve webfs (at the path webfs) on fd, as a page of origin may use
	# it (see originfs.b).  The server forks its own name space, then
	# sends on ready (nil, or why it could not start) and serves until
	# fd hangs up.
	serve:	fn(fd: ref Sys->FD, origin: string, webfs: string, ready: chan of string);

	# A URL's origin as the Fetch standard serializes it: scheme://host,
	# with the port only when it is not the scheme's; "null" for a URL
	# that is not http or https.
	origin:	fn(url: string): string;
};
