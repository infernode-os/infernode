implement SecstoredTest;

#
# auth/secstored through secstore(2), on a store and a port of the
# test's own.
#
#   - "GET ." answered the directory's own bytes (stat(5) entries, the
#     verifier's among them); it is a listing now, a line a file, with
#     the file's SHA-256.
#   - any file that could not be opened was answered -1, "no such
#     file": one that was there and could not be read looked like an
#     account with nothing stored, and the client then saved over it.
#   - PAK, the verifier, was a file like any other: GET gave it, and
#     PUT and RM replaced and removed it.
#   - the verifier was made from one SHA-256 of the password, so
#     whoever read the store tried passwords against it for an
#     exponentiation each, some hundredth of the cost of trying one
#     against a file (100000 HMACs).  Version 4's is made from the file
#     key's root; an account at an older version is moved by its next
#     login, and is at version 4 alone from the one after.
#   - a store or a remove was never answered, so a refusal could not be
#     said: version 4's are.
#   - with a second factor enrolled, the password alone still stored
#     and removed the vault: the server now keeps the hash of the
#     vault key, and changes an enrolled account's files only in a
#     session that has shown the key.
#   - version 4's exchange was a PAK over a 2048-bit group alone: a
#     party that could take logarithms (a quantum computer) tried
#     passwords against a login it had recorded.  Version 5 has the
#     account's version 4 verifier and runs an ML-KEM-1024 encapsulation
#     beside the PAK, its proofs and session from both secrets by
#     SHA-384 (secstore(2)'s PAK5); version 4's exchange is not spoken,
#     and in CNSA mode nothing but version 5 is.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "encoding.m";
	base64: Encoding;
include "secstore.m";
	secstore: Secstore;
include "testing.m";
	testing: Testing;
	T: import testing;

SecstoredTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/secstored_test.b";

passed := 0;
failed := 0;
skipped := 0;

store: string;
addr: string;
srvgrp := -1;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

