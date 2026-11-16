implement SignerTest;

#
# signer(8) and countersigner on a pipe, as listen(1) gives each a
# connection, over a /keydb of the test's own.
#
# signer takes a public key from anybody, signs it, and keeps the
# blinded certificate's pad in /keydb/signed/<owner> until an operator
# who has checked the caller (verify(8)) puts it in
# /keydb/countersigned/<owner>, where countersigner gives it to whoever
# asks for that name.  Both used the name as it came:
#
#   - a key owned by ../signerkey had the request's record written over
#     the signer's own key (every certificate of the realm orphaned by
#     one connection), ../../x made a file anywhere the signer's user
#     could;
#   - a boxid of ../signed/alice had countersigner hand over the pad of
#     a request nobody had approved, which unblinds the certificate the
#     signer sent for it: a certificate from the realm's signer for any
#     name, with no operator and no password.
#
# A name is now one account name (login(6)) before any file is touched,
# countersigner's name space holds only the approved records, the
# signer's own name is not signed for anybody, and a certificate too
# large for a message (ML-DSA-87's) is refused before its record is
# made, not after.
#
# And what was left of the flow's looseness:
#   - a second request for a name replaced the first (the operator then
#     compared the second caller's digest, and turned the first away);
#   - with no key file that read, signer made a new key for the realm,
#     owned by "*", and said nothing;
#   - any key that parsed was signed, for "*" too, and each connection
#     cost a signature, a read of /dev/random and a file, without limit;
#   - the digest the operator compares was MD5;
#   - a refusal, by signer or countersigner, was a connection that
#     closed; verify left a rejected request where it was.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "msgio.m";
	msgio: Msgio;

include "daytime.m";
	daytime: Daytime;

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

SignerTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/signer_test.b";

passed := 0;
failed := 0;
skipped := 0;

testdir: string;

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

signerkey(alg, file: string): string
{
	csk := load Command "/dis/auth/createsignerkey.dis";
	if(csk == nil)
		return sys->sprint("can't load createsignerkey: %r");
	{
		csk->init(nil, "createsignerkey" :: "-a" :: alg :: "-f" :: file :: "signer" :: nil);
	} exception e {
	"*" =>
		return "createsignerkey: " + e;
	}
	(ok, nil) := sys->stat(file);
	if(ok < 0)
		return sys->sprint("no signer key made: %r");
	return nil;
}

setup(): string
{
	(tok, nil) := sys->stat("/tmp");
	if(tok < 0)
		mkdir("/tmp");
	d: string;
	for(i := 0; i < 100; i++){
		d = sys->sprint("/tmp/signertest.%d.%d.%d", sys->pctl(0, nil), sys->millisec(), i);
		if(mkdir(d) >= 0)
			break;
	}
	testdir = d;
	if(mkdir(d+"/root") < 0 || mkdir(d+"/root/keydb") < 0 ||
	   mkdir(d+"/root/keydb/signed") < 0 || mkdir(d+"/root/keydb/countersigned") < 0 ||
	   mkdir(d+"/pq") < 0 || mkdir(d+"/pq/signed") < 0 || mkdir(d+"/pq/countersigned") < 0)
		return sys->sprint("can't make %s: %r", d);
	if(sys->bind(d+"/root", "/", Sys->MBEFORE) < 0)
		return sys->sprint("can't bind the signer's files: %r");
	# the signer's pad is from /dev/random, seconds a read: the DRBG
	if(sys->bind("#c/notquiterandom", "/dev/random", Sys->MREPL) < 0)
		return sys->sprint("can't bind #c/notquiterandom over /dev/random: %r");
	setcnsa(0);
	err := signerkey("ed25519", "/keydb/signerkey");
	if(err == nil)
		err = signerkey("mldsa87", d+"/pq/signerkey");
	return err;
}

# prog with one end of a pipe as its standard input and output; the
# other end.  keydb, if given, is bound over /keydb for it alone.
service(prog, keydb: string): ref Sys->FD
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return nil;
	done := chan of int;
	spawn runsvc(prog, keydb, p[1], done);
	<-done;
	return p[0];
}

svccnsa := 0;	# the services' cnsamode
svcargs: list of string;	# and arguments
keepcount := 0;	# leave the throttle's counts between requests

