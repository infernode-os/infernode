AuditProv: module
{
	PATH:		con "/dis/lib/auditprov.dis";

	# Default dial address of the provenance content store (a local
	# ventisrv(8)). Override with the auditventi environment variable
	# (/env/auditventi); an explicit attach() argument overrides both.
	DEFADDR:	con "tcp!127.0.0.1!17040";
	# get() returns one in-memory array. Refuse hostile vac entries that
	# claim an impractical size before converting big to int or allocating.
	MAXPAYLOAD:	con 64*1024*1024;

	# Payload-bearing records carry exactly these fields, appended by
	# log():  content=<score> sha256=<hex> size=<n>
	# where <score> is the venti score of a packed vac entry (fetch
	# with get() or auditget(1)) and <hex> is the SHA-256 of the raw
	# payload. The score locates; the SHA-256, sealed into the chain,
	# pins — venti's SHA-1 addressing is treated as mechanism only.
	# A record whose payload could not be stored carries
	# content=unstored instead (the event is still sealed).

	init:		fn(): string;

	# attach dials the content store and performs the venti handshake.
	# addr nil/"" resolves via /env/auditventi, then DEFADDR.
	attach:		fn(addr: string): string;

	# dialraw dials without handshaking — for handing the connection
	# fd to a child that will be namespace-restricted: the fd survives
	# pctl(NEWNS); the child completes the handshake with attachfd.
	dialraw:	fn(addr: string): (ref Sys->FD, string);
	attachfd:	fn(fd: ref Sys->FD): string;
	attached:	fn(): int;

	# put stores and syncs a payload as a vac hash tree (Datatype blocks under a
	# packed entry written as a Dirtype block) and returns
	# (score-hex, sha256-hex, error). Identical payloads dedupe.
	put:		fn(data: array of byte): (string, string, string);

	# get fetches a payload back by the score put() returned.
	get:		fn(score: string): (array of byte, string);

	# sha256 of a payload, as the lowercase hex a record carries.
	sha256:		fn(data: array of byte): string;

	# log stores the payload (when non-nil) and seals one audit record:
	#   source event msg content=<score> sha256=<hex> size=<n>
	# Returns 0 on success; -1 if the audit sink is absent or the
	# record write failed (nothing was sealed); -2 if the record was
	# sealed but the payload could not be stored (content=unstored).
	# The caller chooses fail-open or fail-closed — see Audit->ONFILE.
	log:		fn(source, event, msg: string, payload: array of byte): int;
};
