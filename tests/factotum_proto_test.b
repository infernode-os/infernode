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
# p9any: the answer to the server's offer was written into the offer's
# array, and a domain that is not UTF-8 is longer said back than it came:
# array bounds error; the last domain offered was taken, whether or not
# it was the one there is a key for; the caller's user= was dropped, so
# with keys for two users of a domain it was given the first's;
# role=server ran the client's side.
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
include "auth9.m";
	auth9: Auth9;
	Ticketreq: import auth9;
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
	ctl(t, "key proto=pass service=protob user=bob !password=");
	t.assertseq(ask(t, "proto=pass service=protoa"), "ok alice apw", "a password is given");
	r := ask(t, "proto=pass service=protob");
	t.assert(contains(r, "error") && !contains(r, "ok bob"), "a key with an empty password is an error, not a success: " + r);
}

testWpapsk(t: ref T)
{
	ctl(t, "key proto=wpapsk role=client essid=home !password=homepsk");
	ctl(t, "key proto=wpapsk role=client essid=work !password=workpsk");
	t.assertseq(ask(t, "proto=wpapsk role=client essid=work"), "ok workpsk", "a network's passphrase is given for its name");
	r := ask(t, "proto=wpapsk role=client");
	t.assert(contains(r, "error") && !contains(r, "psk"), "a query naming no network is given no passphrase: " + r);
	right := ask(t, "proto=wpapsk role=client essid=work !password=workpsk");
	wrong := ask(t, "proto=wpapsk role=client essid=work !password=wrongpsk");
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

# bytes of s with \xff where it has '~'
offer(s: string): array of byte
{
	b := array of byte s;
	for(i := 0; i < len b; i++)
		if(b[i] == byte '~')
			b[i] = byte 16rff;
	return b;
}

# start p9any, write the server's offer, and read the client's answer
p9offer(t: ref T, start: string, o: array of byte): (ref Sys->FD, string)
{
	fd := newrpc(t);
	r := rpc(fd, "start " + start);
	if(r != "ok")
		return (fd, "start: " + r);
	w := array[6 + len o] of byte;
	w[0:] = array of byte "write ";
	w[6:] = o;
	r = string rpcb(fd, w);
	if(r != "ok")
		return (fd, "write: " + r);
	return (fd, rpc(fd, "read"));
}

testP9any(t: ref T)
{
	# alice's key cannot be used (its !hex is not a key), bob's can
	ctl(t, "key proto=p9sk1 dom=corp user=alice !hex=00 !password=x");
	ctl(t, "key proto=p9sk1 dom=corp user=bob !hex=00112233445566 !password=x");
	ctl(t, "key proto=p9sk1 dom=lab user=carol !password=short");
	ctl(t, "key proto=p9sk1 dom=� user=dave !password=short");

	# a domain that is not UTF-8: said back as U+FFFD, three bytes for one
	(nil, r) := p9offer(t, "proto=p9any role=client", offer("p9sk1@~\0"));
	t.assert(!contains(r, "exception"), "an offer whose domain is not UTF-8 raises nothing: " + r);
	t.assertseq(r, "ok p9sk1 �\0", "and is answered");

	(nil, r) = p9offer(t, "proto=p9any role=client", offer("p9sk1@corp p9sk1@lab\0"));
	t.assertseq(r, "ok p9sk1 corp\0", "of two domains there are keys for, the first offered is taken");
	(nil, r) = p9offer(t, "proto=p9any role=client", offer("p9sk1@nokey p9sk1@lab\0"));
	t.assertseq(r, "ok p9sk1 lab\0", "a domain there is no key for is passed over");
	(nil, r) = p9offer(t, "proto=p9any role=client", offer("p9sk1@lab p9sk1@nokey\0"));
	t.assertseq(r, "ok p9sk1 lab\0", "wherever it is in the offer");
	(nil, r) = p9offer(t, "proto=p9any role=client", offer("p9sk1@nokey\0"));
	t.assert(contains(r, "error") && contains(r, "key"), "with no key for any domain offered, an error saying so: " + r);

	r = ask(t, "proto=p9any role=server");
	t.assert(contains(r, "error") && contains(r, "role"), "role=server is refused, there being only the client's side: " + r);

	# the caller's user chooses the key: bob's works as far as asking
	# the authentication server (there is none: no network here)
	fd: ref Sys->FD;
	(fd, r) = p9offer(t, "proto=p9any role=client user=bob", offer("p9sk1@corp\0"));
	t.assertseq(r, "ok p9sk1 corp\0", "a domain with keys for two users");
	chal := rpcb(fd, array of byte "read");
	t.asserteq(len chal, 3 + Auth9->CHALLEN, "the client's challenge follows");
	tr := ref Ticketreq(Auth9->AuthTreq, "bootes", "corp", array[Auth9->CHALLEN] of {* => byte 'c'}, "x", "y");
	p := tr.pack();
	w := array[6 + len p] of byte;
	w[0:] = array of byte "write ";
	w[6:] = p;
	r = string rpcb(fd, w);
	if(r == "ok")
		r = rpc(fd, "read");
	t.log("after the ticket request: " + r);
	t.assert(!contains(r, "invalid !hex key"), "user=bob is not given alice's key: " + r);
	t.assert(contains(r, "getasticket"), "but bob's, which gets as far as the authentication server: " + r);
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
	auth9 = load Auth9 Auth9->PATH;
	if(kr == nil || auth9 == nil){
		sys->fprint(sys->fildes(2), "factotum_proto_test: cannot load keyring or auth9: %r\n");
		raise "fail:load";
	}
	auth9->init();

	sys->pctl(Sys->FORKNS, nil);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(EMPTY, Sys->OREAD, Sys->DMDIR | 8r777);
	# no network for the agent: p9sk1's call to an authentication
	# server finds nothing to dial with
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
	run("RpcTool", testRpcTool);
	run("Alive", testAlive);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
