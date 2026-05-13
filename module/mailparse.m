#
# mailparse - parsers shared between mail9p (the 9P server) and its
# tests. Pure functions: no I/O, no state.
#

Mailparse: module
{
	PATH: con "/dis/lib/mailparse.dis";

	init:	fn();

	# Parse "\Seen \Flagged" → (add, remove=0, replace=bits) replace
	# mode, or "+\Seen -\Flagged" → (add, remove, replace=-1) diff
	# mode. Mixing +/- with bare tokens is an error. Errors are
	# returned as a non-nil 4th tuple element.
	parseflagswrite:	fn(s: string): (int, int, int, string);

	# Return the section of an RFC822 message after the first blank
	# line. Handles both CRLF and LF terminators.
	splitbody:		fn(raw: string): string;

	# True iff `body` contains a header line whose first len(field)
	# characters are `field` (case-insensitive). Only checks header
	# region (before first blank line).
	hasheaderfield:	fn(body, field: string): int;

	# True iff `body` contains a CRLF/LF blank line (the RFC822
	# header/body separator).
	bodyhasblankline:	fn(body: string): int;

	# Extract the first header value (trimmed leading whitespace),
	# or "" if not found.
	extractheader:	fn(body, field: string): string;

	# Parse a comma-separated address list. Returns each entry with
	# any surrounding "Name <...>" stripped down to the bare address.
	parseaddrlist:	fn(s: string): list of string;

	# Strip "Name <addr@dom>" → "addr@dom", trim surrounding
	# whitespace. Plain addresses pass through.
	trimaddr:	fn(s: string): string;

	# Parse a base-10 unsigned integer string into big. Returns
	# big -1 on empty input or any non-digit character.
	strtobig:	fn(s: string): big;
};
