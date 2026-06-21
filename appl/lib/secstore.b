implement Secstore;

#
# interact with the Plan 9 secstore
#

include "sys.m";
	sys: Sys;

include "dial.m";
	dialler: Dial;

include "keyring.m";
	kr: Keyring;
	DigestState, IPint: import kr;
	AESbsize, AESstate: import kr;

include "security.m";
	ssl: SSL;
	random: Random;

include "encoding.m";
	base64: Encoding;

include "secstore.m";


init()
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	random = load Random Random->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		raise "fail:cannot load base64";
	dialler = load Dial Dial->PATH;
	if(dialler == nil)
		raise "fail:cannot load Dial";
	initPAKparams();
}

# PAK_Hi cache — deterministic function of (user, pwhash), expensive to compute
cached_pakhi_version: string;
cached_pakhi_user: string;
cached_pakhi_pwhash: array of byte;
cached_pakhi_hexHi: string;
cached_pakhi_H: ref IPint;

pwhash_eq(a, b: array of byte): int
{
	if(a == nil || b == nil)
		return 0;
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

privacy(): int
{
	fd := sys->open("#p/"+string sys->pctl(0, nil)+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "private") < 0)
		return 0;
	return 1;
}

connect(addr: string, user: string, pwhash: array of byte): (ref Dial->Connection, string, string)
{
	return connectver(addr, user, VERSION1, pwhash);
}

connect2(addr: string, user: string, pwhash: array of byte, pwhash2: array of byte): (ref Dial->Connection, string, string)
{
	conn: ref Dial->Connection;
	sname, diag: string;
	lastdiag := "no secstore credentials";

	if(pwhash2 != nil){
		(conn, sname, diag) = connectver(addr, user, VERSION3, pwhash2);
		if(conn != nil)
			return (conn, sname, diag);
		lastdiag = diag;

		(conn, sname, diag) = connectver(addr, user, VERSION2, pwhash2);
		if(conn != nil)
			return (conn, sname, diag);
		lastdiag = diag;
	}
	if(pwhash != nil)
		return connectver(addr, user, VERSION1, pwhash);
	return (nil, nil, lastdiag);
}

connectver(addr: string, user: string, version: string, pwhash: array of byte): (ref Dial->Connection, string, string)
{
	params := pakparams(version);
	if(params == nil)
		return (nil, nil, "unsupported verifier version");

	# Pre-compute PAK crypto before dialing to avoid TCP idle timeout.
	# Use cached PAK_Hi if (user, pwhash) match — avoids expensive modexp.
	hexHi: string;
	H: ref IPint;
	if(cached_pakhi_version == version && cached_pakhi_user == user && pwhash_eq(cached_pakhi_pwhash, pwhash)
	   && cached_pakhi_hexHi != nil) {
		sys->fprint(sys->fildes(2), "secstore: step 1: PAK_Hi (cached)\n");
		hexHi = cached_pakhi_hexHi;
		H = cached_pakhi_H;
	} else {
		sys->fprint(sys->fildes(2), "secstore: step 1: PAK_Hi...\n");
		(hexHi, H, nil) = PAK_Hiver(version, user, pwhash);
		# Cache for next time
		cached_pakhi_version = version;
		cached_pakhi_user = user;
		cached_pakhi_pwhash = array[len pwhash] of byte;
		cached_pakhi_pwhash[0:] = pwhash;
		cached_pakhi_hexHi = hexHi;
		cached_pakhi_H = H;
	}
	sys->fprint(sys->fildes(2), "secstore: step 2: random...\n");
	x := mod(IPint.random(exponentbits(version), exponentbits(version)), params.q);
	if(x.eq(IPint.inttoip(0)))
		x = IPint.inttoip(1);
	sys->fprint(sys->fildes(2), "secstore: step 3: g^x mod p...\n");
	gx := params.g.expmod(x, params.p);
	sys->fprint(sys->fildes(2), "secstore: step 4: m = gx*H mod p...\n");
	m := mod(gx.mul(H), params.p);
	hexm := m.iptostr(64);
	sys->fprint(sys->fildes(2), "secstore: PAK pre-computed, dialing...\n");

	dconn := dial(addr);
	if(dconn == nil){
		sys->werrstr(sys->sprint("can't dial %s: %r", addr));
		return (nil, nil, sys->sprint("%r"));
	}
	(sname, diag) := authprecompver(dconn, user, version, hexHi, x, hexm);
	if(sname == nil){
		sys->werrstr(sys->sprint("can't authenticate: %s", diag));
		return (nil, nil, sys->sprint("%r"));
	}
	return (dconn, sname, diag);
}

dial(netaddr: string): ref Dial->Connection
{
	if(netaddr == nil)
		netaddr = "net!$auth!secstore";
	conn := dialler->dial(netaddr, nil);
	if(conn == nil){
		sys->fprint(sys->fildes(2), "secstore: dial %s failed: %r\n", netaddr);
		return nil;
	}
	sys->fprint(sys->fildes(2), "secstore: dialed %s, fd=%d\n", netaddr, conn.dfd.fd);
	(err, sslconn) := ssl->connect(conn.dfd);
	if(err != nil){
		sys->fprint(sys->fildes(2), "secstore: ssl connect failed: %s\n", err);
		sys->werrstr(err);
	} else
		sys->fprint(sys->fildes(2), "secstore: ssl ok, dir=%s\n", sslconn.dir);
	return sslconn;
}

