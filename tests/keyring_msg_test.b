implement KeyringMsgTest;

#
# Keyring's messages (getmsg and sendmsg on a stream; getstring,
# putstring, getbytearray, putbytearray and puterror on a channel that
# keeps a write's bounds) at the lengths certificates have.
#
# Both had a limit of 4096 bytes that was not kept honestly.  putstring
# and putbytearray cut a longer message to 4095 bytes and sent that,
# returning success; an ML-DSA-87 certificate is 6197 bytes of text, so
# a signer with such a key (the CNSA one) delivered two thirds of every
# certificate, and login failed with "signer's certificate is not one".
# getstring cut an error's text to 63 bytes.  getmsg refused a message of
# 4096 bytes or more with "input or format error", leaving its bytes to
# be read as the next message's; sendmsg, given 10000 bytes or more,
# wrote five bytes of a six-byte header and then the data.  auth(2),
# which reads into a larger buffer, was held to the header's 9999: two
# ends with SLH-DSA certificates (21K and 40K of text) could not
# authenticate at all.
#
# Now a message may be Keyring->Maxmsg bytes (49151: the text of the
# largest certificate, with room), one that is longer is refused by the
# sender and by the receiver, and nothing is cut: getmsg's header has
# five or six digits for a length past 9999, and putstring's messages
# past 4095 bytes carry their length and are read until they are whole.
#
# And auth says "cannot sign" when its key makes no signature: it said
# it had no memory.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	auth: Auth;
	login: Login;

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

KeyringMsgTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_msg_test.b";

passed := 0;
failed := 0;
skipped := 0;

Maxmsg: con Keyring->Maxmsg;

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

pattern(n: int): array of byte
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte (i*7 + n + (i>>8));
	return a;
}

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

pipe(t: ref T): array of ref Sys->FD
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	return fds;
}

writer(fd: ref Sys->FD, a: array of byte, done: chan of int)
{
	done <-= sys->write(fd, a, len a);
}

sender(fd: ref Sys->FD, a: array of byte, done: chan of int)
{
	done <-= kr->sendmsg(fd, a, len a);
}

putter(fd: ref Sys->FD, a: array of byte, done: chan of int)
{
	done <-= kr->putbytearray(fd, a, len a);
}

readn(fd: ref Sys->FD, n: int): array of byte
{
	buf := array[n] of byte;
	tot := 0;
	while(tot < n){
		m := sys->read(fd, buf[tot:], n - tot);
		if(m <= 0)
			break;
		tot += m;
	}
	return buf[0:tot];
}

