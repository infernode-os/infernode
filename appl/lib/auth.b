# Inferno authentication protocol
implement Auth;

#
# After Keyring->auth both ends hold a secret nobody else has, and the
# client says which ssl(3) algorithm the connection is to run under.
# It said so in one message, in clear, that nothing vouched for: where
# a server would take "none" beside a cipher, whoever carried the bytes
# could put "none" where the client had written its cipher, and the
# server then ran that client's session in clear, for whoever was
# carrying the bytes to speak in.  The client failed at its own end,
# having turned its cipher on, and knew nothing of it.
#
# The choice is now confirmed with the secret, and the keys are made of
# it (version 2 of the exchange):
#
#	client:	"infernode-auth 2" \n algorithms \n
#		hex HMAC-SHA256(kc, "client" \n algorithms)
#	server:	"ok" \n its list \n
#		hex HMAC-SHA256(kc, "server" \n "ok" \n algorithms \n its list)
#	   or:	"no" \n why \n its list \n
#		hex HMAC-SHA256(kc, "server" \n "no" \n why \n algorithms \n its list)
#
# each a Keyring->sendmsg message, where kc = HMAC-SHA256(secret,
# "infernode auth 2 confirm"), and ssl's secret is HMAC-SHA384(secret,
# "infernode auth 2 ssl" \n algorithms \n the server's list).  A
# server acts on a choice only when the client's tag says it is the
# client's; a client goes on only when the server's says the server
# took that choice, so a choice changed on the way fails at both ends,
# and one refused is refused in the server's own words.  Since the
# keys are made of what each end saw, ends that were shown different
# things have different keys as well.
#
# An end of the exchange before this one is refused, each way: a
# server that is sent a bare algorithm says the client is an old one,
# and a client whose message an old server cannot read (it takes
# "infernode-auth" for an algorithm it does not have) is told the
# server did not confirm.  Both ends of a connection are of one kind.
#

include "sys.m";
	sys: Sys;

include "keyring.m";

include "security.m";
	ssl: SSL;

encalgs, hashalgs: list of string;

VERSION: con "infernode-auth 2";

init(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(encalgs == nil && hashalgs == nil)
		(encalgs, hashalgs) = sslalgs();
	return nil;	
}

