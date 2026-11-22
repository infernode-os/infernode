implement CnsaAuthTest;

#
# CNSA 2.0 mode and the key file a connection is authenticated with.
#
# The mode is a rule for keys (ML-DSA-87 for signatures, SHA-384 or
# SHA-512 under them, a Diffie-Hellman modulus of 3072 bits or more) and
# the programs that make and issue keys keep it.  The ones that use them
# did not ask: a node in the mode went on authenticating with the
# Ed25519 key file over a 2048-bit group that it had from before, and
# took a peer that had one; Keyring's auth chose ML-KEM-1024 by the mode
# and looked no further, and signed the exchange over SHA-256.
#
# - auth(2)'s client, server and auth, with /env/cnsamode set, refuse a
#   key file that is not the mode's before a byte is sent, saying which
#   part of it; a file that is the mode's is used.  (Any emulator: the
#   mode is the environment's.)
# - Keyring's auth, in an emulator started in the mode (CNSAMODE in the
#   host's environment: tests/host/cnsa_auth_test.sh), refuses an
#   Ed25519 key file, an ML-DSA-87 one over a 2048-bit group and one
#   whose certificate is over SHA-256, each end told why, and two ends
#   with the mode's key files authenticate and agree a secret.  Skipped
#   where the emulator is not in the mode; there an Ed25519 key file
#   still authenticates.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
	IPint: import kr;
include "security.m";
	auth: Auth;
	login: Login;
include "testing.m";
	testing: Testing;
	T: import testing;

CnsaAuthTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/cnsa_auth_test.b";

passed := 0;
failed := 0;
skipped := 0;

emucnsa := 0;	# the emulator's own switch, as it was started

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
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# a signer of algorithm alg and two key files it certified over ha, with the group (alpha, p)
keyfiles(alg, ha: string, alpha, p: ref IPint): (ref Keyring->Authinfo, ref Keyring->Authinfo)
{
	ssk := kr->genSK(alg, "signer", 0);
	if(ssk == nil)
		return (nil, nil);
	spk := kr->sktopk(ssk);
	a := array[2] of ref Keyring->Authinfo;
	names := array[] of {"alice", "bob"};
	for(i := 0; i < 2; i++){
		sk := kr->genSKfromPK(spk, names[i]);
		pk := kr->sktopk(sk);
		b := array of byte kr->pktostr(pk);
		state: ref Keyring->DigestState;
		if(ha == "sha384")
			state = kr->sha384(b, len b, nil, nil);
		else
			state = kr->sha256(b, len b, nil, nil);
		a[i] = ref Keyring->Authinfo(sk, pk, kr->sign(ssk, 0, state, ha), spk, alpha, p);
	}
	return (a[0], a[1]);
}

ed, edb: ref Keyring->Authinfo;		# Ed25519, SHA-256, 2048 bits
good, goodb: ref Keyring->Authinfo;	# the mode's
small, smallb: ref Keyring->Authinfo;	# ML-DSA-87, SHA-384, 2048 bits
hash, hashb: ref Keyring->Authinfo;	# ML-DSA-87, SHA-256, 3072 bits

setmode(on: int)
{
	sys->pctl(Sys->FORKENV, nil);
	fd := sys->create("/env/cnsamode", Sys->OWRITE, 8r666);
	if(fd != nil){
		if(on)
			sys->fprint(fd, "1");
		else
			sys->fprint(fd, "0");
	}
}

timer(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

# one end of Keyring's auth: its error, or "ok " and a digest of the secret
krend(ai: ref Keyring->Authinfo, fd: ref Sys->FD, c: chan of string)
{
	r: string;
	{
		(id, secret) := kr->auth(fd, ai, 0);
		if(secret == nil)
			r = "error: " + id;
		else{
			d := array[Keyring->SHA256dlen] of byte;
			kr->sha256(secret, len secret, d, nil);
			r = sys->sprint("ok %s %.2ux%.2ux%.2ux%.2ux", id, int d[0], int d[1], int d[2], int d[3]);
		}
	} exception e {
	"*" =>
		r = "raised: " + e;
	}
	fd = nil;
	c <-= r;
}

# both ends of Keyring's auth over a pipe
krauth(a, b: ref Keyring->Authinfo): (string, string)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		return ("pipe", "pipe");
	ca := chan[2] of string;
	cb := chan[2] of string;
	spawn krend(a, p[0], ca);
	spawn krend(b, p[1], cb);
	p[0] = p[1] = nil;
	spawn timer(ca, 60000);
	spawn timer(cb, 60000);
	return (<-ca, <-cb);
}

# the far end of libend's connection: how much reaches it in its first
# read (nothing, when the connection is closed with nothing sent), and
# then it is gone, which ends an exchange that had begun
peer(fd: ref Sys->FD, c: chan of int)
{
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	c <-= n;
}

# auth(2)'s client, server or auth in an environment with the mode on or
# off: what it said, and how many bytes it had written to its connection
libend(which: string, on: int, ai: ref Keyring->Authinfo, c: chan of string)
{
	setmode(on);
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		c <-= "pipe";
		return;
	}
	pc := chan[1] of int;
	spawn peer(p[1], pc);
	p[1] = nil;
	r: string;
	{
		case which {
		"client" =>
			(fd, err) := auth->client("none", ai, p[0]);
			if(fd == nil)
				r = "refused: " + err;
			else
				r = "ok";
		"server" =>
			(fd, err) := auth->server("none" :: nil, ai, p[0], 0);
			if(fd == nil)
				r = "refused: " + err;
			else
				r = "ok";
		"auth" =>
			(fd, nil, err) := auth->auth(ai, nil, "none", p[0]);
			if(fd == nil)
				r = "refused: " + err;
			else
				r = "ok";
		}
	} exception e {
	"*" =>
		r = "raised: " + e;
	}
	p[0] = nil;
	c <-= sys->sprint("%s [%d bytes sent]", r, <-pc);
}