# sendmsg or putbytearray of a, in a process of its own: what it
# returned, or -2 if it has not in five seconds (the code before wrote a
# message it should have refused, and waited for a reader)
tried(put: int, fd: ref Sys->FD, a: array of byte): int
{
	done := chan[1] of int;
	if(put)
		spawn putter(fd, a, done);
	else
		spawn sender(fd, a, done);
	tmo := chan of int;
	spawn timer(tmo, 5000);
	alt {
	r := <-done =>
		return r;
	<-tmo =>
		return -2;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

# getmsg in a process of its own, so that one that waits for ever is seen
getter(fd: ref Sys->FD, res: chan of (array of byte, string))
{
	a := kr->getmsg(fd);
	res <-= (a, sys->sprint("%r"));
}

getmsg(t: ref T, fd: ref Sys->FD): (array of byte, string)
{
	res := chan[1] of (array of byte, string);
	spawn getter(fd, res);
	tmo := chan of int;
	spawn timer(tmo, 20000);
	alt {
	r := <-res =>
		return r;
	<-tmo =>
		t.fatal("getmsg did not return");
	}
	return (nil, nil);
}

# sendmsg and getmsg at every length that matters, and what is on the wire
testStream(t: ref T)
{
	t.asserteq(Maxmsg, 49151, "Keyring->Maxmsg");
	sizes := array[] of {0, 1, 4095, 4096, 6197, 9999, 10000, 12345, 39751, Maxmsg};
	for(i := 0; i < len sizes; i++){
		n := sizes[i];
		fds := pipe(t);
		a := pattern(n);
		done := chan[1] of int;
		spawn sender(fds[0], a, done);
		(b, err) := getmsg(t, fds[1]);
		if(n == 0){
			# an empty message is an empty array, which Limbo holds as nil
			t.assert(len b == 0, "an empty message is received");
			continue;
		}
		if(b == nil){
			t.error(sys->sprint("a message of %d bytes is not received: %s", n, err));
			continue;
		}
		t.assert(eq(a, b), sys->sprint("a message of %d bytes arrives as sent", n));
		t.asserteq(<-done, n, sys->sprint("sendmsg of %d bytes says so", n));
	}

	# the header: four digits to 9999, as ever; then the length's own digits
	hdrs := array[] of {(12, "0012\n"), (9999, "9999\n"), (10000, "10000\n"), (Maxmsg, "49151\n")};
	for(i = 0; i < len hdrs; i++){
		(n, want) := hdrs[i];
		fds := pipe(t);
		done := chan[1] of int;
		spawn sender(fds[0], pattern(n), done);
		fds[0] = nil;	# the sender's alone: closed when it has done
		h := readn(fds[1], len want);
		t.assertseq(string h, want, sys->sprint("the header of a message of %d bytes", n));
		readn(fds[1], n);
		<-done;
	}

	# longer than a message may be: not sent, and nothing written
	fds := pipe(t);
	toobig := pattern(Maxmsg+1);
	r := tried(0, fds[0], toobig);
	t.asserteq(r, -1, "a message of Maxmsg+1 bytes is refused by sendmsg");
	if(r == -1){
		t.asserteq(kr->sendmsg(fds[0], toobig, len toobig), -1, "and again");
		t.assertseq(sys->sprint("%r"), "message too long", "and it says why");
		small := array of byte "next";
		done := chan[1] of int;
		spawn sender(fds[0], small, done);
		(b, nil) := getmsg(t, fds[1]);
		t.assert(b != nil && string b == "next", "and the stream has nothing of it: the next message is the next");
	}
}

# what getmsg makes of headers that are not one
testStreamHostile(t: ref T)
{
	bad := array[] of {
		("99999\n", "message too long", "a length past Maxmsg"),
		("49152\n", "message too long", "a length of Maxmsg+1"),
		("999999\n", "message too long", "six nines"),
		("00012\nhello, world", "input or format error", "a long header with a leading zero"),
		("09999\n", "input or format error", "five digits for a length four hold"),
		("1234567\n", "input or format error", "seven digits"),
		("12345 x", "input or format error", "no newline after five digits"),
		("1234x\n", "input or format error", "a letter in the count"),
		("+123\nabc", "input or format error", "a sign"),
		(" 123\nabc", "input or format error", "a blank"),
		("!1234\n", "input or format error", "an error of four digits"),
		("12\n", "input or format error", "a header cut short"),
	};
	for(i := 0; i < len bad; i++){
		(hdr, want, what) := bad[i];
		fds := pipe(t);
		done := chan[1] of int;
		spawn writer(fds[0], array of byte hdr, done);
		<-done;
		fds[0] = nil;
		(b, err) := getmsg(t, fds[1]);
		t.assert(b == nil, what + ": no message");
		t.assertseq(err, want, what);
	}

	# a sender that knows only four digits, as sendmsg was: five bytes
	# of "12345\n" and then the data.  Refused, not misread.
	fds := pipe(t);
	done := chan[1] of int;
	spawn writer(fds[0], array of byte ("12345" + string pattern(100)), done);
	(b, err) := getmsg(t, fds[1]);
	t.assert(b == nil, "the header the old sendmsg wrote for 12345 bytes: no message");
	t.assertseq(err, "input or format error", "the header the old sendmsg wrote");

	# an error message, as before
	fds = pipe(t);
	t.asserteq(kr->senderrmsg(fds[0], "no such user"), 0, "senderrmsg");
	(b, err) = getmsg(t, fds[1]);
	t.assert(b == nil, "an error message gives no data");
	t.assertseq(err, "no such user", "an error message's text is the error");
	long := "";
	while(len long < 1000)
		long += "x";
	t.asserteq(kr->senderrmsg(fds[0], long), -1, "an error text of 1000 bytes is refused (its count is three digits)");
}

# putstring and its fellows on a pipe, which keeps a write's bounds
testDelimited(t: ref T)
{
	sizes := array[] of {1, 100, 4095, 4096, 6197, 30000, 39751, Maxmsg};
	for(i := 0; i < len sizes; i++){
		n := sizes[i];
		fds := pipe(t);
		a := pattern(n);
		done := chan[1] of int;
		spawn putter(fds[0], a, done);
		(b, err) := kr->getbytearray(fds[1]);
		if(b == nil){
			t.error(sys->sprint("a byte array of %d bytes is not received: %s", n, err));
			continue;
		}
		t.assert(eq(a, b), sys->sprint("a byte array of %d bytes arrives as sent (%d did)", n, len b));
		t.assert(<-done > 0, "putbytearray says it was sent");
	}

	# a string of a certificate's length
	s := "";
	for(i = 0; len s < 6197; i++)
		s += sys->sprint("%d,", i);
	s = s[0:6197];
	fds := pipe(t);
	done := chan[1] of int;
	spawn putstr(fds[0], s, done);
	(r, err) := kr->getstring(fds[1]);
	t.assertnil(err, "a string of 6197 bytes: no error");
	t.assert(r == s, sys->sprint("a string of 6197 bytes arrives whole (%d bytes did)", len r));
	<-done;

	# what is written: 00 and the bytes; past 4095, 01, the length, the bytes
	fds = pipe(t);
	spawn putter(fds[0], pattern(4095), done);
	fds[0] = nil;	# the sender's alone: closed when it has done
	w := readn(fds[1], 4096);
	<-done;
	t.assert(len w == 4096 && w[0] == byte 0 && eq(w[1:], pattern(4095)), "4095 bytes go as 00 and the bytes, as ever");
	fds = pipe(t);
	spawn putter(fds[0], pattern(4096), done);
	fds[0] = nil;
	w = readn(fds[1], 4096+5);
	<-done;
	t.assert(len w == 4101 && w[0] == byte 1 && w[1] == byte 0 && w[2] == byte 0 && w[3] == byte 16r10 && w[4] == byte 0
		&& eq(w[5:], pattern(4096)), "4096 bytes go as 01, 00 00 10 00, and the bytes");

	# longer than a message may be: refused, nothing sent
	fds = pipe(t);
	toobig := pattern(Maxmsg+1);
	b: array of byte;
	if(tried(1, fds[0], toobig) != -1)
		t.error("a byte array of Maxmsg+1 bytes is not refused by putbytearray");
	else{
		spawn putter(fds[0], pattern(10), done);
		(b, nil) = kr->getbytearray(fds[1]);
		<-done;
		t.assert(b != nil && eq(b, pattern(10)), "and nothing of it was sent");
	}

	# a length that is the sender's
	hostile := array[] of {
		(array[] of {byte 1, byte 16r7f, byte 16rff, byte 16rff, byte 16rff}, "message too long", "a long message said to be 2GB"),
		(array[] of {byte 1, byte 0, byte 0, byte 16rc0, byte 0}, "message too long", "a long message said to be Maxmsg+1"),
		(array[] of {byte 1, byte 0, byte 0, byte 0, byte 5, byte 'h', byte 'e', byte 'l', byte 'l', byte 'o'}, "failure", "a long message of five bytes"),
		(array[] of {byte 2, byte 'x'}, "failure", "a first byte that is neither"),
	};
	for(i = 0; i < len hostile; i++){
		(h, want, what) := hostile[i];
		fds = pipe(t);
		spawn writer(fds[0], h, done);
		<-done;
		(b, err) = kr->getbytearray(fds[1]);
		t.assert(b == nil, what + ": no message");
		t.assertseq(err, want, what);
	}
	# a long message that ends early
	fds = pipe(t);
	cut := array[5+1000] of {* => byte 'a'};
	cut[0] = byte 1; cut[1] = byte 0; cut[2] = byte 0; cut[3] = byte 16r20; cut[4] = byte 0;	# 8192
	spawn writer(fds[0], cut, done);
	<-done;
	fds[0] = nil;
	(b, err) = kr->getbytearray(fds[1]);
	t.assert(b == nil, "a long message cut short: no message");
	t.assertseq(err, "hungup", "a long message cut short");

	# an error's text, whole (it was cut to 63 bytes)
	e := "";
	while(len e < 300)
		e += sys->sprint("reason %d; ", len e);
	fds = pipe(t);
	spawn puterr(fds[0], e, done);
	(r, err) = kr->getstring(fds[1]);
	<-done;
	t.assert(r == nil, "an error gives no string");
	t.assert(err == e, sys->sprint("an error of %d bytes arrives whole (%d did)", len e, len err));
	while(len e < 4096)
		e += "x";
	t.asserteq(kr->puterror(fds[0], e), -1, "an error text of 4096 bytes is refused");
}

putstr(fd: ref Sys->FD, s: string, done: chan of int)
{
	done <-= kr->putstring(fd, s);
}

puterr(fd: ref Sys->FD, s: string, done: chan of int)
{
	done <-= kr->puterror(fd, s);
}

# ---- auth(2) between holders of large certificates ----

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref IPint, name: string): ref Keyring->Authinfo
{
	sk := kr->genSKfromPK(signerpk, name);
	pk := kr->sktopk(sk);
	pkbuf := array of byte kr->pktostr(pk);
	state := kr->sha256(pkbuf, len pkbuf, nil, nil);
	cert := kr->sign(signersk, 0, state, "sha256");

	ai := ref Keyring->Authinfo;
	ai.mysk = sk;
	ai.mypk = pk;
	ai.cert = cert;
	ai.spk = signerpk;
	ai.alpha = alpha;
	ai.p = p;
	return ai;
}

pair(t: ref T, alg: string, bits: int): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	signersk := kr->genSK(alg, "test-signer", bits);
	if(signersk == nil)
		t.fatal("genSK " + alg);
	signerpk := kr->sktopk(signersk);
	(alpha, p) := kr->dhparams(2048);
	if(alpha == nil || p == nil)
		t.fatal("dhparams");
	alice := mkauthinfo(signersk, signerpk, alpha, p, "alice");
	bob := mkauthinfo(signersk, signerpk, alpha, p, "bob");
	if(alice.cert == nil || bob.cert == nil)
		t.fatal(alg + ": the signer made no certificate");
	return (alice, bob);
}

