Auditchain: module
{
	PATH:	con "/dis/lib/auditchain.dis";

	# Domain-separation tag hashed to form H[0], the chain genesis.
	# Versioned so a future format change starts a distinct chain.
	GENESIS:	con "infernode-audit-v1";

	# SHA-256 digest length (== Keyring->SHA256dlen).
	HASHLEN:	con 32;

	# init must be called once before any other function (loads keyring).
	init:		fn();

	# genesis returns H[0] = SHA-256(GENESIS): the fixed chain anchor.
	genesis:	fn(): array of byte;

	# extend returns H[n] = SHA-256(prev ‖ record): the chain step.
	# Editing, reordering, or deleting any record changes this and every
	# subsequent hash — the tamper-evidence property.
	extend:		fn(prev: array of byte, record: array of byte): array of byte;

	# canon renders the canonical, hashed form of a record's fields
	# (the bytes fed to extend). The stored line inserts the hash between
	# the event and the message; canon omits the hash.
	canon:		fn(seq, t: int, source, event, msg: string): string;

	# The canonical text of a record.  A record is one line of words
	# separated by single blanks; whatever a writer sent, the server
	# puts it in this form once, before it hashes, so that what is
	# hashed, what is stored and what a replay reads back are the same
	# bytes.  "Blank" here is every character that is no visible mark:
	# controls (CR, LF, tab, NUL, DEL, C1), the Unicode spaces and line
	# separators, and the characters that reorder a line on display.
	#
	# token is a source or event: one word, each blank an underscore,
	#	"-" if empty.
	# text is a message: each blank a space, runs of them one, none at
	#	either end.
	# value is one value of a key=value field in a message, when the
	#	text is not the emitter's own (a name a model, a user or a
	#	peer chose): blanks, '=' and '%' are written %XX (%uXXXX from
	#	U+0100), so that the value is one word, holds no key= of its
	#	own and reads back exactly with unvalue.
	token:		fn(s: string): string;
	text:		fn(s: string): string;
	value:		fn(s: string): string;
	unvalue:	fn(s: string): string;

	# record renders the stored line (without its newline); parse reads
	# one back as (seq, time, source, event, hash, msg, ok).  ok is 0
	# unless the line is exactly what record gives for those fields:
	# decimal numbers, a 64-digit lowercase hash, single blanks.
	record:		fn(seq, t: int, source, event, hash, msg: string): string;
	parse:		fn(line: string): (int, int, string, string, string, string, int);

	# hex renders bytes as lowercase hex (2 chars per byte).
	hex:		fn(h: array of byte): string;

	# unhex is the inverse of hex (even-length lowercase/uppercase hex).
	# Used to carry a checkpoint signature as a single whitespace-free
	# token inside a record line.
	unhex:		fn(s: string): array of byte;
};
