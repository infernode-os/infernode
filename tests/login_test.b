implement LoginTest;

#
# login(2) against a real auth/logind over loopback TCP: the client and
# the signer each in an environment of their own, so each can be in CNSA
# mode (/env/cnsamode) or not. In CNSA mode the client offers suite 2
# (AES-256-GCM's stream, SHA-384, a group of 3072 bits) and a signer in
# CNSA mode refuses suite 1. The signer's files are made here, in a name
# space of the test's own: /keydb/signerkey and /mnt/keys/<user>/secret
# (the password's SHA-256) and expire, as keyfs(4) serves them.
#
# The exchange is login(6)'s version 2, and the second half of this file
# is about what the exchange before it gave away. It has clients and
# signers of its own, written from the manual page and not through the
# Login module, that do what a peer without the password can do:
#   - send 0, 1, p-1, p or p+1 for the client's Diffie-Hellman value (it
#     got a certificate for any account: the secret was then 0, 1 or one
#     of two values);
#   - collect the signer's reply and try passwords against it (the reply
#     was sealed, and its tag said which was right; now each password
#     unmasks it to a number in range, a square or not as a coin falls);
#   - send the same hello twice (the signer sealed a new value under the
#     same key and nonce);
#   - answer the client with a group or a modulus of its own (it sent
#     p = 2 and was the signer), or with a value of 0, 1 or p-1;
#   - stand between the two and change one thing;
#   - give a name that is a path (carol/. was carol to keyfs and
#     another name to the throttle);
#   - speak the old exchange, to either end.
# Each is refused, counted where a password was tried, and recorded in
# the audit log, whose sink (/mnt/audit/log) the test serves.
# tests/host/login_test.sh checks the groups and the key derivation's
# known answers against Python, and runs this under -c0 and -c1.
#
# logind's failed-attempt throttle (AC-7) is checked with users of its
# own, its counts in /keydb/loginfail of this name space: Maxfail logins
# that do not prove the password refuse the next, fewer do not, a login
# that works clears the count, and a name with no account is counted and
# refused the same way, in the same words. A name with no account, or an
# expired one, is answered as a wrong password is: the client gets the
# same error, so one login does not tell it which names have accounts.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	login: Login;
	ssl: SSL;

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LoginTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/login_test.b";

passed := 0;
failed := 0;
skipped := 0;

User: con "alice";
Users := array[] of {User, "carol", "dave", "erin", "frank", "gwen", "heidi", "ivan", "judy", "ken", "signer"};
Expired: con "gwen";	# an entry whose expire reads "expired"
Maxfail: con 10;	# logind's
Wrong: con "correct horse battery stapler";
testdir: string;
Password: con "correct horse battery staple";

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

