implement Dp9ikProtoTest;

#
# auth/factotum's p9any and dp9ik (proto/p9any.b), the client's side,
# through factotum(2)'s proxy, against a 9front cpu server and auth
# server scripted here with dp9ik(2) as 9front's factotum and authsrv
# speak (p9any.c, p9sk1.c, authsrv.c): the session secret the same at
# both ends; the domain with a key chosen from an offer of several; and
# refused, each saying why: a wrong password, the auth server's error,
# an auth server's public key that is no point, a ticket for another
# conversation, a server naming a domain other than the one negotiated,
# a server that cannot answer with the ticket key, an offer of p9sk1
# alone, and any of it in CNSA mode.  tests/host/dp9ik_live_test.sh
# does the same against 9front itself.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";

include "factotum.m";
	factotum: Factotum;

include "testing.m";
	testing: Testing;
	T: import testing;

include "rconnect.m";

include "../appl/cmd/auth/factotum/authio.m";

include "dp9ik.m";
	dp: Dp9ik;
	Pak, Ticket, Authenticator, Ticketreq: import dp;
	CHALLEN, NONCELEN, PAKYLEN, TICKREQLEN, TICKETLEN, AUTHENTLEN: import Dp9ik;

Dp9ikProtoTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dp9ik_proto_test.b";
MNT: con "/tmp/dp9ik_proto_test";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# the auth server's accounts
Accounts := array[] of {
	("glenda", "glendapass"),
	("bootes", "bootespass"),
};

pakhash(user: string): array of byte
{
	for(i := 0; i < len Accounts; i++)
		if(Accounts[i].t0 == user)
			return dp->authpakhash(dp->passtoaeskey(array of byte Accounts[i].t1), user);
	return nil;
}

# what the scripted auth server does wrong, if anything
asmode := "";
asport := "";

asserve(c: chan of string)
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		c <-= sys->sprint("announce: %r");
		return;
	}
	fd := sys->open(ac.dir+"/local", Sys->OREAD);
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	(nil, l) := sys->tokenize(string b[0:n], "!\n");
	asport = hd tl l;
	c <-= nil;
	for(;;){
		(lok, lc) := sys->listen(ac);
		if(lok < 0)
			return;
		dfd := sys->open(lc.dir+"/data", Sys->ORDWR);
		if(dfd != nil)
			spawn ashandle(dfd);
	}
}

# authsrv's AuthPAK and AuthTreq, as 9front answers them
ashandle(fd: ref Sys->FD)
{
	b := array[TICKREQLEN+2*PAKYLEN] of byte;
	if(readn(fd, b, len b) != len b)
		return;
	(tr, nil) := Ticketreq.unpack(b[0:TICKREQLEN]);
	if(tr == nil || tr.rtype != Dp9ik->AuthPAK)
		return;
	if(asmode == "err"){
		e := array[64] of {* => byte 0};
		e[0:] = array of byte "no such user";
		sys->write(fd, array[] of {byte Dp9ik->AuthErr}, 1);
		sys->write(fd, e, len e);
		return;
	}
	phs := pakhash(tr.authid);
	phc := pakhash(tr.hostid);
	if(phs == nil || phc == nil)
		return;
	ps := Pak.new(phs, 0, nil);
	pc := Pak.new(phc, 0, nil);
	ks := ps.finish(b[TICKREQLEN:TICKREQLEN+PAKYLEN]);
	kc := pc.finish(b[TICKREQLEN+PAKYLEN:]);
	r := array[1+2*PAKYLEN] of byte;
	r[0] = byte Dp9ik->AuthOK;
	r[1:] = ps.y;
	r[1+PAKYLEN:] = pc.y;
	if(asmode == "bady")
		r[1+PAKYLEN:] = array[PAKYLEN] of {* => byte 16rff};
	sys->write(fd, r, len r);
	if(readn(fd, b, TICKREQLEN) != TICKREQLEN)
		return;
	(tr, nil) = Ticketreq.unpack(b[0:TICKREQLEN]);
	if(tr == nil || tr.rtype != Dp9ik->AuthTreq || kc == nil || ks == nil)
		return;
	chal := tr.chal;
	if(asmode == "chal")
		chal = array[CHALLEN] of {* => byte 'x'};
	kn := dp->randombytes(NONCELEN);
	tc := dp->sealticket(ref Ticket(Dp9ik->AuthTc, chal, tr.uid, tr.uid, kn), kc);
	ts := dp->sealticket(ref Ticket(Dp9ik->AuthTs, chal, tr.uid, tr.uid, kn), ks);
	r = array[1+2*TICKETLEN] of byte;
	r[0] = byte Dp9ik->AuthOK;
	r[1:] = tc;
	r[1+TICKETLEN:] = ts;
	sys->write(fd, r, len r);
}

