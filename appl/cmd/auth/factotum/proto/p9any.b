implement Authproto;

#
# p9any and dp9ik, the client's side, as 9front's factotum speaks them
# (factotum(4) on 9front: p9any.c, p9sk1.c), so that a 9front cpu or
# file server can be reached with a 9front account.  p9any is answered
# with dp9ik alone: p9sk1's tickets are DES, which this system does not
# have.  The password stays here: the server and the auth server see
# only a SPAKE2-EE exchange made from a hash of it (dp9ik(2)).
#
# dp9ik is classical cryptography (Ed448, ChaCha20-Poly1305, SHA-256):
# interoperability with 9front, and nothing of CNSA 2.0.  It is refused
# in CNSA mode (/env/cnsamode), and does nothing unless a dp9ik key is
# given to factotum:
#
#	key proto=dp9ik dom=9front user=glenda !password=... [auth=host]
#
# auth= names the domain's auth server where ndb does not (authdom=).
#
#	C->S	CHc
#	S->C	AuthPAK ticketreq, YAs
#	C->A	AuthPAK ticketreq, YAs, YAc
#	A->C	YBs, YBc			(the client now has Kc)
#	C->A	AuthTreq ticketreq
#	A->C	Kc{Tc}, Ks{Ts}
#	C->S	YBs, Ks{Ts}, Kn{AuthAc, CHs, RNc}
#	S->C	Kn{AuthAs, CHc, RNs}
#
# secret = HKDF-SHA256(RNc|RNs, "Plan 9 session secret", Kn), 256 bytes
#

include "sys.m";
	sys: Sys;

include "keyring.m";

include "security.m";
	login: Login;

include "dp9ik.m";
	dp: Dp9ik;
	Pak, Ticket, Ticketreq, Authenticator: import dp;
	ANAMELEN, CHALLEN, NONCELEN, PAKYLEN, TICKREQLEN, TICKETLEN, AUTHENTLEN: import Dp9ik;

include "../authio.m";
	authio: Authio;
	Attr, IO, Key, Authinfo: import authio;
	netmkaddr, eqbytes: import authio;

include "encoding.m";
	base16: Encoding;

Authserver_timeout: con 30*1000;
Maxdoms: con 8;		# domains of an offer looked at

init(f: Authio): string
{
	authio = f;
	sys = load Sys Sys->PATH;
	login = load Login Login->PATH;
	if(login != nil && login->cnsamode())
		return "dp9ik is not available in CNSA mode: it is 9front's classical authentication (Ed448, ChaCha20-Poly1305), not CNSA 2.0";
	dp = load Dp9ik Dp9ik->PATH;
	if(dp == nil)
		return sys->sprint("cannot load %s: %r", Dp9ik->PATH);
	if((e := dp->init()) != nil)
		return e;
	base16 = load Encoding Encoding->BASE16PATH;
	return nil;
}

interaction(attrs: list of ref Attr, io: ref IO): string
{
	role := authio->lookattrval(attrs, "role");
	if(role != nil && role != "client")
		return "dp9ik: only role=client is implemented (InferNode is not a 9front server)";
	proto := authio->lookattrval(attrs, "proto");
	attrs = keyattrs(attrs);
	if(proto == "dp9ik"){
		(key, e) := io.findkey(attrs, "proto=dp9ik role? dom? user? !password?");
		if(key == nil)
			return "dp9ik: can't find key: "+e;
		return dp9ikclient(io, key, authio->lookattrval(key.attrs, "dom"));
	}
	return p9any(attrs, io);
}

# the caller's attributes choose among the keys, less the protocol's name
# and role, which are p9any's
keyattrs(attrs: list of ref Attr): list of ref Attr
{
	r: list of ref Attr;
	for(; attrs != nil; attrs = tl attrs)
		if((hd attrs).name != "proto" && (hd attrs).name != "role")
			r = hd attrs :: r;
	return r;
}

