implement AuthAlgsTest;

#
# The algorithm an authenticated connection runs under (appl/lib/auth.b
# server, and the -a lists of listen(1) and styxlisten).
#
# After the two ends have authenticated, the client says in one message,
# in clear, which ssl(3) algorithm it will use, and the server looks for
# it in its list.  A list in which ssl knows no name (a mistyped one; the
# rc4_256 and sha1 that old scripts gave) asked for neither encryption nor
# integrity, and a client message of one blank named nothing to refuse:
# the server ran the session in clear.  The operator had asked for a
# cipher; an honest client failed at its own end; and someone on the
# path, by putting a blank where the client's choice was, spoke to the
# server as that client.  A blank was taken for "none" under a list that
# had "none" in it too.
#
# The listeners passed any -a name on.  They now refuse to start with a
# name ssl does not have, and with "none" beside an algorithm unless -M
# says so (the client's choice is not authenticated, so that mixture lets
# someone on the path make any caller's session at the server a clear
# one).  styxlisten -A with -a started, and its first caller ended it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "security.m";
	auth: Auth;
include "testing.m";
	testing: Testing;
	T: import testing;

AuthAlgsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auth_algs_test.b";
PLAIN: con "what-the-wire-carries";

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

# the server's end: what it made of the connection, and what it then read
srvproc(algs: list of string, fd: ref Sys->FD, res: chan of string)
{
	(nfd, id) := auth->server(algs, sai, fd, 0);
	fd = nil;
	if(nfd == nil){
		res <-= "REFUSED: " + id;
		return;
	}
	buf := array[128] of byte;
	n := sys->read(nfd, buf, len buf);
	if(n < 0)
		res <-= sys->sprint("ACCEPTED, read error: %r");
	else
		res <-= "ACCEPTED, read: " + string buf[0:n];
}

# a client that authenticates and then sends wire as its choice, whatever
# an honest client would have sent, and goes on in clear
wire(algs: list of string, choice: string): string
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("pipe: %r");
	res := chan[1] of string;
	spawn srvproc(algs, p[1], res);
	p[1] = nil;
	{
		(nil, secret) := kr->auth(p[0], cai, 0);
		if(secret != nil){
			b := array of byte choice;
			kr->sendmsg(p[0], b, len b);
			sys->fprint(p[0], "%s", PLAIN);
		}
	}exception{
	"*" =>
		;	# the server has hung up (a write on a closed pipe)
	}
	spawn timer(res, 10000);
	r := <-res;
	p[0] = nil;
	return r;
}

refused(t: ref T, r: string, what: string)
{
	t.assert(len r >= 8 && r[0:8] == "REFUSED:", what + ": " + r);
}

testServerChoice(t: ref T)
{
	clear := "ACCEPTED, read: " + PLAIN;
	refused(t, wire("bogus" :: nil, " "), "a list ssl knows nothing of, and a blank choice");
	refused(t, wire("rc4_256" :: "sha1" :: nil, "/"), "the old algorithms' names, and a choice of a slash");
	refused(t, wire("bogus" :: nil, "bogus"), "a list ssl knows nothing of, and its own name chosen");
	refused(t, wire("aes_256_gcm" :: nil, " "), "aes_256_gcm offered, a blank choice");
	refused(t, wire("aes_256_gcm" :: nil, "none"), "aes_256_gcm offered, none chosen");
	refused(t, wire("aes_256_gcm" :: "hmac_sha384" :: nil, "hmac_sha384"), "a cipher offered, integrity alone chosen");
	refused(t, wire("none" :: "aes_256_gcm" :: nil, " "), "none and a cipher offered, a blank choice");
	refused(t, wire("none" :: "aes_256_gcm" :: nil, "none aes_256_gcm"), "none chosen with an algorithm");
	refused(t, wire("none" :: nil, " "), "none offered, a blank choice");

	# what the operator named is still to be had
	t.assertseq(wire("none" :: nil, "none"), clear, "none offered and chosen is a clear session");
	t.assertseq(wire("none" :: "aes_256_gcm" :: nil, "none"), clear, "none beside a cipher, and chosen");
	t.assertseq(wire(nil, "none"), clear, "a server with no list takes the client's none");
}

clientproc(alg: string, fd: ref Sys->FD, res: chan of string)
{
	{
		(nfd, err) := auth->client(alg, cai, fd);
		fd = nil;
		if(nfd == nil){
			res <-= "client: " + err;
			return;
		}
		if(sys->fprint(nfd, "%s", PLAIN) < 0)
			res <-= sys->sprint("client write: %r");
		else
			res <-= "sent";
		# keep the conversation until the server has read
		sys->sleep(1000);
	}exception e{
	"*" =>
		res <-= "client: " + e;	# the server has hung up
	}
}

# both ends honest
honest(algs: list of string, alg: string): string
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return sys->sprint("pipe: %r");
	res := chan[1] of string;
	cres := chan[1] of string;
	spawn srvproc(algs, p[1], res);
	spawn clientproc(alg, p[0], cres);
	p = nil;
	spawn timer(res, 10000);
	return <-res;
}