authprecomp(conn: ref Dial->Connection, user: string, hexHi: string, x: ref IPint, hexm: string): (string, string)
{
	return authprecompver(conn, user, VERSION1, hexHi, x, hexm);
}

authprecompver(conn: ref Dial->Connection, user: string, version: string, hexHi: string, x: ref IPint, hexm: string): (string, string)
{
	sname := PAKclientprecompver(conn, user, version, hexHi, x, hexm);
	if(sname == nil)
		return (nil, sys->sprint("%r"));
	s := readstr(conn.dfd);
	if(s == "STA")
		return (sname, "need pin");
	if(s != "OK"){
		if(s != nil)
			sys->werrstr(s);
		return (nil, sys->sprint("%r"));
	}
	return (sname, nil);
}

auth(conn: ref Dial->Connection, user: string, pwhash: array of byte): (string, string)
{
	sname := PAKclientver(conn, user, VERSION1, pwhash);
	if(sname == nil)
		return (nil, sys->sprint("%r"));
	s := readstr(conn.dfd);
	if(s == "STA")
		return (sname, "need pin");
	if(s != "OK"){
		if(s != nil)
			sys->werrstr(s);
		return (nil, sys->sprint("%r"));
	}
	return (sname, nil);
}

cansecstore(netaddr: string, user: string): int
{
	conn := dial(netaddr);
	if(conn == nil)
		return 0;
	if(sys->fprint(conn.dfd, "secstore\tPAK\nC=%s\nm=0\n", user) < 0)
		return 0;
	buf := array[128] of byte;
	n := sys->read(conn.dfd, buf, len buf);
	if(n <= 0)
		return 0;
	return string buf[0:n] == "!account exists";
}

sendpin(conn: ref Dial->Connection, pin: string): int
{
	if(sys->fprint(conn.dfd, "STA%s", pin) < 0)
		return -1;
	s := readstr(conn.dfd);
	if(s != "OK"){
		if(s != nil)
			sys->werrstr(s);
		return -1;
	}
	return 0;
}

files(conn: ref Dial->Connection): list of (string, int, string, string, array of byte)
{
	file := getfile(conn, ".", 0);
	if(file == nil)
		return nil;
	rl: list of (string, int, string, string, array of byte);
	for(linelist := lines(file); linelist != nil; linelist = tl linelist){
		s := string hd linelist;
		# factotum\t2552 Dec  9 13:04:49 GMT 2005 n9wSk45SPDxgljOIflGQoXjOkjs=
		for(i := 0; i < len s && s[i] != '\t' && s[i] != ' '; i++){}	# can be trailing spaces
		name := s[0:i];
		for(; i < len s && (s[i] == ' ' || s[i] == '\t'); i++){}
		for(j := i; j  < len s && s[j] != ' '; j++){}
		size := int s[i+1:j];
		for(i = j; i < len s && s[i] == ' '; i++){}
		date := s[i:i+24];
		i += 24+1;
		for(j = i; j < len s && s[j] != '\n'; j++){}
		sha1 := s[i:j];
		rl = (name, int size, date, sha1, base64->dec(sha1)) :: rl;
	}
	l: list of (string, int, string, string, array of byte);
	for(; rl != nil; rl = tl rl)
		l = hd rl :: l;
	return l;
}

getfile(conn: ref Dial->Connection, name: string, maxsize: int): array of byte
{
	fd := conn.dfd;
	if(maxsize <= 0)
		maxsize = Maxfilesize;
	if(sys->fprint(fd, "GET %s\n", name) < 0 ||
	   (s := readstr(fd)) == nil){
		sys->werrstr(sys->sprint("can't get %q: %r", name));
		return nil;
	}
	nb := int s;
	if(nb == -1){
		sys->werrstr(sys->sprint("remote file %q does not exist", name));
		return nil;
	}
	if(nb < 0 || nb > maxsize){
		sys->werrstr(sys->sprint("implausible file size %d for %q", nb, name));
		return nil;
	}
	file := array[nb] of byte;
	for(nr := 0; nr < nb;){
		n :=  sys->read(fd, file[nr:], nb-nr);
		if(n < 0){
			sys->werrstr(sys->sprint("error reading %q: %r", name));
			return nil;
		}
		if(n == 0){
			sys->werrstr(sys->sprint("empty file chunk reading %q at offset %d", name, nr));
			return nil;
		}
		nr += n;
	}
	return file;
}

remove(conn: ref Dial->Connection, name: string): int
{
	if(sys->fprint(conn.dfd, "RM %s\n", name) < 0)
		return -1;

	return 0;
}

putfile(conn: ref Dial->Connection, name: string, data: array of byte): int
{
	if(len data > Maxfilesize){
		sys->werrstr("file too long");
		return -1;
	}
	fd := conn.dfd;
	if(sys->fprint(fd, "PUT %s\n", name) < 0)
		return -1;
	if(sys->fprint(fd, "%d", len data) < 0)
		return -1;
	for(o := 0; o < len data;){
		n := len data-o;
		if(n > Maxmsg)
			n = Maxmsg;
		if(sys->write(fd, data[o:o+n], n) != n)
			return -1;
		o += n;
	}
	return 0;
}

