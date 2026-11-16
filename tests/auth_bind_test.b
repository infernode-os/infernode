implement AuthBindTest;

#
# The ssl algorithm an authenticated connection runs under is the one
# its client chose, and nobody else's (appl/lib/auth.b).
#
# After Keyring->auth the client said its choice in one message, in
# clear, with nothing to vouch for it.  A server that would take
# "none" beside a cipher (listen -M -a none -a aes_256_gcm) could be
# shown "none" by whoever carried the bytes: it then ran the session
# it had just authenticated for that client in clear, and took
# whatever the carrier wrote next as the client's.  The client, its
# cipher turned on, failed at its own end and learnt nothing.
#
# The choice is now confirmed with the shared secret each way, and
# ssl's keys are made of the secret and of what both ends said.  Here
# a relay sits between an honest client and an honest server, on two
# pipes, and changes what it carries: the client's choice (a cipher
# to none, none to a cipher), then the server's answer.  Each fails
# at both ends, and nothing the relay writes is read as the client's.
# The rest: each algorithm through a relay that changes nothing; an
# end of the exchange before this one refused each way, saying so, and
# not left waiting; a choice the server will not have refused in the
# server's own words, which the client reports with what the server
# does take; and a client that confirms its choice but makes its keys
# of the bare secret, whose records the server cannot open.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "security.m";
	auth: Auth;
	ssl: SSL;
include "testing.m";
	testing: Testing;
	T: import testing;

AuthBindTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auth_bind_test.b";
PLAIN: con "what-the-client-wrote";
INTRUDER: con "what-the-carrier-wrote";
VERSION: con "infernode-auth 2";

passed := 0;
failed := 0;
skipped := 0;

sai, cai: ref Keyring->Authinfo;

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

mkauthinfo(signersk: ref Keyring->SK, signerpk: ref Keyring->PK,
		alpha, p: ref Keyring->IPint, name: string): ref Keyring->Authinfo
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

