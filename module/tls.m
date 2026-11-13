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

		# A server's connection (server()): the peer's traffic secret is
		# then cts, and a KeyUpdate it sends replaces that
		isserver:	int;
		hsmax:		int;	# the longest handshake message taken; 0: MAXHSMSG
	};

	# Connection (read/write after handshake)
	Conn: adt {
		version:	int;		# negotiated TLS version
		suite:		int;		# negotiated cipher suite
		group:		int;		# TLS 1.3 key-exchange group (X25519MLKEM768, ...); 0 under TLS 1.2
		servername:	string;		# peer name; a server's: the name the client asked for (SNI), or nil
		alpn:		string;		# application protocol agreed (ALPN), or nil
		st:		ref State;	# nil once closed

		read:	fn(c: self ref Conn, buf: array of byte, n: int): int;
		write:	fn(c: self ref Conn, buf: array of byte, n: int): int;
		close:	fn(c: self ref Conn): string;
	};

	# A server's identity and what it offers (server(), TLS 1.3 only)
	ServerConfig: adt {
		certs:		list of array of byte;	# the chain in DER, leaf first
		key:		array of byte;		# the leaf's P-256 private scalar, 32 bytes
		alpn:		list of string;		# protocols taken, in preference order; nil: no ALPN
		maxhello:	int;			# the longest ClientHello taken; 0: 16384
	};

	# Primary API
	client:		fn(fd: ref Sys->FD, config: ref Config): (ref Conn, string);
	# Answer a client on fd: TLS 1.3 alone, X25519MLKEM768, X25519 or
	# P-256 (by HelloRetryRequest), the suites the client puts first,
	# an ECDSA P-256 certificate.  No resumption, no early data.
	server:		fn(fd: ref Sys->FD, config: ref ServerConfig): (ref Conn, string);
	# Whether config can serve: the chain parses, the key is P-256 and
	# is the leaf's (a signature made with it verifies with the leaf's key).
	checkserver:	fn(config: ref ServerConfig): string;
	# The DER of each PEM block labelled label ("CERTIFICATE"), in order
	pemblocks:	fn(pem: string, label: string): list of array of byte;
	# The 32-byte scalar of a P-256 private key in DER: SEC1's
	# ECPrivateKey or PKCS #8's PrivateKeyInfo (OpenSSL writes either)
	p256key:	fn(der: array of byte): (array of byte, string);
	# The descriptors init() opened (its entropy source), for a caller
	# that drops the rest with pctl(NEWFD, ...) and goes on using TLS
	keptfds:	fn(): list of int;
	defaultconfig:	fn(): ref Config;
	# Validate an exact SHA-256 SubjectPublicKeyInfo pin against one DER
	# certificate.  Exposed so provisioning and regression tools use the
	# identical strict parser as the handshake.
	verifyspkipin:	fn(pin, cert: array of byte): string;
};
