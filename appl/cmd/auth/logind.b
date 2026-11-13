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
# Failed-attempt throttle (NIST SP 800-53 AC-7; CC FIA_AFL.1), as
# secstored(8) has: Maxfail logins in a row that do not prove the
# password lock the name for Locksecs, refused before any key exchange.
# A name that is no account is counted and locked the same way, and
# refused in the same words, so the throttle says nothing of who has an
# account.
#
# Each connection is a logind of its own (svc/auth: listen ...
# {auth/logind&}), so the counts cannot be in memory as secstored's
# are: they are in Failfile, read and written whole under Failfile.lock,
# made exclusively and removed on close, so a logind that dies holding
# it leaves nothing behind. An attempt is counted when it begins (the
# lock taken for it, before the exchange), and the count cleared only
# when the client has shown it has the session key, which only the
# password gives; so every other end -- a wrong password, a client that
# hangs up after the server's message, a value refused, a time out, a
# logind killed -- stays counted, and many connections opened at once
# for one name are counted as they start, not after they fail.
#
# Names are kept as the SHA-256 of the name, so the file holds no names
# and a name cannot break its lines. A count not added to for
# Forgetsecs is forgotten (AC-7's "during a time period"); past
# Maxentries the oldest unlocked counts are dropped, so names made up by
# the million do not make the file, which every login reads, grow
# without end. The file cannot be read or written, or its lock cannot be
# had: the login is refused (closed, not open).
#
Maxfail: con 10;	# attempts in a row not proving the password
Locksecs: con 60;	# then refused for this long
Forgetsecs: con 15*60;	# a count left this long is forgotten
Maxentries: con 4096;	# unlocked counts kept
Lockwait: con 5000;	# ms to wait for Failfile.lock
Lockstale: con 60;	# s: a lock older than this was left by a crash
failfile := "/keydb/loginfail";

Fail: adt {
	key:	string;	# hex SHA-256 of the name
	fails:	int;	# attempts in a row not proving the password
	last:	int;	# when the last began
	until:	int;	# refused until then; 0, not yet set
};

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

	rand = load Random Random->PATH;
	if(rand == nil)
		nomod(Random->PATH);

	audit = load Audit Audit->PATH;	# optional: the audit log
	if(audit != nil)
		audit->init();

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
	ivec: array of byte;

	(info, err) := signerkey("/keydb/signerkey");
	if(info == nil)
		return "can't read signer's own key: "+err;

	# get user name; ack
	s: string;
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return err;
	name := s;
	kr->putstring(c.dfd, name);

	# get initialization vector: its length says the client's AEAD
	# (login.b): 32 bytes, ChaCha20-Poly1305; 44, AES-256-GCM (CNSA)
	(ivec, err) = kr->getbytearray(c.dfd);
	if(err != nil)
		return "can't get initialization vector: "+err;
	gcm := 0;
	case len ivec {
	32 =>
		if(cnsamode())
			return "CNSA mode: this signer takes AES-256-GCM logins only; set cnsamode on the client";
	44 =>
		gcm = 1;
	* =>
		return "bad initialization vector length";
	}
	nsalt := len ivec - 12;

	# The throttle, before the password is looked up or any exchange:
	# a name in its cooldown is refused, and this attempt is counted
	# until the client proves the password (cleared below).
	key := failkey(name);
	(rem, terr) := charge(name, key);
	if(terr != nil)
		return "login throttle: " + terr;
	if(rem > 0){
		sys->fprint(stderr, "logind: refused %q: locked for %ds more\n", name, rem);
		auditlog("authlock", sys->sprint("user=%q reason=throttled remaining=%d", name, rem));
		return sys->sprint("login refused: too many failed attempts; retry in %ds", rem);
	}

	# Look up the password and expiry. A name that cannot log in -- no
	# account, one keyfs(4) refuses the secret of (disabled, expired),
	# an entry not a SHA-256, no expiry -- is answered as a wrong
	# password is: the exchange goes on under a random stand-in for the
	# password's SHA-256, which no client has, so it fails to decrypt
	# alpha**r0 and says "name or secret incorrect", as for a real name
	# with a wrong password. The reason goes to the console alone, and
	# both paths do the same work: both lookups, the key derivation, the
	# expmods, the same messages.
	pw := getsecret(s);
	why := "";
	if(pw == nil)
		why = sys->sprint("no password entry for %s: %r", s);
	userexp := getexpiry(s);
	if(why == nil && len pw < Keyring->SHA256dlen)
		why = "bad password for "+s+": not SHA256 hashed?";
	if(why == nil && userexp < 0)
		why = sys->sprint("expiry time for %s: %r", s);
	if(why != nil){
		sys->fprint(stderr, "logind: %s; answered as a wrong password\n", why);
		auditlog("authfail", sys->sprint("user=%q reason=unusable", name));
		# the DRBG (#c/notquiterandom): ReallyRandom takes seconds, a
		# delay a wrong password does not have
		pw = rand->randombuf(Random->NotQuiteRandom, Keyring->SHA256dlen);
		userexp = 0;
	}

	# generate our random diffie hellman part
	bits := info.p.bits();
	r0 := kr->IPint.random(bits/4, bits);

	# generate alpha0 = alpha**r0 mod p
	alphar0 := info.alpha.expmod(r0, info.p);

	# The AEAD's key from the stored SHA-256 of the password and the
	# salt, by HKDF as login.b derives it (loginkey).
	aeadkey := loginkey(gcm, pw[0:Keyring->SHA256dlen], ivec[0:nsalt]);
	nonce := ivec[nsalt:];

	# Send AEAD-encrypted alpha**r0 mod p
	plaintext := array of byte alphar0.iptob64();
	ciphertext, authtag: array of byte;
	if(gcm)
		(ciphertext, authtag) = kr->aesgcmencrypt(kr->aesgcmsetup(aeadkey, nonce), plaintext, nil);
	else
		(ciphertext, authtag) = kr->ccpolyencrypt(plaintext, nil, aeadkey, nonce);
	if(kr->putbytearray(c.dfd, ciphertext, len ciphertext) < 0)
		return sys->sprint("can't send encrypted (alpha**r0 mod p): %r");
	if(kr->putbytearray(c.dfd, authtag, len authtag) < 0)
		return sys->sprint("can't send auth tag: %r");

	# send alpha, p
	if(kr->putstring(c.dfd, info.alpha.iptob64()) < 0 ||
	   kr->putstring(c.dfd, info.p.iptob64()) < 0)
		return sys->sprint("can't send alpha, p: %r");

	# get alpha**r1 mod p
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return "can't get alpha**r1 mod p:"+err;
	alphar1 := kr->IPint.b64toip(s);

	# compute alpha**(r0*r1) mod p
	alphar0r1 := alphar1.expmod(r0, info.p);

	# protect the rest: aes_256_gcm, each way under its own secret
	(secretin, secretout) := ssl->secrets(alphar0r1.iptobytes(), 0);
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

	# A name that cannot log in: no client has the stand-in, so none
	# gets here; if one did, it is still refused, uncleared, unsigned.
	if(why != nil)
		return why;

	# The client's key came under the session's secrets: it has
	# alpha**(r0*r1), so it had the password. The attempt is not a failure.
	cleared(key);
	hisPKbuf := array of byte s;
	hisPK := kr->strtopk(s);
	if(hisPK.owner != name)
		return "pk name doesn't match user name";

	# sign and return
	state := certdigest(info.mysk, hisPKbuf);
	cert := kr->sign(info.mysk, userexp, state, certhash(info.mysk));

	if(kr->putstring(c.dfd, kr->certtostr(cert)) < 0)
		return sys->sprint("can't send certificate: %r");

	return nil;
}