authproc(fd: ref Sys->FD, ai: ref Keyring->Authinfo, c: chan of (string, array of byte))
{
	c <-= kr->auth(fd, ai, 0);
}

# a connection over the loopback: its two ends
tcppair(t: ref T): array of ref Sys->FD
{
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0)
		t.fatal(sys->sprint("announce: %r"));
	fd := sys->open(c.dir+"/local", Sys->OREAD);
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		t.fatal("no local address");
	local := string buf[0:n];
	while(local != nil && (local[len local-1] == '\n' || local[len local-1] == ' '))
		local = local[0:len local-1];
	(dok, dc) := sys->dial("tcp!" + local, nil);
	if(dok < 0)
		t.fatal(sys->sprint("dial: %r"));
	(lok, nc) := sys->listen(c);
	if(lok < 0)
		t.fatal(sys->sprint("listen: %r"));
	lfd := sys->open(nc.dir+"/data", Sys->ORDWR);
	if(lfd == nil)
		t.fatal(sys->sprint("open: %r"));
	return array[] of {dc.dfd, lfd};
}

# both ends of auth, over a pipe or (tcp) the loopback: (alice's view, bob's view).
# Each end sends its certificate before it reads the other's, so the
# largest need a connection that holds 40K unread, which a pipe does not.
bothends(t: ref T, alice, bob: ref Keyring->Authinfo, tcp: int): ((string, array of byte), (string, array of byte))
{
	fds: array of ref Sys->FD;
	if(tcp)
		fds = tcppair(t);
	else
		fds = pipe(t);
	ca := chan[1] of (string, array of byte);
	cb := chan[1] of (string, array of byte);
	spawn authproc(fds[0], alice, ca);
	spawn authproc(fds[1], bob, cb);
	fds = nil;
	tmo := chan of int;
	spawn timer(tmo, 120000);
	ra, rb: (string, array of byte);
	for(i := 0; i < 2; i++)
		alt {
		ra = <-ca =>
			;
		rb = <-cb =>
			;
		<-tmo =>
			t.fatal("auth did not finish in two minutes");
		}
	return (ra, rb);
}

