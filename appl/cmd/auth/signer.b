implement Signer;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;
	IPint: import kr;

include "security.m";
	random: Random;
	login: Login;

include "daytime.m";
	daytime: Daytime;

Signer: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# the most one of Keyring's messages holds
Maxmsg:	con Keyring->Maxmsg;

# the least modulus of an RSA, ElGamal or DSA key that is certified
Minmodlen:	con 2048;

#
# A request waits in signed/owner for the operator's verify(8).  It is
# made by anybody who connects, before anything is known of them, so
# what one caller can cost the signer and the others is bounded:
#  - one request waits for a name at a time, and a second for that name
#    is refused while it does (it used to replace the first: the
#    operator then compared the second caller's digest, and the first,
#    reading theirs over the telephone, was turned away);
#  - a request the operator has not answered in Pendingsecs is gone,
#    so a name is not held for ever by a request nobody will approve;
#  - Maxpending requests wait at most;
#  - requests are counted by login(2)'s throttle under a name no
#    account can have: ten in a row and the next are refused for a
#    minute;
#  - the pad is from the system's DRBG (#c/notquiterandom, HMAC_DRBG),
#    not /dev/random, a read of which can take seconds and which every
#    request then held.
#
Pendingsecs:	con 15*60;
Maxpending:	con 256;
Throttlename:	con "signer/requests";	# okname refuses it: no account's

stderr, stdin, stdout: ref Sys->FD;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	random = load Random Random->PATH;
	kr = load Keyring Keyring->PATH;
	login = load Login Login->PATH;

	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	sys->pctl(Sys->FORKNS, nil);
	if(sys->chdir("/keydb") < 0){
		sys->fprint(stderr, "signer: no key database\n");
		raise "fail:no keydb";
	}
	if(login == nil){
		sys->fprint(stderr, "signer: can't load %s: %r\n", Login->PATH);
		raise "fail:load";
	}

	daytime = load Daytime Daytime->PATH;
	if(daytime == nil){
		sys->fprint(stderr, "signer: can't load %s: %r\n", Daytime->PATH);
		raise "fail:load";
	}

	(err, why) := sign();
	if(err != nil){
		sys->fprint(stderr, "signer: %s\n", err);
		# and the caller is told, in words it can show: a refusal
		# was a connection that closed
		if(why != nil)
			kr->senderrmsg(stdout, why);
		raise "fail:error";
	}
}

