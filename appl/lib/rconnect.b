implement Rconnect;

include "sys.m";
	sys: Sys;

include "factotum.m";
	factotum: Factotum;
	Authinfo: import factotum;

include "keyring.m";
include "security.m";
	login: Login;

include "tlspsk.m";
	tlspsk: Tlspsk;

include "rconnect.m";

init(): string
{
	sys = load Sys Sys->PATH;
	login = load Login Login->PATH;
	if(login != nil && login->cnsamode())
		return "rcpu is not available in CNSA mode: 9front's dp9ik and its TLS are classical cryptography, not CNSA 2.0";
	factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		return sys->sprint("cannot load %s: %r", Factotum->PATH);
	factotum->init();
	tlspsk = load Tlspsk Tlspsk->PATH;
	if(tlspsk == nil)
		return sys->sprint("cannot load %s: %r", Tlspsk->PATH);
	return tlspsk->init();
}

addr(host: string): string
{
	(n, nil) := sys->tokenize(host, "!");
	case n {
	1 =>	return "tcp!"+host+"!17019";
	2 =>	return host+"!17019";
	}
	return host;
}

connect(host, keyspec, script: string): (ref Sys->FD, ref Authinfo, string)
{
	a := addr(host);
	(ok, c) := sys->dial(a, nil);
	if(ok < 0)
		return (nil, nil, sys->sprint("cannot dial %s: %r", a));
	afd := factotum->open();
	if(afd == nil)
		return (nil, nil, sys->sprint("cannot open factotum: %r"));
	ai := factotum->proxy(c.dfd, afd, "proto=p9any role=client "+keyspec);
	afd = nil;
	if(ai == nil)
		return (nil, nil, sys->sprint("authentication with %s failed: %r", host));
	if(len ai.secret != 256)
		return (nil, nil, "authentication gave no dp9ik session secret");
	(fd, err) := tlspsk->client(c.dfd, "p9secret", ai.secret);
	for(i := 0; i < len ai.secret; i++)
		ai.secret[i] = byte 0;
	if(fd == nil)
		return (nil, nil, err);
	b := array of byte script;
	n := array of byte sys->sprint("%d\n", len b);
	if(sys->write(fd, n, len n) != len n || sys->write(fd, b, len b) != len b)
		return (nil, nil, sys->sprint("cannot send the script: %r"));
	return (fd, ai, nil);
}

rcquote(s: string): string
{
	r := "'";
	for(i := 0; i < len s; i++){
		if(s[i] == '\'')
			r += "'";
		r[len r] = s[i];
	}
	return r + "'";
}