testHonest(t: ref T)
{
	clear := "ACCEPTED, read: " + PLAIN;
	t.assertseq(honest("aes_256_gcm" :: nil, "aes_256_gcm"), clear, "aes_256_gcm offered and chosen: the data arrives");
	t.assertseq(honest("aes_256_gcm" :: "hmac_sha384" :: nil, "aes_256_gcm"), clear, "the cipher of a longer list");
	t.assertseq(honest("hmac_sha384" :: nil, "hmac_sha384"), clear, "integrity alone, offered alone");
	refused(t, honest("aes_256_gcm" :: nil, "hmac_sha384"), "an algorithm not offered");
	refused(t, honest("bogus" :: nil, "aes_256_gcm"), "an honest client of a server whose list is no use");
}

initproc(path: string, args: list of string, c: chan of string)
{
	m := load Cmd path;
	if(m == nil){
		c <-= sys->sprint("cannot load %s: %r", path);
		return;
	}
	{
		m->init(nil, args);
	}exception e{
	"*" =>
		c <-= e;
		return;
	}
	c <-= "started";
}

# how a command's start ends: "started", or what it raised
start(path: string, args: list of string): string
{
	c := chan[1] of string;
	spawn initproc(path, args, c);
	spawn timer(c, 10000);
	return <-c;
}

testListenerStart(t: ref T)
{
	# an address nothing can be announced on and a key file that is
	# not there: a listener that gets as far as either has taken its
	# algorithms
	addr := "nonet!nowhere!1";
	nokey := "/tmp/auth_algs_test.nokey";
	cmd := "{}" :: nil;

	l := "/dis/listen.dis";
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "bogus" :: addr :: cmd),
		"fail:bad algorithm", "listen with a name ssl does not have");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "rc4_256" :: "-a" :: "sha1" :: addr :: cmd),
		"fail:bad algorithm", "listen with the old algorithms");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "aes_256_gcm" :: "-a" :: "sha1" :: addr :: cmd),
		"fail:bad algorithm", "listen with one name it has and one it has not");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "none" :: "-a" :: "aes_256_gcm" :: addr :: cmd),
		"fail:mixed algorithms", "listen with none beside a cipher");
	t.assertseq(start(l, "listen" :: "-M" :: "-k" :: nokey :: "-a" :: "none" :: "-a" :: "aes_256_gcm" :: addr :: cmd),
		"fail:bad keyfile", "listen -M takes none beside a cipher");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "aes_256_gcm" :: "-a" :: "hmac_sha384" :: addr :: cmd),
		"fail:bad keyfile", "listen takes ssl's own algorithms");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: "-a" :: "none" :: addr :: cmd),
		"fail:bad keyfile", "listen takes none alone");
	t.assertseq(start(l, "listen" :: "-k" :: nokey :: addr :: cmd),
		"fail:bad keyfile", "listen takes its default");

	s := "/dis/styxlisten.dis";
	t.assertseq(start(s, "styxlisten" :: "-k" :: nokey :: "-a" :: "bogus" :: addr :: cmd),
		"fail:bad algorithm", "styxlisten with a name ssl does not have");
	t.assertseq(start(s, "styxlisten" :: "-k" :: nokey :: "-a" :: "rc4_256" :: "-a" :: "sha1" :: addr :: cmd),
		"fail:bad algorithm", "styxlisten with the old algorithms");
	t.assertseq(start(s, "styxlisten" :: "-k" :: nokey :: "-a" :: "none" :: "-a" :: "aes_256_gcm" :: addr :: cmd),
		"fail:mixed algorithms", "styxlisten with none beside a cipher");
	t.assertseq(start(s, "styxlisten" :: "-M" :: "-k" :: nokey :: "-a" :: "none" :: "-a" :: "aes_256_gcm" :: addr :: cmd),
		"fail:error", "styxlisten -M takes none beside a cipher");
	t.assertseq(start(s, "styxlisten" :: "-k" :: nokey :: addr :: cmd),
		"fail:error", "styxlisten takes its default");
	t.assertseq(start(s, "styxlisten" :: "-A" :: "-a" :: "aes_256_gcm" :: addr :: cmd),
		"fail:usage", "styxlisten -A with an algorithm");
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
	if(kr == nil || auth == nil){
		sys->fprint(sys->fildes(2), "cannot load keyring or auth: %r\n");
		raise "fail:cannot load";
	}
	auth->init();

	signer := kr->genSK("ed25519", "algs-signer", 0);
	(alpha, p) := kr->dhparams(2048);
	if(signer == nil || alpha == nil || p == nil){
		sys->fprint(sys->fildes(2), "cannot make a signer or a group: %r\n");
		raise "fail:no keys";
	}
	spk := kr->sktopk(signer);
	sai = mkauthinfo(signer, spk, alpha, p, "algs-server");
	cai = mkauthinfo(signer, spk, alpha, p, "algs-client");

	run("ServerChoice", testServerChoice);
	run("Honest", testHonest);
	run("ListenerStart", testListenerStart);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