timer(c: chan of string, ms: int)
{
	for(e := 0; e < ms; e += 100)
		sys->sleep(100);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# the server's end: what it made of the connection, and what it then read
srvproc(algs: list of string, fd: ref Sys->FD, res: chan of string)
{
	r := "";
	{
		(nfd, id) := auth->server(algs, sai, fd, 0);
		fd = nil;
		if(nfd == nil)
			r = "REFUSED: " + id;
		else {
			buf := array[128] of byte;
			n := sys->read(nfd, buf, len buf);
			if(n < 0)
				r = sys->sprint("ACCEPTED, read error: %r");
			else if(n == 0)
				r = "ACCEPTED, read nothing";
			else
				r = "ACCEPTED, read: " + string buf[0:n];
		}
	}exception e{
	"*" =>
		r = "server raised: " + e;
	}
	res <-= r;
}

# the client's: what Auth told it, and whether it could write
clientproc(alg: string, fd: ref Sys->FD, res: chan of string)
{
	r := "";
	{
		(nfd, err) := auth->client(alg, cai, fd);
		fd = nil;
		if(nfd == nil)
			r = "client: " + err;
		else if(sys->fprint(nfd, "%s", PLAIN) < 0)
			r = sys->sprint("client write: %r");
		else {
			r = "sent";
			res <-= r;
			sys->sleep(1500);	# keep the conversation until the server has read
			return;
		}
	}exception e{
	"*" =>
		r = "client raised: " + e;
	}
	res <-= r;
}

# ---- the carrier

# One Keyring message from fd, as it was framed: (header, payload), or
# (nil, nil) at the end
frame(fd: ref Sys->FD): (array of byte, array of byte)
{
	h := array[16] of byte;
	n := 0;
	for(;;) {
		if(n >= len h || sys->read(fd, h[n:], 1) != 1)
			return (nil, nil);
		if(h[n++] == byte '\n')
			break;
	}
	s := string h[0:n-1];
	if(len s > 0 && s[0] == '!')
		s = s[1:];
	m := int s;
	if(m < 0 || m > 1<<20)
		return (nil, nil);
	b := array[m] of byte;
	for(i := 0; i < m; ) {
		k := sys->read(fd, b[i:], m - i);
		if(k <= 0)
			return (nil, nil);
		i += k;
	}
	return (h[0:n], b);
}

reframe(b: array of byte): array of byte
{
	h := array of byte sys->sprint("%4.4d\n", len b);
	r := array[len h + len b] of byte;
	r[0:] = h;
	r[len h:] = b;
	return r;
}

# Carry from one end to the other.  Messages are looked at one at a
# time until edit changes one; then inject is written after it, if
# there is any, and what the sender says after that is dropped, the
# carrier having taken its place; with nothing to inject the rest is
# carried as it comes.
carry(src, dst: ref Sys->FD, edit: ref fn(b: array of byte): array of byte, inject: string, pidc: chan of int, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	carry0(src, dst, edit, inject);
	src = nil;
	dst = nil;
	done <-= 1;
}

carry0(src, dst: ref Sys->FD, edit: ref fn(b: array of byte): array of byte, inject: string)
{
	{
		if(edit != nil)
			for(;;) {
				(h, b) := frame(src);
				if(h == nil)
					return;
				nb := edit(b);
				if(nb == nil) {
					sys->write(dst, h, len h);
					sys->write(dst, b, len b);
					continue;
				}
				out := reframe(nb);
				sys->write(dst, out, len out);
				if(inject != nil) {
					sys->sleep(300);	# after the server has taken the choice
					sys->fprint(dst, "%s", inject);
					buf := array[8192] of byte;
					while(sys->read(src, buf, len buf) > 0)
						;
					return;
				}
				break;
			}
		buf := array[8192] of byte;
		while((n := sys->read(src, buf, len buf)) > 0)
			if(sys->write(dst, buf, n) != n)
				break;
	}exception{
	"*" =>
		;	# an end has hung up
	}
}

# Both ways at once; when one way ends (an end has hung up) the other
# is stopped, so that the far end is hung up on too
carrier(cfd, sfd: ref Sys->FD, c2s, s2c: ref fn(b: array of byte): array of byte, inject: string)
{
	pidc := chan of int;
	done := chan[2] of int;
	spawn carry(cfd, sfd, c2s, inject, pidc, done);
	p1 := <-pidc;
	spawn carry(sfd, cfd, s2c, nil, pidc, done);
	p2 := <-pidc;
	cfd = nil;
	sfd = nil;
	<-done;
	kill(p1);
	kill(p2);
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

swapto: string;	# what the carrier puts in place of the client's choice

# the client's choice, in this version's message or the one before's
editchoice(b: array of byte): array of byte
{
	s := string b;
	if(len s > len VERSION && s[0:len VERSION] == VERSION) {
		(nil, l) := sys->tokenize(s, "\n");
		if(len l != 3)
			return nil;
		return array of byte (VERSION + "\n" + swapto + "\n" + hd tl tl l);
	}
	if(s == "aes_256_gcm" || s == "none" || s == "hmac_sha384")
		return array of byte swapto;
	return nil;
}

# the server's answer, with another list in it
editanswer(b: array of byte): array of byte
{
	s := string b;
	if(len s < 3 || s[0:3] != "ok\n")
		return nil;
	(nil, l) := sys->tokenize(s, "\n");
	if(len l != 3)
		return nil;
	return array of byte ("ok\nnone aes_256_gcm hmac_sha384\n" + hd tl tl l);
}

# and with its confirmation changed
editanswertag(b: array of byte): array of byte
{
	s := string b;
	if(len s < 3 || s[0:3] != "ok\n")
		return nil;
	c := s[len s - 1];
	if(c == '0')
		c = '1';
	else
		c = '0';
	return array of byte (s[0:len s - 1] + sys->sprint("%c", c));
}

# A client, a server, and what is between them: (what the server made
# of it, what the client did)
session(algs: list of string, alg: string, c2s, s2c: ref fn(b: array of byte): array of byte, inject: string): (string, string)
{
	pc := array[2] of ref Sys->FD;
	ps := array[2] of ref Sys->FD;
	if(sys->pipe(pc) < 0 || sys->pipe(ps) < 0)
		return (sys->sprint("pipe: %r"), "");
	res := chan[1] of string;
	cres := chan[1] of string;
	spawn srvproc(algs, ps[1], res);
	spawn clientproc(alg, pc[0], cres);
	spawn carrier(pc[1], ps[0], c2s, s2c, inject);
	pc = nil;
	ps = nil;
	spawn timer(res, 10000);
	spawn timer(cres, 10000);
	s := <-res;
	c := <-cres;
	return (s, c);
}

BOTH: list of string;
CLEAR: con "ACCEPTED, read: " + PLAIN;

testCarried(t: ref T)
{
	for(l := "aes_256_gcm" :: "hmac_sha384" :: "none" :: nil; l != nil; l = tl l) {
		(s, c) := session("none" :: "aes_256_gcm" :: "hmac_sha384" :: nil, hd l, nil, nil, nil);
		t.assertseq(s, CLEAR, hd l + " through a carrier that changes nothing: the server reads the client's data");
		t.assertseq(c, "sent", hd l + ": the client");
	}
}

# The attack: a cipher changed to none where the server takes either.
testChoiceChanged(t: ref T)
{
	swapto = "none";
	(s, c) := session(BOTH, "aes_256_gcm", editchoice, nil, INTRUDER);
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "not confirmed"),
		"the client chose aes_256_gcm and the carrier wrote none: the server refuses (it ran the session in clear, and read what the carrier wrote as the client's): " + s);
	t.assert(!contains(s, INTRUDER), "nothing the carrier wrote was read as the client's: " + s);
	t.assert(len c >= 7 && c[0:7] == "client:" && c != "sent", "and the client is told its choice was not confirmed: " + c);

	# the other way, and to another algorithm: no choice but the client's
	swapto = "aes_256_gcm";
	(s, c) = session(BOTH, "none", editchoice, nil, nil);
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "not confirmed"), "none changed to aes_256_gcm: " + s);
	t.assert(c != "sent" || s != CLEAR, "the client: " + c);
	swapto = "hmac_sha384";
	(s, c) = session("aes_256_gcm" :: "hmac_sha384" :: nil, "aes_256_gcm", editchoice, nil, nil);
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "not confirmed"), "aes_256_gcm changed to hmac_sha384 (encryption taken away): " + s);
	swapto = " ";
	(s, c) = session(BOTH, "aes_256_gcm", editchoice, nil, INTRUDER);
	t.assert(len s >= 8 && s[0:8] == "REFUSED:", "aes_256_gcm changed to a blank: " + s);
}

