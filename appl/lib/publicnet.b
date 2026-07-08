implement Publicnet;

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "publicnet.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
}

dialaddr(host, port: string): (string, string)
{
	if(sys == nil || str == nil)
		init();
	naddr := resolveaddr(host, port);
	if(naddr == nil || naddr == "")
		return (nil, "public net: destination denied (resolution failed)");
	naddr = str->drop(naddr, " \t\r\n");
	resolved := naddr;
	for(i := len naddr - 1; i >= 0; i--)
		if(naddr[i] == '!') {
			resolved = naddr[0:i];
			break;
		}
	if(publicipv4(resolved) < 0)
		return (nil, "public net: destination denied (non-IPv4 resolution)");
	if(publicipv4(resolved) == 0)
		return (nil, "public net: private or reserved destination denied");
	return ("tcp!" + resolved + "!" + port, nil);
}

resolveaddr(host, port: string): string
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil) {
		if(publicipv4(host) < 0)
			return nil;
		return host + "!" + port;
	}
	if(sys->fprint(fd, "tcp!%s!%s", host, port) < 0)
		return nil;
	sys->seek(fd, big 0, 0);
	buf := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	line := string buf[0:n];
	for(i := 0; i < len line; i++)
		if(line[i] == ' ')
			return line[i + 1:];
	return nil;
}

publicipv4(s: string): int
{
	oct := array[4] of int;
	start := 0;
	part := 0;
	for(i := 0; i <= len s; i++) {
		if(i < len s && s[i] != '.')
			continue;
		if(part >= 4 || i == start)
			return -1;
		v := 0;
		for(j := start; j < i; j++) {
			if(s[j] < '0' || s[j] > '9')
				return -1;
			v = v * 10 + s[j] - '0';
			if(v > 255)
				return -1;
		}
		oct[part++] = v;
		start = i + 1;
	}
	if(part != 4)
		return -1;
	x0 := oct[0]; x1 := oct[1]; x2 := oct[2];
	if(x0 == 0 || x0 == 10 || x0 == 127 || x0 >= 224)
		return 0;
	if(x0 == 100 && x1 >= 64 && x1 <= 127)
		return 0;
	if(x0 == 169 && x1 == 254)
		return 0;
	if(x0 == 172 && x1 >= 16 && x1 <= 31)
		return 0;
	if(x0 == 192 && (x1 == 168 || (x1 == 0 && (x2 == 0 || x2 == 2))))
		return 0;
	if(x0 == 198 && (x1 == 18 || x1 == 19 || (x1 == 51 && x2 == 100)))
		return 0;
	if(x0 == 203 && x1 == 0 && x2 == 113)
		return 0;
	return 1;
}

transitionallowed(initiator, targetscheme: string): int
{
	if(initiator == nil || initiator == "")
		return 1;
	is := schemestr(initiator);
	if(!networkscheme(is))
		return 1;
	return networkscheme(targetscheme);
}

networkscheme(s: string): int
{
	if(str != nil)
		s = str->tolower(s);
	return s == "http" || s == "https" || s == "ftp";
}

schemestr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ':')
			return s[0:i];
	return s;
}