runsvc(prog, keydb: string, fd: ref Sys->FD, done: chan of int)
{
	args := svcargs;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP|Sys->FORKNS|Sys->FORKENV, nil);
	setcnsa(svccnsa);
	if(keydb != nil)
		sys->bind(keydb, "/keydb", Sys->MREPL|Sys->MCREATE);
	if(!keepcount)
		sys->remove("/keydb/loginfail");
	sys->dup(fd.fd, 0);
	sys->dup(fd.fd, 1);
	fd = nil;
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	done <-= 1;
	c := load Command prog;
	if(c == nil)
		return;
	{
		c->init(nil, prog :: args);
	} exception {
	"*" =>
		;
	}
}

# a message from a service, or nil when it has gone or says nothing
getmsg(fd: ref Sys->FD): array of byte
{
	res := chan[1] of array of byte;
	spawn msgreader(fd, res);
	tick := chan of int;
	spawn sleeper(tick, 20000);
	alt {
	b := <-res =>
		return b;
	<-tick =>
		return nil;
	}
}

msgreader(fd: ref Sys->FD, res: chan of array of byte)
{
	res <-= kr->getmsg(fd);
}

# a message, or nil and what the service said in place of one
getmsge(fd: ref Sys->FD): (array of byte, string)
{
	res := chan[1] of (array of byte, string);
	spawn msgereader(fd, res);
	tick := chan of int;
	spawn sleeper(tick, 20000);
	alt {
	(b, e) := <-res =>
		return (b, e);
	<-tick =>
		return (nil, "no answer in 20 seconds");
	}
}

msgereader(fd: ref Sys->FD, res: chan of (array of byte, string))
{
	b := kr->getmsg(fd);
	e: string;
	if(b == nil)
		e = sys->sprint("%r");
	res <-= (b, e);
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

# Ask the signer (its /keydb the one given) to certify a key for owner:
# the signer's key, the caller's as sent, and the blinded certificate.
asksigner(owner, keydb: string): (ref Keyring->PK, array of byte, array of byte)
{
	(spk, mypk, blinded, nil) := asksignerwith("ed25519", owner, keydb);
	return (spk, mypk, blinded);
}

# the same with a key of alg, and what the signer said if it refused
asksignerwith(alg, owner, keydb: string): (ref Keyring->PK, array of byte, array of byte, string)
{
	fd := service("/dis/auth/signer.dis", keydb);
	if(fd == nil)
		return (nil, nil, nil, "no service");
	(spkb, e) := getmsge(fd);
	if(spkb == nil)
		return (nil, nil, nil, e);
	getmsg(fd);	# alpha
	getmsg(fd);	# p
	sk := kr->genSK(alg, "x", 0);
	pk := kr->sktopk(sk);
	pk.owner = owner;
	mypk := array of byte kr->pktostr(pk);
	kr->sendmsg(fd, mypk, len mypk);
	blinded: array of byte;
	(blinded, e) = getmsge(fd);
	return (kr->strtopk(string spkb), mypk, blinded, e);
}

askcounter(boxid: array of byte): array of byte
{
	(b, nil) := askcountere(boxid);
	return b;
}

askcountere(boxid: array of byte): (array of byte, string)
{
	fd := service("/dis/auth/countersigner.dis", nil);
	if(fd == nil)
		return (nil, "no service");
	msgio->sendmsg(fd, boxid, len boxid);
	return getmsge(fd);
}

# verify(8) for owner, the operator answering y or n: what it left
verify(owner, answer: string)
{
	svcargs = owner :: nil;
	fd := service("/dis/auth/verify.dis", nil);
	svcargs = nil;
	if(fd == nil)
		return;
	sys->fprint(fd, "%s\n", answer);
	# its words, until it has gone
	buf := array[512] of byte;
	tick := chan of int;
	done := chan[1] of int;
	spawn drain(fd, buf, done);
	spawn sleeper(tick, 10000);
	alt {
	<-done =>
		;
	<-tick =>
		;
	}
}

drain(fd: ref Sys->FD, buf: array of byte, done: chan of int)
{
	while(sys->read(fd, buf, len buf) > 0)
		;
	done <-= 1;
}

readfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return buf[0:n];
}

