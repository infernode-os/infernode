implement CnsaModeTest;

#
# CNSA 2.0 mode (/env/cnsamode) is a rule for the keys made and taken in
# it, not a default (docs/compliance/CNSA-2.0.md): ML-DSA-87 for
# signatures, SHA-384 or SHA-512 under them, a Diffie-Hellman modulus
# of 3072 bits or more.
#
# The mode chose only what a program made when it was asked for
# nothing: in it, createsignerkey -a rsa -b 512 made a 512-bit RSA
# signer, -a ed25519 -c and -c -a ed25519 made different keys, the key
# file's modulus was 2048 bits, mkauthinfo signed with whatever key it
# was given, and signer(8) made and certified keys of any algorithm.
# Each now asks login(2)'s cnsakey, cnsaalg and cnsahash.  (logind and
# the login client are in login_test.b.)
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "security.m";
	login: Login;
include "testing.m";
	testing: Testing;
	T: import testing;

CnsaModeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/cnsa_mode_test.b";

passed := 0;
failed := 0;
skipped := 0;

dir: string;

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

# A command in an environment of its own, cnsamode as given, its
# complaints kept off the console: nil if it ended well, or how it ended.
cmd(cnsa: int, args: list of string): string
{
	c := chan of string;
	spawn cmdproc(cnsa, args, c);
	return <-c;
}