# A 9front cpu server's factotum (as bootes) on one end of a pipe: the
# session secret, or why not
Srv: adt {
	offer:	string;
	dom:	string;		# the domain its ticket request names
	badauth:	int;	# answers with an authenticator under another key
};

cpuserve(fd: ref Sys->FD, s: Srv, c: chan of (array of byte, string))
{
	o := array of byte s.offer;
	m := array[len o + 1] of {* => byte 0};
	m[0:] = o;
	sys->write(fd, m, len m);
	# the client's choice, its nil, then OK
	ch := "";
	for(;;){
		b := array[1] of byte;
		if(sys->read(fd, b, 1) != 1){
			c <-= (nil, "client gone in negotiation");
			return;
		}
		if(b[0] == byte 0)
			break;
		ch[len ch] = int b[0];
	}
	sys->write(fd, array of byte "OK\0", 3);
	cchal := array[CHALLEN] of byte;
	if(readn(fd, cchal, CHALLEN) != CHALLEN){
		c <-= (nil, "no challenge: chose "+ch);
		return;
	}
	tr := ref Ticketreq(Dp9ik->AuthPAK, "bootes", s.dom, dp->randombytes(CHALLEN), "", "");
	pk := Pak.new(pakhash("bootes"), 1, nil);
	m = array[TICKREQLEN+PAKYLEN] of byte;
	m[0:] = tr.pack();
	m[TICKREQLEN:] = pk.y;
	sys->write(fd, m, len m);
	m = array[PAKYLEN+TICKETLEN+AUTHENTLEN] of byte;
	if(readn(fd, m, len m) != len m){
		c <-= (nil, "no ticket from the client");
		return;
	}
	ks := pk.finish(m[0:PAKYLEN]);
	if(ks == nil){
		c <-= (nil, "YBs is no point");
		return;
	}
	(t, err) := dp->openticket(m[PAKYLEN:PAKYLEN+TICKETLEN], ks);
	if(t == nil || t.num != Dp9ik->AuthTs){
		c <-= (nil, "server ticket: "+err);
		return;
	}
	(a, aerr) := dp->openauth(m[PAKYLEN+TICKETLEN:], t.key);
	if(a == nil || a.num != Dp9ik->AuthAc || hex(a.chal) != hex(tr.chal)){
		c <-= (nil, "client authenticator: "+aerr);
		return;
	}
	rand := array[2*NONCELEN] of byte;
	rand[0:] = a.rand;
	rand[NONCELEN:] = dp->randombytes(NONCELEN);
	key := t.key;
	if(s.badauth)
		key = array[32] of {* => byte 1};
	sb := dp->sealauth(ref Authenticator(Dp9ik->AuthAs, cchal, rand[NONCELEN:]), key);
	sys->write(fd, sb, len sb);
	c <-= (dp->sessionsecret(rand, t.key), nil);
}

