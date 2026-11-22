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

	# Every value of a header field (To:, Cc:, Bcc:), each occurrence
	# with its continuation lines unfolded, joined by ", "; "" if the
	# header section has none.
	headerall:	fn(body, field: string): string;

	# The message without the header lines of that field (and their
	# continuation lines): a Bcc: is for the envelope, not the text
	# every recipient gets.
	dropheader:	fn(body, field: string): string;

	# Parse a comma-separated address list. Returns each entry with
	# any surrounding "Name <...>" stripped down to the bare address.
	# A comma inside a quoted name, angle brackets or a comment
	# separates nothing; empty entries are left out.
	parseaddrlist:	fn(s: string): list of string;

	# The factotum keys a send to smtphost may use, in order, for an
	# account whose IMAP server is imaphost: the service=smtp key of
	# the SMTP host, then the IMAP key, but only when the SMTP host is
	# the IMAP host or is one the user named (named != 0).  A host
	# mail9p made up from the IMAP server's name gets no password its
	# key does not name.
	smtpkeys:	fn(imaphost, smtphost: string, named: int): list of string;

	# Strip "Name <addr@dom>" → "addr@dom", trim surrounding
	# whitespace. Plain addresses pass through.
	trimaddr:	fn(s: string): string;

	# Parse a base-10 unsigned integer string into big. Returns
	# big -1 on empty input or any non-digit character.
	strtobig:	fn(s: string): big;
};
