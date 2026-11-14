implement TLS;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	keyring: Keyring;
	IPint, DigestState: import keyring;

include "asn1.m";
	asn1: ASN1;
	Elem, Tag: import asn1;

include "pkcs.m";
	pkcs: PKCS;
	RSAKey: import PKCS;

include "x509.m";
	x509: X509;
	Signed, Certificate, SubjectPKInfo, PublicKey, ExtClass: import x509;

include "ip.m";
	ip: IP;
	IPaddr: import ip;

include "tls.m";

# Record content types
CT_CHANGE_CIPHER_SPEC:	con 20;
CT_ALERT:		con 21;
CT_HANDSHAKE:		con 22;
CT_APPLICATION_DATA:	con 23;

# Handshake message types
HT_CLIENT_HELLO:		con 1;
HT_SERVER_HELLO:		con 2;
HT_NEW_SESSION_TICKET:		con 4;
HT_ENCRYPTED_EXTENSIONS:	con 8;
HT_CERTIFICATE:			con 11;
HT_SERVER_KEY_EXCHANGE:		con 12;
HT_CERTIFICATE_REQUEST:		con 13;
HT_SERVER_HELLO_DONE:		con 14;
HT_CERTIFICATE_VERIFY:		con 15;
HT_CLIENT_KEY_EXCHANGE:		con 16;
HT_FINISHED:			con 20;
HT_KEY_UPDATE:			con 24;
HT_MESSAGE_HASH:		con 254;	# RFC 8446 §4.4.1: stands for ClientHello1 after a HelloRetryRequest

# Alert levels
ALERT_WARNING:	con 1;
ALERT_FATAL:	con 2;

# Alert descriptions
ALERT_CLOSE_NOTIFY:		con 0;
ALERT_UNEXPECTED_MESSAGE:	con 10;
ALERT_BAD_RECORD_MAC:		con 20;
ALERT_HANDSHAKE_FAILURE:	con 40;
ALERT_BAD_CERTIFICATE:		con 42;
ALERT_CERTIFICATE_EXPIRED:	con 45;
ALERT_CERTIFICATE_UNKNOWN:	con 46;
ALERT_ILLEGAL_PARAMETER:	con 47;
ALERT_DECODE_ERROR:		con 50;
ALERT_DECRYPT_ERROR:		con 51;
ALERT_PROTOCOL_VERSION:		con 70;
ALERT_INTERNAL_ERROR:		con 80;
ALERT_INSUFFICIENT_SECURITY:	con 71;
ALERT_MISSING_EXTENSION:	con 109;
ALERT_UNRECOGNIZED_NAME:	con 112;
ALERT_NO_APPLICATION_PROTOCOL:	con 120;

# Extension types
EXT_SERVER_NAME:		con 0;
EXT_SUPPORTED_GROUPS:		con 10;
EXT_SIGNATURE_ALGORITHMS:	con 13;
EXT_ALPN:			con 16;
EXT_PRE_SHARED_KEY:		con 41;
EXT_SUPPORTED_VERSIONS:		con 43;
EXT_COOKIE:			con 44;
EXT_KEY_SHARE:			con 51;

# Named groups
GROUP_SECP256R1:	con 16r0017;
GROUP_SECP384R1:	con 16r0018;
GROUP_X25519:		con 16r001D;
GROUP_X25519MLKEM768:	con 16r11EC;	# hybrid: ML-KEM-768 + X25519 (4588 decimal), offered by default
GROUP_SECP384R1MLKEM1024: con 16r11ED;	# CNSA 2.0 hybrid: P-384 ECDH + ML-KEM-1024
P384_POINTLEN:		con 97;		# SEC1 uncompressed point (0x04||x||y)
MLKEM768_EKLEN:		con 1184;	# ML-KEM-768 encapsulation key
MLKEM768_CTLEN:		con 1088;	# ML-KEM-768 ciphertext
MLKEM1024_EKLEN:	con 1568;	# ML-KEM-1024 encapsulation key
MLKEM1024_CTLEN:	con 1568;	# ML-KEM-1024 ciphertext

# A ServerHello with this random is a HelloRetryRequest (RFC 8446 §4.1.3):
# SHA-256("HelloRetryRequest")
HRRRANDOM: con "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c";

# Max record size
MAXRECORD:	con 16384;
MAXHSMSG:	con 1<<18;	# a handshake message, however many records it takes (certificate chains run to tens of kilobytes)
MAXFRAGMENT:	con 16384 + 256;	# room for overhead

# TLS 1.2 record version
RECVERSION: con 16r0303;

# A connection's state is TLS->State (tls.m), held by its Conn: dropped
# with it, wherever its holder stops (a reader killed mid-read included).
ConnState: type State;

# Entropy source fd, opened once in init() and reused for all randombuf() calls.
#
# ENTROPY SOURCE SELECTION — SECURITY NOTE
#
# This module runs in two distinct environments with different entropy capabilities:
#
#   1. emu (Inferno hosted on macOS/Linux):
#        #c/notquiterandom  →  prng() → arc4random_buf() / getrandom()
#        This is a full OS CSPRNG (ChaCha20) seeded from hardware entropy.
#        Fast (nanoseconds per call) and cryptographically secure.
#
#   2. Bare-metal Inferno (no host OS):
#        #c/notquiterandom is backed by libsec genrandom, which may have
#        limited entropy on minimal hardware.
#        #c/random uses timing jitter between two kprocs and is the
#        traditional Inferno entropy source for bare metal.
#
# The open() priority order below handles both environments:
#
#   First:  #c/notquiterandom  — fast OS CSPRNG when running under an OS
#   Second: /dev/urandom       — POSIX fallback (works if host /dev is bound)
#   Third:  #c/random          — timing-based entropy; slow (~80ms/byte) but
#                                correct for bare-metal Inferno where no OS
#                                CSPRNG is available
#
# The name "#c/notquiterandom" is a historical Inferno convention from when
# it was a simple LCG.  In this codebase it has been upgraded to delegate to
# the OS CSPRNG via prng() in libsec/prng.c.  See emu/port/random.c and
# docs/TLS-ENTROPY.md for the full picture.
randomfd: ref Sys->FD;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "tls: cannot load Sys";

	keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		return "tls: cannot load Keyring";

	asn1 = load ASN1 ASN1->PATH;
	if(asn1 == nil)
		return "tls: cannot load ASN1";
	asn1->init();

	pkcs = load PKCS PKCS->PATH;
	if(pkcs == nil)
		return "tls: cannot load PKCS";
	pkcs->init();

	x509 = load X509 X509->PATH;
	if(x509 == nil)
		return "tls: cannot load X509";
	x509->init();

	# Open entropy source once; reuse fd for all subsequent randombuf() calls.
	# See the ENTROPY SOURCE SELECTION comment above randomfd for the full rationale.
	randomfd = sys->open("#c/notquiterandom", Sys->OREAD);
	if(randomfd == nil)
		randomfd = sys->open("/dev/urandom", Sys->OREAD);
	if(randomfd == nil)
		randomfd = sys->open("#c/random", Sys->OREAD);

	return nil;
}

defaultconfig(): ref Config
{
	return ref Config(
		TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 ::
		TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 ::
		TLS_AES_128_GCM_SHA256 ::
		TLS_AES_256_GCM_SHA384 ::
		TLS_CHACHA20_POLY1305_SHA256 ::
		TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 ::
		TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 ::
		TLS_RSA_WITH_AES_128_GCM_SHA256 ::
		nil,			# suites
		TLS12,		# minver
		TLS13,		# maxver
		"",			# servername
		0,			# insecure
		nil,			# clientcert
		nil,			# clientkey
		nil			# pinspki
	);
}

client(fd: ref Sys->FD, config: ref Config): (ref Conn, string)
{
	cs := ref ConnState;
	cs.fd = fd;
	cs.version = 0;
	cs.suite = 0;
	cs.writeseq = big 0;
	cs.readseq = big 0;
	cs.rbuf = nil;
	cs.roff = 0;
	cs.rlen = 0;
	cs.tr256 = nil;
	cs.tr384 = nil;
	cs.cts = nil;
	cs.sts = nil;
	cs.servername = config.servername;
	cs.insecure = config.insecure;
	cs.pinspki = config.pinspki;
	cs.hsencrypted = 0;
	cs.hsbuf = nil;
	cs.hsoff = 0;

	err := handshake(cs, config);
	if(err != nil)
		return (nil, err);

	conn := ref Conn;
	conn.version = cs.version;
	conn.suite = cs.suite;
	conn.group = cs.group;
	conn.servername = cs.servername;
	conn.st = cs;

	return (conn, nil);
}

Conn.read(conn: self ref Conn, buf: array of byte, n: int): int
{
	cs := conn.st;
	if(cs == nil)
		return -1;

	# Return buffered data first
	if(cs.rlen > 0) {
		m := cs.rlen;
		if(m > n)
			m = n;
		buf[0:] = cs.rbuf[cs.roff:cs.roff+m];
		cs.roff += m;
		cs.rlen -= m;
		return m;
	}

	# Read next record
	for(;;) {
		(ctype, data, err) := readrecord(cs);
		if(err != nil)
			return -1;

		case ctype {
		CT_APPLICATION_DATA =>
			m := len data;
			if(m > n)
				m = n;
			buf[0:] = data[0:m];
			if(m < len data) {
				cs.rbuf = data;
				cs.roff = m;
				cs.rlen = len data - m;
			}
			return m;

		CT_ALERT =>
			if(len data >= 2 && int data[1] == ALERT_CLOSE_NOTIFY)
				return 0;
			return -1;

		CT_HANDSHAKE =>
			# Post-handshake messages: a KeyUpdate changes the
			# peer's keys (RFC 8446 §4.6.3); a server's
			# NewSessionTicket is not used.  A client may send a
			# server nothing else.
			if(posthandshake(cs, data) < 0)
				return -1;

		* =>
			return -1;
		}
	}
}

Conn.write(conn: self ref Conn, buf: array of byte, n: int): int
{
	cs := conn.st;
	if(cs == nil)
		return -1;

	sent := 0;
	while(sent < n) {
		chunk := n - sent;
		if(chunk > MAXRECORD)
			chunk = MAXRECORD;
		err := writerecord(cs, CT_APPLICATION_DATA, buf[sent:sent+chunk]);
		if(err != nil)
			return -1;
		sent += chunk;
	}
	return sent;
}

Conn.close(conn: self ref Conn): string
{
	cs := conn.st;
	if(cs == nil)
		return "tls: connection closed";

	# Send close_notify alert
	alert := array [2] of byte;
	alert[0] = byte ALERT_WARNING;
	alert[1] = byte ALERT_CLOSE_NOTIFY;
	conn.st = nil;
	writerecord(cs, CT_ALERT, alert);
	return nil;
}

# ================================================================
# TLS Record Layer
# ================================================================

# Read a single TLS record, decrypt if keys are set
readrecord(cs: ref ConnState): (int, array of byte, string)
{
	# Read 5-byte header: content_type(1) + version(2) + length(2)
	hdr := array [5] of byte;
	if(ensure(cs.fd, hdr, 5) < 0)
		return (0, nil, "tls: record read failed");

	ctype := int hdr[0];
	length := (int hdr[3] << 8) | int hdr[4];

	if(length > MAXFRAGMENT)
		return (0, nil, "tls: record too large");

	# Read payload
	payload := array [length] of byte;
	if(ensure(cs.fd, payload, length) < 0)
		return (0, nil, "tls: record payload read failed");

	# TLS 1.3 middlebox compatibility: CCS records are always plaintext
	# (RFC 8446 §5). Don't try to decrypt them.
	if(ctype == CT_CHANGE_CIPHER_SPEC)
		return (ctype, payload, nil);

	# Decrypt if keys are established
	if(cs.readkey != nil) {
		(plaintext, err) := decrypt_record(cs, ctype, payload);
		if(err != nil)
			return (0, nil, err);

		if(cs.version == TLS13) {
			# TLS 1.3: inner content type is last byte of plaintext
			# Strip padding zeros from end
			i := len plaintext - 1;
			while(i >= 0 && int plaintext[i] == 0)
				i--;
			if(i < 0)
				return (0, nil, "tls: empty inner plaintext");
			ctype = int plaintext[i];
			plaintext = plaintext[0:i];
		}

		return (ctype, plaintext, nil);
	}

	return (ctype, payload, nil);
}

# Write a TLS record, encrypt if keys are set
writerecord(cs: ref ConnState, ctype: int, data: array of byte): string
{
	payload := data;

	if(cs.writekey != nil) {
		plaintext := data;
		if(cs.version == TLS13) {
			# TLS 1.3: append real content type
			plaintext = array [len data + 1] of byte;
			plaintext[0:] = data;
			plaintext[len data] = byte ctype;
			ctype = CT_APPLICATION_DATA;
		}
		(ciphertext, err) := encrypt_record(cs, ctype, plaintext);
		if(err != nil)
			return err;
		payload = ciphertext;
	}

	# Build record: type(1) + version(2) + length(2) + payload
	rec := array [5 + len payload] of byte;
	rec[0] = byte ctype;
	put16(rec, 1, RECVERSION);
	put16(rec, 3, len payload);
	rec[5:] = payload;

	n := sys->write(cs.fd, rec, len rec);
	if(n != len rec)
		return "tls: write failed";

	return nil;
}

# ================================================================
# AEAD Encryption/Decryption
# ================================================================

# Build nonce for AEAD: XOR fixed IV with sequence number
buildnonce(iv: array of byte, seq: big): array of byte
{
	nonce := array [12] of byte;
	nonce[0:] = iv;

	# XOR sequence number into rightmost 8 bytes
	for(i := 0; i < 8; i++) {
		shift := 56 - i * 8;
		nonce[4 + i] ^= byte (int (seq >> shift) & 16rFF);
	}
	return nonce;
}

encrypt_record(cs: ref ConnState, ctype: int, plaintext: array of byte): (array of byte, string)
{
	nonce: array of byte;
	aad: array of byte;
	explicit_nonce: array of byte;

	if(cs.version == TLS13) {
		# TLS 1.3: implicit nonce (IV XOR seq), 5-byte AAD
		nonce = buildnonce(cs.writeiv, cs.writeseq);
		aad = array [5] of byte;
		aad[0] = byte ctype;
		put16(aad, 1, RECVERSION);
		put16(aad, 3, len plaintext + 16);
	} else if(!isccpoly(cs.suite)) {
		# TLS 1.2 AES-GCM (RFC 5288): 8-byte explicit nonce prepended to record
		explicit_nonce = array [8] of byte;
		put64(explicit_nonce, 0, cs.writeseq);
		nonce = array [12] of byte;
		nonce[0:] = cs.writeiv[0:4];	# 4-byte fixed IV from key material
		nonce[4:] = explicit_nonce;	# 8-byte explicit nonce
		aad = array [13] of byte;
		put64(aad, 0, cs.writeseq);
		aad[8] = byte ctype;
		put16(aad, 9, RECVERSION);
		put16(aad, 11, len plaintext);
	} else {
		# TLS 1.2 ChaCha20-Poly1305 (RFC 7905): implicit nonce, 13-byte AAD
		nonce = buildnonce(cs.writeiv, cs.writeseq);
		aad = array [13] of byte;
		put64(aad, 0, cs.writeseq);
		aad[8] = byte ctype;
		put16(aad, 9, RECVERSION);
		put16(aad, 11, len plaintext);
	}

	ct: array of byte;
	tag: array of byte;

	if(isccpoly(cs.suite)) {
		(ct, tag) = keyring->ccpolyencrypt(plaintext, aad, cs.writekey, nonce);
	} else {
		gcmstate := keyring->aesgcmsetup(cs.writekey, nonce);
		if(gcmstate == nil)
			return (nil, "tls: aesgcm setup failed");
		(ct, tag) = keyring->aesgcmencrypt(gcmstate, plaintext, aad);
	}

	if(ct == nil || tag == nil)
		return (nil, "tls: encrypt failed");

	# TLS 1.2 AES-GCM: prepend explicit nonce; otherwise ct|tag only
	result: array of byte;
	if(explicit_nonce != nil) {
		result = array [8 + len ct + len tag] of byte;
		result[0:] = explicit_nonce;
		result[8:] = ct;
		result[8 + len ct:] = tag;
	} else {
		result = array [len ct + len tag] of byte;
		result[0:] = ct;
		result[len ct:] = tag;
	}

	cs.writeseq++;
	return (result, nil);
}