eq(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
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

# what verify(8) does once the operator accepts: the pad, first
# message of signed/owner, becomes countersigned/owner
approve(owner: string): int
{
	fd := sys->open("/keydb/signed/"+owner, Sys->OREAD);
	if(fd == nil)
		return -1;
	pad := kr->getmsg(fd);
	if(pad == nil)
		return -1;
	out := sys->create("/keydb/countersigned/"+owner, Sys->OWRITE, 8r600);
	if(out == nil)
		return -1;
	return kr->sendmsg(out, pad, len pad);
}

exists(f: string): int
{
	(ok, nil) := sys->stat(f);
	return ok >= 0;
}

names(d: string): string
{
	s := "";
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil)
		return "?";
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			s += " " + dirs[i].name;
	}
	return s;
}

keysize(): big
{
	(ok, d) := sys->stat("/keydb/signerkey");
	if(ok < 0)
		return big -1;
	return d.length;
}

certifies(spk: ref Keyring->PK, mypk, blinded, pad: array of byte): int
{
	if(spk == nil || blinded == nil || pad == nil || len pad != len blinded)
		return 0;
	b := array[len blinded] of byte;
	for(i := 0; i < len b; i++)
		b[i] = blinded[i] ^ pad[i];
	cert := kr->strtocert(string b);
	if(cert == nil)
		return 0;
	return kr->verify(spk, cert, kr->sha256(mypk, len mypk, nil, nil)) != 0;
}

# The flow as signer(8) describes it still works: request, approval,
# countersigner, a certificate.
testFlow(t: ref T)
{
	(spk, mypk, blinded) := asksigner("alice", nil);
	t.assert(blinded != nil, "the signer answers a request for alice with a blinded certificate");
	t.assert(exists("/keydb/signed/alice"), "and keeps its record in signed/alice");
	t.assert(!certifies(spk, mypk, blinded, blinded), "the blinded certificate is no certificate");
	t.assert(askcounter(array of byte "alice") == nil, "countersigner has nothing for alice before an operator approves");
	if(approve("alice") < 0)
		t.fatal(sys->sprint("can't approve alice's request: %r"));
	pad := askcounter(array of byte "alice");
	t.assert(pad != nil, "once approved, countersigner gives the pad to a caller naming alice");
	t.assert(certifies(spk, mypk, blinded, pad), "and it unblinds a certificate that verifies with the signer's key");
}

# A boxid that is a path gave the pad of a request nobody had approved.
testBoxid(t: ref T)
{
	(spk, mypk, blinded) := asksigner("bob", nil);
	if(blinded == nil || !exists("/keydb/signed/bob"))
		t.fatal("no request for bob to try");
	ids := array[] of {
		array of byte "../signed/bob",
		array of byte "../signed/./bob",
		array of byte "..\\signed\\bob",
		array of byte "../signerkey",
		array of byte "/keydb/signed/bob",
		array of byte "#U/keydb/signed/bob",
		array of byte ".",
		array of byte "..",
		array of byte "a/b",
		array of byte "",
		array of byte "bob\n",
	};
	for(i := 0; i < len ids; i++){
		pad := askcounter(ids[i]);
		what := sys->sprint("boxid %q", string ids[i]);
		t.assert(pad == nil, what + " is given nothing");
		t.assert(!certifies(spk, mypk, blinded, pad), what + " does not unblind bob's certificate, which no operator approved");
	}
	t.assert(askcounter(array of byte "alice") != nil, "an approved record is still given");
}

# An owner that is a path wrote the request's record there.
testOwner(t: ref T)
{
	before := keysize();
	long := "";
	for(i := 0; i < 300; i++)
		long[len long] = 'a';
	owners := array[] of {
		"../signerkey",
		"../../victimfile",
		"../countersigned/carol",
		"..\\signerkey",
		"a/b",
		".",
		"..",
		long,
		"carol\tx",
		" carol",
	};
	was := names("/keydb/signed");
	sys->remove("/victimfile");	# what the code before left, if it ran here
	for(i = 0; i < len owners; i++){
		what := sys->sprint("a key owned by %q", owners[i]);
		if(len owners[i] > 64)
			what = sys->sprint("a key with an owner of %d bytes", len owners[i]);
		(nil, nil, blinded) := asksigner(owners[i], nil);
		t.assert(blinded == nil, what + " is not signed");
	}
	t.assert(keysize() == before && kr->readauthinfo("/keydb/signerkey") != nil, "the signer's key is as it was");
	t.assert(!exists("/victimfile") && !exists(testdir+"/victimfile"), "no file was made outside signed/");
	sys->remove("/victimfile");
	t.assert(!exists("/keydb/countersigned/carol"), "nor an approval nobody gave");
	t.assertseq(names("/keydb/signed"), was, "and signed/ has what it had");

	# the signer's own name is its key file's alone
	(nil, nil, blinded) := asksigner("signer", nil);
	t.assert(blinded == nil, "a key owned by the signer's own name is not signed");
	t.assert(!exists("/keydb/signed/signer"), "and leaves no record");
}