bye(conn: ref Dial->Connection)
{
	if(conn != nil){
		if(conn.dfd != nil)
			sys->fprint(conn.dfd, "BYE");
		conn.dfd = nil;
		conn.cfd = nil;
	}
}

mkseckey(s: string): array of byte
{
	key := array of byte s;
	skey := array[Keyring->SHA1dlen] of byte;
	kr->sha1(key, len key, skey, nil);
	erasekey(key);
	return skey;
}

mkseckey2(s: string): array of byte
{
	key := array of byte s;
	skey := array[Keyring->SHA256dlen] of byte;
	kr->sha256(key, len key, skey, nil);
	erasekey(key);
	return skey;
}

mkverifier(user, version: string, passhash: array of byte): string
{
	(hexHi, nil, nil) := PAK_Hiver(version, user, passhash);
	return hexHi;
}

formatverifier(version, hexHi: string): string
{
	if(version == nil || version == "" || version == VERSION1)
		return hexHi;
	return version + " " + hexHi;
}

parseverifier(s: string): (string, string)
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' ' || s[len s-1] == '\t'))
		s = s[:len s-1];
	if(s == nil || s == "")
		return (nil, nil);
	(nf, flds) := sys->tokenize(s, " \t");
	if(nf == 1)
		return (VERSION1, hd flds);
	if(nf >= 2){
		version := hd flds;
		hexHi := hd tl flds;
		if(version == VERSION1 || version == VERSION2 || version == VERSION3)
			return (version, hexHi);
	}
	return (nil, nil);
}

Checkpat: con "XXXXXXXXXXXXXXXX";	# it's what Plan 9's aescbc uses
Checklen: con len Checkpat;

mkfilekey(s: string): array of byte
{
	key := array of byte s;
	skey := array[Keyring->SHA1dlen] of byte;
	sha := kr->sha1(array of byte "aescbc file", 11, nil, nil);
	kr->sha1(key, len key, skey, sha);
	erasekey(key);
	erasekey(skey[AESbsize:]);
	return skey[0:AESbsize];
}

decrypt(file: array of byte, key: array of byte): array of byte
{
	length := len file;
	if(length == 0)
		return file;
	if(length < AESbsize+Checklen)
		return nil;
	state := kr->aessetup(key, file[0:AESbsize]);
	if(state == nil){
		sys->werrstr("can't set AES state");
		return nil;
	}
	kr->aescbc(state, file[AESbsize:], length-AESbsize, Keyring->Decrypt);
	if(string file[length-Checklen:] != Checkpat){
		sys->werrstr("file did not decrypt correctly");
		return nil;
	}
	return file[AESbsize: length-Checklen];
}

encrypt(file: array of byte, key: array of byte): array of byte
{
	dat := array[AESbsize+len file+Checklen] of byte;
	iv := random->randombuf(random->NotQuiteRandom, AESbsize);
	if(len iv != AESbsize)
		return nil;
	dat[:] = iv;
	dat[len iv:] = file;
	dat[len iv+len file:] = array of byte Checkpat;
	state := kr->aessetup(key, iv);
	if(state == nil){
		sys->werrstr("can't set AES state");
		return nil;
	}
	kr->aescbc(state, dat[AESbsize:], len dat-AESbsize, Keyring->Encrypt);
	return dat;
}

# ── Modern crypto (AES-256-GCM, HMAC-SHA256 key derivation) ──

SGCM1_MAGIC: con "SGCM1\n";
SGCM2_MAGIC: con "SGCM2\n";
SGCM_NONCE_LEN: con 12;
SGCM_TAG_LEN: con 16;
SGCM1_KDF_ROUNDS: con 10000;
SGCM3_ROOT_ROUNDS: con 100000;
SGCM3_SALT_LEN: con 16;

#
# Derive a 32-byte AES-256 key from a password using iterated HMAC-SHA256.
#
mkfilekey2(s: string): array of byte
{
	pass := array of byte s;
	salt := array of byte "secstore filekey";
	key := array[Keyring->SHA256dlen] of byte;

	# First round
	kr->hmac_sha256(salt, len salt, pass, key, nil);

	# Iterate
	for(i := 1; i < SGCM1_KDF_ROUNDS; i++){
		prev := array[Keyring->SHA256dlen] of byte;
		prev[0:] = key;
		kr->hmac_sha256(prev, len prev, pass, key, nil);
	}

	erasekey(pass);
	return key;
}

#
# Derive a stronger secstore root key from (user, password).
# This is used for SGCM2 blobs: the root key is user-scoped and expensive to
# guess, and each blob derives its actual AES key from a fresh random salt.
#
mkfilekey3(user, s: string): array of byte
{
	pass := array of byte s;
	salt := array of byte "secstore filekey seed:";
	u := array of byte user;
	data := array[len salt + len u] of byte;
	data[0:] = salt;
	data[len salt:] = u;
	key := array[Keyring->SHA256dlen] of byte;

	kr->hmac_sha256(data, len data, pass, key, nil);
	for(i := 1; i < SGCM3_ROOT_ROUNDS; i++){
		prev := array[Keyring->SHA256dlen] of byte;
		prev[0:] = key;
		kr->hmac_sha256(prev, len prev, pass, key, nil);
	}

	erasekey(pass);
	erasekey(data);
	return key;
}

