#
# TLS 1.2/1.3 protocol
#

TLS: module {

	PATH: con "/dis/lib/crypt/tls.dis";

	init: fn(): string;

	# TLS versions
	TLS12: con 16r0303;
	TLS13: con 16r0304;

	# Cipher suite IDs
	TLS_RSA_WITH_AES_128_GCM_SHA256:		con 16r009C;
	TLS_RSA_WITH_AES_256_GCM_SHA384:		con 16r009D;
	TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:		con 16rC02F;
	TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:		con 16rC030;
	TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:	con 16rC02B;
	TLS_AES_128_GCM_SHA256:			con 16r1301;
	TLS_AES_256_GCM_SHA384:			con 16r1302;
	TLS_CHACHA20_POLY1305_SHA256:			con 16r1303;

	# Named groups
	X25519:			con 16r001D;
	SECP256R1:		con 16r0017;
	SECP384R1:		con 16r0018;
	X25519MLKEM768:		con 16r11EC;	# 4588 decimal; offered first by default
	SECP384R1MLKEM1024:	con 16r11ED;	# offered alone under /env/cnsatls

	# Signature algorithms
	RSA_PKCS1_SHA256:		con 16r0401;
	RSA_PKCS1_SHA384:		con 16r0501;
	RSA_PKCS1_SHA512:		con 16r0601;
	RSA_PSS_RSAE_SHA256:		con 16r0804;
	RSA_PSS_RSAE_SHA384:		con 16r0805;
	ECDSA_SECP256R1_SHA256:		con 16r0403;
	ECDSA_SECP384R1_SHA384:		con 16r0503;

	# Configuration
	Config: adt {
		suites:		list of int;	# cipher suite IDs (preference order)
		minver:		int;		# minimum TLS version
		maxver:		int;		# maximum TLS version
		servername:	string;		# SNI hostname
		insecure:	int;		# skip cert verification
		clientcert:	array of byte;	# DER certificate offered if the server asks (TLS 1.3); nil: none
		clientkey:	array of byte;	# its raw 32-byte P-256 private scalar
		pinspki:	array of byte;	# SHA-256 of the server's SubjectPublicKeyInfo: replaces chain and name checks
	};

	# A connection's state, its keys among it: tls.b's alone.  It is
	# held by its Conn, not in a table of the module's, so it goes when
	# the Conn does, however its holder stopped (a reader killed
	# mid-read never closes it), and no lock is taken on a read.
	State: adt {
		fd:		ref Sys->FD;
		version:	int;		# negotiated version
		suite:		int;		# negotiated cipher suite
		group:		int;		# TLS 1.3 key-exchange group; 0 under TLS 1.2

		# AEAD keys
		writekey:	array of byte;
		writeiv:	array of byte;
		readkey:	array of byte;
		readiv:		array of byte;

		# Sequence numbers
		writeseq:	big;
		readseq:	big;

		# Read buffer (decrypted application data)
		rbuf:		array of byte;
		roff:		int;
		rlen:		int;

		# The handshake transcript, kept whole for each hash until the suite
		# is known (after a HelloRetryRequest they differ: each begins with
		# message_hash(ClientHello1) by its own hash); hashed when needed
		tr256:		array of byte;	# for SHA-256 suites
		tr384:		array of byte;	# for SHA-384 suites

		# TLS 1.3 traffic secrets
		cts:		array of byte;	# client traffic secret
		sts:		array of byte;	# server traffic secret

		# Server name for cert verification
		servername:	string;
		insecure:	int;
		pinspki:	array of byte;	# pinned server key (Config.pinspki)

		# TLS 1.3: whether handshake is encrypted
		hsencrypted:	int;

		# Handshake message buffer (multiple msgs may arrive in one record)
		hsbuf:		array of byte;
		hsoff:		int;

		# Ephemeral CNSA hybrid (SecP384r1MLKEM1024) private material; nil otherwise
		eph_p384_priv:	array of byte;
		eph_mlkem_sk:	array of byte;

		# Ephemeral ML-KEM-768 secret key for the X25519MLKEM768 share; nil otherwise
		eph_mlkem768_sk:	array of byte;

		# Ephemeral P-256 private key for the TLS 1.3 secp256r1 key share; nil otherwise
		eph_p256_priv:	array of byte;
	};

	# Connection (read/write after handshake)
	Conn: adt {
		version:	int;		# negotiated TLS version
		suite:		int;		# negotiated cipher suite
		group:		int;		# TLS 1.3 key-exchange group (X25519MLKEM768, ...); 0 under TLS 1.2
		servername:	string;		# peer name
		st:		ref State;	# nil once closed

		read:	fn(c: self ref Conn, buf: array of byte, n: int): int;
		write:	fn(c: self ref Conn, buf: array of byte, n: int): int;
		close:	fn(c: self ref Conn): string;
	};

	# Primary API
	client:		fn(fd: ref Sys->FD, config: ref Config): (ref Conn, string);
	defaultconfig:	fn(): ref Config;
};