authok(t: ref T, alg: string, tcp: int)
{
	(alice, bob) := pair(t, alg, 0);
	n := len kr->certtostr(alice.cert);
	((aowner, asecret), (bowner, bsecret)) := bothends(t, alice, bob, tcp);
	if(asecret == nil || bsecret == nil)
		t.fatal(sys->sprint("%s (a certificate is %d bytes of text): auth fails: %s / %s", alg, n, aowner, bowner));
	t.assertseq(aowner, "bob", alg + ": alice authenticates bob");
	t.assertseq(bowner, "alice", alg + ": bob authenticates alice");
	t.assert(eq(asecret, bsecret), alg + ": both have the same secret");
	t.log(sys->sprint("%s: a certificate is %d bytes of text", alg, n));
}

testAuthMLDSA87(t: ref T)
{
	authok(t, "mldsa87", 0);
}

# 21K of certificate: more than the four digits count
testAuthSLH192(t: ref T)
{
	authok(t, "slhdsa192s", 0);
}

# 40K: the largest there is
testAuthSLH256(t: ref T)
{
	authok(t, "slhdsa256s", 1);
}

lines(s: string): array of string
{
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	a := array[n] of string;
	j := 0;
	b := 0;
	for(i = 0; i < len s; i++)
		if(s[i] == '\n'){
			a[j++] = s[b:i];
			b = i+1;
		}
	return a;
}