# A certificate too large for one of the protocol's messages (an
# ML-DSA-87 signature) was signed, recorded, and then could not be sent.
testLargeCert(t: ref T)
{
	keydb := testdir + "/pq";
	(spk, nil, blinded, e) := asksignerwith("mldsa87", "dave", keydb);
	t.assert(spk != nil, "a signer with an ML-DSA-87 key sends its key");
	t.assert(blinded == nil, "its certificate, which no message holds, is not sent");
	t.assert(contains(e, "does not fit"), "and the caller is told it does not fit: " + e);
	t.assert(!exists(keydb+"/signed/dave"), "and no record of a request that cannot be answered is left");
}

# One request waits for a name: a second replaced it, and the operator
# compared the wrong caller's digest.
testPending(t: ref T)
{
	(spk, mypk, blinded, e) := asksignerwith("ed25519", "erin", nil);
	if(blinded == nil)
		t.fatal("no request for erin: " + e);
	rec := readfile("/keydb/signed/erin");
	t.assert(rec != nil, "erin's request is recorded");
	(nil, nil, b2, e2) := asksignerwith("ed25519", "erin", nil);
	t.assert(b2 == nil, "a second request for erin, while the first waits, is not signed");
	t.assert(contains(e2, "pending"), "and its caller is told one is pending: " + e2);
	t.assert(eq(readfile("/keydb/signed/erin"), rec), "the first request's record is as it was");

	# the digest the operator and the caller compare: SHA-256 of the
	# signer's key, the caller's and the blinded certificate
	fd := sys->open("/keydb/signed/erin", Sys->OREAD);
	kr->getmsg(fd);
	digest := kr->getmsg(fd);
	spkb := array of byte kr->pktostr(spk);
	st := kr->sha256(spkb, len spkb, nil, nil);
	kr->sha256(mypk, len mypk, nil, st);
	want := array[Keyring->SHA256dlen] of byte;
	kr->sha256(blinded, len blinded, want, st);
	t.assert(eq(digest, want), sys->sprint("the record's digest is the SHA-256 (%d bytes kept)", len digest));
	fd = nil;

	# the operator says no: the request is gone, and another is taken
	verify("erin", "n");
	t.assert(!exists("/keydb/signed/erin"), "a request the operator rejects is gone from signed/");
	t.assert(!exists("/keydb/countersigned/erin"), "and is not approved");
	(nil, nil, b3, e3) := asksignerwith("ed25519", "erin", nil);
	t.assert(b3 != nil, "after which a request for erin is taken: " + e3);

	# the operator says yes: approved, and gone from signed/
	verify("erin", "y");
	t.assert(exists("/keydb/countersigned/erin"), "a request the operator accepts is in countersigned/");
	t.assert(!exists("/keydb/signed/erin"), "and gone from signed/");

	# one nobody answered is replaced once it is old
	(nil, nil, b4, nil) := asksignerwith("ed25519", "frank", nil);
	t.assert(b4 != nil, "a request for frank");
	nd := sys->nulldir;
	nd.mtime = daytime->now() - 3600;
	if(sys->wstat("/keydb/signed/frank", nd) < 0)
		t.fatal(sys->sprint("can't age frank's request: %r"));
	(nil, nil, b5, e5) := asksignerwith("ed25519", "frank", nil);
	t.assert(b5 != nil, "a request left an hour gives way to a new one: " + e5);
}

