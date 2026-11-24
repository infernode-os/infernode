#
# tlspsk(2): a TLS 1.2 client with a pre-shared key and nothing else
# (RFC 4279's PSK key exchange, RFC 7905's TLS_PSK_WITH_CHACHA20_POLY1305_SHA256,
# 0xCCAB), as 9front's tlssrv(8) speaks it after p9any: rcpu(1) and
# rimport(1) take dp9ik's session secret as the key, "p9secret" as its
# identity.  No certificates, no other suites, no renegotiation, no
# resumption.  It is not tls(2) and is used for nothing else.
#
Tlspsk: module
{
	PATH:	con "/dis/lib/tlspsk.dis";

	init:	fn(): string;

	# The handshake over fd; then the conversation is the returned
	# descriptor, one end of a pipe, its other end kept by two
	# processes that seal and open records.  Closing it closes the
	# conversation (close_notify); the far end's close is end of file.
	client:	fn(fd: ref Sys->FD, identity: string, psk: array of byte): (ref Sys->FD, string);
};