p9any(attrs: list of ref Attr, io: ref IO): string
{
	while((buf := io.read()) == nil || (n := len buf) == 0 || buf[n-1] != byte 0)
		io.toosmall(2048);
	(nil, flds) := sys->tokenize(string buf[0:n-1], " \t");
	version := 1;
	if(flds != nil && len hd flds >= 2 && (hd flds)[0:2] == "v."){
		if(hd flds != "v.2")
			return "p9any: unknown version "+hd flds;
		version = 2;
		flds = tl flds;
	}
	doms: list of string;
	offered: list of string;
	for(; flds != nil; flds = tl flds){
		(nf, subf) := sys->tokenize(hd flds, "@");
		if(nf != 2)
			continue;
		offered = hd subf :: offered;
		if(hd subf == "dp9ik")
			doms = hd tl subf :: doms;
	}
	if(doms == nil){
		if(member("p9sk1", offered))
			return "p9any: the server offers p9sk1 alone, whose tickets are DES, which this system does not have; dp9ik is needed";
		return "p9any: the server offers no protocol known here (dp9ik)";
	}
	doms = rev(doms);
	# the first domain offered that there is a key for; asked for only
	# when there is none, for the first offered
	mykey: ref Key;
	dom: string;
	nd := 0;
	for(l := doms; l != nil && nd < Maxdoms; l = tl l){
		nd++;
		(kl, nil) := io.findkeys(attrs, sys->sprint("proto=dp9ik dom=%q role? user? !password?", hd l));
		if(kl != nil){
			mykey = hd kl;
			dom = hd l;
			break;
		}
	}
	if(mykey == nil){
		dom = hd doms;
		e: string;
		(mykey, e) = io.findkey(attrs, sys->sprint("proto=dp9ik dom=%q role? user? !password?", dom));
		if(mykey == nil)
			return "p9any: can't find key: "+e;
	}
	r := array of byte ("dp9ik "+dom);
	rb := array[len r + 1] of byte;
	rb[0:] = r;
	rb[len r] = byte 0;
	io.write(rb, len rb);
	if(version == 2){
		b := io.readn(3);
		if(b == nil || len b < 3 || b[0] != byte 'O' || b[1] != byte 'K' || b[2] != byte 0)
			return "p9any: the server did not accept dp9ik";
	}
	return dp9ikclient(io, mykey, dom);
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

wipe: list of array of byte;

dp9ikclient(io: ref IO, key: ref Key, dom: string): string
{
	r := dp9ikclient1(io, key, dom);
	for(; wipe != nil; wipe = tl wipe)
		dp->zero(hd wipe);
	return r;
}

dp9ikclient1(io: ref IO, key: ref Key, dom: string): string
{
	user := authio->lookattrval(key.attrs, "user");
	if(user == nil)
		return "dp9ik: key has no user";
	if(dom == nil)
		return "dp9ik: key has no dom";
	aes: array of byte;
	if((h := authio->lookattrval(key.secrets, "!hex")) != nil){
		aes = base16->dec(h);
		if(len aes != Dp9ik->AESKEYLEN)
			return "dp9ik: !hex is not an AES key";
	}else if((pw := authio->lookattrval(key.secrets, "!password")) != nil)
		aes = dp->passtoaeskey(array of byte pw);
	else
		return "dp9ik: key has no !password";
	wipe = aes :: wipe;
	pakhash := dp->authpakhash(aes, user);
	wipe = pakhash :: wipe;

	#	C->S	CHc
	cchal := dp->randombytes(CHALLEN);
	if(io.write(cchal, CHALLEN) != CHALLEN)
		return "dp9ik: can't write challenge";

	#	S->C	AuthPAK ticketreq, YAs
	b := io.readn(TICKREQLEN+PAKYLEN);
	if(b == nil || len b < TICKREQLEN+PAKYLEN)
		return "dp9ik: can't read the server's ticket request";
	(tr, err) := Ticketreq.unpack(b[0:TICKREQLEN]);
	if(tr == nil)
		return "dp9ik: "+err;
	if(tr.rtype != Dp9ik->AuthPAK)
		return "dp9ik: the server's request is not AuthPAK";
	# one domain: the one negotiated, whose key and auth server are used
	if(tr.authdom != dom)
		return sys->sprint("dp9ik: the server's ticket request is for domain %q, not %q, the one negotiated", tr.authdom, dom);
	if(tr.authid == nil)
		return "dp9ik: the server's ticket request names no server";
	ys := b[TICKREQLEN:TICKREQLEN+PAKYLEN];
	tr.hostid = user;
	tr.uid = user;		# speaking for nobody else

	(ybs, kc, tickets, aerr) := getastickets(key, tr, ys, pakhash);
	if(tickets == nil)
		return "dp9ik: "+aerr;
	wipe = kc :: wipe;

	(t, terr) := dp->openticket(tickets[0:TICKETLEN], kc);
	if(t == nil)
		return "dp9ik: the auth server's ticket for us: "+terr+" (wrong password?)";
	wipe = t.key :: wipe;
	if(t.num != Dp9ik->AuthTc)
		return "dp9ik: the auth server's ticket for us is not a client's";
	if(!eqbytes(t.chal, tr.chal))
		return "dp9ik: the ticket is not for this conversation (its challenge is not the server's)";
	if(t.cuid != user || t.suid != user)
		return sys->sprint("dp9ik: the ticket is for %q as %q, not for %q", t.cuid, t.suid, user);

	#	C->S	YBs, Ks{Ts}, Kn{AuthAc, CHs, RNc}
	rand := array[2*NONCELEN] of byte;
	wipe = rand :: wipe;
	rand[0:] = dp->randombytes(NONCELEN);
	ab := dp->sealauth(ref Authenticator(Dp9ik->AuthAc, tr.chal, rand[0:NONCELEN]), t.key);
	out := array[PAKYLEN+TICKETLEN+AUTHENTLEN] of byte;
	out[0:] = ybs;
	out[PAKYLEN:] = tickets[TICKETLEN:2*TICKETLEN];
	out[PAKYLEN+TICKETLEN:] = ab;
	if(io.write(out, len out) != len out)
		return "dp9ik: can't write ticket and authenticator";

	#	S->C	Kn{AuthAs, CHc, RNs}
	sb := io.readn(AUTHENTLEN);
	if(sb == nil || len sb < AUTHENTLEN)
		return "dp9ik: can't read the server's authenticator";
	(sa, nil) := dp->openauth(sb[0:AUTHENTLEN], t.key);
	if(sa == nil || sa.num != Dp9ik->AuthAs || !eqbytes(sa.chal, cchal))
		return "dp9ik: the server's authenticator is not right: the server does not know the ticket key";
	rand[NONCELEN:] = sa.rand;
	secret := dp->sessionsecret(rand, t.key);
	io.done(ref Authinfo(t.cuid, t.suid, nil, secret));
	return nil;
}

# The conversation with the auth server, with a deadline.
getastickets(key: ref Key, tr: ref Ticketreq, ys, pakhash: array of byte): (array of byte, array of byte, array of byte, string)
{
	result := chan[1] of (array of byte, array of byte, array of byte, string);
	pidc := chan[1] of int;
	spawn asproc(pidc, result, key, tr, ys, pakhash);
	wpid := <-pidc;
	timeout := chan[1] of int;
	spawn timer(pidc, timeout);
	tpid := <-pidc;
	alt {
	r := <-result =>
		kill(tpid);
		return r;
	<-timeout =>
		kill(wpid);
		return (nil, nil, nil, "auth server timeout");
	}
}

asproc(pidc: chan of int, result: chan of (array of byte, array of byte, array of byte, string),
	key: ref Key, tr: ref Ticketreq, ys, pakhash: array of byte)
{
	pidc <-= sys->pctl(0, nil);
	(fd, err) := authdial(key, tr.authdom);
	if(fd == nil){
		result <-= (nil, nil, nil, err);
		return;
	}
	#	C->A	AuthPAK ticketreq, YAs, YAc
	tr.rtype = Dp9ik->AuthPAK;
	pc := Pak.new(pakhash, 1, nil);
	if(pc == nil){
		result <-= (nil, nil, nil, "cannot make a PAK key");
		return;
	}
	m := array[TICKREQLEN+2*PAKYLEN] of byte;
	m[0:] = tr.pack();
	m[TICKREQLEN:] = ys;
	m[TICKREQLEN+PAKYLEN:] = pc.y;
	if(sys->write(fd, m, len m) != len m){
		result <-= (nil, nil, nil, sys->sprint("writing to the auth server: %r"));
		return;
	}
	#	A->C	YBs, YBc
	(yb, rerr) := asrdresp(fd, 2*PAKYLEN);
	if(yb == nil){
		result <-= (nil, nil, nil, "auth server: "+rerr);
		return;
	}
	kc := pc.finish(yb[PAKYLEN:]);
	if(kc == nil){
		result <-= (nil, nil, nil, "the auth server's PAK key is not a point");
		return;
	}
	#	C->A	AuthTreq ticketreq;  A->C	Kc{Tc}, Ks{Ts}
	tr.rtype = Dp9ik->AuthTreq;
	t := tr.pack();
	if(sys->write(fd, t, len t) != len t){
		result <-= (nil, nil, nil, sys->sprint("writing to the auth server: %r"));
		return;
	}
	(nil, rerr) = asrdresp(fd, 0);
	if(rerr != nil){
		result <-= (nil, nil, nil, "auth server: "+rerr);
		return;
	}
	tickets := array[2*TICKETLEN] of byte;
	if(readn(fd, tickets, len tickets) != len tickets){
		result <-= (nil, nil, nil, "auth server: protocol botch: short tickets");
		return;
	}
	result <-= (yb[0:PAKYLEN], kc, tickets, nil);
}

# _asrdresp: AuthOK and n bytes, AuthOKvar and up to n, or AuthErr and why
asrdresp(fd: ref Sys->FD, n: int): (array of byte, string)
{
	c := array[1] of byte;
	if(readn(fd, c, 1) != 1)
		return (nil, "protocol botch");
	case int c[0] {
	Dp9ik->AuthOK =>
		b := array[n] of byte;
		if(readn(fd, b, n) != n)
			return (nil, "protocol botch");
		return (b, nil);
	Dp9ik->AuthErr =>
		e := array[64] of byte;
		if(readn(fd, e, len e) != len e)
			return (nil, "protocol botch");
		for(i := 0; i < len e && e[i] != byte 0; i++)
			;
		return (nil, "remote: "+clean(string e[0:i]));
	Dp9ik->AuthOKvar =>
		l := array[5] of byte;
		if(readn(fd, l, 5) != 5)
			return (nil, "protocol botch");
		v := int string l;
		if(v <= 0 || v > n)
			return (nil, "protocol botch");
		b := array[n] of {* => byte 0};
		if(readn(fd, b, v) != v)
			return (nil, "protocol botch");
		return (b, nil);
	}
	return (nil, "protocol botch");
}

# an error from the far end, printable
clean(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] >= ' ' && s[i] != 16r7f)
			r[len r] = s[i];
	return r;
}