# a conversation: the client's Authinfo or error, the server's secret or error
converse(t: ref T, s: Srv, params: string): (ref Factotum->Authinfo, string, array of byte, string)
{
	p := array[2] of ref Sys->FD;
	sys->pipe(p);
	sc := chan[1] of (array of byte, string);
	spawn cpuserve(p[1], s, sc);
	afd := sys->open(MNT+"/rpc", Sys->ORDWR);
	if(afd == nil)
		t.fatal(sys->sprint("open rpc: %r"));
	ai := factotum->proxy(p[0], afd, "proto=p9any role=client "+params);
	cerr := "";
	if(ai == nil)
		cerr = sys->sprint("%r");
	p[0] = nil;
	afd = nil;
	tc := chan[1] of int;
	spawn timer(tc, 10000);
	alt {
	(sec, serr) := <-sc =>
		return (ai, cerr, sec, serr);
	<-tc =>
		return (ai, cerr, nil, "server: no end");
	}
}

key(t: ref T, s: string)
{
	fd := sys->open(MNT+"/ctl", Sys->OWRITE);
	b := array of byte s;
	if(fd == nil || sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("ctl %s: %r", s));
}

delkeys()
{
	fd := sys->open(MNT+"/ctl", Sys->OWRITE);
	sys->fprint(fd, "delkey proto=dp9ik");
}

auth(): string
{
	return " auth=tcp!127.0.0.1!"+asport;
}

std := Srv("v.2 dp9ik@9front", "9front", 0);

testSecret(t: ref T)
{
	delkeys();
	key(t, "key proto=dp9ik dom=9front user=glenda !password=glendapass"+auth());
	(ai, cerr, sec, serr) := converse(t, std, "");
	if(ai == nil)
		t.fatal("client: "+cerr);
	if(sec == nil)
		t.fatal("server: "+serr);
	t.asserteq(len ai.secret, Dp9ik->SECRETLEN, "a 256-byte secret");
	t.assertseq(hex(ai.secret), hex(sec), "the secret the server has");
	t.assertseq(ai.cuid, "glenda", "cuid");
	t.assertseq(ai.suid, "glenda", "suid");
	# again: another secret
	(ai2, nil, nil, nil) := converse(t, std, "");
	t.assert(ai2 != nil && hex(ai2.secret) != hex(ai.secret), "each conversation its own secret");
}

testChooseDomain(t: ref T)
{
	delkeys();
	key(t, "key proto=dp9ik dom=second user=glenda !password=glendapass"+auth());
	s := Srv("v.2 p9sk1@first dp9ik@first dp9ik@second", "second", 0);
	(ai, cerr, sec, serr) := converse(t, s, "");
	t.assert(ai != nil && sec != nil, "the domain with a key: client "+cerr+", server "+serr);
	# the server names another domain than the one chosen
	s.dom = "first";
	(ai, cerr, nil, nil) = converse(t, s, "");
	t.assert(ai == nil && contains(cerr, "negotiated"), "a ticket request for another domain refused: "+cerr);
}

testWrongPassword(t: ref T)
{
	delkeys();
	key(t, "key proto=dp9ik dom=9front user=glenda !password=wrong"+auth());
	(ai, cerr, nil, nil) := converse(t, std, "");
	t.assert(ai == nil && contains(cerr, "wrong password"), "a wrong password refused: "+cerr);
}

testASRefusals(t: ref T)
{
	delkeys();
	key(t, "key proto=dp9ik dom=9front user=glenda !password=glendapass"+auth());
	asmode = "err";
	(ai, cerr, nil, nil) := converse(t, std, "");
	t.assert(ai == nil && contains(cerr, "no such user"), "the auth server's error passed on: "+cerr);
	asmode = "bady";
	(ai, cerr, nil, nil) = converse(t, std, "");
	t.assert(ai == nil && contains(cerr, "not a point"), "a public key that is no point refused: "+cerr);
	asmode = "chal";
	(ai, cerr, nil, nil) = converse(t, std, "");
	t.assert(ai == nil && contains(cerr, "conversation"), "a ticket for another conversation refused: "+cerr);
	asmode = "";
}

