implement Login;

#
# The client of login(6): the password proved to the signer by PAK
# with ML-KEM (loginpak.b), then a key pair made here and its public
# half certified, over ssl(3) under the exchange's session key.
# The protocol before it, Lucent's encrypted key exchange, is gone.
#

include "sys.m";
	sys: Sys;

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";

include "string.m";

include "loginpak.m";
	pak: Loginpak;
	Client: import pak;

# see login(6)
login(id, password, dest: string): (string, ref Keyring->Authinfo)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return nomod(Keyring->PATH);

	ssl := load SSL SSL->PATH;
	if(ssl == nil)
		return nomod(SSL->PATH);

	pak = load Loginpak Loginpak->PATH;
	if(pak == nil)
		return nomod(Loginpak->PATH);
	if((e := pak->init()) != nil)
		return (e, nil);

	if(dest == nil)
		dest = "$SIGNER";
	# Check if dest already has dial address format (contains '!')
	hasdelim := 0;
	for(j := 0; j < len dest; j++)
		if(dest[j] == '!'){
			hasdelim = 1;
			break;
		}
	if(!hasdelim)
		dest = "net!"+dest+"!inflogin";

	# the expensive part before dialling, as secstore does
	kem := pak->kemname(cnsamode());
	pwbuf := array of byte password;
	pw := array[Keyring->SHA256dlen] of byte;
	kr->sha256(pwbuf, len pwbuf, pw, nil);
	erase(pwbuf);
	(pc, perr) := Client.new(kem, id, pw);
	erase(pw);
	if(pc == nil)
		return (perr, nil);

	(ok, lc) := sys->dial(dest, nil);
	if(ok < 0)
		return (sys->sprint("can't contact login service: %r"), nil);

	# push ssl, leave in clear mode for now
	(err, c) := ssl->connect(lc.dfd);
	if(c == nil)
		return ("can't push ssl: " + err, nil);
	lc.dfd = nil;
	lc.cfd = nil;

	# user->CA	version and key encapsulation
	hello := Loginpak->Version + " " + kem;
	if(kr->putstring(c.dfd, hello) < 0)
		return (sys->sprint("can't send protocol version: %r"), nil);

	# CA->user	version
	(s, why) := kr->getstring(c.dfd);
	if(why != nil)
		return ("remote: " + why, nil);
	if(s == hello)
		return ("the signer speaks only the old login protocol, which can give away the password; upgrade its logind", nil);
	if(s != Loginpak->Version)
		return ("unexpected reply from signer: " + s, nil);

	# user->CA	name, m, ek
	if(kr->putstring(c.dfd, id) < 0 ||
	   kr->putstring(c.dfd, pc.m) < 0 ||
	   kr->putbytearray(c.dfd, pc.ek, len pc.ek) < 0)
		return (sys->sprint("can't send the password exchange: %r"), nil);

	# CA->user	mu, ct, k
	ct, k: array of byte;
	(s, err) = kr->getstring(c.dfd);
	if(err == nil)
		(ct, err) = kr->getbytearray(c.dfd);
	if(err == nil)
		(k, err) = kr->getbytearray(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect", nil);
		return ("remote: " + err, nil);
	}

	(kp, rerr) := pc.respond(s, ct, k);
	if(kp == nil){
		kr->puterror(c.dfd, "name or secret incorrect");
		return (rerr, nil);
	}

	# user->CA	k'
	if(kr->putbytearray(c.dfd, kp, len kp) < 0)
		return (sys->sprint("can't send k': %r"), nil);

	# CA->user	ok, or why not
	(s, err) = kr->getstring(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect", nil);
		return ("remote: " + err, nil);
	}
	if(s != "ok")
		return ("unexpected reply from signer: " + s, nil);

	# protect the rest: aes_256_gcm, each way under its own secret
	(secretin, secretout) := ssl->secrets(pc.session, 1);
	erase(pc.session);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return ("can't set secrets: " + err, nil);
	if(sys->fprint(c.cfd, "alg aes_256_gcm") < 0)
		return (sys->sprint("can't push alg aes_256_gcm: %r"), nil);

	# CA->user	CA's public key
	(s, err) = kr->getstring(c.dfd);
	if(err != nil){
		if(err == "failure")
			return ("name or secret incorrect", nil);
		return ("remote: " + err, nil);
	}

	info := ref Keyring->Authinfo;
	info.spk = kr->strtopk(s);
	if(info.spk == nil)
		return ("bad signer's public key", nil);

	# generate a key pair
	info.mysk = kr->genSKfromPK(info.spk, id);
	info.mypk = kr->sktopk(info.mysk);

	# user->CA	user's public key
	if(kr->putstring(c.dfd, kr->pktostr(info.mypk)) < 0)
		return (sys->sprint("can't send your public: %r"), nil);

	# CA->user	user's public key certificate, alpha, p
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get certificate: " + err, nil);
	info.cert = kr->strtocert(s);

	# the Diffie-Hellman constants an Authinfo carries for Keyring->auth
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get alpha: " + err, nil);
	info.alpha = IPint.b64toip(s);
	(s, err) = kr->getstring(c.dfd);
	if(err != nil)
		return ("can't get p: " + err, nil);
	info.p = IPint.b64toip(s);
	if(info.alpha == nil || info.p == nil || info.alpha.bits() > info.p.bits() || info.alpha.bits() < 2)
		return ("bogus diffie hellman constants", nil);
	return(nil, info);
}

erase(a: array of byte)
{
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
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

nomod(mod: string): (string, ref Keyring->Authinfo)
{
	return (sys->sprint("can't load module %s: %r", mod), nil);
}
