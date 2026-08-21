Publicnet: module {
	PATH: con "/dis/lib/publicnet.dis";

	init: fn();
	# Resolve, reject private/reserved destinations, and return a TCP dial
	# string pinned to the validated IPv4 address.
	dialaddr: fn(host, port: string): (string, string);
	publicipv4: fn(addr: string): int;	# -1 malformed, 0 non-public, 1 public
	transitionallowed: fn(initiator, targetscheme: string): int;

	# Extract the host from a URL, correctly: userinfo before port
	# ("http://user:pass@host/" is host, not "user"), bracketed IPv6
	# preserved. Returns "" if there is no host.
	urlhost: fn(url: string): string;

	# True if `host` names an internal/private/reserved destination and
	# must not be fetched. Covers name forms (localhost, cloud metadata),
	# IPv6 loopback/ULA/link-local, and IPv4 literals in ANY radix —
	# decimal, octal (0177.0.0.1), hex (0x7f.0.0.1), and packed integer
	# forms all resolve to the same address and must all be rejected.
	#
	# This is the ONE definition. Fetch tools must call it rather than
	# keeping private copies: three hand-synchronized copies of this
	# predicate had already drifted apart.
	hostblocked: fn(host: string): int;
};
