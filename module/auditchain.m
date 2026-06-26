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

	# hex renders bytes as lowercase hex (2 chars per byte).
	hex:		fn(h: array of byte): string;

	# unhex is the inverse of hex (even-length lowercase/uppercase hex).
	# Used to carry a checkpoint signature as a single whitespace-free
	# token inside a record line.
	unhex:		fn(s: string): array of byte;
};
