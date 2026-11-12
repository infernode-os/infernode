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

include "daytime.m";
	daytime: Daytime;

include "loginpak.m";
	pak: Loginpak;
	Server: import pak;

Logind: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

TimeLimit: con 5*60*1000;	# five minutes
keydb := "/mnt/keys";

stderr: ref Sys->FD;
 
init(nil: ref Draw->Context, nil: list of string)
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

	pak = load Loginpak Loginpak->PATH;
	if(pak == nil)
		nomod(Loginpak->PATH);
	if((e := pak->init()) != nil)
		fatal(e);

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

dologin(c: ref Sys->Connection): string
{
	(info, err) := signerkey("/keydb/signerkey");
	if(info == nil)
		return "can't read signer's own key: "+err;

	# get the protocol version and key encapsulation; answer the version
	s: string;
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return err;
	(nf, flds) := sys->tokenize(s, " ");
	if(nf != 2 || hd flds != Loginpak->Version)
		return "this signer speaks only login(6)'s " + Loginpak->Version + " protocol; the client is older";
	kem := hd tl flds;
	case kem {
	"mlkem768" =>
		if(cnsamode())
			return "CNSA mode: this signer takes ML-KEM-1024 logins only; set cnsamode on the client";
	"mlkem1024" =>
		;
	* =>
		return "unknown key encapsulation " + kem;
	}
	if(kr->putstring(c.dfd, Loginpak->Version) < 0)
		return sys->sprint("can't send version: %r");

	# get name, m, ek
	name, hexm: string;
	ek: array of byte;
	(name, err) = kr->getstring(c.dfd);
	if(err == nil)
		(hexm, err) = kr->getstring(c.dfd);
	if(err == nil)
		(ek, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return "can't get the password exchange: "+err;

	# The user's element of the group, from the password's SHA-256 as
	# changelogin(8) keeps it. A name with no entry gets one from a
	# random secret, made the same way at the same cost, and the
	# exchange runs on to fail at k' as a wrong password does: neither
	# what is sent nor when says whether the name exists.
	why: string;
	pw := getsecret(name);
	if(pw == nil)
		why = sys->sprint("no password entry for %s", name);
	else if(len pw < Keyring->SHA256dlen)
		why = "bad password for "+name+": not SHA256 hashed?";
	if(why != nil){
		rand := load Random Random->PATH;
		if(rand == nil)
			return sys->sprint("can't load %s: %r", Random->PATH);
		pw = rand->randombuf(Random->ReallyRandom, Keyring->SHA256dlen);
	}
	H := pak->pwelem(name, pw[0:Keyring->SHA256dlen]);
	userexp := getexpiry(name);

	(ps, hexmu, ct, k, perr) := Server.new(kem, name, H, hexm, ek);
	if(ps == nil)
		return perr;
	if(kr->putstring(c.dfd, hexmu) < 0 ||
	   kr->putbytearray(c.dfd, ct, len ct) < 0 ||
	   kr->putbytearray(c.dfd, k, len k) < 0)
		return sys->sprint("can't send mu, ct, k: %r");

	# get k'; with no entry, nothing proves it
	kprime: array of byte;
	(kprime, err) = kr->getbytearray(c.dfd);
	if(err != nil || why != nil || !ps.check(kprime)){
		if(why != nil)
			sys->fprint(stderr, "logind: %s\n", why);
		return "name or secret incorrect";
	}
	# the password is proved: say why no certificate, now it tells nothing
	if(userexp < 0)
		return sys->sprint("expiry time for %s: %r", name);
	if(kr->putstring(c.dfd, "ok") < 0)
		return sys->sprint("can't send ok: %r");

	# protect the rest: aes_256_gcm, each way under its own secret
	(secretin, secretout) := ssl->secrets(ps.session, 0);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return "can't set secrets: "+err;
	if(sys->fprint(c.cfd, "alg aes_256_gcm") < 0)
		return sys->sprint("can't push alg aes_256_gcm: %r");

	# send our public key
	if(kr->putstring(c.dfd, kr->pktostr(kr->sktopk(info.mysk))) < 0)
		return sys->sprint("can't send signer's public key: %r");

	# get his public key
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return "client public key: "+err;
	hisPKbuf := array of byte s;
	hisPK := kr->strtopk(s);
	if(hisPK == nil || hisPK.owner != name)
		return "pk name doesn't match user name";

	# sign and return, with the Diffie-Hellman constants an Authinfo carries
	state := certdigest(info.mysk, hisPKbuf);
	cert := kr->sign(info.mysk, userexp, state, certhash(info.mysk));

	if(kr->putstring(c.dfd, kr->certtostr(cert)) < 0 ||
	   kr->putstring(c.dfd, info.alpha.iptob64()) < 0 ||
	   kr->putstring(c.dfd, info.p.iptob64()) < 0)
		return sys->sprint("can't send certificate: %r");

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