# A key that makes no signature (an RSA key whose kq is not its own:
# the signature is checked before it leaves) in auth: "cannot sign",
# from the end that cannot.  It said "out of memory".
testAuthCannotSign(t: ref T)
{
	(alice, bob) := pair(t, "rsa", 1024);
	g := lines(kr->sktostr(alice.mysk));	# rsa, owner, n, ek, dk, p, q, kp, kq, c2
	if(len g != 10)
		t.fatal(sys->sprint("an RSA secret key has %d lines", len g));
	g[8] = IPint.b64toip(g[8]).add(IPint.inttoip(2)).iptob64();
	s := "";
	for(i := 0; i < len g; i++)
		s += g[i] + "\n";
	alice.mysk = kr->strtosk(s);
	if(alice.mysk == nil)
		t.fatal("the key with kq+2 is not read");
	((aerr, asecret), (berr, bsecret)) := bothends(t, alice, bob, 0);
	t.assert(asecret == nil && bsecret == nil, "auth with a key that cannot sign fails at both ends");
	t.assertseq(aerr, "cannot sign", "the end whose key it is says so");
	t.assertseq(berr, "remote: cannot sign", "and the other end is told");
}

# ---- over ssl(3): a write past a record's 32K is several records ----

sslserver(fd: ref Sys->FD, ai: ref Keyring->Authinfo, n: int, rc: chan of string)
{
	(sfd, err) := auth->server("aes_256_gcm" :: nil, ai, fd, 0);
	if(sfd == nil){
		rc <-= "server: " + err;
		return;
	}
	(b, e) := kr->getbytearray(sfd);
	if(b == nil){
		rc <-= "server: getbytearray: " + e;
		return;
	}
	if(!eq(b, pattern(n))){
		rc <-= sys->sprint("server: %d bytes arrived, not the %d sent", len b, n);
		return;
	}
	# and back, then a short one, which must come after it whole
	if(kr->putbytearray(sfd, b, len b) < 0 || kr->putstring(sfd, "done") < 0){
		rc <-= sys->sprint("server: put: %r");
		return;
	}
	rc <-= nil;
}