server(algs: list of string, ai: ref Keyring->Authinfo, fd: ref Sys->FD, setid: int): (ref Sys->FD, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	kr := load Keyring Keyring->PATH;
	if(kr == nil)
		return (nil, sys->sprint("%r"));
	if(encalgs == nil && hashalgs == nil)
		(encalgs, hashalgs) = sslalgs();

	# A list in which ssl(3) knows no name (a mistyped one; the old
	# rc4_256 and sha1) asked for no encryption and no integrity
	# below, and then a client that named nothing was given a clear
	# session: the operator asked for a cipher and got none, and
	# someone on the path, by putting a blank where an honest
	# client's choice was, held the session the server had just
	# made for that client.  Such a list serves nobody.
	if(algs != nil && !usable(algs))
		return (nil, "no algorithm in the server's list that ssl has:" + names(algs));

	# mutual authentication
	# Keyring.auth changes /dev/user before returning when setid is true.
	# Keep the service identity until the accepted network conversation has
	# been handed to the authenticated peer: otherwise the old service owner
	# can still reopen, snoop, or hang up that peer's connection, while the
	# peer itself cannot name it.  This is the Inferno counterpart of
	# 9front's setnetuser() in its authenticated network servers.
	(id_or_err, secret) := kr->auth(fd, ai, 0);
	if(setid){
		if(secret != nil){
			d := sys->nulldir;
			d.uid = id_or_err;
			d.mode = 8r660;
			sys->fwstat(fd, d);
			setuser(id_or_err);
		}else
			setuser("nobody");
	}

	if(secret == nil){
		if(ai == nil && id_or_err == "no authentication information")
			id_or_err = "no server certificate";
		return (nil, id_or_err);
	}
	if(0)
		sys->fprint(sys->fildes(2), "secret is %s\n", dump(secret));

	# have got a secret, get algorithm from client
	# check if the client algorithm is in the server algorithm list
	# client algorithm ::= ident (' ' ident)*
	# where ident is defined by ssl(3)
	msg := kr->getmsg(fd);
	if(msg == nil)
		return (nil, sys->sprint("can't read client ssl algorithm: %r"));
	kc := confirmkey(kr, secret);
	offered := names(algs);
	if(offered != nil)
		offered = offered[1:];
	(nl, lines) := sys->tokenize(string msg, "\n");
	if(nl < 1 || hd lines != VERSION)
		return (nil, "the client did not confirm its ssl algorithm: it is of a version before \"" + VERSION + "\", and both ends must be of one");
	algbuf := "";
	tag := "";
	if(nl == 3){
		algbuf = hd tl lines;
		tag = hd tl tl lines;
	}else if(nl == 2)
		tag = hd tl lines;	# a choice of no words
	if(nl > 3 || !sametag(tag, mac(kr, kc, "client\n" + algbuf)))
		return (nil, "the client's choice of ssl algorithm is not confirmed by its key: changed on the way, or not the client's");

	(alg, why) := choose(algs, algbuf);
	if(why != nil){
		# in the server's words, under its key: the client can say why
		r := "no\n" + why + "\n" + offered + "\n";
		b := array of byte (r + mac(kr, kc, "server\nno\n" + why + "\n" + algbuf + "\n" + offered));
		kr->sendmsg(fd, b, len b);
		return (nil, why);
	}
	b := array of byte ("ok\n" + offered + "\n" + mac(kr, kc, "server\nok\n" + algbuf + "\n" + offered));
	if(kr->sendmsg(fd, b, len b) < 0)
		return (nil, sys->sprint("can't confirm ssl algorithm: %r"));

	# don't push ssl if server supports nossl
	if(alg == nil || alg == "none")
		return (fd, id_or_err);

	# push ssl and turn on algorithms
	ssl = load SSL SSL->PATH;
	if(ssl == nil)
		return (nil, sys->sprint("can't load ssl: %r"));
	(c, err) := pushssl(fd, sslsecret(kr, secret, algbuf, offered), 0, alg);
	if(c == nil)
		return (nil, "push ssl: " + err);
	return (c, id_or_err);
}

# What a server makes of a client's choice: (the algorithms to turn
# on, nil), or (nil, why not)
choose(algs: list of string, algbuf: string): (string, string)
{
	alg := "";
	(nil, calgs) := sys->tokenize(algbuf, " /");
	clientenc := clienthash := 0;
	nwords := noneamong := 0;
	for(; calgs != nil; calgs = tl calgs){
		calg := hd calgs;
		nwords++;
		if(calg == "none")
			noneamong = 1;
		if(algs != nil){	# otherwise we suck it and see
			for(sl := algs; sl != nil; sl = tl sl)
				if(hd sl == calg)
					break;
			if(sl == nil)
				return (nil, "unsupported client algorithm: " + calg);
		}
		clientenc |= member(calg, encalgs);
		clienthash |= member(calg, hashalgs);
		alg += calg + " ";
	}
	clienthash |= clientenc;	# aes_256_gcm, the only cipher, authenticates its records too
	if(algs != nil){
		# the client's choice is one of the list's names, in so
		# many words: a message of blanks named none of them, and
		# was taken for "none" whether or not the list had it
		if(alg == nil)
			return (nil, "client named no algorithm");
		# no ssl at all is asked for alone
		if(nwords > 1 && noneamong)
			return (nil, "client asked for none and an algorithm");
	}
	if(algs != nil && !member("none", algs)){
		if(encalgs == nil && hashalgs == nil)
			return (nil, "cannot enforce ssl algorithm policy");
		requireenc := requirehash := 0;
		for(sl := algs; sl != nil; sl = tl sl){
			requireenc |= member(hd sl, encalgs);
			requirehash |= member(hd sl, hashalgs);
		}
		if(requireenc && !clientenc)
			return (nil, "client omitted required encryption algorithm");
		if(requirehash && !clienthash)
			return (nil, "client omitted required integrity algorithm");
	}
	if(alg != nil)
		alg = alg[0:len alg - 1];
	return (alg, nil);
}