# The AEAD key: HKDF-SHA-256 for ChaCha20-Poly1305, HKDF-SHA-384 for
# AES-256-GCM, 32 bytes either way; login.b's loginkey, the client's.
loginkey(gcm: int, ikm, salt: array of byte): array of byte
{
	info := "infernode login aead";
	dlen := Keyring->SHA256dlen;
	if(gcm){
		info = "infernode login aes-256-gcm";
		dlen = Keyring->SHA384dlen;
	}
	prk := array[dlen] of byte;
	t := array[dlen] of byte;
	inf := array of byte info;
	ex := array[len inf + 1] of byte;
	ex[0:] = inf;
	ex[len inf] = byte 1;
	if(gcm){
		kr->hmac_sha384(ikm, len ikm, salt, prk, nil);
		kr->hmac_sha384(ex, len ex, prk, t, nil);
	}else{
		kr->hmac_sha256(ikm, len ikm, salt, prk, nil);
		kr->hmac_sha256(ex, len ex, prk, t, nil);
	}
	return t[0:32];
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

auditlog(event, msg: string)
{
	if(audit != nil)
		audit->log("logind", event, msg);
}

# Count an attempt for key: the seconds it is still refused for (and
# then it is not counted), or 0 and the attempt counted. Counts reach
# Maxfail at most, and only one at Maxfail is refused.
charge(name, key: string): (int, string)
{
	(lk, err) := failock();
	if(lk == nil)
		return (0, err);
	now := daytime->now();
	fl := prune(loadfails(), now);
	e: ref Fail;
	for(l := fl; l != nil; l = tl l)
		if((hd l).key == key){
			e = hd l;
			break;
		}
	if(e != nil && e.fails >= Maxfail){
		# Maxfail attempts in a row, none proving the password: refused
		# for Locksecs from the last of them. The lock is set here, by
		# the attempt after them, so a last that worked locks nothing.
		if(e.until == 0){
			e.until = e.last + Locksecs;
			if(e.until > now){
				sys->fprint(stderr, "logind: %q locked after %d attempts not proving the password (%ds)\n", name, e.fails, Locksecs);
				auditlog("authlock", sys->sprint("user=%q fails=%d locksecs=%d", name, e.fails, Locksecs));
				err = storefails(fl);
				if(err != nil)
					return (0, err);
			}
		}
		if(e.until > now)
			return (e.until - now, nil);	# lk let go as it goes
		e.fails = 0;	# the cooldown is over: a fresh count
		e.until = 0;
	}
	if(e == nil){
		e = ref Fail(key, 0, 0, 0);
		fl = e :: fl;
	}
	e.fails++;
	e.last = now;
	err = storefails(fl);
	lk = nil;
	if(err != nil)
		return (0, err);
	return (0, nil);
}

# The password proved: key's count gone.
cleared(key: string)
{
	(lk, err) := failock();
	if(lk == nil){
		sys->fprint(stderr, "logind: can't clear a count: %s\n", err);
		return;
	}
	fl := loadfails();
	nl: list of ref Fail;
	found := 0;
	for(; fl != nil; fl = tl fl)
		if((hd fl).key == key)
			found = 1;
		else
			nl = hd fl :: nl;
	if(found){
		err = storefails(nl);
		if(err != nil)
			sys->fprint(stderr, "logind: can't clear a count: %s\n", err);
	}
	lk = nil;
}

# The counts still to keep at now: a lock run out and a count left
# Forgetsecs gone; past Maxentries unlocked, the oldest of those gone.
prune(fl: list of ref Fail, now: int): list of ref Fail
{
	locked, open: list of ref Fail;
	nopen := 0;
	for(; fl != nil; fl = tl fl){
		e := hd fl;
		if(e.fails >= Maxfail){
			until := e.until;
			if(until == 0)
				until = e.last + Locksecs;
			if(until > now)
				locked = e :: locked;
		}else if(now - e.last < Forgetsecs){
			open = e :: open;
			nopen++;
		}
	}
	if(nopen > Maxentries){
		a := array[nopen] of ref Fail;
		i := 0;
		for(; open != nil; open = tl open)
			a[i++] = hd open;
		sortlast(a);
		for(i = nopen - Maxentries; i < nopen; i++)
			open = a[i] :: open;
	}
	for(; open != nil; open = tl open)
		locked = hd open :: locked;
	return locked;
}

# oldest first, by last (Shell's sort)
sortlast(a: array of ref Fail)
{
	for(gap := len a / 2; gap > 0; gap /= 2)
		for(i := gap; i < len a; i++)
			for(j := i - gap; j >= 0 && a[j].last > a[j+gap].last; j -= gap)
				(a[j], a[j+gap]) = (a[j+gap], a[j]);
}

# Failfile's counts; a line that is not one (a torn write) is left out.
loadfails(): list of ref Fail
{
	fd := sys->open(failfile, Sys->OREAD);
	if(fd == nil)
		return nil;
	data := "";
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		data += string buf[0:n];
	fl: list of ref Fail;
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " ");
		if(nf != 4 || len hd f != 2*Keyring->SHA256dlen)
			continue;
		e := ref Fail(hd f, int hd tl f, int hd tl tl f, int hd tl tl tl f);
		if(e.fails <= 0)
			continue;
		fl = e :: fl;
	}
	return fl;
}

