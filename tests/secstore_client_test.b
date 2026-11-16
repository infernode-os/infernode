implement SecstoreClientTest;

#
# secstore(2), the client, against servers on the loopback that do not
# answer as a secstore does.  The server is whoever answers at the
# address dialled, and its first messages are read before anything has
# been authenticated.
#
# What was wrong, each a check here:
#   - a message of no bytes (a record that is its two-byte header) was
#     indexed: "array bounds error" out of connect2, in a caller with no
#     handler (factotum's saving thread, wm/logon with its keyboard
#     readers left running);
#   - the server's text went into the error string as it came;
#   - after any failure at all the older protocol version was tried on
#     a second connection, and the failure reported in its words (a
#     wrong password read "account version mismatch");
#   - mu = 1 was taken for the server's public value: the shared value
#     is then 1 whatever the client's secret (SP 800-56A 5.6.2.3.1);
#   - a file the server could not give (its own error, text that is no
#     size, a connection cut part way) could not be told from a file it
#     does not have, and text that is no number was a file of no bytes;
#   - a listing's lines were sliced where their fields ought to be (an
#     exception for a short one), and the size lost its first digit;
#   - an empty file "decrypted" to itself under any key;
#   - with no random device a file was encrypted under a salt and nonce
#     of zeros.
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

include "styx.m";
	styx: Styx;

include "testing.m";
	testing: Testing;
	T: import testing;

include "secstore.m";
	secstore: Secstore;

SecstoreClientTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/secstore_client_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

USER: con "clienttest";

# ---- a server on the loopback ----

announce(t: ref T): (Sys->Connection, string)
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.skip(sys->sprint("announce: %r"));
	port := "";
	(nil, l) := sys->tokenize(readfile(c.dir + "/local"), "!\n");
	if(l != nil && tl l != nil)
		port = hd tl l;
	if(port == "")
		t.fatal("no local port: " + readfile(c.dir + "/local"));
	return (c, "tcp!127.0.0.1!" + port);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

accept(c: Sys->Connection): ref Sys->FD
{
	(ok, nc) := sys->listen(c);
	if(ok < 0)
		return nil;
	return sys->open(nc.dir + "/data", Sys->ORDWR);
}

readn(fd: ref Sys->FD, n: int): array of byte
{
	a := array[n] of byte;
	for(o := 0; o < n;){
		k := sys->read(fd, a[o:], n - o);
		if(k <= 0)
			return nil;
		o += k;
	}
	return a;
}

# one record of ssl(3) in the clear, as the wire has it: a two-byte
# length with the top bit set, then the bytes
getrec(fd: ref Sys->FD): string
{
	h := readn(fd, 2);
	if(h == nil)
		return nil;
	n := ((int h[0] & 16r7f) << 8) | int h[1];
	if(n == 0)
		return "";
	b := readn(fd, n);
	if(b == nil)
		return nil;
	return string b;
}

putrec(fd: ref Sys->FD, b: array of byte)
{
	a := array[2 + len b] of byte;
	a[0] = byte (16r80 | (len b >> 8));
	a[1] = byte len b;
	a[2:] = b;
	sys->write(fd, a, len a);
}

say(fd: ref Sys->FD, s: string)
{
	putrec(fd, array of byte s);
}

# the hellos of n connections, each answered with what; a hello not
# received is "-"
answerer(c: Sys->Connection, n: int, what: array of string, saw: chan of string)
{
	for(i := 0; i < n; i++){
		fd := accept(c);
		if(fd == nil){
			saw <-= "-";
			continue;
		}
		h := getrec(fd);
		if(h == nil)
			h = "-";
		if(what[i] == "EMPTY")
			putrec(fd, array[0] of byte);
		else
			say(fd, what[i]);
		saw <-= h;
		# what the client says next, if anything, then the end
		getrec(fd);
		fd = nil;
	}
}

