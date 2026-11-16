implement Logind;

#
# certification service (signer)
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	ssl: SSL;
	rand: Random;
	login: Login;

include "daytime.m";
	daytime: Daytime;

include "audit.m";
	audit: Audit;

Logind: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

TimeLimit: con 5*60*1000;	# five minutes
keydb := "/mnt/keys";

#
# The exchange is login(6)'s, version 2; the pieces both ends compute
# (the groups, the keystream, the keys, the rule for names) and the
# count of failed attempts are login(2)'s, in appl/lib/login.b, where
# the reasons are.
#

mingroup := 14;	# -g: the least group offered

stderr: ref Sys->FD;
 
init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->open("/dev/cons", sys->OWRITE);

	kr = load Keyring Keyring->PATH;

	ssl = load SSL SSL->PATH;
	if(ssl == nil)
		nomod(SSL->PATH);

	daytime = load Daytime Daytime->PATH;
	if(daytime == nil) 
		nomod(Daytime->PATH);

	rand = load Random Random->PATH;
	if(rand == nil)
		nomod(Random->PATH);

	login = load Login Login->PATH;
	if(login == nil)
		nomod(Login->PATH);

	audit = load Audit Audit->PATH;	# optional: the audit log
	if(audit != nil)
		audit->init();

	# -g n: offer no group below RFC 3526's group n (14, 15 or 16)
	if(args != nil)
		args = tl args;
	for(; args != nil; args = tl args){
		if(hd args == "-g" && tl args != nil){
			args = tl args;
			mingroup = int hd args;
			(gp, nil) := login->group(mingroup);
			if(gp == nil)
				fatal("-g: no group " + hd args + " (14, 15 or 16)");
		}else
			fatal("usage: logind [-g group]");
	}

	(err, c) := ssl->connect(sys->fildes(0));     
	if(c == nil)
		fatal("pushing ssl: " + err);

	# impose time out to ensure dead network connections recovered well before TCP/IP's long time out

	grpid := sys->pctl(Sys->NEWPGRP,nil);
	pidc := chan of int;
	spawn stalker(pidc, grpid);
	tpid := <-pidc;
	err = dologin(c);
	if(err != nil){
		sys->fprint(stderr, "logind: %s\n", err);
		kr->puterror(c.dfd, err);
	}
	kill(tpid, "kill");
}

