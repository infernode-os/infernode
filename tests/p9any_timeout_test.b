implement P9anyTimeoutTest, Authio;

include "sys.m";
	sys: Sys;
include "draw.m";
include "auth9.m";
	auth9: Auth9;
	Ticketreq: import auth9;
include "../appl/cmd/auth/factotum/authio.m";
	authio: Authio;

P9anyTimeoutTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

hangaddr: string;
ticketreq: array of byte;
testkey: ref Key;
readstage: int;

fail(s: string)
{
	sys->fprint(sys->fildes(2), "p9any_timeout_test: %s\n", s);
	raise "fail:test";
}

contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i+len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

port(c: Sys->Connection): string
{
	fd := sys->open(c.dir+"/local", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	last := -1;
	for(i := 0; i < len s; i++)
		if(s[i] == '!')
			last = i;
	if(last >= 0)
		s = s[last+1:];
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

stallserver(c: Sys->Connection, accepted, closed: chan of int)
{
	(ok, nc) := sys->listen(c);
	if(ok < 0){
		accepted <-= -1;
		return;
	}
	fd := sys->open(nc.dir+"/data", Sys->ORDWR);
	if(fd == nil){
		accepted <-= -1;
		return;
	}
	accepted <-= 1;
	b := array[256] of byte;
	while(sys->read(fd, b, len b) > 0)
		;
	closed <-= 1;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	auth9 = load Auth9 Auth9->PATH;
	if(auth9 == nil)
		fail("cannot load auth9");
	auth9->init();

	(ok, c) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		sys->print("SKIP: p9any timeout: loopback unavailable: %r\n");
		return;
	}
	p := port(c);
	if(p == nil)
		fail("cannot determine listener port");
	hangaddr = "tcp!127.0.0.1!"+p;
	accepted := chan[1] of int;
	closed := chan[1] of int;
	spawn stallserver(c, accepted, closed);

	tr := ref Ticketreq(Auth9->AuthTreq, "server", nil,
		array[Auth9->CHALLEN] of byte, "client", "client");
	ticketreq = tr.pack();
	testkey = ref Key(ref Attr(Aval, "user", "client") :: nil,
		ref Attr(Aval, "!password", "password") :: nil);

	authio = load Authio "$self";
	proto := load Authproto "/dis/auth/proto/p9any.dis";
	if(authio == nil || proto == nil)
		fail("cannot load authio self or p9any");
	if((e := proto->init(authio)) != nil)
		fail("p9any init: "+e);

	readstage = 0;
	start := sys->millisec();
	err := proto->interaction(nil, ref IO(nil, nil));
	elapsed := sys->millisec()-start;
	if(!contains(err, "auth server timeout"))
		fail("stalled server returned wrong error: "+err);
	if(elapsed < 29000 || elapsed > 40000)
		fail(sys->sprint("deadline fired after %dms", elapsed));
	if(<-accepted != 1)
		fail("auth transaction never reached the server");

	closetmo := chan[1] of int;
	spawn timer(closetmo, 5000);
	alt {
	<-closed =>
		;
	<-closetmo =>
		fail("timed-out auth transaction kept its connection open");
	}
	sys->print("PASS: p9any auth-server transaction times out and closes\n");
}

Attr.text(a: self ref Attr): string
{
	if(a.val == nil)
		return a.name;
	return a.name+"="+a.val;
}

Key.mk(nil: list of ref Attr): ref Key { return nil; }
Key.text(nil: self ref Key): string { return nil; }
Key.safetext(nil: self ref Key): string { return nil; }

IO.findkey(nil: self ref IO, nil: list of ref Attr, nil: string): (ref Key, string)
{
	return (testkey, nil);
}

IO.findkeys(nil: self ref IO, nil: list of ref Attr, nil: string): (list of ref Key, string)
{
	return (testkey :: nil, nil);
}

IO.needkey(nil: self ref IO, nil: list of ref Attr, nil: string): (ref Key, string)
{
	return (testkey, nil);
}

IO.read(nil: self ref IO): array of byte
{
	if(readstage++ == 0)
		return array of byte "v.2 p9sk1@test\0";
	return nil;
}

IO.readn(nil: self ref IO, n: int): array of byte
{
	if(n == 3)
		return array of byte "OK\0";
	if(n == Auth9->TICKREQLEN)
		return ticketreq;
	return nil;
}

IO.write(nil: self ref IO, nil: array of byte, n: int): int { return n; }
IO.toosmall(nil: self ref IO, nil: int) {}
IO.error(nil: self ref IO, nil: string) {}
IO.rdwr(nil: self ref IO): array of byte { return nil; }
IO.reply2read(nil: self ref IO, nil: array of byte, nil: int): int { return 0; }
IO.ok(nil: self ref IO) {}
IO.done(nil: self ref IO, nil: ref Authinfo) {}

memrandom(a: array of byte, n: int)
{
	for(i := 0; i < n && i < len a; i++)
		a[i] = byte i;
}

eqbytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

netmkaddr(nil: string, nil: string, nil: string): string { return hangaddr; }
user(): string { return "client"; }

lookattrval(a: list of ref Attr, name: string): string
{
	for(; a != nil; a = tl a)
		if((hd a).name == name)
			return (hd a).val;
	return nil;
}

parseline(nil: string): list of ref Attr { return nil; }
attrtext(nil: list of ref Attr): string { return nil; }