# what answerer saw, or "-" if it has not come in time
got(saw: chan of string): string
{
	tick := chan[1] of int;
	spawn timer(tick, 10000);
	alt {
	s := <-saw =>
		return s;
	<-tick =>
		return "-";
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

keys(): (array of byte, array of byte)
{
	return (secstore->mkseckey("a password"), secstore->mkseckey2("a password"));
}

# ---- before authentication ----

testEmptyMessage(t: ref T)
{
	(c, addr) := announce(t);
	saw := chan[4] of string;
	spawn answerer(c, 1, array[] of {"EMPTY"}, saw);
	(nil, k2) := keys();
	(conn, nil, diag) := secstore->connect2(addr, USER, nil, k2);
	t.assert(conn == nil, "no connection");
	t.assert(diag != nil && diag != "", "and a reason: " + diag);
	t.assert(hasprefix(got(saw), "secstore3\tPAK\n"), "the server had the hello");
}

testServerText(t: ref T)
{
	(c, addr) := announce(t);
	saw := chan[4] of string;
	long := "!go away\n\u0007\u001b[31m";
	while(len long < 480)
		long += " and again";
	spawn answerer(c, 1, array[] of {long}, saw);
	(nil, k2) := keys();
	(conn, nil, diag) := secstore->connect2(addr, USER, nil, k2);
	t.assert(conn == nil, "no connection");
	t.assert(has(diag, "go away"), "the server's reason is given: " + diag);
	t.assert(len diag < 200, sys->sprint("bounded: %d characters", len diag));
	n := 0;
	for(i := 0; i < len diag; i++)
		if(diag[i] < ' ')
			n++;
	t.asserteq(n, 0, "with no control character");
	got(saw);
}

# The older version is tried when the server refuses the newer as a
# version, and only then.
testFallback(t: ref T)
{
	(k1, k2) := keys();

	# an ordinary refusal: one connection, its own words
	refusals := array[] of {"!no account", "!account locked; retry in 30s", "garbage", "EMPTY"};
	for(i := 0; i < len refusals; i++){
		(c, addr) := announce(t);
		saw := chan[4] of string;
		spawn answerer(c, 2, array[] of {refusals[i], "!second"}, saw);
		(conn, nil, diag) := secstore->connect2(addr, USER, k1, k2);
		t.assert(conn == nil, "refused: " + refusals[i]);
		t.assert(!has(diag, "second"), "the failure reported is the first's: " + diag);
		if(refusals[i][0] == '!')
			t.assert(has(diag, refusals[i][1:]), "in the server's words: " + diag);
		t.assert(hasprefix(got(saw), "secstore3\tPAK\n"), "the newer version was asked for");
		kill(c);	# the listener gone, the answerer says what its second was
		t.assertseq(got(saw), "-", "and no second connection was made");
	}

	# the account is the older version's: the server says so
	versions := array[] of {"!account version mismatch", "!bad protocol"};
	for(i = 0; i < len versions; i++){
		(c, addr) := announce(t);
		saw := chan[4] of string;
		spawn answerer(c, 2, array[] of {versions[i], "!second"}, saw);
		(conn, nil, diag) := secstore->connect2(addr, USER, k1, k2);
		t.assert(conn == nil, "refused");
		t.assert(hasprefix(got(saw), "secstore3\tPAK\n"), "the newer version was asked for");
		t.assert(hasprefix(got(saw), "secstore\tPAK\n"), "then the older, after " + versions[i]);
		t.assert(has(diag, "second"), "and its outcome reported: " + diag);
	}

	# with only the newer version's key there is nothing to fall back to
	(c, addr) := announce(t);
	saw := chan[4] of string;
	spawn answerer(c, 2, array[] of {"!account version mismatch", "!second"}, saw);
	(conn, nil, diag) := secstore->connect2(addr, USER, nil, k2);
	t.assert(conn == nil && has(diag, "version mismatch"), "no older key, no fallback: " + diag);
	got(saw);
	kill(c);
	t.assertseq(got(saw), "-", "no second connection");
}

# stop an answerer still waiting for a connection: hang up its listener
kill(c: Sys->Connection)
{
	if(c.cfd != nil)
		sys->fprint(c.cfd, "hangup");
}

#
# A server that holds the verifier and sends mu = 1.  With it the shared
# value is 1, so the server's proof k is made from public values and the
# verifier.  The client must refuse mu ("!bad mu"), not answer with its
# own proof.
#
shorthash(mess, C, S, m, mu, sigma, Hi: string): array of byte
{
	s := mess + C + S + m + mu + sigma + Hi;
	a := array of byte (s + s);
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, d, nil);
	return d;
}

ex(tag, s: string): string
{
	if(!hasprefix(s, tag))
		return "";
	return s[len tag:];
}

muone(c: Sys->Connection, hexHi: string, saw: chan of string)
{
	fd := accept(c);
	if(fd == nil){
		saw <-= "-";
		return;
	}
	h := getrec(fd);
	(n, f) := sys->tokenize(h, "\n");
	if(n != 3){
		saw <-= "bad hello";
		return;
	}
	C := ex("C=", hd tl f);
	m := ex("m=", hd tl tl f);
	one := IPint.inttoip(1).iptostr(64);
	k := base64->enc(shorthash("server", C, "evil", m, one, one, hexHi));
	say(fd, "mu=" + one + "\nk=" + k + "\nS=evil\n");
	r := getrec(fd);
	if(r == nil)
		r = "-";
	saw <-= r;
}

testMuOne(t: ref T)
{
	(nil, k2) := keys();
	hexHi := secstore->mkverifier(USER, "secstore3", k2);
	t.assert(hexHi != nil, "a verifier");
	(c, addr) := announce(t);
	saw := chan[1] of string;
	spawn muone(c, hexHi, saw);
	(conn, nil, diag) := secstore->connect2(addr, USER, nil, k2);
	t.assert(conn == nil, "no connection with a server whose mu is 1");
	t.assert(has(diag, "mu"), "saying why: " + diag);
	r := got(saw);
	t.assert(hasprefix(r, "!bad mu"), "the client refused mu, and sent no proof of its own: " + r);
}

# ---- after authentication: the file operations on a connection ----

# A server for one connection: each request answered by the next of
# what; an answer "SIZE:text" is a size and then the text as the file;
# "CUT:n:text" a size of n, the text, and the end.
fileserver(c: Sys->Connection, what: array of string, done: chan of int)
{
	fd := accept(c);
	if(fd == nil){
		done <-= -1;
		return;
	}
	for(i := 0; i < len what; i++){
		if(getrec(fd) == nil)
			break;
		w := what[i];
		if(w == "EMPTY")
			putrec(fd, array[0] of byte);
		else if(hasprefix(w, "SIZE:")){
			b := array of byte w[5:];
			say(fd, string len b);
			if(len b > 0)
				putrec(fd, b);
		}else if(hasprefix(w, "CUT:")){
			(nil, f) := sys->tokenize(w, ":");
			say(fd, hd tl f);
			say(fd, hd tl tl f);
			break;
		}else if(hasprefix(w, "DIR:"))
			dirlist(fd);
		else
			say(fd, w);
	}
	fd = nil;
	done <-= 0;
}

# a directory as auth/secstored sends it
dirlist(fd: ref Sys->FD)
{
	names := array[] of {"PAK", "factotum", "notes"};
	sizes := array[] of {350, 2552, 17};
	a := array[0] of byte;
	for(i := 0; i < len names; i++){
		d := sys->zerodir;
		d.name = names[i];
		d.uid = "u";
		d.gid = "g";
		d.muid = "m";
		d.length = big sizes[i];
		d.mtime = 1134133489;
		d.mode = 8r600;
		b := styx->packdir(d);
		na := array[len a + len b] of byte;
		na[0:] = a;
		na[len a:] = b;
		a = na;
	}
	say(fd, string len a);
	putrec(fd, a);
}

client(t: ref T, what: array of string): (ref Dial->Connection, chan of int)
{
	(c, addr) := announce(t);
	done := chan[1] of int;
	spawn fileserver(c, what, done);
	conn := secstore->dial(addr);
	if(conn == nil)
		t.fatal(sys->sprint("cannot dial the test's server: %r"));
	return (conn, done);
}

testFetch(t: ref T)
{
	(conn, done) := client(t, array[] of {
		"SIZE:hello",		# a file
		"-1",			# no such file
		"!disk on fire",	# the server's error
		"SIZE:",		# a file of no bytes
		"abc",			# not a size
		"-2",
		"12 34",
		"999999999",		# more than a file may be
		"EMPTY",
		"CUT:10:abc",		# ten bytes promised, three sent
	});
	(f, absent, err) := secstore->fetch(conn, "a", 0);
	t.assert(err == nil && !absent && string f == "hello", "a file is fetched: " + err);
	(f, absent, err) = secstore->fetch(conn, "a", 0);
	t.assert(f == nil && absent && err == nil, "a file the server does not have is absent: " + err);
	(f, absent, err) = secstore->fetch(conn, "a", 0);
	t.assert(f == nil && !absent && has(err, "disk on fire"), "the server's error is an error, not absence: " + err);
	(f, absent, err) = secstore->fetch(conn, "a", 0);
	t.assert(f != nil && len f == 0 && !absent && err == nil, "a file of no bytes is that: " + err);
	bad := array[] of {"text for a size", "a negative size", "two numbers", "an implausible size", "an empty message"};
	for(i := 0; i < len bad; i++){
		(f, absent, err) = secstore->fetch(conn, "a", 0);
		t.assert(f == nil && !absent && err != nil, bad[i] + " is an error: " + err);
	}
	(f, absent, err) = secstore->fetch(conn, "a", 0);
	t.assert(f == nil && !absent && err != nil, "a file cut short is an error: " + err);
	<-done;

	# getfile, for those that use it: nil, the reason in the error string
	(conn, done) = client(t, array[] of {"-1", "abc", "SIZE:x"});
	t.assert(secstore->getfile(conn, "a", 0) == nil, "getfile: absent is nil");
	t.assert(has(sys->sprint("%r"), "does not exist"), sys->sprint("saying so: %r"));
	t.assert(secstore->getfile(conn, "a", 0) == nil, "getfile: text for a size is nil");
	t.assert(!has(sys->sprint("%r"), "does not exist"), sys->sprint("and not said to be absent: %r"));
	g := secstore->getfile(conn, "a", 0);
	t.assert(g != nil && string g == "x", "getfile: a file");
	<-done;
}

testFiles(t: ref T)
{
	(conn, done) := client(t, array[] of {
		"SIZE:factotum\t2552 Dec  9 13:04:49 GMT 2005 n9wSk45SPDxgljOIflGQoXjOkjs=\nnotes 17 Dec  9 13:04:49 GMT 2005 n9wSk45SPDxgljOIflGQoXjOkjs=\n",
		"SIZE:x\n",
		"SIZE:y 7 short\n",
		"SIZE:z notanumber Dec  9 13:04:49 GMT 2005 n9wSk45SPDxgljOIflGQoXjOkjs=\n",
		"SIZE:w 12",
		"DIR:",
		"SIZE:",
		"-1",
		"!no",
	});
	(l, err) := secstore->files(conn);
	t.assert(err == nil && len l == 2, sys->sprint("a listing of two files: %d %s", len l, err));
	if(len l == 2){
		(name, size, date, hash, raw) := hd l;
		t.assertseq(name, "factotum", "the first's name");
		t.asserteq(size, 2552, "its size, every digit");
		t.assertseq(date, "Dec  9 13:04:49 GMT 2005", "its date");
		t.assertseq(hash, "n9wSk45SPDxgljOIflGQoXjOkjs=", "its hash");
		t.asserteq(len raw, 20, "decoded");
		(name, size, nil, nil, nil) = hd tl l;
		t.assert(name == "notes" && size == 17, "the second");
	}
	bad := array[] of {"a name alone", "a short line", "a size that is no number", "a line that stops at its size"};
	for(i := 0; i < len bad; i++){
		(l, err) = secstore->files(conn);
		t.assert(l == nil && err != nil, bad[i] + " is refused: " + err);
	}
	# a directory as read, which is what auth/secstored once sent: it
	# sends a listing now, and nothing else is one
	(l, err) = secstore->files(conn);
	t.assert(l == nil && err != nil, "a directory's own bytes are no listing: " + err);
	(l, err) = secstore->files(conn);
	t.assert(l == nil && err == nil, "an empty listing is no files: " + err);
	(l, err) = secstore->files(conn);
	t.assert(l == nil && err != nil, "a server with no listing says so: " + err);
	(l, err) = secstore->files(conn);
	t.assert(l == nil && has(err, "no"), "the server's error: " + err);
	<-done;
}

testPin(t: ref T)
{
	(conn, done) := client(t, array[] of {"OK", "EMPTY", "!wrong pin", "what\u0007ever"});
	t.asserteq(secstore->sendpin(conn, "1234"), 0, "a pin taken");
	t.asserteq(secstore->sendpin(conn, "1234"), -1, "an empty answer is a refusal");
	t.asserteq(secstore->sendpin(conn, "1234"), -1, "a refusal");
	t.assert(has(sys->sprint("%r"), "wrong pin"), sys->sprint("in the server's words: %r"));
	t.asserteq(secstore->sendpin(conn, "1234"), -1, "any other answer is a refusal");
	<-done;
}

testEmptyFile(t: ref T)
{
	rk := secstore->mkfilekey3(USER, "a password");
	g1 := secstore->mkfilekey2("a password");
	lk := secstore->mkfilekey("a password");
	e := array[0] of byte;
	t.assert(secstore->decrypt3(e, rk, g1, lk) == nil, "decrypt3: an empty file is not an encrypted one");
	t.assert(secstore->decrypt3(e, rk, nil, nil) == nil, "decrypt3 with no older keys");
	# and a file that is one still decrypts
	blob := secstore->encrypt3(array of byte "key x\n", rk);
	p := secstore->decrypt3(blob, rk, nil, nil);
	t.assert(p != nil && string p == "key x\n", "a file still decrypts");
	t.assert(secstore->iscurrent(blob), "and is in the current format");
}

# the two formats nothing writes any more, made here as they were
oldcbc(file, key: array of byte): array of byte
{
	iv := array[16] of {* => byte 7};
	dat := array[16 + len file + 16] of byte;
	dat[0:] = iv;
	dat[16:] = file;
	dat[16 + len file:] = array of byte "XXXXXXXXXXXXXXXX";
	kr->aescbc(kr->aessetup(key, iv), dat[16:], len dat - 16, Keyring->Encrypt);
	return dat;
}

oldgcm1(file, key: array of byte): array of byte
{
	magic := array of byte "SGCM1\n";
	nonce := array[12] of {* => byte 9};
	(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(key, nonce), file, magic);
	out := array[len magic + 12 + len ct + len tag] of byte;
	out[0:] = magic;
	out[len magic:] = nonce;
	out[len magic + 12:] = ct;
	out[len magic + 12 + len ct:] = tag;
	return out;
}

#
# The file chose its own format: decrypt3 was given the keys of the two
# older formats by every caller, so whoever could put a file in the
# store could put one in the oldest format there (AES-CBC under a SHA-1
# of the password, with no integrity) and have it taken.  The older
# formats are read only by whoever gives their keys (auth/secstore m),
# and nothing in the library writes them.
#
testOldFormats(t: ref T)
{
	rk := secstore->mkfilekey3(USER, "a password");
	g1 := secstore->mkfilekey2("a password");
	lk := secstore->mkfilekey("a password");
	plain := array of byte "key y\n";
	cbc := oldcbc(plain, lk);
	gcm1 := oldgcm1(plain, g1);
	t.assert(!secstore->iscurrent(cbc) && !secstore->iscurrent(gcm1), "neither old format is the current one");
	t.assert(secstore->decrypt3(cbc, rk, nil, nil) == nil, "a file in the oldest format is not read by a login");
	t.assert(has(sys->sprint("%r"), "auth/secstore m"), sys->sprint("which says how it is moved: %r"));
	t.assert(secstore->decrypt3(gcm1, rk, nil, nil) == nil, "nor one in SGCM1");
	p := secstore->decrypt3(cbc, rk, g1, lk);
	t.assert(p != nil && string p == "key y\n", "given its key (a move), the oldest format is read");
	p = secstore->decrypt3(gcm1, rk, g1, lk);
	t.assert(p != nil && string p == "key y\n", "and SGCM1");
	t.assert(secstore->decrypt3(gcm1, rk, nil, lk) == nil, "SGCM1 with only the oldest format's key is not");
}

#
# With no random numbers there is no nonce, and so no encryption.  The
# nonce and salt came from random(2)'s randombuf, which gives zeros
# when its device cannot be read: every file was then sealed under the
# same nonce.
#
norandom(c: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("/dev/null", "/dev/random", Sys->MREPL) < 0 ||
	   sys->bind("/dev/null", "/dev/notquiterandom", Sys->MREPL) < 0){
		c <-= sys->sprint("skip: bind: %r");
		return;
	}
	rk := array[32] of {* => byte 7};
	r := "";
	if(secstore->encrypt3(array of byte "secret", rk) != nil)
		r += " encrypt3";
	c <-= r;
}