testOverSSL(t: ref T)
{
	(alice, bob) := pair(t, "ed25519", 0);
	n := 39751;	# an SLH-DSA-256s certificate's text
	fds := pipe(t);
	rc := chan[1] of string;
	spawn sslserver(fds[1], bob, n, rc);
	(cfd, cerr) := auth->client("aes_256_gcm", alice, fds[0]);
	if(cfd == nil)
		t.fatal("client: " + cerr);
	a := pattern(n);
	t.assert(kr->putbytearray(cfd, a, n) > 0, "putbytearray of 39751 bytes through ssl");
	# the other end's word first, if it has given up
	res := chan[1] of (array of byte, string);
	spawn bytesgetter(cfd, res);
	b: array of byte;
	err: string;
	alt {
	(b, err) = <-res =>
		;
	e := <-rc =>
		t.fatal("the other end: " + e);
	}
	t.assert(b != nil && eq(a, b), sys->sprint("39751 bytes come back whole through ssl's records (%d did: %s)", len b, err));
	(s, e2) := kr->getstring(cfd);
	t.assertseq(s, "done", "and the message after it is the next: " + e2);
	t.assertnil(<-rc, "the other end");
}

bytesgetter(fd: ref Sys->FD, res: chan of (array of byte, string))
{
	res <-= kr->getbytearray(fd);
}

# ---- login(2) from signers with large certificates ----

testdir: string;
User: con "alice";
Password: con "correct horse battery staple";

setcnsa(on: int)
{
	fd := sys->create("/env/cnsamode", Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	if(on)
		sys->fprint(fd, "1");
	else
		sys->fprint(fd, "0");
}

writefile(name: string, data: array of byte): int
{
	fd := sys->create(name, Sys->OWRITE, 8r600);
	if(fd == nil)
		return -1;
	if(sys->write(fd, data, len data) != len data)
		return -1;
	return 0;
}

mkdir(name: string): int
{
	fd := sys->create(name, Sys->OREAD, Sys->DMDIR|8r700);
	if(fd == nil)
		return -1;
	return 0;
}

# the signer's files, as tests/login_test.b makes them, in this name space
setup(): string
{
	(tok, nil) := sys->stat("/tmp");
	if(tok < 0)
		mkdir("/tmp");
	d: string;
	for(i := 0; i < 100; i++){
		d = sys->sprint("/tmp/krmsgtest.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
		if(mkdir(d) >= 0)
			break;
	}
	testdir = d;
	if(mkdir(d+"/root") < 0 || mkdir(d+"/root/keydb") < 0 ||
	   mkdir(d+"/mnt") < 0 || mkdir(d+"/mnt/keys") < 0 || mkdir(d+"/mnt/audit") < 0)
		return sys->sprint("can't make %s: %r", d);
	pw := array of byte Password;
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pw, len pw, dig, nil);
	u := d+"/mnt/keys/"+User;
	if(mkdir(u) < 0 || writefile(u+"/secret", dig) < 0 || writefile(u+"/expire", array of byte "never") < 0)
		return sys->sprint("can't write %s's entry: %r", User);
	if(sys->bind(d+"/root", "/", Sys->MBEFORE) < 0 || sys->bind(d+"/mnt", "/mnt", Sys->MBEFORE) < 0)
		return sys->sprint("can't bind the signer's files: %r");
	if(sys->bind("#c/notquiterandom", "/dev/random", Sys->MREPL) < 0)
		return sys->sprint("can't bind #c/notquiterandom over /dev/random: %r");
	if(sys->bind("#s", "/mnt/audit", Sys->MREPL) < 0)
		return sys->sprint("can't bind #s on /mnt/audit: %r");
	af := sys->file2chan("/mnt/audit", "log");
	if(af == nil)
		return sys->sprint("can't serve /mnt/audit/log: %r");
	spawn auditsrv(af);
	return nil;
}

auditsrv(f: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			rc <-= (nil, "permission denied");
	(nil, data, nil, wc) := <-f.write =>
		if(wc != nil)
			wc <-= (len data, nil);
	}
}