# With no key file, signer made a key for the realm and went on.
testNoKey(t: ref T)
{
	keydb := testdir + "/nokey";
	if(mkdir(keydb) < 0 || mkdir(keydb+"/signed") < 0 || mkdir(keydb+"/countersigned") < 0)
		t.fatal(sys->sprint("can't make %s: %r", keydb));
	(spk, nil, blinded, e) := asksignerwith("ed25519", "grace", keydb);
	t.assert(spk == nil && blinded == nil, "a signer with no key file sends no key and signs nothing");
	t.assert(contains(e, "unavailable"), "and says the service is unavailable: " + e);
	t.assert(!exists(keydb+"/signerkey"), "it makes no key of its own");
	# nor with a file that is no key
	fd := sys->create(keydb+"/signerkey", Sys->OWRITE, 8r600);
	sys->fprint(fd, "not a key\n");
	fd = nil;
	was := readfile(keydb+"/signerkey");
	(spk, nil, blinded, e) = asksignerwith("ed25519", "grace", keydb);
	t.assert(spk == nil && blinded == nil, "nor with a file that is no key");
	t.assert(eq(readfile(keydb+"/signerkey"), was), "which it leaves as it was");
}

# The key certified, and its owner.
testKeyChecked(t: ref T)
{
	(nil, nil, blinded, e) := asksignerwith("ed25519", "*", nil);
	t.assert(blinded == nil, "a key owned by * is not signed: " + e);
	t.assert(!exists("/keydb/signed/*"), "and leaves no record");
	(nil, nil, blinded, e) = asksignerwith("mldsa65", "heidi", nil);
	t.assert(blinded == nil, "a key that is not of the signer's algorithm is not signed");
	t.assert(contains(e, "algorithm"), "and its caller is told why: " + e);
	t.assert(!exists("/keydb/signed/heidi"), "and leaves no record");
}

# CNSA mode: a signer's key that is not CNSA's signs nothing.
testCNSA(t: ref T)
{
	svccnsa = 1;
	(spk, nil, blinded, e) := asksignerwith("ed25519", "ivan", nil);
	svccnsa = 0;
	t.assert(spk == nil && blinded == nil, "in CNSA mode a signer with an Ed25519 key sends no key and signs nothing");
	t.assert(contains(e, "CNSA"), "and says its key is not CNSA's: " + e);
	t.assert(!exists("/keydb/signed/ivan"), "and leaves no record");
}

# Ten requests in a row, and the next are refused for a minute: each
# cost a signature and a file, from anybody, without limit.
testThrottle(t: ref T)
{
	sys->remove("/keydb/loginfail");
	keepcount = 1;
	n := 0;
	e: string;
	for(i := 0; i < 14; i++){
		spk: ref Keyring->PK;
		(spk, nil, nil, e) = asksignerwith("ed25519", ".", nil);	# a name refused: cheap
		if(spk == nil)
			break;
		n++;
	}
	keepcount = 0;
	t.asserteq(n, 10, "requests answered before the signer refuses them");
	t.assert(contains(e, "too many requests"), "the next is told there are too many: " + e);
	sys->remove("/keydb/loginfail");
	(spk, nil, nil, nil) := asksignerwith("ed25519", ".", nil);
	t.assert(spk != nil, "and with the count gone the signer answers");
}

# countersigner says why it gives nothing.
testCounterSays(t: ref T)
{
	(b, e) := askcountere(array of byte "nobody-approved");
	t.assert(b == nil, "an id nobody approved is given nothing");
	t.assert(contains(e, "no approved request"), "and is told so: " + e);
	(b, e) = askcountere(array of byte "../signed/alice");
	t.assert(b == nil && contains(e, "bad id"), "an id that is no name is told so: " + e);
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
	msgio = load Msgio Msgio->PATH;
	testing = load Testing Testing->PATH;

	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(msgio == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Msgio->PATH);
		raise "fail:cannot load msgio";
	}
	msgio->init();
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Daytime->PATH);
		raise "fail:cannot load daytime";
	}

	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	err := setup();
	if(err != nil){
		sys->fprint(sys->fildes(2), "signer_test: %s\n", err);
		raise "fail:setup";
	}

	run("Signer/Flow", testFlow);
	run("Signer/Boxid", testBoxid);
	run("Signer/Owner", testOwner);
	run("Signer/LargeCert", testLargeCert);
	run("Signer/Pending", testPending);
	run("Signer/NoKey", testNoKey);
	run("Signer/KeyChecked", testKeyChecked);
	run("Signer/CNSA", testCNSA);
	run("Signer/Throttle", testThrottle);
	run("Signer/CounterSays", testCounterSays);

	rmtree(testdir);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