testAnswerChanged(t: ref T)
{
	(s, c) := session(BOTH, "aes_256_gcm", nil, editanswer, nil);
	t.assert(len c >= 7 && c[0:7] == "client:" && contains(c, "not confirmed"), "the server's answer carried with another list in it: the client stops: " + c);
	t.assert(s != CLEAR, "and the server reads nothing of the client's: " + s);
	(s, c) = session(BOTH, "aes_256_gcm", nil, editanswertag, nil);
	t.assert(len c >= 7 && c[0:7] == "client:" && contains(c, "not confirmed"), "the server's confirmation changed: " + c);
	(s, c) = session("none" :: nil, "none", nil, editanswertag, nil);
	t.assert(len c >= 7 && c[0:7] == "client:" && contains(c, "not confirmed"), "the same when the choice is none: " + c);
}

# ---- ends of another version

# a client of the exchange before: its algorithm, bare, and on it goes
oldclient(alg: string, fd: ref Sys->FD, res: chan of string)
{
	{
		(nil, secret) := kr->auth(fd, cai, 0);
		if(secret == nil) {
			res <-= "client: no secret";
			return;
		}
		b := array of byte alg;
		kr->sendmsg(fd, b, len b);
		sys->fprint(fd, "%s", PLAIN);
		res <-= "sent";
		sys->sleep(500);
	}exception e{
	"*" =>
		res <-= "client raised: " + e;
	}
}

# a server of the exchange before: it looks for the client's words in
# its list, and hangs up on ones it does not have
oldserver(algs: list of string, fd: ref Sys->FD, res: chan of string)
{
	{
		(nil, secret) := kr->auth(fd, sai, 0);
		if(secret == nil) {
			res <-= "REFUSED: no secret";
			return;
		}
		(nil, words) := sys->tokenize(string kr->getmsg(fd), " /");
		for(; words != nil; words = tl words) {
			for(l := algs; l != nil; l = tl l)
				if(hd l == hd words)
					break;
			if(l == nil) {
				res <-= "REFUSED: unsupported client algorithm: " + hd words;
				return;
			}
		}
		res <-= "ACCEPTED";
		sys->sleep(500);
	}exception e{
	"*" =>
		res <-= "server raised: " + e;
	}
}

testOtherVersions(t: ref T)
{
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	res := chan[1] of string;
	cres := chan[1] of string;
	spawn srvproc("none" :: nil, p[1], res);
	spawn oldclient("none", p[0], cres);
	p = nil;
	spawn timer(res, 10000);
	s := <-res;
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "version before"), "a client of the exchange before, asking for none: refused, and the server says what it is: " + s);

	p = array[2] of ref Sys->FD;
	sys->pipe(p);
	res = chan[1] of string;
	cres = chan[1] of string;
	spawn srvproc("aes_256_gcm" :: nil, p[1], res);
	spawn oldclient("aes_256_gcm", p[0], cres);
	p = nil;
	spawn timer(res, 10000);
	s = <-res;
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "version before"), "and asking for a cipher: " + s);

	p = array[2] of ref Sys->FD;
	sys->pipe(p);
	res = chan[1] of string;
	cres = chan[1] of string;
	spawn oldserver("aes_256_gcm" :: nil, p[1], res);
	spawn clientproc("aes_256_gcm", p[0], cres);
	p = nil;
	spawn timer(cres, 10000);
	c := <-cres;
	t.assert(len c >= 7 && c[0:7] == "client:" && contains(c, "did not confirm") && contains(c, "version before"),
		"a server of the exchange before: the client is not left waiting, and says what the server may be: " + c);
}