lib(which: string, on: int, ai: ref Keyring->Authinfo): string
{
	c := chan[2] of string;
	spawn libend(which, on, ai, c);
	spawn timer(c, 30000);
	return <-c;
}

testAuthLib(t: ref T)
{
	ends := array[] of {"client", "server", "auth"};
	for(i := 0; i < len ends; i++){
		w := ends[i];
		r := lib(w, 1, ed);
		t.assert(contains(r, "refused: CNSA mode") && contains(r, "mldsa87"), sys->sprint("%s, in the mode, refuses an Ed25519 key file saying why: %s", w, r));
		t.assert(contains(r, "[0 bytes sent]"), w + ": and has sent nothing: " + r);
		r = lib(w, 1, small);
		t.assert(contains(r, "refused: CNSA mode") && contains(r, "modulus"), sys->sprint("%s refuses an ML-DSA-87 key file over a 2048-bit group: %s", w, r));
		r = lib(w, 1, hash);
		t.assert(contains(r, "refused: CNSA mode") && contains(r, "SHA-384"), sys->sprint("%s refuses a certificate over SHA-256: %s", w, r));
		# the mode's own file gets as far as the exchange (no peer here: it fails there, having sent)
		r = lib(w, 1, good);
		t.assert(!contains(r, "CNSA mode") && !contains(r, "[0 bytes sent]"), sys->sprint("%s takes the mode's key file to the exchange: %s", w, r));
	}
	if(!emucnsa){
		# out of the mode nothing is asked of the key file
		r := lib("client", 0, ed);
		t.assert(!contains(r, "CNSA mode") && !contains(r, "[0 bytes sent]"), "out of the mode an Ed25519 key file is taken to the exchange: " + r);
	}
}

testKeyring(t: ref T)
{
	if(!emucnsa){
		(ra, rb) := krauth(ed, edb);
		t.assert(contains(ra, "ok bob") && contains(rb, "ok alice"), sys->sprint("out of the mode Ed25519 key files authenticate: %s / %s", ra, rb));
		t.skip("the emulator was not started in CNSA mode (CNSAMODE): tests/host/cnsa_auth_test.sh runs this in one");
	}
	(ra, rb) := krauth(ed, edb);
	t.assert(contains(ra, "CNSA mode") && contains(rb, "CNSA mode"), sys->sprint("Ed25519 key files are refused, each end told: %s / %s", ra, rb));
	t.assert(contains(ra, "ML-DSA-87") || contains(rb, "ML-DSA-87"), "and why");
	(ra, rb) = krauth(small, smallb);
	t.assert(contains(ra, "CNSA mode") && (contains(ra, "3072") || contains(rb, "3072")), sys->sprint("a 2048-bit group is refused: %s / %s", ra, rb));
	(ra, rb) = krauth(hash, hashb);
	t.assert(contains(ra, "CNSA mode") && (contains(ra, "SHA-384") || contains(rb, "SHA-384")), sys->sprint("a certificate over SHA-256 is refused: %s / %s", ra, rb));
	# one end with a good file, the other not: neither is authenticated
	(ra, rb) = krauth(good, edb);
	t.assert(!contains(ra, "ok ") && !contains(rb, "ok "), sys->sprint("a good file against an Ed25519 one authenticates neither: %s / %s", ra, rb));
	(ra, rb) = krauth(good, goodb);
	t.assert(contains(ra, "ok bob") && contains(rb, "ok alice"), sys->sprint("the mode's key files authenticate: %s / %s", ra, rb));
	if(len ra > 7 && len rb > 9)
		t.assertseq(ra[len ra-8:], rb[len rb-8:], "and agree a secret");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	auth = load Auth Auth->PATH;
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
	if(kr == nil || auth == nil || login == nil){
		sys->fprint(sys->fildes(2), "cnsa_auth_test: cannot load keyring, auth or login: %r\n");
		raise "fail:load";
	}
	auth->init();
	emucnsa = login->cnsamode();	# the emulator sets /env/cnsamode from its own switch

	(p2048, nil) := login->group(14);
	(p3072, nil) := login->group(Login->CNSAgroup);
	two := IPint.inttoip(2);
	if(p2048 == nil || p3072 == nil){
		sys->fprint(sys->fildes(2), "cnsa_auth_test: no groups\n");
		raise "fail:setup";
	}
	(ed, edb) = keyfiles("ed25519", "sha256", two, p2048);
	(good, goodb) = keyfiles("mldsa87", "sha384", two, p3072);
	(small, smallb) = keyfiles("mldsa87", "sha384", two, p2048);
	(hash, hashb) = keyfiles("mldsa87", "sha256", two, p3072);
	if(ed == nil || good == nil || small == nil || hash == nil){
		sys->fprint(sys->fildes(2), "cnsa_auth_test: cannot make keys\n");
		raise "fail:setup";
	}

	run("AuthLib", testAuthLib);
	run("Keyring", testKeyring);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
