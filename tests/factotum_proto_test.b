implement FactotumProtoTest;

#
# auth/factotum's protocol modules, through the rpc file of an agent of
# the test's own.
#
# btpin: a query with no addr is for "anything not named", and its PIN is
# the key stored with no addr. Such a query matches every btpin key, and
# the first was given: a board holding only PINs for named peers answered
# a stranger's pairing with one of them, and a default stored after a
# named key was never the one given.
#
# pass: a key whose password is empty was a success ("ok bob ''").
#
# wpapsk: a query naming no network was given the first network's
# passphrase; a query carrying !password=guess was answered only when the
# guess was right.
#
# sign: with no service named the first signing key there was signed;
# an op that is neither absent nor pubkey signed too; and the certificate
# had expiry 0, as one that vouches for a public key for ever has: what
# the caller writes is its choice, a public key's text included. One made
# now has an expiry time long past, which is under the signature, so it
# is refused wherever a certificate is a credential, and still verifies
# as the signature it is (as auditverify verifies it).
#
# p9sk1: gone, its tickets being DES (there is none), and a start for it
# says so; p9any is 9front's, with dp9ik alone.  (The old p9any's faults,
# which had tests here: the
# answer to an offer written into the offer's array, the last domain
# taken, the caller's user= dropped, role=server running the client.)
#
# auth/rpc, the tool: a last line with no newline lost its last
# character; a blank line printed a stale error; a reply that filled its
# buffer was printed as though whole.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "keyring.m";
	kr: Keyring;
include "testing.m";
	testing: Testing;
	T: import testing;

FactotumProtoTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/factotum_proto_test.b";
MNT: con "/tmp/factotum_proto_test";
EMPTY: con "/tmp/factotum_proto_test.empty";

passed := 0;
failed := 0;
skipped := 0;

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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

startagent(c: chan of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	mod := load Command "/dis/auth/factotum.dis";
	if(mod == nil){
		c <-= sys->sprint("cannot load factotum: %r");
		return;
	}
	c <-= nil;
	mod->init(nil, "factotum" :: "-m" :: MNT :: "-s" :: "factotum_proto_test" :: nil);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

reader(fd: ref Sys->FD, c: chan of array of byte)
{
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		c <-= sys->aprint("read error: %r");
	else
		c <-= buf[0:n];
}

writer(fd: ref Sys->FD, b: array of byte, c: chan of string)
{
	if(sys->write(fd, b, len b) < 0)
		c <-= sys->sprint("write error: %r");
	else
		c <-= "ok";
}

# one request written to an rpc file, and what the read after it gives
rpcb(fd: ref Sys->FD, req: array of byte): array of byte
{
	wc := chan[1] of string;
	spawn writer(fd, req, wc);
	tc := chan[1] of int;
	spawn timer(tc, 20000);
	alt{
	e := <-wc =>
		if(e != "ok")
			return array of byte e;
	<-tc =>
		return array of byte "TIMEOUT in write";
	}
	rc := chan[1] of array of byte;
	spawn reader(fd, rc);
	tc = chan[1] of int;
	spawn timer(tc, 20000);
	alt{
	b := <-rc =>
		return b;
	<-tc =>
		return array of byte "TIMEOUT in read";
	}
}

rpc(fd: ref Sys->FD, req: string): string
{
	return string rpcb(fd, array of byte req);
}

newrpc(t: ref T): ref Sys->FD
{
	fd := sys->open(MNT + "/rpc", Sys->ORDWR);
	if(fd == nil)
		t.fatal(sys->sprint("open rpc: %r"));
	return fd;
}

# start a conversation and ask for its first answer
ask(t: ref T, start: string): string
{
	fd := newrpc(t);
	r := rpc(fd, "start " + start);
	if(r != "ok")
		return "start: " + r;
	return rpc(fd, "read");
}

ctl(t: ref T, s: string)
{
	fd := sys->open(MNT + "/ctl", Sys->OWRITE);
	if(fd == nil)
		t.fatal(sys->sprint("open ctl: %r"));
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("ctl %s: %r", s));
}

Named: con "00:1f:20:aa:bb:cc";
Stranger: con "11:22:33:44:55:66";