#
# Key-encryption key for a 2FA key-slot: HMAC-SHA256(key=rootkey, msg=R).
# rootkey is already the expensive mkfilekey3 output, so one HMAC is enough;
# R is the YubiKey hmac-secret. Used to wrap the random data key (DK) that
# actually encrypts the factotum blob. See doc/second-factor-auth.md.
#
mkkek2fa(rootkey, R: array of byte): array of byte
{
	kek := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(R, len R, rootkey, kek, nil);
	return kek;
}

mkblobkey3(rootkey, salt: array of byte): array of byte
{
	label := array of byte "secstore file";
	data := array[len label + len salt] of byte;
	data[0:] = label;
	data[len label:] = salt;
	key := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, rootkey, key, nil);
	erasekey(data);
	return key;
}

mkaddaad(magic, salt: array of byte): array of byte
{
	aad := array[len magic + len salt] of byte;
	aad[0:] = magic;
	aad[len magic:] = salt;
	return aad;
}

#
# Encrypt with AES-256-GCM using the older SGCM1 format.
# Output format: "SGCM1\n" + 12-byte nonce + ciphertext + 16-byte GCM tag.
# Kept for compatibility; new callers should prefer encrypt3.
#
encrypt2(file: array of byte, key: array of byte): array of byte
{
	magic := array of byte SGCM1_MAGIC;

	# Generate random nonce using host CSPRNG
	nonce := random->randombuf(random->ReallyRandom, SGCM_NONCE_LEN);
	if(nonce == nil || len nonce != SGCM_NONCE_LEN){
		sys->werrstr("can't generate nonce");
		return nil;
	}

	state := kr->aesgcmsetup(key, nonce);
	if(state == nil){
		sys->werrstr("can't set AES-GCM state");
		return nil;
	}
	(ciphertext, tag) := kr->aesgcmencrypt(state, file, magic);
	if(ciphertext == nil || tag == nil){
		sys->werrstr("AES-GCM encryption failed");
		return nil;
	}

	# Build output: magic + nonce + ciphertext + tag
	outlen := len magic + SGCM_NONCE_LEN + len ciphertext + len tag;
	out := array[outlen] of byte;
	off := 0;
	out[off:] = magic;
	off += len magic;
	out[off:] = nonce;
	off += SGCM_NONCE_LEN;
	out[off:] = ciphertext;
	off += len ciphertext;
	out[off:] = tag;
	return out;
}

#
# Encrypt with AES-256-GCM using the SGCM2 format.
# Output format: "SGCM2\n" + 16-byte kdf salt + 12-byte nonce + ciphertext + tag
# The rootkey is user-scoped and stable for the session; each blob gets a fresh
# random salt and derives its own AES key from that root.
#
encrypt3(file: array of byte, rootkey: array of byte): array of byte
{
	magic := array of byte SGCM2_MAGIC;
	salt := random->randombuf(random->ReallyRandom, SGCM3_SALT_LEN);
	if(salt == nil || len salt != SGCM3_SALT_LEN){
		sys->werrstr("can't generate blob salt");
		return nil;
	}
	nonce := random->randombuf(random->ReallyRandom, SGCM_NONCE_LEN);
	if(nonce == nil || len nonce != SGCM_NONCE_LEN){
		sys->werrstr("can't generate nonce");
		return nil;
	}
	filekey := mkblobkey3(rootkey, salt);
	state := kr->aesgcmsetup(filekey, nonce);
	if(state == nil){
		erasekey(filekey);
		sys->werrstr("can't set AES-GCM state");
		return nil;
	}
	aad := mkaddaad(magic, salt);
	(ciphertext, tag) := kr->aesgcmencrypt(state, file, aad);
	erasekey(filekey);
	erasekey(aad);
	if(ciphertext == nil || tag == nil){
		sys->werrstr("AES-GCM encryption failed");
		return nil;
	}

	outlen := len magic + SGCM3_SALT_LEN + SGCM_NONCE_LEN + len ciphertext + len tag;
	out := array[outlen] of byte;
	off := 0;
	out[off:] = magic;
	off += len magic;
	out[off:] = salt;
	off += SGCM3_SALT_LEN;
	out[off:] = nonce;
	off += SGCM_NONCE_LEN;
	out[off:] = ciphertext;
	off += len ciphertext;
	out[off:] = tag;
	return out;
}

