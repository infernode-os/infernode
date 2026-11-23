implement Passwd;

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "security.m";
	auth: Auth;
	login: Login;

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
	login = load Login Login->PATH;
	if(login == nil)
		noload(Login->PATH);

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

	# The secrets are read as bytes and zeroed when used (login(2)'s
	# readsecret): they were strings, which a program cannot clear
	# (the loop that "blanked" them changed a copy), and in raw mode a
	# backspace typed was a character of the secret.
	# old is the password as typed: which form of secret keyfs holds
	# for it (keys(6)) is the key server's to say, in its challenge.
	old: array of byte;
	for(;;){
		sys->print("Inferno secret: ");
		(word, e) := login->readsecret(stdin);
		if(word == nil)
			err("can't read the secret: " + e);
		if(len word == 0)
			err("no secret given; nothing changed");
		old = word;
		e = putsecret(user, old, nil);
		if(e != "wrong secret"){
			if(e == nil)
				break;
			login->zero(old);
			err(e);
		}
		login->zero(old);
		sys->fprint(stderr, "!wrong secret\n");
	}
	for(;;){
		word: array of byte;
		e: string;
		for(;;){
			sys->print("new secret [default = don't change]: ");
			(word, e) = login->readsecret(stdin);
			if(word == nil){
				login->zero(old);
				err("can't read the new secret; nothing changed");
			}
			if(len word == 0)
				break;
			if(login->runes(word) >= 8)
				break;
			login->zero(word);
			sys->print("!secret must be at least 8 characters\n");
		}
		if(len word == 0){
			sys->print("secret not changed\n");
			break;
		}
		# confirm password change
		sys->print("confirm: ");
		(word1, e1) := login->readsecret(stdin);
		if(word1 == nil || !eq(word, word1)){
			login->zero(word);
			login->zero(word1);
			sys->fprint(stderr, "!entries didn't match\n");
			if(word1 == nil){
				login->zero(old);
				err("can't read the new secret again (" + e1 + "); nothing changed");
			}
			continue;
		}
		login->zero(word1);
		# What keyfs holds, and login(6) uses, is the account's secret
		# made from the password (keys(6): PBKDF2-HMAC-SHA-384 salted
		# by the name), always of the new form: the password itself was
		# once sent and stored, and the account could not log in again.
		if(eq(word, old)){
			login->zero(word);
			sys->print("secret not changed\n");
			break;
		}
		new := login->secret(user, word);
		login->zero(word);
		e = putsecret(user, old, new);
		login->zero(new);
		if(e != nil){
			login->zero(old);
			sys->fprint(stderr, "passwd: can't update secret for %s: %s\n", user, e);
			raise "fail:error";
		}
		sys->print("secret changed\n");
		break;
	}
	login->zero(old);
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

#
# keysrv(4)'s file, version 2: read a challenge, write the proof that
# we have the old secret and, to change it, the new one sealed under a
# key made from the old (see keysrv.b).  The proof used to be a hash of
# the password, the same every time, to whatever had answered.
#
Version: con "keysrv 3 ";
Prooflabel: con "infernode keysrv 2 proof";
Wraplabel: con "infernode keysrv 2 new secret";

putsecret(user: string, oldpw: array of byte, new: array of byte): string
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
		return "key server does not speak keysrv version 3 (keysrv(4))";
	# "keysrv 3 " form " " challenge: the form of the secret it holds
	(nf, f) := sys->tokenize(s[len Version:], " ");
	if(nf != 2)
		return "key server's challenge is not one";
	c := unhex(hd tl f);
	if(c == nil || len c < 32)
		return "key server's challenge is not one";
	old: array of byte;
	case int hd f {
	Login->Newform =>
		old = login->secret(user, oldpw);
	Login->Oldform =>
		old = login->oldsecret(oldpw);
	* =>
		return "key server's form of secret is not one of keys(6)'s";
	}

	prk := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(old, len old, c, prk, nil);
	login->zero(old);
	msg := hex(expand(prk, array of byte (Prooflabel + user), Keyring->SHA384dlen));
	if(new != nil){
		key := expand(prk, array of byte (Wraplabel + user), 32+12);
		(ct, tag) := kr->aesgcmencrypt(kr->aesgcmsetup(key[0:32], key[32:]), new, array of byte Wraplabel);
		login->zero(key);
		msg += " " + hex(ct) + hex(tag);
	}
	login->zero(prk);
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