# What went wrong, for the console, and what the caller is told of it
# (nil: nothing, the fault is the signer's own).
sign(): (string, string)
{
	(info, kerr) := signerkey("signerkey");
	if(info == nil)
		return (kerr, "signing service unavailable");
	cnsa := login->cnsamode();
	if(cnsa && (kerr = login->cnsakey(info)) != nil)
		return ("CNSA mode: /keydb/signerkey is not taken: " + kerr + "; make one with createsignerkey -c",
			"signing service unavailable: signer's key is not CNSA's");

	# the throttle and the room, before any work is done for the caller
	(rem, terr) := login->charge("signer", Throttlename);
	if(terr != nil)
		return ("throttle: " + terr, "signing service unavailable");
	if(rem > 0)
		return (sys->sprint("too many requests: refusing for %ds more", rem),
			sys->sprint("too many requests; retry in %ds", rem));
	now := daytime->now();
	if(pending(now) >= Maxpending)
		return ("too many requests pending in /keydb/signed", "too many requests pending");

	# send public part to client
	mypkbuf := array of byte kr->pktostr(kr->sktopk(info.mysk));
	alphabuf := array of byte info.alpha.iptob64();
	pbuf := array of byte info.p.iptob64();
	if(kr->sendmsg(stdout, mypkbuf, len mypkbuf) < 0 ||
	   kr->sendmsg(stdout, alphabuf, len alphabuf) < 0 ||
	   kr->sendmsg(stdout, pbuf, len pbuf) < 0)
		return (sys->sprint("can't send key: %r"), nil);

	# get client's public key
	hisPKbuf := kr->getmsg(stdin);
	if(hisPKbuf == nil)
		return ("caller hung up", nil);
	hisPK := kr->strtopk(string hisPKbuf);
	if(hisPK == nil)
		return ("illegal caller PK", "that is not a public key");

	# The key's owner becomes the name of a file here (signed/owner)
	# and of an account in the certificate, so it must be one name
	# (login(6)) before anything is signed or made: an owner of
	# ../signerkey had the request's record written over the signer's
	# own key, by anybody who connected.
	err := login->okname(hisPK.owner);
	if(err != nil)
		return ("illegal owner name: " + err, "illegal owner name: " + err);
	# the signer's own name is certified by its key file alone, and
	# "*" is the name of a key that is nobody's
	if(hisPK.owner == info.mypk.owner || hisPK.owner == "*")
		return ("illegal owner name: the signer's own, or *", "illegal owner name");

	# The key certified is like the signer's (its algorithm; a modulus
	# no shorter than is still taken for a signature): any key that
	# parsed was signed.
	if(hisPK.sa == nil || hisPK.sa.name != info.mypk.sa.name)
		return ("caller's key is not of the signer's algorithm (" + info.mypk.sa.name + ")",
			"key is not of the signer's algorithm (" + info.mypk.sa.name + ")");
	bits := modbits(hisPK);
	if(bits != 0 && bits < Minmodlen)
		return (sys->sprint("caller's key has a modulus of %d bits", bits),
			sys->sprint("a key of %d bits is not certified: %d at least", bits, Minmodlen));

	# One request waits for a name.  One the operator has left for
	# Pendingsecs is gone; otherwise this caller is refused, and the
	# first keeps its place.
	file := "signed/"+hisPK.owner;
	(ok, d) := sys->stat(file);
	if(ok >= 0){
		if(now - d.mtime >= 0 && now - d.mtime < Pendingsecs)
			return ("a request for " + hisPK.owner + " is already pending", "a request for that name is already pending");
		sys->remove(file);
	}

	# hash, sign, and blind
	state := certdigest(info.mysk, hisPKbuf);
	cert := kr->sign(info.mysk, 0, state, certhash(info.mysk));
	if(cert == nil)
		return ("can't sign", "signing service unavailable");

	# sanity clause
	state = certdigest(info.mysk, hisPKbuf);
	if(kr->verify(info.mypk, cert, state) == 0)
		return ("bad signer certificate", "signing service unavailable");

	# A certificate that does not fit a message (an ML-DSA-87
	# signature is 4627 bytes) cannot be sent, and was found out only
	# after its record had been left in signed/.
	certbuf := array of byte kr->certtostr(cert);
	if(len certbuf > Maxmsg)
		return (sys->sprint("certificate of %d bytes is more than a message holds (%d)", len certbuf, Maxmsg),
			"certificate does not fit a message");
	blind: array of byte;
	{
		blind = random->randombuf(Random->NotQuiteRandom, len certbuf);
	} exception e {
	"random:*" =>
		return (e, "signing service unavailable");
	}
	for(i := 0; i < len blind; i++)
		certbuf[i] = certbuf[i] ^ blind[i];

	# The digest the caller reads to the operator: the two keys and
	# the blinded certificate under SHA-256 (it was MD5; what it must
	# resist is somebody else's request showing this caller's digest).
	state = kr->sha256(mypkbuf, len mypkbuf, nil, nil);
	kr->sha256(hisPKbuf, len hisPKbuf, nil, state);
	digest := array[Keyring->SHA256dlen] of byte;
	kr->sha256(certbuf, len certbuf, digest, state);

	# save sum and blinded cert in a file, which must not be there
	fd := sys->create(file, Sys->OWRITE|Sys->OEXCL, 8r600);
	if(fd == nil)
		return ("can't create "+file+sys->sprint(": %r"), "a request for that name is already pending");
	if(kr->sendmsg(fd, blind, len blind) < 0 ||
	   kr->sendmsg(fd, digest, len digest) < 0){
		sys->remove(file);
		return ("can't write "+file+sys->sprint(": %r"), "signing service unavailable");
	}

	# send blinded cert to client
	fd = nil;
	if(kr->sendmsg(stdout, certbuf, len certbuf) < 0){
		sys->remove(file);
		return (sys->sprint("can't send certificate: %r"), nil);
	}

	return (nil, nil);
}

# How many requests wait; those left longer than Pendingsecs are
# removed on the way.
pending(now: int): int
{
	fd := sys->open("signed", Sys->OREAD);
	if(fd == nil)
		return 0;
	n := 0;
	for(;;){
		(nd, dirs) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			d := dirs[i];
			if(d.mode & Sys->DMDIR)
				continue;
			if(now - d.mtime >= Pendingsecs)
				sys->remove("signed/" + d.name);
			else
				n++;
		}
	}
	return n;
}

# The bits of an RSA, ElGamal or DSA key's modulus (the first number of
# its text, keytext(6)); 0 for a key of one size.
modbits(pk: ref Keyring->PK): int
{
	case pk.sa.name {
	"rsa" or "elgamal" or "dsa" =>
		;
	* =>
		return 0;
	}
	(nil, flds) := sys->tokenize(kr->pktostr(pk), "\n");
	if(len flds < 3)
		return 1;
	n := IPint.b64toip(hd tl tl flds);
	if(n == nil)
		return 1;
	return n.bits();
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

# The signer's key, which createsignerkey(8) makes.  With no file that
# read as one, a key was made here and written in its place, whatever
# the reason the file did not read: a signer started with a damaged
# file, or with none, replaced the realm's key with a new one owned by
# "*" and said nothing, and every certificate issued before was an
# orphan.
signerkey(filename: string): (ref Keyring->Authinfo, string)
{
	info := kr->readauthinfo(filename);
	if(info == nil)
		return (nil, sys->sprint("can't read /keydb/%s: %r: make the signer's key with auth/createsignerkey", filename));
	now := daytime->now();
	if(info.cert != nil && info.cert.exp != 0 && info.cert.exp < now)
		return (nil, "the signer's key has expired");
	return (info, nil);
}
