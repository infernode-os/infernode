implement LoginTest;

#
# login(2) against a real auth/logind over loopback TCP: the client and
# the signer each in an environment of their own, so each can be in CNSA
# mode (/env/cnsamode) or not. In CNSA mode the client takes AES-256-GCM
# with HKDF-SHA-384 and says so by its IV's length; a signer in CNSA mode
# refuses ChaCha20-Poly1305. The signer's files are made here, in a name
# space of the test's own: /keydb/signerkey and /mnt/keys/<user>/secret
# (the password's SHA-256) and expire, as keyfs(4) serves them.
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

include "security.m";
	login: Login;

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
Users := array[] of {User, "carol", "dave", "erin", "frank", "gwen"};
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
	d := sys->sprint("/tmp/logintest.%d.%d", sys->pctl(0, nil), sys->millisec());
	testdir = d;
	if(mkdir(d) < 0 || mkdir(d+"/root") < 0 || mkdir(d+"/root/keydb") < 0 ||
	   mkdir(d+"/mnt") < 0 || mkdir(d+"/mnt/keys") < 0)
		return sys->sprint("can't make %s: %r", d);
	pw := array of byte Password;
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pw, len pw, dig, nil);
	for(i := 0; i < len Users; i++){
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

	csk := load Command "/dis/auth/createsignerkey.dis";
	if(csk == nil)
		return sys->sprint("can't load createsignerkey: %r");
	setcnsa(0);
	{
		csk->init(nil, "createsignerkey" :: "-a" :: "ed25519" :: "-b" :: "1024" :: "-f" :: "/keydb/signerkey" :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey: " + e;
	}
	(ok, nil) := sys->stat("/keydb/signerkey");
	if(ok < 0)
		return sys->sprint("no signer key made: %r");
	return nil;
}

#
# One logind, in an environment of its own with cnsamode as given, on
# a loopback port; its address is sent on addrc, or nil and why.
#
serve(cnsa: int, addrc: chan of string)
{
	sys->pctl(Sys->FORKENV|Sys->NEWPGRP, nil);
	setcnsa(cnsa);
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
	loggedin(t, "both in CNSA mode (AES-256-GCM)", err, info);
}

testCNSAClient(t: ref T)
{
	(err, info) := dologin(t, 1, 0, Password);
	loggedin(t, "a CNSA client, a signer not in CNSA mode", err, info);
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
	# A real name with a wrong password, a name with no account and an
	# expired entry with the right password give the client the same
	# words; the first two in each AEAD. frank, oscar, gwen: none of
	# them near the throttle. Each login is seconds (the client's
	# ReallyRandom), so no more of them than that.
	for(cnsa := 0; cnsa <= 1; cnsa++){
		mode := "not in CNSA mode";
		if(cnsa)
			mode = "in CNSA mode";
		(wrong, winfo) := userlogin(t, "frank", cnsa, cnsa, Wrong);
		t.assert(winfo == nil, mode + ": a wrong password gives nothing");
		t.assert(wrong != nil && contains(wrong, "incorrect"), mode + ": a wrong password is incorrect: " + wrong);
		(none, ninfo) := userlogin(t, "oscar", cnsa, cnsa, Password);
		t.assert(ninfo == nil, mode + ": a name with no account gives nothing");
		t.assertseq(none, wrong, mode + ": a name with no account answered as a wrong password");
		if(!cnsa){
			(exp, einfo) := userlogin(t, Expired, cnsa, cnsa, Password);
			t.assert(einfo == nil, mode + ": an expired entry gives nothing");
			t.assertseq(exp, wrong, mode + ": an expired entry answered as a wrong password");
		}
	}
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
	run("Login/CNSAServerRefuses", testCNSAServerRefuses);
	run("Login/WrongPassword", testWrongPassword);
	run("Login/Lockout", testLockout);
	run("Login/BelowThreshold", testBelowThreshold);
	run("Login/SuccessResets", testSuccessResets);
	run("Login/UnknownName", testUnknownName);
	run("Login/UnknownLikeWrong", testUnknownLikeWrong);

	rmtree(testdir);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