#
# Decrypt SGCM1 or legacy CBC.
# New callers should prefer decrypt3, which also understands SGCM2.
#
decrypt2(file: array of byte, key: array of byte, legacykey: array of byte): array of byte
{
	magic := array of byte SGCM1_MAGIC;
	length := len file;

	# Check for modern format
	if(length >= len magic){
		ismodern := 1;
		for(i := 0; i < len magic; i++)
			if(file[i] != magic[i]){
				ismodern = 0;
				break;
			}
		if(ismodern){
			# Modern AES-GCM format
			off := len magic;
			if(length - off < SGCM_NONCE_LEN + SGCM_TAG_LEN){
				sys->werrstr("file too short for GCM nonce+tag");
				return nil;
			}
			nonce := file[off:off+SGCM_NONCE_LEN];
			off += SGCM_NONCE_LEN;
			ciphertext := file[off:length-SGCM_TAG_LEN];
			tag := file[length-SGCM_TAG_LEN:length];

			state := kr->aesgcmsetup(key, nonce);
			if(state == nil){
				sys->werrstr("can't set AES-GCM state");
				return nil;
			}
			plaintext := kr->aesgcmdecrypt(state, ciphertext, magic, tag);
			if(plaintext == nil){
				sys->werrstr("GCM decryption failed (wrong key?)");
				return nil;
			}
			return plaintext;
		}
	}

	# Fall back to legacy AES-CBC
	if(legacykey == nil){
		sys->werrstr("legacy format but no legacy key");
		return nil;
	}
	return decrypt(file, legacykey);
}

decrypt3(file: array of byte, rootkey: array of byte, gcm1key: array of byte, legacykey: array of byte): array of byte
{
	magic := array of byte SGCM2_MAGIC;
	length := len file;

	if(length >= len magic){
		ismodern := 1;
		for(i := 0; i < len magic; i++)
			if(file[i] != magic[i]){
				ismodern = 0;
				break;
			}
		if(ismodern){
			off := len magic;
			if(length - off < SGCM3_SALT_LEN + SGCM_NONCE_LEN + SGCM_TAG_LEN){
				sys->werrstr("file too short for SGCM2 salt+nonce+tag");
				return nil;
			}
			salt := file[off:off+SGCM3_SALT_LEN];
			off += SGCM3_SALT_LEN;
			nonce := file[off:off+SGCM_NONCE_LEN];
			off += SGCM_NONCE_LEN;
			ciphertext := file[off:length-SGCM_TAG_LEN];
			tag := file[length-SGCM_TAG_LEN:length];
			filekey := mkblobkey3(rootkey, salt);
			state := kr->aesgcmsetup(filekey, nonce);
			erasekey(filekey);
			if(state == nil){
				sys->werrstr("can't set AES-GCM state");
				return nil;
			}
			aad := mkaddaad(magic, salt);
			plaintext := kr->aesgcmdecrypt(state, ciphertext, aad, tag);
			erasekey(aad);
			if(plaintext == nil){
				sys->werrstr("SGCM2 decryption failed (wrong key?)");
				return nil;
			}
			return plaintext;
		}
	}

	return decrypt2(file, gcm1key, legacykey);
}

lines(file: array of byte): list of array of byte
{
	rl: list of array of byte;
	for(i := 0; i < len file;){
		for(j := i; j < len file; j++)
			if(file[j] == byte '\n'){
				j++;
				break;
			}
		rl = file[i:j] :: rl;
		i = j;
	}
	l: list of array of byte;
	for(; rl != nil; rl = tl rl)
		l = (hd rl) :: l;
	return l;
}

readstr(fd: ref Sys->FD): string
{
	buf := array[500] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	s := string buf[0:n];
	if(s[0] == '!'){
		sys->werrstr(s[1:]);
		return nil;
	}
	return s;
}

writerr(fd: ref Sys->FD, s: string)
{
	sys->fprint(fd, "!%s", s);
	sys->werrstr(s);
}

setsecret(conn: ref Dial->Connection, sigma: array of byte, direction: int): string
{
	return setsecretver(conn, sigma, direction, VERSION1);
}

setsecretver(conn: ref Dial->Connection, sigma: array of byte, direction: int, version: string): string
{
	if(hashis256(version)){
		secretin := array[Keyring->SHA256dlen] of byte;
		secretout := array[Keyring->SHA256dlen] of byte;
		if(direction != 0){
			kr->hmac_sha256(sigma, len sigma, array of byte "one", secretout, nil);
			kr->hmac_sha256(sigma, len sigma, array of byte "two", secretin, nil);
		}else{
			kr->hmac_sha256(sigma, len sigma, array of byte "two", secretout, nil);
			kr->hmac_sha256(sigma, len sigma, array of byte "one", secretin, nil);
		}
		return ssl->secret(conn, secretin, secretout);
	}

	secretin := array[Keyring->SHA1dlen] of byte;
	secretout := array[Keyring->SHA1dlen] of byte;
	if(direction != 0){
		kr->hmac_sha1(sigma, len sigma, array of byte "one", secretout, nil);
		kr->hmac_sha1(sigma, len sigma, array of byte "two", secretin, nil);
	}else{
		kr->hmac_sha1(sigma, len sigma, array of byte "two", secretout, nil);
		kr->hmac_sha1(sigma, len sigma, array of byte "one", secretin, nil);
	}
	return ssl->secret(conn, secretin, secretout);
}

erasekey(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
}

#
# PAKclient with pre-computed values — sends hello immediately after connect
# without blocking on expensive crypto while holding an open connection.
#
PAKclientprecomp(conn: ref Dial->Connection, C: string, hexHi: string, x: ref IPint, hexm: string): string
{
	return PAKclientprecompver(conn, C, VERSION1, hexHi, x, hexm);
}

