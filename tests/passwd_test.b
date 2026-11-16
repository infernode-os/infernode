implement PasswdTest;

#
# Changing a password, end to end: auth/passwd against auth/keysrv over
# loopback TCP, the accounts in a real keyfs(4), the certificates from a
# real logind and signer key, all in a name space of the test's own.
#
# It could not be done.  passwd proved the old secret with the SHA-1
# of the password in hex and keysrv wanted the SHA-256 of what keyfs
# holds, so every attempt was "wrong secret"; a client that sent what
# keysrv wanted had the new secret stored as typed, which no login
# matches (keyfs holds the password's SHA-256).  And what was sent was
# worth having:
#
#   - passwd threw away the name the server authenticated as, so any
#     holder of a certificate of the realm that answered at the key
#     server's address was sent the proof, a hash of the password that
#     is the same every time, and then the new password;
#   - keysrv took any number of wrong proofs in a session, counted by
#     nobody, and went on proving against the secret as it was when the
#     session began.
#
# Now keysrv runs with the signer's key and passwd refuses a server
# that is not the signer of its certificate before it asks for
# anything; the proof answers a challenge of the server's that is
# fresh for every write; the new secret is the password's SHA-256,
# sealed under a key from the old one; wrong proofs are counted in
# logind's file, and a session takes five.
#
# changelogin(8) is driven here too, for its dates.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	login: Login;
	auth: Auth;

include "daytime.m";
	daytime: Daytime;

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

PasswdTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/passwd_test.b";

passed := 0;
failed := 0;
skipped := 0;

testdir: string;
keyfspid := -1;
signer: ref Keyring->Authinfo;	# /keydb/signerkey

Old: con "correct horse battery staple";
New: con "a new and better secret";
Users := array[] of {"alice", "bob", "carol", "dave", "erin", "frank"};

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

mkdir(name: string): int
{
	fd := sys->create(name, Sys->OREAD, Sys->DMDIR|8r700);
	if(fd == nil)
		return -1;
	return 0;
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

readfile(name: string): array of byte
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return buf[0:n];
}

pwdigest(password: string): array of byte
{
	pw := array of byte password;
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pw, len pw, dig, nil);
	return dig;
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

