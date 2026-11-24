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
	login: Login;

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

#
# The account's version is the server's to say.  Version 3 is tried, and
# the version 1 exchange only when the server refuses version 3 as a
# version: it has another's verifier for the account, or does not know
# the protocol.  It was tried after any failure at all (a wrong password,
# a dropped connection, whatever a peer answered), so every such failure
# cost a second handshake and was reported in the second's words: a wrong
# password read "account version mismatch".
#
# VERSION2 (secstore2) retired: nothing enrols it, and legacy V1 accounts
# self-upgrade straight to VERSION3 on first login (see logon migratepak).
#
connect2(addr: string, user: string, pwhash: array of byte, pwhash2: array of byte): (ref Dial->Connection, string, string)
{
	return connect4(addr, user, pwhash, pwhash2, nil);
}

#
# Version 5 is tried first, with the version 4 verifier, the key
# mkseckey4 makes from the file key's root: version 5 is version 4's
# account and verifier with ML-KEM-1024 and SHA-384 in its exchange
# (see PAK5 below), and the version 4 exchange is no longer spoken.  An
# account not yet at version 4 is logged in to at its own version (as
# above), given its version 4 verifier, and logged in to again at
# version 5: so a connection from here is a version 5 session, whose
# stores and removes are answered.  In CNSA mode nothing but version 5
# is spoken, and an account at an older version is not moved: it is
# refused, saying so.
#
connect4(addr: string, user: string, pwhash, pwhash2, pwhash4: array of byte): (ref Dial->Connection, string, string)
{
	conn: ref Dial->Connection;
	sname, diag: string;
	if(cnsamode())
		return (nil, nil, "CNSA mode: secstore version 6 alone (connect6), whose verifier and files are under SHA-384");
	if(pwhash4 != nil){
		(conn, sname, diag) = connectver(addr, user, VERSION5, pwhash4);
		if(conn != nil){
			acked = conn :: acked;
			return (conn, sname, diag);
		}
		if(pwhash == nil && pwhash2 == nil || !refusedversion(diag))
			return (nil, nil, diag);
	}
	if(pwhash2 != nil){
		(conn, sname, diag) = connectver(addr, user, VERSION3, pwhash2);
		if(conn == nil && (pwhash == nil || !refusedversion(diag)))
			return (nil, nil, diag);
	}
	if(conn == nil && pwhash != nil)
		(conn, sname, diag) = connectver(addr, user, VERSION1, pwhash);
	if(conn == nil){
		if(diag == nil)
			diag = "no secstore credentials";
		return (nil, nil, diag);
	}
	if(pwhash4 == nil || diag != nil)	# diag: "need pin", the caller's to answer
		return (conn, sname, diag);
	# move the account, and begin again at version 4
	err := setverifier(conn, VERSION4, mkverifier(user, VERSION4, pwhash4));
	if(err != nil){
		sys->fprint(sys->fildes(2), "secstore: account %s not moved to version 4: %s\n", user, err);
		return (conn, sname, diag);
	}
	bye(conn);
	(conn, sname, diag) = connectver(addr, user, VERSION5, pwhash4);
	if(conn != nil)
		acked = conn :: acked;
	return (conn, sname, diag);
}

# the connections that are version 5 sessions
acked: list of ref Dial->Connection;

isacked(conn: ref Dial->Connection): int
{
	for(l := acked; l != nil; l = tl l)
		if(hd l == conn)
			return 1;
	return 0;
}

#
# Version 6: the exchange of version 5 (PAK5) with a verifier made from
# the file key's root of version 6 (mkfilekey6: PBKDF2-HMAC-SHA-384),
# and the account's files under keys from that root by HMAC-SHA-384
# (SGCM3).  Versions 4 and 5 had their verifier and files' keys from a
# root of HMAC-SHA-256, which is not CNSA 2.0's hash.
#
# An account at an older version is logged in to at its own version (as
# connect4 does, but with no stop at version 4), given its version 6
# verifier, and logged in to again at version 6.  In CNSA mode an
# account at version 4 is moved over version 5's exchange, which is
# CNSA's (ML-KEM-1024, SHA-384, AES-256), and one at version 3 or 1 is
# not: their exchanges are classical (Oldcnsa says what to do).  Its
# files are the caller's to move (openfile says which are of the old
# form; encrypt3 writes the new).
#
connect6(addr: string, c: ref Creds): (ref Dial->Connection, string, string)
{
	if(c == nil)
		return (nil, nil, "no secstore credentials");
	(conn, sname, diag) := connectver(addr, c.user, VERSION6, c.h6);
	if(conn != nil){
		acked = conn :: acked;
		return (conn, sname, diag);
	}
	if(!refusedversion(diag))
		return (nil, nil, diag);
	# the versions before, newest first, each tried only when the
	# server refuses the one before as a version; the session had is
	# where the version 6 verifier is given.  In CNSA mode only version
	# 5's exchange (ML-KEM-1024 beside the PAK, SHA-384, AES-256) is
	# one to move over: the new verifier goes inside it.  Versions 3 and
	# 1 are classical, and a recording of the move would give the new
	# verifier to whoever can later break it.
	if(!oldkeys(c))
		return (nil, nil, "the account is at an older secstore version, and the keys for it were let go: unlock again with the password");
	vers := array[] of {(VERSION5, c.h4), (VERSION3, c.h2), (VERSION1, c.h1)};
	if(cnsamode())
		vers = vers[0:1];
	for(i := 0; i < len vers; i++){
		(v, h) := vers[i];
		(conn, sname, diag) = connectver(addr, c.user, v, h);
		if(conn != nil || !refusedversion(diag))
			break;
	}
	if(conn == nil){
		if(cnsamode() && refusedversion(diag))
			return (nil, nil, Oldcnsa);
		return (nil, nil, diag);
	}
	if(diag != nil)	# "need pin": the caller's to answer, at the version it has
		return (conn, sname, diag);
	err := setverifier(conn, VERSION6, mkverifier(c.user, VERSION6, c.h6));
	if(err != nil){
		sys->fprint(sys->fildes(2), "secstore: account %s not moved to version 6: %s\n", c.user, err);
		return (conn, sname, diag);
	}
	bye(conn);
	(conn, sname, diag) = connectver(addr, c.user, VERSION6, c.h6);
	if(conn != nil)
		acked = conn :: acked;
	return (conn, sname, diag);
}