# What is said to the client is at most 63 bytes: Keyring's getstring
# keeps no more of an error.
dologin(c: ref Sys->Connection): string
{
	(info, err) := signerkey("/keydb/signerkey");
	if(info == nil){
		sys->fprint(stderr, "logind: can't read signer's own key: %s\n", err);
		return "login service unavailable";
	}

	# The user's name, which must be one account name before it is
	# acknowledged, counted, looked up or signed: "carol/." was carol to
	# keyfs and somebody else to the throttle, and "../../tmp/x" took the
	# password from a file of anybody's.
	s: string;
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return err;
	name := s;
	err = login->okname(name);
	if(err != nil){
		# recorded as one value, and no more of it than a name has
		if(len s > 64)
			s = s[0:64];
		auditlog("authfail", sys->sprint("user=%s reason=badname", auditval(s)));
		sys->fprint(stderr, "logind: refused a name: %s\n", err);
		return "bad user name";
	}
	kr->putstring(c.dfd, name);

	# The client's hello: version, suite, its nonce.  The old exchange
	# sent an ivec of 32 or 44 bytes here; it is not spoken, and nothing
	# is negotiated down to it.
	hello: array of byte;
	(hello, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return "can't get hello: "+err;
	if(len hello == 32 || len hello == 44)
		return "signer speaks login version 2; update the client (login(6))";
	if(len hello != 2+Login->Noncelen || int hello[0] != Login->Version)
		return "bad hello: signer speaks login version 2 (login(6))";
	suite := int hello[1];
	gid := mingroup;
	case suite {
	Login->Chacha =>
		if(cnsamode())
			return "CNSA mode: AES-256-GCM logins only; set cnsamode on the client";
	Login->Aesgcm =>
		if(gid < 15)
			gid = 15;	# CNSA: 3072 bits at least
	* =>
		return "unknown login suite";
	}
	(p, n) := login->group(gid);
	hlen := Keyring->SHA256dlen;
	if(suite == Login->Aesgcm)
		hlen = Keyring->SHA384dlen;

	# The throttle, before the password is looked up or any exchange:
	# a name in its cooldown is refused, and this attempt is counted
	# until the client proves the password (cleared below).
	(rem, terr) := login->charge("logind", name);
	if(terr != nil){
		sys->fprint(stderr, "logind: login throttle: %s\n", terr);
		return "login service unavailable";
	}
	if(rem > 0){
		sys->fprint(stderr, "logind: refused %q: locked for %ds more\n", name, rem);
		auditlog("authlock", sys->sprint("user=%s reason=throttled remaining=%d", auditval(name), rem));
		return sys->sprint("login refused: too many failed attempts; retry in %ds", rem);
	}

	# Look up the password and expiry. A name that cannot log in -- no
	# account, one keyfs(4) refuses the secret of (disabled, expired),
	# an entry not a SHA-256, no expiry, the signer's own name -- is
	# answered as a wrong password is: the exchange goes on under a
	# random stand-in for the password's SHA-256, which no client has, so
	# its proof fails and it is told "name or secret incorrect", as for a
	# real name with a wrong password. The reason goes to the console
	# alone, and both paths do the same work: both lookups, the key
	# derivation, the expmods, the same messages.
	pw := getsecret(s);
	why := "";
	if(pw == nil)
		why = sys->sprint("no password entry for %s: %r", s);
	userexp := getexpiry(s);
	if(why == nil && len pw < Keyring->SHA256dlen)
		why = "bad password for "+s+": not SHA256 hashed?";
	if(why == nil && userexp < 0)
		why = sys->sprint("expiry time for %s: %r", s);
	# The signer's own name is certified by its key file alone: a
	# server that shows a certificate in that name (keysrv(4)) is taken
	# for the signer.
	if(why == nil && name == info.mypk.owner)
		why = "the signer's own name is not an account's";
	if(why != nil){
		sys->fprint(stderr, "logind: %s; answered as a wrong password\n", why);
		auditlog("authfail", sys->sprint("user=%s reason=unusable", auditval(name)));
		# the DRBG (#c/notquiterandom): ReallyRandom takes seconds, a
		# delay a wrong password does not have
		pw = rand->randombuf(Random->NotQuiteRandom, Keyring->SHA256dlen);
		userexp = 0;
	}
	pw = pw[0:Keyring->SHA256dlen];

	# Our Diffie-Hellman value, 2**r0 mod p, or p less it as a coin
	# falls.  2 generates the squares, so 2**r0 alone is always a
	# square, and whether a number is one can be computed: a guessed
	# password that unmasked the message below to a non-square would be
	# known wrong, half of them from each login watched.  With the sign
	# the value is uniform over 2..p-2, as a wrong guess's is (p's top
	# 64 bits are ones); the 2 in the exponents below takes it off.
	r0 := login->exponent(p);
	x := IPint.inttoip(2).expmod(r0, p);
	if(int login->nonce()[0] & 1)
		x = p.sub(x);

	# CA->user: version, suite, group, our nonce, and x under the
	# password's keystream: no tag, nothing a guess can be checked
	# against.  Our nonce is in the keystream's derivation, so the same
	# hello sent again gets another keystream.
	reply := array[3+Login->Noncelen+n] of byte;
	reply[0] = byte Login->Version;
	reply[1] = byte suite;
	reply[2] = byte gid;
	reply[3:] = login->nonce();
	reply[3+Login->Noncelen:] = login->mask(suite, gid, name, pw, hello[2:], reply[3:3+Login->Noncelen], login->bebytes(x, n));
	if(kr->putbytearray(c.dfd, reply, len reply) < 0)
		return sys->sprint("can't send masked (2**r0 mod p): %r");

	# user->CA: 2**r1 mod p and the client's proof.  Nothing made from
	# the secret leaves here before the proof is checked: what was sent
	# next under the secret's keys let a client that had chosen r1 try
	# passwords against it at leisure.
	msg: array of byte;
	(msg, err) = kr->getbytearray(c.dfd);
	if(err != nil){
		auditlog("authfail", sys->sprint("user=%s reason=exchange", auditval(name)));
		return "can't get 2**r1 mod p: "+err;
	}
	if(len msg != n+hlen){
		auditlog("authfail", sys->sprint("user=%s reason=exchange", auditval(name)));
		return "bad Diffie-Hellman message";
	}

	# The client's value must be one whose powers are not known to
	# all: with 0, 1 or p-1 (or p+1, which is 1) the secret was 0, 1 or
	# p-1 whatever r0 was, and a certificate went to anybody for any
	# name.  The range is SP 800-56A's (5.6.2.3.1); the order needs no
	# test, since p is a safe prime and the exponent is 2*r0: what is
	# left of any value in range is of order q.
	y := IPint.bytestoip(msg[0:n]);
	if(!login->inrange(y, p)){
		auditlog("authfail", sys->sprint("user=%s reason=badvalue", auditval(name)));
		return "bad Diffie-Hellman value";
	}
	z := login->bebytes(y.expmod(r0.shl(1), p), n);
	(cproof, sproof, sk) := login->keys(suite, name, pw, hello, reply, msg[0:n], z);

	# A name that cannot log in: no client has the stand-in, so none
	# has the proof; if one did, it is still refused, uncleared, unsigned.
	if(why != nil || !login->same(cproof, msg[n:])){
		if(why == nil)
			auditlog("authfail", sys->sprint("user=%s reason=secret", auditval(name)));
		return "name or secret incorrect";
	}

	# The client has the secret, which only the password gives: the
	# attempt is not a failure.  Our proof, then the rest under
	# aes_256_gcm, each way under its own secret.
	login->cleared("logind", name);
	if(kr->putbytearray(c.dfd, sproof, len sproof) < 0)
		return sys->sprint("can't send proof: %r");
	(secretin, secretout) := ssl->secrets(sk, 0);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return "can't set secrets: "+err;
	if(sys->fprint(c.cfd, "alg aes_256_gcm") < 0)
		return sys->sprint("can't push alg aes_256_gcm: %r");

	# send our public key, and the alpha and p of our key file: they
	# are not this exchange's (which uses login(6)'s groups whatever
	# the file has) but auth(2)'s, between holders of our certificates
	if(kr->putstring(c.dfd, kr->pktostr(kr->sktopk(info.mysk))) < 0)
		return sys->sprint("can't send signer's public key: %r");
	if(kr->putstring(c.dfd, info.alpha.iptob64()) < 0 ||
	   kr->putstring(c.dfd, info.p.iptob64()) < 0)
		return sys->sprint("can't send alpha, p: %r");

	# get his public key
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return "client public key: "+err;
	hisPKbuf := array of byte s;
	hisPK := kr->strtopk(s);
	if(hisPK == nil)
		return "client's public key is not a key";
	if(hisPK.owner != name)
		return "pk name doesn't match user name";

	# sign and return
	state := certdigest(info.mysk, hisPKbuf);
	cert := kr->sign(info.mysk, userexp, state, certhash(info.mysk));
	if(cert == nil)
		return "can't sign";

	if(kr->putstring(c.dfd, kr->certtostr(cert)) < 0)
		return sys->sprint("can't send certificate: %r");
	auditlog("authok", sys->sprint("user=%s exp=%d", auditval(name), userexp));

	return nil;
}

# CNSA 2.0 strict mode: the /env/cnsamode policy flag, as signer(8) reads it.
cnsamode(): int
{
	fd := sys->open("/env/cnsamode", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return 0;
	c := buf[0];
	return c != byte '0' && c != byte 'n' && c != byte 'N' && c != byte '\n';
}

nomod(mod: string)
{
	fatal(sys->sprint("can't load %s: %r",mod));
}

# CNSA 2.0: bind the certificate hash to the signing key's strength.
# ML-DSA / SLH-DSA (FIPS 204/205, NIST Cat >=3) keys pair with SHA-384;
# classical keys keep SHA-256 so pre-existing certs verify unchanged. The
# chosen name is stored in the certificate, so any verifier re-hashes to match.
certhash(sk: ref Keyring->SK): string
{
	if(sk != nil && sk.sa != nil)
		case sk.sa.name {
		"mldsa65" or "mldsa87" or "slhdsa192s" or "slhdsa256s" =>
			return "sha384";
		}
	return "sha256";
}

certdigest(sk: ref Keyring->SK, buf: array of byte): ref Keyring->DigestState
{
	if(certhash(sk) == "sha384")
		return kr->sha384(buf, len buf, nil, nil);
	return kr->sha256(buf, len buf, nil, nil);
}

fatal(msg: string)
{
	sys->fprint(stderr, "logind: %s\n", msg);
	exit;
}

signerkey(filename: string): (ref Keyring->Authinfo, string)
{

	info := kr->readauthinfo(filename);
	if(info == nil)
		return (nil, sys->sprint("readauthinfo %r"));

	# validate signer key
	# NOTE: The Inferno Certificate adt only has an 'exp' field;
	# unlike X.509 Validity (which has not_before/not_after),
	# there is no notBefore check possible here.  X.509 certificates
	# are properly validated via x509.b:is_expired() which checks both.
	now := daytime->now();
	if(info.cert.exp != 0 && info.cert.exp < now)
		return (nil, sys->sprint("signer key expired"));

	return (info, nil);
}

getsecret(id: string): array of byte
{
	fd := sys->open(sys->sprint("%s/%s/secret", keydb, id), Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return nil;
	return a[0:n];
}

getexpiry(id: string): int
{
	fd := sys->open(sys->sprint("%s/%s/expire", keydb, id), Sys->OREAD);
	if(fd == nil)
		return -1;
	a := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return -1;
	s := string a[0:n];
	if(s == "never")
		return 0;
	if(s == "expired"){
		sys->werrstr(sys->sprint("entry for %s expired", id));
		return -1;
	}
	return int s;
}

auditlog(event, msg: string)
{
	if(audit != nil)
		audit->log("logind", event, msg);
}

# a name the client sent, as one value of a record: quoted, it still read
# as more fields when it held a blank and a key of its own
auditval(s: string): string
{
	if(audit == nil)
		return "";
	return audit->value(s);
}

stalker(pidc: chan of int, killpid: int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(TimeLimit);
	sys->fprint(stderr, "logind: login timed out\n");
	kill(killpid, "killgrp");
}

kill(pid: int, how: string)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", how) < 0)
		sys->fprint(stderr, "logind: can't %s %d: %r\n", how, pid);
}
