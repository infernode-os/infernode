implement Passwd;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;

include "arg.m";

Passwd: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr, stdin, stdout: ref Sys->FD;
keysrv := "/mnt/keysrv";
signer := "$SIGNER";

usage()
{
	sys->fprint(sys->fildes(2), "usage: passwd [-u user] [-s signer] [keyfile]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		noload(Keyring->PATH);
	auth = load Auth Auth->PATH;
	if(auth == nil)
		noload(Auth->PATH);
	auth->init();

	keyfile, id: string;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		noload(Arg->PATH);
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		's' =>
			signer = arg->arg();
		'u' =>
			id = arg->arg();
		* =>
			usage();
		}
	args = arg->argv();
	arg = nil;

	if(args == nil)
		args = "default" :: nil;

	if(id == nil)
		id= user();

	if(args != nil)
		keyfile = hd args;
	else
		keyfile = "default";
	if(len keyfile > 0 && keyfile[0] != '/')
		keyfile = "/usr/" + id + "/keyring/" + keyfile;

	ai := kr->readauthinfo(keyfile);
	if(ai == nil)
		err(sys->sprint("can't read certificate from %s: %r", keyfile));
	if(ai.spk == nil || ai.mypk == nil)
		err(sys->sprint("%s has no signer's key", keyfile));

	# The key server must be the signer of this certificate: it is
	# about to be given a proof of the old secret and the new one.  The
	# authentication alone says only that the far end holds some
	# certificate of the signer's, as every user of the realm does, and
	# the name it gave was thrown away; keysrv(4) runs with the signer's
	# own key, whose name logind(8) and signer(8) certify for nobody.
	sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
	srvid := mountsrv(ai);
	if(srvid != ai.spk.owner)
		err(sys->sprint("%s authenticated as %q, not as %q, the signer of %s: nothing sent", signer, srvid, ai.spk.owner, keyfile));
	user := ai.mypk.owner;

	# get password
	ok: int;
	old: array of byte;
	word: string;
	for(;;){
		sys->print("Inferno secret: ");
		(ok, word) = readline(stdin, "rawon");
		if(!ok)
			err("can't read the secret");
		if(word == nil)
			err("no secret given; nothing changed");
		old = hashpw(word);
		word = blank(word);
		e := putsecret(user, old, nil);
		if(e != "wrong secret"){
			if(e == nil)
				break;
			err(e);
		}
		sys->fprint(stderr, "!wrong secret\n");
	}
	for(;;){
		for(;;){
			sys->print("new secret [default = don't change]: ");
			(ok, word) = readline(stdin, "rawon");
			if(!ok)
				err("can't read the new secret; nothing changed");
			if(word == "")
				break;
			if(len word >= 8)
				break;
			sys->print("!secret must be at least 8 characters\n");
		}
		if(word == ""){
			sys->print("secret not changed\n");
			break;
		}
		# confirm password change
		word1 := word;
		sys->print("confirm: ");
		(ok, word) = readline(stdin, "rawon");
		if(!ok || word != word1){
			word = blank(word);
			word1 = blank(word1);
			sys->fprint(stderr, "!entries didn't match\n");
			if(!ok)
				err("can't read the new secret again; nothing changed");
			continue;
		}
		# What keyfs holds, and login(6) uses, is the SHA-256 of the
		# password: the password itself was sent and stored, and the
		# account could not log in again.
		new := hashpw(word);
		word = blank(word);
		word1 = blank(word1);
		if(eq(new, old)){
			sys->print("secret not changed\n");
			break;
		}
		if((e := putsecret(user, old, new)) != nil){
			sys->fprint(stderr, "passwd: can't update secret for %s: %s\n", user, e);
			raise "fail:error";
		}
		sys->print("secret changed\n");
		break;
	}
}

noload(s: string)
{
	err(sys->sprint("can't load %s: %r", s));
}

err(s: string)
{
	sys->fprint(sys->fildes(2), "passwd: %s\n", s);
	raise "fail:error";
}