# An account at version 3 or older, in CNSA mode: what to do, in words
# the login screen shows
Oldcnsa: con "this secstore account is at an old version whose login is not quantum-resistant, so CNSA mode will not move it: start InferNode once with CNSAMODE unset, unlock secstore (it is moved to version 6), then start it with CNSAMODE=1 again";

# Everything a password gives a client of the store, for a store and its
# files at any version: the PAK hashes of each verifier version and the
# two file keys' roots.
mkcreds(user, pass: string): ref Creds
{
	c := ref Creds;
	c.user = user;
	c.h1 = mkseckey(pass);
	c.h2 = mkseckey2(pass);
	c.root6 = mkfilekey6(user, pass);
	c.h6 = mkseckey6(c.root6);
	c.pw = array of byte pass;
	return c;
}

# The old forms' keys, made at the first need: an account at version 4
# or a file in SGCM2.  They were made at every mkcreds, 140 ms of a
# login for keys an account moved to version 6 never uses again.
oldkeys(c: ref Creds): int
{
	if(c == nil)
		return 0;
	if(c.root3 == nil){
		if(c.pw == nil)
			return 0;
		pass := string c.pw;
		c.root3 = mkfilekey3(c.user, pass);
		c.h4 = mkseckey4(c.root3);
	}
	return 1;
}

forgetold(c: ref Creds)
{
	if(c == nil)
		return;
	erasekey(c.pw);
	erasekey(c.h1);
	erasekey(c.h2);
	erasekey(c.h4);
	erasekey(c.root3);
	c.pw = nil;
	c.h1 = nil;
	c.h2 = nil;
	c.h4 = nil;
	c.root3 = nil;
}

erasecreds(c: ref Creds)
{
	if(c == nil)
		return;
	erasekey(c.h1);
	erasekey(c.h2);
	erasekey(c.h4);
	erasekey(c.h6);
	erasekey(c.root3);
	erasekey(c.root6);
	erasekey(c.pw);
}

#
# A file of the account's, decrypted with whichever root it is under:
# (plaintext, 1) if it is of the current form (SGCM3 under the version 6
# root), (plaintext, 0) if it opened and is to be written again in it,
# (nil, 0) if it does not open (another key's, a damaged file, an old
# format only auth/secstore m moves).
#
openfile(file: array of byte, c: ref Creds): (array of byte, int)
{
	if(c == nil)
		return (nil, 0);
	pt := decrypt3(file, c.root6, nil, nil);
	if(pt != nil)
		return (pt, iscurrent(file));
	if(!oldkeys(c))
		return (nil, 0);
	pt = decrypt3(file, c.root3, nil, nil);
	if(pt != nil)
		return (pt, 0);
	return (nil, 0);
}

# OK from the server, or its refusal: nil, or why not
ack(conn: ref Dial->Connection): string
{
	s := readstr(conn.dfd);
	if(s == nil)
		return sys->sprint("%r");
	if(s != "OK")
		return "unexpected answer from server: " + cleantext(s);
	return nil;
}

#
# The account's verifier, replaced by a session that has proved the
# password: a version 4 verifier for an account at an older version
# (kept beside the old one until a version 4 login has worked), or a
# new one for a new password.
#
setverifier(conn: ref Dial->Connection, version, hexHi: string): string
{
	if(hexHi == nil)
		return "no verifier";
	if(sys->fprint(conn.dfd, "VERIFIER %s %s", version, hexHi) < 0)
		return sys->sprint("%r");
	return ack(conn);
}

#
# The second factor's lock on an account's files (secstored(8)).  The
# vault key is made from the data key the second factor unwraps; the
# server keeps its hash once the factor is enrolled, and from then on
# stores and removes only in a session that has shown the key.
#
vaultkey(dk: array of byte): array of byte
{
	label := array of byte "secstore vault key";
	wk := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(label, len label, dk, wk, nil);
	return wk;
}

