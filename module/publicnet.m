Publicnet: module {
	PATH: con "/dis/lib/publicnet.dis";

	init: fn();
	# Resolve, reject private/reserved destinations, and return a TCP dial
	# string pinned to the validated IPv4 address.
	dialaddr: fn(host, port: string): (string, string);
	publicipv4: fn(addr: string): int;	# -1 malformed, 0 non-public, 1 public
};
