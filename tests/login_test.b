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

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

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
Expired: con "bob";	# an entry whose expire file says expired
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
	   mkdir(d+"/mnt") < 0 || mkdir(d+"/mnt/keys") < 0 || mkdir(d+"/mnt/keys/"+User) < 0 ||
	   mkdir(d+"/mnt/keys/"+Expired) < 0)
		return sys->sprint("can't make %s: %r", d);
	pw := array of byte Password;
	dig := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pw, len pw, dig, nil);
	if(writefile(d+"/mnt/keys/"+User+"/secret", dig) < 0 ||
	   writefile(d+"/mnt/keys/"+User+"/expire", array of byte "never") < 0 ||
	   writefile(d+"/mnt/keys/"+Expired+"/secret", dig) < 0 ||
	   writefile(d+"/mnt/keys/"+Expired+"/expire", array of byte "expired") < 0)
		return sys->sprint("can't write the user's entry: %r");
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
	return dologinas(t, User, clientcnsa, servercnsa, password);
}

dologinas(t: ref T, user: string, clientcnsa, servercnsa: int, password: string): (string, ref Keyring->Authinfo)
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
	t.assertnil(err, what + ": login");
	if(info == nil){
		t.error(what + ": no Authinfo");
		return;
	}
	t.assert(info.cert != nil, what + ": a certificate");
	t.assert(info.mypk != nil && info.mypk.owner == User, what + ": a key for " + User);
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

#
# Offline guessing. Someone who knows no password connects, names a
# user and takes whatever the signer sends before the client has
# proved anything; then, off line, tries passwords against it. The
# signer must have given nothing a guess can be checked against: the
# old protocol (login(6) before PAK) sent the DH value under an AEAD
# keyed by the password, whose tag tells a right guess from a wrong.
#
Guesses := array[] of {
	"password", "123456", "letmein", "alice", "correct horse battery stapler",
	Password, "hunter2",
};

# The old protocol's opening, as a client that knows no password sends
# it: name, IV (32 bytes: ChaCha20-Poly1305), then whatever comes back.
probe(addr: string, res: chan of (array of byte, array of byte, array of byte, string))
{
	ssl := load SSL SSL->PATH;
	(ok, lc) := sys->dial(addr, nil);
	if(ok < 0){
		res <-= (nil, nil, nil, sys->sprint("dial: %r"));
		return;
	}
	(err, c) := ssl->connect(lc.dfd);
	if(c == nil){
		res <-= (nil, nil, nil, "ssl: " + err);
		return;
	}
	kr->putstring(c.dfd, User);
	(nil, why) := kr->getstring(c.dfd);
	if(why != nil){
		res <-= (nil, nil, nil, "name refused: " + why);
		return;
	}
	ivec := array[32] of {* => byte 16r5a};
	kr->putbytearray(c.dfd, ivec, len ivec);
	(ct, e1) := kr->getbytearray(c.dfd);
	if(e1 != nil){
		res <-= (nil, nil, nil, "no ciphertext: " + e1);
		return;
	}
	(tag, e2) := kr->getbytearray(c.dfd);
	if(e2 != nil){
		res <-= (nil, nil, nil, "no tag: " + e2);
		return;
	}
	res <-= (ivec, ct, tag, nil);
}

# HKDF-SHA-256 as the old protocol keyed ChaCha20-Poly1305
oldkey(ikm, salt: array of byte): array of byte
{
	prk := array[Keyring->SHA256dlen] of byte;
	t := array[Keyring->SHA256dlen] of byte;
	inf := array of byte "infernode login aead";
	ex := array[len inf + 1] of byte;
	ex[0:] = inf;
	ex[len inf] = byte 1;
	kr->hmac_sha256(ikm, len ikm, salt, prk, nil);
	kr->hmac_sha256(ex, len ex, prk, t, nil);
	return t[0:32];
}