testNoRandom(t: ref T)
{
	c := chan of string;
	spawn norandom(c);
	r := <-c;
	if(len r > 5 && r[0:5] == "skip:")
		t.skip(r);
	t.assertseq(r, "", "nothing is encrypted with no random numbers");
	# and with them, two encryptions of one file share no salt or nonce
	rk := array[32] of {* => byte 7};
	a := secstore->encrypt3(array of byte "secret", rk);
	b := secstore->encrypt3(array of byte "secret", rk);
	t.assert(a != nil && b != nil && len a == len b, "a file is encrypted");
	if(a != nil && b != nil && len a >= 34 && len b >= 34){
		same := 1;
		zero := 1;
		for(i := 6; i < 34; i++){
			if(a[i] != b[i])
				same = 0;
			if(a[i] != byte 0)
				zero = 0;
		}
		t.assert(!same, "twice, with another salt and nonce");
		t.assert(!zero, "which are not zeros");
	}
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
	styx = load Styx Styx->PATH;
	secstore = load Secstore Secstore->PATH;
	if(kr == nil || base64 == nil || styx == nil || secstore == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	styx->init();
	secstore->init();

	run("EmptyMessage", testEmptyMessage);
	run("ServerText", testServerText);
	run("Fallback", testFallback);
	run("MuOne", testMuOne);
	run("Fetch", testFetch);
	run("Files", testFiles);
	run("Pin", testPin);
	run("EmptyFile", testEmptyFile);
	run("OldFormats", testOldFormats);
	run("NoRandom", testNoRandom);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