sleeper(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

# keyfs calls pctl(NEWPGRP) in the process that starts it: one of its
# own, kept so that the group can be killed at the end
startkeyfs(nvram: string, res: chan of string)
{
	keyfspid = sys->pctl(0, nil);
	keyfs := load Command "/dis/auth/keyfs.dis";
	if(keyfs == nil){
		res <-= sys->sprint("can't load keyfs: %r");
		return;
	}
	{
		keyfs->init(nil, "keyfs" :: "-n" :: nvram :: "/keydb/keys" :: nil);
	} exception e {
	"*" =>
		res <-= "keyfs: " + e;
		return;
	}
	res <-= nil;
	<-chan of int;
}

setup(): string
{
	(tok, nil) := sys->stat("/tmp");
	if(tok < 0)
		mkdir("/tmp");
	d: string;
	for(i := 0; i < 100; i++){
		d = sys->sprint("/tmp/passwdtest.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
		if(mkdir(d) >= 0)
			break;
	}
	testdir = d;
	if(mkdir(d+"/root") < 0 || mkdir(d+"/root/keydb") < 0 ||
	   mkdir(d+"/mnt") < 0 || mkdir(d+"/mnt/keys") < 0 || mkdir(d+"/mnt/keysrv") < 0 || mkdir(d+"/mnt/kc") < 0)
		return sys->sprint("can't make %s: %r", d);
	if(writefile(d+"/root/keydb/keys", array[0] of byte) < 0 ||
	   writefile(d+"/nvram", array of byte "the key file's key") < 0 ||
	   writefile(d+"/consctl", array[0] of byte) < 0)
		return sys->sprint("can't write %s's files: %r", d);
	if(sys->bind(d+"/root", "/", Sys->MBEFORE) < 0 || sys->bind(d+"/mnt", "/mnt", Sys->MBEFORE) < 0)
		return sys->sprint("can't bind the signer's files: %r");
	# passwd and changelogin set the console raw to read a secret
	if(sys->bind(d+"/consctl", "/dev/consctl", Sys->MREPL) < 0)
		return sys->sprint("can't bind over /dev/consctl: %r");
	if(sys->bind("#c/notquiterandom", "/dev/random", Sys->MREPL) < 0)
		return sys->sprint("can't bind #c/notquiterandom over /dev/random: %r");

	res := chan of string;
	spawn startkeyfs(d+"/nvram", res);
	err := <-res;
	if(err != nil)
		return err;
	dig := pwdigest(Old);
	for(i = 0; i < len Users; i++){
		u := "/mnt/keys/"+Users[i];
		if(mkdir(u) < 0 || writefile(u+"/secret", dig) < 0)
			return sys->sprint("can't make %s in keyfs: %r", Users[i]);
	}

	csk := load Command "/dis/auth/createsignerkey.dis";
	if(csk == nil)
		return sys->sprint("can't load createsignerkey: %r");
	{
		csk->init(nil, "createsignerkey" :: "-a" :: "ed25519" :: "-f" :: "/keydb/signerkey" :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey: " + e;
	}
	signer = kr->readauthinfo("/keydb/signerkey");
	if(signer == nil)
		return sys->sprint("no signer key made: %r");
	return nil;
}

#
# One connection's server on a loopback port: logind, or keysrv with
# the arguments given.
#
serve(prog: string, args: list of string, addrc: chan of string)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		addrc <-= nil;
		return;
	}
	fd := sys->open(c.dir+"/local", Sys->OREAD);
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0){
		addrc <-= nil;
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
	cmd := load Command prog;
	if(cmd == nil)
		return;
	{
		cmd->init(nil, prog :: args);
	} exception {
	"*" =>
		;
	}
}

server(t: ref T, prog: string, args: list of string): string
{
	addrc := chan of string;
	spawn serve(prog, args, addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("can't serve " + prog);
	return addr;
}

# a login as login(2) makes it, against a logind of this name space
dologin(t: ref T, user, password: string): (string, ref Keyring->Authinfo)
{
	addr := server(t, "/dis/auth/logind.dis", nil);
	res := chan[1] of (string, ref Keyring->Authinfo);
	spawn loginproc(user, password, addr, res);
	tick := chan of int;
	spawn sleeper(tick, 30000);
	alt {
	r := <-res =>
		return r;
	<-tick =>
		t.fatal("login took more than 30 seconds");
	}
	return (nil, nil);
}

loginproc(user, password, addr: string, res: chan of (string, ref Keyring->Authinfo))
{
	res <-= login->login(user, password, addr);
}

# A certificate for owner by the test's signer, as a login would give
# (and for names a login would not).
certificate(owner: string): ref Keyring->Authinfo
{
	info := ref Keyring->Authinfo;
	info.mysk = kr->genSK("ed25519", owner, 0);
	info.mypk = kr->sktopk(info.mysk);
	info.mypk.owner = owner;
	info.mysk.owner = owner;
	b := array of byte kr->pktostr(info.mypk);
	info.cert = kr->sign(signer.mysk, 0, kr->sha256(b, len b, nil, nil), "sha256");
	info.spk = signer.mypk;
	info.alpha = signer.alpha;
	info.p = signer.p;
	return info;
}

#
# A program that asks its questions on standard output and reads the
# answers from standard input, one read a line (passwd, changelogin):
# each answer is written when its question has been asked.  What it
# printed, and how it ended.
#
dialog(prog: string, args: list of string, script: list of (string, string)): (string, string)
{
	in := array[2] of ref Sys->FD;
	out := array[2] of ref Sys->FD;
	if(sys->pipe(in) < 0 || sys->pipe(out) < 0)
		return (nil, sys->sprint("pipe: %r"));
	done := chan[1] of string;
	spawn runprog(prog, args, in[1], out[1], done);
	in[1] = nil;
	out[1] = nil;
	rc := chan of string;
	spawn outreader(out[0], rc);
	said := "";
	tick := chan of int;
	spawn sleeper(tick, 20000);
	seen := 0;
	for(;;){
		if(script != nil){
			(q, a) := hd script;
			if(contains(said[seen:], q)){
				seen = len said;
				script = tl script;
				sys->fprint(in[0], "%s\n", a);
				continue;
			}
		}
		alt {
		s := <-rc =>
			if(s == nil){
				end := "ended";
				alt {
				end = <-done =>
					;
				* =>
					;
				}
				if(script != nil)
					end += sys->sprint("; never asked %q", (hd script).t0);
				return (said, end);
			}
			said += s;
		<-tick =>
			in[0] = nil;
			what := "still running after 20 s";
			if(script != nil)
				what += sys->sprint("; never asked %q", (hd script).t0);
			return (said, what);
		}
	}
}

runprog(prog: string, args: list of string, in, out: ref Sys->FD, done: chan of string)
{
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	sys->dup(in.fd, 0);
	sys->dup(out.fd, 1);
	sys->dup(out.fd, 2);
	in = nil;
	out = nil;
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	c := load Command prog;
	if(c == nil){
		done <-= sys->sprint("can't load %s: %r", prog);
		return;
	}
	{
		c->init(nil, prog :: args);
		done <-= "returned";
	} exception e {
	"*" =>
		done <-= "raised " + e;
	}
	sys->pctl(Sys->NEWFD, nil);
}

outreader(fd: ref Sys->FD, rc: chan of string)
{
	buf := array[1024] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		rc <-= string buf[0:n];
	rc <-= nil;
}

passwd(t: ref T, keyfile: string, srvargs: list of string, script: list of (string, string)): (string, string)
{
	addr := server(t, "/dis/auth/keysrv.dis", srvargs);
	return dialog("/dis/auth/passwd.dis", "-s" :: addr :: keyfile :: nil, script);
}

# The whole thing: a login, a change of password through passwd and
# keysrv, a login with the new one.
testChange(t: ref T)
{
	(err, info) := dologin(t, "alice", Old);
	if(info == nil)
		t.fatal("alice can't log in to begin with: " + err);
	kf := testdir + "/alice.key";
	if(kr->writeauthinfo(kf, info) < 0)
		t.fatal(sys->sprint("can't write alice's key file: %r"));

	(said, end) := passwd(t, kf, nil,
		("Inferno secret: ", Old) :: ("new secret", New) :: ("confirm: ", New) :: nil);
	t.assertseq(end, "returned", "passwd, the old secret and a new one twice: " + said);
	t.assert(contains(said, "secret changed"), "it says the secret is changed: " + said);
	t.assert(!contains(said, "key owner"), "and prints nothing else of its own");
	secret := readfile("/mnt/keys/alice/secret");
	t.asserteq(len secret, Keyring->SHA256dlen, "what keyfs holds is 32 bytes");
	t.assert(eq(secret, pwdigest(New)), "the SHA-256 of the new password, as login(6) wants it");

	(err, info) = dologin(t, "alice", New);
	t.assertnil(err, "a login with the new password");
	t.assert(info != nil && info.cert != nil, "gets a certificate");
	(err, info) = dologin(t, "alice", Old);
	t.assert(info == nil && err != nil && contains(err, "incorrect"), "and the old password no longer does: " + err);
}

# A wrong old secret is said to be wrong and asked for again; no new
# secret given changes nothing.
testWrongOld(t: ref T)
{
	kf := testdir + "/bob.key";
	if(kr->writeauthinfo(kf, certificate("bob")) < 0)
		t.fatal(sys->sprint("can't write bob's key file: %r"));
	(said, end) := passwd(t, kf, nil,
		("Inferno secret: ", "not the secret") :: ("Inferno secret: ", Old) :: ("new secret", "") :: nil);
	t.assertseq(end, "returned", "passwd, a wrong secret, the right one, no new one: " + said);
	t.assert(contains(said, "!wrong secret"), "the wrong one is said to be wrong: " + said);
	t.assert(contains(said, "not changed"), "and no new secret changes nothing: " + said);
	t.assert(eq(readfile("/mnt/keys/bob/secret"), pwdigest(Old)), "bob's secret is as it was");
	sys->remove("/keydb/loginfail");

	# entries that do not match are asked for again
	(said, end) = passwd(t, kf, nil,
		("Inferno secret: ", Old) :: ("new secret", New) :: ("confirm: ", "something else") ::
		("new secret", "short") :: ("new secret", New) :: ("confirm: ", New) :: nil);
	t.assertseq(end, "returned", "passwd, a confirmation that does not match, a short secret, then a new one: " + said);
	t.assert(contains(said, "didn't match") && contains(said, "at least 8"), "each is said: " + said);
	t.assert(eq(readfile("/mnt/keys/bob/secret"), pwdigest(New)), "and bob's secret is the new one's SHA-256");
}

# The server must be the signer: one that authenticates with a user's
# certificate of the realm is given nothing.
testNotSigner(t: ref T)
{
	kf := testdir + "/carol.key";
	evil := testdir + "/erin.key";
	if(kr->writeauthinfo(kf, certificate("carol")) < 0 || kr->writeauthinfo(evil, certificate("erin")) < 0)
		t.fatal(sys->sprint("can't write key files: %r"));
	(said, end) := passwd(t, kf, "-k" :: evil :: nil, ("Inferno secret: ", Old) :: ("new secret", New) :: ("confirm: ", New) :: nil);
	t.assert(!contains(said, "Inferno secret"), "passwd asks a server that is not the signer for nothing: " + said);
	t.assert(contains(said, "not as") && contains(said, "erin"), "and says who answered: " + said);
	t.assert(contains(end, "raised fail:"), "and fails: " + end);
	t.assert(eq(readfile("/mnt/keys/carol/secret"), pwdigest(Old)), "carol's secret is as it was");
}

#
# keysrv's file by a client of the test's own.
#
Version: con "keysrv 2 ";

# keysrv on a pipe as its connection, authenticated to as ai, its file
# mounted on /mnt/kc
session(t: ref T, ai: ref Keyring->Authinfo)
{
	sys->unmount(nil, "/mnt/kc");
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		t.fatal(sys->sprint("pipe: %r"));
	done := chan of int;
	spawn runks(p[1], done);
	<-done;
	p[1] = nil;
	(fd, id) := auth->client("aes_256_gcm", ai, p[0]);
	if(fd == nil)
		t.fatal("can't authenticate to keysrv: " + id);
	if(sys->mount(fd, nil, "/mnt/kc", Sys->MREPL, nil) < 0)
		t.fatal(sys->sprint("can't mount keysrv: %r"));
}

runks(fd: ref Sys->FD, done: chan of int)
{
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	sys->pctl(Sys->NEWFD, 0 :: 2 :: nil);
	done <-= 1;
	c := load Command "/dis/auth/keysrv.dis";
	if(c == nil)
		return;
	{
		c->init(nil, "keysrv" :: nil);
	} exception {
	"*" =>
		;
	}
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%2.2ux", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	a := array[len s/2] of byte;
	for(i := 0; i < len a; i++)
		a[i] = byte ((hexval(s[2*i])<<4) | hexval(s[2*i+1]));
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	return c - 'a' + 10;
}

# the challenge, or nil and the error
challenge(): (array of byte, string)
{
	fd := sys->open("/mnt/kc/secret", Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return (nil, sys->sprint("%r"));
	s := string buf[0:n];
	if(len s != len Version + 64 || s[0:len Version] != Version)
		return (nil, sys->sprint("read %q", s));
	return (unhex(s[len Version:]), nil);
}

expand(prk: array of byte, info: string, n: int): array of byte
{
	t := array[Keyring->SHA384dlen] of byte;
	b := array of byte info;
	c := array[len b + 1] of byte;
	c[0:] = b;
	c[len b] = byte 1;
	kr->hmac_sha384(c, len c, prk, t, nil);
	return t[0:n];
}

# what keysrv(4) says is written for a challenge: the proof of secret,
# and newsecret (if any) sealed
answer(c, secret: array of byte, user: string, newsecret: array of byte): string
{
	prk := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(secret, len secret, c, prk, nil);
	s := hex(expand(prk, "infernode keysrv 2 proof" + user, Keyring->SHA384dlen));
	if(newsecret != nil){
		key := expand(prk, "infernode keysrv 2 new secret" + user, 44);
		(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(key[0:32], key[32:]), newsecret, array of byte "infernode keysrv 2 new secret");
		s += " " + hex(ct) + hex(tag);
	}
	return s;
}

# a write to keysrv's file: "ok", or the error
put(s: string): string
{
	fd := sys->open("/mnt/kc/secret", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open: %r");
	b := array of byte s;
	if(sys->write(fd, b, len b) < 0)
		return sys->sprint("%r");
	return "ok";
}

# the count /keydb/loginfail has for name; 0 if none
counted(name: string): int
{
	b := readfile("/keydb/loginfail");
	if(b == nil)
		return 0;
	nb := array of byte name;
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nb, len nb, d, nil);
	key := hex(d);
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, fl) := sys->tokenize(hd lines, " ");
		if(nf == 4 && hd fl == key)
			return int hd tl fl;
	}
	return 0;
}

# Wrong proofs: a session takes five, each is counted where logind
# counts wrong passwords, and ten lock the name for both.
testWrongProofs(t: ref T)
{
	sys->remove("/keydb/loginfail");
	dave := certificate("dave");
	session(t, dave);
	secret := pwdigest(Old);
	wrong := pwdigest("a guess");
	for(i := 0; i < 5; i++){
		(c, err) := challenge();
		if(c == nil)
			t.fatal("no challenge: " + err);
		e := put(answer(c, wrong, "dave", nil));
		t.assert(contains(e, "wrong secret"), sys->sprint("wrong proof %d: %s", i+1, e));
	}
	t.asserteq(counted("dave"), 5, "five wrong proofs are five counts in /keydb/loginfail");
	(c, nil) := challenge();
	t.assert(c == nil, "after five the session gives no more challenges");
	e := put(answer(array[32] of {* => byte 0}, secret, "dave", nil));
	t.assert(contains(e, "too many wrong secrets"), "and takes no more proofs, right or wrong: " + e);

	session(t, dave);
	for(i = 0; i < 5; i++){
		(c, nil) = challenge();
		if(c == nil)
			t.fatal("no challenge in a second session");
		put(answer(c, wrong, "dave", nil));
	}
	t.asserteq(counted("dave"), 10, "five more in another session: ten");
	session(t, dave);
	(c, nil) = challenge();
	if(c == nil)
		t.fatal("no challenge in a third session");
	e = put(answer(c, secret, "dave", nil));
	t.assert(contains(e, "too many failed attempts"), "the name is then refused, the right proof too: " + e);
	(err, info) := dologin(t, "dave", Old);
	t.assert(info == nil && err != nil && contains(err, "too many failed attempts"), "and so is a login for it: one count for both: " + err);
	sys->remove("/keydb/loginfail");
	session(t, dave);
	(c, nil) = challenge();
	e = put(answer(c, secret, "dave", nil));
	t.assertseq(e, "ok", "the right proof once the count is gone");
	t.asserteq(counted("dave"), 0, "and a right proof leaves no count");
}

# A proof answers one challenge: sent again it is wrong.  The proofs of
# the protocol before are not taken.
testReplay(t: ref T)
{
	sys->remove("/keydb/loginfail");
	frank := certificate("frank");
	session(t, frank);
	secret := pwdigest(Old);
	(c, err) := challenge();
	if(c == nil)
		t.fatal("no challenge: " + err);
	proof := answer(c, secret, "frank", nil);
	t.assertseq(put(proof), "ok", "the proof for a challenge");
	e := put(proof);
	t.assert(contains(e, "wrong secret"), "the same proof again answers no challenge: " + e);
	(c2, nil) := challenge();
	t.assert(c2 != nil && !eq(c, c2), "each write has a challenge of its own");

	# keysrv's old proof (the SHA-256 of what keyfs holds, in hex) and
	# passwd's (the SHA-1 of the password)
	d2 := array[Keyring->SHA256dlen] of byte;
	kr->sha256(secret, len secret, d2, nil);
	e = put(hex(d2));
	t.assert(!contains(e, "ok") && contains(e, "version 2"), "the old keysrv's proof is refused, saying why: " + e);
	e = put(hex(d2) + " newpassword1");
	t.assert(!contains(e, "ok"), "and with a new secret in clear: " + e);
	pw := array of byte Old;
	s1 := array[Keyring->SHA1dlen] of byte;
	kr->sha1(pw, len pw, s1, nil);
	e = put(hex(s1));
	t.assert(!contains(e, "ok") && contains(e, "version 2"), "the old passwd's proof is refused: " + e);
	t.assert(eq(readfile("/mnt/keys/frank/secret"), secret), "frank's secret is as it was");

	# a new secret that is not a password's SHA-256
	(c, nil) = challenge();
	e = put(answer(c, secret, "frank", array of byte "newpassword1"));
	t.assert(!contains(e, "ok"), "a new secret of 12 bytes is not stored: " + e);
	(c, nil) = challenge();
	e = put(answer(c, secret, "frank", nil) + " " + hex(array[48] of {* => byte 1}));
	t.assert(contains(e, "unacceptable"), "nor one not sealed under the old secret's key: " + e);
	t.assert(eq(readfile("/mnt/keys/frank/secret"), secret), "frank's secret is still as it was");
	sys->remove("/keydb/loginfail");
}

# The secret proved is the one keyfs has now, not the one it had when
# the session began.
testStale(t: ref T)
{
	sys->remove("/keydb/loginfail");
	erin := certificate("erin");
	session(t, erin);
	was := pwdigest(Old);
	now := pwdigest("the operator's new one");
	if(writefile("/mnt/keys/erin/secret", now) < 0)
		t.fatal(sys->sprint("can't change erin's secret in keyfs: %r"));
	(c, err) := challenge();
	if(c == nil)
		t.fatal("no challenge: " + err);
	e := put(answer(c, was, "erin", pwdigest("taken back")));
	t.assert(contains(e, "wrong secret"), "the secret as it was when the session began no longer proves anything: " + e);
	t.assert(eq(readfile("/mnt/keys/erin/secret"), now), "and changes nothing");
	(c, nil) = challenge();
	e = put(answer(c, now, "erin", nil));
	t.assertseq(e, "ok", "the secret as it is now does");
	sys->remove("/keydb/loginfail");
}

# A certificate whose name is a path is no account's.
testName(t: ref T)
{
	names := array[] of {"x/../alice", "../../tmp", "alice/."};
	for(i := 0; i < len names; i++){
		session(t, certificate(names[i]));
		(c, err) := challenge();
		t.assert(c == nil && contains(err, "bad user name"), sys->sprint("a certificate for %q is given no challenge: %s", names[i], err));
	}
	# and one for a name with no account
	session(t, certificate("nobody"));
	(c, err) := challenge();
	t.assert(c == nil && err != nil, "a certificate for a name with no account: " + err);
}

#
# changelogin(8), its answers typed as it asks.
#
expiry(user: string): ref Daytime->Tm
{
	b := readfile("/mnt/keys/"+user+"/expire");
	if(b == nil || string b == "never")
		return nil;
	return daytime->local(int string b);
}

testChangelogin(t: ref T)
{
	sys->remove("/keydb/loginfail");
	# A new account; dates that are none are each refused and asked for
	# again: month 00 (it was taken, as January), 31 February (it was 3
	# March), a year whose seconds do not fit, a date in the past.
	(said, end) := dialog("/dis/auth/changelogin.dis", "gina" :: nil,
		("secret: ", New) :: ("confirm: ", New) ::
		("expires [", "15002031") :: ("expires [", "31022031") :: ("expires [", "29022031") ::
		("expires [", "01012039") :: ("expires [", "0101203x") ::
		("expires [", "01012000") :: ("expires [", "01032031") :: nil);
	t.assertseq(end, "returned", "changelogin, a new account, six dates that are none and one that is: " + said);
	t.assert(contains(said, "!bad month 0"), "month 00 is refused: " + said);
	t.assert(contains(said, "!bad day of month 31") && contains(said, "!bad day of month 29"), "31 and 29 February 2031 are refused");
	t.assert(contains(said, "!bad expiration date 01012039"), "a date past the last an int holds is refused");
	t.assert(contains(said, "!bad date format 0101203x"), "a date that is not digits is refused");
	t.assert(contains(said, "!bad expiration date 01012000"), "a date in the past is refused");
	tm := expiry("gina");
	if(tm == nil)
		t.fatal("gina has no expiry");
	t.assert(tm.mday == 1 && tm.mon == 2 && tm.year == 131, sys->sprint("the expiry is 1 March 2031: %d/%d/%d", tm.mday, tm.mon+1, tm.year+1900));
	t.assert(tm.hour == 23 && tm.min == 59 && tm.sec == 59,
		sys->sprint("at the end of that day, though dates were refused before it: %.2d:%.2d:%.2d", tm.hour, tm.min, tm.sec));
	t.assert(eq(readfile("/mnt/keys/gina/secret"), pwdigest(New)), "the secret is the password's SHA-256");
	(err, info) := dologin(t, "gina", New);
	t.assert(info != nil, "and the account logs in: " + err);

	# no new secret and no new date: the entry is as it was
	(said, end) = dialog("/dis/auth/changelogin.dis", "gina" :: nil,
		("don't change]: ", "") :: ("expires [", "") :: nil);
	t.assertseq(end, "returned", "changelogin, return at both questions: " + said);
	t.assert(eq(readfile("/mnt/keys/gina/secret"), pwdigest(New)), "leaves the secret");
	tm2 := expiry("gina");
	t.assert(tm2 != nil && daytime->tm2epoch(tm2) == daytime->tm2epoch(tm), "and the expiry");

	# a leap day is a day
	(said, end) = dialog("/dis/auth/changelogin.dis", "gina" :: nil,
		("don't change]: ", "") :: ("expires [", "29022032") :: nil);
	tm = expiry("gina");
	t.assert(end == "returned" && tm != nil && tm.mday == 29 && tm.mon == 1 && tm.year == 132, "29 February 2032 is taken: " + said);

	# a name that is a path is no account's
	names := array[] of {"../x", "gina/.", "a/b", ".."};
	for(i := 0; i < len names; i++){
		(said, end) = dialog("/dis/auth/changelogin.dis", names[i] :: nil,
			("secret: ", New) :: ("confirm: ", New) :: ("expires [", "") :: nil);
		t.assert(contains(end, "raised fail:") && contains(said, "not an account name"),
			sys->sprint("changelogin %s is refused before it asks anything: %s (%s)", names[i], said, end));
		t.assert(!contains(said, "secret: "), sys->sprint("changelogin %s asks nothing", names[i]));
	}
	sys->remove("/keydb/loginfail");
}

#
# A secret is typed with the console raw, where nothing edits the line:
# a backspace typed to correct a slip, a line killed with ^U, and a \r
# before the newline were each characters of the secret that was
# hashed.  login(2)'s readsecret edits the line as it reads it.
#
testTyped(t: ref T)
{
	sys->remove("/keydb/loginfail");
	typed := "zzzz\u0015" + New[0:5] + "Qé\b\b" + New[5:] + "\r";
	(said, end) := dialog("/dis/auth/changelogin.dis", "hank" :: nil,
		("secret: ", typed) :: ("confirm: ", New) :: ("expires [", "permanent") :: nil);
	t.assertseq(end, "returned", "changelogin, a secret typed with corrections, confirmed without: " + said);
	t.assert(eq(readfile("/mnt/keys/hank/secret"), pwdigest(New)), "the secret is the SHA-256 of what was meant");
	(err, info) := dologin(t, "hank", New);
	t.assert(info != nil, "and the account logs in with it: " + err);
	# seven characters, however many bytes, are too few
	(said, end) = dialog("/dis/auth/changelogin.dis", "hank" :: nil,
		("don't change]: ", "ééééééé") :: ("don't change]: ", "") :: ("expires [", "") :: nil);
	t.assert(contains(said, "at least 8 characters"), "seven characters of fourteen bytes are too few: " + said);
	sys->remove("/keydb/loginfail");
}

kill(pid: int, how: string)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", how);
}