hexof(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

# 1: enrolled; 0: not; -1 and why
vaultstate(conn: ref Dial->Connection): (int, string)
{
	if(sys->fprint(conn.dfd, "VAULT?") < 0)
		return (-1, sys->sprint("%r"));
	s := readstr(conn.dfd);
	case s {
	"enrolled" =>
		return (1, nil);
	"none" =>
		return (0, nil);
	}
	if(s == nil)
		return (-1, sys->sprint("%r"));
	return (-1, "unexpected answer from server: " + cleantext(s));
}

# 1: shown, and this session may store; 0: no second factor is
# enrolled (it may anyway); -1 and why
showvault(conn: ref Dial->Connection, wk: array of byte): (int, string)
{
	if(sys->fprint(conn.dfd, "VAULTKEY %s", hexof(wk)) < 0)
		return (-1, sys->sprint("%r"));
	s := readstr(conn.dfd);
	case s {
	"OK" =>
		return (1, nil);
	"none" =>
		return (0, nil);
	}
	if(s == nil)
		return (-1, sys->sprint("%r"));
	return (-1, "unexpected answer from server: " + cleantext(s));
}

enrolvault(conn: ref Dial->Connection, wk: array of byte): string
{
	if(sys->fprint(conn.dfd, "ENROLL2FA %s", hexof(wk)) < 0)
		return sys->sprint("%r");
	return ack(conn);
}

unenrolvault(conn: ref Dial->Connection): string
{
	if(sys->fprint(conn.dfd, "UNENROLL2FA") < 0)
		return sys->sprint("%r");
	return ack(conn);
}

# what a server says of a version it will not speak for this account
Eacctver: con "account version mismatch";
Eprotover: con "bad protocol";

refusedversion(diag: string): int
{
	return hassuffix(diag, Eacctver) || hassuffix(diag, Eprotover);
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

connectver(addr: string, user: string, version: string, pwhash: array of byte): (ref Dial->Connection, string, string)
{
	params := pakparams(version);
	if(params == nil)
		return (nil, nil, "unsupported verifier version");
	# In CNSA mode version 6 is spoken, and version 5's exchange (the
	# same exchange: ML-KEM-1024, SHA-384, AES-256) to move an account
	# from version 4 to 6 (connect6), and nothing older: theirs is not
	# quantum-resistant.
	if(version != VERSION6 && version != VERSION5 && cnsamode())
		return (nil, nil, "CNSA mode: secstore version 6 alone, not " + version);

	# Pre-compute PAK crypto before dialing to avoid TCP idle timeout.
	# (The verifier was kept in the module from one connection to the
	# next, with the password's hash beside it: it is an exponentiation
	# to make again, and is password-equivalent to keep.)
	(hexHi, H, nil) := PAK_Hiver(verver(version), user, pwhash);
	if(H == nil)
		return (nil, nil, "can't make the verifier");
	x := mod(IPint.random(exponentbits(version), exponentbits(version)), params.q);
	if(x.eq(IPint.inttoip(0)))
		x = IPint.inttoip(1);
	gx := params.g.expmod(x, params.p);
	m := mod(gx.mul(H), params.p);
	hexm := m.iptostr(64);

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
	(err, sslconn) := ssl->connect(conn.dfd);
	if(err != nil){
		sys->fprint(sys->fildes(2), "secstore: ssl connect failed: %s\n", err);
		sys->werrstr(err);
	}
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
			sys->werrstr("unexpected answer from server: " + cleantext(s));
		return (nil, sys->sprint("%r"));
	}
	return (sname, nil);
}

auth(conn: ref Dial->Connection, user: string, pwhash: array of byte): (string, string)
{
	if(cnsamode()){
		sys->werrstr("CNSA mode: secstore version 6 alone, not " + VERSION1);
		return (nil, sys->sprint("%r"));
	}
	sname := PAKclientver(conn, user, VERSION1, pwhash);
	if(sname == nil)
		return (nil, sys->sprint("%r"));
	s := readstr(conn.dfd);
	if(s == "STA")
		return (sname, "need pin");
	if(s != "OK"){
		if(s != nil)
			sys->werrstr("unexpected answer from server: " + cleantext(s));
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
			sys->werrstr("unexpected answer from server: " + cleantext(s));
		return -1;
	}
	return 0;
}

#
# The account's files: (name, size, date, hash as text, hash).  A Plan 9
# secstore answers "GET ." with a line for each,
#	factotum\t2552 Dec  9 13:04:49 GMT 2005 n9wSk45SPDxgljOIflGQoXjOkjs=
# and so does auth/secstored (which once sent its directory as read,
# stat(5) entries and all); the hash is whatever the server gives, its
# SHA-256 of the file from secstored.  Nothing else is read: a line was
# sliced where its fields ought to be, so one that was short raised an
# exception in the caller, and the size lost its first digit.  The
# error says which entry was not one.
#
files(conn: ref Dial->Connection): (list of (string, int, string, string, array of byte), string)
{
	(file, absent, err) := fetch(conn, ".", 0);
	if(err != nil)
		return (nil, err);
	if(absent)
		return (nil, "server gives no listing");
	if(!printable(file))
		return (nil, "malformed listing from server");
	rl: list of (string, int, string, string, array of byte);
	for(linelist := lines(file); linelist != nil; linelist = tl linelist){
		s := string hd linelist;
		while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
			s = s[0:len s-1];
		if(s == nil)
			continue;
		for(i := 0; i < len s && s[i] != '\t' && s[i] != ' '; i++){}	# can be trailing spaces
		name := s[0:i];
		for(; i < len s && (s[i] == ' ' || s[i] == '\t'); i++){}
		for(j := i; j < len s && s[j] != ' '; j++){}
		if(name == nil || j == i || j - i > 9 || !alldigits(s[i:j]))
			return (nil, "malformed listing from server: " + cleantext(s));
		size := int s[i:j];
		for(i = j; i < len s && s[i] == ' '; i++){}
		if(i + 24 + 1 >= len s)
			return (nil, "malformed listing from server: " + cleantext(s));
		date := s[i:i+24];
		hash := s[i+24+1:];
		rl = (name, size, date, hash, base64->dec(hash)) :: rl;
	}
	l: list of (string, int, string, string, array of byte);
	for(; rl != nil; rl = tl rl)
		l = hd rl :: l;
	return (l, nil);
}

printable(a: array of byte): int
{
	for(i := 0; i < len a; i++)
		if(a[i] < byte ' ' && a[i] != byte '\n' && a[i] != byte '\t')
			return 0;
	return 1;
}

alldigits(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

getfile(conn: ref Dial->Connection, name: string, maxsize: int): array of byte
{
	(file, absent, err) := fetch(conn, name, maxsize);
	if(absent)
		err = sys->sprint("remote file %q does not exist", name);
	if(err != nil){
		sys->werrstr(err);
		return nil;
	}
	return file;
}

#
# A file of the account's: (file, 0, nil); (nil, 1, nil) when the server
# says it has none of that name; (nil, 0, why) when it could not be
# read.  getfile gives nil for the last two alike, and its callers took
# every nil for an account with nothing stored yet: a read that failed
# (the server's error, a connection cut part way) was then a login with
# no keys, and the next key added was saved over the file not read.
#
# The server's answer is a size and nothing else.  It was converted as
# it came, and text that is no number is 0: a file of no bytes.
#
fetch(conn: ref Dial->Connection, name: string, maxsize: int): (array of byte, int, string)
{
	fd := conn.dfd;
	if(maxsize <= 0)
		maxsize = Maxfilesize;
	if(sys->fprint(fd, "GET %s\n", name) < 0 ||
	   (s := readstr(fd)) == nil)
		return (nil, 0, sys->sprint("can't get %q: %r", name));
	if(s == "-1")
		return (nil, 1, nil);
	if(len s > 9 || !alldigits(s))
		return (nil, 0, sys->sprint("can't get %q: server's size is no number: %s", name, cleantext(s)));
	nb := int s;
	if(nb > maxsize)
		return (nil, 0, sys->sprint("implausible file size %d for %q", nb, name));
	file := array[nb] of byte;
	for(nr := 0; nr < nb;){
		n :=  sys->read(fd, file[nr:], nb-nr);
		if(n < 0)
			return (nil, 0, sys->sprint("error reading %q: %r", name));
		if(n == 0)
			return (nil, 0, sys->sprint("%q cut short by the server: %d bytes of %d", name, nr, nb));
		nr += n;
	}
	return (file, 0, nil);
}

# A version 4 session's removes and stores are answered: the result
# is the server's.  In an older session nothing is said either way.
remove(conn: ref Dial->Connection, name: string): int
{
	if(sys->fprint(conn.dfd, "RM %s\n", name) < 0)
		return -1;
	if(isacked(conn) && (e := ack(conn)) != nil){
		sys->werrstr(e);
		return -1;
	}
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
	if(isacked(conn) && (e := ack(conn)) != nil){
		sys->werrstr(e);
		return -1;
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
		nl: list of ref Dial->Connection;
		for(l := acked; l != nil; l = tl l)
			if(hd l != conn)
				nl = hd l :: nl;
		acked = nl;
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

#
# Version 4's key for PAK: made from the root of the file key
# (mkfilekey3: 100000 HMACs of the password), so that a guess at the
# password costs as much against the verifier a server keeps as against
# the files beside it.  Version 3's was one SHA-256 of the password
# (mkseckey2): whoever read a server's store tried a password against
# its verifier for an exponentiation, some hundredth of the cost of
# trying it against a file.  The root itself is not what is sent into
# PAK: a keyed hash of it, so that the verifier's key is no file's.
#
mkseckey4(rootkey: array of byte): array of byte
{
	label := array of byte "secstore4 verifier";
	skey := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(label, len label, rootkey, skey, nil);
	return skey;
}

#
# Version 6's root and verifier key.  The root is PBKDF2 (RFC 8018,
# SP 800-132) with HMAC-SHA-384 of the password, Root6iter iterations,
# salted with "secstore filekey 6", a zero byte and the user's name, 48
# bytes; the verifier's key a keyed hash of it, as version 4's is of its
# root, so that the verifier's key is no file's.
#
Root6iter: con 200000;

mkfilekey6(user, s: string): array of byte
{
	pass := array of byte s;
	salt := catb(array of byte "secstore filekey 6", catb(array[] of {byte 0}, array of byte user));
	u := catb(salt, array[] of {byte 0, byte 0, byte 0, byte 1});
	t := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(u, len u, pass, t, nil);
	u = array[Keyring->SHA384dlen] of byte;
	u[0:] = t;
	v := array[Keyring->SHA384dlen] of byte;
	for(i := 1; i < Root6iter; i++){
		kr->hmac_sha384(u, len u, pass, v, nil);
		for(j := 0; j < len t; j++)
			t[j] ^= v[j];
		(u, v) = (v, u);
	}
	erasekey(u);
	erasekey(v);
	erasekey(pass);
	return t;
}

mkseckey6(rootkey: array of byte): array of byte
{
	label := array of byte "secstore6 verifier";
	skey := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(label, len label, rootkey, skey, nil);
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
		if(version == VERSION1 || version == VERSION3 || version == VERSION4 || version == VERSION6)
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
	# an empty file is not an encrypted one (it was returned as its own
	# plaintext, whatever the key)
	length := len file;
	if(length < AESbsize+Checklen){
		sys->werrstr("file too short to be an encrypted one");
		return nil;
	}
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

# ── Modern crypto (AES-256-GCM, HMAC-SHA256 key derivation) ──

SGCM1_MAGIC: con "SGCM1\n";
SGCM2_MAGIC: con "SGCM2\n";
SGCM3_MAGIC: con "SGCM3\n";
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

	# Iterate (one block for the value before, erased at the end: a
	# new one was made each round and left for the collector)
	prev := array[Keyring->SHA256dlen] of byte;
	for(i := 1; i < SGCM1_KDF_ROUNDS; i++){
		prev[0:] = key;
		kr->hmac_sha256(prev, len prev, pass, key, nil);
	}

	erasekey(prev);
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
	prev := array[Keyring->SHA256dlen] of byte;
	for(i := 1; i < SGCM3_ROOT_ROUNDS; i++){
		prev[0:] = key;
		kr->hmac_sha256(prev, len prev, pass, key, nil);
	}

	erasekey(prev);
	erasekey(pass);
	erasekey(data);
	return key;
}

#
# Key-encryption key for a 2FA key-slot: HMAC-SHA256(key=rootkey, msg=R).
# rootkey is already the expensive mkfilekey3 output, so one HMAC is enough;
# R is the YubiKey hmac-secret. Used to wrap the random data key (DK) that
# actually encrypts the factotum blob. See docs/second-factor-auth.md.
#
mkkek2fa(rootkey, R: array of byte): array of byte
{
	kek := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(R, len R, rootkey, kek, nil);
	return kek;
}

# the key slots' key before version 6, HMAC-SHA256 of the old root, for
# a slot not yet wrapped again (twofaslot(2) does at the next unlock)
oldkek2fa(rootkey, R: array of byte): array of byte
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

# SGCM3's: HMAC-SHA-384 of the root, AES-256's 32 bytes of it
mkblobkey6(rootkey, salt: array of byte): array of byte
{
	label := array of byte "secstore file 3";
	data := array[len label + len salt] of byte;
	data[0:] = label;
	data[len label:] = salt;
	d := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(data, len data, rootkey, d, nil);
	erasekey(data);
	key := array[32] of byte;
	key[0:] = d[0:32];
	erasekey(d);
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
# n random bytes, or nil: read here, and the read checked.  random(2)'s
# randombuf gives an array of zeros when the device cannot be opened or
# read, with no error, and its length is right; the checks that were
# made of it could not fail.  A nonce of zeros under AES-GCM is the same
# nonce for every file (SP 800-38D 8: it must not repeat under a key).
#
randbytes(which, n: int): array of byte
{
	f := "/dev/random";
	if(which == random->NotQuiteRandom)
		f = "/dev/notquiterandom";
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[n] of byte;
	for(o := 0; o < n;){
		k := sys->read(fd, buf[o:], n - o);
		if(k <= 0)
			return nil;
		o += k;
	}
	return buf;
}

#
# Encrypt with AES-256-GCM in the SGCM3 format, the one written.
# Output format: "SGCM3\n" + 16-byte kdf salt + 12-byte nonce + ciphertext + tag
# The rootkey is user-scoped and stable for the session; each blob gets a fresh
# random salt and derives its own AES key from that root by HMAC-SHA-384
# (SGCM2, still read, by HMAC-SHA256).
#
encrypt3(file: array of byte, rootkey: array of byte): array of byte
{
	magic := array of byte SGCM3_MAGIC;
	salt := randbytes(random->ReallyRandom, SGCM3_SALT_LEN);
	if(salt == nil){
		sys->werrstr("can't generate blob salt");
		return nil;
	}
	nonce := randbytes(random->ReallyRandom, SGCM_NONCE_LEN);
	if(nonce == nil){
		sys->werrstr("can't generate nonce");
		return nil;
	}
	filekey := mkblobkey6(rootkey, salt);
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

			if(key == nil){
				sys->werrstr("SGCM1 format but no key for it");
				return nil;
			}
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

#
# A file of the account's, decrypted.  Its format is SGCM2, which is
# all that is written: AES-256-GCM, the format's name and the file's
# salt under the tag.  The two formats before it (SGCM1; and Plan 9's
# AES-CBC under a SHA-1 of the password, with no integrity) are read
# only when the caller gives their keys, which is to say only by
# whoever is moving an old file (auth/secstore m): given the keys every
# time, as they were, the file chose its own format, and whoever could
# put a file in the store could put an old, weaker one in its place.
#
decrypt3(file: array of byte, rootkey: array of byte, gcm1key: array of byte, legacykey: array of byte): array of byte
{
	length := len file;
	magic: array of byte;
	sgcm3 := 0;
	if(hasmagic(file, SGCM3_MAGIC)){
		magic = array of byte SGCM3_MAGIC;
		sgcm3 = 1;
	}else if(hasmagic(file, SGCM2_MAGIC))
		magic = array of byte SGCM2_MAGIC;

	if(magic != nil && rootkey != nil){
		{
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
			filekey: array of byte;
			if(sgcm3)
				filekey = mkblobkey6(rootkey, salt);
			else
				filekey = mkblobkey3(rootkey, salt);
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
				sys->werrstr("SGCM decryption failed (wrong key?)");
				return nil;
			}
			return plaintext;
		}
	}
	if(magic != nil){
		sys->werrstr("no key for an SGCM file");
		return nil;
	}

	if(gcm1key == nil && legacykey == nil){
		sys->werrstr("not in a current format (SGCM3, SGCM2): an older file is moved with auth/secstore m");
		return nil;
	}
	return decrypt2(file, gcm1key, legacykey);
}

hasmagic(file: array of byte, m: string): int
{
	magic := array of byte m;
	if(len file < len magic)
		return 0;
	for(i := 0; i < len magic; i++)
		if(file[i] != magic[i])
			return 0;
	return 1;
}

# whether file is in the format that is written (SGCM3)
iscurrent(file: array of byte): int
{
	return hasmagic(file, SGCM3_MAGIC);
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

#
# One message from the server; nil with the error string set for no
# message, and for the server's own refusal ("!why").  The server is
# whoever answered the dial, and this is read before anything has been
# authenticated: a message of no bytes (a record that is its header
# alone) was indexed and raised an exception in the caller.
#
readstr(fd: ref Sys->FD): string
{
	return readmsg(fd, 500);
}

# a message of at most max bytes (version 5's ciphertext is 2092 in base 64)
readmsg(fd: ref Sys->FD, max: int): string
{
	buf := array[max] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	s := string buf[0:n];
	if(len s == 0){
		sys->werrstr("empty message from server");
		return nil;
	}
	if(s[0] == '!'){
		sys->werrstr(cleantext(s[1:]));
		return nil;
	}
	return s;
}

# The server's text for an error string: one line of printable
# characters and no more than a line's worth, whatever was sent.
cleantext(s: string): string
{
	r := "";
	for(i := 0; i < len s && len r < 120; i++){
		c := s[i];
		if(c < ' ' || c == 16r7f)
			c = ' ';
		r[len r] = c;
	}
	return r;
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

#
# The session's secrets each way, HMAC-SHA-384 of the session key, for
# every version: ssl(3)'s aes_256_gcm takes 32 bytes each way at the
# least (secstore's SHA-1 ones were 20), and the version 1 PAK is kept
# only for accounts to log on once and move to version 3.
#
setsecretver(conn: ref Dial->Connection, sigma: array of byte, direction: int, nil: string): string
{
	secretin := array[Keyring->SHA384dlen] of byte;
	secretout := array[Keyring->SHA384dlen] of byte;
	if(direction != 0){
		kr->hmac_sha384(sigma, len sigma, array of byte "one", secretout, nil);
		kr->hmac_sha384(sigma, len sigma, array of byte "two", secretin, nil);
	}else{
		kr->hmac_sha384(sigma, len sigma, array of byte "two", secretout, nil);
		kr->hmac_sha384(sigma, len sigma, array of byte "one", secretin, nil);
	}
	err := ssl->secret(conn, secretin, secretout);
	# the device has them now: these copies were left in the heap
	erasekey(secretin);
	erasekey(secretout);
	return err;
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
	if(version == VERSION5 || version == VERSION6)
		return pak5client(conn, version, C, hexHi, x, hexm, params);
	dfd := conn.dfd;

	# Send hello immediately — crypto was pre-computed
	if(sys->fprint(dfd, "%s\tPAK\nC=%s\nm=%s\n", version, C, hexm) < 0){
		sys->fprint(sys->fildes(2), "secstore: PAKclient hello write failed: %r\n");
		return nil;
	}

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
	if(!goodmu(mu, params)){
		writerr(dfd, "bad mu");
		sys->werrstr("secstore: server's mu is outside the group");
		return nil;
	}
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
	erasekey(digest);
	if(err != nil){
		sys->werrstr("can't set the session's secrets: " + err);
		return nil;
	}
	if(sys->fprint(conn.cfd, "alg aes_256_gcm") < 0)
		return nil;
	return S;
}

#
# the following must only be used to talk to a Plan 9 secstore
#

VERSION1: con "secstore";		# legacy: 1024-bit group, pre-SHA-256 hash
VERSION3: con "secstore3";		# 2048-bit group + SHA-256 (VERSION2 retired)
VERSION4: con "secstore4";		# the same, its verifier from the file key's root (mkseckey4)
VERSION5: con "secstore5";		# version 4's verifier; ML-KEM-1024 and SHA-384 in the exchange
VERSION6: con "secstore6";		# version 5's exchange; its verifier from mkfilekey6 (SHA-384)

# the verifier a version's exchange uses: version 5's is version 4's
verver(version: string): string
{
	if(version == VERSION5)
		return VERSION4;
	return version;
}

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
	if(version == VERSION3 || version == VERSION4 || version == VERSION5 || version == VERSION6)
		return pak3;
	if(version == VERSION1)
		return paklegacy;
	return nil;
}

hashis256(version: string): int
{
	return version == VERSION3 || version == VERSION4;
}

exponentbits(version: string): int
{
	if(version == VERSION3 || version == VERSION4 || version == VERSION5 || version == VERSION6)
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
	if(ver == VERSION6){
		# 336 bytes of HMAC-SHA-384, more than p's 256, taken mod p
		buf := array[7*Keyring->SHA384dlen] of byte;
		for(i := 0; i < 7; i++){
			key := array[] of { byte('A'+i) };
			kr->hmac_sha384(Cp, len Cp, key, buf[i*Keyring->SHA384dlen:], nil);
		}
		erasekey(Cp);
		return mod(IPint.bebytestoip(buf), params.p).expmod(params.r, params.p);
	}
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

	(hexHi, H, nil) := PAK_Hiver(version, C, pwhash);

	# random 1<=x<=q-1; send C, m=g**x H
	x := mod(IPint.random(exponentbits(version), exponentbits(version)), params.q);
	if(x.eq(IPint.inttoip(0)))
		x = IPint.inttoip(1);
	m := mod(params.g.expmod(x, params.p).mul(H), params.p);
	hexm := m.iptostr(64);

	if(sys->fprint(dfd, "%s\tPAK\nC=%s\nm=%s\n", version, C, hexm) < 0){
		sys->fprint(sys->fildes(2), "secstore: PAKclient hello write failed: %r\n");
		return nil;
	}

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
	if(!goodmu(mu, params)){
		writerr(dfd, "bad mu");
		sys->werrstr("secstore: server's mu is outside the group");
		return nil;
	}
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
	erasekey(digest);
	if(err != nil){
		sys->werrstr("can't set the session's secrets: " + err);
		return nil;
	}
	if(sys->fprint(conn.cfd, "alg aes_256_gcm") < 0)
		return nil;
	return S;
}

#
# The server's public value, validated as SP 800-56A rev. 3, 5.6.2.3.1
# (FFC full public-key validation) has it: 2 <= mu <= p-2, and mu of
# order q (mu^q mod p = 1).  Only 0 < mu < p was asked: with mu = 1 (or
# p-1) the shared value is 1 (or +-1) whatever the client's secret, so
# the session's key followed from public values and the verifier alone.
# One that is no number was a nil dereference before that.
#
goodmu(mu: ref IPint, params: ref PAKparams): int
{
	one := IPint.inttoip(1);
	if(mu == nil || mu.cmp(one) <= 0 || mu.cmp(params.p.sub(one)) >= 0)
		return 0;
	return mu.expmod(params.q, params.p).eq(one);
}

ex(tag: string, s: string): string
{
	if(len s < len tag || s[0:len tag] != tag)
		return nil;
	return s[len tag:];
}

#
# PAK5: the version 5 exchange.  Version 4's PAK (Boyko, MacKenzie and
# Patel's, as Plan 9's secstore has it) is over a 2048-bit group alone:
# a party that can take logarithms (a quantum computer) and has a
# recording of one login finds the password by trying each guess
# against the server's k, and then reads the session.  Version 5 runs
# beside it the construction login(6) version 3 has: the client sends
# an ML-KEM-1024 encapsulation key whose 32-byte seed is under a
# keystream of the PAK's secret sigma and the verifier, the server
# encapsulates to the key as it unmasks it, and both proofs and the
# session are made from the ML-KEM secret, sigma and the verifier, by
# HKDF over HMAC-SHA-384.  So the exchange holds while either problem
# does: a guess at the password is checked only through the ML-KEM
# secret, which the server's one ciphertext gives for the one key the
# real verifier unmasks.
#
#	client->server	secstore5\tPAK\nC=C\nm=m\n		(as before)
#	server->client	mu=mu\nS=S\n
#	client->server	ek=base64(ek less its seed || kemmask(seed))\n
#	server->client	ct=base64(ct)\nk=base64(proofs)\n
#	client->server	k'=base64(proofc)\n
#
#	tr0 = "secstore5 transcript" || L(version) || L(C) || L(S) || L(m) || L(mu)
#	kemmask: PRK = HMAC-SHA-384(SHA-384(tr0), sigma || Hi)
#		key || nonce = HKDF-Expand(PRK, "secstore5 kem mask", 44)
#		AES-256-CTR (GCM's stream, its tag dropped) of the seed
#	keys: th = SHA-384(tr0 || L(ek) || L(ct))
#		PRK = HMAC-SHA-384(th, k || sigma || Hi)
#		proofs, proofc, session = HKDF-Expand(PRK, label, 48)
#
# L(x) is x's length in two bytes, big-endian, and x; m, mu, sigma and
# Hi are the base64 texts the exchange has always used; version is the
# hello's first word, "secstore5" or "secstore6" (version 6 is this
# exchange with version 6's verifier).  k first is SP
# 800-56C rev. 2's Z || T, the ML-KEM secret the approved Z.
#
PAK5: con "secstore5";
Pak5eklen: con Keyring->MLKEM1024_PKLEN;
Pak5ctlen: con Keyring->MLKEM1024_CTLEN;
Pak5rholen: con 32;

lp(a: array of byte): array of byte
{
	b := array[2+len a] of byte;
	b[0] = byte (len a >> 8);
	b[1] = byte len a;
	b[2:] = a;
	return b;
}

catb(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

pak5tr0(version, C, S, m, mu: string): array of byte
{
	tr := array of byte "secstore5 transcript";
	tr = catb(tr, lp(array of byte version));
	tr = catb(tr, lp(array of byte C));
	tr = catb(tr, lp(array of byte S));
	tr = catb(tr, lp(array of byte m));
	return catb(tr, lp(array of byte mu));
}

hmac384(data, key: array of byte): array of byte
{
	d := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(data, len data, key, d, nil);
	return d;
}

expand384(prk, info: array of byte, n: int): array of byte
{
	out := array[0] of byte;
	t := array[0] of byte;
	for(i := 1; len out < n; i++){
		t = hmac384(catb(catb(t, info), array[] of {byte i}), prk);
		old := out;
		out = catb(out, t);
		erasekey(old);
	}
	r := array[n] of byte;
	r[0:] = out[0:n];
	erasekey(out);
	erasekey(t);
	return r;
}

pak5mask(version, C, S, m, mu, sigma, Hi: string, rho: array of byte): array of byte
{
	tr := pak5tr0(version, C, S, m, mu);
	th := array[Keyring->SHA384dlen] of byte;
	kr->sha384(tr, len tr, th, nil);
	ikm := catb(array of byte sigma, array of byte Hi);
	prk := hmac384(ikm, th);
	erasekey(ikm);
	okm := expand384(prk, array of byte "secstore5 kem mask", 32+12);
	(out, nil) := kr->aesgcmencrypt(kr->aesgcmsetup(okm[0:32], okm[32:]), rho, nil);
	erasekey(prk);
	erasekey(okm);
	return out;
}

pak5keys(version, C, S, m, mu, sigma, Hi: string, ek, ct, k: array of byte): (array of byte, array of byte, array of byte)
{
	tr := catb(catb(pak5tr0(version, C, S, m, mu), lp(ek)), lp(ct));
	th := array[Keyring->SHA384dlen] of byte;
	kr->sha384(tr, len tr, th, nil);
	ks := catb(k, array of byte sigma);
	ikm := catb(ks, array of byte Hi);
	erasekey(ks);
	prk := hmac384(ikm, th);
	erasekey(ikm);
	n := Keyring->SHA384dlen;
	proofs := expand384(prk, array of byte "secstore5 server proof", n);
	proofc := expand384(prk, array of byte "secstore5 client proof", n);
	sess := expand384(prk, array of byte "secstore5 session", n);
	erasekey(prk);
	return (proofs, proofc, sess);
}

# equal, in a time that does not say where not
samebytes(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= int (a[i] ^ b[i]);
	return d == 0;
}

pak5client(conn: ref Dial->Connection, version, C: string, hexHi: string, x: ref IPint, hexm: string, params: ref PAKparams): string
{
	dfd := conn.dfd;
	if(sys->fprint(dfd, "%s\tPAK\nC=%s\nm=%s\n", version, C, hexm) < 0)
		return nil;

	# mu and S, and no k: the server's proof comes with its ciphertext
	s := readstr(dfd);
	if(s == nil){
		e := sys->sprint("%r");
		writerr(dfd, "couldn't read g**y");
		sys->werrstr(e);
		return nil;
	}
	(nf, flds) := sys->tokenize(s, "\n");
	if(nf != 2){
		writerr(dfd, "verifier syntax error");
		return nil;
	}
	hexmu := ex("mu=", hd flds);
	S := ex("S=", hd tl flds);
	if(hexmu == nil || S == nil){
		writerr(dfd, "verifier syntax error");
		return nil;
	}
	mu := IPint.strtoip(hexmu, 64);
	if(!goodmu(mu, params)){
		writerr(dfd, "bad mu");
		sys->werrstr("secstore: server's mu is outside the group");
		return nil;
	}
	sigma := mu.expmod(x, params.p);
	hexsigma := sigma.iptostr(64);

	# the client's ML-KEM-1024 key, its seed under sigma and the verifier
	ek, dk: array of byte;
	{
		(ek, dk) = kr->mlkem1024_keygen();
	} exception {
	"*" =>
		ek = nil;
	}
	if(ek == nil || dk == nil || len ek != Pak5eklen){
		writerr(dfd, "no ML-KEM key");
		sys->werrstr("secstore: can't make an ML-KEM key");
		return nil;
	}
	msg := array[Pak5eklen] of byte;
	msg[0:] = ek[0:Pak5eklen-Pak5rholen];
	msg[Pak5eklen-Pak5rholen:] = pak5mask(version, C, S, hexm, hexmu, hexsigma, hexHi, ek[Pak5eklen-Pak5rholen:]);
	if(sys->fprint(dfd, "ek=%s\n", base64->enc(msg)) < 0)
		return nil;

	# the server's ciphertext for the key as it unmasked it, and its proof
	s = readmsg(dfd, Maxmsg);
	if(s == nil){
		e := sys->sprint("%r");
		erasekey(dk);
		sys->werrstr(e);
		return nil;
	}
	(nf, flds) = sys->tokenize(s, "\n");
	cts, ks: string;
	if(nf == 2){
		cts = ex("ct=", hd flds);
		ks = ex("k=", hd tl flds);
	}
	ct: array of byte;
	if(cts != nil)
		ct = base64->dec(cts);
	if(ks == nil || ct == nil || len ct != Pak5ctlen){
		erasekey(dk);
		writerr(dfd, "verifier syntax error");
		return nil;
	}
	k: array of byte;
	{
		k = kr->mlkem1024_decaps(dk, ct);
	} exception {
	"*" =>
		k = nil;
	}
	erasekey(dk);
	if(k == nil){
		writerr(dfd, "bad ciphertext");
		return nil;
	}
	(proofs, proofc, sess) := pak5keys(version, C, S, hexm, hexmu, hexsigma, hexHi, msg, ct, k);
	erasekey(k);
	for(i := 0; i < len hexsigma; i++)
		hexsigma[i] = 0;
	if(!samebytes(base64->dec(ks), proofs)){
		erasekey(sess);
		writerr(dfd, "verifier didn't match");
		return nil;
	}
	if(sys->fprint(dfd, "k'=%s\n", base64->enc(proofc)) < 0){
		erasekey(sess);
		return nil;
	}
	err := setsecretver(conn, sess, 0, version);
	erasekey(sess);
	if(err != nil){
		sys->werrstr("can't set the session's secrets: " + err);
		return nil;
	}
	if(sys->fprint(conn.cfd, "alg aes_256_gcm") < 0)
		return nil;
	return S;
}

# CNSA 2.0 mode (/env/cnsamode), as login(2) reads it
cnsamode(): int
{
	if(login == nil){
		login = load Login Login->PATH;
		if(login == nil)
			return 1;	# cannot tell: the stricter side
	}
	return login->cnsamode();
}