mountsrv(ai: ref Keyring->Authinfo): string
{
	(rc, c) := sys->dial(netmkaddr(signer, "net", "infkey"), nil);
	if(rc < 0)
		err(sys->sprint("can't dial %s: %r", signer));
	(fd, id_or_err) := auth->client("aes_256_gcm", ai, c.dfd);
	if(fd == nil)
		err(sys->sprint("can't authenticate with %s: %s", signer, id_or_err));
	if(sys->mount(fd, nil, keysrv, Sys->MREPL, nil) < 0)
		err(sys->sprint("can't mount %s on %s: %r", signer, keysrv));
	return id_or_err;
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

eq(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# the SHA-256 of a password: what keyfs(4) holds (changelogin(8))
hashpw(word: string): array of byte
{
	a := array of byte word;
	hash := array[Keyring->SHA256dlen] of byte;
	kr->sha256(a, len a, hash, nil);
	for(i := 0; i < len a; i++)
		a[i] = byte 0;
	return hash;
}

blank(word: string): string
{
	for(i := 0; i < len word; i++)
		word[i] = ' ';
	return nil;
}

#
# keysrv(4)'s file, version 2: read a challenge, write the proof that
# we have the old secret and, to change it, the new one sealed under a
# key made from the old (see keysrv.b).  The proof used to be a hash of
# the password, the same every time, to whatever had answered.
#
Version: con "keysrv 2 ";
Prooflabel: con "infernode keysrv 2 proof";
Wraplabel: con "infernode keysrv 2 new secret";

putsecret(user: string, old: array of byte, new: array of byte): string
{
	fd := sys->open(keysrv+"/secret", Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("%r");
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("%r");
	s := string buf[0:n];
	if(len s <= len Version || s[0:len Version] != Version)
		return "key server does not speak keysrv version 2 (keysrv(4))";
	c := unhex(s[len Version:]);
	if(c == nil || len c < 32)
		return "key server's challenge is not one";

	prk := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(old, len old, c, prk, nil);
	msg := hex(expand(prk, array of byte (Prooflabel + user), Keyring->SHA384dlen));
	if(new != nil){
		key := expand(prk, array of byte (Wraplabel + user), 32+12);
		(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(key[0:32], key[32:]), new, array of byte Wraplabel);
		msg += " " + hex(ct) + hex(tag);
	}
	b := array of byte msg;
	if(sys->write(fd, b, len b) < 0)
		return sys->sprint("%r");
	return nil;
}

# HKDF-Expand (RFC 5869 2.3) with HMAC-SHA-384: one block is enough
expand(prk, info: array of byte, n: int): array of byte
{
	t := array[Keyring->SHA384dlen] of byte;
	b := array[len info + 1] of byte;
	b[0:] = info;
	b[len info] = byte 1;
	kr->hmac_sha384(b, len b, prk, t, nil);
	return t[0:n];
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

netmkaddr(addr, net, svc: string): string
{
	if(net == nil)
		net = "net";
	(n, nil) := sys->tokenize(addr, "!");
	if(n <= 1){
		if(svc== nil)
			return sys->sprint("%s!%s", net, addr);
		return sys->sprint("%s!%s!%s", net, addr, svc);
	}
	if(svc == nil || n > 2)
		return addr;
	return sys->sprint("%s!%s", addr, svc);
}

readline(io: ref Sys->FD, mode: string): (int, string)
{
	r : int;
	line : string;
	buf := array[8192] of byte;
	fdctl : ref Sys->FD;
	rawoff := array of byte "rawoff";

	if(mode == "rawon"){
		fdctl = sys->open("/dev/consctl", sys->OWRITE);
		if(fdctl == nil || sys->write(fdctl,array of byte mode,len mode) != len mode){
			sys->fprint(stderr, "unable to change console mode");
			return (0,nil);
		}
	}

	line = "";
	for(;;) {
		r = sys->read(io, buf, len buf);
		if(r <= 0){
			sys->fprint(stderr, "error read from console mode");
			if(mode == "rawon")
				sys->write(fdctl,rawoff,6);
			return (0, nil);
		}

		line += string buf[0:r];
		if ((len line >= 1) && (line[(len line)-1] == '\n')){
			if(mode == "rawon"){
				r = sys->write(stdout,array of byte "\n",1);
				if(r <= 0) {
					sys->write(fdctl,rawoff,6);
					return (0, nil);
				}
			}
			break;
		}
		else {
			if(mode == "rawon"){
				#r = sys->write(stdout, array of byte "*",1);
				if(r <= 0) {
					sys->write(fdctl,rawoff,6);
					return (0, nil);
				}
			}
		}
	}

	if(mode == "rawon")
		sys->write(fdctl,rawoff,6);

	return (1, line[0:len line - 1]);
}