# The key the two ends confirm the choice with, and the secret ssl's
# keys are made of: each of the shared secret, the second of what the
# two ends said as well
confirmkey(kr: Keyring, secret: array of byte): array of byte
{
	l := array of byte "infernode auth 2 confirm";
	k := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(l, len l, secret, k, nil);
	return k;
}

sslsecret(kr: Keyring, secret: array of byte, algbuf, offered: string): array of byte
{
	l := array of byte ("infernode auth 2 ssl\n" + algbuf + "\n" + offered);
	k := array[Keyring->SHA384dlen] of byte;
	kr->hmac_sha384(l, len l, secret, k, nil);
	return k;
}

mac(kr: Keyring, key: array of byte, text: string): string
{
	b := array of byte text;
	d := array[Keyring->SHA256dlen] of byte;
	kr->hmac_sha256(b, len b, key, d, nil);
	return dump(d);
}

# equal, in time that does not say where they differ
sametag(a, b: string): int
{
	if(len a != len b)
		return 0;
	d := 0;
	for(i := 0; i < len a; i++)
		d |= a[i] ^ b[i];
	return d == 0;
}

# The client's half, after Keyring->auth: say alg, have it confirmed,
# and turn it on.  (the connection, nil) or (nil, why not)
negotiate(kr: Keyring, fd: ref Sys->FD, secret: array of byte, alg: string): (ref Sys->FD, string)
{
	for(i := 0; i < len alg; i++)
		if(alg[i] == '\n')
			return (nil, "bad ssl algorithm");
	kc := confirmkey(kr, secret);
	# send algorithm
	buf := array of byte (VERSION + "\n" + alg + "\n" + mac(kr, kc, "client\n" + alg));
	if(kr->sendmsg(fd, buf, len buf) < 0)
		return (nil, sys->sprint("can't send ssl algorithm: %r"));

	# the server's answer, which only the holder of the secret can make
	msg := kr->getmsg(fd);
	if(msg == nil)
		return (nil, sys->sprint("the server did not confirm the ssl algorithm (%r): it refused it, or is of a version before \"%s\"", VERSION));
	text := string msg;
	(nil, lines) := sys->tokenize(text, "\n");
	bad := "the server's answer about the ssl algorithm is not confirmed by its key: changed on the way, or not the server's";
	if(lines == nil)
		return (nil, bad);
	offered := "";
	case hd lines {
	"ok" =>
		# "ok", the list (not there when the server has none), the tag
		tag: string;
		case len lines {
		3 =>
			offered = hd tl lines;
			tag = hd tl tl lines;
		2 =>
			tag = hd tl lines;
		* =>
			return (nil, bad);
		}
		if(!sametag(tag, mac(kr, kc, "server\nok\n" + alg + "\n" + offered)))
			return (nil, bad);
	"no" =>
		why, tag: string;
		case len lines {
		4 =>
			why = hd tl lines;
			offered = hd tl tl lines;
			tag = hd tl tl tl lines;
		3 =>
			why = hd tl lines;
			tag = hd tl tl lines;
		* =>
			return (nil, bad);
		}
		if(!sametag(tag, mac(kr, kc, "server\nno\n" + why + "\n" + alg + "\n" + offered)))
			return (nil, bad);
		if(offered != nil)
			why += " (the server takes: " + offered + ")";
		return (nil, "server: " + why);
	* =>
		return (nil, bad);
	}

	# don't push ssl if server supports no ssl connection
	if(alg == "none")
		return (fd, nil);

	# push ssl and turn on algorithm
	ssl = load SSL SSL->PATH;
	if(ssl == nil)
		return (nil, sys->sprint("can't load ssl: %r"));
	(c, err) := pushssl(fd, sslsecret(kr, secret, alg, offered), 1, alg);
	if(c == nil)
		return (nil, "push ssl: " + err);
	return (c, nil);
}