readn(fd: ref Sys->FD, b: array of byte, n: int): int
{
	for(m := 0; m < n; ){
		r := sys->read(fd, b[m:], n - m);
		if(r <= 0)
			return m;
		m += r;
	}
	return n;
}

timer(pidc: chan of int, timeout: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(Authserver_timeout);
	timeout <-= 1;
}

kill(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# the auth server: the key's auth=, else ndb's for the domain
authdial(key: ref Key, dom: string): (ref Sys->FD, string)
{
	p := authio->lookattrval(key.attrs, "auth");
	if(p == nil)
		p = csgetvalue("authdom", dom, "auth");
	if(p == nil)
		p = csgetvalue("dom", dom, "auth");
	if(p == nil)
		return (nil, "no auth server found for "+dom+" (give the key auth=host, or ndb authdom="+dom+" auth=host)");
	addr := netmkaddr(p, "tcp", "567");	# ticket, by number: no cs needed
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return (nil, sys->sprint("cannot dial the auth server %s: %r", addr));
	return (conn.dfd, nil);
}

csgetvalue(keytag, keyval, needtag: string): string
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil)
		return nil;
	if(sys->fprint(fd, "!%s=%s %s=*", keytag, keyval, needtag) < 0)
		return nil;
	sys->seek(fd, big 0, 0);
	buf := array[1024] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		for(al := authio->parseline(string buf[0:n]); al != nil; al = tl al)
			if((hd al).name == needtag)
				return (hd al).val;
	}
	return nil;
}

keycheck(k: ref Authio->Key): string
{
	if(authio->lookattrval(k.attrs, "dom") == nil)
		return "a dp9ik key needs dom=";
	if(authio->lookattrval(k.attrs, "user") == nil)
		return "a dp9ik key needs user=";
	if((h := authio->lookattrval(k.secrets, "!hex")) != nil){
		if(len h != 2*Dp9ik->AESKEYLEN)
			return sys->sprint("a dp9ik key's !hex is %d hexadecimal digits", 2*Dp9ik->AESKEYLEN);
		return nil;
	}
	if(authio->lookattrval(k.secrets, "!password") == nil)
		return "a dp9ik key needs !password=";
	return nil;
}
