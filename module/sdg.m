#
# Styx over datagrams: 9P2000 one message per datagram, secured with
# Noise_IKpsk2_25519_ChaChaPoly_SHA256, with per-request retransmission
# and the server's duplicate reply cache standing in for a byte stream.
# See the styxbrick repository's docs/STYX-DGRAM.md.
#
Sdg: module
{
	PATH:	con "/dis/lib/sdg.dis";
	PORT:	con "5640";

	init:	fn(): string;

	# Keys: our X25519 private key, the server's public key, the PSK
	# (32 bytes each), and the file that keeps the initiation counter
	# monotonic across restarts and clock steps.
	Keys: adt {
		key:	array of byte;
		server:	array of byte;
		psk:	array of byte;
		ctrfile:	string;
	};

	# Handshake with addr (a dial string, udp!host!port), then relay 9P
	# between fd and the session until fd is closed.  Every request gets
	# an answer: the server's reply, or an error made here when its
	# deadline passes ("timed out"; for a write, "outcome unknown"), or
	# when a request the server acknowledged as pending stops being
	# acknowledged ("link down").  Returns nil, or an error if the
	# handshake failed.
	relay:	fn(addr: string, keys: ref Keys, fd: ref Sys->FD): string;

	# Timing (milliseconds): request deadline, first retransmission
	# interval and its cap, retransmission while pending, the silence that
	# means the link is down, and the idle time before a keepalive.
	DEADLINE:	con 5000;
	RTO:	con 40;
	RTOMAX:	con 500;
	KEEP:	con 1000;
	LIVE:	con 5000;
	IDLE:	con 15000;
	MSIZE:	con 1200;
};