# Match Keyring.auth's documented setid behaviour.# Match Keyring.auth's documented setid behaviour.  Failure is deliberately
# ignored: changing identity has historically been best-effort for callers
# without permission to write /dev/user.
setuser(user: string)
{
	ufd := sys->open("/dev/user", Sys->OWRITE);
	if(ufd != nil)
		sys->write(ufd, array of byte user, len user);
}

# is there a name in a server's list that can make a session: one ssl(3)
# has, or the two that ask for none of it
usable(algs: list of string): int
{
	for(; algs != nil; algs = tl algs){
		a := hd algs;
		if(a == "none" || a == "clear" || member(a, encalgs) || member(a, hashalgs))
			return 1;
	}
	return 0;
}

names(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l)
		s += " " + hd l;
	return s;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

sslalgs(): (list of string, list of string)
{
	clone := readfile("#D/clone");
	base := "#D/";
	if(clone == nil){
		clone = readfile("#D/ssl/clone");
		base = "#D/ssl/";
	}
	if(clone == nil)
		return (nil, nil);
	(nil, ids) := sys->tokenize(clone, " \t\n");
	if(ids == nil)
		return (nil, nil);
	base += hd ids;
	(nil, enc) := sys->tokenize(readfile(base+"/encalgs"), " \t\n");
	(nil, hash) := sys->tokenize(readfile(base+"/hashalgs"), " \t\n");
	return (enc, hash);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

client(alg: string, ai: ref Keyring->Authinfo, fd: ref Sys->FD): (ref Sys->FD, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	kr := load Keyring Keyring->PATH;
	if(kr == nil)
		return (nil, sys->sprint("%r"));

	if(alg == nil)
		alg = "none";

	# mutual authentication
	(id_or_err, secret) := kr->auth(fd, ai, 0);
	if(secret == nil)
		return (nil, id_or_err);

	(c, err) := negotiate(kr, fd, secret, alg);
	if(c == nil)
		return (nil, err);
	return (c, id_or_err);
}

auth(ai: ref Keyring->Authinfo, keyspec: string, alg: string, fd: ref Sys->FD): (ref Sys->FD, ref Keyring->Authinfo, string)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	kr := load Keyring Keyring->PATH;
	if(kr == nil)
		return (nil, nil, sys->sprint("can't load %s: %r", Keyring->PATH));
	if(alg == nil)
		alg = "none";
	if(ai == nil && keyspec != nil){
		ai = key(keyspec);
		if(ai == nil)
			return (nil, nil, sys->sprint("can't obtain key: %r"));
	}

	# mutual authentication
	(id_or_err, secret) := kr->auth(fd, ai, 0);
	if(secret == nil)
		return (nil, nil, id_or_err);

	(c, err) := negotiate(kr, fd, secret, alg);	# as the client: it says the algorithm
	if(c == nil)
		return (nil, nil, err);
	return (c, nil, id_or_err);
}

dump(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s += sys->sprint("%.2ux", int b[i]);
	return s;
}

# push an SSLv2 Record Layer onto the fd, each way under its own secret
pushssl(fd: ref Sys->FD, secret: array of byte, client: int, alg: string): (ref Sys->FD, string)
{
	(err, c) := ssl->connect(fd);
	if(err != nil)
		return (nil, "can't connect ssl: " + err);

	(secretin, secretout) := ssl->secrets(secret, client);
	err = ssl->secret(c, secretin, secretout);
	if(err != nil)
		return (nil, "can't write secret: " + err);

	if(sys->fprint(c.cfd, "alg %s", alg) < 0)
		return (nil, sys->sprint("can't push algorithm %s: %r", alg));

	return (c.dfd, nil);
}

