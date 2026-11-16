implement Keysrv;

#
# remote access to keys (currently only to change secret)
#
# Copyright © 2003 Vita Nuova Holdings Limited.  All rights reserved.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;
	login: Login;

include "audit.m";
	audit: Audit;

include "arg.m";

keydb := "/mnt/keys";

#
# The file's protocol, version 2 (keysrv(4)).  A read gives a challenge,
# fresh after every write:
#	keysrv 2 <challenge: 32 bytes in hex>
# and a write answers it:
#	<proof> [<new secret>]
# with, for the secret keyfs(4) holds (the SHA-256 of the password),
#	PRK = HMAC-SHA-384(challenge, secret)
#	proof = HKDF-Expand(PRK, "infernode keysrv 2 proof" || user, 48)
#	key || nonce = HKDF-Expand(PRK, "infernode keysrv 2 new secret" || user, 44)
#	new secret = AES-256-GCM(key, nonce, SHA-256 of the new password)
# each in hex.  The proof was the hash of the stored secret, the same
# every time: whoever was once sent it could send it again.  The new
# secret came as typed and was stored so, which no login then matched.
#
Version: con "keysrv 2 ";
Challen: con 32;
Prooflen: con Keyring->SHA384dlen;
Sealedlen: con Keyring->SHA256dlen + 16;
Maxwrong: con 5;	# wrong proofs in one session, then no more are taken

Keysrv: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2), "usage: keysrv [-k keyfile]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(sys->pctl(Sys->FORKNS|Sys->NEWPGRP, nil) < 0)
		err(sys->sprint("can't fork name space: %r"));

	# The signer's own key, so that a client can tell this is the
	# signer's key server: with a user's key (the default was the
	# invoking user's) any holder of a certificate looked the same.
	keyfile := "/keydb/signerkey";

	arg := load Arg Arg->PATH;
	if(arg == nil)
		err("can't load Arg");
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		'k' =>
			keyfile = arg->arg();
			if(keyfile == nil)
				usage();
		* =>
			usage();
		}
	args = arg->argv();
	arg = nil;

	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		err("can't load Keyring");

	auth = load Auth Auth->PATH;
	if(auth == nil)
		err("can't load Auth");
	auth->init();

	login = load Login Login->PATH;
	if(login == nil)
		err("can't load Login");

	audit = load Audit Audit->PATH;	# optional: the audit log
	if(audit != nil)
		audit->init();

	ai := kr->readauthinfo(keyfile);
	if(ai == nil)
		err(sys->sprint("can't read server key file %s: %r", keyfile));

	(fd, id_or_err) := auth->server("aes_256_gcm" :: nil, ai, sys->fildes(0), 0);
	if(fd == nil)
		err(sys->sprint("can't authenticate: %s", id_or_err));

	if(sys->bind("#s", "/mnt/keysrv", Sys->MREPL) < 0)
		err(sys->sprint("can't bind #s on /mnt/keysrv: %r"));
	srv := sys->file2chan("/mnt/keysrv", "secret");
	if(srv == nil)
		err(sys->sprint("can't create file2chan on /mnt/keysrv: %r"));
	exitc := chan of int;
	spawn worker(srv, id_or_err, exitc);
	if(sys->export(fd, "/mnt/keysrv", Sys->EXPWAIT) < 0){
		exitc <-= 1;
		err(sys->sprint("can't export %s: %r", "/mnt/keysrv"));
	}
	exitc <-= 1;
}

err(s: string)
{
	sys->fprint(sys->fildes(2), "keysrv: %s\n", s);
	raise "fail:error";
}

user(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		err(sys->sprint("can't open /dev/user: %r"));

	buf := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		err(sys->sprint("error reading /dev/user: %r"));

	return string buf[0:n];	
}

auditlog(event, msg: string)
{
	if(audit != nil)
		audit->log("keysrv", event, msg);
}

auditval(s: string): string
{
	if(audit == nil)
		return "";
	return audit->value(s);
}

