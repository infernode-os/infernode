#
# rfc3339.m — RFC 3339 timestamp parsing
#
# Inferno's daytime->string2tm only handles RFC822/RFC1123/RFC850/asctime,
# none of which is what users (or HTTP/JMAP/CalDAV/iCalendar) actually
# write. This module parses the RFC 3339 profile of ISO 8601 — the
# "2026-05-10T09:00:00Z" shape — and returns absolute UTC epoch seconds.
#
# Accepted shape:
#   YYYY-MM-DDTHH:MM:SS<TZ>
#   YYYY-MM-DD HH:MM:SS<TZ>           (RFC 3339 §5.6 "alternative space")
#   YYYY-MM-DDTHH:MM:SS.fff<TZ>       (fractional seconds parsed but not retained)
#   <TZ> is one of: Z, z, +HH:MM, -HH:MM
#
# Strict-width fields: each numeric component must be exactly the right
# width and digits-only. A stray letter anywhere fails the parse cleanly
# rather than silently producing the wrong number (which a naive `int "30s"`
# would do).
#

Rfc3339: module
{
	PATH: con "/dis/lib/rfc3339.dis";

	# Lazy-loads daytime. Safe to call repeatedly.
	init: fn();

	# parse: parse an RFC 3339 timestamp into absolute UTC epoch seconds.
	# Returns (epoch_seconds, "") on success, (0, error_string) on failure.
	#
	# Past timestamps are NOT rejected — that policy belongs to the caller
	# (a scheduler may want to refuse the past; a logger may want to accept it).
	#
	# Y2038 caveat: the underlying daytime->tm2epoch returns int (32-bit
	# in Limbo). Timestamps at or after 2038-01-19T03:14:08Z silently
	# wrap to negative. This function does not detect or reject the
	# overflow; callers that schedule far into the future must be aware.
	# Lifting this requires extending daytime to use big — out of scope
	# for the initial RFC 3339 parser.
	parse: fn(s: string): (int, string);
};