testBadServer(t: ref T)
{
	delkeys();
	key(t, "key proto=dp9ik dom=9front user=glenda !password=glendapass"+auth());
	(ai, cerr, nil, nil) := converse(t, Srv("v.2 dp9ik@9front", "9front", 1), "");
	t.assert(ai == nil && contains(cerr, "does not know the ticket key"), "a server without the ticket key refused: "+cerr);
	(ai, cerr, nil, nil) = converse(t, Srv("v.2 p9sk1@9front", "9front", 0), "");
	t.assert(ai == nil && contains(cerr, "DES"), "an offer of p9sk1 alone refused: "+cerr);
	(ai, cerr, nil, nil) = converse(t, Srv("v.3 dp9ik@9front", "9front", 0), "");
	t.assert(ai == nil && contains(cerr, "version"), "an unknown version refused: "+cerr);
	# no auth server reachable
	delkeys();
	key(t, "key proto=dp9ik dom=9front user=glenda !password=glendapass auth=tcp!127.0.0.1!1");
	(ai, cerr, nil, nil) = converse(t, std, "");
	t.assert(ai == nil && contains(cerr, "auth server"), "an auth server not there: "+cerr);
}

# CNSA mode is the system's from its start (factotum takes its own
# environment when it starts): the protocol module and rconnect(2) are
# each refused when they are started in it, saying why
testCNSA(t: ref T)
{
	fd := sys->create("/env/cnsamode", Sys->OWRITE, 8r666);
	if(fd == nil)
		t.skip(sys->sprint("cannot set /env/cnsamode: %r"));
	sys->fprint(fd, "1");
	fd = nil;
	p := load Authproto "/dis/auth/proto/p9any.dis";
	e := "not loaded";
	if(p != nil)
		e = p->init(nil);
	rc := load Rconnect Rconnect->PATH;
	re := "not loaded";
	if(rc != nil)
		re = rc->init();
	sys->remove("/env/cnsamode");
	t.assert(contains(e, "CNSA"), "p9any refused in CNSA mode: "+e);
	t.assert(contains(re, "CNSA"), "rconnect refused in CNSA mode: "+re);
	p = load Authproto "/dis/auth/proto/p9any.dis";
	t.assert(p != nil && p->init(nil) == nil, "and taken out of it");
}

contains(s, p: string): int
{
	for(i := 0; i+len p <= len s; i++)
		if(s[i:i+len p] == p)
			return 1;
	return 0;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
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

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

startagent(c: chan of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	mod := load Command "/dis/auth/factotum.dis";
	if(mod == nil){
		c <-= sys->sprint("cannot load factotum: %r");
		return;
	}
	c <-= nil;
	mod->init(nil, "factotum" :: "-m" :: MNT :: "-s" :: "dp9ik_proto_test" :: nil);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	factotum = load Factotum Factotum->PATH;
	dp = load Dp9ik Dp9ik->PATH;
	if(testing == nil || factotum == nil || dp == nil){
		sys->fprint(sys->fildes(2), "dp9ik_proto_test: cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	factotum->init();
	if((e := dp->init()) != nil){
		sys->fprint(sys->fildes(2), "dp9ik_proto_test: %s\n", e);
		raise "fail:load";
	}
	sys->pctl(Sys->FORKNS|Sys->FORKENV, nil);
	sys->remove("/env/cnsamode");
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);
	c := chan of string;
	spawn asserve(c);
	if((e = <-c) != nil){
		sys->fprint(sys->fildes(2), "dp9ik_proto_test: %s\n", e);
		raise "fail:setup";
	}
	spawn startagent(c);
	if((e = <-c) != nil){
		sys->fprint(sys->fildes(2), "dp9ik_proto_test: %s\n", e);
		raise "fail:setup";
	}
	for(i := 0; i < 50; i++){
		(ok, nil) := sys->stat(MNT + "/rpc");
		if(ok >= 0)
			break;
		sys->sleep(100);
	}

	run("Secret", testSecret);
	run("ChooseDomain", testChooseDomain);
	run("WrongPassword", testWrongPassword);
	run("ASRefusals", testASRefusals);
	run("BadServer", testBadServer);
	run("CNSA", testCNSA);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