signerkey(alg: string): string
{
	sys->remove("/keydb/signerkey");
	csk := load Command "/dis/auth/createsignerkey.dis";
	if(csk == nil)
		return sys->sprint("can't load createsignerkey: %r");
	{
		csk->init(nil, "createsignerkey" :: "-a" :: alg :: "-f" :: "/keydb/signerkey" :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey: " + e;
	}
	(ok, nil) := sys->stat("/keydb/signerkey");
	if(ok < 0)
		return sys->sprint("no signer key made: %r");
	return nil;
}

# one logind on a loopback port, as login_test's
serve(addrc: chan of string)
{
	sys->pctl(Sys->FORKENV|Sys->NEWPGRP, nil);
	setcnsa(0);
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		addrc <-= nil;
		addrc <-= sys->sprint("announce: %r");
		return;
	}
	fd := sys->open(c.dir+"/local", Sys->OREAD);
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0){
		addrc <-= nil;
		addrc <-= "no local address";
		return;
	}
	local := string buf[0:n];
	while(local != nil && (local[len local-1] == '\n' || local[len local-1] == ' '))
		local = local[0:len local-1];
	addrc <-= "tcp!" + local;
	(lok, nc) := sys->listen(c);
	if(lok < 0)
		return;
	dfd := sys->open(nc.dir+"/data", Sys->ORDWR);
	if(dfd == nil)
		return;
	sys->dup(dfd.fd, 0);
	dfd = nil;
	sys->pctl(Sys->NEWFD, 0 :: 2 :: nil);
	logind := load Command "/dis/auth/logind.dis";
	if(logind == nil)
		return;
	logind->init(nil, "logind" :: nil);
}

client(addr: string, res: chan of (string, ref Keyring->Authinfo))
{
	sys->pctl(Sys->FORKENV, nil);
	setcnsa(0);
	res <-= login->login(User, Password, addr);
}

# a login from a signer whose key is alg's: the certificate arrives and verifies
loginfrom(t: ref T, alg: string)
{
	if(login == nil)
		t.skip(sys->sprint("cannot load %s: %r", Login->PATH));
	if(testdir == nil){
		err := setup();
		if(err != nil)
			t.fatal(err);
	}
	err := signerkey(alg);
	if(err != nil)
		t.fatal(err);
	addrc := chan of string;
	spawn serve(addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("serve: " + <-addrc);
	res := chan[1] of (string, ref Keyring->Authinfo);
	spawn client(addr, res);
	tmo := chan of int;
	spawn timer(tmo, 120000);
	info: ref Keyring->Authinfo;
	alt {
	(err, info) = <-res =>
		;
	<-tmo =>
		t.fatal("login took more than two minutes");
	}
	t.assertnil(err, alg + " signer: login");
	if(info == nil || info.cert == nil || info.spk == nil || info.mypk == nil)
		t.fatal(alg + " signer: no certificate");
	t.assertseq(info.cert.sa.name, alg, "the certificate's algorithm");
	t.assertseq(info.mypk.owner, User, "a key for " + User);
	b := array of byte kr->pktostr(info.mypk);
	st: ref Keyring->DigestState;
	case info.cert.ha {
	"sha384" =>
		st = kr->sha384(b, len b, nil, nil);
	"sha512" =>
		st = kr->sha512(b, len b, nil, nil);
	* =>
		st = kr->sha256(b, len b, nil, nil);
	}
	t.assert(kr->verify(info.spk, info.cert, st) != 0, alg + " signer: the certificate verifies with the signer's key");
	t.log(sys->sprint("%s signer: the certificate is %d bytes of text", alg, len kr->certtostr(info.cert)));
}

testLoginMLDSA87(t: ref T)
{
	loginfrom(t, "mldsa87");
}

testLoginSLH256(t: ref T)
{
	loginfrom(t, "slhdsa256s");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
	login = load Login Login->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(auth != nil)
		auth->init();
	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);

	run("Stream", testStream);
	run("StreamHostile", testStreamHostile);
	run("Delimited", testDelimited);
	run("OverSSL", testOverSSL);
	run("AuthMLDSA87", testAuthMLDSA87);
	run("AuthSLH192", testAuthSLH192);
	run("AuthSLH256", testAuthSLH256);
	run("AuthCannotSign", testAuthCannotSign);
	run("LoginMLDSA87", testLoginMLDSA87);
	run("LoginSLH256", testLoginSLH256);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