PAKclientprecompver(conn: ref Dial->Connection, C: string, version: string, hexHi: string, x: ref IPint, hexm: string): string
{
	params := pakparams(version);
	if(params == nil){
		sys->werrstr("unsupported verifier version");
		return nil;
	}
	dfd := conn.dfd;

	# Send hello immediately — crypto was pre-computed
	sys->fprint(sys->fildes(2), "secstore: PAKclient sending pre-computed hello\n");
	if(sys->fprint(dfd, "%s\tPAK\nC=%s\nm=%s\n", version, C, hexm) < 0){
		sys->fprint(sys->fildes(2), "secstore: PAKclient hello write failed: %r\n");
		return nil;
	}
	sys->fprint(sys->fildes(2), "secstore: PAKclient hello sent, waiting for response\n");

	# recv g**y, S, check hash1(g**xy)
	s := readstr(dfd);
	if(s == nil){
		e := sys->sprint("%r");
		writerr(dfd, "couldn't read g**y");
		sys->werrstr(e);
		return nil;
	}
	(nf, flds) := sys->tokenize(s, "\n");
	if(nf != 3){
		writerr(dfd, "verifier syntax  error");
		return nil;
	}
	hexmu := ex("mu=", hd flds); flds = tl flds;
	ks := ex("k=", hd flds); flds = tl flds;
	S := ex("S=", hd flds);
	if(hexmu == nil || ks == nil || S == nil){
		writerr(dfd, "verifier syntax error");
		return nil;
	}
	mu := IPint.strtoip(hexmu, 64);
	sigma := mu.expmod(x, params.p);
	hexsigma := sigma.iptostr(64);
	digest := shorthashver(version, "server", C, S, hexm, hexmu, hexsigma, hexHi);
	kc := base64->enc(digest);
	if(ks != kc){
		writerr(dfd, "verifier didn't match");
		return nil;
	}

	# send hash2(g**xy)
	digest = shorthashver(version, "client", C, S, hexm, hexmu, hexsigma, hexHi);
	kc = base64->enc(digest);
	if(sys->fprint(dfd, "k'=%s\n", kc) < 0)
		return nil;

	# set session key
	digest = shorthashver(version, "session", C, S, hexm, hexmu, hexsigma, hexHi);
	for(i := 0; i < len hexsigma; i++)
		hexsigma[i] = 0;

	err := setsecretver(conn, digest, 0, version);
	if(err != nil)
		return nil;
	erasekey(digest);
	if(sys->fprint(conn.cfd, "alg sha256 aes_128_cbc") < 0)
		return nil;
	return S;
}

#
# the following must only be used to talk to a Plan 9 secstore
#

VERSION1: con "secstore";
VERSION2: con "secstore2";
VERSION3: con "secstore3";

PAKparams: adt {
	q:	ref IPint;
	p:	ref IPint;
	r:	ref IPint;
	g:	ref IPint;
};

paklegacy: ref PAKparams;
pak3: ref PAKparams;

# from seed EB7B6E35F7CD37B511D96C67D6688CC4DD440E1E

initPAKparams()
{
	if(paklegacy != nil && pak3 != nil)
		return;
	lpak := ref PAKparams;
	lpak.q = IPint.strtoip("E0F0EF284E10796C5A2A511E94748BA03C795C13", 16);
	lpak.p = IPint.strtoip("C41CFBE4D4846F67A3DF7DE9921A49D3B42DC33728427AB159CEC8CBB"+
		"DB12B5F0C244F1A734AEB9840804EA3C25036AD1B61AFF3ABBC247CD4B384224567A86"+
		"3A6F020E7EE9795554BCD08ABAD7321AF27E1E92E3DB1C6E7E94FAAE590AE9C48F96D9"+
		"3D178E809401ABE8A534A1EC44359733475A36A70C7B425125062B1142D", 16);
	lpak.r = IPint.strtoip("DF310F4E54A5FEC5D86D3E14863921E834113E060F90052AD332B3241"+
		"CEF2497EFA0303D6344F7C819691A0F9C4A773815AF8EAECFB7EC1D98F039F17A32A7E"+
		"887D97251A927D093F44A55577F4D70444AEBD06B9B45695EC23962B175F266895C67D"+
		"21C4656848614D888A4", 16);
	lpak.g = IPint.strtoip("2F1C308DC46B9A44B52DF7DACCE1208CCEF72F69C743ADD4D23271734"+
		"44ED6E65E074694246E07F9FD4AE26E0FDDD9F54F813C40CB9BCD4338EA6F242AB94CD"+
		"410E676C290368A16B1A3594877437E516C53A6EEE5493A038A017E955E218E7819734"+
		"E3E2A6E0BAE08B14258F8C03CC1B30E0DDADFCF7CEDF0727684D3D255F1", 16);
	paklegacy = lpak;

	lpak = ref PAKparams;
	lpak.q = IPint.strtoip("8CF83642A709A097B447997640129DA299B1A47D1EB3750BA308B0FE64F5FBD3", 16);
	lpak.p = IPint.strtoip("87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4"+
		"435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D"+
		"830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF"+
		"4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C5"+
		"81B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD83477"+
		"96524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F79"+
		"71506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375"+
		"D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE9"+
		"1E1A1597", 16);
	lpak.r = IPint.strtoip("F65B7EA7706034A28A29B9436AF161BBF3632483671C60AEE9B1A6A496FFF904"+
		"FCB09731B6C6E16B551CEC2C063910B04E40795D4BEB474DB762E28CC923AE40"+
		"FDBAF05BF7501D0314C3CBE4BAD7329DD473BDF441E7B8B387B402CD0BE7DC53"+
		"4FA6D3C039BDAD133F59DC899FD570A667C453D08150A35CF5E845087BD9ACFA"+
		"8333343375E8EE52965A84C699C59DFEF852EFB96023BEF0FFB2F99C53AC2D94"+
		"CD2969764698B8DDE401DA6AA6BDB3B03B5506D287090F8E852C05EC0BDB3C0C"+
		"4FBEC1A4AB9FE141E8A7C9EADB17D335921B673615A7FC0C92384946B9AB6452", 16);
	lpak.g = IPint.strtoip("3FB32C9B73134D0B2E77506660EDBD484CA7B18F21EF205407F4793A"+
		"1A0BA12510DBC15077BE463FFF4FED4AAC0BB555BE3A6C1B0C6B47B1BC3773BF"+
		"7E8C6F62901228F8C28CBB18A55AE31341000A650196F931C77A57F2DDF463E5"+
		"E9EC144B777DE62AAAB8A8628AC376D282D6ED3864E67982428EBC831D14348F"+
		"6F2F9193B5045AF2767164E1DFC967C1FB3F2E55A4BD1BFFE83B9C80D052B985"+
		"D182EA0ADB2A3B7313D3FE14C8484B1E052588B9B7D2BBD2DF016199ECD06E15"+
		"57CD0915B3353BBB64E0EC377FD028370DF92B52C7891428CDC67EB6184B523D"+
		"1DB246C32F63078490F00EF8D647D148D47954515E2327CFEF98C582664B4C0F"+
		"6CC41659", 16);
	pak3 = lpak;
}