# A choice the server will not have is refused in the server's words.
testRefusalSaysWhy(t: ref T)
{
	(s, c) := session("aes_256_gcm" :: nil, "hmac_sha384", nil, nil, nil);
	t.assert(len s >= 8 && s[0:8] == "REFUSED:" && contains(s, "unsupported client algorithm"), "integrity alone asked of a server that takes a cipher: " + s);
	t.assert(contains(c, "unsupported client algorithm: hmac_sha384") && contains(c, "the server takes: aes_256_gcm"),
		"the client says why, and what the server does take (it had a closed connection and no reason): " + c);
	(s, c) = session("aes_256_gcm" :: nil, "none", nil, nil, nil);
	t.assert(contains(c, "the server takes: aes_256_gcm"), "none asked of it: " + c);
}

# ---- the keys are made of what was said

confirmkey(secret: array of byte): array of byte
{
	l := array of byte "infernode auth 2 confirm";
	k := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(l, len l, secret, k, nil);
	return k;
}

mac(key: array of byte, text: string): string
{
	b := array of byte text;
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(b, len b, key, d, nil);
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

# a client that confirms its choice as Auth's does, and then makes
# ssl's keys of bound (the secret itself, or what Auth makes of it)
handclient(alg, offered: string, bound: int, fd: ref Sys->FD, res: chan of string)
{
	{
		(nil, secret) := kr->auth(fd, cai, 0);
		if(secret == nil) {
			res <-= "client: no secret";
			return;
		}
		b := array of byte (VERSION + "\n" + alg + "\n" + mac(confirmkey(secret), "client\n" + alg));
		kr->sendmsg(fd, b, len b);
		if(kr->getmsg(fd) == nil) {
			res <-= "client: no answer";
			return;
		}
		if(bound) {
			l := array of byte ("infernode auth 2 ssl\n" + alg + "\n" + offered);
			k := array[Keyring->SHA384dlen] of byte;
			kr->hmac_sha384(l, len l, secret, k, nil);
			secret = k;
		}
		(err, c) := ssl->connect(fd);
		if(err != nil) {
			res <-= "client: " + err;
			return;
		}
		(sin, sout) := ssl->secrets(secret, 1);
		ssl->secret(c, sin, sout);
		sys->fprint(c.cfd, "alg %s", alg);
		sys->fprint(c.dfd, "%s", PLAIN);
		res <-= "sent";
		sys->sleep(1000);
	}exception e{
	"*" =>
		res <-= "client raised: " + e;
	}
}

hand(alg, offered: string, algs: list of string, bound: int): string
{
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	res := chan[1] of string;
	cres := chan[1] of string;
	spawn srvproc(algs, p[1], res);
	spawn handclient(alg, offered, bound, p[0], cres);
	p = nil;
	spawn timer(res, 10000);
	return <-res;
}

testKeysBound(t: ref T)
{
	algs := "aes_256_gcm" :: "hmac_sha384" :: nil;
	t.assertseq(hand("aes_256_gcm", "aes_256_gcm hmac_sha384", algs, 1), CLEAR,
		"keys made of the secret, the choice and the server's list, written out here again: the server reads the data");
	s := hand("aes_256_gcm", "aes_256_gcm hmac_sha384", algs, 0);
	t.assert(s != CLEAR && !contains(s, PLAIN), "keys made of the secret alone, as they were: the server cannot open the record: " + s);
	s = hand("aes_256_gcm", "aes_256_gcm", algs, 1);
	t.assert(s != CLEAR && !contains(s, PLAIN), "keys made with another list than the server's: " + s);
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
	auth = load Auth Auth->PATH;
	ssl = load SSL SSL->PATH;
	if(kr == nil || auth == nil || ssl == nil){
		sys->fprint(sys->fildes(2), "cannot load keyring, auth or ssl: %r\n");
		raise "fail:cannot load";
	}
	auth->init();
	BOTH = "none" :: "aes_256_gcm" :: nil;

	signer := kr->genSK("ed25519", "bind-signer", 0);
	(alpha, p) := kr->dhparams(2048);
	if(signer == nil || alpha == nil || p == nil){
		sys->fprint(sys->fildes(2), "cannot make a signer or a group: %r\n");
		raise "fail:no keys";
	}
	spk := kr->sktopk(signer);
	sai = mkauthinfo(signer, spk, alpha, p, "bind-server");
	cai = mkauthinfo(signer, spk, alpha, p, "bind-client");

	run("Carried", testCarried);
	run("ChoiceChanged", testChoiceChanged);
	run("AnswerChanged", testAnswerChanged);
	run("OtherVersions", testOtherVersions);
	run("RefusalSaysWhy", testRefusalSaysWhy);
	run("KeysBound", testKeysBound);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