mkdir(d: string): int
{
	return sys->create(d, Sys->OREAD, Sys->DMDIR|8r700) != nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

writefile(f: string, b: array of byte): int
{
	fd := sys->create(f, Sys->OWRITE, 8r600);
	if(fd == nil)
		return -1;
	return sys->write(fd, b, len b);
}

# The keys a password gives, kept: the file key's root is 100000 HMACs.
Keys: adt {
	user, pass:	string;
	v1, v3, v4, root:	array of byte;
};
keycache: list of ref Keys;

keys(user, pass: string): ref Keys
{
	for(l := keycache; l != nil; l = tl l)
		if((hd l).user == user && (hd l).pass == pass)
			return hd l;
	k := ref Keys(user, pass, secstore->mkseckey(pass), secstore->mkseckey2(pass), nil, secstore->mkfilekey3(user, pass));
	k.v4 = secstore->mkseckey4(k.root);
	keycache = k :: keycache;
	return k;
}

# an account, its verifier of the version given, as secstore-setup makes it
account(t: ref T, user, pass, version: string)
{
	k := keys(user, pass);
	h := k.v4;
	case version {
	"secstore" =>
		h = k.v1;
	"secstore3" =>
		h = k.v3;
	}
	hexHi := secstore->mkverifier(user, version, h);
	if(hexHi == nil)
		t.fatal("no verifier for " + version);
	mkdir(store + "/" + user);
	if(writefile(store + "/" + user + "/PAK", array of byte (secstore->formatverifier(version, hexHi) + "\n")) < 0)
		t.fatal(sys->sprint("can't write %s's PAK: %r", user));
}

# a version 4 login (moving the account if it must be)
login(user, pass: string): (ref Dial->Connection, string)
{
	k := keys(user, pass);
	(conn, nil, diag) := secstore->connect4(addr, user, k.v1, k.v3, k.v4);
	return (conn, diag);
}

# a login as a client before version 4 makes it
oldlogin(user, pass: string): (ref Dial->Connection, string)
{
	k := keys(user, pass);
	(conn, nil, diag) := secstore->connect2(addr, user, k.v1, k.v3);
	return (conn, diag);
}

mustlogin(t: ref T, user, pass: string): ref Dial->Connection
{
	(conn, diag) := login(user, pass);
	if(conn == nil)
		t.fatal(sys->sprint("can't log in as %s: %s", user, diag));
	return conn;
}

put(conn: ref Dial->Connection, name, text: string): string
{
	if(secstore->putfile(conn, name, array of byte text) < 0)
		return sys->sprint("%r");
	return nil;
}

get(conn: ref Dial->Connection, name: string): string
{
	(f, absent, err) := secstore->fetch(conn, name, 0);
	if(absent)
		return "ABSENT";
	if(err != nil)
		return "ERROR: " + err;
	return string f;
}

testListing(t: ref T)
{
	account(t, "lister", "lister's password", "secstore4");
	conn := mustlogin(t, "lister", "lister's password");
	t.assertnil(put(conn, "factotum", "key one\n"), "a file is stored");
	t.assertnil(put(conn, "notes", "0123456789"), "and another");
	(l, err) := secstore->files(conn);
	t.assert(err == nil && len l == 2, sys->sprint("the account's two files are listed: %d %s", len l, err));
	for(; l != nil; l = tl l){
		(name, size, date, hash, raw) := hd l;
		text := "key one\n";
		if(name == "notes")
			text = "0123456789";
		else
			t.assertseq(name, "factotum", "a listed name");
		t.asserteq(size, len text, name + ": its size");
		t.asserteq(len date, 24, name + ": a date of 24 characters: " + date);
		b := array of byte text;
		d := array[Keyring->SHA256dlen] of byte;
		kr->sha256(b, len b, d, nil);
		t.assertseq(hash, base64->enc(d), name + ": its hash is the SHA-256 of the file");
		t.asserteq(len raw, Keyring->SHA256dlen, name + ": decoded");
	}
	secstore->bye(conn);
}

testAbsentOrError(t: ref T)
{
	account(t, "reader", "reader's password", "secstore4");
	conn := mustlogin(t, "reader", "reader's password");
	t.assertseq(get(conn, "nosuchfile"), "ABSENT", "a file the account does not have is absent");
	# a file that is there and is not served: too long, and a directory
	long := array[Secstore->Maxfilesize + 1] of {* => byte 16r78};
	writefile(store + "/reader/toolong", long);
	mkdir(store + "/reader/adir");
	r := get(conn, "toolong");
	t.assert(has(r, "ERROR"), "a file too long to send is an error, not absent and not a piece of it: " + r[0:40]);
	r = get(conn, "adir");
	t.assert(has(r, "ERROR"), "a directory is an error, not its bytes: " + r[0:10]);
	t.assertnil(put(conn, "after", "still in step"), "and the session goes on");
	t.assertseq(get(conn, "after"), "still in step", "in step");
	secstore->bye(conn);
}

testReserved(t: ref T)
{
	account(t, "owner", "owner's password", "secstore4");
	pak := readfile(store + "/owner/PAK");
	conn := mustlogin(t, "owner", "owner's password");
	names := array[] of {"PAK", "PAK.new", "VAULTKEY", "2fa", ".new.factotum", ".hidden"};
	for(i := 0; i < len names; i++){
		n := names[i];
		r := get(conn, n);
		t.assert(has(r, "ERROR"), n + " is not fetched: " + r);
		e := put(conn, n, "secstore4 AAAA\n");
		t.assert(e != nil, n + " is not stored");
		t.asserteq(secstore->remove(conn, n), -1, n + " is not removed");
	}
	t.assertseq(readfile(store + "/owner/PAK"), pak, "the verifier is as it was");
	bad := array[] of {"a b", "a/b", "..", "a\tb", ""};
	for(i = 0; i < len bad; i++)
		t.assert(put(conn, bad[i], "x") != nil, sys->sprint("%q is no file's name", bad[i]));
	t.assertnil(put(conn, "plain", "x"), "a plain name is still stored");
	t.asserteq(secstore->remove(conn, "plain"), 0, "and removed");
	t.asserteq(secstore->remove(conn, "plain"), -1, "a remove of what is not there is refused");
	t.assert(has(sys->sprint("%r"), "does not exist"), sys->sprint("saying so: %r"));
	secstore->bye(conn);
	(l, nil) := secstore->files(mustlogin(t, "owner", "owner's password"));
	t.assert(l == nil, "and the listing has none of them");
}

testVersion4(t: ref T)
{
	# a new account is at version 4
	account(t, "newer", "newer's password", "secstore4");
	(conn, diag) := login("newer", "newer's password");
	t.assert(conn != nil, "a version 4 account logs in: " + diag);
	secstore->bye(conn);
	(conn, diag) = login("newer", "another password");
	t.assert(conn == nil, "and not with another password: " + diag);
	(conn, diag) = oldlogin("newer", "newer's password");
	t.assert(conn == nil && has(diag, "version"), "a client that knows nothing of version 4 is told the version: " + diag);

	# an account at version 3 is moved by a login
	vers := array[] of {"secstore3", "secstore"};
	for(i := 0; i < len vers; i++){
		user := "mover" + string i;
		pass := user + "'s password";
		account(t, user, pass, vers[i]);
		pakfile := store + "/" + user + "/PAK";
		was := readfile(pakfile);
		(conn, diag) = login(user, pass);
		t.assert(conn != nil, "a " + vers[i] + " account logs in: " + diag);
		pak := readfile(pakfile);
		t.assert(has(pak, "secstore4 "), "and has a version 4 verifier");
		# the old one beside it, until a version 4 login has worked:
		# this login's second half was one
		t.assert(!has(pak, was[0:len was-1]), "and after that login's second step, at version 4, the old verifier is gone");
		t.assertnil(put(conn, "factotum", "moved\n"), "the session it is given stores");
		secstore->bye(conn);
		(conn, diag) = oldlogin(user, pass);
		t.assert(conn == nil, "the old verifier no longer logs in: " + diag);
		(conn, diag) = login(user, pass);
		t.assert(conn != nil && get(conn, "factotum") == "moved\n", "and version 4 does: " + diag);
		secstore->bye(conn);
	}

	# an account whose verifier was being replaced when its machine
	# stopped: PAK gone, PAK.new there
	account(t, "halfway", "halfway's password", "secstore4");
	nd := sys->nulldir;
	nd.name = "PAK.new";
	if(sys->wstat(store + "/halfway/PAK", nd) < 0)
		t.fatal(sys->sprint("can't rename PAK: %r"));
	(conn, diag) = login("halfway", "halfway's password");
	t.assert(conn != nil, "an account left with only PAK.new logs in: " + diag);
	secstore->bye(conn);
	t.assert(readfile(store + "/halfway/PAK") != nil && readfile(store + "/halfway/PAK.new") == nil, "its verifier is PAK again");

	# a session of an older version reads, and does not store
	account(t, "oldie", "oldie's password", "secstore3");
	writefile(store + "/oldie/factotum", array of byte "old keys\n");
	(conn, diag) = oldlogin("oldie", "oldie's password");
	if(conn == nil)
		t.fatal("an old client cannot log in to a version 3 account: " + diag);
	t.assertseq(get(conn, "factotum"), "old keys\n", "a version 3 session reads");
	secstore->putfile(conn, "factotum", array of byte "written by an old session\n");
	sys->sleep(300);
	t.assertseq(readfile(store + "/oldie/factotum"), "old keys\n", "and what it stores is not stored");
	secstore->bye(conn);
}

# what the server answers to text written raw on a connection of its own
Raw: adt {
	conn:	ref Dial->Connection;
};

rawsay(r: ref Raw, msg: string): string
{
	if(sys->fprint(r.conn.dfd, "%s", msg) < 0)
		return sys->sprint("!can't write: %r");
	buf := array[8192] of byte;
	n := sys->read(r.conn.dfd, buf, len buf);
	if(n <= 0)
		return sys->sprint("!nothing: %r");
	return string buf[0:n];
}

rawdial(t: ref T): ref Raw
{
	c := secstore->dial(addr);
	if(c == nil)
		t.fatal(sys->sprint("can't dial %s: %r", addr));
	return ref Raw(c);
}

setcnsa(on: int)
{
	fd := sys->create("/env/cnsamode", Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%d", on);
}

testVersion5(t: ref T)
{
	account(t, "pq", "pq's password", "secstore4");
	two := IPint.inttoip(2).iptostr(64);

	# the version 4 exchange is refused, saying how the account is spoken to
	r := rawdial(t);
	a := rawsay(r, "secstore4\tPAK\nC=pq\nm=" + two + "\n");
	t.assert(has(a, "secstore4 is spoken as secstore5"), "a secstore4 hello is told the version: " + a);

	# version 5's first answer is mu and S, and nothing made from the
	# verifier: the server's proof waits for the client's ML-KEM key
	r = rawdial(t);
	a = rawsay(r, "secstore5\tPAK\nC=pq\nm=" + two + "\n");
	t.assert(has(a, "mu=") && has(a, "S=") && !has(a, "k="), "a secstore5 hello is answered with mu and S alone: " + a);
	# a key of no length, and one that is no ML-KEM key, are refused
	b := rawsay(r, "ek=AAAA\n");
	t.assert(has(b, "bad ML-KEM key"), "a key of the wrong length is refused: " + b);
	r = rawdial(t);
	rawsay(r, "secstore5\tPAK\nC=pq\nm=" + two + "\n");
	ff := array[Keyring->MLKEM1024_PKLEN] of {* => byte 16rFF};
	b = rawsay(r, "ek=" + base64->enc(ff) + "\n");
	t.assert(has(b, "bad ML-KEM key"), "a key whose coefficients are q and past it is refused: " + b);
	# a real key, its seed masked under nothing the server has: a
	# ciphertext and a proof, and the client's proof then refused
	r = rawdial(t);
	a = rawsay(r, "secstore5\tPAK\nC=pq\nm=" + two + "\n");
	(ek, nil) := kr->mlkem1024_keygen();
	b = rawsay(r, "ek=" + base64->enc(ek) + "\n");
	t.assert(has(b, "ct=") && has(b, "k="), "a key that is one is answered with a ciphertext and the server's proof: " + b[0:20]);
	t.assert(len b > 2000, sys->sprint("of ML-KEM-1024's length (%d bytes of text)", len b));
	c := rawsay(r, "k'=" + base64->enc(array[48] of {* => byte 0}) + "\n");
	t.assert(has(c, "didn't match"), "and a proof that is none is refused: " + c);

	# secstore(2) logs in at version 5, with the right password only
	(conn, diag) := login("pq", "pq's password");
	t.assert(conn != nil, "a version 4 account logs in at version 5: " + diag);
	if(conn != nil){
		t.assertnil(put(conn, "factotum", "pq keys\n"), "and the session stores");
		secstore->bye(conn);
	}
	(conn, diag) = login("pq", "another password");
	t.assert(conn == nil && has(diag, "didn't match"), "not with another password: " + diag);

	# CNSA mode: version 5 alone, both ends
	account(t, "pqold", "pqold's password", "secstore3");
	setcnsa(1);
	r = rawdial(t);
	a = rawsay(r, "secstore3\tPAK\nC=pqold\nm=" + two + "\n");
	t.assert(has(a, "CNSA mode"), "in CNSA mode the server refuses secstore3: " + a);
	(conn, diag) = oldlogin("pqold", "pqold's password");
	t.assert(conn == nil && has(diag, "CNSA mode"), "and the client offers no older version: " + diag);
	(conn, diag) = login("pq", "pq's password");
	t.assert(conn != nil, "a version 4 account still logs in at version 5: " + diag);
	if(conn != nil){
		t.assertseq(get(conn, "factotum"), "pq keys\n", "and reads what it stored");
		secstore->bye(conn);
	}
	(conn, diag) = login("pqold", "pqold's password");
	t.assert(conn == nil && has(diag, "CNSA mode"), "an account at version 3 is not moved in CNSA mode: " + diag);
	setcnsa(0);
}

testVerifier(t: ref T)
{
	account(t, "changer", "the old password", "secstore4");
	conn := mustlogin(t, "changer", "the old password");
	pak := readfile(store + "/changer/PAK");
	bad := array[] of {"", "AA==", "not base 64 !", "AQ=="};
	for(i := 0; i < len bad; i++)
		t.assert(secstore->setverifier(conn, "secstore4", bad[i]) != nil, sys->sprint("a verifier of %q is refused", bad[i]));
	k := keys("changer", "the old password");
	t.assert(secstore->setverifier(conn, "secstore3", secstore->mkverifier("changer", "secstore3", k.v3)) != nil, "and one of an older version");
	t.assertseq(readfile(store + "/changer/PAK"), pak, "the verifier is as it was");
	# a new password: a new verifier, from a session that proved the old
	nk := keys("changer", "the new password");
	t.assertnil(secstore->setverifier(conn, "secstore4", secstore->mkverifier("changer", "secstore4", nk.v4)), "a new verifier is taken");
	secstore->bye(conn);
	(c2, diag) := login("changer", "the old password");
	t.assert(c2 == nil, "the old password no longer logs in: " + diag);
	(c2, diag) = login("changer", "the new password");
	t.assert(c2 != nil, "the new one does: " + diag);
	secstore->bye(c2);
}

testVault(t: ref T)
{
	account(t, "twofa", "twofa's password", "secstore4");
	dk := array[32] of {* => byte 16r5a};
	wk := secstore->vaultkey(dk);
	other := secstore->vaultkey(array[32] of {* => byte 16r11});

	# enrolment: the vault stored, then locked to its key
	conn := mustlogin(t, "twofa", "twofa's password");
	(st, serr) := secstore->vaultstate(conn);
	t.asserteq(st, 0, "no second factor is enrolled: " + serr);
	(shown, verr) := secstore->showvault(conn, wk);
	t.asserteq(shown, 0, "and a vault key shown is answered so: " + verr);
	t.assertnil(put(conn, "factotum", "the vault\n"), "the vault is stored");
	t.assertnil(secstore->enrolvault(conn, wk), "and its key enrolled");
	t.assertnil(put(conn, "factotum", "the vault, again\n"), "the enrolling session still stores");
	secstore->bye(conn);
	vk := readfile(store + "/twofa/VAULTKEY");
	t.assert(vk != nil && !has(vk, secstorehex(wk)), "the server keeps the key's hash, not the key");

	# the password alone
	conn = mustlogin(t, "twofa", "twofa's password");
	(st, serr) = secstore->vaultstate(conn);
	t.asserteq(st, 1, "the account is enrolled: " + serr);
	e := put(conn, "factotum", "a vault of the password holder's own\n");
	t.assert(e != nil && has(e, "second factor"), "with the password alone the vault is not replaced: " + e);
	t.asserteq(secstore->remove(conn, "factotum"), -1, "nor removed");
	t.assert(put(conn, "another", "x") != nil, "nor any other file stored");
	t.assertseq(get(conn, "factotum"), "the vault, again\n", "it is read, as it was");
	t.assert(secstore->enrolvault(conn, other) != nil, "another key is not enrolled over it");
	t.assert(secstore->unenrolvault(conn) != nil, "nor the lock taken off");
	(shown, verr) = secstore->showvault(conn, other);
	t.assert(shown < 0, "a wrong vault key is refused: " + verr);
	t.assert(put(conn, "factotum", "still not\n") != nil, "and stores nothing");
	# the second factor
	(shown, verr) = secstore->showvault(conn, wk);
	t.asserteq(shown, 1, "the vault key is taken: " + verr);
	t.assertnil(put(conn, "factotum", "the vault, changed\n"), "and then the vault is stored");
	secstore->bye(conn);
	t.assertseq(readfile(store + "/twofa/factotum"), "the vault, changed\n", "which is the file");

	# disabling: with the key shown, the lock comes off
	conn = mustlogin(t, "twofa", "twofa's password");
	secstore->showvault(conn, wk);
	t.assertnil(secstore->unenrolvault(conn), "a session that has shown the key takes the lock off");
	secstore->bye(conn);
	conn = mustlogin(t, "twofa", "twofa's password");
	t.assertnil(put(conn, "factotum", "under the password again\n"), "and the password alone stores again");
	secstore->bye(conn);
}

secstorehex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

server(c: chan of int)
{
	c <-= sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	# its log, off the console
	null := sys->open("/dev/null", Sys->OWRITE);
	if(null != nil)
		sys->dup(null.fd, 2);
	m := load Command "/dis/auth/secstored.dis";
	if(m == nil)
		return;
	{
		m->init(nil, "secstored" :: "-s" :: store :: "-a" :: addr :: nil);
	} exception {
	"*" =>
		;
	}
}

# a port on the loopback that is free now
freeaddr(): string
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		return nil;
	fd := sys->open(c.dir + "/local", Sys->OREAD);
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	while(s != nil && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return "tcp!" + s;
}

rmtree(d: string)
{
	fd := sys->open(d, Sys->OREAD);
	if(fd != nil)
		for(;;){
			(n, dirs) := sys->dirread(fd);
			if(n <= 0)
				break;
			for(i := 0; i < n; i++)
				if(dirs[i].mode & Sys->DMDIR)
					rmtree(d + "/" + dirs[i].name);
				else
					sys->remove(d + "/" + dirs[i].name);
		}
	fd = nil;
	sys->remove(d);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	kr = load Keyring Keyring->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	secstore = load Secstore Secstore->PATH;
	if(kr == nil || base64 == nil || secstore == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load modules";
	}
	secstore->init();

	sys->pctl(Sys->FORKNS, nil);
	# the files' nonces are from /dev/random, seconds a read on some hosts
	sys->bind("#c/notquiterandom", "/dev/random", Sys->MREPL);
	# the client's progress reports, off the console
	for(i := 0; i < 100; i++){
		store = sys->sprint("/tmp/secstored_test.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
		if(mkdir(store))
			break;
	}
	addr = freeaddr();
	if(addr == nil){
		sys->fprint(sys->fildes(2), "secstored_test: no port: %r\n");
		raise "fail:no port";
	}
	c := chan of int;
	spawn server(c);
	srvgrp = <-c;
	sys->sleep(1000);

	run("Listing", testListing);
	run("AbsentOrError", testAbsentOrError);
	run("Reserved", testReserved);
	run("Version4", testVersion4);
	run("Version5", testVersion5);
	run("Verifier", testVerifier);
	run("Vault", testVault);

	fd := sys->open("#p/" + string srvgrp + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	rmtree(store);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