storefails(fl: list of ref Fail): string
{
	fd := sys->create(failfile, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("can't write %s: %r", failfile);
	s := "";
	for(; fl != nil; fl = tl fl){
		e := hd fl;
		s += sys->sprint("%s %d %d %d\n", e.key, e.fails, e.last, e.until);
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("can't write %s: %r", failfile);
	return nil;
}

# Failfile.lock, made exclusively and removed when its fd goes; one
# older than Lockstale (a host that went down holding it) is removed.
failock(): (ref Sys->FD, string)
{
	lf := failfile + ".lock";
	t0 := sys->millisec();
	for(;;){
		fd := sys->create(lf, Sys->OWRITE|Sys->OEXCL|Sys->ORCLOSE, 8r600);
		if(fd != nil)
			return (fd, nil);
		err := sys->sprint("%r");
		(ok, d) := sys->stat(lf);
		if(ok < 0){
			# not made and not there: the directory refuses it, unless
			# a holder let go between the two
			fd = sys->create(lf, Sys->OWRITE|Sys->OEXCL|Sys->ORCLOSE, 8r600);
			if(fd != nil)
				return (fd, nil);
			(ok, nil) = sys->stat(lf);
			if(ok < 0)
				return (nil, sys->sprint("can't make %s: %s", lf, err));
		}else if(daytime->now() - d.mtime > Lockstale)
			sys->remove(lf);
		if(sys->millisec() - t0 > Lockwait)
			return (nil, sys->sprint("%s held for %d ms", lf, Lockwait));
		sys->sleep(10);
	}
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
