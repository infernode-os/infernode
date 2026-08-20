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

#
# ── URL host extraction and blocking ─────────────────────────────────
#
# Shared by every fetch tool (webfetch, payfetch, http). Keeping this
# in one place is the point: private copies of a security predicate
# drift, and the weakest copy is the one that gets exploited.
#

urlhost(url: string): string
{
	if(sys == nil || str == nil)
		init();
	s := url;
	# strip scheme
	for(i := 0; i < len s; i++) {
		if(i + 2 < len s && s[i] == '/' && s[i+1] == '/') {
			s = s[i+2:];
			break;
		}
	}
	# strip path/query/fragment
	for(i = 0; i < len s; i++) {
		c := s[i];
		if(c == '/' || c == '?' || c == '#') {
			s = s[0:i];
			break;
		}
	}
	# strip userinfo FIRST (rightmost '@'), else "user:pass@host"
	# leaves "user" once the port strip below cuts at the first ':'
	for(i = len s - 1; i >= 0; i--) {
		if(s[i] == '@') {
			s = s[i+1:];
			break;
		}
	}
	if(len s > 0 && s[0] == '[') {
		# bracketed IPv6 literal: keep "[...]", drop any :port after
		for(i = 0; i < len s; i++) {
			if(s[i] == ']') {
				s = s[0:i+1];
				break;
			}
		}
	} else {
		for(i = 0; i < len s; i++) {
			if(s[i] == ':') {
				s = s[0:i];
				break;
			}
		}
	}
	return str->tolower(s);
}

hostblocked(host: string): int
{
	if(sys == nil || str == nil)
		init();
	if(host == nil || host == "")
		return 1;
	host = str->tolower(host);
	if(len host > 2 && host[0] == '[' && host[len host - 1] == ']')
		host = host[1:len host - 1];

	# literal name forms
	if(host == "localhost" || host == "ip6-localhost" ||
	   host == "metadata" || host == "metadata.google.internal")
		return 1;
	if(hasprefix(host, "localhost."))
		return 1;

	# IPv6: loopback, unspecified, unique-local (fc00::/7), link-local
	if(hasprefix(host, "::") || hasprefix(host, "fc") ||
	   hasprefix(host, "fd") || hasprefix(host, "fe80"))
		return 1;
	if(host == "0:0:0:0:0:0:0:1" ||
	   host == "0000:0000:0000:0000:0000:0000:0000:0001")
		return 1;

	# IPv4 literal in any radix (decimal, octal, hex, packed integer).
	# 0177.0.0.1, 0x7f.0.0.1 and 2130706433 are all 127.0.0.1.
	(v, ok) := parseipv4any(host);
	if(ok)
		return publicipv4(dotted(v)) != 1;

	return 0;
}

# Parse an IPv4 literal the way inet_aton does: 1-4 dot-separated
# parts, each decimal, octal (leading 0) or hex (leading 0x).
# Returns (address, 1) on success.
parseipv4any(s: string): (int, int)
{
	if(s == nil || s == "")
		return (0, 0);
	parts: list of int;
	nparts := 0;
	start := 0;
	for(i := 0; i <= len s; i++) {
		if(i < len s && s[i] != '.')
			continue;
		if(i == start)
			return (0, 0);
		(v, ok) := parseradix(s[start:i]);
		if(!ok)
			return (0, 0);
		parts = v :: parts;
		nparts++;
		start = i + 1;
	}
	if(nparts < 1 || nparts > 4)
		return (0, 0);
	# reverse into order
	ordered := array[nparts] of int;
	k := nparts - 1;
	for(pl := parts; pl != nil; pl = tl pl)
		ordered[k--] = hd pl;

	# last part absorbs the remaining bytes (a.b.c.d, a.b.c, a.b, a)
	addr := 0;
	for(j := 0; j < nparts - 1; j++) {
		if(ordered[j] > 255)
			return (0, 0);
		addr |= ordered[j] << (8 * (3 - j));
	}
	last := ordered[nparts - 1];
	maxlast := 0;
	case nparts {
	1 => maxlast = 16r7fffffff;	# full 32-bit (int is signed; see below)
	2 => maxlast = 16rffffff;
	3 => maxlast = 16rffff;
	* => maxlast = 16rff;
	}
	if(last < 0 || (nparts > 1 && last > maxlast))
		return (0, 0);
	addr |= last;
	return (addr, 1);
}

parseradix(s: string): (int, int)
{
	if(s == nil || s == "" || len s > 11)
		return (0, 0);
	base := 10;
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		base = 16;
		s = s[2:];
	} else if(len s > 1 && s[0] == '0') {
		base = 8;
		s = s[1:];
	}
	if(s == "")
		return (0, 1);
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(base == 16 && c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(base == 16 && c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		if(d < 0 || d >= base)
			return (0, 0);
		v = v * base + d;
		if(v < 0)
			return (0, 0);	# overflowed
	}
	return (v, 1);
}

dotted(v: int): string
{
	return sys->sprint("%d.%d.%d.%d", (v >> 24) & 16rff,
		(v >> 16) & 16rff, (v >> 8) & 16rff, v & 16rff);
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}