pakparams(version: string): ref PAKparams
{
	initPAKparams();
	if(version == VERSION3)
		return pak3;
	if(version == VERSION1 || version == VERSION2)
		return paklegacy;
	return nil;
}

hashis256(version: string): int
{
	return version == VERSION2 || version == VERSION3;
}

exponentbits(version: string): int
{
	if(version == VERSION3)
		return 320;
	return 240;
}

# H = (sha(ver,C,sha(passphrase)))^r mod p,
# a hash function expensive to attack by brute force.

longhash(ver: string, C: string, passwd: array of byte): ref IPint
{
	return longhashver(ver, C, passwd);
}

longhashver(ver: string, C: string, passwd: array of byte): ref IPint
{
	params := pakparams(ver);
	if(params == nil)
		return nil;

	aver := array of byte ver;
	aC := array of byte C;
	Cp := array[len aver + len aC + len passwd] of byte;
	Cp[0:] = aver;
	Cp[len aver:] = aC;
	Cp[len aver+len aC:] = passwd;
	if(hashis256(ver)){
		buf := array[7*Keyring->SHA256dlen] of byte;
		for(i := 0; i < 7; i++){
			key := array[] of { byte('A'+i) };
			kr->hmac_sha256(Cp, len Cp, key, buf[i*Keyring->SHA256dlen:], nil);
		}
		erasekey(Cp);
		return mod(IPint.bebytestoip(buf), params.p).expmod(params.r, params.p);
	}
	buf := array[7*Keyring->SHA1dlen] of byte;
	for(i := 0; i < 7; i++){
		key := array[] of { byte('A'+i) };
		kr->hmac_sha1(Cp, len Cp, key, buf[i*Keyring->SHA1dlen:], nil);
	}
	erasekey(Cp);
	return mod(IPint.bebytestoip(buf), params.p).expmod(params.r, params.p);	# H
}

mod(a, b: ref IPint): ref IPint
{
	return a.div(b).t1;
}

shaz(s: string, digest: array of byte, state: ref DigestState): ref DigestState
{
	a := array of byte s;
	state = kr->sha1(a, len a, digest, state);
	erasekey(a);
	return state;
}

shaz256(s: string, digest: array of byte, state: ref DigestState): ref DigestState
{
	a := array of byte s;
	state = kr->sha256(a, len a, digest, state);
	erasekey(a);
	return state;
}

# Hi = H^-1 mod p
PAK_Hi(C: string, passhash: array of byte): (string, ref IPint, ref IPint)
{
	return PAK_Hiver(VERSION1, C, passhash);
}

PAK_Hiver(version: string, C: string, passhash: array of byte): (string, ref IPint, ref IPint)
{
	params := pakparams(version);
	if(params == nil)
		return (nil, nil, nil);
	H := longhashver(version, C, passhash);
	if(H == nil)
		return (nil, nil, nil);
	Hi := H.invert(params.p);
	return (Hi.iptostr(64), H, Hi);
}

# another, faster, hash function for each party to
# confirm that the other has the right secrets.

shorthash(mess: string, C: string, S: string, m: string, mu: string, sigma: string, Hi: string): array of byte
{
	return shorthashver(VERSION1, mess, C, S, m, mu, sigma, Hi);
}