worker(file: ref Sys->FileIO, user: string, exitc: chan of int)
{
	# The certificate's name is a directory of keyfs here: one name,
	# as logind takes (certificates were issued for x/../alice).
	err := login->okname(user);
	if(err != nil)
		err = "bad user name: " + err;
	chal := login->nonce();
	wrong := 0;
	# The stored secret, the proof wanted, the key a new secret comes
	# under and the new secret are each zeroed when the request that
	# read or made them has been answered: they stayed in the heap for
	# as long as the session, and after.
	w: list of array of byte;
	for(;;){
	for(; w != nil; w = tl w)
		login->zero(hd w);
	alt{
	<-exitc =>
		exit;
	(offset, count, nil, rc) := <-file.read =>
		if(rc == nil)
			break;
		if(err == nil){
			# the user as it is now, not as it was when the session began
			(keydir, secret, e) := getuser(user);
			w = secret :: w;
			if(e == nil && (keydir == nil || secret == nil))
				e = "no existing secret";		# can't change it remotely until set
			if(e != nil){
				rc <-= (nil, e);
				break;
			}
		}
		if(err != nil){
			rc <-= (nil, err);
			break;
		}
		b := array of byte (Version + hex(chal));
		if(offset >= len b)
			rc <-= (nil, nil);
		else{
			if(offset + count > len b)
				count = len b - offset;
			rc <-= (b[offset:offset+count], nil);
		}
	(nil, data, nil, wc) := <-file.write =>
		if(wc == nil)
			break;
		if(err != nil){
			wc <-= (0, err);
			break;
		}
		(nf, flds) := sys->tokenize(string data, " ");
		if(nf < 1 || nf > 2 || len hd flds != 2*Prooflen){
			wc <-= (0, "keysrv speaks version 2 (keysrv(4)); update passwd");
			break;
		}
		proof := unhex(hd flds);
		sealed: array of byte;
		if(nf == 2)
			sealed = unhex(hd tl flds);
		if(proof == nil || (nf == 2 && (sealed == nil || len sealed != Sealedlen))){
			wc <-= (0, "bad proof or secret");
			break;
		}

		# A challenge answers one write.  A wrong proof is counted
		# where logind counts wrong passwords (they are guesses at the
		# same thing, and were unlimited here), and a session takes
		# only so many.
		c := chal;
		chal = login->nonce();
		(rem, terr) := login->charge("keysrv", user);
		if(terr != nil){
			sys->fprint(sys->fildes(2), "keysrv: throttle: %s\n", terr);
			wc <-= (0, "key service unavailable");
			break;
		}
		if(rem > 0){
			auditlog("authlock", sys->sprint("user=%s reason=throttled remaining=%d", auditval(user), rem));
			wc <-= (0, sys->sprint("refused: too many failed attempts; retry in %ds", rem));
			break;
		}
		# the secret as it is now: one changed since the session began
		# (by an operator, or by this session) is the one to prove
		(keydir, secret, e) := getuser(user);
		w = secret :: w;
		if(e == nil && (keydir == nil || secret == nil))
			e = "no existing secret";
		if(e != nil){
			wc <-= (0, e);
			break;
		}
		(want, key) := answers(c, secret, user);
		w = want :: key :: w;
		if(!login->same(proof, want)){
			auditlog("authfail", sys->sprint("user=%s reason=secret", auditval(user)));
			if(++wrong >= Maxwrong)
				err = "too many wrong secrets in this session";
			wc <-= (0, "wrong secret");
			break;
		}
		login->cleared("keysrv", user);
		if(nf == 1){
			wc <-= (0, nil);
			break;
		}
		newsecret := kr->aesgcmdecrypt(kr->aesgcmsetup(key[0:32], key[32:]), sealed[0:Keyring->SHA256dlen], array of byte Wraplabel, sealed[Keyring->SHA256dlen:]);
		w = newsecret :: w;
		if(newsecret == nil || len newsecret != Keyring->SHA256dlen){
			wc <-= (0, "unacceptable secret");
			break;
		}
		if(putsecret(keydir, newsecret) != len newsecret){
			wc <-= (0, sys->sprint("can't update secret: %r"));
			break;
		}
		auditlog("secretchange", sys->sprint("user=%s", auditval(user)));
		wc <-= (len data, nil);
	}
	}
}

Prooflabel: con "infernode keysrv 2 proof";
Wraplabel: con "infernode keysrv 2 new secret";

# the proof of secret for challenge c, and the key and nonce a new
# secret is sealed under
answers(c, secret: array of byte, user: string): (array of byte, array of byte)
{
	prk := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(secret, len secret, c, prk, nil);
	proof := expand(prk, array of byte (Prooflabel + user), Prooflen);
	key := expand(prk, array of byte (Wraplabel + user), 32+12);
	login->zero(prk);
	return (proof, key);
}

# HKDF-Expand (RFC 5869 2.3) with HMAC-SHA-384: one block is enough
expand(prk, info: array of byte, n: int): array of byte
{
	t := array[Keyring->SHA384dlen] of byte;
	b := array[len info + 1] of byte;
	b[0:] = info;
	b[len info] = byte 1;
	kr->hmac_sha384(b, len b, prk, t, nil);
	# a copy: a slice left the rest of the block behind its result
	r := array[n] of byte;
	r[0:] = t[0:n];
	login->zero(t);
	return r;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%2.2ux", int a[i]);
	return s;
}

unhex(s: string): array of byte
{
	if(len s % 2 != 0)
		return nil;
	a := array[len s/2] of byte;
	for(i := 0; i < len a; i++){
		h := hexval(s[2*i]);
		l := hexval(s[2*i+1]);
		if(h < 0 || l < 0)
			return nil;
		a[i] = byte (h<<4 | l);
	}
	return a;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

getuser(id: string): (string, array of byte, string)
{
	(ok, nil) := sys->stat(keydb);
	if(ok < 0)
		return (nil, nil, sys->sprint("can't stat %s: %r", id));
	dbdir := keydb+"/"+id;
	(ok, nil) = sys->stat(dbdir);
	if(ok < 0)
		return (nil, nil, sys->sprint("user not registered: %s", id));
	fd := sys->open(dbdir+"/secret", Sys->OREAD);
	if(fd == nil)
		return (nil, nil, sys->sprint("can't open %s/secret: %r", id));
	d: Sys->Dir;
	(ok, d) = sys->fstat(fd);
	if(ok < 0)
		return (nil, nil, sys->sprint("can't stat %s/secret: %r", id));
	l := int d.length;
	secret: array of byte;
	if(l > 0){
		secret = array[l] of byte;
		if(sys->read(fd, secret, len secret) != len secret)
			return (nil, nil, sys->sprint("error reading %s/secret: %r", id));
	}
	return (dbdir, secret, nil);
}

putsecret(dir: string, secret: array of byte): int
{
	fd := sys->create(dir+"/secret", Sys->OWRITE, 8r600);
	if(fd == nil)
		return -1;
	return sys->write(fd, secret, len secret);
}