decrypt_record(cs: ref ConnState, ctype: int, ciphertext: array of byte): (array of byte, string)
{
	nonce: array of byte;
	ct, tag, aad: array of byte;

	if(cs.version == TLS13) {
		if(len ciphertext < 16)
			return (nil, "tls: ciphertext too short");
		nonce = buildnonce(cs.readiv, cs.readseq);
		ctlen := len ciphertext - 16;
		ct = ciphertext[0:ctlen];
		tag = ciphertext[ctlen:];
		aad = array [5] of byte;
		aad[0] = byte ctype;
		put16(aad, 1, RECVERSION);
		put16(aad, 3, len ciphertext);
	} else if(!isccpoly(cs.suite)) {
		# TLS 1.2 AES-GCM (RFC 5288): first 8 bytes of payload are explicit nonce
		if(len ciphertext < 8 + 16)
			return (nil, "tls: ciphertext too short");
		explicit_nonce := ciphertext[0:8];
		nonce = array [12] of byte;
		nonce[0:] = cs.readiv[0:4];	# 4-byte fixed IV from key material
		nonce[4:] = explicit_nonce;	# 8-byte explicit nonce from record
		ctlen := len ciphertext - 8 - 16;
		ct = ciphertext[8:8+ctlen];
		tag = ciphertext[8+ctlen:];
		aad = array [13] of byte;
		put64(aad, 0, cs.readseq);
		aad[8] = byte ctype;
		put16(aad, 9, RECVERSION);
		put16(aad, 11, ctlen);
	} else {
		# TLS 1.2 ChaCha20-Poly1305 (RFC 7905): implicit nonce, 13-byte AAD
		if(len ciphertext < 16)
			return (nil, "tls: ciphertext too short");
		nonce = buildnonce(cs.readiv, cs.readseq);
		ctlen := len ciphertext - 16;
		ct = ciphertext[0:ctlen];
		tag = ciphertext[ctlen:];
		aad = array [13] of byte;
		put64(aad, 0, cs.readseq);
		aad[8] = byte ctype;
		put16(aad, 9, RECVERSION);
		put16(aad, 11, ctlen);
	}

	plaintext: array of byte;

	if(isccpoly(cs.suite)) {
		plaintext = keyring->ccpolydecrypt(ct, aad, tag, cs.readkey, nonce);
	} else {
		gcmstate := keyring->aesgcmsetup(cs.readkey, nonce);
		if(gcmstate == nil)
			return (nil, "tls: aesgcm setup failed");
		plaintext = keyring->aesgcmdecrypt(gcmstate, ct, aad, tag);
	}

	if(plaintext == nil)
		return (nil, "tls: decrypt/auth failed");

	cs.readseq++;
	return (plaintext, nil);
}

isccpoly(suite: int): int
{
	return suite == TLS_CHACHA20_POLY1305_SHA256;
}

# ================================================================
# Handshake
# ================================================================