key(keyspec: string): ref Keyring->Authinfo
{
	f := keyfile(keyspec);
	if(f == nil)
		return nil;
	kr := load Keyring Keyring->PATH;
	if(kr == nil){
		sys->werrstr(sys->sprint("can't load %s: %r", Keyring->PATH));
		return nil;
	}
	return kr->readauthinfo(f);
}

#
# look for key in old style keyring directory;
# closest match to [net!]addr[!svc]
#

hasslash(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 1;
	return 0;
}

keyfile(keyspec: string): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	al := parseattr(keyspec);
	keyname := get(al, "key");
	if(keyname != nil){
		# explicit keyname overrides rest of spec
		if(keyname[0] == '/' ||
		   len keyname > 2 && keyname[0:2]=="./" ||
		   len keyname > 3 && keyname[0:3]=="../")
			return keyname;	# don't add directory
		return keydir()+keyname;
	}
	net := "net";
	svc := get(al, "service");
	addr := get(al, "server");
	(nf, flds) := sys->tokenize(addr, "!");	# compatibility
	if(nf > 1){
		net = hd flds;
		addr = hd tl flds;
	}
	# server, service and dom name a file in the key directory, and
	# only there: with a slash in one (server=../../x) the name made of
	# it was a path to anywhere.  key= is the attribute for a path.
	if(hasslash(net) || hasslash(addr) || hasslash(svc))
		return nil;
	if(addr != nil)
		keyname = addr;
	else
		keyname = "default";
	kd := keydir();
	dom := get(al, "dom");
	if(hasslash(dom))
		dom = nil;
	if(dom != nil){
		if((cert := exists(kd+dom)) != nil)
			return cert;
	}
	if(keyname == "default")
		return kd+"default";
	if(net == "net")
		l := "net!" :: "tcp!" :: nil;
	else
		l = net+"!" :: nil;
	if(svc != nil){
		for(nl := l; nl != nil; nl = tl nl){
			cert := exists(kd+(hd nl)+keyname+"!"+svc);	# most specific
			if(cert != nil)
				return cert;
		}
	}
	for(nl := l; nl != nil; nl = tl nl){
		cert := exists(kd+(hd nl)+keyname);
		if(cert != nil)
			return cert;
	}
	cert := exists(kd+keyname);	# unadorned
	if(cert != nil)
		return cert;
	if(keyname != "default"){
		cert = exists(kd+"default");
		if(cert != nil)
			return cert;
	}
	return kd+keyname;
}

keydir(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	nr := sys->read(fd, b, len b);
	if(nr <= 0){
		sys->werrstr("can't read /dev/user");
		return nil;
	}
	user := string b[0:nr];
	return "/usr/" + user + "/keyring/";
}

exists(f: string): string
{
	(ok, nil) := sys->stat(f);
	if(0)sys->fprint(sys->fildes(2), "exists: %q %d\n", f, ok>=0);
	if(ok >= 0)
		return f;
	return nil;
}

Aattr, Aval, Aquery: con iota;

Attr: adt {
	tag:	int;
	name:	string;
	val:	string;
};

parseattr(s: string): list of ref Attr
{
	(nil, fld) := sys->tokenize(s, " \t\n");	# should do quoting; later
	rfld := fld;
	for(fld = nil; rfld != nil; rfld = tl rfld)
		fld = (hd rfld) :: fld;
	attrs: list of ref Attr;
	for(; fld != nil; fld = tl fld){
		n := hd fld;
		a := "";
		tag := Aattr;
		for(i:=0; i<len n; i++)
			if(n[i] == '='){
				a = n[i+1:];
				n = n[0:i];
				tag = Aval;
			}
		if(len n == 0)
			continue;
		if(tag == Aattr && len n > 1 && n[len n-1] == '?'){
			tag = Aquery;
			n = n[0:len n-1];
		}
		attrs = ref Attr(tag, n, a) :: attrs;
	}
	return attrs;
}

get(al: list of ref Attr, n: string): string
{
	for(; al != nil; al = tl al)
		if((a := hd al).name == n && a.tag == Aval)
			return a.val;
	return nil;
}