testBtpin(t: ref T)
{
	ctl(t, "key proto=btpin addr=" + Named + " !pin=4711");

	# as bt9p asks for a peer it has no key for: by address, then with none
	r := ask(t, "proto=btpin addr=" + Stranger);
	t.assert(contains(r, "error"), "no PIN for an address not stored: " + r);
	r = ask(t, "proto=btpin");
	t.assert(!contains(r, "4711"), "a query with no address is not given a named peer's PIN: " + r);
	t.assert(contains(r, "error"), "and is an error while there is no PIN for peers not named: " + r);
	t.assertseq(ask(t, "proto=btpin addr=" + Named), "ok 4711", "the named peer's PIN is given for its address");

	# the default, stored after the named one
	ctl(t, "key proto=btpin !pin=0000");
	t.assertseq(ask(t, "proto=btpin"), "ok 0000", "a query with no address is given the PIN stored with none");
	t.assertseq(ask(t, "proto=btpin addr=" + Named), "ok 4711", "the named peer's is still its own");
}

testPass(t: ref T)
{
	ctl(t, "key proto=pass service=protoa user=alice !password=apw");
	# a key with no password is not stored now (keycheck); asked for,
	# there is none
	e := ctle("key proto=pass service=protob user=bob !password=");
	t.assert(contains(e, "password"), "a key with an empty password is refused when stored: " + e);
	t.assertseq(ask(t, "proto=pass service=protoa"), "ok alice apw", "a password is given");
	r := ask(t, "proto=pass service=protob");
	t.assert(contains(r, "error") && !contains(r, "ok bob"), "and asked for, is an error, not a success: " + r);
}