#
# The signer's files, under a directory unioned before / and /mnt, so
# /keydb and /mnt/keys are there in this name space and no other.
#
setup(): string
{
	(tok, nil) := sys->stat("/tmp");
	if(tok < 0)
		mkdir("/tmp");
	# a run that was killed leaves its directory, and the next emulator
	# has the same pids and much the same clock
	d: string;
	for(i := 0; i < 100; i++){
		d = sys->sprint("/tmp/logintest.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
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
	for(i = 0; i < len Users; i++){
		u := d+"/mnt/keys/"+Users[i];
		exp := "never";
		if(Users[i] == Expired)
			exp = "expired";
		if(mkdir(u) < 0 || writefile(u+"/secret", dig) < 0 ||
		   writefile(u+"/expire", array of byte exp) < 0)
			return sys->sprint("can't write %s's entry: %r", Users[i]);
	}
	if(sys->bind(d+"/root", "/", Sys->MBEFORE) < 0 || sys->bind(d+"/mnt", "/mnt", Sys->MBEFORE) < 0)
		return sys->sprint("can't bind the signer's files: %r");

	# login(2) draws its IV from /dev/random (Random->ReallyRandom),
	# seconds a read (ten on the macOS runners), and the throttle's
	# tests make dozens of logins: the DRBG in its place, in this name
	# space alone. What is checked does not depend on the generator.
	if(sys->bind("#c/notquiterandom", "/dev/random", Sys->MREPL) < 0)
		return sys->sprint("can't bind #c/notquiterandom over /dev/random: %r");

	# the audit log's sink, as auditfs(4) would serve it
	if(sys->bind("#s", "/mnt/audit", Sys->MREPL) < 0)
		return sys->sprint("can't bind #s on /mnt/audit: %r");
	af := sys->file2chan("/mnt/audit", "log");
	if(af == nil)
		return sys->sprint("can't serve /mnt/audit/log: %r");
	spawn auditsrv(af);

	csk := load Command "/dis/auth/createsignerkey.dis";
	if(csk == nil)
		return sys->sprint("can't load createsignerkey: %r");
	setcnsa(0);
	{
		csk->init(nil, "createsignerkey" :: "-a" :: "ed25519" :: "-f" :: "/keydb/signerkey" :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey: " + e;
	}
	(ok, nil) := sys->stat("/keydb/signerkey");
	if(ok < 0)
		return sys->sprint("no signer key made: %r");
	# and a CNSA signer's key (ML-DSA-87, SHA-384, 3072 bits), which a
	# logind in CNSA mode has in place of the other
	cnsakey = d + "/cnsakey";
	{
		csk->init(nil, "createsignerkey" :: "-c" :: "-f" :: cnsakey :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey -c: " + e;
	}
	(ok, nil) = sys->stat(cnsakey);
	if(ok < 0)
		return sys->sprint("no CNSA signer key made: %r");
	return nil;
}

cnsakey: string;

# how a signer is run: in CNSA mode or not, and with the other mode's key
Otherkey: con 2;

# Keyring's messages hold so much (4096 bytes, keyring.c's Maxmsg), and
# an ML-DSA-87 certificate is 6197 as text: until they hold one, a
# signer with a CNSA key can do everything but deliver the certificate,
# and says so.
bigmsgs(): int
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return 0;
	s := "";
	for(i := 0; i < 70; i++)
		s += "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789";
	# 7000 bytes do not fill a pipe
	if(login->putstring(p[0], s) != nil)
		return 0;
	(got, nil) := kr->getstring(p[1]);
	return got == s;
}

# A CNSA login that got no certificate because one does not fit a
# message is skipped, having said so; any other failure is one.
cnsaloggedin(t: ref T, what: string, err: string, info: ref Keyring->Authinfo)
{
	if(info == nil && !bigmsgs()){
		t.assert(err != nil && contains(err, "does not fit a message"), what + ": the signer says its certificate does not fit a message: " + err);
		t.skip(what + ": Keyring's messages do not hold an ML-DSA-87 certificate yet");
	}
	loggedin(t, what, err, info);
	if(info != nil){
		t.assertnil(login->cnsakey(info), what + ": the key file is CNSA's");
		t.assertseq(info.cert.ha, "sha384", what + ": the certificate's hash");
	}
}

#
# One logind, in an environment of its own with cnsamode as given, on
# a loopback port; its address is sent on addrc, or nil and why.
#
serve(cnsa: int, addrc: chan of string)
{
	sys->pctl(Sys->FORKENV|Sys->FORKNS|Sys->NEWPGRP, nil);
	other := cnsa & Otherkey;
	cnsa &= 1;
	setcnsa(cnsa);
	if(cnsa != 0 && !other || cnsa == 0 && other)
		if(sys->bind(cnsakey, "/keydb/signerkey", Sys->MREPL) < 0){
			addrc <-= nil;
			addrc <-= sys->sprint("can't bind the CNSA key: %r");
			return;
		}
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

#
# A login with cnsamode as given on each side; the error, or nil and
# the Authinfo.
#
dologin(t: ref T, clientcnsa, servercnsa: int, password: string): (string, ref Keyring->Authinfo)
{
	return userlogin(t, User, clientcnsa, servercnsa, password);
}

userlogin(t: ref T, user: string, clientcnsa, servercnsa: int, password: string): (string, ref Keyring->Authinfo)
{
	addrc := chan of string;
	spawn serve(servercnsa, addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("serve: " + <-addrc);
	res := chan of (string, ref Keyring->Authinfo);
	spawn client(user, clientcnsa, password, addr, res);
	timeout := chan of int;
	spawn sleeper(timeout, 30000);
	alt {
	(err, info) := <-res =>
		return (err, info);
	<-timeout =>
		t.fatal("login took more than 30 seconds");
	}
	return (nil, nil);
}

client(user: string, cnsa: int, password, addr: string, res: chan of (string, ref Keyring->Authinfo))
{
	sys->pctl(Sys->FORKENV, nil);
	setcnsa(cnsa);
	(err, info) := login->login(user, password, addr);
	res <-= (err, info);
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

# A login that worked has a certificate for User from the signer.
loggedin(t: ref T, what: string, err: string, info: ref Keyring->Authinfo)
{
	userloggedin(t, User, what, err, info);
}

userloggedin(t: ref T, user, what: string, err: string, info: ref Keyring->Authinfo)
{
	t.assertnil(err, what + ": login");
	if(info == nil){
		t.error(what + ": no Authinfo");
		return;
	}
	t.assert(info.cert != nil, what + ": a certificate");
	t.assert(info.mypk != nil && info.mypk.owner == user, what + ": a key for " + user);
	if(info.cert != nil && info.spk != nil)
		t.assert(kr->verify(info.spk, info.cert, certsum(info)) != 0, what + ": the certificate verifies with the signer's key");
}

# what logind signed: the user's public key as a string, by the cert's hash
certsum(info: ref Keyring->Authinfo): ref Keyring->DigestState
{
	b := array of byte kr->pktostr(info.mypk);
	if(info.cert.ha == "sha384")
		return kr->sha384(b, len b, nil, nil);
	return kr->sha256(b, len b, nil, nil);
}

testPlain(t: ref T)
{
	(err, info) := dologin(t, 0, 0, Password);
	loggedin(t, "neither in CNSA mode (ChaCha20-Poly1305)", err, info);
}

testCNSABoth(t: ref T)
{
	(err, info) := dologin(t, 1, 1, Password);
	cnsaloggedin(t, "both in CNSA mode (AES-256-GCM, an ML-DSA-87 signer)", err, info);
}

# A client in CNSA mode takes a certificate from a CNSA signer's key
# alone, whatever mode the signer is in: it took one from an Ed25519
# signer, the suite being all it asked about.
testCNSAClient(t: ref T)
{
	(err, info) := dologin(t, 1, 0, Password);
	t.assert(info == nil, "a CNSA client gets nothing from an Ed25519 signer not in CNSA mode");
	t.assert(err != nil && contains(err, "ML-DSA-87"), "and says what it takes: " + err);
	(err, info) = dologin(t, 1, 0|Otherkey, Password);
	cnsaloggedin(t, "a CNSA client, an ML-DSA-87 signer not in CNSA mode", err, info);
}

# A signer in CNSA mode signs with a CNSA key or not at all: it signed
# with whatever /keydb/signerkey held.
testCNSASignerKey(t: ref T)
{
	(err, info) := dologin(t, 1, 1|Otherkey, Password);
	t.assert(info == nil, "a signer in CNSA mode with an Ed25519 key gives nothing");
	t.assert(err != nil && contains(err, "not CNSA's"), "and says its key is not CNSA's: " + err);
	(err, info) = dologin(t, 0, 1|Otherkey, Password);
	t.assert(info == nil, "to a client not in the mode either");
}

testCNSAServerRefuses(t: ref T)
{
	(err, info) := dologin(t, 0, 1, Password);
	t.assert(info == nil, "a signer in CNSA mode gives a client not in it nothing");
	t.assert(err != nil && contains(err, "CNSA mode"), "and says why: " + err);
}

testWrongPassword(t: ref T)
{
	(err, info) := dologin(t, 1, 1, "correct horse battery stapler");
	t.assert(info == nil, "a wrong password in CNSA mode gives nothing");
	t.assert(err != nil && contains(err, "incorrect"), "and says the secret is incorrect: " + err);
	(err, info) = dologin(t, 0, 0, "correct horse battery stapler");
	t.assert(info == nil, "a wrong password gives nothing");
	t.assert(err != nil && contains(err, "incorrect"), "and says the secret is incorrect: " + err);
}

# The throttle's refusal, the seconds left taken out.
Refusal: con "login refused: too many failed attempts";
throttled(err: string): int
{
	return err != nil && contains(err, Refusal);
}

refusalwords(err: string): string
{
	for(i := 0; i + 5 <= len err; i++)
		if(err[i:i+5] == "retry")
			return err[0:i];
	return err;
}

# n logins as user with a wrong password, each refused as a wrong
# password (not by the throttle).
wrongs(t: ref T, user: string, n: int, what: string)
{
	for(i := 0; i < n; i++){
		(err, info) := userlogin(t, user, 0, 0, Wrong);
		if(info != nil || err == nil || throttled(err)){
			t.fatal(sys->sprint("%s: wrong password %d of %d as %s: want it refused as wrong, got %q", what, i+1, n, user, err));
			return;
		}
	}
}

carolrefusal: string;	# testLockout's refusal, for testUnknownName

testLockout(t: ref T)
{
	wrongs(t, "carol", Maxfail, "to the threshold");
	(err, info) := userlogin(t, "carol", 0, 0, Password);
	t.assert(info == nil, "past the threshold the right password gives nothing");
	t.assert(throttled(err), "and is refused by the throttle: " + err);
	t.assert(contains(err, "retry in "), "saying when to retry: " + err);
	carolrefusal = err;
	(err, info) = userlogin(t, "carol", 1, 1, Wrong);
	t.assert(throttled(err), "a wrong password is refused the same while locked: " + err);

	# The cooldown run out (its end put in the past in logind's file):
	# the right password works again.
	if(expire(failkey("carol")) < 0)
		t.fatal(sys->sprint("can't end carol's cooldown in /keydb/loginfail: %r"));
	(err, info) = userlogin(t, "carol", 0, 0, Password);
	userloggedin(t, "carol", "the cooldown over", err, info);
}

testBelowThreshold(t: ref T)
{
	# Maxfail-1 wrong: the Maxfail-th attempt, the right password, works
	# and the next is not refused.
	wrongs(t, "dave", Maxfail-1, "below the threshold");
	(err, info) := userlogin(t, "dave", 0, 0, Password);
	userloggedin(t, "dave", sys->sprint("after %d wrong passwords", Maxfail-1), err, info);
	(err, info) = userlogin(t, "dave", 0, 0, Password);
	userloggedin(t, "dave", "the login after it", err, info);
}

testSuccessResets(t: ref T)
{
	# 5 wrong, a login that works, then Maxfail-1 wrong again and a
	# login that works: more than Maxfail attempts not proving the
	# password in all, so the count must have been cleared between.
	wrongs(t, "erin", 5, "before a login");
	(err, info) := userlogin(t, "erin", 0, 0, Password);
	userloggedin(t, "erin", "after 5 wrong passwords", err, info);
	wrongs(t, "erin", Maxfail-1, "after a login");
	(err, info) = userlogin(t, "erin", 0, 0, Password);
	userloggedin(t, "erin", "the count cleared by the login before", err, info);
}

testUnknownName(t: ref T)
{
	for(i := 0; i < Maxfail; i++){
		(err, info) := userlogin(t, "mallory", 0, 0, Password);
		if(info != nil || err == nil || throttled(err))
			t.fatal(sys->sprint("login %d of %d as a name with no account: want it refused, not by the throttle; got %q", i+1, Maxfail, err));
	}
	(err, info) := userlogin(t, "mallory", 0, 0, Password);
	t.assert(info == nil, "a name with no account, past the threshold, gives nothing");
	t.assert(throttled(err), "and is refused by the throttle: " + err);

	if(carolrefusal == nil)
		t.fatal("Lockout gave no refusal to compare with");
	t.assertseq(refusalwords(err), refusalwords(carolrefusal), "a name with no account refused in an account's words");
}

testUnknownLikeWrong(t: ref T)
{
	# Each AEAD: a real name with a wrong password, a name with no
	# account (either password) and an expired entry (the right
	# password) give the client the same words. frank, oscar, gwen:
	# none of them near the throttle.
	for(cnsa := 0; cnsa <= 1; cnsa++){
		mode := "not in CNSA mode";
		if(cnsa)
			mode = "in CNSA mode";
		(wrong, winfo) := userlogin(t, "frank", cnsa, cnsa, Wrong);
		t.assert(winfo == nil, mode + ": a wrong password gives nothing");
		t.assert(wrong != nil && contains(wrong, "incorrect"), mode + ": a wrong password is incorrect: " + wrong);
		(none, ninfo) := userlogin(t, "oscar", cnsa, cnsa, Wrong);
		t.assert(ninfo == nil, mode + ": a name with no account gives nothing");
		t.assertseq(none, wrong, mode + ": a name with no account answered as a wrong password");
		(none, ninfo) = userlogin(t, "oscar", cnsa, cnsa, Password);
		t.assertseq(none, wrong, mode + ": whatever password it is given");
		(exp, einfo) := userlogin(t, Expired, cnsa, cnsa, Password);
		t.assert(einfo == nil, mode + ": an expired entry gives nothing");
		t.assertseq(exp, wrong, mode + ": an expired entry answered as a wrong password");
	}
}

#
# login(6) as this test computes it, from the manual page and not
# through the Login module: the rogue clients and signers below are a
# second reading of the page, and tests/host/login/mkvectors.py's known
# answers (testVectors) a third.
#
Version: con 2;
Chacha: con 1;
Aesgcm: con 2;
Noncelen: con 32;

# RFC 3526's groups 14 and 15 (tests/host/login/mkgroups.py -c checks them)
P14: con
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"+
	"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"+
	"4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"+
	"98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"+
	"9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
	"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"+
	"3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF";

P15: con
	"FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"+
	"020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"+
	"4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"+
	"EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05"+
	"98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB"+
	"9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"+
	"E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"+
	"3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33"+
	"A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"+
	"ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864"+
	"D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2"+
	"08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

xgroup(gid: int): (ref IPint, int)
{
	case gid {
	14 =>
		return (IPint.strtoip(P14, 16), len P14/2);
	15 =>
		return (IPint.strtoip(P15, 16), len P15/2);
	}
	return (nil, 0);
}

xbe(x: ref IPint, n: int): array of byte
{
	b := x.iptobytes();
	while(len b > 0 && b[0] == byte 0)
		b = b[1:];
	a := array[n] of {* => byte 0};
	a[n - len b:] = b;
	return a;
}

xcat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

xhmac(suite: int, data, key: array of byte): array of byte
{
	if(suite == Aesgcm){
		d := array[Keyring->SHA384dlen] of byte;
		kr->hmac_sha384(data, len data, key, d, nil);
		return d;
	}
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

xexpand(suite: int, prk, info: array of byte, n: int): array of byte
{
	out := array[0] of byte;
	t := array[0] of byte;
	for(i := 1; len out < n; i++){
		t = xhmac(suite, xcat(xcat(t, info), array[] of {byte i}), prk);
		out = xcat(out, t);
	}
	return out[0:n];
}

xmask(suite, gid: int, name: string, pw, cnonce, snonce, x: array of byte): array of byte
{
	prk := xhmac(suite, pw, xcat(cnonce, snonce));
	info := xcat(array of byte "infernode login 2 mask", array[] of {byte 0, byte suite, byte gid});
	okm := xexpand(suite, prk, xcat(info, array of byte name), 44);
	out: array of byte;
	if(suite == Aesgcm)
		(out, nil) = kr->aesgcmencrypt(kr->aesgcmsetup(okm[0:32], okm[32:]), x, nil);
	else
		(out, nil) = kr->ccpolyencrypt(x, nil, okm[0:32], okm[32:]);
	return out;
}

xlen(a: array of byte): array of byte
{
	return xcat(array[] of {byte (len a>>8), byte len a}, a);
}

xkeys(suite: int, name: string, pw, hello, reply, share, z: array of byte): (array of byte, array of byte, array of byte)
{
	tr := array of byte "infernode login 2 transcript";
	tr = xcat(tr, xlen(array of byte name));
	tr = xcat(tr, xlen(hello));
	tr = xcat(tr, xlen(reply));
	tr = xcat(tr, xlen(share));
	th: array of byte;
	if(suite == Aesgcm){
		th = array[Keyring->SHA384dlen] of byte;
		kr->sha384(tr, len tr, th, nil);
	}else{
		th = array[Keyring->SHA256dlen] of byte;
		kr->sha256(tr, len tr, th, nil);
	}
	prk := xhmac(suite, xcat(z, pw), th);
	n := len th;
	return (xexpand(suite, prk, array of byte "infernode login 2 client proof", n),
		xexpand(suite, prk, array of byte "infernode login 2 signer proof", n),
		xexpand(suite, prk, array of byte "infernode login 2 session", n));
}

pwdigest(password: string): array of byte
{
	pw := array of byte password;
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pw, len pw, dig, nil);
	return dig;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
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

ramp(mul, add, n: int): array of byte
{
	a := array[n] of byte;
	for(i := 0; i < n; i++)
		a[i] = byte (mul*i + add);
	return a;
}

inrange(x, p: ref IPint): int
{
	return x.cmp(IPint.inttoip(1)) > 0 && x.cmp(p.sub(IPint.inttoip(1))) < 0;
}

# The key derivation against answers made by Python's cryptography from
# the manual page (tests/host/login/mkvectors.py).
testVectors(t: ref T)
{
	v := array[] of {
		(Chacha, 14, "bd4c6a604395623acb6a96ab8f1251e2",
			"520fa7458b35863304f1d3fa43ba580bbcc748d9bbaaaea7b84971e20480847a",
			"7dbbea4cbd2c0f67bc777e216e72670628e13d073da2312b0137f923c8965477",
			"bcf00399bd138a40459846efb60cfd9ef9bc671862ecb905765f1235a8f6e78e",
			"ffec534b5604a8dd5120f6bae645f899f11acb8641b4ce73c994758738ca0743"),
		(Aesgcm, 15, "81b1dd47513210dd77179b922e70bb8d",
			"9b364bbf94baea7f934f11df9307ae36f45742ab96485b926b3ee35eb0fe5893",
			"2c573fc8d0f407586482565a2e4940de452bf71209cedfafbf00da3e9e5a62b7c02697e01bf6de1888a4ab0658db73e0",
			"65ac26450890c9b4165511de31cf9a3c2c5b549af65c7b170cf268c16b301836b84d67433ef7fb4d5b1afdc7ed3465ac",
			"131162e9f9473dd2367c31fa64a11be21bb155b56e58aa440120c79adbdcac2236b06758f5d2207d5c647dc7af421a44"),
	};
	pw := pwdigest(Password);
	cnonce := ramp(1, 0, Noncelen);
	snonce := ramp(1, Noncelen, Noncelen);
	for(i := 0; i < len v; i++){
		(suite, gid, m16, msum, cproof, sproof, sk) := v[i];
		what := sys->sprint("suite %d", suite);
		(nil, n) := xgroup(gid);
		x := ramp(7, 1, n);
		m := xmask(suite, gid, "alice", pw, cnonce, snonce, x);
		t.assertseq(hex(m[0:16]), m16, what + ": the masked value's first bytes");
		sum := array[Keyring->SHA256dlen] of byte;
		kr->sha256(m, len m, sum, nil);
		t.assertseq(hex(sum), msum, what + ": the masked value");
		t.assert(eq(xmask(suite, gid, "alice", pw, cnonce, snonce, m), x), what + ": masked again it is the value");
		hello := xcat(array[] of {byte Version, byte suite}, cnonce);
		reply := xcat(xcat(array[] of {byte Version, byte suite, byte gid}, snonce), m);
		(c, s, k) := xkeys(suite, "alice", pw, hello, reply, ramp(5, 3, n), ramp(11, 2, n));
		t.assertseq(hex(c), cproof, what + ": the client's proof");
		t.assertseq(hex(s), sproof, what + ": the signer's proof");
		t.assertseq(hex(k), sk, what + ": the session's secret");
	}
}

# The groups: safe primes of the size said, 2 of order q, the top 64
# bits ones (mkgroups.py checks they are RFC 3526's and prime).
testGroups(t: ref T)
{
	one := IPint.inttoip(1);
	gids := array[] of {(14, 2048), (15, 3072)};
	for(i := 0; i < len gids; i++){
		(gid, bits) := gids[i];
		(p, n) := xgroup(gid);
		what := sys->sprint("group %d", gid);
		t.asserteq(p.bits(), bits, what + ": bits");
		t.asserteq(n*8, bits, what + ": bytes");
		q := p.shr(1);
		t.assert(IPint.inttoip(2).expmod(q, p).eq(one), what + ": 2 is of order q");
		t.assert(p.shr(bits-64).eq(one.shl(64).sub(one)), what + ": the top 64 bits are ones");
	}
}

#
# One logind on a loopback port; its address.
#
logind(t: ref T, cnsa: int): string
{
	addrc := chan of string;
	spawn serve(cnsa, addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("serve: " + <-addrc);
	return addr;
}

# A conversation with a signer as far as its reply.
Conv: adt {
	c:	ref Sys->Connection;
	name:	string;
	suite:	int;
	gid:	int;
	n:	int;
	p:	ref IPint;
	hello:	array of byte;
	reply:	array of byte;
};

# A read from a signer or a client that may never answer (the code
# before waited five minutes for a message that was not coming).
Readwait: con 10000;

getstr(fd: ref Sys->FD): (string, string)
{
	res := chan[1] of (string, string);
	spawn strreader(fd, res);
	tick := chan of int;
	spawn sleeper(tick, Readwait);
	alt {
	r := <-res =>
		return r;
	<-tick =>
		return (nil, "no answer");
	}
}

strreader(fd: ref Sys->FD, res: chan of (string, string))
{
	res <-= kr->getstring(fd);
}

getbytes(fd: ref Sys->FD): (array of byte, string)
{
	res := chan[1] of (array of byte, string);
	spawn bytesreader(fd, res);
	tick := chan of int;
	spawn sleeper(tick, Readwait);
	alt {
	r := <-res =>
		return r;
	<-tick =>
		return (nil, "no answer");
	}
}

bytesreader(fd: ref Sys->FD, res: chan of (array of byte, string))
{
	res <-= kr->getbytearray(fd);
}

rawdial(addr: string): (ref Sys->Connection, string)
{
	(ok, lc) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("dial: %r"));
	(err, c) := ssl->connect(lc.dfd);
	if(c == nil)
		return (nil, "push ssl: " + err);
	return (c, nil);
}

randombytes(n: int): array of byte
{
	return xbe(IPint.random(0, 8*n), n);
}

begin(addr, name: string, suite: int, hello: array of byte): (ref Conv, string)
{
	(c, err) := rawdial(addr);
	if(c == nil)
		return (nil, err);
	kr->putstring(c.dfd, name);
	(s, why) := getstr(c.dfd);
	if(why != nil)
		return (nil, "ack: " + why);
	if(s != name)
		return (nil, "ack: " + s);
	if(hello == nil)
		hello = xcat(array[] of {byte Version, byte suite}, randombytes(Noncelen));
	kr->putbytearray(c.dfd, hello, len hello);
	reply: array of byte;
	(reply, err) = getbytes(c.dfd);
	if(err != nil)
		return (nil, "reply: " + err);
	if(len reply < 3+Noncelen)
		return (nil, sys->sprint("reply of %d bytes", len reply));
	cv := ref Conv(c, name, suite, int reply[2], 0, nil, hello, reply);
	(cv.p, cv.n) = xgroup(cv.gid);
	if(cv.p == nil)
		return (nil, sys->sprint("reply names group %d", cv.gid));
	return (cv, nil);
}

# what the signer's masked value is under password
unmask(cv: ref Conv, password: string): ref IPint
{
	return IPint.bytestoip(xmask(cv.suite, cv.gid, cv.name, pwdigest(password), cv.hello[2:], cv.reply[3:3+Noncelen], cv.reply[3+Noncelen:]));
}

# The rest of a login, as login(6) has it, with password.
finish(cv: ref Conv, password: string): (string, ref Keyring->Authinfo)
{
	x := unmask(cv, password);
	if(!inrange(x, cv.p))
		return ("signer's value out of range", nil);
	r1 := IPint.random(0, 256).add(IPint.inttoip(2));
	y := xbe(IPint.inttoip(2).expmod(r1, cv.p), cv.n);
	z := xbe(x.expmod(r1.shl(1), cv.p), cv.n);
	(cproof, sproof, sk) := xkeys(cv.suite, cv.name, pwdigest(password), cv.hello, cv.reply, y, z);
	msg := xcat(y, cproof);
	kr->putbytearray(cv.c.dfd, msg, len msg);
	(proof, err) := getbytes(cv.c.dfd);
	if(err != nil)
		return ("signer's proof: " + err, nil);
	if(!eq(proof, sproof))
		return ("signer's proof is not the proof", nil);
	(secretin, secretout) := ssl->secrets(sk, 1);
	err = ssl->secret(cv.c, secretin, secretout);
	if(err != nil)
		return ("secrets: " + err, nil);
	if(sys->fprint(cv.c.cfd, "alg aes_256_gcm") < 0)
		return (sys->sprint("alg: %r"), nil);
	info := ref Keyring->Authinfo;
	s: string;
	(s, err) = getstr(cv.c.dfd);
	if(err != nil)
		return ("signer's key: " + err, nil);
	info.spk = kr->strtopk(s);
	(s, err) = getstr(cv.c.dfd);
	if(err != nil)
		return ("alpha: " + err, nil);
	info.alpha = IPint.b64toip(s);
	(s, err) = getstr(cv.c.dfd);
	if(err != nil)
		return ("p: " + err, nil);
	info.p = IPint.b64toip(s);
	info.mysk = kr->genSKfromPK(info.spk, cv.name);
	info.mypk = kr->sktopk(info.mysk);
	kr->putstring(cv.c.dfd, kr->pktostr(info.mypk));
	(s, err) = getstr(cv.c.dfd);
	if(err != nil)
		return ("certificate: " + err, nil);
	info.cert = kr->strtocert(s);
	return (nil, info);
}

# The exchange as the page has it, by a client that is not login(2).
testManual(t: ref T)
{
	sys->remove("/keydb/loginfail");
	(cv, err) := begin(logind(t, 0), User, Chacha, nil);
	if(cv == nil)
		t.fatal("ChaCha20: " + err);
	t.asserteq(int cv.reply[0], Version, "ChaCha20: the reply's version");
	t.asserteq(int cv.reply[1], Chacha, "ChaCha20: the reply's suite");
	t.asserteq(cv.gid, 14, "ChaCha20: group 14");
	t.asserteq(len cv.reply, 3+Noncelen+256, "ChaCha20: version, suite, group, nonce and a value of len(p) bytes: no tag");
	info: ref Keyring->Authinfo;
	(err, info) = finish(cv, Password);
	loggedin(t, "a client written from login(6), ChaCha20", err, info);
	if(info != nil && info.p != nil)
		t.asserteq(info.p.bits(), 2048, "the signer's own p came under the session's keys");

	(cv, err) = begin(logind(t, 1), User, Aesgcm, nil);
	if(cv == nil)
		t.fatal("AES-256-GCM: " + err);
	t.asserteq(cv.gid, 15, "AES-256-GCM: group 15 (3072 bits)");
	t.asserteq(len cv.reply, 3+Noncelen+384, "AES-256-GCM: the reply's length");
	cnsacv := cv;

	# a signer not in CNSA mode gives a client offering suite 2 no less
	(cv, err) = begin(logind(t, 0), User, Aesgcm, nil);
	if(cv == nil)
		t.fatal("AES-256-GCM, signer not in CNSA mode: " + err);
	t.asserteq(cv.gid, 15, "AES-256-GCM from a signer not in CNSA mode: still group 15");

	# the signer in CNSA mode has an ML-DSA-87 key (last: it may skip)
	(err, info) = finish(cnsacv, Password);
	if(err != nil)
		info = nil;
	cnsaloggedin(t, "a client written from login(6), AES-256-GCM", err, info);
}

# the count /keydb/loginfail has for name; 0 if none
counted(name: string): int
{
	fd := sys->open("/keydb/loginfail", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[64*1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	key := failkey(name);
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, fl) := sys->tokenize(hd lines, " ");
		if(nf == 4 && hd fl == key)
			return int hd tl fl;
	}
	return 0;
}

#
# The audit log's sink, /mnt/audit/log, served here: what logind(8)
# writes there.
#
auditlines: list of string;

auditsrv(f: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			rc <-= (nil, "permission denied");
	(nil, data, nil, wc) := <-f.write =>
		if(wc != nil){
			auditlines = string data :: auditlines;
			wc <-= (len data, nil);
		}
	}
}

audited(s: string): int
{
	for(l := auditlines; l != nil; l = tl l)
		if(contains(hd l, s))
			return 1;
	return 0;
}

#
# No password: a client that sends a value whose powers anybody knows.
# With 1 (or p+1), 0 or p-1 the secret was 1, 0 or one of two values
# whatever the signer's exponent, and the client had a certificate for
# any account.
#
testNoPassword(t: ref T)
{
	sys->remove("/keydb/loginfail");
	auditlines = nil;
	(p, n) := xgroup(14);
	one := IPint.inttoip(1);
	vals := array[] of {
		("0", IPint.inttoip(0), IPint.inttoip(0)),
		("1", one, one),
		("p-1", p.sub(one), one),
		("p", p, IPint.inttoip(0)),
		("p+1", p.add(one), one),
		("2^2048-1", one.shl(8*n).sub(one), one),
	};
	zeros := array[Keyring->SHA256dlen] of {* => byte 0};
	for(i := 0; i < len vals; i++){
		(what, v, secret) := vals[i];
		(cv, err) := begin(logind(t, 0), "judy", Chacha, nil);
		if(cv == nil)
			t.fatal(what + ": " + err);
		y := xbe(v, n);
		# the proof a client could make if the secret were what it wants
		(cproof, nil, nil) := xkeys(Chacha, "judy", zeros, cv.hello, cv.reply, y, xbe(secret, n));
		msg := xcat(y, cproof);
		kr->putbytearray(cv.c.dfd, msg, len msg);
		(b, e) := getbytes(cv.c.dfd);
		t.assert(b == nil, "a client sending " + what + " is sent nothing");
		t.assert(e != nil && contains(e, "bad Diffie-Hellman value"), "a client sending " + what + " is refused for its value: " + e);
	}
	t.asserteq(counted("judy"), len vals, "each is counted against the name and none cleared");
	t.assert(audited("logind authfail user=judy reason=badvalue"), "and recorded in the audit log");
	t.assert(!audited("authok"), "no certificate was recorded as issued");

	# a message that is no value and proof is refused, not left waiting
	(cv, err) := begin(logind(t, 0), "judy", Chacha, nil);
	if(cv == nil)
		t.fatal("short message: " + err);
	kr->putbytearray(cv.c.dfd, array of byte "!!!", 3);
	(b, e) := getbytes(cv.c.dfd);
	t.assert(b == nil && e != nil && contains(e, "bad Diffie-Hellman message"), "a message that is no value is refused: " + e);

	# a value in range, its exponent known, and no password: refused as
	# a wrong password is, with nothing made from the secret sent
	(cv, err) = begin(logind(t, 0), "judy", Chacha, nil);
	if(cv == nil)
		t.fatal("2: " + err);
	y := xbe(IPint.inttoip(2), n);
	(cproof, nil, nil) := xkeys(Chacha, "judy", zeros, cv.hello, cv.reply, y, xbe(one, n));
	msg := xcat(y, cproof);
	kr->putbytearray(cv.c.dfd, msg, len msg);
	(b, e) = getbytes(cv.c.dfd);
	t.assert(b == nil && e != nil && contains(e, "name or secret incorrect"), "a value in range and no password: " + e);
	t.assert(audited("logind authfail user=judy reason=secret"), "a proof that is not one is recorded");
	t.asserteq(counted("judy"), len vals+2, "all of them counted");

	# AES-256-GCM, a signer in CNSA mode
	(cv, err) = begin(logind(t, 1), "judy", Aesgcm, nil);
	if(cv == nil)
		t.fatal("CNSA: " + err);
	y = xbe(one, cv.n);
	(cproof, nil, nil) = xkeys(Aesgcm, "judy", zeros, cv.hello, cv.reply, y, y);
	msg = xcat(y, cproof);
	kr->putbytearray(cv.c.dfd, msg, len msg);
	(b, e) = getbytes(cv.c.dfd);
	t.assert(b == nil && e != nil && contains(e, "bad Diffie-Hellman value"), "CNSA mode: a client sending 1 is refused: " + e);
	sys->remove("/keydb/loginfail");
}

#
# One exchange gave anybody the signer's value sealed under the
# password: its tag said which guess was right.  Now the reply is the
# value under a keystream and nothing more, and every password unmasks
# it to something a signer could have sent: a number in 2..p-2, a
# square or not as a coin falls (2**r0 alone is always a square, which
# would rule out half the wrong guesses from each reply).
#
testOffline(t: ref T)
{
	sys->remove("/keydb/loginfail");
	words := array[] of {"password", "letmein", "hunter2", "correct horse", Password, "trustno1"};
	Right: con 4;
	one := IPint.inttoip(1);
	squares := array[len words] of {* => 0};
	N: con 20;
	for(i := 0; i < N; i++){
		if(i%8 == 0)
			sys->remove("/keydb/loginfail");
		(cv, err) := begin(logind(t, 0), "heidi", Chacha, nil);
		if(cv == nil)
			t.fatal(sys->sprint("connection %d: %s", i, err));
		if(len cv.reply != 3+Noncelen+cv.n)
			t.fatal(sys->sprint("the reply has %d bytes: more than the nonce and the value", len cv.reply));
		q := cv.p.shr(1);
		for(w := 0; w < len words; w++){
			x := unmask(cv, words[w]);
			if(!inrange(x, cv.p))
				t.fatal(sys->sprint("%q unmasks the reply to a number outside 2..p-2: a guess can be told wrong", words[w]));
			if(x.expmod(q, cv.p).eq(one))
				squares[w]++;
		}
		cv = nil;
	}
	for(w := 0; w < len words; w++){
		what := "a wrong password";
		if(w == Right)
			what = "the right password";
		t.assert(squares[w] > 0 && squares[w] < N,
			sys->sprint("%s unmasks %d replies to squares %d times: neither always nor never", what, N, squares[w]));
	}
	sys->remove("/keydb/loginfail");
}

# The same hello sent twice: the signer's nonce differs, and so does
# the keystream its value is under.
testReplay(t: ref T)
{
	sys->remove("/keydb/loginfail");
	hello := xcat(array[] of {byte Version, byte Chacha}, ramp(3, 9, Noncelen));
	(cv1, e1) := begin(logind(t, 0), "ivan", Chacha, hello);
	(cv2, e2) := begin(logind(t, 0), "ivan", Chacha, hello);
	if(cv1 == nil || cv2 == nil)
		t.fatal("replay: " + e1 + " " + e2);
	t.assert(!eq(cv1.reply[3:3+Noncelen], cv2.reply[3:3+Noncelen]), "the signer's nonce is fresh for each reply");
	zero := array[cv1.n] of {* => byte 0};
	pw := pwdigest(Password);
	k1 := xmask(Chacha, cv1.gid, "ivan", pw, hello[2:], cv1.reply[3:3+Noncelen], zero);
	k2 := xmask(Chacha, cv2.gid, "ivan", pw, hello[2:], cv2.reply[3:3+Noncelen], zero);
	t.assert(!eq(k1, k2), "one hello sent twice gets two keystreams");
	# and each reply is the signer's value under its own
	t.assert(inrange(unmask(cv1, Password), cv1.p) && inrange(unmask(cv2, Password), cv2.p), "each unmasks to a value in range");
	sys->remove("/keydb/loginfail");
}

# Names that are not one account name are refused before the ack, and
# nothing is counted for them.
testBadNames(t: ref T)
{
	sys->remove("/keydb/loginfail");
	auditlines = nil;
	long := "";
	for(i := 0; i < 300; i++)
		long[len long] = 'a';
	names := array[] of {
		array of byte "carol/.",
		array of byte "carol//",
		array of byte "./carol",
		array of byte "alice/../carol",
		array of byte "../../tmp/x",
		array of byte "carol\\x",
		array of byte ".",
		array of byte "..",
		array of byte "",
		array of byte long,
		array of byte "carol\tx",
		array of byte "carol\n",
		array of byte " carol",
		array of byte "carol ",
		array[] of {byte 'c', byte 16rFF, byte 16rFE},
	};
	for(i = 0; i < len names; i++){
		what := sys->sprint("%q", string names[i]);
		if(len names[i] > 64)
			what = sys->sprint("a name of %d bytes", len names[i]);
		(c, err) := rawdial(logind(t, 0));
		if(c == nil)
			t.fatal(what + ": " + err);
		kr->putbytearray(c.dfd, names[i], len names[i]);
		(s, why) := getstr(c.dfd);
		t.assert(s == nil && why != nil && contains(why, "bad user name"), what + " is refused, not acknowledged: " + s + why);
	}
	(ok, nil) := sys->stat("/keydb/loginfail");
	t.assert(ok < 0, "and no count is made for any of them");
	t.assert(audited("logind authfail user=carol/. reason=badname"), "each is recorded");
	t.assert(audited("logind authfail user=carol%09x reason=badname"), "as one value of its record, whatever is in it");
	(err, info) := userlogin(t, "carol/.", 0, 0, Password);
	t.assert(info == nil && err != nil && contains(err, "bad user name"), "login(2) refuses such a name itself: " + err);
}

#
# Signers of the test's own.
#
fakesigner(t: ref T, script: ref fn(c: ref Sys->Connection, arg: string): string, arg: string): (string, chan of string)
{
	addrc := chan of string;
	resc := chan[1] of string;
	spawn fakesrv(script, arg, addrc, resc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("fake signer: " + <-addrc);
	return (addr, resc);
}

fakesrv(script: ref fn(c: ref Sys->Connection, arg: string): string, arg: string, addrc, resc: chan of string)
{
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
	if(lok < 0){
		resc <-= "listen failed";
		return;
	}
	dfd := sys->open(nc.dir+"/data", Sys->ORDWR);
	(e, sc) := ssl->connect(dfd);
	if(sc == nil){
		resc <-= "ssl: " + e;
		return;
	}
	resc <-= script(sc, arg);
}

# name and ack, then the hello
fakehello(c: ref Sys->Connection): (string, array of byte)
{
	(name, err) := getstr(c.dfd);
	if(err != nil)
		return (nil, nil);
	kr->putstring(c.dfd, name);
	(hello, nil) := getbytes(c.dfd);
	return (name, hello);
}

# what the client does once it has a reply
aftermath(c: ref Sys->Connection): string
{
	(b, err) := getbytes(c.dfd);
	if(b != nil)
		return sys->sprint("the client sent %d bytes more", len b);
	return "the client sent nothing more: " + err;
}

# A signer that answers before version 2 did: with what logind said to
# a third message that was not its ivec.
oldsigner(c: ref Sys->Connection, nil: string): string
{
	fakehello(c);
	kr->puterror(c.dfd, "bad initialization vector length");
	return "refused the hello";
}

# A signer (or something between the client and one) with parameters
# of its own.
ownparams(c: ref Sys->Connection, arg: string): string
{
	(nil, hello) := fakehello(c);
	if(len hello != 2+Noncelen)
		return "no hello";
	suite := int hello[1];
	version := Version;
	gid := 14;
	n := 256;
	case arg {
	"group2" =>
		gid = 2;	# RFC 2409's 1024 bits
		n = 128;
	"group0" =>
		gid = 0;
	"p=2" =>
		n = 1;	# a modulus of its own: what a relay sent for p
	"version1" =>
		version = 1;
	"version3" =>
		version = 3;
	"suite" =>
		suite = 3 - suite;
	"group14" =>
		;
	}
	reply := xcat(xcat(array[] of {byte version, byte suite, byte gid}, randombytes(Noncelen)), randombytes(n));
	kr->putbytearray(c.dfd, reply, len reply);
	return aftermath(c);
}

# A signer that has the password and sends a value whose powers are
# known, or does the whole exchange and then sends something wrong.
pwsigner(c: ref Sys->Connection, arg: string): string
{
	(name, hello) := fakehello(c);
	if(len hello != 2+Noncelen)
		return "no hello";
	suite := int hello[1];
	gid := 14;
	if(suite == Aesgcm)
		gid = 15;
	(p, n) := xgroup(gid);
	one := IPint.inttoip(1);
	r0 := IPint.random(0, 256).add(IPint.inttoip(2));
	x := IPint.inttoip(2).expmod(r0, p);
	case arg {
	"0" =>
		x = IPint.inttoip(0);
	"1" =>
		x = one;
	"p-1" =>
		x = p.sub(one);
	}
	pw := pwdigest(Password);
	snonce := randombytes(Noncelen);
	reply := xcat(xcat(array[] of {byte Version, byte suite, byte gid}, snonce), xmask(suite, gid, name, pw, hello[2:], snonce, xbe(x, n)));
	kr->putbytearray(c.dfd, reply, len reply);
	(msg, err) := getbytes(c.dfd);
	if(msg == nil)
		return "the client sent nothing more: " + err;
	hlen := Keyring->SHA256dlen;
	if(suite == Aesgcm)
		hlen = Keyring->SHA384dlen;
	if(len msg != n+hlen)
		return "the client's message is not a value and a proof";
	y := IPint.bytestoip(msg[0:n]);
	z := xbe(y.expmod(r0.shl(1), p), n);
	(cproof, sproof, sk) := xkeys(suite, name, pw, hello, reply, msg[0:n], z);
	if(!eq(cproof, msg[n:]))
		return "the client's proof is not the proof";
	if(arg == "badproof"){
		sproof = randombytes(hlen);
		kr->putbytearray(c.dfd, sproof, len sproof);
		return aftermath(c);
	}
	kr->putbytearray(c.dfd, sproof, len sproof);
	(secretin, secretout) := ssl->secrets(sk, 0);
	if(ssl->secret(c, secretin, secretout) != nil || sys->fprint(c.cfd, "alg aes_256_gcm") < 0)
		return "can't seal";
	keyfile := "/keydb/signerkey";
	if(arg == "cnsakey" || arg == "cnsakey256")
		keyfile = cnsakey;
	info := kr->readauthinfo(keyfile);
	if(info == nil)
		return "no signer key";
	sp := info.p.iptob64();
	salpha := info.alpha.iptob64();
	case arg {
	"smallp" =>
		# a prime of 1024 bits (RFC 2409's second group has this top and tail)
		sp = one.shl(1024).sub(one.shl(960)).sub(one).iptob64();
	"evenp" =>
		sp = info.p.sub(one).iptob64();
	"alpha1" =>
		salpha = one.iptob64();
	"nokey" =>
		kr->putstring(c.dfd, "not a key");
		return aftermath(c);
	}
	kr->putstring(c.dfd, kr->pktostr(info.mypk));
	kr->putstring(c.dfd, salpha);
	kr->putstring(c.dfd, sp);
	(hispk, e2) := getstr(c.dfd);
	if(e2 != nil)
		return "the client sent no key: " + e2;
	b := array of byte hispk;
	case arg {
	"nocert" =>
		kr->putstring(c.dfd, "not a certificate");
	"othercert" =>
		# a certificate, but by a key that is not the one just sent
		other := kr->genSK("ed25519", "signer", 0);
		kr->putstring(c.dfd, kr->certtostr(kr->sign(other, 0, kr->sha256(b, len b, nil, nil), "sha256")));
	"cnsakey" =>
		kr->putstring(c.dfd, kr->certtostr(kr->sign(info.mysk, 0, kr->sha384(b, len b, nil, nil), "sha384")));
	* =>
		kr->putstring(c.dfd, kr->certtostr(kr->sign(info.mysk, 0, kr->sha256(b, len b, nil, nil), "sha256")));
	}
	return "sent a certificate";
}

# login(2), cnsamode as given, against a signer of the test's own
fakelogin(t: ref T, script: ref fn(c: ref Sys->Connection, arg: string): string, arg: string, cnsa: int): (string, ref Keyring->Authinfo, string)
{
	(addr, resc) := fakesigner(t, script, arg);
	res := chan of (string, ref Keyring->Authinfo);
	spawn client(User, cnsa, Password, addr, res);
	timeout := chan of int;
	spawn sleeper(timeout, 30000);
	alt {
	(err, info) := <-res =>
		tick := chan of int;
		spawn sleeper(tick, 5000);
		alt {
		what := <-resc =>
			return (err, info, what);
		<-tick =>
			return (err, info, "the fake signer is still waiting");
		}
	<-timeout =>
		t.fatal("login to a fake signer (" + arg + ") took more than 30 seconds");
	}
	return (nil, nil, nil);
}

#
# The client took alpha and p from whoever answered, with no floor: a
# relay sent p = 2 and was the signer.  The groups are now login(6)'s,
# named by number, and a client takes one on its list, of the size its
# mode asks.
#
testOwnParams(t: ref T)
{
	cases := array[] of {
		("group2", 0, "group 2"),
		("group0", 0, "group 0"),
		("p=2", 0, "length of its group"),
		("version1", 0, "not login version 2"),
		("version3", 0, "not login version 2"),
		("suite", 0, "suite not offered"),
		("suite", 1, "CNSA mode"),
		("group14", 1, "3072"),
	};
	for(i := 0; i < len cases; i++){
		(arg, cnsa, want) := cases[i];
		what := "a signer answering with " + arg;
		if(cnsa)
			what += " to a client in CNSA mode";
		(err, info, did) := fakelogin(t, ownparams, arg, cnsa);
		t.assert(info == nil, what + " gives no Authinfo");
		t.assert(err != nil && contains(err, want), what + " is refused saying why: " + err);
		t.assert(contains(did, "nothing more"), what + ": " + did);
	}
	# sanity: the same script with the group a client not in CNSA mode
	# takes gets its value and proof (and is no signer: random bytes)
	(err, info, did) := fakelogin(t, ownparams, "group14", 0);
	t.assert(info == nil && err != nil, "random bytes for a reply give no Authinfo: " + err);
	t.assert(contains(did, "bytes more"), "but the client went on: " + did);
}

# The client's own checks of what a signer with the password sends.
testSignerValues(t: ref T)
{
	vals := array[] of {"0", "1", "p-1"};
	for(i := 0; i < len vals; i++){
		what := "a signer whose value is " + vals[i];
		(err, info, did) := fakelogin(t, pwsigner, vals[i], 0);
		t.assert(info == nil && err != nil && contains(err, "name or secret incorrect"), what + " is refused: " + err);
		t.assert(contains(did, "nothing more"), what + ": " + did);
	}
	cases := array[] of {
		("badproof", "did not prove"),
		("smallp", "1024 bits"),
		("evenp", "bogus"),
		("alpha1", "bogus"),
		("nokey", "not a key"),
		("nocert", "not one"),
		("othercert", "does not verify"),
	};
	for(i = 0; i < len cases; i++){
		(arg, want) := cases[i];
		what := "a signer with the password, then " + arg;
		(err, info, nil) := fakelogin(t, pwsigner, arg, 0);
		t.assert(info == nil, what + " gives no Authinfo");
		t.assert(err != nil && contains(err, want), what + " is refused saying why: " + err);
	}
	# and the script is a signer when it does nothing wrong
	(err, info, nil) := fakelogin(t, pwsigner, "", 0);
	loggedin(t, "a signer written from login(6)", err, info);
	# a client in CNSA mode: refused for the Ed25519 key, and for a
	# CNSA key whose certificate is under SHA-256
	(err, info, nil) = fakelogin(t, pwsigner, "", 1);
	t.assert(info == nil && err != nil && contains(err, "ML-DSA-87"), "a CNSA client refuses the script's Ed25519 key: " + err);
	if(bigmsgs()){
		(err, info, nil) = fakelogin(t, pwsigner, "cnsakey", 1);
		loggedin(t, "a signer written from login(6), CNSA client", err, info);
		(err, info, nil) = fakelogin(t, pwsigner, "cnsakey256", 1);
		t.assert(info == nil && err != nil && contains(err, "SHA-384"), "a CNSA client refuses a certificate under SHA-256: " + err);
	}
}

#
# Something between the client and the real signer that changes one
# thing on the way: both ends' keys are made from all that was said,
# so nothing changed gets a certificate.
#
relay(c: ref Sys->Connection, arg: string): string
{
	(sv, err) := rawdial(relayto);
	if(sv == nil)
		return "relay: " + err;
	(name, e1) := getstr(c.dfd);
	if(e1 != nil)
		return "relay: no name";
	kr->putstring(sv.dfd, name);
	(ack, nil) := getstr(sv.dfd);
	kr->putstring(c.dfd, ack);
	(hello, nil) := getbytes(c.dfd);
	if(arg == "cnonce")
		hello[5] ^= byte 1;
	kr->putbytearray(sv.dfd, hello, len hello);
	(reply, e2) := getbytes(sv.dfd);
	if(reply == nil)
		return "relay: no reply: " + e2;
	case arg {
	"snonce" =>
		reply[7] ^= byte 1;
	"value" =>
		reply[len reply-1] ^= byte 1;
	"group" =>
		reply[2] = byte 15;
	}
	kr->putbytearray(c.dfd, reply, len reply);
	(msg, e3) := getbytes(c.dfd);
	if(msg == nil)
		return "the client sent nothing more: " + e3;
	if(arg == "share"){
		# a value of the relay's own, whose exponent it knows
		(p, n) := xgroup(int reply[2]);
		msg[0:] = xbe(IPint.inttoip(2).expmod(IPint.inttoip(5), p), n);
	}
	kr->putbytearray(sv.dfd, msg, len msg);
	(proof, e4) := getbytes(sv.dfd);
	if(proof == nil){
		kr->puterror(c.dfd, e4);
		return "the signer refused: " + e4;
	}
	kr->putbytearray(c.dfd, proof, len proof);
	return "the signer sent its proof";
}

relayto: string;

testRelay(t: ref T)
{
	sys->remove("/keydb/loginfail");
	cases := array[] of {"cnonce", "snonce", "value", "group", "share"};
	for(i := 0; i < len cases; i++){
		relayto = logind(t, 0);
		what := "a relay changing the " + cases[i];
		(err, info, did) := fakelogin(t, relay, cases[i], 0);
		t.assert(info == nil && err != nil, what + " gets the client no Authinfo: " + err);
		t.assert(!contains(did, "sent its proof"), what + ": " + did);
	}
	t.assert(!audited("authok user=alice"), "and the signer issued nothing");
	sys->remove("/keydb/loginfail");
}

# Before version 2 the third message was an ivec of 32 or 44 bytes and
# the signer answered with its value sealed under the password.  Neither
# end goes back to that, and each says why.
testOldExchange(t: ref T)
{
	sys->remove("/keydb/loginfail");
	lens := array[] of {32, 44};
	for(i := 0; i < len lens; i++){
		(c, err) := rawdial(logind(t, 0));
		if(c == nil)
			t.fatal("old client: " + err);
		kr->putstring(c.dfd, "ken");
		(s, why) := getstr(c.dfd);
		if(s != "ken")
			t.fatal("old client: ack: " + why);
		ivec := array[lens[i]] of {* => byte 7};
		kr->putbytearray(c.dfd, ivec, len ivec);
		(ct, e) := getbytes(c.dfd);
		what := sys->sprint("a client of the old exchange (an ivec of %d bytes)", lens[i]);
		t.assert(ct == nil, what + " is sent nothing sealed under the password");
		t.assert(e != nil && contains(e, "login version 2"), what + " is told the signer's version: " + e);
	}
	t.asserteq(counted("ken"), 0, "and is not counted: no password was tried");

	(err, info, nil) := fakelogin(t, oldsigner, nil, 0);
	t.assert(info == nil, "a signer of the old exchange gives login(2) nothing");
	t.assert(err != nil && contains(err, "old login exchange"), "and login(2) says which exchange it speaks: " + err);
}

# The signer's own name is not an account's: its certificate is the
# one in the signer's key file, which keysrv(4) shows.
testSignerName(t: ref T)
{
	sys->remove("/keydb/loginfail");
	(wrong, nil) := userlogin(t, "frank", 0, 0, Wrong);
	(err, info) := userlogin(t, "signer", 0, 0, Password);
	t.assert(info == nil, "an account with the signer's name gets no certificate");
	t.assertseq(err, wrong, "and is answered as a wrong password");
	sys->remove("/keydb/loginfail");
}

# A certificate issued and a wrong password are in the audit log, the
# name as one value.
testAudit(t: ref T)
{
	sys->remove("/keydb/loginfail");
	auditlines = nil;
	(err, info) := userlogin(t, User, 0, 0, Password);
	loggedin(t, "for the audit log", err, info);
	t.assert(audited("logind authok user=alice exp=0"), "a certificate issued is recorded");
	auditlines = nil;
	(err, info) = userlogin(t, User, 0, 0, Wrong);
	t.assert(info == nil, "a wrong password");
	t.assert(audited("logind authfail user=alice reason=secret"), "a wrong password is recorded");
	t.assert(!audited("authok"), "and nothing as issued");
	auditlines = nil;
	(err, info) = userlogin(t, "eve x=y", 0, 0, Password);
	t.assert(audited("logind authfail user=eve%20x%3Dy reason=unusable"), "a name with a blank and an = is one value of its record");
	sys->remove("/keydb/loginfail");
}

failkey(name: string): string
{
	b := array of byte name;
	d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(b, len b, d, nil);
	h := "";
	for(i := 0; i < len d; i++)
		h += sys->sprint("%.2ux", int d[i]);
	return h;
}

# key's cooldown in logind's file made to end in the past.
expire(key: string): int
{
	f := "/keydb/loginfail";
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return -1;
	buf := array[64*1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	out := "";
	found := 0;
	for(; lines != nil; lines = tl lines){
		(nf, fl) := sys->tokenize(hd lines, " ");
		if(nf == 4 && hd fl == key){
			out += sys->sprint("%s %s %s 1\n", hd fl, hd tl fl, hd tl tl fl);
			found = 1;
		}else
			out += hd lines + "\n";
	}
	if(!found){
		sys->werrstr("no count for the name");
		return -1;
	}
	return writefile(f, array of byte out);
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	login = load Login Login->PATH;
	ssl = load SSL SSL->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	if(login == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Login->PATH);
		raise "fail:cannot load login";
	}
	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	err := setup();
	if(err != nil){
		sys->fprint(sys->fildes(2), "login_test: %s\n", err);
		raise "fail:setup";
	}

	run("Login/Plain", testPlain);
	run("Login/CNSABoth", testCNSABoth);
	run("Login/CNSAClient", testCNSAClient);
	run("Login/CNSASignerKey", testCNSASignerKey);
	run("Login/CNSAServerRefuses", testCNSAServerRefuses);
	run("Login/WrongPassword", testWrongPassword);
	run("Login/Lockout", testLockout);
	run("Login/BelowThreshold", testBelowThreshold);
	run("Login/SuccessResets", testSuccessResets);
	run("Login/UnknownName", testUnknownName);
	run("Login/UnknownLikeWrong", testUnknownLikeWrong);
	run("Login/Vectors", testVectors);
	run("Login/Groups", testGroups);
	run("Login/Manual", testManual);
	run("Login/NoPassword", testNoPassword);
	run("Login/Offline", testOffline);
	run("Login/Replay", testReplay);
	run("Login/BadNames", testBadNames);
	run("Login/OwnParams", testOwnParams);
	run("Login/SignerValues", testSignerValues);
	run("Login/Relay", testRelay);
	run("Login/OldExchange", testOldExchange);
	run("Login/SignerName", testSignerName);
	run("Login/Audit", testAudit);

	rmtree(testdir);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