rmtree(d: string)
{
	if(d == nil)
		return;
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
	sys->remove(d);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	login = load Login Login->PATH;
	auth = load Auth Auth->PATH;
	daytime = load Daytime Daytime->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(login == nil || auth == nil || daytime == nil){
		sys->fprint(sys->fildes(2), "cannot load Login, Auth or Daytime: %r\n");
		raise "fail:cannot load";
	}
	auth->init();

	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	err := setup();
	if(err != nil){
		sys->fprint(sys->fildes(2), "passwd_test: %s\n", err);
		if(keyfspid >= 0)
			kill(keyfspid, "killgrp");
		rmtree(testdir);
		raise "fail:setup";
	}

	run("Passwd/Change", testChange);
	run("Passwd/WrongOld", testWrongOld);
	run("Passwd/NotSigner", testNotSigner);
	run("Keysrv/WrongProofs", testWrongProofs);
	run("Keysrv/Replay", testReplay);
	run("Keysrv/Stale", testStale);
	run("Keysrv/Name", testName);
	run("Changelogin/Dates", testChangelogin);
	run("Changelogin/Typed", testTyped);

	sys->unmount(nil, "/mnt/kc");
	sys->unmount(nil, "/mnt/keys");
	kill(keyfspid, "killgrp");
	rmtree(testdir);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