testNoOfflineGuessing(t: ref T)
{
	addrc := chan of string;
	spawn serve(0, addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("serve: " + <-addrc);
	res := chan of (array of byte, array of byte, array of byte, string);
	spawn probe(addr, res);
	timeout := chan of int;
	spawn sleeper(timeout, 30000);
	ivec, ct, tag: array of byte;
	why: string;
	alt {
	(ivec, ct, tag, why) = <-res =>
		;
	<-timeout =>
		t.fatal("probe took more than 30 seconds");
	}
	if(why != nil){
		t.log("the signer gave an unauthenticated client nothing to guess against: " + why);
		return;
	}
	for(i := 0; i < len Guesses; i++){
		pw := array of byte Guesses[i];
		dig := array[Keyring->SHA256dlen] of byte;
		kr->sha256(pw, len pw, dig, nil);
		if(kr->ccpolydecrypt(ct, nil, tag, oldkey(dig, ivec[0:20]), ivec[20:]) != nil){
			t.error(sys->sprint("password recovered off line from one unauthenticated probe, guess %d: %q", i+1, Guesses[i]));
			return;
		}
	}
	t.error("the signer answered an unauthenticated client with a ciphertext (no guess here matched)");
}

# A name with no entry is refused as a wrong password is, the client
# told nothing more.
testUnknownUser(t: ref T)
{
	(err, info) := dologinas(t, "mallory", 0, 0, Password);
	t.assert(info == nil, "a name with no entry gives nothing");
	(werr, nil) := dologin(t, 0, 0, "not the password");
	t.assertseq(err, werr, "and the same words as a wrong password");
}

# An expired entry: with the password, the signer says why; without
# it, a wrong password, as for any name.
testExpired(t: ref T)
{
	(err, info) := dologinas(t, Expired, 0, 0, Password);
	t.assert(info == nil, "an expired entry gives no certificate");
	t.assert(err != nil && contains(err, "expired"), "and, the password proved, says so: " + err);
	(err, info) = dologinas(t, Expired, 0, 0, "not the password");
	t.assert(info == nil && err != nil && contains(err, "incorrect"), "without the password, it is a wrong password: " + err);
}

# RFC 5114's 2048-bit p, the group loginpak(2) works in
P: con "87A8E61DB4B6663CFFBBD19C651959998CEEF608660DD0F25D2CEED4"+
	"435E3B00E00DF8F1D61957D4FAF7DF4561B2AA3016C3D91134096FAA3BF4296D"+
	"830E9A7C209E0C6497517ABD5A8A9D306BCF67ED91F9E6725B4758C022E0B1EF"+
	"4275BF7B6C5BFC11D45F9088B941F54EB1E59BB8BC39A0BF12307F5C4FDB70C5"+
	"81B23F76B63ACAE1CAA6B7902D52526735488A0EF13C6D9A51BFA4AB3AD83477"+
	"96524D8EF6A167B5A41825D967E144E5140564251CCACB83E6B486F6B3CA3F79"+
	"71506026C0B857F689962856DED4010ABD0BE621C3A3960A54E710C375F26375"+
	"D7014103A4B54330C198AF126116D2276E11715F693877FAD7EF09CADB094AE9"+
	"1E1A1597";

# The new protocol's opening with the given m; the error the signer
# answers with, or nil if it sent mu, ct and k.
pakprobe(addr, hexm: string, res: chan of string)
{
	ssl := load SSL SSL->PATH;
	(ok, lc) := sys->dial(addr, nil);
	if(ok < 0){
		res <-= sys->sprint("dial: %r");
		return;
	}
	(err, c) := ssl->connect(lc.dfd);
	if(c == nil){
		res <-= "ssl: " + err;
		return;
	}
	kr->putstring(c.dfd, "inflogin2 mlkem768");
	(nil, why) := kr->getstring(c.dfd);
	if(why != nil){
		res <-= "version refused: " + why;
		return;
	}
	(ek, nil) := kr->mlkem768_keygen();
	kr->putstring(c.dfd, User);
	kr->putstring(c.dfd, hexm);
	kr->putbytearray(c.dfd, ek, len ek);
	(nil, e1) := kr->getstring(c.dfd);
	if(e1 != nil){
		res <-= e1;
		return;
	}
	res <-= nil;
}

# m that would take sigma out of the group (0, p: sigma 0 and k a
# function of the password alone; p-1, of order 2: sigma 1 or p-1)
# is refused before the signer sends anything that depends on the
# password. A random element is answered.
testDegenerateM(t: ref T)
{
	p := IPint.strtoip(P, 16);
	one := IPint.inttoip(1);
	bad := array[] of {
		("0", IPint.inttoip(0)),
		("1", one),
		("p", p),
		("p-1", p.sub(one)),
		("p+1", p.add(one)),
	};
	for(i := 0; i < len bad; i++){
		(what, m) := bad[i];
		addrc := chan of string;
		spawn serve(0, addrc);
		addr := <-addrc;
		if(addr == nil)
			t.fatal("serve: " + <-addrc);
		res := chan of string;
		spawn pakprobe(addr, m.iptob64(), res);
		err := <-res;
		t.assert(err != nil && contains(err, "not in the group"), "m = " + what + " refused: " + err);
	}
	# g**5 mod p, an element of the subgroup: answered with mu, ct, k
	g := IPint.strtoip("3FB32C9B73134D0B2E77506660EDBD484CA7B18F21EF205407F4793A"+
		"1A0BA12510DBC15077BE463FFF4FED4AAC0BB555BE3A6C1B0C6B47B1BC3773BF"+
		"7E8C6F62901228F8C28CBB18A55AE31341000A650196F931C77A57F2DDF463E5"+
		"E9EC144B777DE62AAAB8A8628AC376D282D6ED3864E67982428EBC831D14348F"+
		"6F2F9193B5045AF2767164E1DFC967C1FB3F2E55A4BD1BFFE83B9C80D052B985"+
		"D182EA0ADB2A3B7313D3FE14C8484B1E052588B9B7D2BBD2DF016199ECD06E15"+
		"57CD0915B3353BBB64E0EC377FD028370DF92B52C7891428CDC67EB6184B523D"+
		"1DB246C32F63078490F00EF8D647D148D47954515E2327CFEF98C582664B4C0F"+
		"6CC41659", 16);
	addrc := chan of string;
	spawn serve(0, addrc);
	addr := <-addrc;
	if(addr == nil)
		t.fatal("serve: " + <-addrc);
	res := chan of string;
	spawn pakprobe(addr, g.expmod(IPint.inttoip(5), p).iptob64(), res);
	err := <-res;
	t.assertnil(err, "an element of the group answered");
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
	run("Login/NoOfflineGuessing", testNoOfflineGuessing);
	run("Login/UnknownUser", testUnknownUser);
	run("Login/Expired", testExpired);
	run("Login/DegenerateM", testDegenerateM);

	rmtree(testdir);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