shorthashver(version: string, mess: string, C: string, S: string, m: string, mu: string, sigma: string, Hi: string): array of byte
{
	if(hashis256(version)){
		state := shaz256(mess, nil, nil);
		state = shaz256(C, nil, state);
		state = shaz256(S, nil, state);
		state = shaz256(m, nil, state);
		state = shaz256(mu, nil, state);
		state = shaz256(sigma, nil, state);
		state = shaz256(Hi, nil, state);
		state = shaz256(mess, nil, state);
		state = shaz256(C, nil, state);
		state = shaz256(S, nil, state);
		state = shaz256(m, nil, state);
		state = shaz256(mu, nil, state);
		state = shaz256(sigma, nil, state);
		digest := array[Keyring->SHA256dlen] of byte;
		shaz256(Hi, digest, state);
		return digest;
	}

	state := shaz(mess, nil, nil);
	state = shaz(C, nil, state);
	state = shaz(S, nil, state);
	state = shaz(m, nil, state);
	state = shaz(mu, nil, state);
	state = shaz(sigma, nil, state);
	state = shaz(Hi, nil, state);
	state = shaz(mess, nil, state);
	state = shaz(C, nil, state);
	state = shaz(S, nil, state);
	state = shaz(m, nil, state);
	state = shaz(mu, nil, state);
	state = shaz(sigma, nil, state);
	digest := array[Keyring->SHA1dlen] of byte;
	shaz(Hi, digest, state);
	return digest;
}

#
# On input, conn provides an open channel to the server;
#	C is the name this client calls itself;
#	pass is the user's passphrase
# On output, session secret has been set in conn
#	(unless return code is negative, which means failure).
#
PAKclient(conn: ref Dial->Connection, C: string, pwhash: array of byte): string
{
	return PAKclientver(conn, C, VERSION1, pwhash);
}

PAKclientver(conn: ref Dial->Connection, C: string, version: string, pwhash: array of byte): string
{
	params := pakparams(version);
	if(params == nil){
		sys->werrstr("unsupported verifier version");
		return nil;
	}
	dfd := conn.dfd;

	sys->fprint(sys->fildes(2), "secstore: PAK_Hi starting...\n");
	(hexHi, H, nil) := PAK_Hiver(version, C, pwhash);
	sys->fprint(sys->fildes(2), "secstore: PAK_Hi done, computing m...\n");

	# random 1<=x<=q-1; send C, m=g**x H
	x := mod(IPint.random(exponentbits(version), exponentbits(version)), params.q);
	if(x.eq(IPint.inttoip(0)))
		x = IPint.inttoip(1);
	m := mod(params.g.expmod(x, params.p).mul(H), params.p);
	hexm := m.iptostr(64);

	sys->fprint(sys->fildes(2), "secstore: PAKclient crypto done, writing hello to fd=%d\n", dfd.fd);
	if(sys->fprint(dfd, "%s\tPAK\nC=%s\nm=%s\n", version, C, hexm) < 0){
		sys->fprint(sys->fildes(2), "secstore: PAKclient hello write failed: %r\n");
		return nil;
	}
	sys->fprint(sys->fildes(2), "secstore: PAKclient hello sent, waiting for response\n");

	# recv g**y, S, check hash1(g**xy)
	s := readstr(dfd);
	if(s == nil){
		e := sys->sprint("%r");
		writerr(dfd, "couldn't read g**y");
		sys->werrstr(e);
		return nil;
	}
	# should be: "mu=%s\nk=%s\nS=%s\n"
	(nf, flds) := sys->tokenize(s, "\n");
	if(nf != 3){
		writerr(dfd, "verifier syntax  error");
		return nil;
	}
	hexmu := ex("mu=", hd flds); flds = tl flds;
	ks := ex("k=", hd flds); flds = tl flds;
	S := ex("S=", hd flds);
	if(hexmu == nil || ks == nil || S == nil){
		writerr(dfd, "verifier syntax error");
		return nil;
	}
	mu := IPint.strtoip(hexmu, 64);
	sigma := mu.expmod(x, params.p);
	hexsigma := sigma.iptostr(64);
	digest := shorthashver(version, "server", C, S, hexm, hexmu, hexsigma, hexHi);
	kc := base64->enc(digest);
	if(ks != kc){
		writerr(dfd, "verifier didn't match");
		return nil;
	}

	# send hash2(g**xy)
	digest = shorthashver(version, "client", C, S, hexm, hexmu, hexsigma, hexHi);
	kc = base64->enc(digest);
	if(sys->fprint(dfd, "k'=%s\n", kc) < 0)
		return nil;

	# set session key
	digest = shorthashver(version, "session", C, S, hexm, hexmu, hexsigma, hexHi);
	for(i := 0; i < len hexsigma; i++)
		hexsigma[i] = 0;

	err := setsecretver(conn, digest, 0, version);
	if(err != nil)
		return nil;
	erasekey(digest);
	if(sys->fprint(conn.cfd, "alg sha256 aes_128_cbc") < 0)
		return nil;
	return S;
}

ex(tag: string, s: string): string
{
	if(len s < len tag || s[0:len tag] != tag)
		return nil;
	return s[len tag:];
}