# CNSA 2.0 strict TLS: read the /env/cnsatls policy flag (off by default; the
# emu reflects the host CNSATLS into it). When set, the TLS client offers only
# the SecP384r1MLKEM1024 hybrid (P-384 is the CNSA-approved curve; X25519 is
# not) and refuses any server that will not take it. Public servers do not, so
# this is for networks whose TLS servers are all your own. It is apart from
# /env/cnsamode, which governs the native STS handshake between nodes: a node
# can be CNSA-strict to its peers and still reach the web.
cnsatls(): int
{
	fd := sys->open("/env/cnsatls", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	c := int buf[0];
	return c != '0' && c != 'n' && c != 'N' && c != '\n';
}

wipebytes(a: array of byte)
{
	if(a == nil)
		return;
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

strictcnsaconfig(config: ref Config)
{
	config.suites = TLS_AES_256_GCM_SHA384 :: nil;
	config.minver = TLS13;
	config.maxver = TLS13;
}

# Wipe whatever ephemeral key material this handshake made.
clearephemeral(cs: ref ConnState)
{
	wipebytes(cs.eph_p384_priv);
	wipebytes(cs.eph_mlkem_sk);
	wipebytes(cs.eph_mlkem768_sk);
	wipebytes(cs.eph_p256_priv);
	cs.eph_p384_priv = nil;
	cs.eph_mlkem_sk = nil;
	cs.eph_mlkem768_sk = nil;
	cs.eph_p256_priv = nil;
}

handshake(cs: ref ConnState, config: ref Config): string
{
	e := handshake0(cs, config);
	clearephemeral(cs);
	return e;
}

handshake0(cs: ref ConnState, config: ref Config): string
{
	# A new transcript
	cs.tr256 = nil;
	cs.tr384 = nil;

	# Generate client random, and the legacy session id, both of which
	# a second ClientHello after a HelloRetryRequest repeats
	client_random := randombytes(32);
	session_id := randombytes(32);

	# Key exchange: only the CNSA hybrid (SecP384r1MLKEM1024) when
	# /env/cnsatls is set; else the X25519MLKEM768 hybrid first, then
	# X25519.  P-256 and P-384 are offered in supported_groups but get
	# no share until a server asks for one by HelloRetryRequest: a
	# share costs a scalar multiplication, and most servers take
	# X25519 or the hybrid.
	x25519_priv: array of byte;
	x25519_pub: array of byte;
	groups: list of int;			# supported_groups, in preference order
	shares: list of (int, array of byte);	# key_share entries sent
	cnsa := cnsatls();
	if(cnsa){
		strictcnsaconfig(config);
		(p384priv, p384pub) := keyring->p384_keygen();
		(mlkem_ek, mlkem_sk) := keyring->mlkem1024_keygen();
		if(p384priv == nil || p384pub == nil || mlkem_ek == nil || mlkem_sk == nil)
			return "tls: CNSA hybrid keygen failed";
		cs.eph_p384_priv = p384priv;
		cs.eph_mlkem_sk = mlkem_sk;
		# key_share entry: P-384 point (97) || ML-KEM-1024 ek (1568)
		groups = GROUP_SECP384R1MLKEM1024 :: nil;
		shares = (GROUP_SECP384R1MLKEM1024, catbytes(p384pub, mlkem_ek)) :: nil;
	}else{
		x25519_priv = randombytes(32);
		x25519_pub = keyring->x25519_base(x25519_priv);
		groups = GROUP_X25519 :: GROUP_SECP256R1 :: GROUP_SECP384R1 :: nil;
		shares = (GROUP_X25519, x25519_pub) :: nil;
		# The post-quantum hybrid, preferred: ML-KEM-768 ek (1184) ||
		# X25519 (32), the X25519 key shared with the plain X25519
		# share (draft-ietf-tls-ecdhe-mlkem allows it, as browsers do).
		(mlkem_ek, mlkem_sk) := keyring->mlkem768_keygen();
		if(mlkem_ek != nil && mlkem_sk != nil) {
			cs.eph_mlkem768_sk = mlkem_sk;
			groups = GROUP_X25519MLKEM768 :: groups;
			shares = (GROUP_X25519MLKEM768, catbytes(mlkem_ek, x25519_pub)) :: shares;
		}
	}

	# Build and send ClientHello
	hello := buildclienthello(config, client_random, session_id, groups, shares, nil);
	err := sendhsmsg(cs, HT_CLIENT_HELLO, hello);
	if(err != nil)
		return err;

	# Read ServerHello
	(shtype, shdata, sherr) := readhsmsg(cs);
	if(sherr != nil)
		return sherr;
	if(shtype != HT_SERVER_HELLO)
		return "tls: expected ServerHello";

	# A HelloRetryRequest (RFC 8446 §4.1.4): the server wants a share
	# for another group we offered, a cookie echoed, or both.  Answer
	# with a second ClientHello, the same but for those (§4.1.2).
	hrrsuite := 0;
	hrrgroup := 0;
	if(ishrr(shdata)) {
		(suite, group, cookie, herr) := parsehrr(shdata, session_id, config, groups, shares);
		if(herr != nil)
			return herr;
		hrrsuite = suite;
		hrrgroup = group;
		cs.suite = suite;
		cs.version = TLS13;

		# the transcript begins again: ClientHello1 stands as its
		# hash in a message_hash message, then the HRR (§4.4.1)
		hrrtranscript(cs, hsmsg(HT_CLIENT_HELLO, hello), hsmsg(HT_SERVER_HELLO, shdata));

		if(group != 0) {
			(share, serr) := keyshare(cs, group);
			if(serr != nil)
				return serr;
			shares = (group, share) :: nil;
		}
		hello = buildclienthello(config, client_random, session_id, groups, shares, cookie);
		err = sendhsmsg(cs, HT_CLIENT_HELLO, hello);
		if(err != nil)
			return err;

		(shtype, shdata, sherr) = readhsmsg(cs);
		if(sherr != nil)
			return sherr;
		if(shtype != HT_SERVER_HELLO)
			return "tls: expected ServerHello";
		if(ishrr(shdata))
			return "tls: second HelloRetryRequest";
	}

	# Parse ServerHello
	(server_random, server_suite, server_version, key_share_group, key_share_data, pherr) := parseserverhello(shdata, config);
	if(pherr != nil)
		return pherr;

	if(hrrsuite != 0) {
		# §4.1.4: the ServerHello must agree with the HRR
		if(server_version != TLS13)
			return "tls: ServerHello after HelloRetryRequest is not TLS 1.3";
		if(server_suite != hrrsuite)
			return "tls: ServerHello cipher suite differs from HelloRetryRequest's";
		if(hrrgroup != 0 && key_share_group != hrrgroup)
			return "tls: ServerHello key share differs from HelloRetryRequest's group";
	}

	cs.version = server_version;
	cs.suite = server_suite;
	if(cs.version == TLS13) {
		cs.group = key_share_group;
		# the server's share must answer one we sent (§4.2.8)
		if(sharefor(shares, key_share_group) == nil)
			return sys->sprint("tls: server chose key share group 0x%04x, which we did not send", key_share_group);
	}

	if(cnsa) {
		if(cs.version != TLS13)
			return "tls: CNSA mode requires TLS 1.3";
		if(cs.suite != TLS_AES_256_GCM_SHA384)
			return "tls: CNSA mode requires TLS_AES_256_GCM_SHA384";
		if(key_share_group != GROUP_SECP384R1MLKEM1024)
			return "tls: CNSA mode requires SecP384r1MLKEM1024";
	}

	if(cs.version == TLS13)
		return handshake13(cs, config, client_random, server_random,
			x25519_priv, key_share_group, key_share_data);
	return handshake12(cs, config, client_random, server_random,
		x25519_priv);
}

# ================================================================
# HelloRetryRequest (RFC 8446 §4.1.4)
# ================================================================

ishrr(shdata: array of byte): int
{
	if(len shdata < 34)
		return 0;
	return hexstr(shdata[2:34]) == HRRRANDOM;
}

hexstr(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

# The share entry sent for group, or nil.
sharefor(shares: list of (int, array of byte), group: int): array of byte
{
	for(; shares != nil; shares = tl shares) {
		(g, d) := hd shares;
		if(g == group)
			return d;
	}
	return nil;
}

# Parse a HelloRetryRequest: (cipher suite, selected group or 0, cookie or nil, error).
# It must name a TLS 1.3 suite we offered, echo our session id, carry only
# extensions we sent, and change something in the ClientHello: select a
# group we offered without a share, or send a cookie, or both.
parsehrr(data: array of byte, session_id: array of byte, config: ref Config,
	groups: list of int, shares: list of (int, array of byte)): (int, int, array of byte, string)
{
	if(len data < 38)
		return (0, 0, nil, "tls: HelloRetryRequest too short");
	off := 34;	# legacy_version(2) + random(32)
	sid_len := int data[off++];
	if(off + sid_len + 3 > len data)
		return (0, 0, nil, "tls: HelloRetryRequest truncated");
	if(!bytescmp(data[off:off+sid_len], session_id))
		return (0, 0, nil, "tls: HelloRetryRequest does not echo our session id");
	off += sid_len;
	suite := get16(data, off);
	off += 2;
	if(int data[off++] != 0)
		return (0, 0, nil, "tls: non-null compression");

	if(off + 2 > len data)
		return (0, 0, nil, "tls: HelloRetryRequest has no extensions");
	ext_end := off + 2 + get16(data, off);
	off += 2;
	if(ext_end != len data)
		return (0, 0, nil, "tls: HelloRetryRequest extensions truncated");

	version := 0;
	group := 0;
	cookie: array of byte;
	seen := 0;
	while(off < ext_end) {
		if(off + 4 > ext_end)
			return (0, 0, nil, "tls: HelloRetryRequest extension truncated");
		etype := get16(data, off);
		elen := get16(data, off + 2);
		off += 4;
		if(off + elen > ext_end)
			return (0, 0, nil, "tls: HelloRetryRequest extension truncated");
		bit := 0;
		case etype {
		EXT_SUPPORTED_VERSIONS =>
			bit = 1;
			if(elen != 2)
				return (0, 0, nil, "tls: bad supported_versions in HelloRetryRequest");
			version = get16(data, off);
		EXT_KEY_SHARE =>
			bit = 2;
			if(elen != 2)
				return (0, 0, nil, "tls: bad key_share in HelloRetryRequest");
			group = get16(data, off);
		EXT_COOKIE =>
			bit = 4;
			if(elen < 3 || get16(data, off) != elen - 2)
				return (0, 0, nil, "tls: bad cookie in HelloRetryRequest");
			cookie = data[off+2:off+elen];
		* =>
			return (0, 0, nil, sys->sprint("tls: HelloRetryRequest has extension %d we did not send", etype));
		}
		if(seen & bit)
			return (0, 0, nil, sys->sprint("tls: HelloRetryRequest repeats extension %d", etype));
		seen |= bit;
		off += elen;
	}

	if(version != TLS13)
		return (0, 0, nil, "tls: HelloRetryRequest is not TLS 1.3");
	if((suite >> 8) != 16r13 || !member(config.suites, suite))
		return (0, 0, nil, sys->sprint("tls: HelloRetryRequest chose unsupported suite 0x%04x", suite));
	if(group != 0) {
		if(!member(groups, group))
			return (0, 0, nil, sys->sprint("tls: HelloRetryRequest selected group 0x%04x, which we did not offer", group));
		if(sharefor(shares, group) != nil)
			return (0, 0, nil, sys->sprint("tls: HelloRetryRequest selected group 0x%04x, which we sent a share for", group));
	}else if(cookie == nil)
		return (0, 0, nil, "tls: HelloRetryRequest asks for no change");
	return (suite, group, cookie, nil);
}

member(l: list of int, x: int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}

# A share for group, made when a HelloRetryRequest asks for it.
keyshare(cs: ref ConnState, group: int): (array of byte, string)
{
	case group {
	GROUP_SECP256R1 =>
		(priv, pt) := keyring->p256_keygen();
		if(priv == nil || pt == nil)
			return (nil, "tls: P-256 key generation failed");
		cs.eph_p256_priv = priv;
		return (keyring->p256_point_bytes(pt), nil);
	GROUP_SECP384R1 =>
		(priv, pub) := keyring->p384_keygen();
		if(priv == nil || pub == nil)
			return (nil, "tls: P-384 key generation failed");
		cs.eph_p384_priv = priv;
		return (pub, nil);
	}
	return (nil, sys->sprint("tls: no key share for group 0x%04x", group));
}

# After a HelloRetryRequest the transcript is message_hash(ClientHello1)
# followed by the HRR (RFC 8446 §4.4.1), each transcript hashing
# ClientHello1 with its own algorithm.
hrrtranscript(cs: ref ConnState, ch1, hrr: array of byte)
{
	h256 := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(ch1, len ch1, h256, nil);
	h384 := array[Keyring->SHA384dlen] of byte;
	keyring->sha384(ch1, len ch1, h384, nil);
	m256 := hsmsg(HT_MESSAGE_HASH, h256);
	m384 := hsmsg(HT_MESSAGE_HASH, h384);
	cs.tr256 = trcat(m256, hrr);
	cs.tr384 = trcat(m384, hrr);
}

# A handshake message: type(1) + length(3) + body
hsmsg(mtype: int, data: array of byte): array of byte
{
	msg := array [4 + len data] of byte;
	msg[0] = byte mtype;
	put24(msg, 1, len data);
	msg[4:] = data;
	return msg;
}

# ================================================================
# TLS 1.2 Handshake
# ================================================================

handshake12(cs: ref ConnState, config: ref Config,
	client_random, server_random: array of byte,
	x25519_priv: array of byte): string
{
	server_certs: list of array of byte;
	server_pubkey: array of byte;
	server_ecpoint: array of byte;
	server_curve := 0;
	uses_ecdhe := 0;

	# Read server messages until ServerHelloDone
	got_server_done := 0;
	while(!got_server_done) {
		(mtype, mdata, merr) := readhsmsg(cs);
		if(merr != nil)
			return merr;

		case mtype {
		HT_CERTIFICATE =>
			(certs, cerr) := parsecertificatemsg(mdata);
			if(cerr != nil)
				return cerr;
			server_certs = certs;

		HT_SERVER_KEY_EXCHANGE =>
			# ECDHE key exchange - parse and verify signature
			(curve, ecpoint, skerr) := parseserverkeyexchange(mdata,
				client_random, server_random, server_certs, cs.insecure);
			if(skerr != nil)
				return skerr;
			server_ecpoint = ecpoint;
			server_curve = curve;
			uses_ecdhe = 1;

		HT_CERTIFICATE_REQUEST =>
			# Client cert requested - we don't support this yet
			;

		HT_SERVER_HELLO_DONE =>
			got_server_done = 1;

		* =>
			return sys->sprint("tls: unexpected handshake message type %d", mtype);
		}
	}

	# Verify server certificate: mandatory (no anonymous or PSK suites)
	if(!cs.insecure) {
		if(server_certs == nil)
			return "tls: server sent no certificate";
		verr := verifycerts(cs, server_certs);
		if(verr != nil)
			return verr;
	}
	if(isecdhe(cs.suite) && !uses_ecdhe)
		return "tls: ECDHE suite without ServerKeyExchange";

	# Compute premaster secret
	premaster: array of byte;

	if(uses_ecdhe) {
		if(server_curve == GROUP_SECP384R1) {
			# ECDHE with P-384: points are SEC1 uncompressed (0x04 || x || y)
			(p384_priv, p384_pub) := keyring->p384_keygen();
			if(p384_priv == nil || p384_pub == nil)
				return "tls: P-384 key generation failed";
			if(server_ecpoint == nil || len server_ecpoint != P384_POINTLEN)
				return "tls: invalid server P-384 point";
			{
				premaster = keyring->p384_ecdh(p384_priv, server_ecpoint);
			} exception {
			* =>
				premaster = nil;
			}
			wipebytes(p384_priv);
			if(premaster == nil)
				return "tls: P-384 ECDH failed";
			cke := buildclientkeyexchange_ecdhe(p384_pub);
			err := sendhsmsg(cs, HT_CLIENT_KEY_EXCHANGE, cke);
			if(err != nil)
				return err;
		} else if(server_curve == GROUP_SECP256R1) {
			# ECDHE with P-256
			(p256_priv, p256_pub) := keyring->p256_keygen();
			if(p256_priv == nil)
				return "tls: P-256 key generation failed";
			srv_pt := keyring->p256_make_point(server_ecpoint);
			if(srv_pt == nil)
				return "tls: invalid server P-256 point";
			premaster = keyring->p256_ecdh(p256_priv, srv_pt);
			if(premaster == nil)
				return "tls: P-256 ECDH failed";
			# CKE: uncompressed P-256 point (0x04 || 32-byte X || 32-byte Y)
			pub_bytes := keyring->p256_point_bytes(p256_pub);
			if(pub_bytes == nil)
				return "tls: P-256 public key encoding failed";
			cke := buildclientkeyexchange_ecdhe(pub_bytes);
			err := sendhsmsg(cs, HT_CLIENT_KEY_EXCHANGE, cke);
			if(err != nil)
				return err;
		} else {
			# ECDHE with X25519 (default)
			if(server_ecpoint == nil || len server_ecpoint != 32)
				return "tls: invalid server X25519 point";
			premaster = keyring->x25519(x25519_priv, server_ecpoint);
			if(premaster == nil)
				return "tls: X25519 computation failed";
			x25519_pub := keyring->x25519_base(x25519_priv);
			cke_x := buildclientkeyexchange_ecdhe(x25519_pub);
			err_x := sendhsmsg(cs, HT_CLIENT_KEY_EXCHANGE, cke_x);
			if(err_x != nil)
				return err_x;
		}
	} else {
		# RSA key exchange
		premaster = array [48] of byte;
		premaster[0] = byte 3;
		premaster[1] = byte 3;
		randombuf(premaster[2:], 46);

		# Encrypt premaster with server's RSA public key
		if(server_certs == nil)
			return "tls: no server certificate for RSA key exchange";
		(rsakey, pkerr) := extractrsakey(server_certs);
		if(pkerr != nil)
			return pkerr;
		(encerr, encbytes) := pkcs->rsa_encrypt(premaster, rsakey, 2);
		if(encerr != nil)
			return "tls: RSA encryption failed: " + encerr;
		server_pubkey = encbytes;
	}

	# Send ClientKeyExchange (RSA case — ECDHE CKE already sent above)
	if(!uses_ecdhe) {
		cke := buildclientkeyexchange_rsa(server_pubkey);
		err := sendhsmsg(cs, HT_CLIENT_KEY_EXCHANGE, cke);
		if(err != nil)
			return err;
	}

	# Derive keys using TLS 1.2 PRF
	master := tls12_prf(cs.suite, premaster,
		s2b("master secret"),
		catbytes(client_random, server_random),
		48);

	keyblock := tls12_prf(cs.suite, master,
		s2b("key expansion"),
		catbytes(server_random, client_random),
		keyblocklen(cs.suite));

	# Extract keys from key block.
	# In TLS 1.2:
	#   - Write encryption starts AFTER we send CCS (CCS itself is plaintext).
	#   - Read decryption starts only AFTER we receive the server's CCS.
	# Keep both keys local until the right moment.
	writekey, writeiv: array of byte;
	readkey, readiv: array of byte;
	(writekey, writeiv, readkey, readiv) = splitkeyblock(cs.suite, keyblock);

	# Send ChangeCipherSpec UNENCRYPTED (cs.writekey still nil here).
	err := writerecord(cs, CT_CHANGE_CIPHER_SPEC, array [] of {byte 1});
	if(err != nil)
		return err;

	# Activate write encryption for the Finished (seq=0) and beyond.
	cs.writekey = writekey;
	cs.writeiv = writeiv;

	# Send Finished (now encrypted, seq=0).
	verify_data := tls12_prf(cs.suite, master,
		s2b("client finished"),
		hashfinish(cs),
		12);
	ferr := sendhsmsg(cs, HT_FINISHED, verify_data);
	if(ferr != nil)
		return ferr;

	# Read server ChangeCipherSpec (plaintext — cs.readkey still nil).
	(ccstype, ccspayload, ccserr) := readrecord(cs);
	if(ccserr != nil)
		return ccserr;
	if(ccstype == CT_ALERT) {
		if(len ccspayload >= 2)
			return sys->sprint("tls: server rejected handshake: alert level=%d desc=%d",
				int ccspayload[0], int ccspayload[1]);
		return "tls: server rejected handshake (alert)";
	}
	if(ccstype != CT_CHANGE_CIPHER_SPEC)
		return "tls: expected ChangeCipherSpec";

	# Server has switched to encrypted mode — activate read key.
	cs.readkey = readkey;
	cs.readiv = readiv;

	# Capture transcript hash BEFORE reading server Finished.
	# RFC 5246 §7.4.9: server Finished covers all messages through client Finished
	# but NOT the server Finished itself.
	pre_server_finished := hashfinish(cs);

	# Read server Finished (now encrypted; readhsmsg hashes it into transcript).
	(ftype, fdata, ferr2) := readhsmsg(cs);
	if(ferr2 != nil)
		return ferr2;
	if(ftype != HT_FINISHED)
		return "tls: expected Finished";

	# Verify server Finished using hash that excludes server Finished itself.
	expected := tls12_prf(cs.suite, master,
		s2b("server finished"),
		pre_server_finished,
		12);
	if(!bytescmp(fdata, expected))
		return "tls: server Finished verification failed";

	return nil;
}

# ================================================================
# TLS 1.3 Handshake
# ================================================================

handshake13(cs: ref ConnState, config: ref Config,
	client_random, server_random: array of byte,
	x25519_priv: array of byte,
	key_share_group: int,
	key_share_data: array of byte): string
{
	shared_secret: array of byte;

	if(key_share_group == GROUP_SECP384R1MLKEM1024){
		# CNSA hybrid: server share = P-384 point (97) || ML-KEM-1024 ct (1568)
		if(key_share_data == nil || len key_share_data != P384_POINTLEN + MLKEM1024_CTLEN)
			return "tls: invalid server hybrid key share";
		if(cs.eph_p384_priv == nil || cs.eph_mlkem_sk == nil)
			return "tls: server chose a hybrid group we did not offer";
		srv_p384 := key_share_data[0:P384_POINTLEN];
		srv_ct := key_share_data[P384_POINTLEN:];
		ecdh_ss: array of byte;
		mlkem_ss: array of byte;
		{
			ecdh_ss = keyring->p384_ecdh(cs.eph_p384_priv, srv_p384);
			mlkem_ss = keyring->mlkem1024_decaps(cs.eph_mlkem_sk, srv_ct);
		} exception {
		* =>
			return "tls: CNSA hybrid key agreement failed";
		}
		if(ecdh_ss == nil || mlkem_ss == nil)
			return "tls: CNSA hybrid key agreement failed";
		# combiner: ECDH secret first, then ML-KEM (SecP-prefixed codepoint order)
		shared_secret = catbytes(ecdh_ss, mlkem_ss);
	}else if(key_share_group == GROUP_X25519MLKEM768){
		# server share = ML-KEM-768 ct (1088) || X25519 (32)
		if(key_share_data == nil || len key_share_data != MLKEM768_CTLEN + 32)
			return "tls: invalid server hybrid key share";
		if(cs.eph_mlkem768_sk == nil)
			return "tls: server chose X25519MLKEM768, which we did not offer";
		mlkem_ss: array of byte;
		x_ss: array of byte;
		{
			mlkem_ss = keyring->mlkem768_decaps(cs.eph_mlkem768_sk, key_share_data[0:MLKEM768_CTLEN]);
			x_ss = keyring->x25519(x25519_priv, key_share_data[MLKEM768_CTLEN:]);
		} exception {
		* =>
			return "tls: X25519MLKEM768 key agreement failed";
		}
		if(mlkem_ss == nil || x_ss == nil)
			return "tls: X25519MLKEM768 key agreement failed";
		# combiner: ML-KEM secret first, then X25519 (the codepoint's order)
		shared_secret = catbytes(mlkem_ss, x_ss);
	}else if(key_share_group == GROUP_X25519){
		if(key_share_data == nil || len key_share_data != 32)
			return "tls: invalid server key share";
		shared_secret = keyring->x25519(x25519_priv, key_share_data);
		if(shared_secret == nil)
			return "tls: X25519 computation failed";
	}else if(key_share_group == GROUP_SECP256R1){
		if(cs.eph_p256_priv == nil)
			return "tls: server chose secp256r1, which we did not offer";
		if(key_share_data == nil || len key_share_data != 65)
			return "tls: invalid server P-256 key share";
		srv_pt := keyring->p256_make_point(key_share_data);
		if(srv_pt == nil)
			return "tls: invalid server P-256 point";
		shared_secret = keyring->p256_ecdh(cs.eph_p256_priv, srv_pt);
		wipebytes(cs.eph_p256_priv);
		cs.eph_p256_priv = nil;
		if(shared_secret == nil)
			return "tls: P-256 ECDH failed";
	}else if(key_share_group == GROUP_SECP384R1){
		if(cs.eph_p384_priv == nil)
			return "tls: server chose secp384r1, which we did not offer";
		if(key_share_data == nil || len key_share_data != P384_POINTLEN)
			return "tls: invalid server P-384 key share";
		{
			shared_secret = keyring->p384_ecdh(cs.eph_p384_priv, key_share_data);
		} exception {
		* =>
			shared_secret = nil;
		}
		wipebytes(cs.eph_p384_priv);
		cs.eph_p384_priv = nil;
		if(shared_secret == nil)
			return "tls: P-384 ECDH failed";
	}else
		return "tls: unsupported key share group";

	hashlen := hashlength(cs.suite);

	# TLS 1.3 Key Schedule (RFC 8446 §7.1)
	# Hash algorithm is determined by cs.suite: SHA-256 or SHA-384
	zeros := array [hashlen] of {* => byte 0};
	early_secret := hkdf_extract(cs.suite, zeros, zeros);

	# Derive handshake secret
	derived := hkdf_expand_label(cs.suite, early_secret, "derived", hash_empty(cs), hashlen);
	handshake_secret := hkdf_extract(cs.suite, derived, shared_secret);

	# Derive handshake traffic secrets
	hs_hash := hashcurrent(cs);
	c_hs_traffic := hkdf_expand_label(cs.suite, handshake_secret, "c hs traffic", hs_hash, hashlen);
	s_hs_traffic := hkdf_expand_label(cs.suite, handshake_secret, "s hs traffic", hs_hash, hashlen);

	# Derive handshake keys
	(cs.readkey, cs.readiv) = derivekeys(s_hs_traffic, cs.suite);
	(cs.writekey, cs.writeiv) = derivekeys(c_hs_traffic, cs.suite);
	cs.readseq = big 0;
	cs.writeseq = big 0;
	cs.hsencrypted = 1;

	# Read encrypted handshake messages
	server_certs: list of array of byte;
	hs_done := 0;
	got_cv := 0;
	# Some peers (e.g. Gmail's SMTP submission frontend) send CertificateRequest
	# during the handshake even when the cert is optional. RFC 8446 §4.4.2
	# requires the client to respond with a Certificate message (empty is OK)
	# before its Finished, echoing the certificate_request_context.
	cert_requested := 0;
	cert_request_context: array of byte;	# nil = empty context
	cert_request: array of byte;	# the CertificateRequest body

	while(!hs_done) {
		# Save transcript hash (as finalized bytes) before reading next message.
		# CertificateVerify and Finished cover transcript EXCLUDING the message itself,
		# but readhsmsg hashes the message before returning.
		pre_read_hash := hashcurrent(cs);

		(mtype, mdata, merr) := readhsmsg(cs);
		if(merr != nil)
			return merr;

		case mtype {
		HT_ENCRYPTED_EXTENSIONS =>
			# Parse but mostly ignore for now
			;

		HT_CERTIFICATE_REQUEST =>
			# RFC 8446 §4.3.2: body =
			#   opaque certificate_request_context<0..2^8-1>;
			#   Extension extensions<2..2^16-1>;
			# We don't have a client cert, but we still MUST send an
			# empty Certificate response (with the echoed context) or
			# the server will respond with unexpected_message(10).
			cert_requested = 1;
			cert_request = mdata;
			if(len mdata >= 1) {
				ctxlen := int mdata[0];
				if(1 + ctxlen <= len mdata && ctxlen > 0)
					cert_request_context = mdata[1:1+ctxlen];
			}

		HT_CERTIFICATE =>
			(certs, cerr) := parsecertificatemsg13(mdata);
			if(cerr != nil)
				return cerr;
			server_certs = certs;

		HT_CERTIFICATE_VERIFY =>
			# Verify server's signature over transcript (EXCLUDING CertificateVerify)
			if(server_certs == nil)
				return "tls: CertificateVerify before Certificate";
			if(!cs.insecure) {
				verr := verifycertverify_hash(cs, mdata, server_certs, pre_read_hash);
				if(verr != nil)
					return verr;
			}
			got_cv = 1;

		HT_FINISHED =>
			# Without PSK the server must have authenticated itself
			# (RFC 8446 §4.4): a Finished alone proves only knowledge of
			# the (attacker-chosen) key share.
			if(!cs.insecure && (server_certs == nil || !got_cv))
				return "tls: server did not authenticate (Certificate/CertificateVerify missing)";
			# Verify server Finished using transcript hash BEFORE Finished was hashed
			fverr := verifyfinished13_hash(cs, mdata, s_hs_traffic, pre_read_hash);
			if(fverr != nil)
				return fverr;
			hs_done = 1;

		* =>
			return sys->sprint("tls: unexpected hs msg type %d in TLS 1.3", mtype);
		}
	}

	# Verify server certificate chain (mandatory: see HT_FINISHED above)
	if(!cs.insecure) {
		if(server_certs == nil)
			return "tls: server sent no certificate";
		verr := verifycerts(cs, server_certs);
		if(verr != nil)
			return verr;
	}

	# Derive application traffic secrets BEFORE sending Client Finished.
	# Per RFC 8446 §7.1, app secrets use transcript through Server Finished only.
	master_derived := hkdf_expand_label(cs.suite, handshake_secret, "derived", hash_empty(cs), hashlen);
	master_secret := hkdf_extract(cs.suite, master_derived, zeros);

	app_hash := hashcurrent(cs);	# includes Server Finished, not Client Finished
	cs.cts = hkdf_expand_label(cs.suite, master_secret, "c ap traffic", app_hash, hashlen);
	cs.sts = hkdf_expand_label(cs.suite, master_secret, "s ap traffic", app_hash, hashlen);

	# If the server requested a client certificate, RFC 8446 §4.4.2 requires
	# us to send a Certificate message before our Finished — even when we
	# have no certificate to present. The body is:
	#   opaque certificate_request_context<0..2^8-1>;	(echoed from request)
	#   CertificateEntry certificate_list<0..2^24-1>;
	# with our one certificate, if the config has one, and then a
	# CertificateVerify over the transcript so far.  When the list is
	# empty we MUST NOT send CertificateVerify (§4.4.3).
	if(cert_requested) {
		entry: array of byte;
		if(config.clientcert != nil && config.clientkey != nil) {
			if(!certreqsigalg(cert_request, ECDSA_SECP256R1_SHA256))
				return "tls: server does not accept an ecdsa_secp256r1_sha256 client signature";
			# CertificateEntry: cert_data<1..2^24-1>, extensions<0..2^16-1>
			c := config.clientcert;
			entry = array [3 + len c + 2] of byte;
			put24(entry, 0, len c);
			entry[3:] = c;
			put16(entry, 3 + len c, 0);
		}
		ctxlen := len cert_request_context;
		cmsg := array [1 + ctxlen + 3 + len entry] of byte;
		cmsg[0] = byte ctxlen;
		if(ctxlen > 0)
			cmsg[1:] = cert_request_context;
		put24(cmsg, 1 + ctxlen, len entry);
		if(entry != nil)
			cmsg[1 + ctxlen + 3:] = entry;
		cerr := sendhsmsg(cs, HT_CERTIFICATE, cmsg);
		if(cerr != nil)
			return cerr;
		if(entry != nil) {
			(cv, cverr) := clientcertverify13(hashcurrent(cs), config.clientkey);
			if(cverr != nil)
				return cverr;
			cerr = sendhsmsg(cs, HT_CERTIFICATE_VERIFY, cv);
			if(cerr != nil)
				return cerr;
		}
	}

	# Send client Finished
	finished_key := hkdf_expand_label(cs.suite, c_hs_traffic, "finished", nil, hashlen);
	finished_hash := hashcurrent(cs);
	verify_data := hmac_hash(cs.suite, finished_key, finished_hash);
	ferr := sendhsmsg(cs, HT_FINISHED, verify_data);
	if(ferr != nil)
		return ferr;

	# Switch to application traffic keys
	(cs.readkey, cs.readiv) = derivekeys(cs.sts, cs.suite);
	(cs.writekey, cs.writeiv) = derivekeys(cs.cts, cs.suite);
	cs.readseq = big 0;
	cs.writeseq = big 0;

	return nil;
}

# ================================================================
# Handshake Message Building
# ================================================================

buildclienthello(config: ref Config, random, session_id: array of byte,
	groups: list of int, shares: list of (int, array of byte),
	cookie: array of byte): array of byte
{
	# Build extensions

	# SNI extension
	sni: array of byte;
	if(config.servername != nil && len config.servername > 0)
		sni = buildsniext(config.servername);
	else
		sni = nil;

	# Supported groups + key share: the CNSA hybrid alone, or the
	# X25519MLKEM768 hybrid ahead of the classical groups.
	groupsext := buildsupportedgroups(groups);
	keyshare := buildkeyshare(shares);

	# Cookie, echoed from a HelloRetryRequest (RFC 8446 §4.2.2)
	cookieext: array of byte;
	if(cookie != nil) {
		cookieext = array[4 + 2 + len cookie] of byte;
		put16(cookieext, 0, EXT_COOKIE);
		put16(cookieext, 2, 2 + len cookie);
		put16(cookieext, 4, len cookie);
		cookieext[6:] = cookie;
	}

	# Signature algorithms extension
	sigalgs := buildsigalgsext();

	# Supported versions extension (for TLS 1.3)
	suppver: array of byte;
	if(config.maxver >= TLS13)
		suppver = buildsupportedversions(config);
	else
		suppver = nil;

	# Concatenate extensions
	extlist := catbytes(sni, catbytes(groupsext, catbytes(sigalgs,
		catbytes(suppver, catbytes(cookieext, keyshare)))));

	# Cipher suites
	suitebytes := buildsuites(config.suites);

	# Build ClientHello body
	# version(2) + random(32) + session_id_len(1) + session_id(32) +
	# suites_len(2) + suites + compressions(2) + extensions
	bodylen := 2 + 32 + 1 + len session_id + 2 + len suitebytes + 2 + 2 + len extlist;
	body := array [bodylen] of byte;
	off := 0;

	# Legacy version: TLS 1.2 (actual version in extension)
	put16(body, off, RECVERSION);
	off += 2;

	# Random
	body[off:] = random;
	off += 32;

	# Session ID
	body[off] = byte len session_id;
	off++;
	body[off:] = session_id;
	off += len session_id;

	# Cipher suites
	put16(body, off, len suitebytes);
	off += 2;
	body[off:] = suitebytes;
	off += len suitebytes;

	# Compression methods (null only)
	body[off] = byte 1;
	off++;
	body[off] = byte 0;
	off++;

	# Extensions
	put16(body, off, len extlist);
	off += 2;
	body[off:] = extlist;

	return body;
}

buildsniext(name: string): array of byte
{
	namebytes := s2b(name);
	# Extension: type(2) + length(2)
	# SNI list: length(2) + entry: type(1) + name_length(2) + name
	listlen := 1 + 2 + len namebytes;
	extlen := 2 + listlen;
	ext := array [4 + extlen] of byte;
	put16(ext, 0, EXT_SERVER_NAME);
	put16(ext, 2, extlen);
	put16(ext, 4, listlen);
	ext[6] = byte 0;	# host_name type
	put16(ext, 7, len namebytes);
	ext[9:] = namebytes;
	return ext;
}

buildsupportedgroups(groups: list of int): array of byte
{
	n := 2 * len groups;
	ext := array [4 + 2 + n] of byte;
	put16(ext, 0, EXT_SUPPORTED_GROUPS);
	put16(ext, 2, 2 + n);
	put16(ext, 4, n);
	off := 6;
	for(; groups != nil; groups = tl groups) {
		put16(ext, off, hd groups);
		off += 2;
	}
	return ext;
}

buildsigalgsext(): array of byte
{
	# Advertise in preference order:
	#   ECDSA P-256/SHA-256 and P-384/SHA-384  (EC certificates)
	#   RSA-PSS SHA-256 and SHA-384            (modern RSA, required for TLS 1.3)
	#   RSA-PKCS1 SHA-256/SHA-384/SHA-512      (legacy RSA, TLS 1.2 compat)
	#
	# P-384 is common for certificates signed by Let's Encrypt and DigiCert
	# using ECDSA; omitting it causes handshake_failure on those sites.
	algs := array[] of {
		ECDSA_SECP256R1_SHA256,
		ECDSA_SECP384R1_SHA384,
		RSA_PSS_RSAE_SHA256,
		RSA_PSS_RSAE_SHA384,
		RSA_PKCS1_SHA256,
		RSA_PKCS1_SHA384,
		RSA_PKCS1_SHA512,
	};
	nalgs := len algs;
	ext := array [4 + 2 + nalgs * 2] of byte;
	put16(ext, 0, EXT_SIGNATURE_ALGORITHMS);
	put16(ext, 2, 2 + nalgs * 2);
	put16(ext, 4, nalgs * 2);
	for(i := 0; i < nalgs; i++)
		put16(ext, 6 + i*2, algs[i]);
	return ext;
}

buildsupportedversions(config: ref Config): array of byte
{
	versions: list of int;
	if(config.maxver >= TLS13)
		versions = TLS13 :: versions;
	if(config.minver <= TLS12)
		versions = TLS12 :: versions;

	nver := 0;
	for(l := versions; l != nil; l = tl l)
		nver++;

	ext := array [4 + 1 + nver * 2] of byte;
	put16(ext, 0, EXT_SUPPORTED_VERSIONS);
	put16(ext, 2, 1 + nver * 2);
	ext[4] = byte (nver * 2);
	off := 5;
	for(l = versions; l != nil; l = tl l) {
		put16(ext, off, hd l);
		off += 2;
	}
	return ext;
}

buildkeyshare(shares: list of (int, array of byte)): array of byte
{
	# one entry per share: group(2) + key_len(2) + key
	listlen := 0;
	for(l := shares; l != nil; l = tl l) {
		(nil, d) := hd l;
		listlen += 2 + 2 + len d;
	}
	ext := array [4 + 2 + listlen] of byte;
	put16(ext, 0, EXT_KEY_SHARE);
	put16(ext, 2, 2 + listlen);
	put16(ext, 4, listlen);
	off := 6;
	for(l = shares; l != nil; l = tl l) {
		(g, d) := hd l;
		put16(ext, off, g);
		put16(ext, off+2, len d);
		ext[off+4:] = d;
		off += 4 + len d;
	}
	return ext;
}

buildsuites(suites: list of int): array of byte
{
	n := 0;
	for(l := suites; l != nil; l = tl l)
		n++;
	buf := array [n * 2] of byte;
	off := 0;
	for(l = suites; l != nil; l = tl l) {
		put16(buf, off, hd l);
		off += 2;
	}
	return buf;
}

buildclientkeyexchange_ecdhe(pubkey: array of byte): array of byte
{
	# Length-prefixed EC point (uncompressed format for X25519 is just 32 bytes)
	buf := array [1 + len pubkey] of byte;
	buf[0] = byte len pubkey;
	buf[1:] = pubkey;
	return buf;
}

buildclientkeyexchange_rsa(encrypted_premaster: array of byte): array of byte
{
	# 2-byte length prefix + encrypted premaster
	buf := array [2 + len encrypted_premaster] of byte;
	put16(buf, 0, len encrypted_premaster);
	buf[2:] = encrypted_premaster;
	return buf;
}

# ================================================================
# Handshake Message Parsing
# ================================================================

parseserverhello(data: array of byte, config: ref Config): (array of byte, int, int, int, array of byte, string)
{
	if(len data < 38)
		return (nil, 0, 0, 0, nil, "tls: ServerHello too short");

	# version(2) + random(32) + session_id_len(1)...
	off := 0;
	legacy_version := get16(data, off);
	off += 2;

	server_random := data[off:off+32];
	off += 32;

	sid_len := int data[off];
	off++;
	if(off + sid_len + 3 > len data)
		return (nil, 0, 0, 0, nil, "tls: ServerHello truncated");
	off += sid_len;

	suite := get16(data, off);
	off += 2;

	compression := int data[off];
	off++;
	if(compression != 0)
		return (nil, 0, 0, 0, nil, "tls: non-null compression");

	# Parse extensions
	version := legacy_version;
	key_share_group := 0;
	key_share_data: array of byte;

	if(off + 2 <= len data) {
		ext_len := get16(data, off);
		off += 2;
		ext_end := off + ext_len;
		if(ext_end > len data)
			return (nil, 0, 0, 0, nil, "tls: ServerHello extensions truncated");

		while(off + 4 <= ext_end) {
			etype := get16(data, off);
			elen := get16(data, off + 2);
			off += 4;

			if(off + elen > ext_end)
				return (nil, 0, 0, 0, nil, "tls: ServerHello extension truncated");

			case etype {
			EXT_SUPPORTED_VERSIONS =>
				if(elen >= 2)
					version = get16(data, off);

			EXT_KEY_SHARE =>
				# group(2) + key_len(2) + key
				if(elen >= 4) {
					key_share_group = get16(data, off);
					klen := get16(data, off + 2);
					if(off + 4 + klen <= ext_end)
						key_share_data = data[off+4:off+4+klen];
				}
			}
			off += elen;
		}
		if(off != ext_end)
			return (nil, 0, 0, 0, nil, "tls: ServerHello extension truncated");
	}

	# Validate suite
	found := 0;
	for(l := config.suites; l != nil; l = tl l) {
		if(hd l == suite) {
			found = 1;
			break;
		}
	}
	if(!found)
		return (nil, 0, 0, 0, nil, sys->sprint("tls: server chose unsupported suite 0x%04x", suite));

	# Validate version
	if(version != TLS12 && version != TLS13)
		return (nil, 0, 0, 0, nil, sys->sprint("tls: unsupported version 0x%04x", version));

	return (server_random, suite, version, key_share_group, key_share_data, nil);
}

parsecertificatemsg(data: array of byte): (list of array of byte, string)
{
	if(len data < 3)
		return (nil, "tls: Certificate msg too short");

	total_len := get24(data, 0);
	off := 3;
	end := off + total_len;
	if(end > len data)
		return (nil, "tls: Certificate msg truncated");
	certs: list of array of byte;

	while(off + 3 <= end) {
		cert_len := get24(data, off);
		off += 3;
		if(off + cert_len > end)
			return (nil, "tls: certificate truncated");
		certs = data[off:off+cert_len] :: certs;
		off += cert_len;
	}
	if(off != end)
		return (nil, "tls: certificate truncated");

	# Reverse to get original order (leaf first)
	result: list of array of byte;
	for(l := certs; l != nil; l = tl l)
		result = hd l :: result;

	return (result, nil);
}

parsecertificatemsg13(data: array of byte): (list of array of byte, string)
{
	if(len data < 4)
		return (nil, "tls: Certificate msg too short");

	# TLS 1.3: request_context(1) + certificate_list
	ctx_len := int data[0];
	off := 1 + ctx_len;

	if(off + 3 > len data)
		return (nil, "tls: Certificate msg truncated");

	total_len := get24(data, off);
	off += 3;
	certs: list of array of byte;

	end := off + total_len;
	if(end > len data)
		return (nil, "tls: Certificate msg truncated");
	while(off + 3 <= end) {
		cert_len := get24(data, off);
		off += 3;
		if(off + cert_len > end)
			return (nil, "tls: certificate truncated");
		certs = data[off:off+cert_len] :: certs;
		off += cert_len;

		# TLS 1.3: extensions per certificate entry
		if(off + 2 <= end) {
			ext_len := get16(data, off);
			if(off + 2 + ext_len > end)
				return (nil, "tls: certificate extensions truncated");
			off += 2 + ext_len;
		}
	}
	if(off != end)
		return (nil, "tls: certificate truncated");

	# Reverse
	result: list of array of byte;
	for(l := certs; l != nil; l = tl l)
		result = hd l :: result;

	return (result, nil);
}

parseserverkeyexchange(data: array of byte,
	client_random, server_random: array of byte,
	server_certs: list of array of byte, insecure: int): (int, array of byte, string)
{
	if(len data < 4)
		return (0, nil, "tls: ServerKeyExchange too short");

	off := 0;

	# EC parameters
	curve_type := int data[off];
	off++;
	if(curve_type != 3)	# named_curve
		return (0, nil, "tls: unsupported curve type");

	named_curve := get16(data, off);
	off += 2;

	if(named_curve != GROUP_X25519 && named_curve != GROUP_SECP256R1 && named_curve != GROUP_SECP384R1)
		return (0, nil, sys->sprint("tls: unsupported named curve 0x%04x", named_curve));

	point_len := int data[off];
	off++;
	if(off + point_len > len data)
		return (0, nil, "tls: EC point truncated");

	ecpoint := data[off:off+point_len];
	off += point_len;

	# The signature over the ECDHE params authenticates the key exchange;
	# it is mandatory unless verification is explicitly disabled.
	if(!insecure) {
		if(server_certs == nil)
			return (0, nil, "tls: ServerKeyExchange before Certificate");
		if(off + 4 > len data)
			return (0, nil, "tls: ServerKeyExchange is not signed");
		scheme := get16(data, off);
		off += 2;
		sig_len := get16(data, off);
		off += 2;
		if(off + sig_len != len data)
			return (0, nil, "tls: ServerKeyExchange signature length");
		sig := data[off:off+sig_len];

		# signed content: client_random(32) + server_random(32) + server_params
		params_len := 1 + 2 + 1 + point_len;
		signed_content := array [32 + 32 + params_len] of byte;
		signed_content[0:] = client_random;
		signed_content[32:] = server_random;
		signed_content[64:] = data[0:params_len];

		verr := verifyserversig(server_certs, scheme, signed_content, sig, 0);
		if(verr != nil)
			return (0, nil, "tls: ServerKeyExchange: " + verr);
	}

	return (named_curve, ecpoint, nil);
}

# ================================================================
# Certificate Verification
# ================================================================

verifycerts(cs: ref ConnState, certs: list of array of byte): string
{
	if(certs == nil)
		return "tls: no server certificates";

	# A pinned key stands in for the chain and the name: the peer is
	# whoever holds that key (its CertificateVerify is checked apart).
	if(cs.pinspki != nil)
		return verifyspkipin(cs.pinspki, hd certs);

	# Use X509 to verify certificate chain
	(ok, err) := x509->verify_certchain(certs);
	if(!ok && !cs.insecure)
		return "tls: certificate chain verification failed: " + err;

	# Verify hostname matches certificate CN/SAN
	if(cs.servername != nil && len cs.servername > 0) {
		herr := verifyhostname(cs.servername, hd certs);
		if(herr != nil && !cs.insecure)
			return herr;
	}
	return nil;
}

verifyspkipin(pin: array of byte, leaf: array of byte): string
{
	spki := certspki(leaf);
	if(spki == nil)
		return "tls: no SubjectPublicKeyInfo in the server certificate";
	digest := array [Keyring->SHA256dlen] of byte;
	keyring->sha256(spki, len spki, digest, nil);
	if(!bytescmp(digest, pin))
		return "tls: server key does not match the pinned key";

	# The pinned key must be the key the server's signature is checked
	# with.  certspki finds the bytes the pin is over; the signature is
	# checked (verifyserversig) with the key X509 reads from the same
	# certificate.  A certificate the two read differently could pass
	# the pin on one key and sign with another, so the key bits and
	# algorithm the pinned bytes hold are matched against X509's.
	(oid, bits) := spkikey(spki);
	if(bits == nil)
		return "tls: the pinned SubjectPublicKeyInfo does not parse";
	(serr, signed) := x509->Signed.decode(leaf);
	if(serr != nil)
		return "tls: decode cert: " + serr;
	(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
	if(cerr != nil)
		return "tls: decode TBSCert: " + cerr;
	pk := cert.subject_pkinfo;
	if(pk == nil || pk.alg_id == nil || !oideq(pk.alg_id.oid, oid) ||
	   !bytescmp(pk.subject_pk, bits))
		return "tls: the pinned key is not the certificate's key";
	return nil;
}

# The algorithm and key bits of a DER SubjectPublicKeyInfo, read as
# X509's parse_pkinfo reads one: SEQUENCE { AlgorithmIdentifier
# SEQUENCE { OID, ... }, BIT STRING with no unused bits }.
spkikey(spki: array of byte): (ref ASN1->Oid, array of byte)
{
	(err, e) := asn1->decode(spki);
	if(err != nil || e == nil)
		return (nil, nil);
	(ok, el) := e.is_seq();
	if(!ok || len el != 2)
		return (nil, nil);
	al: list of ref ASN1->Elem;
	(ok, al) = (hd el).is_seq();
	if(!ok || al == nil)
		return (nil, nil);
	oid: ref ASN1->Oid;
	(ok, oid) = (hd al).is_oid();
	if(!ok || oid == nil)
		return (nil, nil);
	unused: int;
	bits: array of byte;
	(ok, unused, bits) = (hd tl el).is_bitstring();
	if(!ok || unused != 0 || bits == nil)
		return (nil, nil);
	return (oid, bits);
}

# The DER header at a[off]: (tag, header length, content length), or
# tag -1 if it is malformed or runs past the end of a.
dertlv(a: array of byte, off: int): (int, int, int)
{
	if(off < 0 || off + 2 > len a)
		return (-1, 0, 0);
	tag := int a[off];
	if((tag & 16r1F) == 16r1F)
		return (-1, 0, 0);	# multi-byte tags do not occur here
	n := int a[off+1];
	hdr := 2;
	if(n & 16r80) {
		k := n & 16r7F;
		if(k == 0 || k > 3 || off + 2 + k > len a)
			return (-1, 0, 0);
		# DER lengths are shortest-form: no leading zero and no long form
		# for a value below 128.  Reject BER alternatives so the raw bytes
		# hashed for a pin have exactly one structural interpretation.
		if(a[off+2] == byte 0)
			return (-1, 0, 0);
		n = 0;
		for(i := 0; i < k; i++)
			n = (n << 8) | int a[off+2+i];
		if(n < 128)
			return (-1, 0, 0);
		hdr += k;
	}
	if(n > len a - off - hdr)
		return (-1, 0, 0);
	return (tag, hdr, n);
}

# The raw DER SubjectPublicKeyInfo of a certificate, as it is hashed
# for a pin: Certificate { tbsCertificate { [0] version OPTIONAL,
# serial, signature, issuer, validity, subject, spki, ... } ... }.
certspki(der: array of byte): array of byte
{
	(t, h, n) := dertlv(der, 0);
	if(t != 16r30 || h + n != len der)
		return nil;
	off := h;
	(t, h, n) = dertlv(der, off);	# tbsCertificate
	if(t != 16r30)
		return nil;
	off += h;
	end := off + n;
	(t, h, n) = dertlv(der, off);
	if(t == 16rA0) {
		off += h + n;
		(t, h, n) = dertlv(der, off);
	}
	for(i := 0; i < 5; i++) {	# serial .. subject
		if(t < 0 || off + h + n > end)
			return nil;
		off += h + n;
		(t, h, n) = dertlv(der, off);
	}
	if(t != 16r30 || off + h + n > end)
		return nil;
	return der[off:off+h+n];
}

# The CertificateRequest's signature_algorithms extension offers alg.
certreqsigalg(m: array of byte, alg: int): int
{
	if(len m < 1)
		return 0;
	off := 1 + int m[0];	# skip certificate_request_context
	if(off + 2 > len m)
		return 0;
	end := off + 2 + get16(m, off);
	if(end > len m)
		return 0;
	for(off += 2; off + 4 <= end; ) {
		etype := get16(m, off);
		elen := get16(m, off + 2);
		off += 4;
		if(off + elen > end)
			return 0;
		if(etype == EXT_SIGNATURE_ALGORITHMS && elen >= 2) {
			n := get16(m, off);
			if(2 + n > elen)
				return 0;
			for(i := 0; i + 1 < n; i += 2)
				if(get16(m, off + 2 + i) == alg)
					return 1;
		}
		off += elen;
	}
	return 0;
}

# TLS 1.3 client CertificateVerify (RFC 8446 §4.4.3), signed
# ecdsa_secp256r1_sha256 with the raw P-256 private scalar key.
clientcertverify13(transcript_hash, key: array of byte): (array of byte, string)
{
	if(len key != 32)
		return (nil, "tls: client key is not a P-256 private key");
	return certverify13("TLS 1.3, client CertificateVerify", transcript_hash, key);
}

# A CertificateVerify's body (RFC 8446 §4.4.3): ecdsa_secp256r1_sha256
# over 64 spaces, the context string, a zero byte and the transcript hash.
certverify13(context_str: string, transcript_hash, key: array of byte): (array of byte, string)
{
	content := array [64 + len context_str + 1 + len transcript_hash] of byte;
	for(i := 0; i < 64; i++)
		content[i] = byte 16r20;
	content[64:] = array of byte context_str;
	content[64 + len context_str] = byte 0;
	content[64 + len context_str + 1:] = transcript_hash;

	digest := array [Keyring->SHA256dlen] of byte;
	keyring->sha256(content, len content, digest, nil);
	raw: array of byte;
	{
		raw = keyring->p256_ecdsa_sign(key, digest);
	} exception {
	* =>
		raw = nil;
	}
	if(raw == nil || len raw != 64)
		return (nil, "tls: CertificateVerify signature failed");
	sig := ecdsadersig(raw[0:32], raw[32:64]);
	cv := array [4 + len sig] of byte;
	put16(cv, 0, ECDSA_SECP256R1_SHA256);
	put16(cv, 2, len sig);
	cv[4:] = sig;
	return (cv, nil);
}

# Ecdsa-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }, from raw r and s.
ecdsadersig(r, s: array of byte): array of byte
{
	ri := derposint(r);
	si := derposint(s);
	seq := array [2 + len ri + len si] of byte;	# at most 70 bytes: short form
	seq[0] = byte 16r30;
	seq[1] = byte (len ri + len si);
	seq[2:] = ri;
	seq[2 + len ri:] = si;
	return seq;
}

# A minimal DER INTEGER for the unsigned big-endian b.
derposint(b: array of byte): array of byte
{
	i := 0;
	while(i < len b - 1 && b[i] == byte 0)
		i++;
	pad := 0;
	if(int b[i] & 16r80)
		pad = 1;
	n := len b - i + pad;
	e := array [2 + n] of {* => byte 0};
	e[0] = byte 16r02;
	e[1] = byte n;
	e[2 + pad:] = b[i:];
	return e;
}

# Verify that hostname matches the leaf certificate's CN or SAN dNSName entries.
# RFC 6125: prefer SAN over CN; wildcard matching for *.example.com.
verifyhostname(hostname: string, certder: array of byte): string
{
	# Decode the X.509 certificate
	(serr, signed) := x509->Signed.decode(certder);
	if(serr != nil)
		return "tls: hostname verify: decode cert: " + serr;

	(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
	if(cerr != nil)
		return "tls: hostname verify: decode TBSCert: " + cerr;

	# An IP address is matched against the SAN's iPAddress entries
	# alone, a name against its dNSName entries and then the CN
	# (RFC 6125 1.7.2, 6.2.1).
	(isip, addr) := ipliteral(hostname);

	# SubjectAltName first (RFC 6125). Decode only that extension, so an
	# unrelated extension this x509 cannot parse does not hide it, and
	# fail closed: a SAN that is present but undecodable is an error.
	san_checked := 0;
	san_oid := ref x509->objIdTab[x509->id_ce_subjectAltName];
	for(xl := cert.exts; xl != nil; xl = tl xl) {
		ext := hd xl;
		if(!oideq(ext.oid, san_oid))
			continue;
		(derr, ec) := x509->ExtClass.decode(ext);
		if(derr != "" || ec == nil)
			return sys->sprint("tls: hostname verify: bad subjectAltName: %s", derr);
		pick san := ec {
		SubjectAltName =>
			san_checked = 1;
			for(al := san.alias; al != nil; al = tl al) {
				gn := hd al;
				pick g := gn {
				dNSName =>
					if(!isip && matchhostname(hostname, g.str))
						return nil;
				iPAddress =>
					if(isip && ipmatch(addr, g.ip))
						return nil;
				}
			}
		* =>
			return "tls: hostname verify: subjectAltName decoded as another extension";
		}
	}

	# If SAN was present but didn't match, fail (RFC 6125 §6.4.4)
	if(san_checked)
		return sys->sprint("tls: hostname %s does not match any subjectAltName", hostname);
	if(isip)
		return sys->sprint("tls: certificate names no IP address %s", hostname);

	# Fall back to CN in subject
	for(rdl := cert.subject.rd_names; rdl != nil; rdl = tl rdl) {
		rdn := hd rdl;
		for(al := rdn.avas; al != nil; al = tl al) {
			ava := hd al;
			if(ava.oid != nil && x509->objIdTab != nil &&
			   ava.oid.nums != nil && len ava.oid.nums > 0) {
				cn_oid := ref x509->objIdTab[x509->id_at_commonName];
				if(oideq(ava.oid, cn_oid)) {
					if(matchhostname(hostname, ava.value))
						return nil;
				}
			}
		}
	}

	return sys->sprint("tls: hostname %s does not match certificate", hostname);
}

# An IPv4 or IPv6 address written as text, as a reference identity: one
# with a colon, or digits and dots (IPaddr.parse alone would take an
# all-hex name, a host called cafe, for an IPv6 address)
ipliteral(s: string): (int, IPaddr)
{
	colon := 0;
	numeric := 1;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == ':')
			colon = 1;
		else if(c != '.' && (c < '0' || c > '9'))
			numeric = 0;
	}
	if(!colon && !numeric || s == "")
		return (0, IPaddr(nil));
	if(ip == nil) {
		ip = load IP IP->PATH;
		if(ip == nil)
			return (0, IPaddr(nil));
		ip->init();
	}
	(ok, a) := IPaddr.parse(s);
	if(ok < 0)
		return (0, a);
	return (1, a);
}

# An iPAddress entry is the address's 4 or 16 bytes (RFC 5280 4.2.1.6)
ipmatch(a: IPaddr, b: array of byte): int
{
	case len b {
	4 =>
		if(!a.isv4())
			return 0;
		v := a.v4();
		for(i := 0; i < 4; i++)
			if(v[i] != b[i])
				return 0;
		return 1;
	16 =>
		return a.eq(IPaddr.newv6(b));
	}
	return 0;
}

oideq(a, b: ref ASN1->Oid): int
{
	if(a == nil || b == nil)
		return 0;
	if(a.nums == nil || b.nums == nil)
		return 0;
	if(len a.nums != len b.nums)
		return 0;
	for(i := 0; i < len a.nums; i++)
		if(a.nums[i] != b.nums[i])
			return 0;
	return 1;
}

# Match hostname against a certificate name pattern.
# Supports wildcards: *.example.com matches foo.example.com
# but not foo.bar.example.com or example.com.
matchhostname(hostname, pattern: string): int
{
	h := strlower(hostname);
	p := strlower(pattern);

	# Exact match
	if(h == p)
		return 1;

	# Wildcard: *.domain
	if(len p > 2 && p[0] == '*' && p[1] == '.') {
		suffix := p[1:];	# .example.com
		# hostname must have exactly one label before the suffix
		dot := strindex(h, '.');
		if(dot > 0 && h[dot:] == suffix)
			return 1;
	}
	return 0;
}

strlower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c = c - 'A' + 'a';
		r[len r] = c;
	}
	return r;
}

strindex(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

verifycertverify(cs: ref ConnState, data: array of byte, certs: list of array of byte): string
{
	return verifycertverify_hash(cs, data, certs, hashcurrent(cs));
}

# certverify_fail_context — wrap a CertificateVerify failure with the
# context users actually need to diagnose it: the negotiated version /
# suite, the expected hostname, and the leaf cert's subject CN. When a
# TLS-intercepting middlebox (corporate proxy, antivirus, captive portal)
# replaces the cert chain, the subject CN here will differ from the
# servername we asked for — that's the smoking gun. Returning a generic
# "ECDSA verification failed" without this context was the GH #230
# experience: identical message regardless of root cause.
certverify_fail_context(cs: ref ConnState, certs: list of array of byte,
	what: string): string
{
	leaf_cn := "<no leaf cert>";
	if(certs != nil) {
		(serr, signed) := x509->Signed.decode(hd certs);
		if(serr == nil) {
			(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
			if(cerr == nil && cert.subject != nil) {
				# Mirror of verifyhostname's CN extraction (see CN
				# fallback there); fields are cert.subject.rd_names ->
				# RDName.avas -> AVA.{oid,value}.
				cn_oid := ref x509->objIdTab[x509->id_at_commonName];
				for(rdl := cert.subject.rd_names; rdl != nil; rdl = tl rdl) {
					rdn := hd rdl;
					for(al := rdn.avas; al != nil; al = tl al) {
						ava := hd al;
						if(ava.oid != nil && oideq(ava.oid, cn_oid))
							leaf_cn = ava.value;
					}
				}
			}
		}
	}
	hint := "";
	if(cs.servername != "" && leaf_cn != "<no leaf cert>" && leaf_cn != cs.servername)
		hint = " (CN mismatch suggests TLS-intercepting proxy)";
	return sys->sprint("tls: CertificateVerify: %s [host=%s leaf-cn=%s version=0x%04x suite=0x%04x]%s",
		what, cs.servername, leaf_cn, cs.version, cs.suite, hint);
}

verifycertverify_hash(cs: ref ConnState, data: array of byte, certs: list of array of byte,
	transcript_hash: array of byte): string
{
	# TLS 1.3 CertificateVerify (RFC 8446 §4.4.3)
	if(len data < 4)
		return "tls: CertificateVerify too short";

	sig_alg := get16(data, 0);
	sig_len := get16(data, 2);
	if(4 + sig_len > len data)
		return "tls: CertificateVerify truncated";
	sig := data[4:4+sig_len];
	context_str := "TLS 1.3, server CertificateVerify";
	content := array [64 + len context_str + 1 + len transcript_hash] of byte;
	for(i := 0; i < 64; i++)
		content[i] = byte 16r20;
	content[64:] = array of byte context_str;
	content[64 + len context_str] = byte 0;
	content[64 + len context_str + 1:] = transcript_hash;

	if(certs == nil)
		return "tls: CertificateVerify without a server Certificate";
	verr := verifyserversig(certs, sig_alg, content, sig, 1);
	if(verr != nil)
		# When this fails on a network where openssl s_client succeeds,
		# the most likely cause is a TLS-intercepting middlebox presenting
		# a substitute chain (INFR-309).
		return certverify_fail_context(cs, certs, verr);
	return nil;
}

# Verify a server signature over msg with the leaf key in certs, for TLS
# SignatureScheme scheme (a TLS 1.2 SignatureAndHashAlgorithm has the same
# encoding). Returns nil if valid. Fails closed on anything unsupported.
# In TLS 1.3 (RFC 8446 §4.4.3) RSA PKCS#1 v1.5 is not allowed and an
# ECDSA scheme names its curve; in TLS 1.2 it names only the hash.
verifyserversig(certs: list of array of byte, scheme: int, msg, sig: array of byte, tls13: int): string
{
	hashlen := 0;
	case scheme >> 8 {
	16r04 =>	hashlen = Keyring->SHA256dlen;
	16r05 =>	hashlen = Keyring->SHA384dlen;
	16r06 =>	hashlen = Keyring->SHA512dlen;
	}
	case scheme {
	RSA_PKCS1_SHA256 or RSA_PKCS1_SHA384 or RSA_PKCS1_SHA512 =>
		if(tls13)
			return "RSA PKCS#1 v1.5 is not allowed in TLS 1.3";
		(rsakey, kerr) := extractrsakey(certs);
		if(kerr != nil)
			return kerr;
		di := catbytes(digestinfoprefix(hashlen), hashbytes(msg, hashlen));
		if(!pkcs1v15_verify(sig, rsakey, di))
			return "RSA signature verification failed";
	RSA_PSS_RSAE_SHA256 or RSA_PSS_RSAE_SHA384 =>
		if(scheme == RSA_PSS_RSAE_SHA256)
			hashlen = Keyring->SHA256dlen;
		else
			hashlen = Keyring->SHA384dlen;
		(rsakey, kerr) := extractrsakey(certs);
		if(kerr != nil)
			return kerr;
		perr := rsapss_verify(hashbytes(msg, hashlen), sig, rsakey);
		if(perr != nil)
			return perr;
	ECDSA_SECP256R1_SHA256 or ECDSA_SECP384R1_SHA384 or ECDSA_SHA512 =>
		(pt, perr) := extractecpointbytes(certs);
		if(pt == nil)
			return perr;
		digest := hashbytes(msg, hashlen);
		case len pt {
		65 =>
			if(tls13 && scheme != ECDSA_SECP256R1_SHA256)
				return "ECDSA scheme does not match the P-256 key";
			ecpt := keyring->p256_make_point(pt);
			raw := parse_ecdsa_der_sig_n(sig, 32);
			if(ecpt == nil || raw == nil)
				return "invalid ECDSA P-256 key or signature";
			if(!keyring->p256_ecdsa_verify(ecpt, digest, raw))
				return "ECDSA-P256 verification failed";
		97 =>
			if(tls13 && scheme != ECDSA_SECP384R1_SHA384)
				return "ECDSA scheme does not match the P-384 key";
			raw := parse_ecdsa_der_sig_n(sig, 48);
			if(raw == nil)
				return "invalid ECDSA P-384 signature";
			if(!keyring->p384_ecdsa_verify(pt, digest, raw))
				return "ECDSA-P384 verification failed";
		* =>
			return "unsupported EC key size";
		}
	* =>
		return sys->sprint("unsupported signature scheme 0x%04x", scheme);
	}
	return nil;
}

ECDSA_SHA512:	con 16r0603;	# TLS 1.2: ecdsa with SHA-512 (any curve); TLS 1.3: P-521, rejected by key size

hashbytes(msg: array of byte, hashlen: int): array of byte
{
	d := array [hashlen] of byte;
	case hashlen {
	Keyring->SHA384dlen =>	keyring->sha384(msg, len msg, d, nil);
	Keyring->SHA512dlen =>	keyring->sha512(msg, len msg, d, nil);
	* =>	keyring->sha256(msg, len msg, d, nil);
	}
	return d;
}

# DER DigestInfo prefixes for SHA-256/384/512 (RFC 8017 §9.2 note 1)
digestinfoprefix(hashlen: int): array of byte
{
	h := byte 16r01;
	l := byte 16r31;
	case hashlen {
	Keyring->SHA384dlen =>	h = byte 16r02; l = byte 16r41;
	Keyring->SHA512dlen =>	h = byte 16r03; l = byte 16r51;
	}
	return array [] of {
		byte 16r30, l, byte 16r30, byte 16r0d, byte 16r06, byte 16r09,
		byte 16r60, byte 16r86, byte 16r48, byte 16r01, byte 16r65, byte 16r03,
		byte 16r04, byte 16r02, h, byte 16r05, byte 16r00,
		byte 16r04, byte hashlen };
}

# EMSA-PKCS1-v1_5 verification (RFC 8017 §8.2.2): rebuild the whole encoded
# message 00 01 FF..FF 00 DigestInfo and compare exactly.
pkcs1v15_verify(sig: array of byte, key: ref RSAKey, digestinfo: array of byte): int
{
	k := key.modlen;
	if(len sig != k || len digestinfo > k - 11)
		return 0;
	x := IPint.bebytestoip(sig);
	if(x.cmp(key.modulus) >= 0)
		return 0;
	yb := x.expmod(key.exponent, key.modulus).iptobebytes();
	if(len yb > k)
		return 0;
	em := array [k] of {* => byte 0};
	em[k - len yb:] = yb;
	if(em[0] != byte 0 || em[1] != byte 1)
		return 0;
	pad := k - 3 - len digestinfo;
	for(i := 2; i < 2 + pad; i++)
		if(em[i] != byte 16rFF)
			return 0;
	if(em[2 + pad] != byte 0)
		return 0;
	return bytescmp(em[3 + pad:], digestinfo);
}

# MGF1 (RFC 8017 §B.2.1) with SHA-256 or SHA-384
mgf1(seed: array of byte, masklen, hashlen: int): array of byte
{
	mask := array [masklen] of byte;
	off := 0;
	for(c := 0; off < masklen; c++) {
		in := array [len seed + 4] of byte;
		in[0:] = seed;
		in[len seed] = byte (c >> 24);
		in[len seed + 1] = byte (c >> 16);
		in[len seed + 2] = byte (c >> 8);
		in[len seed + 3] = byte c;
		d := hashbytes(in, hashlen);
		n := len d;
		if(off + n > masklen)
			n = masklen - off;
		mask[off:] = d[0:n];
		off += n;
	}
	return mask;
}

# RSA-PSS verification (PKCS#1 v2.1, EMSA-PSS; SHA-256 or SHA-384 by
# the length of msghash, MGF1 with the same hash, salt length = hash length
# as TLS requires). RFC 8017 §8.1.2 + §9.1.2
rsapss_verify(msghash, sig: array of byte, rsakey: ref RSAKey): string
{
	hashlen := len msghash;
	if(hashlen != Keyring->SHA256dlen && hashlen != Keyring->SHA384dlen)
		return "PSS: unsupported hash";
	saltlen := hashlen;
	if(len sig != rsakey.modlen)
		return "PSS: bad signature length";

	# Step 1: raw RSA public-key operation (modular exponentiation).
	# Do NOT use pkcs->rsa_decrypt — that strips PKCS#1 v1.5 padding,
	# which PSS-encoded messages do not have.  RFC 8017 §8.1.2 step 2.
	em: array of byte;
	{
		x := IPint.bebytestoip(sig);
		y := x.expmod(rsakey.exponent, rsakey.modulus);
		ybytes := y.iptobebytes();
		k := rsakey.modlen;
		ylen := len ybytes;
		if(ylen < k) {
			em = array[k] of {* => byte 0};
			em[k-ylen:] = ybytes[0:];
		} else
			em = ybytes;
	}

	embits := rsakey.modlen * 8 - 1;
	emlen := (embits + 7) / 8;

	# Pad EM to emLen if needed
	if(len em < emlen) {
		padded := array [emlen] of {* => byte 0};
		padded[emlen - len em:] = em;
		em = padded;
	} else if(len em > emlen) {
		em = em[len em - emlen:];
	}

	# Step 3: check rightmost byte is 0xBC
	if(int em[emlen - 1] != 16rBC)
		return "PSS: invalid trailer";

	# Step 4: separate maskedDB and H
	dblen := emlen - hashlen - 1;
	if(dblen <= saltlen)
		return "PSS: encoded message too short";
	maskeddb := em[0:dblen];
	h := em[dblen:dblen + hashlen];

	# Step 5: check top bits are zero
	topbits := 8 * emlen - embits;
	if(topbits > 0 && (int maskeddb[0] & (16rFF << (8 - topbits))) != 0)
		return "PSS: non-zero top bits";

	# Step 6: MGF1 to unmask DB
	dbmask := mgf1(h, dblen, hashlen);

	# Step 7: DB = maskedDB XOR dbMask
	db := array [dblen] of byte;
	for(i := 0; i < dblen; i++)
		db[i] = maskeddb[i] ^ dbmask[i];

	# Step 8: clear top bits
	if(topbits > 0)
		db[0] &= byte (16rFF >> topbits);

	# Step 9: check padding (zeros followed by 0x01)
	pslen := dblen - saltlen - 1;
	for(j := 0; j < pslen; j++)
		if(int db[j] != 0)
			return "PSS: non-zero padding";
	if(int db[pslen] != 1)
		return "PSS: missing 0x01 separator";

	# Step 10: extract salt
	salt := db[dblen - saltlen:];

	# Step 11: compute M' = 0x00..00 (8 bytes) || mHash || salt
	mprime := array [8 + hashlen + saltlen] of byte;
	for(j = 0; j < 8; j++)
		mprime[j] = byte 0;
	mprime[8:] = msghash;
	mprime[8 + hashlen:] = salt;

	# Step 12: H' = Hash(M')
	hprime := hashbytes(mprime, hashlen);

	# Step 13: compare H and H'
	if(!bytescmp(h, hprime))
		return "PSS: hash mismatch";

	return nil;
}

verifyfinished13(cs: ref ConnState, data: array of byte, traffic_secret: array of byte): string
{
	return verifyfinished13_hash(cs, data, traffic_secret, hashcurrent(cs));
}

verifyfinished13_hash(cs: ref ConnState, data: array of byte, traffic_secret: array of byte,
	transcript_hash: array of byte): string
{
	hashlen := hashlength(cs.suite);
	if(len data != hashlen)
		return "tls: Finished wrong length";

	finished_key := hkdf_expand_label(cs.suite, traffic_secret, "finished", nil, hashlen);
	expected := hmac_hash(cs.suite, finished_key, transcript_hash);

	if(!bytescmp(data, expected))
		return "tls: server Finished verification failed";

	return nil;
}

# ================================================================
# RSA Public Key Extraction
# ================================================================

extractrsakey(certs: list of array of byte): (ref RSAKey, string)
{
	if(certs == nil)
		return (nil, "tls: no certificates");

	leaf := hd certs;

	# Decode the X.509 certificate Signed wrapper
	(serr, signed) := x509->Signed.decode(leaf);
	if(serr != nil)
		return (nil, "tls: decode cert: " + serr);

	# Decode the TBSCertificate
	(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
	if(cerr != nil)
		return (nil, "tls: decode TBSCert: " + cerr);

	# Extract public key from SubjectPublicKeyInfo
	(pkerr, _, pk) := cert.subject_pkinfo.getPublicKey();
	if(pkerr != nil)
		return (nil, "tls: extract key: " + pkerr);
	if(pk == nil)
		return (nil, "tls: no public key");

	pick rpk := pk {
	RSA =>
		return (rpk.pk, nil);
	* =>
		return (nil, "tls: not an RSA public key");
	}
}

# Extract raw EC public key bytes from leaf certificate (for P-384 and other curves)
extractecpointbytes(certs: list of array of byte): (array of byte, string)
{
	if(certs == nil)
		return (nil, "no certs");
	leaf := hd certs;

	(serr, signed) := x509->Signed.decode(leaf);
	if(serr != nil)
		return (nil, "decode cert: " + serr);
	(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
	if(cerr != nil)
		return (nil, "decode TBSCert: " + cerr);
	(pkerr, _, pk) := cert.subject_pkinfo.getPublicKey();
	if(pkerr != nil)
		return (nil, "getPublicKey: " + pkerr);
	if(pk == nil)
		return (nil, "no public key");

	pick epk := pk {
	EC =>
		return (epk.point, nil);
	* =>
		return (nil, "not an EC key");
	}
}

# Extract EC public key (ECpoint) from leaf certificate
extractecpoint(certs: list of array of byte): (ref Keyring->ECpoint, string)
{
	if(certs == nil)
		return (nil, "no certs");
	leaf := hd certs;

	(serr, signed) := x509->Signed.decode(leaf);
	if(serr != nil)
		return (nil, "decode cert: " + serr);
	(cerr, cert) := x509->Certificate.decode(signed.tobe_signed);
	if(cerr != nil)
		return (nil, "decode TBSCert: " + cerr);
	(pkerr, _, pk) := cert.subject_pkinfo.getPublicKey();
	if(pkerr != nil)
		return (nil, "getPublicKey: " + pkerr);
	if(pk == nil)
		return (nil, "no public key");

	pick epk := pk {
	EC =>
		pt := keyring->p256_make_point(epk.point);
		if(pt == nil)
			return (nil, "make_point failed");
		return (pt, nil);
	* =>
		return (nil, "not an EC key");
	}
}

# Parse DER-encoded ECDSA signature into raw r||s bytes.
# coordlen is the byte length of each scalar: 32 for P-256, 48 for P-384.
# Returns array of 2*coordlen bytes with r and s right-justified, or nil on error.
# TLS CertificateVerify provides raw DER (no BIT STRING unused-bits byte).
parse_ecdsa_der_sig_n(sig: array of byte, coordlen: int): array of byte
{
	(err, e) := asn1->decode(sig);
	if(err != nil)
		return nil;
	(ok, el) := e.is_seq();
	if(!ok || len el != 2)
		return nil;
	rbytes, sbytes: array of byte;
	(ok, rbytes) = (hd el).is_bigint();
	if(!ok)
		return nil;
	(ok, sbytes) = (hd tl el).is_bigint();
	if(!ok)
		return nil;

	rawsig := array [2 * coordlen] of {* => byte 0};
	# r: strip leading zeros, right-justify in coordlen bytes
	ri := 0;
	while(ri < len rbytes && rbytes[ri] == byte 0)
		ri++;
	rlen := len rbytes - ri;
	if(rlen > coordlen)
		return nil;
	rawsig[coordlen - rlen:] = rbytes[ri:];
	# s: strip leading zeros, right-justify in coordlen bytes
	si := 0;
	while(si < len sbytes && sbytes[si] == byte 0)
		si++;
	slen := len sbytes - si;
	if(slen > coordlen)
		return nil;
	rawsig[2*coordlen - slen:] = sbytes[si:];

	return rawsig;
}

# Convenience wrappers
parse_ecdsa_der_sig(sig: array of byte): array of byte
{
	return parse_ecdsa_der_sig_n(sig, 32);	# P-256: 32-byte scalars
}

parse_ecdsa_der_sig_p384(sig: array of byte): array of byte
{
	return parse_ecdsa_der_sig_n(sig, 48);	# P-384: 48-byte scalars
}

# ================================================================
# Handshake Message I/O
# ================================================================

sendhsmsg(cs: ref ConnState, mtype: int, data: array of byte): string
{
	msg := hsmsg(mtype, data);

	# Hash the handshake message
	updatehash(cs, msg);

	return writerecord(cs, CT_HANDSHAKE, msg);
}

readhsmsg(cs: ref ConnState): (int, array of byte, string)
{
	for(;;) {
		# a whole message buffered (a record may carry several): take it
		if(cs.hsbuf != nil && len cs.hsbuf - cs.hsoff >= 4) {
			rem := cs.hsbuf[cs.hsoff:];
			mtype := int rem[0];
			mlen := get24(rem, 1);
			limit := MAXHSMSG;
			if(cs.hsmax > 0)
				limit = cs.hsmax;
			if(mlen > limit)
				return (0, nil, "tls: handshake message too long");
			if(4 + mlen <= len rem) {
				updatehash(cs, rem[0:4+mlen]);
				cs.hsoff += 4 + mlen;
				if(cs.hsoff >= len cs.hsbuf) {
					cs.hsbuf = nil;
					cs.hsoff = 0;
				}
				return (mtype, rem[4:4+mlen], nil);
			}
		}

		# Read record (possibly encrypted)
		(ctype, payload, rerr) := readrecord(cs);
		if(rerr != nil) {
			# the connection ended part way through a message
			if(cs.hsbuf != nil && cs.hsoff < len cs.hsbuf) {
				if(len cs.hsbuf - cs.hsoff < 4)
					return (0, nil, "tls: handshake message too short");
				return (0, nil, "tls: handshake message truncated");
			}
			return (0, nil, rerr);
		}

		# TLS 1.3: silently skip CCS records (middlebox compatibility)
		if(ctype == CT_CHANGE_CIPHER_SPEC)
			continue;

		if(ctype == CT_ALERT) {
			if(len payload >= 2)
				return (0, nil, sys->sprint("tls: alert level=%d desc=%d",
					int payload[0], int payload[1]));
			return (0, nil, "tls: received alert");
		}

		if(ctype != CT_HANDSHAKE)
			return (0, nil, sys->sprint("tls: expected handshake, got type %d", ctype));

		# a message may be longer than a record, and go on in the
		# next (RFC 8446 §5.1, RFC 5246 §6.2.1): a certificate chain
		# often does.  What is left of the last record comes first.
		if(cs.hsbuf == nil || cs.hsoff >= len cs.hsbuf)
			cs.hsbuf = payload;
		else {
			rest := cs.hsbuf[cs.hsoff:];
			nb := array[len rest + len payload] of byte;
			nb[0:] = rest;
			nb[len rest:] = payload;
			cs.hsbuf = nb;
		}
		cs.hsoff = 0;
	}
}

# ================================================================
# Handshake Hashing
# ================================================================

updatehash(cs: ref ConnState, data: array of byte)
{
	# Both transcripts until the suite is known; hashcurrent() hashes
	# the one cs.suite needs.
	cs.tr256 = trcat(cs.tr256, data);
	cs.tr384 = trcat(cs.tr384, data);
}

# a then b, in a new array: the transcript shares no bytes with a
# buffer the record layer reuses.
trcat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

hashcurrent(cs: ref ConnState): array of byte
{
	# The transcript hash for the negotiated suite
	if(hashlength(cs.suite) == 48) {
		digest := array [Keyring->SHA384dlen] of byte;
		keyring->sha384(cs.tr384, len cs.tr384, digest, nil);
		return digest;
	}
	digest := array [Keyring->SHA256dlen] of byte;
	keyring->sha256(cs.tr256, len cs.tr256, digest, nil);
	return digest;
}

hashfinish(cs: ref ConnState): array of byte
{
	return hashcurrent(cs);
}

hash_empty(cs: ref ConnState): array of byte
{
	# Hash of empty string using the suite's hash algorithm
	hashlen := hashlength(cs.suite);
	digest := array [hashlen] of byte;
	if(hashlen == 48)
		keyring->sha384(nil, 0, digest, nil);
	else
		keyring->sha256(nil, 0, digest, nil);
	return digest;
}

# ================================================================
# Key Derivation
# ================================================================

# TLS 1.2 PRF — RFC 5246 §5: P_hash where hash is suite's PRF hash (SHA-256 or SHA-384)
tls12_prf(suite: int, secret, label, seed: array of byte, n: int): array of byte
{
	labelseed := catbytes(label, seed);
	result := array [n] of byte;
	off := 0;

	# A(0) = seed, A(i) = HMAC(secret, A(i-1))
	a := labelseed;
	while(off < n) {
		a = hmac_hash(suite, secret, a);
		p := hmac_hash(suite, secret, catbytes(a, labelseed));
		m := len p;
		if(off + m > n)
			m = n - off;
		result[off:] = p[0:m];
		off += m;
	}
	return result;
}

# HKDF-Extract (RFC 5869)
hkdf_extract(suite: int, salt, ikm: array of byte): array of byte
{
	return hmac_hash(suite, salt, ikm);
}

# HKDF-Expand (RFC 5869) — suite selects SHA-256 or SHA-384
hkdf_expand(suite: int, prk, info: array of byte, length: int): array of byte
{
	hashlen := hashlength(suite);
	n := (length + hashlen - 1) / hashlen;
	result := array [n * hashlen] of byte;
	t: array of byte;

	for(i := 1; i <= n; i++) {
		input: array of byte;
		if(t == nil)
			input = catbytes(info, array [1] of {byte i});
		else
			input = catbytes(t, catbytes(info, array [1] of {byte i}));
		t = hmac_hash(suite, prk, input);
		off := (i - 1) * hashlen;
		result[off:] = t;
	}
	return result[0:length];
}

# HKDF-Expand-Label (TLS 1.3) — suite selects hash algorithm
hkdf_expand_label(suite: int, secret: array of byte, label: string, context: array of byte, length: int): array of byte
{
	# HkdfLabel = length(2) + label_len(1) + "tls13 " + label + context_len(1) + context
	full_label := s2b("tls13 " + label);
	ctx := context;
	if(ctx == nil)
		ctx = array [0] of byte;

	info := array [2 + 1 + len full_label + 1 + len ctx] of byte;
	put16(info, 0, length);
	info[2] = byte len full_label;
	info[3:] = full_label;
	info[3 + len full_label] = byte len ctx;
	if(len ctx > 0)
		info[4 + len full_label:] = ctx;

	return hkdf_expand(suite, secret, info, length);
}

# Derive traffic keys from a traffic secret
derivekeys(secret: array of byte, suite: int): (array of byte, array of byte)
{
	keylen := keylength(suite);
	ivlen := 12;

	key := hkdf_expand_label(suite, secret, "key", nil, keylen);
	iv := hkdf_expand_label(suite, secret, "iv", nil, ivlen);

	return (key, iv);
}

# HMAC-SHA256
hmac256(key, data: array of byte): array of byte
{
	digest := array [Keyring->SHA256dlen] of byte;
	keyring->hmac_sha256(data, len data, key, digest, nil);
	return digest;
}

# HMAC using suite's hash algorithm
hmac_hash(suite: int, key, data: array of byte): array of byte
{
	hashlen := hashlength(suite);
	digest := array [hashlen] of byte;

	case hashlen {
	48 =>
		keyring->hmac_sha384(data, len data, key, digest, nil);
	* =>
		keyring->hmac_sha256(data, len data, key, digest, nil);
	}
	return digest;
}

# ================================================================
# Suite Parameters
# ================================================================

hashlength(suite: int): int
{
	case suite {
	TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 or
	TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 or
	TLS_RSA_WITH_AES_256_GCM_SHA384 or
	TLS_AES_256_GCM_SHA384 =>
		return 48;
	* =>
		return 32;
	}
}

TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:	con 16rC02C;

isecdhe(suite: int): int
{
	case suite {
	TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 or TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 or
	TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 or TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 =>
		return 1;
	}
	return 0;
}

keylength(suite: int): int
{
	case suite {
	TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 or
	TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 or
	TLS_AES_256_GCM_SHA384 or
	TLS_RSA_WITH_AES_256_GCM_SHA384 or
	TLS_CHACHA20_POLY1305_SHA256 =>	# ChaCha20 takes only a 256-bit key
		return 32;
	* =>
		return 16;
	}
}

keyblocklen(suite: int): int
{
	# For TLS 1.2 GCM: 2 * (key_len + iv_len)
	klen := keylength(suite);
	return 2 * (klen + 4);	# GCM uses 4-byte implicit IV for TLS 1.2
}

splitkeyblock(suite: int, keyblock: array of byte): (array of byte, array of byte, array of byte, array of byte)
{
	klen := keylength(suite);
	ivlen := 4;	# TLS 1.2 GCM implicit nonce
	off := 0;

	cw_key := keyblock[off:off+klen];
	off += klen;
	sw_key := keyblock[off:off+klen];
	off += klen;
	cw_iv := array [12] of {* => byte 0};
	cw_iv[0:] = keyblock[off:off+ivlen];
	off += ivlen;
	sw_iv := array [12] of {* => byte 0};
	sw_iv[0:] = keyblock[off:off+ivlen];

	return (cw_key, cw_iv, sw_key, sw_iv);
}

# ================================================================
# Utility Functions
# ================================================================

ensure(fd: ref Sys->FD, buf: array of byte, n: int): int
{
	i := 0;
	while(i < n) {
		m := sys->read(fd, buf[i:], n - i);
		if(m <= 0)
			return -1;
		i += m;
	}
	return n;
}

put16(buf: array of byte, off: int, val: int)
{
	buf[off] = byte (val >> 8);
	buf[off + 1] = byte val;
}

put24(buf: array of byte, off: int, val: int)
{
	buf[off] = byte (val >> 16);
	buf[off + 1] = byte (val >> 8);
	buf[off + 2] = byte val;
}

put64(buf: array of byte, off: int, val: big)
{
	for(i := 0; i < 8; i++) {
		shift := 56 - i * 8;
		buf[off + i] = byte (int (val >> shift) & 16rFF);
	}
}

get16(buf: array of byte, off: int): int
{
	return (int buf[off] << 8) | int buf[off + 1];
}

get24(buf: array of byte, off: int): int
{
	return (int buf[off] << 16) | (int buf[off + 1] << 8) | int buf[off + 2];
}

s2b(s: string): array of byte
{
	return array of byte s;
}

catbytes(a, b: array of byte): array of byte
{
	if(a == nil)
		return b;
	if(b == nil)
		return a;
	r := array [len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

bytescmp(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int a[i] ^ int b[i];
	return d == 0;
}

randombytes(n: int): array of byte
{
	buf := array [n] of byte;
	randombuf(buf, n);
	return buf;
}

# n bytes from the entropy source, or an exception: never bytes anyone
# could guess.  (It once fell back to the millisecond clock, and took a
# short read as whole: a process whose name space had no #c -- a server
# after pctl(NODEVS) -- would have made its keys from the time.)
randombuf(buf: array of byte, n: int)
{
	if(randomfd == nil) {
		# init() not called: open one now
		fd := sys->open("#c/notquiterandom", Sys->OREAD);
		if(fd == nil)
			fd = sys->open("/dev/urandom", Sys->OREAD);
		if(fd == nil)
			fd = sys->open("#c/random", Sys->OREAD);
		randomfd = fd;
	}
	if(randomfd == nil)
		raise "tls: no entropy source";
	for(i := 0; i < n; ) {
		m := sys->read(randomfd, buf[i:], n - i);
		if(m <= 0)
			raise "tls: entropy source failed";
		i += m;
	}
}

keptfds(): list of int
{
	if(randomfd == nil)
		return nil;
	return randomfd.fd :: nil;
}

# ================================================================
# Post-handshake messages (both sides, TLS 1.3)
# ================================================================

# The handshake messages in one record after the handshake: 0, or -1
# for one we cannot take.  A KeyUpdate from the peer moves our reading
# keys on (RFC 8446 §4.6.3); a server asked for one of its own updates
# its writing keys too.  A client does not: another of its threads may
# be writing, and the new keys would race it (the server is told
# nothing, and goes on reading the old keys, as RFC 8446 allows it to
# stop the connection).
posthandshake(cs: ref ConnState, data: array of byte): int
{
	if(cs.version != TLS13)
		return 0;	# TLS 1.2's HelloRequest and the like: ignored, as before
	off := 0;
	while(off < len data) {
		if(off + 4 > len data) {
			if(cs.isserver)
				return -1;
			return 0;	# a ticket split over records: not ours to keep
		}
		mtype := int data[off];
		mlen := get24(data, off+1);
		if(off + 4 + mlen > len data) {
			if(cs.isserver)
				return -1;
			return 0;
		}
		body := data[off+4:off+4+mlen];
		off += 4 + mlen;
		case mtype {
		HT_KEY_UPDATE =>
			if(mlen != 1 || int body[0] > 1)
				return -1;
			hashlen := hashlength(cs.suite);
			if(cs.isserver) {
				cs.cts = hkdf_expand_label(cs.suite, cs.cts, "traffic upd", nil, hashlen);
				(cs.readkey, cs.readiv) = derivekeys(cs.cts, cs.suite);
			} else {
				cs.sts = hkdf_expand_label(cs.suite, cs.sts, "traffic upd", nil, hashlen);
				(cs.readkey, cs.readiv) = derivekeys(cs.sts, cs.suite);
			}
			cs.readseq = big 0;
			if(cs.isserver && int body[0] == 1) {
				# our own, sent under the old keys, then the new
				if(writerecord(cs, CT_HANDSHAKE, hsmsg(HT_KEY_UPDATE, array[1] of {byte 0})) != nil)
					return -1;
				cs.sts = hkdf_expand_label(cs.suite, cs.sts, "traffic upd", nil, hashlen);
				(cs.writekey, cs.writeiv) = derivekeys(cs.sts, cs.suite);
				cs.writeseq = big 0;
			}
		HT_NEW_SESSION_TICKET =>
			if(cs.isserver)
				return -1;
		* =>
			return -1;
		}
	}
	return 0;
}

# ================================================================
# Server (TLS 1.3 only)
# ================================================================
#
# What a ClientHello offers.  Each list is in the order the client
# sent it.

Hello: adt {
	sessid:		array of byte;
	suites:		list of int;
	versions:	list of int;
	groups:		list of int;
	shares:		list of (int, array of byte);
	sigalgs:	list of int;
	sni:		string;
	alpn:		list of string;
	hasalpn:	int;
	hassigalgs:	int;
	haskeyshare:	int;
};

# The suites a server takes, and the groups, in its preference.  The
# client's order decides among suites (it knows whether it has AES
# instructions); ours among groups, the post-quantum hybrid first.
servergroups(): list of int
{
	return GROUP_X25519MLKEM768 :: GROUP_X25519 :: GROUP_SECP256R1 :: nil;
}

serversuite(s: int): int
{
	return s == TLS_AES_128_GCM_SHA256 || s == TLS_AES_256_GCM_SHA384 ||
		s == TLS_CHACHA20_POLY1305_SHA256;
}

sharelen(group: int): int
{
	case group {
	GROUP_X25519 =>
		return 32;
	GROUP_SECP256R1 =>
		return 65;
	GROUP_X25519MLKEM768 =>
		return MLKEM768_EKLEN + 32;
	}
	return -1;
}

server(fd: ref Sys->FD, config: ref ServerConfig): (ref Conn, string)
{
	if(config == nil || config.certs == nil || len config.key != 32)
		return (nil, "tls: server has no certificate or key");
	cs := ref ConnState;
	cs.fd = fd;
	cs.isserver = 1;
	cs.hsmax = config.maxhello;
	if(cs.hsmax <= 0)
		cs.hsmax = 16384;
	cs.writeseq = big 0;
	cs.readseq = big 0;

	alpn: string;
	err: string;
	alert := 0;
	{
		(alert, alpn, err) = server0(cs, config);
	} exception e {
	"tls:*" =>
		(alert, err) = (ALERT_INTERNAL_ERROR, e);
	"*" =>
		# the peer's end gone under a write ("write on closed
		# pipe"), and the like: an error, not an exception
		(alert, err) = (0, "tls: " + e);
	}
	clearephemeral(cs);
	if(err != nil) {
		if(alert != 0) {
			# best effort, under whatever keys are set
			a := array[2] of byte;
			a[0] = byte ALERT_FATAL;
			a[1] = byte alert;
			writerecord(cs, CT_ALERT, a);
		}
		return (nil, err);
	}
	cs.hsmax = 0;

	conn := ref Conn;
	conn.version = cs.version;
	conn.suite = cs.suite;
	conn.group = cs.group;
	conn.servername = cs.servername;
	conn.alpn = alpn;
	conn.st = cs;
	return (conn, nil);
}

# The handshake: (alert to send or 0, ALPN protocol, error or nil)
server0(cs: ref ConnState, config: ref ServerConfig): (int, string, string)
{
	(mtype, ch, err) := readhsmsg(cs);
	if(err != nil)
		return (0, nil, err);
	if(mtype != HT_CLIENT_HELLO)
		return (ALERT_UNEXPECTED_MESSAGE, nil, "tls: expected ClientHello");
	(h, alert, herr) := parsehello(ch);
	if(herr != nil)
		return (alert, nil, herr);
	if(!member(h.versions, TLS13))
		return (ALERT_PROTOCOL_VERSION, nil, "tls: client does not offer TLS 1.3");

	# ours if we say (the cipher fastest here), else the client's order
	suite := 0;
	for(l := config.suites; l != nil && suite == 0; l = tl l)
		if(serversuite(hd l) && member(h.suites, hd l))
			suite = hd l;
	for(l = h.suites; l != nil && suite == 0; l = tl l)
		if(serversuite(hd l))
			suite = hd l;
	if(suite == 0)
		return (ALERT_HANDSHAKE_FAILURE, nil, "tls: no cipher suite in common");
	if(!h.hassigalgs)
		return (ALERT_MISSING_EXTENSION, nil, "tls: no signature_algorithms");
	if(!member(h.sigalgs, ECDSA_SECP256R1_SHA256))
		return (ALERT_HANDSHAKE_FAILURE, nil, "tls: client does not take ecdsa_secp256r1_sha256");
	if(!h.haskeyshare)
		return (ALERT_MISSING_EXTENSION, nil, "tls: no key_share");

	alpn: string;
	if(h.hasalpn && config.alpn != nil) {
		for(a := config.alpn; a != nil && alpn == nil; a = tl a)
			for(b := h.alpn; b != nil; b = tl b)
				if(hd a == hd b) {
					alpn = hd a;
					break;
				}
		if(alpn == nil)
			return (ALERT_NO_APPLICATION_PROTOCOL, nil, "tls: no application protocol in common");
	}

	# A group the client sent a share for, else one it supports with no
	# share: asked for by HelloRetryRequest, once.
	group := 0;
	share: array of byte;
	for(g := servergroups(); g != nil && group == 0; g = tl g)
		if((d := sharefor(h.shares, hd g)) != nil) {
			group = hd g;
			share = d;
		}
	cs.suite = suite;
	cs.version = TLS13;
	sentccs := 0;
	if(group == 0) {
		for(g = servergroups(); g != nil && group == 0; g = tl g)
			if(member(h.groups, hd g))
				group = hd g;
		if(group == 0)
			return (ALERT_HANDSHAKE_FAILURE, nil, "tls: no key exchange group in common");

		hrr := buildserverhello(hexbytes(HRRRANDOM), h.sessid, suite, group, nil);
		hrrtranscript(cs, hsmsg(HT_CLIENT_HELLO, ch), hsmsg(HT_SERVER_HELLO, hrr));
		if((err = writerecord(cs, CT_HANDSHAKE, hsmsg(HT_SERVER_HELLO, hrr))) != nil)
			return (0, nil, err);
		if(len h.sessid > 0) {
			if((err = sendccs(cs)) != nil)
				return (0, nil, err);
			sentccs = 1;
		}

		ch2: array of byte;
		(mtype, ch2, err) = readhsmsg(cs);
		if(err != nil)
			return (0, nil, err);
		if(mtype != HT_CLIENT_HELLO)
			return (ALERT_UNEXPECTED_MESSAGE, nil, "tls: expected a second ClientHello");
		h2: ref Hello;
		(h2, alert, herr) = parsehello(ch2);
		if(herr != nil)
			return (alert, nil, herr);
		# §4.1.2: the same but for the share asked for
		if(!member(h2.versions, TLS13) || !member(h2.suites, suite) ||
		   !bytescmp(h2.sessid, h.sessid))
			return (ALERT_ILLEGAL_PARAMETER, nil, "tls: second ClientHello differs from the first");
		if(h2.shares == nil || tl h2.shares != nil || (hd h2.shares).t0 != group)
			return (ALERT_ILLEGAL_PARAMETER, nil, "tls: second ClientHello does not answer the HelloRetryRequest");
		share = (hd h2.shares).t1;
		h = h2;
	}
	cs.group = group;
	cs.servername = h.sni;

	(myshare, secret, kerr) := serverkeyex(cs, group, share);
	if(kerr != nil)
		return (ALERT_ILLEGAL_PARAMETER, nil, kerr);

	sh := buildserverhello(randombytes(32), h.sessid, suite, group, myshare);
	if((err = sendhsmsg(cs, HT_SERVER_HELLO, sh)) != nil)
		return (0, nil, err);
	if(len h.sessid > 0 && !sentccs)
		if((err = sendccs(cs)) != nil)
			return (0, nil, err);

	# The key schedule (RFC 8446 §7.1), as the client's but turned round
	hashlen := hashlength(suite);
	zeros := array [hashlen] of {* => byte 0};
	early_secret := hkdf_extract(suite, zeros, zeros);
	derived := hkdf_expand_label(suite, early_secret, "derived", hash_empty(cs), hashlen);
	hs_secret := hkdf_extract(suite, derived, secret);
	wipebytes(secret);
	hs_hash := hashcurrent(cs);
	c_hs := hkdf_expand_label(suite, hs_secret, "c hs traffic", hs_hash, hashlen);
	s_hs := hkdf_expand_label(suite, hs_secret, "s hs traffic", hs_hash, hashlen);
	(cs.readkey, cs.readiv) = derivekeys(c_hs, suite);
	(cs.writekey, cs.writeiv) = derivekeys(s_hs, suite);
	cs.readseq = big 0;
	cs.writeseq = big 0;
	cs.hsencrypted = 1;

	# EncryptedExtensions: the protocol agreed, if any
	ee: array of byte;
	if(alpn != nil) {
		ab := s2b(alpn);
		ee = array[2 + 4 + 2 + 1 + len ab] of byte;
		put16(ee, 0, 4 + 2 + 1 + len ab);
		put16(ee, 2, EXT_ALPN);
		put16(ee, 4, 2 + 1 + len ab);
		put16(ee, 6, 1 + len ab);
		ee[8] = byte len ab;
		ee[9:] = ab;
	} else
		ee = array[2] of {* => byte 0};
	if((err = sendhsmsg(cs, HT_ENCRYPTED_EXTENSIONS, ee)) != nil)
		return (0, nil, err);

	# Certificate: no context, each entry with no extensions
	total := 0;
	for(c := config.certs; c != nil; c = tl c)
		total += 3 + len hd c + 2;
	cm := array[1 + 3 + total] of byte;
	cm[0] = byte 0;
	put24(cm, 1, total);
	off := 4;
	for(c = config.certs; c != nil; c = tl c) {
		put24(cm, off, len hd c);
		cm[off+3:] = hd c;
		off += 3 + len hd c;
		put16(cm, off, 0);
		off += 2;
	}
	if((err = sendhsmsg(cs, HT_CERTIFICATE, cm)) != nil)
		return (0, nil, err);

	(cv, cverr) := certverify13("TLS 1.3, server CertificateVerify", hashcurrent(cs), config.key);
	if(cverr != nil)
		return (ALERT_INTERNAL_ERROR, nil, cverr);
	if((err = sendhsmsg(cs, HT_CERTIFICATE_VERIFY, cv)) != nil)
		return (0, nil, err);

	fkey := hkdf_expand_label(suite, s_hs, "finished", nil, hashlen);
	if((err = sendhsmsg(cs, HT_FINISHED, hmac_hash(suite, fkey, hashcurrent(cs)))) != nil)
		return (0, nil, err);

	# the application secrets cover the transcript through our Finished
	md := hkdf_expand_label(suite, hs_secret, "derived", hash_empty(cs), hashlen);
	master := hkdf_extract(suite, md, zeros);
	app_hash := hashcurrent(cs);
	cs.cts = hkdf_expand_label(suite, master, "c ap traffic", app_hash, hashlen);
	cs.sts = hkdf_expand_label(suite, master, "s ap traffic", app_hash, hashlen);
	wipebytes(hs_secret);
	wipebytes(master);

	# the client's Finished, under its handshake keys; nothing else
	# (we asked for no certificate)
	pre := hashcurrent(cs);
	fin: array of byte;
	(mtype, fin, err) = readhsmsg(cs);
	if(err != nil)
		return (0, nil, err);
	if(mtype != HT_FINISHED)
		return (ALERT_UNEXPECTED_MESSAGE, nil, "tls: expected the client's Finished");
	if(verifyfinished13_hash(cs, fin, c_hs, pre) != nil)
		return (ALERT_DECRYPT_ERROR, nil, "tls: client Finished verification failed");
	if(cs.hsbuf != nil && cs.hsoff < len cs.hsbuf)
		return (ALERT_UNEXPECTED_MESSAGE, nil, "tls: data after the client's Finished in its record");
	wipebytes(c_hs);
	wipebytes(s_hs);

	(cs.readkey, cs.readiv) = derivekeys(cs.cts, suite);
	(cs.writekey, cs.writeiv) = derivekeys(cs.sts, suite);
	cs.readseq = big 0;
	cs.writeseq = big 0;
	cs.tr256 = nil;
	cs.tr384 = nil;
	return (0, alpn, nil);
}

# Our share and the shared secret for the client's share in group.
serverkeyex(cs: ref ConnState, group: int, share: array of byte): (array of byte, array of byte, string)
{
	if(len share != sharelen(group))
		return (nil, nil, "tls: client key share is the wrong length");
	case group {
	GROUP_X25519 =>
		(pub, ss) := x25519pair(share);
		if(ss == nil)
			return (nil, nil, "tls: X25519 key share is not usable");
		return (pub, ss, nil);
	GROUP_X25519MLKEM768 =>
		# client: ML-KEM-768 ek || X25519; ours: ciphertext || X25519
		ct, kss: array of byte;
		{
			(ct, kss) = keyring->mlkem768_encaps(share[0:MLKEM768_EKLEN]);
		} exception {
		* =>
			ct = nil;
		}
		if(ct == nil || kss == nil || len ct != MLKEM768_CTLEN)
			return (nil, nil, "tls: ML-KEM-768 key share is not usable");
		(pub, xss) := x25519pair(share[MLKEM768_EKLEN:]);
		if(xss == nil)
			return (nil, nil, "tls: X25519 key share is not usable");
		return (catbytes(ct, pub), catbytes(kss, xss), nil);
	GROUP_SECP256R1 =>
		pt := keyring->p256_make_point(share);
		if(pt == nil)
			return (nil, nil, "tls: P-256 key share is not a point on the curve");
		(priv, mine) := keyring->p256_keygen();
		if(priv == nil || mine == nil)
			return (nil, nil, "tls: P-256 key generation failed");
		cs.eph_p256_priv = priv;
		ss := keyring->p256_ecdh(priv, pt);
		if(ss == nil)
			return (nil, nil, "tls: P-256 ECDH failed");
		return (keyring->p256_point_bytes(mine), ss, nil);
	}
	return (nil, nil, "tls: unsupported group");
}

# A fresh X25519 key's public half and its secret with peer, or nil
# for a peer whose secret comes out all zeros (a small-order point,
# RFC 8446 §7.4.2).
x25519pair(peer: array of byte): (array of byte, array of byte)
{
	priv := randombytes(32);
	pub := keyring->x25519_base(priv);
	ss := keyring->x25519(priv, peer);
	wipebytes(priv);
	if(pub == nil || ss == nil || len ss != 32)
		return (nil, nil);
	z := 0;
	for(i := 0; i < len ss; i++)
		z |= int ss[i];
	if(z == 0)
		return (nil, nil);
	return (pub, ss);
}

# A ServerHello (or, with HRRRANDOM, a HelloRetryRequest: share nil,
# the key_share then the group alone)
buildserverhello(random, sessid: array of byte, suite, group: int, share: array of byte): array of byte
{
	kslen := 2;
	if(share != nil)
		kslen = 4 + len share;
	extlen := 4 + 2 + 4 + kslen;
	b := array[2 + 32 + 1 + len sessid + 2 + 1 + 2 + extlen] of byte;
	off := 0;
	put16(b, off, RECVERSION);
	off += 2;
	b[off:] = random;
	off += 32;
	b[off++] = byte len sessid;
	b[off:] = sessid;
	off += len sessid;
	put16(b, off, suite);
	off += 2;
	b[off++] = byte 0;
	put16(b, off, extlen);
	off += 2;
	put16(b, off, EXT_SUPPORTED_VERSIONS);
	put16(b, off+2, 2);
	put16(b, off+4, TLS13);
	off += 6;
	put16(b, off, EXT_KEY_SHARE);
	put16(b, off+2, kslen);
	put16(b, off+4, group);
	if(share != nil) {
		put16(b, off+6, len share);
		b[off+8:] = share;
	}
	return b;
}

sendccs(cs: ref ConnState): string
{
	return writerecord(cs, CT_CHANGE_CIPHER_SPEC, array[1] of {byte 1});
}

hexbytes(s: string): array of byte
{
	b := array[len s / 2] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte ((hexval(s[2*i]) << 4) | hexval(s[2*i+1]));
	return b;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

# A ClientHello's offers, checked as RFC 8446 §4.1.2 and §4.2 have
# them: (offers, alert, error)
parsehello(d: array of byte): (ref Hello, int, string)
{
	nohello: ref Hello;
	bad := (nohello, ALERT_DECODE_ERROR, "tls: malformed ClientHello");
	h := ref Hello;
	if(len d < 2 + 32 + 1)
		return bad;
	off := 34;
	n := int d[off++];
	if(n > 32 || off + n + 2 > len d)
		return bad;
	h.sessid = d[off:off+n];
	off += n;
	n = get16(d, off);
	off += 2;
	if(n < 2 || n & 1 || off + n + 1 > len d)
		return bad;
	h.suites = list16(d[off:off+n]);
	off += n;
	n = int d[off++];
	if(n < 1 || off + n > len d)
		return bad;
	# TLS 1.3: the null method alone
	if(n != 1 || d[off] != byte 0)
		return (nil, ALERT_ILLEGAL_PARAMETER, "tls: ClientHello offers compression");
	off += n;
	if(off == len d)
		return (nil, ALERT_PROTOCOL_VERSION, "tls: ClientHello has no extensions (not TLS 1.3)");
	if(off + 2 > len d)
		return bad;
	end := off + 2 + get16(d, off);
	off += 2;
	if(end != len d)
		return bad;
	seen: list of int;
	nexts := 0;
	while(off < end) {
		if(off + 4 > end)
			return bad;
		etype := get16(d, off);
		elen := get16(d, off+2);
		off += 4;
		if(off + elen > end)
			return bad;
		if(member(seen, etype))
			return (nil, ALERT_ILLEGAL_PARAMETER, sys->sprint("tls: ClientHello repeats extension %d", etype));
		seen = etype :: seen;
		if(++nexts > 64)
			return bad;
		e := d[off:off+elen];
		off += elen;
		case etype {
		EXT_SERVER_NAME =>
			if(elen < 2 || get16(e, 0) != elen - 2)
				return bad;
			for(o := 2; o < elen; ) {
				if(o + 3 > elen)
					return bad;
				nl := get16(e, o+1);
				if(o + 3 + nl > elen)
					return bad;
				if(int e[o] == 0 && h.sni == nil) {
					name := string e[o+3:o+3+nl];
					if(!hostname(name))
						return (nil, ALERT_ILLEGAL_PARAMETER, "tls: server_name is not a host name");
					h.sni = strlower(name);
				}
				o += 3 + nl;
			}
		EXT_SUPPORTED_GROUPS =>
			if(elen < 2 || get16(e, 0) != elen - 2 || elen & 1)
				return bad;
			h.groups = list16(e[2:]);
		EXT_SIGNATURE_ALGORITHMS =>
			if(elen < 2 || get16(e, 0) != elen - 2 || elen & 1)
				return bad;
			h.sigalgs = list16(e[2:]);
			h.hassigalgs = 1;
		EXT_ALPN =>
			if(elen < 2 || get16(e, 0) != elen - 2)
				return bad;
			h.hasalpn = 1;
			protos: list of string;
			for(o := 2; o < elen; ) {
				pl := int e[o];
				if(pl == 0 || o + 1 + pl > elen)
					return bad;
				protos = string e[o+1:o+1+pl] :: protos;
				o += 1 + pl;
			}
			for(; protos != nil; protos = tl protos)
				h.alpn = hd protos :: h.alpn;
		EXT_SUPPORTED_VERSIONS =>
			if(elen < 1 || int e[0] != elen - 1 || (elen - 1) & 1)
				return bad;
			h.versions = list16(e[1:]);
		EXT_KEY_SHARE =>
			if(elen < 2 || get16(e, 0) != elen - 2)
				return bad;
			h.haskeyshare = 1;
			rev: list of (int, array of byte);
			groups: list of int;
			for(o := 2; o < elen; ) {
				if(o + 4 > elen)
					return bad;
				g := get16(e, o);
				kl := get16(e, o+2);
				if(kl == 0 || o + 4 + kl > elen)
					return bad;
				if(member(groups, g))
					return (nil, ALERT_ILLEGAL_PARAMETER, "tls: key_share repeats a group");
				groups = g :: groups;
				rev = (g, e[o+4:o+4+kl]) :: rev;
				o += 4 + kl;
			}
			for(; rev != nil; rev = tl rev)
				h.shares = hd rev :: h.shares;
		EXT_PRE_SHARED_KEY =>
			# §4.2.11: the last extension.  We hold no tickets, and
			# answer as though it were not there.
			if(off != end)
				return (nil, ALERT_ILLEGAL_PARAMETER, "tls: pre_shared_key is not the last extension");
		}
	}
	return (h, 0, nil);
}

list16(b: array of byte): list of int
{
	l: list of int;
	for(i := len b - 2; i >= 0; i -= 2)
		l = get16(b, i) :: l;
	return l;
}

# A DNS name as SNI carries one: letters, digits, '-', '_' and '.',
# 1 to 253 bytes, no empty label.
hostname(s: string): int
{
	if(len s == 0 || len s > 253 || s[0] == '.' || s[len s - 1] == '.')
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		     c == '-' || c == '_' || c == '.'))
			return 0;
		if(c == '.' && s[i+1] == '.')
			return 0;
	}
	return 1;
}

checkserver(config: ref ServerConfig): string
{
	if(config == nil || config.certs == nil)
		return "no certificate";
	if(len config.key != 32)
		return "the key is not a P-256 private key";
	for(c := config.certs; c != nil; c = tl c) {
		(serr, nil) := x509->Signed.decode(hd c);
		if(serr != nil)
			return "a certificate does not parse: " + serr;
	}
	(pt, perr) := extractecpoint(config.certs);
	if(perr != nil)
		return "the certificate's key is not P-256 (" + perr + ")";
	digest := array[Keyring->SHA256dlen] of byte;
	msg := array of byte "InferNode TLS: does this key match its certificate?";
	keyring->sha256(msg, len msg, digest, nil);
	sig: array of byte;
	{
		sig = keyring->p256_ecdsa_sign(config.key, digest);
	} exception {
	* =>
		sig = nil;
	}
	if(sig == nil || keyring->p256_ecdsa_verify(pt, digest, sig) != 1)
		return "the key is not the certificate's";
	return nil;
}

pemblocks(pem: string, label: string): list of array of byte
{
	begin := "-----BEGIN " + label + "-----";
	end := "-----END " + label + "-----";
	rev: list of array of byte;
	for(;;) {
		i := strfind(pem, begin);
		if(i < 0)
			break;
		pem = pem[i + len begin:];
		j := strfind(pem, end);
		if(j < 0)
			break;
		b := unbase64(pem[0:j]);
		if(b == nil)
			return nil;
		rev = b :: rev;
		pem = pem[j + len end:];
	}
	l: list of array of byte;
	for(; rev != nil; rev = tl rev)
		l = hd rev :: l;
	return l;
}

strfind(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

# Base64 with white space between; nil for anything else
unbase64(s: string): array of byte
{
	out := array[len s * 3 / 4 + 3] of byte;
	n := 0;
	acc := 0;
	bits := 0;
	pad := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		v := -1;
		if(c >= 'A' && c <= 'Z')
			v = c - 'A';
		else if(c >= 'a' && c <= 'z')
			v = c - 'a' + 26;
		else if(c >= '0' && c <= '9')
			v = c - '0' + 52;
		else if(c == '+')
			v = 62;
		else if(c == '/')
			v = 63;
		else if(c == '=') {
			pad++;
			continue;
		} else if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
			continue;
		else
			return nil;
		if(pad)
			return nil;
		acc = (acc << 6) | v;
		bits += 6;
		if(bits >= 8) {
			bits -= 8;
			out[n++] = byte (acc >> bits);
			acc &= (1 << bits) - 1;
		}
	}
	return out[0:n];
}

# prime256v1, 1.2.840.10045.3.1.7, as DER content
P256OID := array[] of {byte 16r2A, byte 16r86, byte 16r48, byte 16rCE, byte 16r3D, byte 16r03, byte 16r01, byte 16r07};

p256key(der: array of byte): (array of byte, string)
{
	(t, h, n) := dertlv(der, 0);
	if(t != 16r30 || h + n != len der)
		return (nil, "not a DER key");
	off := h;
	(t, h, n) = dertlv(der, off);
	if(t != 16r02 || n != 1)
		return (nil, "not a private key");
	version := int der[off+h];
	off += h + n;
	case version {
	0 =>
		# PKCS #8: AlgorithmIdentifier { id-ecPublicKey, prime256v1 },
		# then the SEC1 key in an OCTET STRING
		(t, h, n) = dertlv(der, off);
		if(t != 16r30)
			return (nil, "not a PKCS #8 key");
		if(!hasbytes(der[off+h:off+h+n], P256OID))
			return (nil, "not a P-256 key");
		off += h + n;
		(t, h, n) = dertlv(der, off);
		if(t != 16r04)
			return (nil, "not a PKCS #8 key");
		return p256key(der[off+h:off+h+n]);
	1 =>
		# SEC1 ECPrivateKey: privateKey OCTET STRING, [0] the curve
		(t, h, n) = dertlv(der, off);
		if(t != 16r04 || n != 32)
			return (nil, "not a P-256 private key");
		k := der[off+h:off+h+n];
		off += h + n;
		(t, h, n) = dertlv(der, off);
		if(t == 16rA0 && !hasbytes(der[off+h:off+h+n], P256OID))
			return (nil, "not a P-256 key");
		key := array[32] of byte;
		key[0:] = k;
		return (key, nil);
	}
	return (nil, "not a private key we know");
}

hasbytes(a, b: array of byte): int
{
	for(i := 0; i + len b <= len a; i++)
		if(bytescmp(a[i:i+len b], b))
			return 1;
	return 0;
}

fastsuites(): list of int
{
	key := array[32] of {* => byte 16r5A};
	nonce := array[12] of {* => byte 16rA5};
	rec := array[MAXRECORD + 1] of {* => byte 16r33};
	aad := array[5] of {* => byte 16r17};
	suites := array[] of {TLS_AES_128_GCM_SHA256, TLS_CHACHA20_POLY1305_SHA256, TLS_AES_256_GCM_SHA384};
	cost := array[len suites] of int;
	for(i := 0; i < len suites; i++) {
		k := key[0:keylength(suites[i])];
		t0 := sys->millisec();
		n := 0;
		# at least 8 records and 20ms: a coarse clock on a slow board
		while(n < 8 || sys->millisec() - t0 < 20) {
			if(suites[i] == TLS_CHACHA20_POLY1305_SHA256)
				keyring->ccpolyencrypt(rec, aad, k, nonce);
			else
				keyring->aesgcmencrypt(keyring->aesgcmsetup(k, nonce), rec, aad);
			n++;
		}
		cost[i] = (sys->millisec() - t0) * 1000 / n;
	}
	# cheapest first; ties keep the order above
	l: list of int;
	for(j := 0; j < len suites; j++) {
		best := -1;
		for(i = 0; i < len suites; i++)
			if(cost[i] >= 0 && (best < 0 || cost[i] < cost[best]))
				best = i;
		l = suites[best] :: l;
		cost[best] = -1;
	}
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