cmdproc(cnsa: int, args: list of string, c: chan of string)
{
	sys->pctl(Sys->FORKENV|Sys->FORKNS|Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	setcnsa(cnsa);
	# mkauthinfo and createsignerkey say why on the console
	sys->bind("/dev/null", "/dev/cons", Sys->MREPL);
	null := sys->open("/dev/null", Sys->OWRITE);
	if(null != nil)
		sys->dup(null.fd, 2);
	m := load Command "/dis/auth/" + hd args + ".dis";
	if(m == nil){
		c <-= sys->sprint("can't load %s: %r", hd args);
		return;
	}
	{
		m->init(nil, args);
	} exception e {
	"*" =>
		c <-= e;
		return;
	}
	c <-= nil;
}

exists(f: string): int
{
	(ok, nil) := sys->stat(f);
	return ok >= 0;
}

refused(t: ref T, what: string, cnsa: int, file: string, args: list of string)
{
	sys->remove(file);
	r := cmd(cnsa, args);
	t.assert(r != nil, what + " is refused");
	t.assert(!exists(file), what + " writes no key file");
}

testCreatesignerkey(t: ref T)
{
	f := dir + "/sk";
	# the mode by /env/cnsamode: an algorithm or a size given is refused
	refused(t, "cnsamode, -a rsa -b 2048", 1, f, "createsignerkey" :: "-a" :: "rsa" :: "-b" :: "2048" :: "-f" :: f :: "signer" :: nil);
	refused(t, "cnsamode, -a ed25519", 1, f, "createsignerkey" :: "-a" :: "ed25519" :: "-f" :: f :: "signer" :: nil);
	refused(t, "cnsamode, -a mldsa65", 1, f, "createsignerkey" :: "-a" :: "mldsa65" :: "-f" :: f :: "signer" :: nil);
	refused(t, "cnsamode, -a slhdsa256s", 1, f, "createsignerkey" :: "-a" :: "slhdsa256s" :: "-f" :: f :: "signer" :: nil);
	refused(t, "cnsamode, -b 4096", 1, f, "createsignerkey" :: "-b" :: "4096" :: "-f" :: f :: "signer" :: nil);
	# the mode by -c, before or after the algorithm
	refused(t, "-c -a ed25519", 0, f, "createsignerkey" :: "-c" :: "-a" :: "ed25519" :: "-f" :: f :: "signer" :: nil);
	refused(t, "-a ed25519 -c", 0, f, "createsignerkey" :: "-a" :: "ed25519" :: "-c" :: "-f" :: f :: "signer" :: nil);
	refused(t, "-a rsa -b 3072 -c", 0, f, "createsignerkey" :: "-a" :: "rsa" :: "-b" :: "3072" :: "-c" :: "-f" :: f :: "signer" :: nil);

	# what the mode makes: ML-DSA-87, SHA-384, RFC 3526's 3072-bit group
	cases := array[] of {
		(1, "createsignerkey" :: "-f" :: f :: "signer" :: nil, "cnsamode"),
		(1, "createsignerkey" :: "-a" :: "mldsa87" :: "-f" :: f :: "signer" :: nil, "cnsamode, -a mldsa87"),
		(0, "createsignerkey" :: "-c" :: "-f" :: f :: "signer" :: nil, "-c"),
	};
	for(i := 0; i < len cases; i++){
		(cnsa, args, what) := cases[i];
		sys->remove(f);
		t.assertnil(cmd(cnsa, args), what + ": a key is made");
		info := kr->readauthinfo(f);
		if(info == nil){
			t.error(what + ": no key file");
			continue;
		}
		t.assertseq(info.mysk.sa.name, "mldsa87", what + ": the algorithm");
		t.assertseq(info.cert.ha, "sha384", what + ": the certificate's hash");
		t.asserteq(info.p.bits(), 3072, what + ": the modulus's bits");
		(p, nil) := login->group(15);
		t.assert(info.p.eq(p), what + ": the modulus is RFC 3526's group 15");
		t.assertnil(login->cnsakey(info), what + ": the key file is CNSA's");
	}

	# outside the mode: as before, and the floor under a modulus
	sys->remove(f);
	t.assertnil(cmd(0, "createsignerkey" :: "-f" :: f :: "signer" :: nil), "not in the mode: a key is made");
	info := kr->readauthinfo(f);
	if(info != nil){
		t.assertseq(info.mysk.sa.name, "ed25519", "not in the mode: Ed25519");
		t.asserteq(info.p.bits(), 2048, "not in the mode: 2048 bits");
		t.assert(login->cnsakey(info) != nil, "and that key file is not CNSA's");
	}else
		t.error("not in the mode: no key file");
	refused(t, "-a rsa -b 512", 0, f, "createsignerkey" :: "-a" :: "rsa" :: "-b" :: "512" :: "-f" :: f :: "signer" :: nil);
	refused(t, "-a rsa -b 32", 0, f, "createsignerkey" :: "-a" :: "rsa" :: "-b" :: "32" :: "-f" :: f :: "signer" :: nil);
	refused(t, "-a ed25519 -b 2048 (a size for a key that has one)", 0, f, "createsignerkey" :: "-a" :: "ed25519" :: "-b" :: "2048" :: "-f" :: f :: "signer" :: nil);
}

testMkauthinfo(t: ref T)
{
	ed := dir + "/sk.ed";
	pq := dir + "/sk.pq";
	out := dir + "/ai";
	t.assertnil(cmd(0, "createsignerkey" :: "-f" :: ed :: "signer" :: nil), "an Ed25519 signer");
	t.assertnil(cmd(0, "createsignerkey" :: "-c" :: "-f" :: pq :: "signer" :: nil), "an ML-DSA-87 signer");

	refused(t, "mkauthinfo in the mode with an Ed25519 signer", 1, out, "mkauthinfo" :: "-k" :: "key=" + ed :: "alice" :: out :: nil);

	sys->remove(out);
	t.assertnil(cmd(1, "mkauthinfo" :: "-k" :: "key=" + pq :: "alice" :: out :: nil), "mkauthinfo in the mode with a CNSA signer");
	info := kr->readauthinfo(out);
	if(info != nil){
		t.assertnil(login->cnsakey(info), "the key made is CNSA's");
		t.assertseq(info.mypk.owner, "alice", "and alice's");
	}else
		t.error("mkauthinfo in the mode: no key file");

	sys->remove(out);
	t.assertnil(cmd(0, "mkauthinfo" :: "-k" :: "key=" + ed :: "alice" :: out :: nil), "mkauthinfo not in the mode, an Ed25519 signer");
	t.assert(exists(out), "makes a key file");
}

# login(2)'s statement of the rule
testRule(t: ref T)
{
	t.assertnil(login->cnsaalg("mldsa87"), "ML-DSA-87 is taken");
	algs := array[] of {"ed25519", "mldsa65", "slhdsa192s", "slhdsa256s", "rsa", "elgamal", "dsa", "", "MLDSA87"};
	for(i := 0; i < len algs; i++)
		t.assert(login->cnsaalg(algs[i]) != nil, "algorithm \"" + algs[i] + "\" is refused");
	t.assertnil(login->cnsahash("sha384"), "SHA-384 is taken");
	t.assertnil(login->cnsahash("sha512"), "SHA-512 is taken");
	hashes := array[] of {"sha256", "sha1", "md5", ""};
	for(i = 0; i < len hashes; i++)
		t.assert(login->cnsahash(hashes[i]) != nil, "hash \"" + hashes[i] + "\" is refused");
	t.assert(login->cnsakey(nil) != nil, "no key is refused");

	# an ML-DSA-87 key file with something else wrong
	f := dir + "/sk.rule";
	t.assertnil(cmd(0, "createsignerkey" :: "-c" :: "-f" :: f :: "signer" :: nil), "an ML-DSA-87 signer");
	info := kr->readauthinfo(f);
	if(info == nil)
		t.fatal("no key file");
	t.assertnil(login->cnsakey(info), "its key file is taken");
	(p14, nil) := login->group(14);
	p15 := info.p;
	info.p = p14;
	e := login->cnsakey(info);
	t.assert(e != nil && contains(e, "2048"), "with a 2048-bit modulus it is refused: " + e);
	info.p = p15;
	pk := array of byte kr->pktostr(info.mypk);
	cert := info.cert;
	info.cert = kr->sign(info.mysk, 0, kr->sha256(pk, len pk, nil, nil), "sha256");
	e = login->cnsakey(info);
	t.assert(e != nil && contains(e, "SHA-384"), "with a certificate under SHA-256 it is refused: " + e);
	info.cert = cert;
	spk := info.spk;
	info.spk = kr->sktopk(kr->genSK("ed25519", "signer", 0));
	e = login->cnsakey(info);
	t.assert(e != nil && contains(e, "signer's key"), "with an Ed25519 signer's key it is refused: " + e);
	info.spk = spk;
	t.assertnil(login->cnsakey(info), "and put back it is taken");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

mkdir(name: string): int
{
	fd := sys->create(name, Sys->OREAD, Sys->DMDIR|8r700);
	return fd != nil;
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
	login = load Login Login->PATH;
	if(kr == nil || login == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:cannot load modules";
	}

	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	for(i := 0; i < 100; i++){
		dir = sys->sprint("/tmp/cnsamode.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
		if(mkdir(dir))
			break;
	}

	run("Createsignerkey", testCreatesignerkey);
	run("Mkauthinfo", testMkauthinfo);
	run("Rule", testRule);

	# the scratch files
	names := array[] of {"sk", "sk.ed", "sk.pq", "sk.rule", "ai"};
	for(i = 0; i < len names; i++)
		sys->remove(dir + "/" + names[i]);
	sys->remove(dir);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