# a write to ctl: nil, or the error
ctle(s: string): string
{
	fd := sys->open(MNT + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open ctl: %r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

keys(): string
{
	fd := sys->open(MNT + "/ctl", Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open ctl: %r");
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

#
# Every attribute of a request is a pattern, the secret ones too: a
# request carrying !password=guess found the key when the guess was
# right and none when it was not, and the two answers differed (pass,
# btpin, btlink, btltk; wpapsk had its own refusal).  delkey always
# refused a secret with a value; start does now, for every protocol.
#
testSecretQuery(t: ref T)
{
	ctl(t, "key proto=pass service=oracle user=olive !password=rightpw");
	ctl(t, "key proto=btpin addr=aa:aa:aa:aa:aa:aa !pin=2468");
	ctl(t, "key proto=btlink addr=bb:bb:bb:bb:bb:bb type=4 !key=00112233445566778899aabbccddeeff");
	ctl(t, "key proto=btltk addr=cc:cc:cc:cc:cc:cc !ltk=ffeeddccbbaa99887766554433221100");
	ctl(t, "key proto=wpapsk role=client essid=oracle !password=oraclepassphrase");
	cases := array[] of {
		("proto=pass service=oracle", "!password", "rightpw"),
		("proto=btpin addr=aa:aa:aa:aa:aa:aa", "!pin", "2468"),
		("proto=btlink addr=bb:bb:bb:bb:bb:bb", "!key", "00112233445566778899aabbccddeeff"),
		("proto=btltk addr=cc:cc:cc:cc:cc:cc", "!ltk", "ffeeddccbbaa99887766554433221100"),
		("proto=wpapsk role=client essid=oracle", "!password", "oraclepassphrase"),
	};
	for(i := 0; i < len cases; i++){
		(q, name, val) := cases[i];
		right := ask(t, q + " " + name + "=" + val);
		wrong := ask(t, q + " " + name + "=wrongguess");
		t.assert(contains(right, "private fields") && !contains(right, val), q + ": a request with the right secret in it is refused: " + right);
		t.assertseq(right, wrong, q + ": and answered as a wrong guess is");
		ok := ask(t, q);
		t.assert(contains(ok, "ok") && contains(ok, val), q + ": asked for properly, the secret is given");
		quest := ask(t, q + " " + name + "?");
		t.assert(contains(quest, "ok"), q + ": and a secret asked for by name alone (" + name + "?) is no guess: " + quest);
	}
}

#
# Each protocol's check of its own keys, which no code called: a key
# the protocol could never use is refused when it is stored.
#
testKeycheck(t: ref T)
{
	bad := array[] of {
		("key proto=btlink addr=dd:dd:dd:dd:dd:dd !key=short", "32 hex"),
		("key proto=btlink addr=dd:dd:dd:dd:dd:dd !key=zz112233445566778899aabbccddeeff", "32 hex"),
		("key proto=btlink !key=00112233445566778899aabbccddeeff", "addr"),
		("key proto=btltk addr=dd:dd:dd:dd:dd:dd !ltk=0011", "32 hex"),
		("key proto=btltk addr=dd:dd:dd:dd:dd:dd rand=12 !ltk=00112233445566778899aabbccddeeff", "16 hex"),
		("key proto=btpin addr=dd:dd:dd:dd:dd:dd !pin=12345678901234567", "16 bytes"),
		("key proto=btpin addr=dd:dd:dd:dd:dd:dd", "!pin"),
		("key proto=wpapsk role=client essid=kc !password=short", "8 to 63"),
		("key proto=wpapsk role=client !password=longenoughpassphrase", "essid"),
		("key proto=pass service=kc !password=pw", "user"),
		("key proto=sign service=kc !sk=notakey", "secret key"),
		("key proto=sign !sk=notakey", "service"),
	};
	for(i := 0; i < len bad; i++){
		(k, why) := bad[i];
		e := ctle(k);
		t.assert(e != nil && contains(e, why), k + ": refused, saying why: " + e);
	}
	t.assert(!contains(keys(), "dd:dd:dd:dd:dd:dd") && !contains(keys(), "=kc"), "and none of them is stored");
	good := array[] of {
		"key proto=btlink addr=ee:ee:ee:ee:ee:ee type=4 !key=00112233445566778899AABBCCDDEEFF",
		"key proto=btltk addr=ee:ee:ee:ee:ee:ee type=1 ediv=4660 rand=0102030405060708 irk=00 !ltk=00112233445566778899aabbccddeeff",
		"key proto=btpin !pin=1234567890123456",
		"key proto=wpapsk role=client essid=kcgood !password=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"key proto=somethingelse service=kcgood whatever=1 !secret=x",
	};
	for(i = 0; i < len good; i++)
		t.assertnil(ctle(good[i]), good[i] + ": taken");
}

testWpapsk(t: ref T)
{
	ctl(t, "key proto=wpapsk role=client essid=home !password=homepassphrase");
	ctl(t, "key proto=wpapsk role=client essid=work !password=workpassphrase");
	t.assertseq(ask(t, "proto=wpapsk role=client essid=work"), "ok workpassphrase", "a network's passphrase is given for its name");
	r := ask(t, "proto=wpapsk role=client");
	t.assert(contains(r, "error") && !contains(r, "passphrase"), "a query naming no network is given no passphrase: " + r);
	right := ask(t, "proto=wpapsk role=client essid=work !password=workpassphrase");
	wrong := ask(t, "proto=wpapsk role=client essid=work !password=wrongpassphrase");
	t.assert(contains(right, "error") && !contains(right, "ok"), "a query with a secret in it is refused: " + right);
	t.assertseq(right, wrong, "and a right guess is answered as a wrong one is");
}

digest(cert: ref Keyring->Certificate, b: array of byte): ref Keyring->DigestState
{
	if(cert.ha == "sha384")
		return kr->sha384(b, len b, nil, nil);
	return kr->sha256(b, len b, nil, nil);
}

# a conversation with proto=sign: the certificate over content, or the error
signit(t: ref T, start: string, content: array of byte): (ref Keyring->Certificate, string)
{
	fd := newrpc(t);
	r := rpc(fd, "start " + start);
	if(r != "ok")
		return (nil, "start: " + r);
	w := array[6 + len content] of byte;
	w[0:] = array of byte "write ";
	w[6:] = content;
	r = string rpcb(fd, w);
	if(r != "ok")
		return (nil, "write: " + r);
	a := rpcb(fd, array of byte "read");
	if(len a < 3 || string a[0:3] != "ok ")
		return (nil, "read: " + string a);
	cert := kr->strtocert(string a[3:]);
	if(cert == nil)
		return (nil, "not a certificate: " + string a);
	return (cert, nil);
}

now(): int
{
	fd := sys->open("/dev/time", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	return int (big string buf[0:n] / big 1000000);
}

testSign(t: ref T)
{
	ctl(t, "genkey proto=sign service=audit alg=ed25519 owner=audit");
	ctl(t, "genkey proto=sign service=release alg=ed25519 owner=release");

	fd := newrpc(t);
	t.assertseq(rpc(fd, "start proto=sign role=client service=audit op=pubkey"), "ok", "start for the public key");
	a := rpcb(fd, array of byte "read");
	pk: ref Keyring->PK;
	if(len a > 3 && string a[0:3] == "ok ")
		pk = kr->strtopk(string a[3:]);
	if(pk == nil)
		t.fatal("op=pubkey gave no public key: " + string a);
	t.assertseq(pk.owner, "audit", "the service's key is the one named");

	hello := array of byte "audit-checkpoint 00ff 7";
	(cert, err) := signit(t, "proto=sign role=client service=audit", hello);
	if(cert == nil)
		t.fatal("service=audit did not sign: " + err);
	t.asserteq(kr->verify(pk, cert, digest(cert, hello)), 1, "what was signed verifies under the service's public key, as auditverify verifies it");
	other := array of byte "audit-checkpoint 00ff 8";
	t.asserteq(kr->verify(pk, cert, digest(cert, other)), 0, "and other content does not");

	# the caller chooses what is signed: a public key's text makes the
	# result, in bytes, a certificate for that key
	sk := kr->genSK("ed25519", "mallory", 0);
	if(sk == nil)
		t.fatal("cannot make a key");
	mine := array of byte kr->pktostr(kr->sktopk(sk));
	(cert, err) = signit(t, "proto=sign role=client service=audit", mine);
	if(cert == nil)
		t.fatal("did not sign: " + err);
	t.asserteq(kr->verify(pk, cert, digest(cert, mine)), 1, "a signature over a public key's text is a signature");
	n := now();
	t.assert(n > 0, "the clock reads");
	# Keyring's auth, logind and keyset take a certificate with exp 0,
	# or one whose exp is still to come
	t.assert(cert.exp != 0 && cert.exp < n,
		sys->sprint("and is no certificate for the key: its expiry time (%d) is long past, where 0 is never", cert.exp));

	(cert, err) = signit(t, "proto=sign role=client", hello);
	t.assert(cert == nil && contains(err, "error"), "with no service named nothing is signed: " + err);
	(cert, err) = signit(t, "proto=sign role=client service=audit op=bogus", hello);
	t.assert(cert == nil && contains(err, "error"), "an op that is not one signs nothing: " + err);
}

# p9sk1 is gone (its tickets are DES, which is): a start for it says so,
# and a key stored for p9sk1 is still a key of a protocol with no module
# here, taken and listed.  p9any is 9front's, offering dp9ik alone
# (tests/dp9ik_proto_test.b has its conversations): the client's side
# only, an offer of p9sk1 alone refused saying why, and a dp9ik key
# checked when it is stored.
testP9any(t: ref T)
{
	ctl(t, "key proto=p9sk1 dom=corp user=alice !password=x");
	plain := "p9sk1 authentication is not available";
	r := ask(t, "proto=p9sk1 role=client dom=corp");
	t.assert(contains(r, "start: ") && contains(r, plain), "a start for p9sk1 says the protocol is gone: " + r);
	t.assert(!contains(r, "does not exist") && !contains(r, "module"), "not that a file is missing");
	t.assert(contains(keys(), "dom=corp"), "a p9sk1 key is kept as any key with no protocol module is");

	r = ask(t, "proto=p9any role=server");
	t.assert(contains(r, "role=client"), "p9any's server side is refused: " + r);

	fd := newrpc(t);
	t.assertseq(rpc(fd, "start proto=p9any role=client"), "ok", "p9any's client starts");
	r = string rpcb(fd, array of byte "write v.2 p9sk1@corp\0");
	t.assert(contains(r, "DES") && contains(r, "dp9ik"), "an offer of p9sk1 alone is refused saying why: " + r);

	t.assert(contains(ctle("key proto=dp9ik user=alice !password=x"), "dom="), "a dp9ik key with no domain is refused");
	t.assert(contains(ctle("key proto=dp9ik dom=corp !password=x"), "user="), "or no user");
	t.assert(contains(ctle("key proto=dp9ik dom=corp user=alice"), "password"), "or no password");
	t.assert(ctle("key proto=dp9ik dom=corp user=alice !password=x") == nil, "a whole dp9ik key is taken");
}

# auth/rpc with text as its standard input: what it prints
tool(text: string): string
{
	in := array[2] of ref Sys->FD;
	out := array[2] of ref Sys->FD;
	if(sys->pipe(in) < 0 || sys->pipe(out) < 0)
		return sys->sprint("pipe: %r");
	c := chan of int;
	spawn toolproc(in[0], out[1], c);
	<-c;
	in[0] = nil;
	out[1] = nil;
	b := array of byte text;
	sys->write(in[1], b, len b);
	in[1] = nil;
	rc := chan[1] of string;
	spawn readall(out[0], rc);
	tc := chan[1] of int;
	spawn timer(tc, 20000);
	alt{
	s := <-rc =>
		return s;
	<-tc =>
		return "TIMEOUT";
	}
}

readall(fd: ref Sys->FD, c: chan of string)
{
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	c <-= s;
}

toolproc(in, out: ref Sys->FD, c: chan of int)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(in.fd, 0);
	sys->dup(out.fd, 1);
	in = nil;
	out = nil;
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	c <-= 1;
	mod := load Command "/dis/auth/rpc.dis";
	if(mod == nil){
		sys->print("cannot load auth/rpc: %r\n");
		return;
	}
	{
		mod->init(nil, "rpc" :: MNT + "/rpc" :: nil);
	}exception{
	"*" =>
		;
	}
}

testRpcTool(t: ref T)
{
	ctl(t, "key proto=pass service=toola user=tess !password=tpw");
	r := tool("start proto=pass service=toola\nread");
	t.assert(contains(r, "ok tess tpw"), "a last line with no newline is sent whole: " + r);
	r = tool("\nstart proto=pass service=toola\n\nread\n");
	t.assert(contains(r, "ok tess tpw"), "blank lines are passed over: " + r);
	t.assert(!contains(r, "!"), "and print no error: " + r);
	long := "";
	for(i := 0; i < 5000; i++)
		long[i] = 'x';
	r = tool("start proto=pass service=" + long + "\nread\n");
	t.assert(contains(r, "may be cut short"), "a reply that filled the buffer is said to be perhaps not whole: ..." + r[len r - 80:]);
}

alive(t: ref T)
{
	fd := sys->open(MNT + "/ctl", Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open ctl: %r"));
	c := chan[1] of array of byte;
	spawn reader(fd, c);
	tc := chan[1] of int;
	spawn timer(tc, 5000);
	alt{
	<-c =>
		t.assert(1, "the agent's ctl file still reads");
	<-tc =>
		t.error("the agent no longer answers");
	}
}

testAlive(t: ref T)
{
	alive(t);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(sys->fildes(2), "factotum_proto_test: cannot load keyring: %r\n");
		raise "fail:load";
	}

	sys->pctl(Sys->FORKNS, nil);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(EMPTY, Sys->OREAD, Sys->DMDIR | 8r777);
	# no network for the agent
	sys->bind(EMPTY, "/net", Sys->MREPL);
	c := chan of string;
	spawn startagent(c);
	if((e := <-c) != nil){
		sys->fprint(sys->fildes(2), "factotum_proto_test: %s\n", e);
		raise "fail:setup";
	}
	for(i := 0; i < 50; i++){
		(ok, nil) := sys->stat(MNT + "/rpc");
		if(ok >= 0)
			break;
		sys->sleep(100);
	}

	run("Btpin", testBtpin);
	run("Pass", testPass);
	run("Wpapsk", testWpapsk);
	run("Sign", testSign);
	run("P9any", testP9any);
	run("SecretQuery", testSecretQuery);
	run("Keycheck", testKeycheck);
	run("RpcTool", testRpcTool);
	run("Alive", testAlive);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
